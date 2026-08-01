// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two complaints, end to end:
//
//   "the current TUI doesn't let me highlight and copy text. I'd very much like
//    to be able to highlight, right click and copy text into my clipboard."
//   "I very much like Claude Code's support to drag and drop images into your
//    prompt to use them as context rather than having to specify by
//    filename/path."
//
// Everything here runs the REAL full-screen client — `runFullScreenClient` over
// a real `ServerClient`, a real `TerminalDriver` and a real in-process
// `DoMoServer` — feeds it the exact bytes a terminal sends for a drag, a
// right-click, an F8 and a file drop, and asserts on the CELLS a VT100 emulator
// ends up with plus on what actually crossed the clipboard seam and the wire. A
// test that asserts on a controller proves the model; only this proves the
// gesture.

import AsyncHTTPClient
import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoLLM
import DoMoServer
import DoMoTermIO
import DoMoTUI
import Foundation
import Synchronization
import SystemPackage
import Testing

// MARK: - Doubles

/// A render target that keeps a live VT100 emulator alongside the raw bytes.
///
/// The emulator is fed INCREMENTALLY, as each frame is written, rather than by
/// replaying the whole capture on every assertion. That is not an optimisation
/// for its own sake: these tests poll the screen every few milliseconds while a
/// real client runs on the same main actor, and replaying a growing buffer into
/// a fresh 24×220 emulator on every poll starves the very client being tested —
/// and, when two such suites run at once, each other's.
@MainActor
private final class CaptureTarget: RenderTarget {
    let columns: Int
    let rows: Int
    let page: ScreenOracle
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        self.page = ScreenOracle(rows: rows, cols: columns)
    }

    func write(_ bytes: String) {
        buffer += bytes
        page.feed(bytes)
    }

    func snapshot() -> String { buffer }
}

/// A lifecycle that records every mid-session mouse-mode change, which is the
/// only externally observable effect F8 has.
private final class RecordingLifecycle: TerminalLifecycleControl {
    private let modes = Mutex<[Bool]>([])
    func enter() throws(DoMoError) {}
    func stop() {}
    func setMouseReporting(_ enabled: Bool) { modes.withLock { $0.append(enabled) } }
    var recorded: [Bool] { modes.withLock { $0 } }
}

/// The user messages a run was actually asked to execute, captured from inside
/// the stream function. A class because `Mutex` is noncopyable and cannot be
/// passed as a parameter.
private final class SeenMessages: Sendable {
    private let storage = Mutex<[Message]>([])
    func record(_ messages: [Message]) { storage.withLock { $0 = messages } }
    var messages: [Message] { storage.withLock { $0 } }
}

/// Records exactly what reached the system-clipboard seam.
private final class RecordingClipboard: ClipboardSink {
    private let texts = Mutex<[String]>([])
    func copy(_ text: String) async -> ClipboardOutcome {
        texts.withLock { $0.append(text) }
        return .copied("recorder")
    }
    var recorded: [String] { texts.withLock { $0 } }
}

// MARK: - Byte sequences a terminal really sends

private enum Term {
    static func press(column: Int, row: Int, button: Int = 0, shift: Bool = false) -> [UInt8] {
        Array("\u{1b}[<\(button + (shift ? 4 : 0));\(column + 1);\(row + 1)M".utf8)
    }
    /// A motion report with the left button held — what `?1002h` adds, and the
    /// only thing that makes a drag distinguishable from a press and a release
    /// far apart.
    static func drag(column: Int, row: Int) -> [UInt8] {
        Array("\u{1b}[<32;\(column + 1);\(row + 1)M".utf8)
    }
    static func release(column: Int, row: Int) -> [UInt8] {
        Array("\u{1b}[<0;\(column + 1);\(row + 1)m".utf8)
    }
    static func rightPress(column: Int, row: Int) -> [UInt8] { press(column: column, row: row, button: 2) }
    static let f8 = Array("\u{1b}[19~".utf8)
    static let escape: [UInt8] = [0x1b]

    /// `ESC [ M` + three bytes biased by 32 — the pre-SGR encoding a terminal
    /// falls back to when it does not answer `?1006h`.
    static func x10(_ code: Int, column: Int, row: Int) -> [UInt8] {
        [0x1b, 0x5b, 0x4d, UInt8(code + 32), UInt8(column + 33), UInt8(row + 33)]
    }
    static func x10Press(column: Int, row: Int) -> [UInt8] { x10(0, column: column, row: row) }
    static func x10Drag(column: Int, row: Int) -> [UInt8] { x10(32, column: column, row: row) }
    /// X10 has no release code of its own: it sends button bits `3`, which the
    /// decoder reports as `.release` with `.none` for the button.
    static func x10Release(column: Int, row: Int) -> [UInt8] { x10(3, column: column, row: row) }
    static func x10RightPress(column: Int, row: Int) -> [UInt8] { x10(2, column: column, row: row) }

    /// A wheel-up report over a cell, the way `?1006h` spells it.
    static func wheelUp(column: Int, row: Int) -> [UInt8] {
        Array("\u{1b}[<64;\(column + 1);\(row + 1)M".utf8)
    }
    static func wheelDown(column: Int, row: Int) -> [UInt8] {
        Array("\u{1b}[<65;\(column + 1);\(row + 1)M".utf8)
    }

    static let pageUp = Array("\u{1b}[5~".utf8)
    static let pageDown = Array("\u{1b}[6~".utf8)
    /// The xterm/kitty/iTerm2 spelling. Byte-distinct from the bare `ESC [ A`
    /// that recalls prompt history, which is the whole reason it is safe to bind.
    static let shiftUp = Array("\u{1b}[1;2A".utf8)
    static let shiftDown = Array("\u{1b}[1;2B".utf8)
    static let up = Array("\u{1b}[A".utf8)
    static func paste(_ text: String) -> [UInt8] {
        Array("\u{1b}[200~\(text)\u{1b}[201~".utf8)
    }
}

// MARK: - Suite

@MainActor
@Suite(.serialized)
struct SelectionCopyAndDropEndToEndTests {
    private static let token = "e2e-selection-drop-token"
    private static let columns = 150
    private static let rows = 24

