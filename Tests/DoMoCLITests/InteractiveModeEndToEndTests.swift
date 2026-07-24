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

import DoMoCLI
import DoMoCore
import DoMoLLM
import DoMoTermIO
import DoMoTUI
import Foundation
import Testing

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
