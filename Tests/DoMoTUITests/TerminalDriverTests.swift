// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The live terminal driver, exercised HEADLESSLY. Every collaborator the driver
// binds — the input byte stream, the resize stream, the terminal lifecycle — is
// injected, so the whole interactive loop runs with no TTY: scripted keystrokes
// go in through an `AsyncStream`, the focused component records what it received,
// and the frame bytes come back out through the capture target into a SwiftTerm
// oracle. The four guarantees the driver exists to make are each pinned here:
// input reaches focus, a resize repaints, restore always runs (quit AND cancel),
// and key-release is filtered unless the component opts in.

import DoMoCore
import DoMoTermIO
import Synchronization
import Testing

@testable import DoMoTUI

// MARK: - Test doubles

/// A ``TerminalLifecycleControl`` that records enter/stop counts instead of
/// touching a real terminal — the seam that lets a test assert "restore ran
/// exactly once" without a `tcsetattr`. `Sendable` (the protocol demands it), so
/// the counters live behind a `Mutex`.
private final class RecordingLifecycle: TerminalLifecycleControl {
    private let counts = Mutex<(enter: Int, stop: Int)>((enter: 0, stop: 0))
    private let enterError: DoMoError?

    init(enterError: DoMoError? = nil) {
        self.enterError = enterError
    }

    var enterCount: Int { counts.withLock { $0.enter } }
    var stopCount: Int { counts.withLock { $0.stop } }

    func enter() throws(DoMoError) {
        counts.withLock { $0.enter += 1 }
        if let enterError { throw enterError }
    }

    func stop() {
        counts.withLock { $0.stop += 1 }
    }
}

/// Let the in-memory capture target adopt an injected resize, the same way the
/// live stdout target adopts a `SIGWINCH` from the kernel. This is what makes a
/// scripted resize visible to the very next frame.
extension CaptureTarget: @MainActor ResizableRenderTarget {
    public func setSize(_ size: TerminalSize) {
        columns = size.columns
        rows = size.rows
    }
}

/// A focusable component that echoes the text of every keystroke it receives into
/// its own render — so a test can drive input and then read the result back off a
/// screen oracle, proving the keystroke traversed input → focus → render → bytes.
@MainActor
private final class EchoProbe: @MainActor Focusable {
    var focused = false
    var typed = ""

    func render(width: Int) -> [String] {
        [typed.isEmpty ? "_" : typed]
    }

    func handleInput(_ data: [UInt8]) {
        if let text = String(bytes: data, encoding: .utf8) {
            typed += text
        }
    }
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

/// Yield the main actor for a real interval so the driver's concurrent input and
/// resize child tasks (which hop back onto this actor) get to run. Used only by
/// the tests that drive the loop while it is live; the input-EOF tests need no
/// settle because `run` returns on its own when the scripted stream ends.
@MainActor
private func settle(_ milliseconds: Int = 30) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

// MARK: - Tests

@MainActor
@Suite("Live terminal driver")
struct TerminalDriverTests {
    /// Scripted keystrokes reach the focused component, in order, and the loop
    /// tears the terminal back down when the input stream ends.
    @Test("Scripted keystrokes reach the focused component")
    func keystrokesReachFocus() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let probe = FocusableProbe("probe")
        tui.addChild(probe)
        tui.setFocus(probe)

        let lifecycle = RecordingLifecycle()
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        // Buffer the whole script, then end the stream: `run` drains every chunk
        // and returns on input-EOF — no timers, fully deterministic.
        inputCont.yield(bytes("a"))
        inputCont.yield(bytes("b"))
        inputCont.yield(bytes("c"))
        inputCont.finish()

        await driver.run(tui, quit: QuitSignal())

        #expect(probe.received == [bytes("a"), bytes("b"), bytes("c")])
        #expect(lifecycle.enterCount == 1)
        #expect(lifecycle.stopCount == 1)
    }

