// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

// MARK: - Test support

/// A gateway whose behavior is scripted per request: the Nth model request gets
/// the Nth entry, and the last entry repeats forever so a capped loop can be
/// driven against a gateway that never recovers.
private final class GatewayScript: Sendable {
    /// One request's worth of gateway behavior.
    enum Reply: Sendable {
        /// The proxy answered with a timeout status instead of the model.
        case timeoutStatus(Int)
        /// The socket gave up before a status existed — the shape
        /// `Transport.idleGuarded` produces, prose and all.
        case transportTimeout(String)
        /// A failure that is emphatically not a timeout.
        case fatal(DoMoError.Kind, String)
        /// The model answered.
        case answer(String)
    }

    private let replies: [Reply]
    private let requests = Mutex<[[Message]]>([])

    init(_ replies: [Reply]) { self.replies = replies }

    /// The context each request was made with, in request order.
    var requestContexts: [[Message]] { requests.withLock { $0 } }
    var requestCount: Int { requests.withLock { $0.count } }

    func fn() -> AgentStreamFn {
        { [self] context in
            let index = requests.withLock { recorded -> Int in
                recorded.append(context.messages)
                return recorded.count - 1
            }
            switch replies[min(index, replies.count - 1)] {
            case .timeoutStatus(let status):
                return Self.throwing(
                    DoMoError(.provider(status: status, isRetryable: true), "Gateway Time-out")
                )
            case .transportTimeout(let message):
                return Self.throwing(DoMoError(.transport, message))
            case .fatal(let kind, let message):
                return Self.throwing(DoMoError(kind, message))
            case .answer(let text):
                let message = AssistantMessage(
                    content: [.text(text)],
                    model: "test-model",
                    stopReason: .stop
                )
                return AsyncThrowingStream { continuation in
                    continuation.yield(.start(AssistantSnapshot(model: message.model)))
                    continuation.yield(.done(message))
                    continuation.finish()
                }
            }
        }
    }

    private static func throwing(_ error: DoMoError) -> AsyncThrowingStream<AssemblyEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
    }
}

/// Keeps every event so the continuation notices can be counted and read.
private final class NoticeRecorder: AgentEventSink {
    private let storage = Mutex<[AgentNotice]>([])
    func emit(_ event: AgentEvent) async {
        guard case .notice(let notice) = event else { return }
        storage.withLock { $0.append(notice) }
    }
    var notices: [AgentNotice] { storage.withLock { $0 } }
    var continuations: [AgentNotice] { notices.filter { $0.code == "gateway_continue" } }
}

private final class SequentialIDs: Sendable {
    private let counter = Mutex<Int>(0)
    private let prefix: String
    init(prefix: String) { self.prefix = prefix }
    func factory() -> @Sendable () -> String {
        { [self] in
            let value = counter.withLock { current -> Int in
                let taken = current
                current += 1
                return taken
            }
            return "\(prefix)-\(value)"
        }
    }
}

