// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The reported complaint, end to end: "sometimes errors occur and they give no
// context as to what the error is."
//
// Everything here runs the REAL full-screen client — `runFullScreenClient` over
// a real `ServerClient`, a real `TerminalDriver`, and (where the failure is a
// gateway failure) a real in-process `DoMoServer` — and asserts on the CELLS a
// VT100 emulator ends up with after replaying the bytes the client wrote. A test
// that asserts on the store proves the model; only this proves the screen, which
// is where the complaint was made.

import AsyncHTTPClient
import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoLLM
import DoMoServer
import DoMoTermIO
import DoMoTUI
import Foundation
import SystemPackage
import Testing

// MARK: - Doubles

/// A `RenderTarget` that accumulates every frame the driver writes, so the whole
/// byte stream can be replayed into a fresh emulator and the resulting screen
/// asserted.
@MainActor
private final class CaptureTarget: RenderTarget {
    let columns: Int
    let rows: Int
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    func write(_ bytes: String) { buffer += bytes }
    func snapshot() -> String { buffer }
}

/// There is no tty to put into raw mode headlessly; the driver needs only that
/// `enter`/`stop` succeed.
private final class NoopClientLifecycle: TerminalLifecycleControl {
    func enter() throws(DoMoError) {}
    func stop() {}
}

// MARK: - Helpers

@MainActor
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

@MainActor
private func screenRows(_ target: CaptureTarget, rows: Int, columns: Int) -> [String] {
    let oracle = ScreenOracle(rows: rows, cols: columns)
    oracle.feed(target.snapshot())
    return oracle.screen + oracle.transcript
}

@MainActor
private func screenContains(_ target: CaptureTarget, rows: Int, columns: Int, _ needle: String) -> Bool {
    screenRows(target, rows: rows, columns: columns).contains { $0.contains(needle) }
}

@MainActor
@Suite(.serialized)
struct ErrorSurfaceEndToEndTests {
    private static let token = "e2e-error-surface-token"
    // Widened from 150 when the mouse-mode hint joined the status line. The
    // status line is truncated from the right and this suite asserts on a hint
    // near its end (`^O: expand`), so the terminal has to be wide enough to hold
    // the whole line. No assertion changed.
    private static let columns = 180
    private static let rows = 30

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-errsurface-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeServer(_ dirs: Dirs, streamFn: @escaping AgentStreamFn) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    /// Run the real client against `baseURL`, drive it with `script`, and return
    /// the captured screen once `until` holds (or the deadline passes).
    private func runClient(
        baseURL: String,
        token: String = ErrorSurfaceEndToEndTests.token,
        script: @escaping @MainActor (AsyncStream<[UInt8]>.Continuation, CaptureTarget) async -> Void = { _, _ in },
        until: @escaping @MainActor (CaptureTarget) -> Bool
    ) async -> CaptureTarget {
        // One end-to-end client at a time across the whole binary — see
        // FullScreenClientGate. This suite's `type` helper has a wall-clock
        // budget, and a second client running on the same main actor spends it.
        await FullScreenClientGate.shared.enter()
        let target = CaptureTarget(columns: Self.columns, rows: Self.rows)
        let (input, inputCont) = AsyncStream<[UInt8]>.makeStream()
        let (resize, resizeCont) = AsyncStream<TerminalSize>.makeStream()
        let clientTask = Task { @MainActor in
            try? await runFullScreenClient(
                baseURL: baseURL,
                token: token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: NoopClientLifecycle()
            )
        }
        await script(inputCont, target)
        _ = await waitUntil { until(target) }
        inputCont.yield([0x03])   // ^C quits
        inputCont.finish()
        resizeCont.finish()
        _ = await clientTask.result
        await FullScreenClientGate.shared.leave()
        return target
    }

