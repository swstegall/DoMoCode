// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The Phase 4 EXIT CRITERION, exercised for real and headlessly: the actual
// `InteractiveMode` REPL is driven through its injected seams — a scripted
// `AsyncStream` of keystrokes in, a capturing `RenderTarget` out — against a
// loopback OpenAI-compatible gateway. Nothing here is stubbed: the real event
// sink, key dispatch, `@` completion, and Escape-to-abort all run, and the frames
// are replayed into a SwiftTerm oracle so the assertions are on the cell grid a
// terminal would actually show, not on the bytes the renderer emitted.
//
// Three things are pinned, matching the exit criterion:
//   1. A submitted prompt streams the assistant's reply into the transcript.
//   2. Escape while the agent runs aborts the run (a clean, interrupted transcript).
//   3. `@` opens a file-completion popup listing a real temp directory.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import DoMoCLI
import DoMoCore
import DoMoLLM
import DoMoTermIO
import DoMoTUI
import Foundation
import Testing

#if canImport(Glibc)
private let steerableStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let steerableStreamSocketType = SOCK_STREAM
#endif

// MARK: - Test doubles

/// A `RenderTarget` that accumulates every frame the driver writes, so a test can
/// replay the whole byte stream into a fresh VT100 oracle and assert the resulting
/// screen. Fixed size — no resize is scripted in these tests.
@MainActor
final class CaptureTarget: RenderTarget {
    var columns: Int
    var rows: Int
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    func write(_ bytes: String) {
        buffer += bytes
    }

    /// Everything written so far, without clearing — polled repeatedly while the
    /// session is live.
    func snapshot() -> String { buffer }
}

/// A ``TerminalLifecycleControl`` that does nothing: there is no real tty to put
/// into raw mode headlessly, and the driver only needs `enter`/`stop` to succeed.
final class NoopLifecycle: TerminalLifecycleControl {
    func enter() throws(DoMoError) {}
    func stop() {}
}

// MARK: - Helpers

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

/// Poll `condition` on the main actor until it holds or the deadline passes,
/// yielding the actor between checks so the driver's concurrent input/agent tasks
/// run. Returns whether the condition ultimately held.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(15),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// True if any transcript (scrollback + viewport) row produced by replaying the
/// captured bytes contains `needle`.
@MainActor
private func screenContains(_ target: CaptureTarget, rows: Int, cols: Int, _ needle: String) -> Bool {
    let oracle = ScreenOracle(rows: rows, cols: cols)
    oracle.feed(target.snapshot())
    if oracle.transcript.contains(where: { $0.contains(needle) }) { return true }
    return oracle.screen.contains { $0.contains(needle) }
}

/// A throwaway working tree plus an (empty) session directory, isolated from the
/// developer's real `~/.domocode`.
private struct TempTree {
    let root: URL
    let work: URL
    let sessions: URL

    init() throws {
        let manager = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-repl-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for directory in [work, sessions] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeFile(_ name: String, _ contents: String) throws {
        try contents.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct InteractiveModeEndToEndTests {

    /// A single-turn SSE reply that streams one plain-text answer, then stops.
    static let singleTextTurn = #"""
        data: {"id":"c1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello from the agent."},"finish_reason":null}]}

        data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":5,"total_tokens":10}}

        data: [DONE]


