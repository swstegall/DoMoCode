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
        }

        #expect(clipboard.recorded == [needle], "the clipboard got \(clipboard.recorded)")
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

        #expect(after.contains { $0.contains("attachments too large") }, "no notice:\n\(after.joined(separator: "\n"))")
        #expect(after.contains { $0.contains("The server refused the message as too large") })
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
}