    /// Type `text`, then press Enter until `needle` shows up.
    ///
    /// Retried rather than timed, because the prompt has to reach a session that
    /// bootstrap is still opening. `PromptInput` clears before submitting and
    /// `submit` restores on refusal, so a press that lands too early puts the same
    /// text back rather than duplicating it, and a press that lands while a turn
    /// is running finds an empty prompt and does nothing.
    @MainActor
    private func type(
        _ text: String,
        into continuation: AsyncStream<[UInt8]>.Continuation,
        target: CaptureTarget,
        untilScreenHas needle: String,
        attempts: Int = 40
    ) async {
        continuation.yield(Array(text.utf8))
        for _ in 0..<attempts {
            continuation.yield([0x0d])
            try? await Task.sleep(for: .milliseconds(250))
            if screenContains(target, rows: Self.rows, columns: Self.columns, needle) { return }
        }
    }

    // MARK: A gateway that refuses the credential

    @Test("A 401 from the gateway is spelled out on screen, with a remedy")
    func gatewayAuthFailureIsReadable() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        // Exactly how LiteLLM's 4xx path behaves: the stream finishes THROWING an
        // already-classified DoMoError. Before this work the classification was
        // stringified one frame later and the client rendered nothing at all.
        let server = makeServer(dirs, streamFn: { _ in
            AsyncThrowingStream {
                $0.finish(throwing: DoMoError(
                    .authentication,
                    "stream chat completions: HTTP 401: Invalid API key provided"
                ))
            }
        })
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var portIterator = ports.makeAsyncIterator()
        let port = await portIterator.next() ?? 0