@Suite("Gateway continuation")
struct GatewayContinuationTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-gateway-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private func makeHarness(
        _ script: GatewayScript,
        continuation: GatewayContinuationSettings,
        prefix: String
    ) throws -> AgentHarness {
        try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: AgentHarness.Configuration(
                systemPrompt: "You are a test.",
                model: "test-model",
                streamFn: script.fn(),
                compaction: CompactionSettings(enabled: false),
                now: { self.fixedDate },
                entryIDFactory: SequentialIDs(prefix: prefix).factory(),
                gatewayContinuation: continuation
            )
        )
    }

    /// Every user message a run produced, in order — the continuation prompts are
    /// counted here rather than in the session file so the assertion holds whether
    /// or not persistence reordered anything.
    private func userTexts(in result: AgentRunResult) -> [String] {
        result.messages.compactMap { message in
            guard case .user(let user) = message else { return nil }
            return user.text
        }
    }

    /// The user messages the session file records, which is what a resumed
    /// session and the transcript UI will show.
    private func persistedUserTexts(of path: FilePath) throws -> [String] {
        try JSONLSessionStore.open(path: path).readEntries().compactMap { entry in
            guard case .message(.user(let user)) = entry.payload else { return nil }
            return user.text
        }
    }

    // MARK: - The cap

    @Test("a gateway that never recovers sends one continuation per attempt and stops at the cap")
    func stopsAtTheCap() async throws {
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 3, message: "Continue please.")
        let script = GatewayScript([.timeoutStatus(504)])
        let harness = try makeHarness(script, continuation: settings, prefix: "cap")
        let sink = NoticeRecorder()

        let result = try await harness.run(prompt: "write the thing", sink: sink)

        #expect(script.requestCount == 4, "the original request plus exactly three continuations")
        #expect(sink.continuations.count == 3)
        #expect(userTexts(in: result).filter({ $0 == "Continue please." }).count == 3)
        #expect(result.stopReason == .errored)
        #expect(result.failure != nil, "the last failure survives — the loop gives up, it does not launder")

        // The prompts reach the session file, so a resumed session sees the same
        // conversation the model was shown.
        let persisted = try persistedUserTexts(of: await harness.sessionFilePath)
        #expect(persisted == ["write the thing", "Continue please.", "Continue please.", "Continue please."])

        // The notice names the attempt and the cap, which is the whole reason it
        // exists — a run that has been quiet for minutes must say it is still driven.
        #expect(sink.continuations.map(\.text) == [
            "Gateway timed out — continuing (1/3)",
            "Gateway timed out — continuing (2/3)",
            "Gateway timed out — continuing (3/3)",
        ])
        #expect(sink.continuations.allSatisfy({ $0.level == .warning }))
    }

    // MARK: - Stopping on success

    @Test("a retry that succeeds ends the loop and its answer becomes the run's result")
    func stopsWhenARetrySucceeds() async throws {
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 10, message: "Continue.")
        let script = GatewayScript([
            .timeoutStatus(504),
            .timeoutStatus(504),
            .answer("here is the rest"),
        ])
        let harness = try makeHarness(script, continuation: settings, prefix: "recover")
        let sink = NoticeRecorder()

        let result = try await harness.run(prompt: "write the thing", sink: sink)

        #expect(script.requestCount == 3, "the third request answered, so there is no fourth")
        #expect(sink.continuations.count == 2)
        #expect(result.stopReason == .completed)
        #expect(result.failure == nil, "a run that recovered must not report the failure it recovered from")

        // The failed turns are still in the transcript — the continuation adds to
        // the conversation rather than rewriting it.
        let assistantTexts = result.messages.compactMap { message -> String? in
            guard case .assistant(let assistant) = message else { return nil }
            return assistant.text
        }
        #expect(assistantTexts.last == "here is the rest")

        // Each continuation was asked against the conversation as it then stood,
        // with the continuation prompt as the newest message.
        let contexts = script.requestContexts
        #expect(contexts.count == 3)
        #expect(contexts[1].last == Message.user(UserMessage(content: [.text("Continue.")])))
        #expect(contexts[1].contains(Message.user(UserMessage(content: [.text("write the thing")]))))
        #expect(contexts[2].count > contexts[1].count, "the second continuation sees the first one's turn")
    }

    // MARK: - What never enters the loop

    @Test("a failure that is not a gateway timeout produces no continuation at all")
    func nonTimeoutFailuresAreLeftAlone() async throws {
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 5, message: "Continue.")
        for (index, reply) in [
            GatewayScript.Reply.fatal(.provider(status: 400, isRetryable: false), "invalid request"),
            GatewayScript.Reply.fatal(.rateLimit(retryAfter: nil), "rate limit reached"),
            GatewayScript.Reply.fatal(.authentication, "invalid api key"),
            GatewayScript.Reply.fatal(.transport, "connection refused"),
        ].enumerated() {
            let script = GatewayScript([reply])
            let harness = try makeHarness(script, continuation: settings, prefix: "fatal-\(index)")
            let sink = NoticeRecorder()

            let result = try await harness.run(prompt: "hello", sink: sink)

            #expect(script.requestCount == 1, "reply \(index) was continued when it should not have been")
            #expect(sink.continuations.isEmpty, "reply \(index) emitted a continuation notice")
            #expect(result.stopReason == .errored)
        }
    }

    @Test("a transport failure whose prose says it timed out is continued")
    func transportTimeoutsAreContinued() async throws {
        // The status-code path and the prose path are independent signals; this is
        // the one a read timeout takes, where no HTTP status was ever received.
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 1, message: "Continue.")
        let script = GatewayScript([
            .transportTimeout("The model stopped sending data and the request timed out"),
            .answer("resumed"),
        ])
        let harness = try makeHarness(script, continuation: settings, prefix: "transport")
        let sink = NoticeRecorder()

        let result = try await harness.run(prompt: "hello", sink: sink)

        #expect(script.requestCount == 2)
        #expect(sink.continuations.count == 1)
        #expect(result.stopReason == .completed)
    }

    @Test("continuation disabled leaves a timed-out run exactly as it settled")
    func disabledSendsNothing() async throws {
        let settings = GatewayContinuationSettings(enabled: false, maxAttempts: 10, message: "Continue.")
        let script = GatewayScript([.timeoutStatus(504)])
        let harness = try makeHarness(script, continuation: settings, prefix: "off")
        let sink = NoticeRecorder()

        let result = try await harness.run(prompt: "hello", sink: sink)

        #expect(script.requestCount == 1)
        #expect(sink.continuations.isEmpty)
        #expect(result.failure != nil)
    }

    @Test("a zero attempt budget is the same as disabled")
    func zeroAttemptsSendsNothing() async throws {
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 0, message: "Continue.")
        let script = GatewayScript([.timeoutStatus(504)])
        let harness = try makeHarness(script, continuation: settings, prefix: "zero")
        let sink = NoticeRecorder()

        _ = try await harness.run(prompt: "hello", sink: sink)

        #expect(script.requestCount == 1)
        #expect(sink.continuations.isEmpty)
    }

    @Test("every gateway timeout status the proxies use is continued")
    func everyTimeoutStatusIsContinued() async throws {
        let settings = GatewayContinuationSettings(enabled: true, maxAttempts: 1, message: "Continue.")
        for status in [408, 504, 522, 524] {
            let script = GatewayScript([.timeoutStatus(status), .answer("done")])
            let harness = try makeHarness(script, continuation: settings, prefix: "status-\(status)")
            let sink = NoticeRecorder()

            _ = try await harness.run(prompt: "hello", sink: sink)

            #expect(script.requestCount == 2, "status \(status) did not produce a continuation")
            #expect(sink.continuations.count == 1)
        }
    }

    // MARK: - The bound itself

    @Test("the attempt budget is clamped, so no configuration can produce an unbounded loop")
    func attemptBudgetIsClamped() {
        #expect(GatewayContinuationSettings.default.enabled)
        #expect(GatewayContinuationSettings.default.maxAttempts == 10)
        #expect(GatewayContinuationSettings.default.message == "Refer to previous context and continue.")
        #expect(GatewayContinuationSettings.default.effectiveMaxAttempts == 10)

        #expect(GatewayContinuationSettings(maxAttempts: Int.max).effectiveMaxAttempts
            == GatewayContinuationSettings.attemptHardCap)
        #expect(GatewayContinuationSettings(maxAttempts: -5).effectiveMaxAttempts == 0)
        #expect(GatewayContinuationSettings(enabled: false, maxAttempts: 10).effectiveMaxAttempts == 0)
        // The premise of the first assertion: the cap is genuinely below Int.max.
        #expect(GatewayContinuationSettings.attemptHardCap < Int.max)
    }

    @Test("the settings survive a JSON round trip unchanged")
    func settingsRoundTrip() throws {
        let settings = GatewayContinuationSettings(enabled: false, maxAttempts: 4, message: "carry on")
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GatewayContinuationSettings.self, from: data) == settings)
    }

    /// A hand-edited settings file decodes straight past the initializer, which is
    /// exactly why the clamp lives on the read rather than on the write.
    @Test("a decoded attempt count over the hard cap is still clamped")
    func decodedAttemptsAreClamped() throws {
        let json = Data(#"{"enabled":true,"maxAttempts":1000000,"message":"go"}"#.utf8)
        let decoded = try JSONDecoder().decode(GatewayContinuationSettings.self, from: json)
        #expect(decoded.maxAttempts == 1_000_000, "the stored value is preserved…")
        #expect(decoded.effectiveMaxAttempts == GatewayContinuationSettings.attemptHardCap, "…but not honored")
    }
}