    /// The smallest thing `FileContentProbe` will call a PNG: the 8-byte
    /// signature plus a well-formed IHDR for a 1×1 image.
    private static let onePixelPNG: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
        bytes += [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00]
        bytes += [0x1F, 0x15, 0xC4, 0x89]
        return Data(bytes)
    }()

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        let files: URL
        init() throws {
            // Deliberately SHORT: a restored path has to fit one prompt row for
            // the "it came back as text" assertions to be about the feature
            // rather than about word wrap.
            root = URL(fileURLWithPath: "/tmp/domo-w4-\(UUID().uuidString.prefix(8))", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            files = root.appendingPathComponent("files", isDirectory: true)
            for directory in [cwd, sessions, files] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A server whose model answers with one line, and which records every
    /// user message it was asked to run — including its image blocks.
    private func makeServer(_ dirs: Dirs, seen: SeenMessages, reply: String) -> DoMoServer {
        makeServer(dirs, seen: seen, replyFor: { _ in reply })
    }

    /// The same, with a reply that depends on the conversation so far — needed
    /// wherever a test has to make two turns produce DIFFERENT rows.
    private func makeServer(
        _ dirs: Dirs,
        seen: SeenMessages,
        replyFor: @escaping @Sendable ([Message]) -> String
    ) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: { context in
                seen.record(context.messages)
                let answer = replyFor(context.messages)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                    continuation.yield(.done(AssistantMessage(
                        content: [.text(answer)], model: "test-model", stopReason: .stop
                    )))
                    continuation.finish()
                }
            },
            toolExecution: .sequential,
            maxTurns: 4,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(20),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func oracle(_ target: CaptureTarget) -> ScreenOracle { target.page }

    private func screenHas(_ target: CaptureTarget, _ needle: String) -> Bool {
        oracle(target).screen.contains { $0.contains(needle) }
    }

    /// Whether anything in the TRANSCRIPT is painted in reverse video.
    ///
    /// Two exclusions, both because reverse video is already in use elsewhere and
    /// "is anything inverse on the page" would therefore be permanently true:
    /// the sidebar paints its focused row that way, and the prompt paints its
    /// caret that way. What is left is the transcript viewport, which is the only
    /// place a selection highlight can be.
    private func transcriptHasHighlight(_ target: CaptureTarget) -> Bool {
        // `min(32, max(16, columns / 4))` at this width, and the footer the
        // client builds for an empty single-line prompt: one status row plus a
        // three-row bordered editor.
        let sidebar = 32
        let transcriptRows = Self.rows - 4
        let page = oracle(target)
        for row in 0..<transcriptRows {
            for column in sidebar..<Self.columns where page.cell(col: column, row: row)?.style.inverse == true {
                return true
            }
        }
        return false
    }

    /// Wait until the client is ready to be driven.
    ///
    /// The settle is not superstition. The sidebar marks a session open as soon
    /// as `select` runs, which is BEFORE `open()` has resumed the session on the
    /// server and subscribed to its event stream — and a prompt sent in that
    /// window starts a run whose events nobody is listening for, so the
    /// transcript stays empty forever. Nothing on screen reports the stream's
    /// state, so this is a delay rather than a condition.
    private func settle(_ target: CaptureTarget) async {
        _ = await waitUntil { self.ready(target) }
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// The client is up AND a session is open.
    ///
    /// Both halves are load-bearing. The status line paints before `bootstrap`
    /// has opened a session, and a prompt submitted in that window is correctly
    /// refused and put back — so a test that starts typing as soon as it sees a
    /// status line is testing the refusal path by accident. The sidebar's open
    /// marker is the first thing on screen that says a session exists.
    private func ready(_ target: CaptureTarget) -> Bool {
        screenHas(target, "Enter: send") && screenHas(target, "•")
    }

    /// Where `needle` sits on the painted page, as (row, first column).
    private func locate(_ target: CaptureTarget, _ needle: String) -> (row: Int, column: Int)? {
        for (index, line) in oracle(target).screen.enumerated() {
            if let range = line.range(of: needle) {
                return (index, line.distance(from: line.startIndex, to: range.lowerBound))
            }
        }
        return nil
    }

    /// Run the real client and drive it, returning the capture and the doubles.
    private func runClient(
        port: Int,
        clipboard: RecordingClipboard,
        lifecycle: RecordingLifecycle,
        script: @escaping @MainActor (AsyncStream<[UInt8]>.Continuation, CaptureTarget) async -> Void
    ) async -> CaptureTarget {
        // One end-to-end client at a time across the whole binary — see
        // FullScreenClientGate.
        await FullScreenClientGate.shared.enter()
        let target = CaptureTarget(columns: Self.columns, rows: Self.rows)
        let (input, inputCont) = AsyncStream<[UInt8]>.makeStream()
        let (resize, resizeCont) = AsyncStream<TerminalSize>.makeStream()
        let clientTask = Task { @MainActor in
            try? await runFullScreenClient(
                baseURL: "http://127.0.0.1:\(port)",
                token: Self.token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: lifecycle,
                clipboard: clipboard
            )
        }
        await script(inputCont, target)
        inputCont.yield([0x03])
        inputCont.finish()
        resizeCont.finish()
        _ = await clientTask.result
        await FullScreenClientGate.shared.leave()
        return target
    }

    private func startServer(_ server: DoMoServer) async -> (task: Task<Void, any Error>, port: Int) {
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let task = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var iterator = ports.makeAsyncIterator()
        return (task, await iterator.next() ?? 0)
    }

    // MARK: Selection and copy

    @Test("Drag across the transcript, right-click, and the clipboard has the exact plain text")
    func dragRightClickCopies() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let clipboard = RecordingClipboard()
        let lifecycle = RecordingLifecycle()
        // A word that cannot occur anywhere else on the page, so locating it is
        // unambiguous and the copy can be compared for EQUALITY rather than for
        // "contains" — the padding and escape bugs only show up in equality.
        let needle = "ZEBRAFISH-QUARTZ"

        let target = await runClient(port: port, clipboard: clipboard, lifecycle: lifecycle) { input, target in
            await self.settle(target)
            input.yield(Array(needle.utf8))
            input.yield([0x0d])
            // The reply is what proves the turn completed, which is what proves
            // the needle has moved out of the prompt and into the transcript.
            _ = await self.waitUntil { self.screenHas(target, "ack") && self.locate(target, needle) != nil }
            guard let spot = self.locate(target, needle) else { return }

            input.yield(Term.press(column: spot.column, row: spot.row))
            input.yield(Term.drag(column: spot.column + needle.count, row: spot.row))
            input.yield(Term.release(column: spot.column + needle.count, row: spot.row))
            // The highlight has to be on screen BEFORE the copy, or the copy is
            // proving something the user could not see.
            _ = await self.waitUntil {
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true
            }
            input.yield(Term.rightPress(column: spot.column, row: spot.row))
            _ = await self.waitUntil { !clipboard.recorded.isEmpty }
            // The highlight goes with the copy — it has served its purpose, and
            // leaving it up invites a second right-click that copies the same
            // thing again. Waited for HERE, inside the run, because the frame is
            // only repainted while the client is alive.
            _ = await self.waitUntil { !self.transcriptHasHighlight(target) }
        }

        #expect(clipboard.recorded == [needle], "the clipboard got \(clipboard.recorded)")
        #expect(!transcriptHasHighlight(target), "the highlight outlived the copy")
        #expect(!screenHas(target, "Esc: clear selection"), "the selection outlived the copy")
        // The user is told it happened; a silent copy is indistinguishable from a
        // dead right-click.
        #expect(screenHas(target, "copied 1 line"))
        // And the terminal-native path fired too: OSC 52 is the only one that
        // works over ssh, and it is invisible to the emulator, so it is asserted
        // on the raw byte stream.
        #expect(target.snapshot().contains("\u{1b}]52;c;"), "no OSC 52 reached the terminal")
        let payload = Data(needle.utf8).base64EncodedString()
        #expect(target.snapshot().contains("\u{1b}]52;c;\(payload)\u{07}"))

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A drag down the transcript never cuts the sidebar into the copied lines")
    func multiRowDragStaysInThePane() async throws {
        // The sidebar and the transcript share every screen row. Without a pane
        // window the stream rule would take whole ROWS for everything between the
        // first and the last, so every middle line would arrive with the session
        // list's columns glued to its front.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, replyFor: { _ in
            (1...12).map { "ROW-\($0)" }.joined(separator: "\n")
        })
        let (serverTask, port) = await startServer(server)
        let clipboard = RecordingClipboard()

        _ = await runClient(port: port, clipboard: clipboard, lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array("go".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "ROW-12") != nil }
            guard let first = self.locate(target, "ROW-10"),
                  let last = self.locate(target, "ROW-12") else { return }

            input.yield(Term.press(column: first.column, row: first.row))
            input.yield(Term.drag(column: last.column + 6, row: last.row))
            input.yield(Term.release(column: last.column + 6, row: last.row))
            _ = await self.waitUntil {
                self.oracle(target).cell(col: first.column, row: first.row)?.style.inverse == true
            }
            input.yield(Term.rightPress(column: first.column, row: first.row))
            _ = await self.waitUntil { !clipboard.recorded.isEmpty }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(clipboard.recorded == ["ROW-10\nROW-11\nROW-12"], "copied \(clipboard.recorded)")
    }

    @Test("The highlight is reverse video exactly where the drag was, and nowhere else")
    func highlightCoversTheDragAndNothingElse() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let needle = "MARMALADE-ORBIT"

        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array(needle.utf8))
            input.yield([0x0d])
            // The reply is what proves the turn completed, which is what proves
            // the needle has moved out of the prompt and into the transcript.
            _ = await self.waitUntil { self.screenHas(target, "ack") && self.locate(target, needle) != nil }
            guard let spot = self.locate(target, needle) else { return }
            input.yield(Term.press(column: spot.column, row: spot.row))
            input.yield(Term.drag(column: spot.column + 6, row: spot.row))
            input.yield(Term.release(column: spot.column + 6, row: spot.row))
            _ = await self.waitUntil {
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true
            }
        }

        let spot = try #require(locate(target, needle))
        let page = oracle(target)
        for column in spot.column..<(spot.column + 6) {
            #expect(page.cell(col: column, row: spot.row)?.style.inverse == true, "column \(column) is not highlighted")
        }
        #expect(page.cell(col: spot.column + 6, row: spot.row)?.style.inverse == false, "the highlight ran past the drag")
        #expect(page.cell(col: max(0, spot.column - 1), row: spot.row)?.style.inverse == false)
        // Not a paint bug either: the row still reads as itself.
        #expect(page.screen[spot.row].contains(needle))

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("Escape clears a live selection; a second Escape aborts as it always did")
    func escapeClearsTheSelectionFirst() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let needle = "CLEAR-ME-PLEASE"

        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array(needle.utf8))
            input.yield([0x0d])
            // The reply is what proves the turn completed, which is what proves
            // the needle has moved out of the prompt and into the transcript.
            _ = await self.waitUntil { self.screenHas(target, "ack") && self.locate(target, needle) != nil }
            guard let spot = self.locate(target, needle) else { return }
            input.yield(Term.press(column: spot.column, row: spot.row))
            input.yield(Term.drag(column: spot.column + 8, row: spot.row))
            input.yield(Term.release(column: spot.column + 8, row: spot.row))
            _ = await self.waitUntil { self.screenHas(target, "Esc: clear selection") }
            input.yield(Term.escape)
            _ = await self.waitUntil { !self.screenHas(target, "Esc: clear selection") }
        }

        // The hint appeared and then went away, which is only possible if the
        // selection was live and then was not.
        #expect(!screenHas(target, "Esc: clear selection"))
        #expect(screenHas(target, "Esc: abort"), "the ordinary hints came back")
        let spot = try #require(locate(target, needle))
        #expect(oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == false, "the highlight outlived Escape")

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A right-click with nothing selected says what the gesture is for")
    func rightClickWithNoSelection() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let clipboard = RecordingClipboard()

        let target = await runClient(port: port, clipboard: clipboard, lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.rightPress(column: 60, row: 3))
            _ = await self.waitUntil { self.screenHas(target, "drag to select") }
        }

        #expect(screenHas(target, "drag to select"))
        #expect(clipboard.recorded.isEmpty, "an empty selection must not copy anything")

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("F8 releases the mouse and takes it back, and says which mode is active")
    func f8TogglesMouseCapture() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let lifecycle = RecordingLifecycle()

        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: lifecycle) { input, target in
            await self.settle(target)
            #expect(self.screenHas(target, "F8: release mouse"), "the capture state must be visible from the start")
            input.yield(Term.f8)
            _ = await self.waitUntil { self.screenHas(target, "mouse released") }
            #expect(self.screenHas(target, "F8: capture mouse"))
            // The PERSISTENT marker, not the six-second notice. It is spelled
            // "mouse: released" precisely so the two can be told apart on the
            // page: while they shared a spelling, deleting the marker changed
            // nothing any test could see, and a user who let the notice lapse had
            // no way to tell which mode they were in.
            #expect(self.screenHas(target, "mouse: released"), "no persistent mouse-mode marker")
            // The wheel goes with the mouse, and the notice has to say so — plus
            // name what replaces it, or F8 is a one-way door out of scrolling.
            #expect(self.screenHas(target, "PgUp/PgDn"), "the F8 notice did not name the replacement")
            // With the mouse released a stray report — one already in the pipe
            // when F8 was pressed — must not select anything.
            input.yield(Term.press(column: 60, row: 3))
            input.yield(Term.drag(column: 80, row: 3))
            input.yield(Term.release(column: 80, row: 3))
            // A keystroke AFTER the reports, waited on: input frames are handled
            // in order, so seeing this on screen proves the reports were handled
            // and repainted. Waiting on the hint alone would prove nothing — it is
            // already true before the reports arrive.
            input.yield(Array("ZZQ".utf8))
            _ = await self.waitUntil { self.screenHas(target, "ZZQ") }
            #expect(!self.screenHas(target, "Esc: clear selection"), "a released mouse still selected")
            #expect(!self.transcriptHasHighlight(target), "a released mouse still painted a highlight")
            input.yield(Term.f8)
            _ = await self.waitUntil { self.screenHas(target, "mouse captured") }
        }

        // The bytes that matter are the lifecycle's, not the app's flag: without
        // this call the terminal is still in `?1002h` and the user's own
        // selection stays broken however the status line describes it.
        #expect(lifecycle.recorded == [false, true], "recorded \(lifecycle.recorded)")
        #expect(screenHas(target, "F8: release mouse"))

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A selection is dropped when the rows under it actually change")
    func selectionDiesWhenTheTranscriptMovesUnderIt() async throws {
        // The invalidation policy, on the real render loop. The selection has to
        // survive an ordinary repaint — this test would be meaningless if it did
        // not, because every frame is a repaint — and has to be GONE the moment
        // the rows it names hold different text, because the alternative is a
        // highlight over one thing and a clipboard full of another.
        //
        // The reply is deliberately taller than the viewport so the transcript is
        // full and bottom-anchored: a second turn then genuinely moves every row,
        // which is the condition being tested. A short transcript grows downward
        // and would leave the selected row exactly where it was.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        // The reply names its own turn: two identical replies would leave the
        // selected row holding the very same text after the shift, and the
        // selection would then correctly — but uninterestingly — survive.
        let server = makeServer(dirs, seen: seen, replyFor: { messages in
            let turn = messages.filter { if case .user = $0 { return true } else { return false } }.count
            return (1...30).map { "T\(turn)-LINE-\($0)" }.joined(separator: "\n")
        })
        let (serverTask, port) = await startServer(server)
        var highlightedWhileStill = false
        var highlightedAfterTheShift = true

        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array("first".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "T1-LINE-30") != nil }
            guard let spot = self.locate(target, "T1-LINE-30") else { return }

            input.yield(Term.press(column: spot.column, row: spot.row))
            input.yield(Term.drag(column: spot.column + 7, row: spot.row))
            input.yield(Term.release(column: spot.column + 7, row: spot.row))
            _ = await self.waitUntil {
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true
            }

            // Typing repaints the prompt rows and the status line, not the
            // selected transcript row.
            input.yield(Array("again".utf8))
            _ = await self.waitUntil { self.screenHas(target, "again") }
            highlightedWhileStill =
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true

            // Sending pushes a second thirty-line reply in, so every transcript
            // row now holds something the selection never named.
            input.yield([0x0d])
            _ = await self.waitUntil { !self.transcriptHasHighlight(target) }
            highlightedAfterTheShift = self.transcriptHasHighlight(target)
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(highlightedWhileStill, "an ordinary repaint destroyed the selection")
        #expect(!highlightedAfterTheShift, "the highlight outlived the content it named")
    }

    @Test("Scrolling clears the selection before the rows move")
    func wheelClearsTheSelection() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let needle = "TANGERINE-BOLT"
        var stillHighlighted = true

        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array(needle.utf8))
            input.yield([0x0d])
            // The reply is what proves the turn completed, which is what proves
            // the needle has moved out of the prompt and into the transcript.
            _ = await self.waitUntil { self.screenHas(target, "ack") && self.locate(target, needle) != nil }
            guard let spot = self.locate(target, needle) else { return }
            input.yield(Term.press(column: spot.column, row: spot.row))
            input.yield(Term.drag(column: spot.column + needle.count, row: spot.row))
            input.yield(Term.release(column: spot.column + needle.count, row: spot.row))
            _ = await self.waitUntil {
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true
            }
            // Wheel up over the transcript.
            input.yield(Array("\u{1b}[<64;\(spot.column + 1);\(spot.row + 1)M".utf8))
            _ = await self.waitUntil { !self.transcriptHasHighlight(target) }
            stillHighlighted = self.transcriptHasHighlight(target)
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(!stillHighlighted, "the highlight survived a scroll that moved the rows under it")
    }

    // MARK: Dropping a file

    /// What a drop looked like WHILE it was staged, plus the finished capture.
    ///
    /// The chip has to be observed before the send, because submitting clears
    /// the attachments — an assertion made after the run would be asking whether
    /// the chip is still there, which it correctly is not.
    private struct DropRun {
        var target: CaptureTarget
        var chipRowsWhileStaged: [String]
    }

    /// Drop `spelling` on the prompt, then send, and report both.
    private func dropAndSend(
        _ dirs: Dirs,
        spelling: String,
        chipNeedle: String,
        seen: SeenMessages
    ) async throws -> DropRun {
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(spelling))
            _ = await self.waitUntil { self.screenHas(target, chipNeedle) }
            staged = self.oracle(target).screen
            input.yield(Array("look".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.screenHas(target, "got it") }
        }
        serverTask.cancel()
        _ = try? await serverTask.value
        return DropRun(target: target, chipRowsWhileStaged: staged)
    }

    @Test("Every spelling a terminal uses for a dropped file becomes a chip")
    func dropSpellings() async throws {
        // All four spellings in ONE session: a terminal only ever uses one of
        // them, but the parser has to accept all four, and four separate client
        // runs would quadruple the cost of saying so.
        //
        // A space in every name is the case that separates the readings: the
        // tokenizer cannot tell one file with a space from two files, and only
        // the disk can.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let forms = ["bare", "escaped", "quoted", "fileURL"]
        var spellings: [String] = []
        for form in forms {
            let file = dirs.files.appendingPathComponent("\(form) snap.png")
            try Self.onePixelPNG.write(to: file)
            let path = file.path
            switch form {
            case "escaped": spellings.append(path.replacingOccurrences(of: " ", with: "\\ ") + " ")
            case "quoted": spellings.append("'\(path)'")
            case "fileURL": spellings.append("file://" + path.replacingOccurrences(of: " ", with: "%20"))
            default: spellings.append(path)
            }
        }

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            for (form, spelling) in zip(forms, spellings) {
                input.yield(Term.paste(spelling))
                _ = await self.waitUntil { self.screenHas(target, "\(form) snap.png") }
            }
            staged = self.oracle(target).screen
            input.yield(Array("look".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.screenHas(target, "got it") }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        // 1. Every spelling produced a chip carrying the file's own name.
        for form in forms {
            #expect(staged.contains { $0.contains("\(form) snap.png") }, "no chip for \(form)")
        }
        // 2. No spelling leaked its raw text into the prompt.
        for spelling in spellings {
            #expect(!staged.contains { $0.contains(spelling) }, "\(spelling) leaked into the prompt")
        }
        // 3. The gateway received one image part per spelling, with the real bytes.
        let images = seen.messages.flatMap { message -> [ImageBlock] in
            guard case .user(let user) = message else { return [] }
            return user.content.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
        }
        #expect(images.count == forms.count, "the model saw \(images.count) images")
        #expect(images.allSatisfy { $0.data == Self.onePixelPNG && $0.mediaType == "image/png" })
        // 4. And the text rode with them.
        let texts = seen.messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { if case .text(let text) = $0 { return text.text } else { return nil } }.first
        }
        #expect(texts.contains("look"))
    }

    @Test("A path that is not an attachable image is left alone as text")
    func nonImageDropsKeepTheirText() async throws {
        // The guarantee the whole feature rests on, in the two shapes it takes:
        // a real file that is not an image, and a path with nothing behind it.
        // Both must leave the user holding exactly the text they pasted, plus a
        // line saying why nothing was attached.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let notes = dirs.files.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        let missing = dirs.files.appendingPathComponent("ghost.png").path

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        var afterText: [String] = []
        var afterMissing: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(notes.path))
            _ = await self.waitUntil { self.screenHas(target, "is not a supported image") }
            afterText = self.oracle(target).screen

            // Clear the box before the second case, so the two cannot be confused.
            for _ in 0..<notes.path.count { input.yield([0x7f]) }
            input.yield(Term.paste(missing))
            _ = await self.waitUntil { self.screenHas(target, "no such file") }
            afterMissing = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(afterText.contains { $0.contains(notes.path) }, "the .txt path did not come back as text")
        #expect(afterText.contains { $0.contains("not attached") })
        #expect(afterText.contains { $0.contains("is not a supported image") })
        #expect(afterMissing.contains { $0.contains(missing) }, "the missing path did not come back as text")
        #expect(afterMissing.contains { $0.contains("no such file") })
    }

    @Test("Prose that merely mentions a path is pasted, not eaten")
    func proseIsNeverADrop() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let file = dirs.files.appendingPathComponent("real.png")
        try Self.onePixelPNG.write(to: file)
        let prose = "please look at \(file.path) and tell me"

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(prose))
            _ = await self.waitUntil { self.screenHas(target, "please look at") }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(screenHas(target, "please look at"))
        #expect(!screenHas(target, "attached 1 image"), "prose was mistaken for a drop")
    }

    @Test("A 413 puts the message AND its attachments back, and says why")
    func oversizedAttachmentIsRecoverable() async throws {
        // The server bounds a prompt body, and an attachment is the only thing
        // that can realistically reach that bound. The failure mode this pins is
        // the expensive one: a refusal that restored the text and dropped the
        // images would have the user re-send a message that is silently missing
        // the picture it was about.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let file = dirs.files.appendingPathComponent("huge.png")
        try Self.onePixelPNG.write(to: file)

        // Route order matters: the prompt route is more specific than the
        // session route and has to be matched first.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("POST", "/prompt", 413, "Content Too Large", "request body is too large"),
                StubRoute("GET", "/sessions", 200, "OK",
                          #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/work","timestamp":"2026-01-01"}]"#),
                StubRoute("POST", "/session", 201, "Created", #"{"id":"abc123","path":"/tmp/abc123.jsonl"}"#),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        // One end-to-end client at a time across the whole binary — see
        // FullScreenClientGate.
        await FullScreenClientGate.shared.enter()
        let target = CaptureTarget(columns: Self.columns, rows: Self.rows)
        let (input, inputCont) = AsyncStream<[UInt8]>.makeStream()
        let (resize, resizeCont) = AsyncStream<TerminalSize>.makeStream()
        let clientTask = Task { @MainActor in
            try? await runFullScreenClient(
                baseURL: stub.baseURL,
                token: Self.token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: RecordingLifecycle(),
                clipboard: RecordingClipboard()
            )
        }
        // The stub answers `/events` with a 404, so the client never reports a
        // live stream and `settle`'s session check would simply time out. The
        // status line is enough here: nothing in this test needs a working run,
        // only a prompt that will POST.
        _ = await waitUntil { self.screenHas(target, "Enter: send") }
        try? await Task.sleep(for: .milliseconds(250))
        inputCont.yield(Term.paste(file.path))
        _ = await waitUntil { self.screenHas(target, "huge.png") }
        inputCont.yield(Array("look at this".utf8))
        inputCont.yield([0x0d])
        _ = await waitUntil { self.screenHas(target, "too large") }
        let after = oracle(target).screen
        inputCont.yield([0x03])
        inputCont.finish()
        resizeCont.finish()
        _ = await clientTask.result
        await FullScreenClientGate.shared.leave()

        // Asserted on the PERSISTENT row, not on the transient notice. `post(notice:)`
        // is a single slot with a TTL and several sources, so any other event inside
        // its window replaces it — here the stub's 404 `/events` reconnects and posts
        // "the session is live again" over it. That is the design working as intended
        // rather than a defect: a refusal the user has to act on gets a scrollable
        // transcript row with strictly more detail, which is precisely why the error
        // surface stopped relying on a message that evaporates after four seconds.
        #expect(
            after.contains { $0.contains("The server refused the message as too large") },
            "no persistent row:\n\(after.joined(separator: "\n"))"
        )
        #expect(after.contains { $0.contains("HTTP 413") })
        // Both halves of the message are back on the prompt.
        #expect(after.contains { $0.contains("look at this") }, "the text was destroyed by the refusal")
        #expect(after.contains { $0.contains("huge.png") }, "the chip was destroyed by the refusal")
    }

    @Test("Two files dropped at once become two chips and two image parts")
    func multiFileDrop() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let first = dirs.files.appendingPathComponent("one.png")
        let second = dirs.files.appendingPathComponent("two.png")
        try Self.onePixelPNG.write(to: first)
        try Self.onePixelPNG.write(to: second)

        let seen = SeenMessages()
        let run = try await dropAndSend(
            dirs,
            spelling: "\(first.path) \(second.path)",
            chipNeedle: "two.png",
            seen: seen
        )

        #expect(run.chipRowsWhileStaged.contains { $0.contains("one.png") })
        #expect(run.chipRowsWhileStaged.contains { $0.contains("two.png") })
        #expect(run.chipRowsWhileStaged.contains { $0.contains("attached 2 images") })
        let messages = seen.messages
        let images = messages.flatMap { message -> [ImageBlock] in
            guard case .user(let user) = message else { return [] }
            return user.content.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
        }
        #expect(images.count == 2, "the model saw \(images.count) images")
    }

    @Test("Dropping the same file twice says so instead of claiming a new chip")
    func reDroppingSaysAlreadyAttached() async throws {
        // A duplicate is neither a success nor a failure, and the two wrong
        // answers are both worse than the right one: "attached 0 images" reads as
        // a bug, and silence reads as a dead gesture.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let file = dirs.files.appendingPathComponent("twice.png")
        try Self.onePixelPNG.write(to: file)

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        var after: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(file.path))
            _ = await self.waitUntil { self.screenHas(target, "attached 1 image") }
            input.yield(Term.paste(file.path))
            _ = await self.waitUntil { self.screenHas(target, "already attached") }
            after = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(after.contains { $0.contains("already attached") }, "screen:\n\(after.joined(separator: "\n"))")
        #expect(after.contains { $0.contains("twice.png") }, "the original chip was destroyed by the re-drop")
        #expect(!after.contains { $0.contains(file.path) }, "the re-dropped path leaked into the prompt as text")
    }

    // MARK: A limit refuses one file, not the whole drop

    /// The images the gateway was asked to run with, newest turn first.
    private func imageParts(_ seen: SeenMessages) -> [ImageBlock] {
        seen.messages.flatMap { message -> [ImageBlock] in
            guard case .user(let user) = message else { return [] }
            return user.content.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
        }
    }

    @Test("Nine images attach eight and hand back only the ninth path")
    func countLimitKeepsWhatLoaded() async throws {
        // `ImageAttachmentLimits.default.maximumCount` is 8. Refusing the ninth is
        // correct; throwing away the other eight — which is what a bare
        // `guard result.isCompleteSuccess` did — is not, and the notice said
        // "skipped", which tells the user the rest were kept.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        var paths: [String] = []
        for index in 1...9 {
            let file = dirs.files.appendingPathComponent("n\(index).png")
            try Self.onePixelPNG.write(to: file)
            paths.append(file.path)
        }

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(paths.joined(separator: " ")))
            _ = await self.waitUntil { self.screenHas(target, "attached 8 images") }
            staged = self.oracle(target).screen
            input.yield([0x0d])
            _ = await self.waitUntil { self.screenHas(target, "got it") }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        let page = staged.joined(separator: "\n")
        // The notice names what HAPPENED: eight on, one off, and why.
        #expect(staged.contains { $0.contains("attached 8 images") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("n9.png not attached") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("at most 8 images per message") }, "screen:\n\(page)")
        // The chips are real — the eighth one is on the page (as a chip or under
        // the "+N more" overflow, which only exists because chips were staged).
        #expect(staged.contains { $0.contains("n1.png") || $0.contains("more") }, "no chips at all:\n\(page)")
        // Only the refused path came back as text, and it did come back.
        #expect(staged.contains { $0.contains(paths[8]) }, "the refused path was eaten:\n\(page)")
        #expect(!staged.contains { $0.contains(paths[0]) }, "an ATTACHED path was also typed in as text")
        // And eight images actually rode the message.
        #expect(imageParts(seen).count == 8, "the model saw \(imageParts(seen).count) images")
    }

    @Test("A file over the per-image limit is refused alone; the rest attach")
    func perImageByteLimitKeepsWhatLoaded() async throws {
        // 5 MiB per image. The oversized file is dropped FIRST so the small one
        // behind it is the thing that must survive the refusal.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let big = dirs.files.appendingPathComponent("big.png")
        var bytes = Self.onePixelPNG
        bytes.append(Data(repeating: 0x41, count: (6 << 20)))
        try bytes.write(to: big)
        let small = dirs.files.appendingPathComponent("small.png")
        try Self.onePixelPNG.write(to: small)

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste("\(big.path) \(small.path)"))
            _ = await self.waitUntil { self.screenHas(target, "attached 1 image") }
            staged = self.oracle(target).screen
            input.yield([0x0d])
            _ = await self.waitUntil { self.screenHas(target, "got it") }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        let page = staged.joined(separator: "\n")
        #expect(staged.contains { $0.contains("attached 1 image") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("over the 5.0 MB limit") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("small.png") }, "the small image was thrown away with the big one")
        #expect(staged.contains { $0.contains(big.path) }, "the refused path was eaten:\n\(page)")
        #expect(imageParts(seen).count == 1, "the model saw \(imageParts(seen).count) images")
    }

    @Test("A file that would blow the total budget is refused alone; the rest attach")
    func totalByteLimitKeepsWhatLoaded() async throws {
        // 10 MiB total. Three 4 MiB images: two fit, the third does not, and its
        // rejection is restated in the budget's terms rather than the per-image
        // one — which is exactly the case the ambiguous-reading rule must not
        // treat as a bad tokenization.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        var paths: [String] = []
        for index in 1...3 {
            let file = dirs.files.appendingPathComponent("b\(index).png")
            var bytes = Self.onePixelPNG
            bytes.append(Data(repeating: UInt8(0x40 + index), count: (4 << 20)))
            try bytes.write(to: file)
            paths.append(file.path)
        }

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(paths.joined(separator: " ")))
            _ = await self.waitUntil { self.screenHas(target, "attached 2 images") }
            staged = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        // Not sent: eight megabytes of base64 across the wire proves nothing this
        // test is about, and `countLimitKeepsWhatLoaded` already pins that the
        // staged chips reach the model.
        let page = staged.joined(separator: "\n")
        #expect(staged.contains { $0.contains("attached 2 images") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("b3.png not attached") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("total limit") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains(paths[2]) }, "the refused path was eaten:\n\(page)")
    }

    @Test("A .txt among two photos is handed back alone, and the photos attach")
    func aNonImageAmongImagesRefusesOnlyItself() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let first = dirs.files.appendingPathComponent("p1.png")
        let second = dirs.files.appendingPathComponent("p2.png")
        try Self.onePixelPNG.write(to: first)
        try Self.onePixelPNG.write(to: second)
        let notes = dirs.files.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        var staged: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste("\(first.path) \(second.path) \(notes.path)"))
            _ = await self.waitUntil { self.screenHas(target, "attached 2 images") }
            staged = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        let page = staged.joined(separator: "\n")
        #expect(staged.contains { $0.contains("attached 2 images") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("is not a supported image") }, "screen:\n\(page)")
        #expect(staged.contains { $0.contains("p1.png") })
        #expect(staged.contains { $0.contains(notes.path) }, "the .txt path was eaten:\n\(page)")
    }

    @Test("A path that is not there makes the whole reading ambiguous, and it all comes back")
    func aMissingPathKeepsTheDropAllOrNothing() async throws {
        // The other half of the rule, and the reason it is written in terms of the
        // REASON rather than "did anything load". `missing` is the signature of a
        // bad split — `/Users/x/my pic.png` read as two tokens leaves
        // `/Users/x/my`, which is not there — so a reading that produced one must
        // not be trusted enough to attach the files beside it and re-spell the
        // rest. Everything goes back exactly as pasted.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let real = dirs.files.appendingPathComponent("real.png")
        try Self.onePixelPNG.write(to: real)
        let ghost = dirs.files.appendingPathComponent("ghost.png").path
        let spelling = "\(real.path) \(ghost)"

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        var after: [String] = []
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Term.paste(spelling))
            _ = await self.waitUntil { self.screenHas(target, "no such file") }
            after = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        let page = after.joined(separator: "\n")
        #expect(after.contains { $0.contains("not attached") }, "screen:\n\(page)")
        #expect(after.contains { $0.contains("no such file") }, "screen:\n\(page)")
        // No chip: the chip row is the only thing on the page that carries 📎.
        #expect(!after.contains { $0.contains("📎") }, "an ambiguous reading attached something:\n\(page)")
        #expect(after.contains { $0.contains(real.path) }, "the paste did not come back whole:\n\(page)")
        #expect(after.contains { $0.contains(ghost) }, "the paste did not come back whole:\n\(page)")
    }

    // MARK: Enter while a drop is still being read

    @Test("A message never reaches the model claiming an image it does not carry")
    func sendingDuringADropNeverLosesTheImage() async throws {
        // The window: `handleSubmit` used to clear `pendingDrops`, which made the
        // loader's answer stale — so the drop's images were discarded, the message
        // went out with no image part in it, and the status line said "attached 1
        // image" anyway. A two-megabyte file makes the window wide enough to walk
        // into on the first try, which is how it was found on a real pty, without
        // making the Linux test server buffer an unnecessarily large request.
        //
        // The assertion is the INVARIANT rather than the race: whichever side wins,
        // no user message may reach the gateway without the picture it claims.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let file = dirs.files.appendingPathComponent("shot.png")
        var bytes = Self.onePixelPNG
        bytes.append(Data(repeating: 0x42, count: (2 << 20)))
        try bytes.write(to: file)

        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "got it")
        let (serverTask, port) = await startServer(server)
        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            // Paste, type and Enter in one go, with nothing awaited in between:
            // the read is `@concurrent` and has to hop off and back, so these
            // frames are handled while it is still going.
            input.yield(Term.paste(file.path))
            input.yield(Array("describe this".utf8))
            input.yield([0x0d])
            // Either the deferral held the message (the chip is now on the prompt)
            // or the send already went through with the image.
            _ = await self.waitUntil { self.screenHas(target, "shot.png") || !seen.messages.isEmpty }
            // Whatever happened above, Enter now sends anything still in the box.
            input.yield([0x0d])
            // Waited on the GATEWAY rather than on the reply appearing: what is
            // being tested is what crossed the wire, and painting a reply behind a
            // multi-megabyte base64 body is a different (slow) question.
            _ = await self.waitUntil { !seen.messages.isEmpty }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        let users = seen.messages.compactMap { message -> UserMessage? in
            if case .user(let user) = message { return user } else { return nil }
        }
        #expect(!users.isEmpty, "nothing was ever sent")
        for user in users {
            let hasImage = user.content.contains { if case .image = $0 { return true } else { return false } }
            #expect(hasImage, "a message reached the model with no image: \(user.content)")
        }
    }

    // MARK: Scrolling from the keyboard

    /// A reply tall enough that the transcript viewport cannot hold it.
    ///
    /// Three-digit row numbers so `SCROLLROW-030` cannot also match
    /// `SCROLLROW-3`, which is what makes "is this row on the page" a real test.
    private nonisolated static func tallReply(_ count: Int = 60) -> String {
        (1...count).map { index in
            let digits = String(index)
            return "SCROLLROW-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        }.joined(separator: "\n")
    }

    @Test("PgUp and PgDn scroll the transcript, and go on working with the mouse released")
    func keyboardScrollSurvivesAReleasedMouse() async throws {
        // F8 (and `--no-mouse`, which ships the same state permanently) hands the
        // pointer back to the terminal, and the wheel goes with it. Before this
        // there was no other way to move the transcript at all: `scrollOffset` was
        // written in exactly one place, inside `handleMouse`, behind
        // `guard mouseOwned` — while the status line went on advertising a scroll
        // that no gesture on the machine could perform.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, replyFor: { _ in Self.tallReply() })
        let (serverTask, port) = await startServer(server)
        var beforeScroll: [String] = []
        var afterPageUp: [String] = []
        var afterPageDown: [String] = []

        let target = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array("go".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "SCROLLROW-060") != nil }

            // Release the mouse FIRST, so nothing below can be doing its work
            // through the wheel path.
            input.yield(Term.f8)
            _ = await self.waitUntil { self.screenHas(target, "mouse: released") }
            beforeScroll = self.oracle(target).screen

            input.yield(Term.pageUp)
            _ = await self.waitUntil { self.locate(target, "SCROLLROW-030") != nil }
            afterPageUp = self.oracle(target).screen

            input.yield(Term.pageDown)
            _ = await self.waitUntil { self.locate(target, "SCROLLROW-060") != nil }
            afterPageDown = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(beforeScroll.contains { $0.contains("SCROLLROW-060") }, "the transcript was not at the tail")
        #expect(!beforeScroll.contains { $0.contains("SCROLLROW-030") }, "the viewport was not full")
        // The page turned, with the mouse released.
        #expect(afterPageUp.contains { $0.contains("SCROLLROW-030") }, "PgUp did not scroll:\n\(afterPageUp.joined(separator: "\n"))")
        #expect(!afterPageUp.contains { $0.contains("SCROLLROW-060") }, "PgUp did not move the viewport")
        // And the status line names the key rather than a gesture that is gone.
        #expect(afterPageUp.contains { $0.contains("PgDn to follow") }, "screen:\n\(afterPageUp.joined(separator: "\n"))")
        // PgDn comes back to the tail.
        #expect(afterPageDown.contains { $0.contains("SCROLLROW-060") }, "PgDn did not follow again")
        // The keys were never typed into the prompt.
        #expect(!screenHas(target, "[5~"))
        #expect(!screenHas(target, "[6~"))
    }

    @Test("Shift+↑ scrolls a row and does not steal prompt history")
    func shiftArrowScrollsWithoutEatingHistory() async throws {
        // The bare arrows recall history at the boundary rows and must keep doing
        // it. `ESC [ 1 ; 2 A` and `ESC [ A` are different byte sequences and the
        // decoder tells them apart — which is the whole reason this binding is
        // safe, and is checked here rather than assumed.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, replyFor: { _ in Self.tallReply() })
        let (serverTask, port) = await startServer(server)
        let sent = "HISTORYWORD"
        var afterShiftUp: [String] = []
        var afterPlainUp: [String] = []

        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array(sent.utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "SCROLLROW-060") != nil }

            // Four Shift+Ups: one row each, so the tail row leaves the viewport.
            for _ in 0..<4 { input.yield(Term.shiftUp) }
            _ = await self.waitUntil { self.screenHas(target, "↑ 4 rows") }
            afterShiftUp = self.oracle(target).screen

            // A bare Up on the same empty prompt still recalls history.
            input.yield(Term.up)
            _ = await self.waitUntil { self.promptRows(target).contains { $0.contains(sent) } }
            afterPlainUp = self.oracle(target).screen
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(afterShiftUp.contains { $0.contains("↑ 4 rows") }, "Shift+↑ did not scroll:\n\(afterShiftUp.joined(separator: "\n"))")
        // The prompt is untouched: no history recall, and no escape gibberish.
        let promptAfterShift = Array(afterShiftUp.suffix(3))
        #expect(!promptAfterShift.contains { $0.contains(sent) }, "Shift+↑ recalled history")
        #expect(!promptAfterShift.contains { $0.contains("[1;2A") }, "Shift+↑ was typed into the prompt")
        // The positive control: the bare arrow still does its job.
        #expect(Array(afterPlainUp.suffix(3)).contains { $0.contains(sent) }, "the bare ↑ stopped recalling history")
    }

    /// The prompt's rows — the bottom three at this size (a bordered single-line
    /// editor), which is where a history recall would land.
    private func promptRows(_ target: CaptureTarget) -> [String] {
        Array(oracle(target).screen.suffix(3))
    }

    // MARK: Gestures the decoder really produces

    @Test("An X10 release ends the drag, so a stray motion cannot extend it")
    func x10ReleaseEndsTheDrag() async throws {
        // A terminal that does not answer `?1006h` sends the pre-SGR encoding,
        // which has no release code: it reports button bits `3`, decoded as
        // `.release` with `.none` for the button. Without that arm the drag never
        // ends, and the next motion report — one already in the pipe, or a pointer
        // crossing the window — silently grows the selection past what the user
        // highlighted, so the clipboard holds more than the screen showed.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, replyFor: { _ in "X10ANCHOR TAILWORD" })
        let (serverTask, port) = await startServer(server)
        let clipboard = RecordingClipboard()

        _ = await runClient(port: port, clipboard: clipboard, lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array("go".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "X10ANCHOR TAILWORD") != nil }
            guard let spot = self.locate(target, "X10ANCHOR") else { return }

            input.yield(Term.x10Press(column: spot.column, row: spot.row))
            input.yield(Term.x10Drag(column: spot.column + 9, row: spot.row))
            input.yield(Term.x10Release(column: spot.column + 9, row: spot.row))
            _ = await self.waitUntil {
                self.oracle(target).cell(col: spot.column, row: spot.row)?.style.inverse == true
            }
            // A motion report AFTER the release. The controller documents that a
            // stray one must not resurrect a finished selection — which it can
            // only honour if the release was seen at all.
            input.yield(Term.x10Drag(column: spot.column + 18, row: spot.row))
            input.yield(Term.x10RightPress(column: spot.column, row: spot.row))
            _ = await self.waitUntil { !clipboard.recorded.isEmpty }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(clipboard.recorded == ["X10ANCHOR"], "the clipboard got \(clipboard.recorded)")
    }

    @Test("A press is routed to the pane it lands in, not to the transcript")
    func aPressIsRoutedToItsOwnPane() async throws {
        // The pane window is what keeps a drag inside the column it started in.
        // Routed wrongly, a sidebar press is clamped into the transcript's columns
        // and collapses to nothing — so the gesture copies neither pane.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, reply: "ack")
        let (serverTask, port) = await startServer(server)
        let clipboard = RecordingClipboard()

        _ = await runClient(port: port, clipboard: clipboard, lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            // The sidebar's own header row, which lives in columns 0..<17 of row 0
            // — a region the transcript never occupies.
            input.yield(Term.press(column: 0, row: 0))
            input.yield(Term.drag(column: 17, row: 0))
            input.yield(Term.release(column: 17, row: 0))
            _ = await self.waitUntil { self.oracle(target).cell(col: 0, row: 0)?.style.inverse == true }
            input.yield(Term.rightPress(column: 0, row: 0))
            _ = await self.waitUntil { !clipboard.recorded.isEmpty }
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(clipboard.recorded == ["Sessions (n: new)"], "the clipboard got \(clipboard.recorded)")
    }

    @Test("A scroll restarts the click run, so the next click is not a double-click")
    func scrollingRestartsTheClickRun() async throws {
        // A click in the same cell before and after a scroll is a click on two
        // different pieces of text; expanding the second one to a word would take
        // a word the user never pointed at.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let seen = SeenMessages()
        let server = makeServer(dirs, seen: seen, replyFor: { _ in "CLICKRUN alpha SECONDWORD" })
        let (serverTask, port) = await startServer(server)
        var doubleClickHighlighted = false
        var afterScrollHighlighted = true

        _ = await runClient(port: port, clipboard: RecordingClipboard(), lifecycle: RecordingLifecycle()) { input, target in
            await self.settle(target)
            input.yield(Array("go".utf8))
            input.yield([0x0d])
            _ = await self.waitUntil { self.locate(target, "SECONDWORD") != nil }
            guard let control = self.locate(target, "CLICKRUN"),
                  let scrolled = self.locate(target, "SECONDWORD") else { return }

            // The positive control: two presses in the same cell DO take the word,
            // which is what makes the negative below mean anything.
            input.yield(Term.press(column: control.column, row: control.row))
            input.yield(Term.press(column: control.column, row: control.row))
            _ = await self.waitUntil { self.transcriptHasHighlight(target) }
            doubleClickHighlighted = self.transcriptHasHighlight(target)

            input.yield(Term.escape)
            _ = await self.waitUntil { !self.transcriptHasHighlight(target) }

            // The same two presses with a scroll between them — on a DIFFERENT
            // cell, because `Escape` clears the selection and deliberately does
            // not touch the click run, so re-using the control's cell would carry
            // its count into this half and prove nothing. The wheel-down at the
            // tail moves no rows, so the only difference is the click run itself.
            input.yield(Term.press(column: scrolled.column, row: scrolled.row))
            input.yield(Term.wheelDown(column: scrolled.column, row: scrolled.row))
            input.yield(Term.press(column: scrolled.column, row: scrolled.row))
            // A keystroke after the reports, waited on: frames are handled in
            // order, so seeing this proves the presses were handled and painted.
            input.yield(Array("ZQX".utf8))
            _ = await self.waitUntil { self.screenHas(target, "ZQX") }
            afterScrollHighlighted = self.transcriptHasHighlight(target)
        }
        serverTask.cancel()
        _ = try? await serverTask.value

        #expect(doubleClickHighlighted, "a double-click did not take the word — the control failed")
        #expect(!afterScrollHighlighted, "a click after a scroll still counted as a double-click")
    }
}