        let target = await runClient(
            baseURL: "http://127.0.0.1:\(port)",
            script: { continuation, target in
                await self.type(
                    "what went wrong?", into: continuation, target: target,
                    untilScreenHas: "The gateway rejected the credential"
                )
            },
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "✗") }
        )

        let rows = screenRows(target, rows: Self.rows, columns: Self.columns)
        let joined = rows.joined(separator: "\n")
        #expect(joined.contains("The gateway rejected the credential"), "screen:\n\(joined)")
        #expect(joined.contains("Invalid API key provided"), "screen:\n\(joined)")
        // "is my key wrong?" answered without reading a log.
        #expect(joined.contains("credential is set and has not expired"), "screen:\n\(joined)")

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    // MARK: A gateway that blew the context window

    @Test("A context-overflow failure names the window and what to do about it")
    func contextOverflowIsReadable() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, streamFn: { _ in
            AsyncThrowingStream {
                $0.finish(throwing: DoMoError(
                    .contextOverflow,
                    "stream chat completions: HTTP 400: This model's maximum context length is 128000 tokens"
                ))
            }
        })
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var portIterator = ports.makeAsyncIterator()
        let port = await portIterator.next() ?? 0

        let target = await runClient(
            baseURL: "http://127.0.0.1:\(port)",
            script: { continuation, target in
                await self.type(
                    "summarise everything", into: continuation, target: target,
                    untilScreenHas: "no longer fits the context window"
                )
            },
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "✗") }
        )

        let joined = screenRows(target, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        #expect(joined.contains("no longer fits the context window"), "screen:\n\(joined)")
        #expect(joined.contains("maximum context length is 128000"), "screen:\n\(joined)")
        #expect(joined.contains("Compact it and retry"), "screen:\n\(joined)")

        serverTask.cancel()
        _ = try? await serverTask.value
    }

    // MARK: A runtime that answers with an explanation

    @Test("A 502 with an explanation shows the explanation, not just the number")
    func explainedStatusShowsItsBody() async throws {
        // This is the difference `unexpectedStatus.body` exists for. Every throw
        // site used to pass `nil`, so a 500 and a 502-with-a-real-reason rendered
        // identically: as a number.
        let explanation = "upstream connect error or disconnect/reset before headers: the runtime is not accepting connections"
        let stub = try ExplainingServer(status: 502, reason: "Bad Gateway", body: explanation)
        stub.start()
        defer { stub.stop() }

        let target = await runClient(
            baseURL: stub.baseURL,
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "Could not reach the runtime") }
        )
        let joined = screenRows(target, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        #expect(joined.contains("HTTP 502 from /sessions"), "screen:\n\(joined)")
        #expect(joined.contains("upstream connect error"), "screen:\n\(joined)")
    }

    // MARK: A session the runtime will not resume

    /// A runtime that LISTS a session and then refuses to resume it. The client
    /// used to enter this state through a bare `_ = try?` and then look
    /// completely normal while refusing every prompt, abort and approval.
    private static func halfDeadRuntime() throws -> ExplainingServer {
        try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK",
                          #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/work","timestamp":"2026-01-01"}]"#),
                StubRoute("POST", "/session", 404, "Not Found", "no such session on this runtime"),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
    }

    @Test("A session the runtime will not resume says so instead of looking fine")
    func deadSessionIsReported() async throws {
        let stub = try Self.halfDeadRuntime()
        stub.start()
        defer { stub.stop() }

        let target = await runClient(
            baseURL: stub.baseURL,
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "not live on the server") }
        )
        let joined = screenRows(target, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        #expect(joined.contains("This session is not live on the server"), "screen:\n\(joined)")
        // The consequence, spelled out — this is the part that turns a mysterious
        // dead UI into something the user can act on.
        #expect(joined.contains("Prompts, aborts and approvals will not work"), "screen:\n\(joined)")
        // And the runtime's own words, carried by `unexpectedStatus.body`.
        #expect(joined.contains("no such session on this runtime"), "screen:\n\(joined)")
    }

    @Test("History that will not load is reported, not shown as an empty conversation")
    func unloadableHistoryIsReported() async throws {
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK",
                          #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/work","timestamp":"2026-01-01"}]"#),
                StubRoute("POST", "/session", 201, "Created",
                          #"{"id":"abc123","path":"/tmp/abc123.jsonl"}"#),
                StubRoute("GET", "/messages", 500, "Internal Server Error", "session file is unreadable"),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let target = await runClient(
            baseURL: stub.baseURL,
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "Could not load this session") }
        )
        let joined = screenRows(target, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        // An empty pane is indistinguishable from a brand-new session.
        #expect(joined.contains("Could not load this session's history"), "screen:\n\(joined)")
        #expect(joined.contains("session file is unreadable"), "screen:\n\(joined)")
        // The session file the server DID name, so there is somewhere to look.
        #expect(joined.contains("/tmp/abc123.jsonl"), "screen:\n\(joined)")
    }

    // MARK: ^O

    @Test("^O expands a capped failure body and the status line offers the key")
    func ctrlOExpandsDetail() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        // A gateway body long enough to be capped — a real HTML error page is
        // much worse than this.
        let long = (1...150).map { "cause \($0) in the chain" }.joined(separator: "\n")
        let server = makeServer(dirs, streamFn: { _ in
            AsyncThrowingStream { $0.finish(throwing: DoMoError(.provider(status: 500, isRetryable: true), long)) }
        })
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var portIterator = ports.makeAsyncIterator()
        let port = await portIterator.next() ?? 0

        let capturedBefore = await runClient(
            baseURL: "http://127.0.0.1:\(port)",
            script: { continuation, target in
                await self.type("go", into: continuation, target: target, untilScreenHas: "^O to expand")
            },
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "^O to expand") }
        )
        let before = screenRows(capturedBefore, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        // The cap advertises its own door, and the status line offers the key.
        #expect(before.contains("^O to expand"), "screen:\n\(before)")
        #expect(before.contains("^O: expand"), "screen:\n\(before)")
        #expect(!before.contains("cause 150 in the chain"), "screen:\n\(before)")

        let capturedAfter = await runClient(
            baseURL: "http://127.0.0.1:\(port)",
            script: { continuation, target in
                await self.type("go", into: continuation, target: target, untilScreenHas: "^O to expand")
                continuation.yield([0x0f])   // ^O
            },
            until: { screenContains($0, rows: Self.rows, columns: Self.columns, "cause 150 in the chain") }
        )
        let after = screenRows(capturedAfter, rows: Self.rows, columns: Self.columns).joined(separator: "\n")
        #expect(after.contains("cause 150 in the chain"), "screen:\n\(after)")

        serverTask.cancel()
        _ = try? await serverTask.value
    }
}