        """#

    /// EXIT CRITERION 1 — a submitted prompt streams the assistant reply into the
    /// transcript, visible on the rendered grid.
    @Test
    func submittedPromptStreamsAssistantTextIntoTranscript() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("list the files"))
        inputCont.yield(bytes("\r"))

        let appeared = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(appeared, "assistant text never streamed into the transcript")
        #expect(gateway.requestCount == 1)

        inputCont.finish()
        try await runTask.value
    }

    /// EXIT CRITERION 3 — typing `@` opens a completion popup listing a real temp
    /// directory's contents.
    @Test
    func atSignOpensFileCompletionPopup() async throws {
        let tree = try TempTree()
        defer { tree.cleanUp() }
        try tree.writeFile("target_marker.txt", "hi\n")

        // No request is made in this test (nothing is submitted), so the base URL
        // is a dead port; `make` still needs a well-formed client configuration.
        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: "http://127.0.0.1:1/v1", apiKey: nil),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // Trigger file completion at a fresh `@` token.
        inputCont.yield(bytes("@"))

        let appeared = await waitUntil { screenContains(target, rows: rows, cols: cols, "target_marker.txt") }
        #expect(appeared, "the @ completion popup never listed the temp directory entry")

        inputCont.finish()
        try await runTask.value
    }

    /// EXIT CRITERION 2 — Escape while the agent is running aborts the run: the
    /// partial reply is shown, then an interrupted marker appears without waiting
    /// for the (still-open) upstream stream to finish.
    @Test
    func escapeAbortsARunningAgent() async throws {
        let gateway = try HangingGateway(firstDelta: "partial-answer")
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("do something long"))
        inputCont.yield(bytes("\r"))

        // The run is now in-flight and has streamed its first delta.
        let started = await waitUntil { screenContains(target, rows: rows, cols: cols, "partial-answer") }
        #expect(started, "the run never began streaming, so there is nothing to abort")

        // Escape: a bare ESC byte, held by the framer's disambiguation window then
        // flushed to the focused component — which aborts the in-flight run.
        inputCont.yield(bytes("\u{1b}"))

        let interrupted = await waitUntil { screenContains(target, rows: rows, cols: cols, "interrupted") }
        #expect(interrupted, "Escape did not abort the running agent")

        inputCont.finish()
        try await runTask.value
    }

    /// REGRESSION — input EOF (equally, a quit binding) while the agent is still
    /// running must abort the in-flight run so the driver reaches its terminal
    /// restore promptly. Before the fix, the unstructured run task outlived the
    /// cancelled agent loop and `run` blocked until the turn finished on its own
    /// (here, the hanging gateway's multi-second server timeout) — the terminal
    /// staying in raw mode the whole time.
    @Test
    func eofWhileRunningAbortsInFlightRunPromptly() async throws {
        let gateway = try HangingGateway(firstDelta: "partial-answer")
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let done = RunDoneFlag()
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
            done.markDone()
        }

        inputCont.yield(bytes("do something long"))
        inputCont.yield(bytes("\r"))

        let started = await waitUntil { screenContains(target, rows: rows, cols: cols, "partial-answer") }
        #expect(started, "the run never began streaming")

        // EOF while the run is in-flight. The gateway holds its socket open for
        // ~20s, so if the run were not aborted `run` would not return until then.
        inputCont.finish()
        let returnedPromptly = await waitUntil(timeout: .seconds(6)) { done.isDone }
        #expect(returnedPromptly, "run did not return promptly after EOF — the in-flight run was not aborted")

        _ = try? await runTask.value
    }

    /// A second single-turn SSE reply with a distinct marker, so a two-run test can
    /// tell the runs apart on the rendered grid.
    static let secondTextTurn = #"""
        data: {"id":"c2","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Second-answer-here."},"finish_reason":null}]}

        data: {"id":"c2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"c2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":5,"total_tokens":10}}

        data: [DONE]


        """#

    /// TRUE MID-TURN STEERING — a line typed while the agent is running is injected
    /// into the CURRENT run's next turn, not deferred to a fresh run.
    ///
    /// The gateway holds the first (tool-call) turn open, so the steering line is
    /// provably delivered before the loop reaches its turn boundary; on release the
    /// same run takes a second turn whose request carries the steered text. Two
    /// requests (not three) plus that text in the second body is the proof: the old
    /// defer-to-next-run path would have made the tool-result continuation carry no
    /// steering and pushed the steered line into a separate later run.
    @Test
    func midRunSubmissionSteersIntoTheRunningAgent() async throws {
        let gateway = try SteerableGateway(firstTurnText: "checking-now", secondTurnText: "all-done")
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        try tree.writeFile("marker.txt", "hi\n")

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // Start the run; the first turn streams its text, then the gateway holds it.
        inputCont.yield(bytes("kick off the work"))
        inputCont.yield(bytes("\r"))
        let started = await waitUntil { screenContains(target, rows: rows, cols: cols, "checking-now") }
        #expect(started, "the first turn never began streaming, so there is nothing to steer")

        // Type a line WHILE the agent runs. It must land in the steering box, not a
        // deferred queue. Wait for its echo before releasing, so it is provably in
        // the box when the loop next polls for steering.
        inputCont.yield(bytes("run-the-tests-too"))
        inputCont.yield(bytes("\r"))
        let echoed = await waitUntil { screenContains(target, rows: rows, cols: cols, "run-the-tests-too") }
        #expect(echoed, "the mid-run submission was never accepted")

        // Release the first turn → the same run dispatches the tool and takes a
        // second turn that must carry the steered line.
        gateway.release()
        let finished = await waitUntil { screenContains(target, rows: rows, cols: cols, "all-done") }
        #expect(finished, "the run never produced its steered second turn")

        // Two turns of ONE run — not a third request for a deferred new run.
        #expect(gateway.requestCount == 2)
        let secondBody = gateway.requests[1].body
        #expect(secondBody.contains("run-the-tests-too"), "steer missing from turn 2 request: \(secondBody)")

        inputCont.finish()
        try await runTask.value
    }

    /// An idle submission still starts a fresh run: two prompts entered while the
    /// agent is idle drive two independent runs (two gateway requests), proving the
    /// steering rework did not fold idle submits into the current run.
    @Test
    func idleSubmissionsEachStartAFreshRun() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn, Self.secondTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // First idle submission → first run.
        inputCont.yield(bytes("first prompt"))
        inputCont.yield(bytes("\r"))
        // Wait for the reply AND the return to the idle status line, so the run has
        // fully settled before the next submission (else it would be steering).
        let firstSettled = await waitUntil {
            screenContains(target, rows: rows, cols: cols, "Hello from the agent")
                && screenContains(target, rows: rows, cols: cols, "enter to send")
        }
        #expect(firstSettled, "the first idle run never completed")

        // Second idle submission → a fresh, second run.
        inputCont.yield(bytes("second prompt"))
        inputCont.yield(bytes("\r"))
        let secondArrived = await waitUntil { screenContains(target, rows: rows, cols: cols, "Second-answer-here") }
        #expect(secondArrived, "the second idle submission did not start a fresh run")

        #expect(gateway.requestCount == 2)

        inputCont.finish()
        try await runTask.value
    }
}

/// A tiny thread-safe done flag: the run task marks it on the main actor, the test
/// polls it. `@unchecked Sendable` because the `NSLock` provides the synchronization
/// the compiler cannot see.
final class RunDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func markDone() { lock.lock(); done = true; lock.unlock() }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

// MARK: - Steerable gateway

/// A loopback OpenAI-compatible gateway that opens a deterministic mid-run window.
///
/// The mid-run steering test needs the agent to be *provably* in flight — with the
/// steered keystrokes already delivered — before the first turn reaches its turn
/// boundary and polls for steering. So the first turn's SSE is streamed in two
/// halves: an initial text delta the test can watch for, then a pause on
/// ``release()`` before the tool-call tail that ends the turn. While paused the run
/// is genuinely blocked in-flight, so the test can submit the steering line and
/// only then release the turn — making the injection race-free rather than timed.
///
/// The tool call in the first turn forces a second turn *within the same run*, so
/// true steering (the steer rides into that second turn's request) is cleanly
/// distinguishable from deferral (which would need a separate later run). Raw POSIX
/// sockets, the same rationale as ``MockGateway`` — which is why `DoMoCLITests`
/// builds without `.strictMemorySafety()`.
final class SteerableGateway: @unchecked Sendable {
    let port: UInt16

    private let listenFD: Int32
    private let firstTurnText: String
    private let secondTurnText: String
    private let lock = NSLock()
    private var stopped = false
    private var released = false
    private var chatCount = 0
    private var recorded: [RecordedRequest] = []
    private var thread: Thread?

    /// - Parameters:
    ///   - firstTurnText: the visible text delta streamed before the first turn
    ///     pauses on ``release()``.
    ///   - secondTurnText: the assistant text the second turn streams to completion.
    init(firstTurnText: String, secondTurnText: String) throws {
        self.firstTurnText = firstTurnText
        self.secondTurnText = secondTurnText

        let fd = socket(AF_INET, steerableStreamSocketType, 0)
        guard fd >= 0 else { throw MockGatewayError("socket() failed: \(errno)") }

        var yes: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)

        let bindResult = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw MockGatewayError("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw MockGatewayError("listen() failed: \(errno)")
        }

        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = unsafe withUnsafeMutablePointer(to: &bound) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe getsockname(fd, generic, &boundSize)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw MockGatewayError("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// How many `chat/completions` requests were answered.
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chatCount
    }

    /// The `chat/completions` requests seen, in arrival order.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Unblock the first turn so it can finish and the run can reach its turn
    /// boundary. Called by the test once the steering line has been delivered.
    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func start() {
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "steerable-gateway"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }

            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handleConnection(client)
            close(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(fd) else { return }

        if request.method == "GET", request.path.contains("models") {
            writeAll(
                fd,
                Self.httpResponse(
                    body: Array(#"{"object":"list","data":[{"id":"mock-model","object":"model","owned_by":"openai"}]}"#.utf8)
                )
            )
            return
        }

        lock.lock()
        recorded.append(request)
        let index = chatCount
        chatCount += 1
        lock.unlock()

        if index == 0 {
            firstTurn(fd)
        } else {
            writeAll(fd, Self.sseHeaders(callID: "steer-\(index)") + Array(Self.finalTurnBody(text: secondTurnText).utf8))
        }
    }

    /// Stream the first turn's visible delta, pause until ``release()``, then send
    /// the tool-call tail that ends the turn.
    private func firstTurn(_ fd: Int32) {
        writeAll(fd, Self.sseHeaders(callID: "steer-0"))
        let head = """
            data: {"id":"s1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\(firstTurnText)"},"finish_reason":null}]}


            """
        writeAll(fd, Array(head.utf8))

        // Hold the turn open until the test releases it — the deterministic window
        // in which the steering line is delivered. A generous spin backstop keeps a
        // forgotten release from wedging the suite.
        let deadline = Date().addingTimeInterval(15)
        while true {
            lock.lock()
            let go = released || stopped
            lock.unlock()
            if go || Date() >= deadline { break }
            usleep(5000)
        }

        let tail = #"""
            data: {"id":"s1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_ls","type":"function","function":{"name":"ls","arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

            data: {"id":"s1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: {"id":"s1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

            data: [DONE]


            """#
        writeAll(fd, Array(tail.utf8))
    }

    private static func finalTurnBody(text: String) -> String {
        """
        data: {"id":"s2","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\(text)"},"finish_reason":null}]}

        data: {"id":"s2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"s2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":5,"total_tokens":25}}

        data: [DONE]


        """
    }

    // MARK: Request reading (mirrors MockGateway's minimal HTTP parse)

    private func readRequest(_ fd: Int32) -> RecordedRequest? {
        var buffer: [UInt8] = []
        var headerEnd: Int?
        while headerEnd == nil {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return nil }
            buffer.append(contentsOf: chunk)
            headerEnd = Self.indexOfDoubleCRLF(buffer)
            if buffer.count > 1 << 20 { return nil }
        }
        guard let headerEnd else { return nil }

        let headerText = String(decoding: buffer[..<headerEnd], as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        var contentLength = 0
        var expectsContinue = false
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("expect:"), lower.contains("100-continue") {
                expectsContinue = true
            }
        }
        if expectsContinue {
            writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        var bodyBytes = Array(buffer[(headerEnd + 4)...])
        while bodyBytes.count < contentLength {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            bodyBytes.append(contentsOf: chunk)
        }
        return RecordedRequest(method: method, path: path, body: String(decoding: bodyBytes, as: UTF8.self))
    }

    private func readChunk(_ fd: Int32) -> [UInt8]? {
        var scratch = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = unsafe scratch.withUnsafeMutableBytes { raw in
                unsafe recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return Array(scratch[..<count])
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        unsafe bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let sent = unsafe send(fd, base + offset, bytes.count - offset, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += sent
            }
        }
    }

    private static func sseHeaders(callID: String) -> [UInt8] {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "x-litellm-call-id: \(callID)",
            "x-litellm-model-id: mock-deployment",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(headers.utf8)
    }

    private static func httpResponse(body: [UInt8]) -> [UInt8] {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(headers.utf8) + body
    }

    private static func indexOfDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i
        }
        return nil
    }
}
