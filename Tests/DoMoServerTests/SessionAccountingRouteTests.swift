// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 5a, server half: the session's cumulative accounting crossing the wire on
// `GET /session/{id}/status`, and the three knobs `ServerRuntime.Config` now
// forwards into every harness it builds (context window, compaction settings, the
// summarization call).
//
// Two things this file is deliberately built to catch, because both have shipped
// green here before:
//
//   * A field that is plumbed into a struct and read by nobody. The forwarding
//     tests therefore assert through BEHAVIOUR — a tiny window makes the session
//     compact, a disabled one stops it — never by reading the value back out of
//     the object it was just written into.
//   * A degradation that is documented and not implemented. `accounting()` throws
//     on a session whose active path has a hole, which is exactly the session a
//     client asks `/status` about; the route must still answer.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoServer
import Foundation
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct SessionAccountingRouteTests {

    static let token = "test-token-accounting"

    /// The per-turn usage every scripted answer below reports. Distinct, non-round
    /// numbers so a total can only match by actually summing these.
    static let turnUsage = Usage(input: 3_000, output: 10, reportedCost: Decimal(string: "0.25"))

    /// What the injected summarizer reports for the summarization request. Its
    /// presence in a session total is the only evidence that compaction's own model
    /// call was billed.
    static let summaryUsage = Usage(input: 77, output: 7)

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-accounting-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A summarizer that records how often it was asked to summarize.
    ///
    /// The call count is the whole instrument: `Config.summarizer` reaching the
    /// harness, `Config.contextWindow` reaching it small enough to trigger, and
    /// `Config.compaction` reaching it enabled are each necessary for this to be
    /// called even once.
    private final class RecordingSummarizer: Sendable {
        private let calls = Mutex(0)

        var callCount: Int { calls.withLock { $0 } }

        var summarizer: Summarizer {
            // Captures `self`, not the mutex: `Mutex` is non-copyable, so binding it
            // to a local to capture would be a copy the compiler rejects. The class
            // is `Sendable`, which is what makes the capture legal in a `@Sendable`
            // closure.
            { [self] _ in
                calls.withLock { $0 += 1 }
                return SummarizerResult(text: "COMPACTED", usage: SessionAccountingRouteTests.summaryUsage)
            }
        }
    }

    /// One assistant turn answering `"ok"`, reporting ``turnUsage``.
    private static func answeringStreamFn() -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(
                    content: [.text("ok")],
                    model: "test-model",
                    usage: SessionAccountingRouteTests.turnUsage,
                    stopReason: .stop
                )))
                continuation.finish()
            }
        }
    }

    private static func makeRuntime(
        _ dirs: Dirs,
        contextWindow: Int? = nil,
        compaction: CompactionSettings = .default,
        summarizer: Summarizer? = nil
    ) -> ServerRuntime {
        ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: answeringStreamFn(),
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            contextWindow: contextWindow,
            compaction: compaction,
            summarizer: summarizer
        ))
    }

    private static func makeServer(_ dirs: Dirs, contextWindow: Int?) -> DoMoServer {
        DoMoServer(
            runtime: makeRuntime(dirs, contextWindow: contextWindow),
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    // MARK: - The status route carries the totals

    @Test("The status route reports the session's real accounting after a turn")
    func statusCarriesAccountingAfterATurn() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = Self.makeServer(dirs, contextWindow: 123_456)

        try await withServer(server) { http, port in
            let create = try await send(http, port, .post, "/session")
            let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id

            // Before any turn: a session that has spent nothing still reports, and
            // reports zeroes rather than nothing. `nil` here would mean "unknown",
            // which would be a lie about a session with an empty transcript.
            let fresh = try await status(http, port, id)
            let freshAccounting = try #require(fresh.accounting, "a fresh session reported no accounting at all")
            #expect(freshAccounting.turns == 0)
            #expect(freshAccounting.usage.totalTokens == 0)
            #expect(freshAccounting.contextTokens == 0)

            let prompt = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": "go"])
            #expect(prompt.status == 202, "prompt returned \(prompt.status)")
            #expect(await waitUntilIdle(http, port, id), "the turn never finished")

            let after = try await status(http, port, id)
            let accounting = try #require(after.accounting, "the status route reported no accounting after a turn")
            #expect(accounting.turns == 1, "turns was \(accounting.turns)")
            #expect(accounting.usage.input == 3_000, "input was \(accounting.usage.input)")
            #expect(accounting.usage.output == 10, "output was \(accounting.usage.output)")
            // The gateway-reported price, not the four-way `cost` breakdown, which
            // is zero here because no rate table was configured. Asserting the
            // reported number is what pins `effectiveCostTotal` as the source.
            #expect(
                accounting.costTotal == Decimal(string: "0.25"),
                "costTotal was \(accounting.costTotal); reading cost.total instead of effectiveCostTotal gives 0"
            )
            // The whole context is the user prompt and one assistant turn, and that
            // turn reported 3,010 tokens, so the estimate anchors on it exactly.
            #expect(accounting.contextTokens == 3_010, "contextTokens was \(accounting.contextTokens)")
            #expect(accounting.contextWindow == 123_456, "the configured window did not reach the wire")
        }
    }

    @Test("An unknown context window crosses the wire as nil, never as the compaction fallback")
    func unknownContextWindowStaysUnknown() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        // No window configured — the default, and the honest answer behind a
        // gateway. Compaction still falls back to 200,000 internally; a meter must
        // never see that number, because a percentage of a guess is indistinguishable
        // on screen from a percentage of a measurement.
        let server = Self.makeServer(dirs, contextWindow: nil)

        try await withServer(server) { http, port in
            let create = try await send(http, port, .post, "/session")
            let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id
            let prompt = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": "go"])
            #expect(prompt.status == 202, "prompt returned \(prompt.status)")
            #expect(await waitUntilIdle(http, port, id), "the turn never finished")

            let reported = try await status(http, port, id)
            let accounting = try #require(reported.accounting, "no accounting was reported")
            #expect(accounting.contextWindow == nil, "an unknown window was reported as \(accounting.contextWindow ?? -1)")
            // And genuinely absent from the bytes, not merely decoded as nil: an
            // encoder that substituted the fallback would still decode as a number,
            // and a client cannot tell an invented denominator from a measured one.
            let raw = try await send(http, port, .get, "/session/\(id)/status")
            let body = String(decoding: raw.body, as: UTF8.self)
            #expect(body.contains("contextTokens"), "the payload carried no accounting at all: \(body)")
            #expect(!body.contains("contextWindow"), "an unknown window was written to the wire: \(body)")
            #expect(!body.contains("200000"), "the compaction fallback window leaked onto the status payload: \(body)")
        }
    }

    // MARK: - The degradation

    @Test("Status still answers, with accounting nil, when the session's path cannot be resolved")
    func statusDegradesRatherThanFailing() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = Self.makeServer(dirs, contextWindow: 123_456)

        try await withServer(server) { http, port in
            let create = try await send(http, port, .post, "/session")
            let ref = try JSONDecoder().decode(SessionRef.self, from: create.body)
            let prompt = try await send(http, port, .post, "/session/\(ref.id)/prompt", json: ["prompt": "go"])
            #expect(prompt.status == 202, "prompt returned \(prompt.status)")
            #expect(await waitUntilIdle(http, port, ref.id), "the turn never finished")
            let healthy = try await status(http, port, ref.id)
            #expect(healthy.accounting != nil, "no accounting to lose; the degradation below proves nothing")

            // Punch the hole: keep the header line, drop every entry. The live
            // harness still holds a tip id that the file no longer contains, so
            // `AgentHarness.accounting()` throws resolving the active path — the
            // exact shape of damage a wedged client asks this route about.
            try truncateToHeaderLine(ref.path)

            let reply = try await send(http, port, .get, "/session/\(ref.id)/status")
            #expect(reply.status == 200, "a damaged session made the diagnostic route fail with \(reply.status)")
            let damaged = try JSONDecoder().decode(SessionStatus.self, from: reply.body)
            #expect(damaged.accounting == nil, "accounting was computed off a path that cannot be resolved")
            // Everything the route exists for survives the numbers not being
            // available. This is the assertion the degradation is FOR.
            #expect(damaged.sessionID == ref.id)
            #expect(damaged.running == false)
            #expect(damaged.runStartedAt == nil)
            #expect(damaged.pendingPermissionIDs.isEmpty)

            // The messages route, which has no such degradation, is the control:
            // the file really is broken, so the 200 above is not a truncation that
            // silently did nothing.
            let messages = try await send(http, port, .get, "/session/\(ref.id)/messages")
            #expect(messages.status != 200, "the file was not actually damaged; the degradation was never exercised")
        }
    }

    // MARK: - Config forwarding, asserted through behaviour

    @Test("A tiny configured context window plus the configured summarizer makes the session compact")
    func configuredWindowAndSummarizerReachTheHarness() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let recorder = RecordingSummarizer()
        // 3,010 reported tokens per turn against a 2,000-token window with a 500
        // reserve trips the threshold, so the third turn compacts. Under the
        // default 200,000-token window it never would.
        let runtime = Self.makeRuntime(
            dirs,
            contextWindow: 2_000,
            compaction: CompactionSettings(enabled: true, reserveTokens: 500, keepRecentTokens: 200),
            summarizer: recorder.summarizer
        )

        let session = try await runtime.createSession()
        for turn in 1...3 { try await runTurn(runtime, session.id, turn: turn) }

        #expect(
            recorder.callCount == 1,
            """
            the configured summarizer ran \(recorder.callCount) times, not once — \
            a zero means Config.contextWindow, Config.compaction or Config.summarizer \
            never reached AgentHarness.Configuration
            """
        )

        let reported = try await runtime.status(sessionID: session.id)
        let accounting = try #require(reported.accounting, "the runtime reported no accounting")
        #expect(accounting.turns == 3, "turns was \(accounting.turns)")
        // 3 × 3,000 for the turns, plus 77 for the summarization request. The
        // summarizer's own usage is the only way compaction's cost ever enters a
        // session total, so 9,000 here would mean it was silently dropped.
        #expect(accounting.usage.input == 9_077, "input was \(accounting.usage.input)")
        #expect(accounting.usage.output == 37, "output was \(accounting.usage.output)")
        #expect(accounting.costTotal == Decimal(string: "0.75"), "costTotal was \(accounting.costTotal)")
        #expect(accounting.contextWindow == 2_000)
    }

    @Test("Compaction settings that disable it reach the harness too — nothing compacts")
    func configuredCompactionSettingsReachTheHarness() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let recorder = RecordingSummarizer()
        // Identical to the test above in every respect but one: compaction is off.
        // That makes the absence below meaningful rather than merely quiet — the
        // same script with `enabled: true` compacts exactly once.
        let runtime = Self.makeRuntime(
            dirs,
            contextWindow: 2_000,
            compaction: CompactionSettings(enabled: false, reserveTokens: 500, keepRecentTokens: 200),
            summarizer: recorder.summarizer
        )

        let session = try await runtime.createSession()
        for turn in 1...3 { try await runTurn(runtime, session.id, turn: turn) }

        #expect(
            recorder.callCount == 0,
            "compaction ran \(recorder.callCount) times with `enabled: false`; Config.compaction was not forwarded"
        )
        // The positive control: the three turns really did happen, so "nothing
        // compacted" is not "nothing ran".
        let reported = try await runtime.status(sessionID: session.id)
        let accounting = try #require(reported.accounting, "the runtime reported no accounting")
        #expect(accounting.turns == 3, "turns was \(accounting.turns)")
        #expect(accounting.usage.input == 9_000, "input was \(accounting.usage.input)")
    }

    // MARK: - Wire compatibility

    @Test("A status payload from a server that predates `accounting` still decodes")
    func olderStatusShapeStillDecodes() throws {
        // Byte-for-byte the shape the previous version of this server encoded.
        // `ServerClient.status` uses a plain JSONDecoder, so an absent optional key
        // has to read as nil rather than throw.
        let json = """
            {"sessionID":"s1","running":true,"pendingPermissionIDs":["p1"],\
            "subscribers":2,"runStartedAt":"2026-07-31T00:00:00.000Z"}
            """
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        #expect(status.accounting == nil)
        #expect(status.sessionID == "s1")
        #expect(status.running)
        #expect(status.pendingPermissionIDs == ["p1"])
        #expect(status.subscribers == 2)
        #expect(status.runStartedAt == "2026-07-31T00:00:00.000Z")
    }

    @Test("A status with no accounting encodes the same bytes an older server sent")
    func absentAccountingWritesNoKey() throws {
        let bare = SessionStatus(
            sessionID: "s1",
            running: false,
            pendingPermissionIDs: [],
            subscribers: 0,
            runStartedAt: nil
        )
        let text = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(
            !text.contains("accounting"),
            "an unknown accounting encoded a key; an older client would decode a shape it does not expect: \(text)"
        )
    }

    @Test("A status carrying accounting round-trips, and an unknown window stays absent")
    func accountingRoundTripsOnTheWire() throws {
        let half = try #require(Decimal(string: "0.5"))
        let accounting = SessionAccounting(
            usage: Usage(input: 3, output: 4, reportedCost: half),
            costTotal: half,
            contextTokens: 7,
            contextWindow: nil,
            turns: 2
        )
        let status = SessionStatus(
            sessionID: "s1",
            running: true,
            pendingPermissionIDs: ["p1"],
            subscribers: 1,
            runStartedAt: "2026-07-31T00:00:00.000Z",
            accounting: accounting
        )
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(SessionStatus.self, from: data) == status)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("contextTokens"), "the payload did not carry accounting at all: \(text)")
        #expect(
            !text.contains("contextWindow"),
            "an unknown window encoded a key; a client cannot tell it from a real number: \(text)"
        )
    }

    @Test("The wire protocol version is unchanged — an additive optional field does not bump it")
    func protocolVersionUnchangedByAnAdditiveField() {
        // `ServerEvent.swift` states the rule this relies on: a new OPTIONAL field
        // on a payload is absorbed by both sides' plain JSONDecoder, so bumping
        // would only make older clients refuse a server they can still read.
        #expect(serverProtocolVersion == 1)
    }

    // MARK: - Helpers

    private struct Reply { let status: UInt; let body: Data }
    private enum Method { case get, post }

    /// Drive one turn to completion on the runtime directly.
    private func runTurn(_ runtime: ServerRuntime, _ sessionID: String, turn: Int) async throws {
        // Long enough that the user message is ~1,000 estimated tokens, so the
        // recent-token budget is met at a user boundary that is not the first one —
        // which is what leaves anything older for a compaction to summarize.
        try await runtime.startRun(
            sessionID: sessionID,
            prompt: String(repeating: "context ", count: 500) + "turn \(turn)",
            attachments: []
        )
        var waited = Duration.zero
        while waited < .seconds(10) {
            if await runtime.isRunning(sessionID: sessionID) == false { return }
            try await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        Issue.record("turn \(turn) never finished")
    }

    /// Overwrite a session file with its header line alone, leaving a live harness
    /// pinned to a tip the file no longer contains.
    private func truncateToHeaderLine(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let header = try #require(
            text.split(separator: "\n", omittingEmptySubsequences: true).first,
            "the session file was empty; nothing to damage"
        )
        try Data((header + "\n").utf8).write(to: url)
    }

    private func status(_ http: HTTPClient, _ port: Int, _ id: String) async throws -> SessionStatus {
        let reply = try await send(http, port, .get, "/session/\(id)/status")
        #expect(reply.status == 200, "status returned \(reply.status)")
        return try JSONDecoder().decode(SessionStatus.self, from: reply.body)
    }

    private func waitUntilIdle(_ http: HTTPClient, _ port: Int, _ id: String) async -> Bool {
        var waited = Duration.zero
        while waited < .seconds(10) {
            if let idle = try? await status(http, port, id), !idle.running { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        return false
    }

    private func withServer(
        _ server: DoMoServer,
        _ body: (HTTPClient, Int) async throws -> Void
    ) async throws {
        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        var thrown: (any Error)?
        do {
            try await body(http, port)
        } catch {
            thrown = error
        }
        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
        if let thrown { throw thrown }
    }

    private func send(
        _ http: HTTPClient,
        _ port: Int,
        _ method: Method,
        _ path: String,
        json: [String: String]? = nil,
        token: String? = SessionAccountingRouteTests.token
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        switch method {
        case .get: request.method = .GET
        case .post: request.method = .POST
        }
        if let token { request.headers.add(name: "authorization", value: "Bearer \(token)") }
        if let json {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(try JSONEncoder().encode(json)))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 64 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Reply(status: response.status.code, body: Data(bytes))
    }
}