    /// The full traversal, asserted through the oracle: typed characters land in
    /// the focused component AND show up in the rendered cell grid.
    @Test("Keystrokes render through to the screen grid")
    func keystrokesRenderToGrid() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let target = CaptureTarget(columns: 20, rows: 4)
        let tui = TUI(target: target)
        let probe = EchoProbe()
        tui.addChild(probe)
        tui.setFocus(probe)

        let driver = TerminalDriver(input: input, resize: resize, lifecycle: RecordingLifecycle())

        inputCont.yield(bytes("h"))
        inputCont.yield(bytes("i"))
        inputCont.finish()

        await driver.run(tui, quit: QuitSignal())

        #expect(probe.typed == "hi")

        // Replay every emitted frame into a fresh VT100; the final grid is "hi".
        let oracle = ScreenOracle(rows: 4, cols: 20)
        oracle.feed(target.drain())
        #expect(oracle.row(0) == "hi")
    }

    /// A completed bracketed paste is re-wrapped in its guards before reaching the
    /// focused component — the framer strips them, the driver puts them back for
    /// the one consumer (the editor) that treats a paste as atomic.
    @Test("A bracketed paste arrives re-wrapped")
    func pasteReWrapped() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui = TUI(target: CaptureTarget(columns: 40, rows: 6))
        let probe = FocusableProbe("probe")
        tui.addChild(probe)
        tui.setFocus(probe)

        let driver = TerminalDriver(input: input, resize: resize, lifecycle: RecordingLifecycle())

        inputCont.yield(bytes("\u{1b}[200~pasted\u{1b}[201~"))
        inputCont.finish()

        await driver.run(tui, quit: QuitSignal())

        #expect(probe.received == [bytes("\u{1b}[200~pasted\u{1b}[201~")])
    }

    /// Key-release events are dropped for an ordinary component and delivered to
    /// one that opts in — the filter the driver inherits from `TUI.handleInput`.
    @Test("Key-release is filtered unless the component opts in")
    func keyReleaseFiltering() async {
        // Ordinary component: release swallowed, press delivered.
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let probe = FocusableProbe("probe")
        tui.addChild(probe)
        tui.setFocus(probe)
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: RecordingLifecycle())

        inputCont.yield(bytes("\u{1b}[97;1:3u")) // Kitty 'a' RELEASE
        inputCont.yield(bytes("a")) // plain press
        inputCont.finish()
        await driver.run(tui, quit: QuitSignal())
        #expect(probe.received == [bytes("a")])

        // Opt-in component: the same release is delivered.
        let (input2, input2Cont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize2, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui2 = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let probe2 = FocusableProbe("probe")
        probe2.wantsKeyRelease = true
        tui2.addChild(probe2)
        tui2.setFocus(probe2)
        let driver2 = TerminalDriver(input: input2, resize: resize2, lifecycle: RecordingLifecycle())

        input2Cont.yield(bytes("\u{1b}[97;1:3u"))
        input2Cont.finish()
        await driver2.run(tui2, quit: QuitSignal())
        #expect(probe2.received == [bytes("\u{1b}[97;1:3u")])
    }

    /// A resize event repaints: a width change forces the full-redraw path, and
    /// the new grid reflows to the new width.
    @Test("A resize triggers a re-render at the new size")
    func resizeRepaints() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, resizeCont) = AsyncStream.makeStream(of: TerminalSize.self)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(Text("hello"))
        let quit = QuitSignal()
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: RecordingLifecycle())

        let runTask = Task { await driver.run(tui, quit: quit) }
        await settle()
        // Initial frame done.
        #expect(tui.fullRedraws == 1)
        _ = target.drain()
        let before = tui.fullRedraws

        // Shrink to 10 columns; the driver applies it and repaints.
        resizeCont.yield(TerminalSize(columns: 10, rows: 6))
        await settle()
        let resizeBytes = target.drain()

        #expect(tui.fullRedraws == before + 1) // width change → full redraw
        #expect(resizeBytes.contains("\u{1b}[2J")) // ...which clears the screen
        let oracle = ScreenOracle(rows: 6, cols: 10)
        oracle.feed(resizeBytes)
        #expect(oracle.row(0) == "hello")

        quit.quit()
        inputCont.finish()
        resizeCont.finish()
        await runTask.value
    }

    /// A component pulling the quit signal ends the loop and restores the terminal.
    @Test("Quit from within the UI exits and restores")
    func quitRestores() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, resizeCont) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let lifecycle = RecordingLifecycle()
        let quit = QuitSignal()
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        let runTask = Task { await driver.run(tui, quit: quit) }
        await settle()
        quit.quit()
        inputCont.finish()
        resizeCont.finish()
        await runTask.value

        #expect(lifecycle.enterCount == 1)
        #expect(lifecycle.stopCount == 1)
    }

    /// Cancelling the task running the loop still restores the terminal — the
    /// guarantee that a crash-adjacent shutdown never leaves the tty in raw mode.
    @Test("Cancellation exits and restores")
    func cancellationRestores() async {
        let (input, _) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let lifecycle = RecordingLifecycle()
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        // Streams never finish; only cancellation can end this loop.
        let runTask = Task { await driver.run(tui, quit: QuitSignal()) }
        await settle()
        runTask.cancel()
        await runTask.value

        #expect(lifecycle.enterCount == 1)
        #expect(lifecycle.stopCount == 1)
    }

    /// Background work (the agent) runs concurrently with input and flushes its
    /// component updates through the driver's synchronous render seam.
    @Test("Background work renders concurrently, then quits")
    func backgroundWorkRenders() async {
        let (input, _) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let content = LinesComponent(["start"])
        tui.addChild(content)
        let quit = QuitSignal()
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: RecordingLifecycle())

        let ran = Mutex(false)
        // The input stream never ends; the background job is what quits, proving
        // it ran to completion alongside the (idle) input pump.
        await driver.run(tui, quit: quit, background: {
            await MainActor.run { content.lines = ["start", "bg"] }
            await driver.render()
            ran.withLock { $0 = true }
            quit.quit()
        })

        #expect(ran.withLock { $0 })
        let oracle = ScreenOracle(rows: 6, cols: 20)
        oracle.feed(target.drain())
        #expect(oracle.row(0) == "start")
        #expect(oracle.row(1) == "bg")
    }

    /// A non-terminal descriptor makes `enter` throw; `run` records the startup
    /// error and returns without ever entering the group.
    @Test("A failed raw-mode enter is reported, not fatal")
    func failedEnterReported() async {
        let (input, _) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let tui = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let lifecycle = RecordingLifecycle(enterError: DoMoError(.malformedResponse, "not a tty"))
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        await driver.run(tui, quit: QuitSignal())

        #expect(driver.startupError != nil)
        #expect(lifecycle.enterCount == 1)
    }
}

// MARK: - The live fd reader (regression)

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// `standardInputStream` builds a `DispatchSource` whose event handler runs on a
/// background queue. Under DoMoTUI's `.defaultIsolation(MainActor.self)` that
/// handler was `@MainActor`-isolated, so firing it off the main actor trapped in
/// `dispatchPrecondition` — crashing the real binary on the first keystroke. The
/// headless tests above inject their own `AsyncStream` and never touch the real
/// reader, so only driving an actual descriptor catches it. A pipe stands in for
/// stdin: if the handler were main-actor-isolated, consuming this stream would
/// trap rather than yield.
@Suite("TerminalDriver live input")
struct TerminalDriverLiveInputTests {
    @Test("The DispatchSource reader yields bytes off the main actor without trapping")
    func liveReaderDoesNotTrap() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let readEnd = fds[0]
        let writeEnd = fds[1]

        let payload = Array("hi\u{1b}[A".utf8) // plain + an arrow escape
        _ = payload.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
        close(writeEnd) // EOF after the payload, so the stream finishes

        var received: [UInt8] = []
        for await chunk in TerminalDriver.standardInputStream(fileDescriptor: readEnd) {
            received.append(contentsOf: chunk)
        }
        close(readEnd)

        #expect(received == payload)
    }
}
