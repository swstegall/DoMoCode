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
import DoMoTermGraphics
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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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

    /// PHASE 5.5 — a submitted line that `@`-mentions an image file attaches it: the
    /// gateway request carries the bytes as an OpenAI `image_url` content part. This
    /// exercises the interactive-only path — token extraction, the sandboxed read,
    /// and media-type sniffing — that the print-mode `--image` test cannot.
    @Test
    func atMentionedImageIsAttachedToTheTurn() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        // A 16-byte PNG the sniffer accepts: signature + IHDR length 13 + "IHDR".
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        ])
        try png.write(to: tree.work.appendingPathComponent("shot.png"))

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 60, rows = 20
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // Trailing non-`@` text leaves the cursor outside the mention token, so no
        // completion popup is open when Enter submits the line.
        inputCont.yield(bytes("@shot.png what is this"))
        inputCont.yield(bytes("\r"))

        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the turn never completed")
        #expect(gateway.requestCount == 1)

        let json = try JSONValue(parsing: Data(gateway.requests[0].body.utf8))
        let content = json["messages"]?[1]?["content"]
        #expect(content?[1]?["type"]?.stringValue == "image_url", "body: \(gateway.requests[0].body)")
        #expect(
            content?[1]?["image_url"]?["url"]?.stringValue
                == "data:image/png;base64,\(png.base64EncodedString())",
            "body: \(gateway.requests[0].body)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// Turn 1: the assistant calls `read` on a PNG, then finishes with `tool_calls`
    /// so the loop dispatches the read (which returns the image block) before turn 2.
    static let readImageToolTurn = #"""
        data: {"id":"r1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_read_1","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"r1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \"shot.png\"}"}}]},"finish_reason":null}]}

        data: {"id":"r1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"r1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    /// Turn 2: a plain-text final answer with a distinct marker.
    static let describedImageTurn = #"""
        data: {"id":"r2","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"described-the-image."},"finish_reason":null}]}

        data: {"id":"r2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"r2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":5,"total_tokens":65}}

        data: [DONE]


        """#

    /// PHASE 7.5d — a tool that returns an image adds an image row to the inline
    /// transcript. The captured target is not a graphics tty (the test process's
    /// stdout is a pipe), so capability detection reports no image protocol and the
    /// row degrades to a `[Image: …]` text marker — which is exactly what proves the
    /// `endTool → ImageBlockView` wiring runs: the image survived the `RegistryTool`
    /// adapter into `AgentToolResult.images` and was rendered as its own transcript
    /// row rather than dropped.
    @Test
    func toolReturnedImageAddsAnImageRowToTheTranscript() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.readImageToolTurn, Self.describedImageTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        // A 24-byte PNG the sniffer accepts AND the dimension parser reads as 40×20,
        // so the fallback marker carries the size.
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x14,
        ])
        try png.write(to: tree.work.appendingPathComponent("shot.png"))

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 60, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        // Force "no image protocol" so the assertion is hermetic: real capability
        // detection reads the test process's own env/stdout (which may carry a
        // graphics terminal's markers), and an actual escape would be swallowed by
        // the VT100 oracle rather than shown as text. With no protocol the image row
        // is the `[Image: …]` fallback, which the oracle renders and we can assert.
        let runTask = Task { @MainActor in
            try await mode.run(
                target: target, input: input, resize: resize, lifecycle: NoopLifecycle(),
                imageCapabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false)
            )
        }

        inputCont.yield(bytes("read shot.png and describe it"))
        inputCont.yield(bytes("\r"))

        // The run reaches its final turn, and the image row is on the grid — the
        // capitalized `[Image:` marker is distinct from the read tool's own text.
        let described = await waitUntil { screenContains(target, rows: rows, cols: cols, "described-the-image") }
        #expect(described, "the two-turn read-image run never completed")
        let imageRow = await waitUntil { screenContains(target, rows: rows, cols: cols, "[Image:") }
        #expect(imageRow, "the tool-returned image did not become a transcript row")
        #expect(gateway.requestCount == 2)

        inputCont.finish()
        try await runTask.value
    }

    /// Turn 1: the assistant calls `bash echo permitted` — under the Phase-8 baseline
    /// this needs interactive approval.
    static let bashApprovalTurn = #"""
        data: {"id":"b1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_bash_1","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"b1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\": \"echo permitted\"}"}}]},"finish_reason":null}]}

        data: {"id":"b1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"b1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    /// The content of the first tool-role message in a chat-completions body — the
    /// tool result fed back to the model.
    private static func toolResult(_ body: String) -> String {
        guard let json = try? JSONValue(parsing: body), let messages = json["messages"]?.arrayValue else { return "" }
        for message in messages where message["role"]?.stringValue == "tool" {
            return message["content"]?.stringValue ?? ""
        }
        return ""
    }

    /// PHASE 8 — a bash tool needing approval raises the modal; Enter ("Allow once")
    /// runs it. The gate suspends the tool on a continuation and the render loop keeps
    /// going (the modal is visible), then the keypress resumes it.
    @Test
    func permissionModalAllowOnceRunsTheTool() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.bashApprovalTurn, Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }
        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 70, rows = 22
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("run echo"))
        inputCont.yield(bytes("\r"))
        let modalUp = await waitUntil { screenContains(target, rows: rows, cols: cols, "Allow bash") }
        #expect(modalUp, "the approval modal never appeared")

        inputCont.yield(bytes("\r"))   // confirm the highlighted "Allow once"
        let finished = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(finished, "the run never completed after approval")
        #expect(gateway.requestCount == 2)
        #expect(Self.toolResult(gateway.requests[1].body).contains("permitted"), "the echo should have run")

        inputCont.finish()
        try await runTask.value
    }

    /// PHASE 8 — Escape on the modal rejects the tool; the model gets the refusal and
    /// the run still completes (no leaked tool fiber).
    @Test
    func permissionModalEscapeRejectsTheTool() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.bashApprovalTurn, Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }
        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 70, rows = 22
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("run echo"))
        inputCont.yield(bytes("\r"))
        let modalUp = await waitUntil { screenContains(target, rows: rows, cols: cols, "Allow bash") }
        #expect(modalUp, "the approval modal never appeared")

        // Escape SELECTS the Reject row; Enter confirms it. Escape deliberately no
        // longer answers on its own: a terminal splits an arrow key into `ESC` and
        // `[B`, and a late lone `ESC` is indistinguishable from a keypress, so
        // answering on it let a cursor keystroke silently reject a tool call.
        inputCont.yield(bytes("\u{1b}"))
        // Wait for the MARKER to move onto Reject, not merely for the modal to still
        // be there. A lone ESC is held for the disambiguation window, so sending Enter
        // before that window closes would coalesce the two into one `ESC \r` sequence
        // and neither key would be delivered.
        let rejectSelected = await waitUntil { screenContains(target, rows: rows, cols: cols, "→ Reject") }
        #expect(rejectSelected, "Escape must move the selection onto Reject without answering")
        inputCont.yield(bytes("\r"))
        let finished = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(finished, "the run never completed after rejection")
        #expect(gateway.requestCount == 2)
        #expect(Self.toolResult(gateway.requests[1].body).contains("rejected"), "the tool should have been refused")

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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
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

    // MARK: A run that stops without finishing

    /// One assistant turn that calls `ls .` and finishes with `tool_calls`, so the
    /// loop dispatches the (auto-allowed, read-only) call and asks for another turn.
    static let lsToolTurn = #"""
        data: {"id":"l1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_ls_1","type":"function","function":{"name":"ls","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"l1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

        data: {"id":"l1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]


        """#

    /// A run cut off by `--max-turns` says so, in the transcript.
    ///
    /// This is the inline half of the reported defect: the REPL reacted to
    /// `.aborted` and to nothing else, so a run that hit the turn budget produced
    /// NO output at all — the session simply went quiet mid-task, which reads
    /// exactly like the model deciding it was finished.
    @Test
    func inlineReplSaysWhyARunStoppedAtTheTurnLimit() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.lsToolTurn, Self.lsToolTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        try tree.writeFile("hello.txt", "hi\n")

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path,
            maxTurns: 1
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("list the files"))
        inputCont.yield(bytes("\r"))

        let explained = await waitUntil { screenContains(target, rows: rows, cols: cols, "--max-turns limit") }
        #expect(explained, "the REPL went idle without saying the turn limit stopped the run")
        // The budget really did stop it — one turn, one request.
        #expect(gateway.requestCount == 1)

        inputCont.finish()
        try await runTask.value
    }

    // MARK: Drag and drop

    /// A 16-byte PNG the sniffer accepts: signature + IHDR length 13 + "IHDR".
    static let tinyPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])

    /// Wrap `text` in the bracketed-paste guards a terminal puts around a drop.
    static func bracketedPaste(_ text: String) -> [UInt8] {
        bytes("\u{1b}[200~" + text + "\u{1b}[201~")
    }

    /// Dragging an image onto the inline REPL attaches it instead of typing its
    /// path.
    ///
    /// The file deliberately lives OUTSIDE the session's working directory: a
    /// dropped screenshot from `~/Desktop` is trusted operator input, exactly like
    /// `--image`, and resolving it through the tool sandbox would refuse the
    /// commonest case there is.
    @Test
    func inlineReplAttachesADroppedImage() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the drop was not staged as an attachment")

        inputCont.yield(bytes("what is this"))
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the turn never completed")

        // The bytes really rode the message, and the path was NOT typed into it.
        let json = try JSONValue(parsing: Data(gateway.requests[0].body.utf8))
        let content = json["messages"]?[1]?["content"]
        #expect(content?[0]?["text"]?.stringValue == "what is this", "body: \(gateway.requests[0].body)")
        #expect(content?[1]?["type"]?.stringValue == "image_url", "body: \(gateway.requests[0].body)")
        #expect(
            content?[1]?["image_url"]?["url"]?.stringValue
                == "data:image/png;base64,\(Self.tinyPNG.base64EncodedString())",
            "body: \(gateway.requests[0].body)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// A paste that is not path-shaped is ordinary text, untouched.
    ///
    /// The whole safety property of the drop parser: prose that merely MENTIONS a
    /// path must reach the prompt verbatim, or pasting a paragraph would start
    /// eating words.
    @Test
    func inlineReplLeavesOrdinaryPastedProseAlone() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste("check /tmp/absent.png and tell me"))
        let typed = await waitUntil { screenContains(target, rows: rows, cols: cols, "check /tmp/absent.png and tell me") }
        #expect(typed, "a non-drop paste did not reach the prompt")
        #expect(!screenContains(target, rows: rows, cols: cols, "attached"))

        inputCont.finish()
        try await runTask.value
    }

    /// A dropped file that is not an image is refused — and its path goes back into
    /// the prompt as text, so the gesture never silently loses what the user meant.
    ///
    /// The restored text is asserted through the SUBMITTED MESSAGE, not by looking
    /// for the file name on the grid. The rejection notice already contains the
    /// file's display name (`notes.txt is not a supported image …`), so a screen
    /// assertion on `notes.txt` is satisfied by the notice alone and stays green
    /// with the entire restore block — and with it the only scrubber on this
    /// attacker-influenced paste path — deleted. The request body carries the FULL
    /// path plus the words typed before the drop, neither of which the notice has,
    /// and it cannot be produced at all if the editor was left empty: `handleSubmit`
    /// returns early on an empty line with nothing staged, so no request is made.
    @Test
    func inlineReplRestoresARefusedDropAsText() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        // In its own subdirectory, so the full path contains a component that the
        // rejection message provably does not.
        let dropZone = tree.root.appendingPathComponent("dropzone", isDirectory: true)
        try FileManager.default.createDirectory(at: dropZone, withIntermediateDirectories: true)
        let dropped = dropZone.appendingPathComponent("notes.txt")
        try "not an image\n".write(to: dropped, atomically: true, encoding: .utf8)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 120, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // Words typed BEFORE the drop must survive it; the path is appended after.
        inputCont.yield(bytes("please look at"))
        inputCont.yield(Self.bracketedPaste(dropped.path))
        let explained = await waitUntil {
            screenContains(target, rows: rows, cols: cols, "notes.txt is not a supported image")
        }
        #expect(explained, "a refused drop said nothing")

        // Submit what the editor now holds. If the restore block were gone the
        // editor would hold only "please look at" — and if the typed words were
        // clobbered it would hold only the path — so the body pins both halves.
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the refused drop left nothing submittable in the prompt")
        #expect(gateway.requestCount == 1)

        let submitted = try Self.firstUserText(gateway.requests[0].body)
        #expect(submitted.contains("please look at"), "the typed words were eaten: \(submitted)")
        #expect(submitted.contains(dropped.path), "the refused drop's text was eaten: \(submitted)")

        inputCont.finish()
        try await runTask.value
    }

    /// The text of the first user message in a chat-completions body, whichever
    /// wire shape it took: a bare string when the turn carried no attachments, or
    /// the first `text` content part when it did.
    static func firstUserText(_ body: String) throws -> String {
        let json = try JSONValue(parsing: Data(body.utf8))
        guard let messages = json["messages"]?.arrayValue else { return "" }
        for message in messages where message["role"]?.stringValue == "user" {
            if let text = message["content"]?.stringValue { return text }
            if let text = message["content"]?[0]?["text"]?.stringValue { return text }
        }
        return ""
    }

    /// Every `image_url` data URL carried by a chat-completions body, in message
    /// order. Parsed rather than substring-matched: Foundation escapes `/` in JSON,
    /// so `body.contains("data:image/png…")` is a false negative waiting to happen.
    static func imageDataURLs(_ body: String) throws -> [String] {
        let json = try JSONValue(parsing: Data(body.utf8))
        guard let messages = json["messages"]?.arrayValue else { return [] }
        var urls: [String] = []
        for message in messages {
            guard let parts = message["content"]?.arrayValue else { continue }
            for part in parts where part["type"]?.stringValue == "image_url" {
                if let url = part["image_url"]?["url"]?.stringValue { urls.append(url) }
            }
        }
        return urls
    }

    /// The data URL the 16-byte test PNG must appear as on the wire.
    static var tinyPNGDataURL: String {
        "data:image/png;base64,\(Self.tinyPNG.base64EncodedString())"
    }

    /// A drop staged WHILE a turn is in flight rides the steering message into the
    /// current run's next turn.
    ///
    /// A mid-run submit does not go through the submissions stream — it is appended
    /// to the ``SteeringBox`` as a `Message`, and `Message.user(_:)` builds a
    /// TEXT-ONLY message. Using it there is exactly how a mid-run drop's bytes used
    /// to vanish, and nothing else in the suite touches that construction: the
    /// existing drop test only covers the idle path. The gateway holds turn 1 open
    /// so the drop and the submit are provably in the box before the loop polls,
    /// then turn 2's request body has to carry the image.
    @Test
    func aDropStagedWhileARunIsInFlightRidesTheSteeringMessage() async throws {
        let gateway = try SteerableGateway(firstTurnText: "checking-now", secondTurnText: "all-done")
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        try tree.writeFile("marker.txt", "hi\n")
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // Turn 1 starts and then hangs, so everything below happens mid-run.
        inputCont.yield(bytes("kick off the work"))
        inputCont.yield(bytes("\r"))
        let started = await waitUntil { screenContains(target, rows: rows, cols: cols, "checking-now") }
        #expect(started, "the first turn never began streaming, so there is no in-flight run to drop onto")

        // Drop the image onto the prompt of a RUNNING session.
        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the mid-run drop was not staged")

        // …and submit it. This is the steering path, not the submissions stream.
        inputCont.yield(bytes("what is this"))
        inputCont.yield(bytes("\r"))
        let echoed = await waitUntil { screenContains(target, rows: rows, cols: cols, "what is this") }
        #expect(echoed, "the mid-run submission was never accepted")

        gateway.release()
        let finished = await waitUntil { screenContains(target, rows: rows, cols: cols, "all-done") }
        #expect(finished, "the run never produced its steered second turn")

        // Two turns of ONE run, and the steered turn carries the dropped bytes.
        #expect(gateway.requestCount == 2)
        let secondBody = gateway.requests[1].body
        #expect(secondBody.contains("what is this"), "steer missing from turn 2 request: \(secondBody)")
        #expect(
            try Self.imageDataURLs(secondBody) == [Self.tinyPNGDataURL],
            "the mid-run drop's bytes did not ride the steering message: \(secondBody)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// A steering message left in the box when the run ends carries its IMAGES into
    /// the re-queued run, not just its text.
    ///
    /// `drainLeftoverSteering` re-queues whatever landed after the run's last
    /// steering poll. Escape is what makes that window deterministic: an aborted run
    /// settles straight out of the turn without ever polling, so the mid-run
    /// submission below is still in the box when `agentLoop` drains it. Re-queuing
    /// `user.text` alone silently threw the attachment away — the one place a
    /// leftover can lose content rather than merely arrive late.
    @Test
    func aLeftoverSteeringMessageCarriesItsImageIntoTheRequeuedRun() async throws {
        let gateway = try SteerableGateway(firstTurnText: "checking-now", secondTurnText: "all-done")
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("kick off the work"))
        inputCont.yield(bytes("\r"))
        let started = await waitUntil { screenContains(target, rows: rows, cols: cols, "checking-now") }
        #expect(started, "the first turn never began streaming")

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the mid-run drop was not staged")

        inputCont.yield(bytes("look at this"))
        inputCont.yield(bytes("\r"))
        let echoed = await waitUntil { screenContains(target, rows: rows, cols: cols, "look at this") }
        #expect(echoed, "the mid-run submission was never accepted")

        // Abort turn 1. The loop settles `.aborted` without ever polling steering,
        // so the message above is a LEFTOVER — exactly the window under test.
        inputCont.yield(bytes("\u{1b}"))
        let interrupted = await waitUntil { screenContains(target, rows: rows, cols: cols, "interrupted") }
        #expect(interrupted, "Escape did not abort the running agent")

        // Free the gateway's accept loop so the re-queued run gets served.
        gateway.release()
        let requeued = await waitUntil { screenContains(target, rows: rows, cols: cols, "all-done") }
        #expect(requeued, "the leftover steering message never became a fresh run")

        #expect(gateway.requestCount == 2)
        let secondBody = gateway.requests[1].body
        #expect(secondBody.contains("look at this"), "the leftover's text was lost: \(secondBody)")
        #expect(
            try Self.imageDataURLs(secondBody) == [Self.tinyPNGDataURL],
            "the leftover steering message dropped its image: \(secondBody)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// `/clear` drops staged attachments with the transcript.
    ///
    /// Their `📎 attached …` rows are gone, so bytes still staged after a clear are
    /// invisible: the next message would carry an image the user has no way to know
    /// is still there.
    @Test
    func clearDropsStagedAttachments() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the drop was not staged")

        // `/` opens the slash-command popup, and Enter with a popup up APPLIES the
        // completion rather than submitting. Two Enters cover both orderings: with
        // the popup up the first applies `/clear ` and the second submits it; with
        // the popup not yet built the first submits and the second is a no-op on an
        // empty editor. No wait for the clear to be VISIBLE is possible — the oracle
        // replays the whole captured byte stream, so the already-scrolled
        // `📎 attached …` row never leaves its scrollback — but keystrokes are
        // delivered in order through one stream and `handleSubmit` is synchronous,
        // so the clear provably precedes the next submission.
        inputCont.yield(bytes("/clear"))
        inputCont.yield(bytes("\r"))
        inputCont.yield(bytes("\r"))

        inputCont.yield(bytes("words only please"))
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the post-clear turn never completed")
        #expect(gateway.requestCount == 1)

        let body = gateway.requests[0].body
        #expect(try Self.imageDataURLs(body).isEmpty, "a cleared session still sent the staged image: \(body)")
        #expect(try Self.firstUserText(body) == "words only please", "body: \(body)")

        inputCont.finish()
        try await runTask.value
    }

    /// Dropping a file AND naming it with `@` sends ONE copy, not two.
    ///
    /// The two attachment sources meet in `runOne`, which deduplicates them; without
    /// that, the commonest way to be explicit about a drop — drag it, then also type
    /// its name — doubles the image payload of the turn.
    @Test
    func aDropAlsoNamedWithAtSignAttachesOnce() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        // Inside the working directory, so the SAME file is reachable both as a
        // dropped absolute path and as a sandbox-resolved `@shot.png` mention.
        let dropped = tree.work.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the drop was not staged")

        // Trailing words keep the cursor out of the mention token, so no completion
        // popup is up when Enter submits.
        inputCont.yield(bytes("@shot.png what is this"))
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the turn never completed")
        #expect(gateway.requestCount == 1)

        let body = gateway.requests[0].body
        #expect(
            try Self.imageDataURLs(body) == [Self.tinyPNGDataURL],
            "the drop and its @mention were both attached: \(body)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// A drop with no words is still a message: Enter on an empty editor sends the
    /// image.
    ///
    /// The submit guard used to require text, so dragging a photo in and pressing
    /// Enter did nothing at all — no turn, no error, and the staged bytes silently
    /// held for whenever the user next typed something.
    @Test
    func aDropWithNoWordsStillSendsATurn() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the drop was not staged")

        // Enter with an EMPTY editor.
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "an image-only Enter sent nothing at all")
        #expect(gateway.requestCount == 1)
        #expect(
            try Self.imageDataURLs(gateway.requests[0].body) == [Self.tinyPNGDataURL],
            "body: \(gateway.requests[0].body)"
        )

        inputCont.finish()
        try await runTask.value
    }

    /// Dropping the same file twice says so, and still attaches exactly one copy.
    ///
    /// A duplicate is neither a success nor a failure: with no notice the second
    /// drop looks like it did nothing, and treating it as "not a drop" would type
    /// the path into the prompt as literal text instead.
    @Test
    func reDroppingTheSameFileSaysItIsAlreadyAttached() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.singleTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }
        let dropped = tree.root.appendingPathComponent("shot.png")
        try Self.tinyPNG.write(to: dropped)

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let attached = await waitUntil { screenContains(target, rows: rows, cols: cols, "attached shot.png") }
        #expect(attached, "the first drop was not staged")

        inputCont.yield(Self.bracketedPaste(dropped.path))
        let noticed = await waitUntil {
            screenContains(target, rows: rows, cols: cols, "shot.png is already attached")
        }
        #expect(noticed, "the duplicate drop was silent")
        // And it was NOT typed into the prompt as text.
        //
        // Asserted on the REQUEST BODY rather than on the screen. A screen check
        // here cannot fail: `screenContains` matches within one rendered LINE, and
        // "❯ " plus an absolute temp path is longer than the grid is wide, so no
        // line could ever contain it. The body is where the answer actually is.

        inputCont.yield(bytes("what is this"))
        inputCont.yield(bytes("\r"))
        let replied = await waitUntil { screenContains(target, rows: rows, cols: cols, "Hello from the agent") }
        #expect(replied, "the turn never completed")
        #expect(
            try Self.imageDataURLs(gateway.requests[0].body) == [Self.tinyPNGDataURL],
            "the re-drop attached a second copy: \(gateway.requests[0].body)"
        )
        #expect(
            try Self.firstUserText(gateway.requests[0].body) == "what is this",
            "the duplicate drop's path was typed into the prompt as text: \(gateway.requests[0].body)"
        )

        inputCont.finish()
        try await runTask.value
    }

    // MARK: Errors

    /// A failure the loop SETTLES (rather than throws) is spelled out in the
    /// transcript, with the same three parts the full-screen client shows.
    ///
    /// This is the whole reason the REPL's notice handling exists. A refused
    /// credential produces an assistant message with EMPTY text, which
    /// `finalizeAssistant` deletes as a tool-only turn — so before this the REPL
    /// went straight back to idle with nothing on screen at all, and the user's
    /// only evidence that anything had happened was that no answer arrived.
    @Test
    func inlineReplSpellsOutAGatewayRefusal() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [],
            refuseWith: (
                status: 401,
                reason: "Unauthorized",
                body: #"{"error":{"message":"Invalid API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#
            )
        )
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("what went wrong"))
        inputCont.yield(bytes("\r"))

        // 1. The class of failure, named.
        let headline = await waitUntil {
            screenContains(target, rows: rows, cols: cols, "The gateway rejected the credential")
        }
        #expect(headline, "the REPL went idle with no error on screen")
        // 2. The provider's own words, so the cause is not guesswork.
        #expect(screenContains(target, rows: rows, cols: cols, "Invalid API key provided"))
        // 3. What to do about it — "is my key wrong?" answered without a log.
        #expect(screenContains(target, rows: rows, cols: cols, "credential is set and has not expired"))

        inputCont.finish()
        try await runTask.value
    }

    /// The inline REPL reports a retry too, without any REPL-specific code: the
    /// loop emits an `AgentEvent.notice` and `handle(_:)` already routes every
    /// notice to the transcript. This pins that, because "it works by
    /// inheritance" is exactly the kind of coverage that silently disappears.
    @Test
    func inlineReplShowsARetryWhileItWaits() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.singleTextTurn],
            refuseWith: (
                status: 503,
                reason: "Service Unavailable",
                body: #"{"error":{"message":"upstream is at capacity","type":"server_error"}}"#
            ),
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let tree = try TempTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(
                baseURL: gateway.baseURL,
                apiKey: "sk-test",
                // Keep the wait to the shortest possible backoff — the test is
                // about the message, not the sleep.
                baseRetryDelay: .milliseconds(1),
                maxRetryDelay: .milliseconds(1)
            ),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)

        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(bytes("hello"))
        inputCont.yield(bytes("\r"))

        let shown = await waitUntil {
            screenContains(target, rows: rows, cols: cols, "Retrying in")
        }
        #expect(shown, "the REPL never said it was retrying")
        #expect(screenContains(target, rows: rows, cols: cols, "provider busy"))

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
        #if canImport(Darwin)
        // The abort test releases this turn AFTER the client has hung up, so the
        // tail below is written to a socket whose peer is gone. Without this, a
        // second `send` on the RST'd socket would raise SIGPIPE and take the whole
        // test process down rather than returning EPIPE to `writeAll`.
        var noSigPipe: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

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
