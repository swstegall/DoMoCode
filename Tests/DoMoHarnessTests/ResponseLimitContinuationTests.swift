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

/// A gateway scripted per request: the Nth model request gets the Nth reply, and
/// the last reply repeats forever so a capped loop can be driven against a
/// gateway that never recovers.
private final class ContinuationScript: Sendable {
    enum Reply: Sendable {
        /// A completed turn carrying `characters` characters of assistant text.
        case answer(characters: Int)
        /// The proxy in front of the model gave up on time.
        case gatewayTimeout
        /// A failure that has nothing to do with how long the answer was.
        case fatal(DoMoError.Kind, String)
    }

    private let replies: [Reply]
    private let requests = Mutex<[[Message]]>([])

    init(_ replies: [Reply]) { self.replies = replies }

    /// The context of each request, in request order.
    var requestContexts: [[Message]] { requests.withLock { $0 } }
    var requestCount: Int { requests.withLock { $0.count } }

    func fn() -> AgentStreamFn {
        { [self] context in
            let index = requests.withLock { recorded -> Int in
                recorded.append(context.messages)
                return recorded.count - 1
            }
            switch replies[min(index, replies.count - 1)] {
            case .answer(let characters):
                let message = AssistantMessage(
                    content: [.text(String(repeating: "x", count: characters))],
                    model: "test-model",
                    stopReason: .stop
                )
                return AsyncThrowingStream { continuation in
                    continuation.yield(.start(AssistantSnapshot(model: message.model)))
                    continuation.yield(.done(message))
                    continuation.finish()
                }
            case .gatewayTimeout:
                return Self.throwing(
                    DoMoError(.provider(status: 504, isRetryable: true), "Gateway Time-out")
                )
            case .fatal(let kind, let message):
                return Self.throwing(DoMoError(kind, message))
            }
        }
    }

    private static func throwing(_ error: DoMoError) -> AsyncThrowingStream<AssemblyEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
    }
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

/// What the continuation loop, the evidence classifier and the steering wrapper
/// each have to get right for the learned ceiling to mean anything.
///
/// The three failures these pin are not independent bugs that happened to share a
/// file. They are the same mistake at three points: treating a result that
/// describes some *other* request as though it described the decorated one.
@Suite("Response limit across the continuation and steering seams")
struct ResponseLimitContinuationTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-limit-continue-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private func makeHarness(
        _ script: ContinuationScript,
        controller: ResponseLimitController?,
        continuation: GatewayContinuationSettings,
        steeringBox: SteeringBox? = nil,
        prefix: String
    ) throws -> AgentHarness {
        try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: AgentHarness.Configuration(
                systemPrompt: "You are a test.",
                model: "test-model",
                streamFn: script.fn(),
                // Off throughout: compaction would introduce a summarization
                // request this suite's scripts do not account for, and the
                // overflow-recovery branch is not what is under test here.
                compaction: CompactionSettings(enabled: false),
                now: { self.fixedDate },
                entryIDFactory: SequentialIDs(prefix: prefix).factory(),
                steeringBox: steeringBox,
                responseLimit: controller,
                gatewayContinuation: continuation
            )
        )
    }

    private func controller(_ settings: ResponseLimitSettings) -> ResponseLimitController {
        ResponseLimitController(settings: settings, store: InMemoryResponseLimitStore())
    }

    /// A settings value whose limit sentence is trivially countable in a string.
    ///
    /// The shipped template renders as prose, and prose is the wrong instrument
    /// for "exactly one": a test that scanned for "Respond in less than" would
    /// also match a user who wrote that sentence themselves.
    private func markedSettings(probeEvery: Int) -> ResponseLimitSettings {
        var settings = ResponseLimitSettings.default
        settings.probeEvery = probeEvery
        settings.template = "LIMIT={limit}"
        return settings
    }

    private func markerCount(in text: String) -> Int {
        text.components(separatedBy: "LIMIT=").count - 1
    }

    private func persistedUserTexts(of path: FilePath) throws -> [String] {
        try JSONLSessionStore.open(path: path).readEntries().compactMap { entry in
            guard case .message(.user(let user)) = entry.payload else { return nil }
            return user.text
        }
    }

    // MARK: - The continuation must not launder a refusal into a delivery

    /// The bug this suite exists for.
    ///
    /// A probe at 550 times out. The continuation re-asks with the harness's own
    /// undecorated prompt — no limit sentence on it at all — and *that* request
    /// returns 4000 characters. Reading the merged result made the run look like a
    /// probe that had delivered 4000 characters, so the ceiling was promoted to
    /// 550: the exact number the gateway had just refused. A promotion is only
    /// undone by fresh failures at the new height, so the ratchet went up and
    /// stayed there.
    @Test("a probe that timed out is not promoted by the continuation that rescued the run")
    func continuationDoesNotPromoteARefusedProbe() async throws {
        let settings = markedSettings(probeEvery: 1)
        let learner = controller(settings)
        let script = ContinuationScript([.gatewayTimeout, .answer(characters: 4000)])
        let harness = try makeHarness(
            script,
            controller: learner,
            continuation: GatewayContinuationSettings(enabled: true, maxAttempts: 3, message: "Continue."),
            prefix: "launder"
        )

        let result = try await harness.run(prompt: "write the thing")

        // The premise, without which the assertion below is vacuous: the run
        // really did time out, really did continue, and really did end well.
        #expect(script.requestCount == 2, "the probe failed and exactly one continuation answered it")
        #expect(result.stopReason == .completed)
        #expect(result.failure == nil, "the continuation rescued the run")
        #expect(
            ResponseLimitContinuationTests.longestAssistantText(in: result.messages) == 4000,
            "the merged result really does contain a very long answer — that is the temptation"
        )

        let afterRun = await learner.currentThreshold(model: "test-model")
        #expect(
            afterRun == settings.thresholdCharacters,
            "the continuation's answer was to an undecorated prompt and cannot promote the probe"
        )

        // Not merely "unchanged": the probe has to have been recorded as a
        // refusal, which only the *next* probe can show. A second successful turn
        // on the same controller must land between the ceiling and the point that
        // failed rather than back on it.
        let recovering = try makeHarness(
            ContinuationScript([.answer(characters: 4000)]),
            controller: learner,
            continuation: GatewayContinuationSettings(enabled: true, maxAttempts: 3, message: "Continue."),
            prefix: "launder-2"
        )
        _ = try await recovering.run(prompt: "write it again")
        let afterRecovery = await learner.currentThreshold(model: "test-model")

        let refusedProbe = settings.thresholdCharacters
            + (settings.thresholdCharacters * settings.jumpPercentage) / 100
        #expect(afterRecovery > settings.thresholdCharacters, "a delivered probe still raises the ceiling")
        #expect(
            afterRecovery < refusedProbe,
            "the second probe repeated the limit the gateway had just refused"
        )
    }

    /// The control for the test above. If recording were simply broken — a ticket
    /// dropped, an outcome never fed back — that test would pass while the feature
    /// learned nothing at all. Identical script minus the timeout, and the ceiling
    /// must move.
    @Test("a probe that needed no continuation still promotes the ceiling")
    func anUninterruptedProbeStillLearns() async throws {
        let settings = markedSettings(probeEvery: 1)
        let learner = controller(settings)
        let script = ContinuationScript([.answer(characters: 4000)])
        let harness = try makeHarness(
            script,
            controller: learner,
            continuation: GatewayContinuationSettings(enabled: true, maxAttempts: 3, message: "Continue."),
            prefix: "control"
        )

        let result = try await harness.run(prompt: "write the thing")

        #expect(script.requestCount == 1, "nothing failed, so nothing was continued")
        #expect(result.stopReason == .completed)
        let afterRun = await learner.currentThreshold(model: "test-model")
        #expect(
            afterRun > settings.thresholdCharacters,
            "a delivered probe is exactly the evidence the ceiling is supposed to move on"
        )
    }

    // MARK: - Classifying what the failure was evidence OF

    /// A refused credential says nothing about how many characters the gateway
    /// would have returned. Two of them in a row used to be read as "the ceiling
    /// moved underneath us" and backed the threshold down 10% — permanently,
    /// because the back-off also wrote the old threshold down as a bad point.
    ///
    /// The paired half is what makes this non-vacuous: two *timeouts* in the same
    /// shape must still back the threshold off, so the assertion above is about
    /// the classification and not about the mechanism being dead.
    @Test("two authentication failures teach nothing; two gateway timeouts still back the ceiling off")
    func authenticationFailuresAreNotEvidence() async throws {
        // No probes: a probe failure takes a different branch, and the branch
        // under test here is the consecutive-failure back-off on ordinary prompts.
        let settings = markedSettings(probeEvery: 1_000)
        let continuation = GatewayContinuationSettings(enabled: false, maxAttempts: 0, message: "Continue.")

        let unrelated = controller(settings)
        for attempt in 0..<2 {
            let harness = try makeHarness(
                ContinuationScript([.fatal(.authentication, "invalid api key")]),
                controller: unrelated,
                continuation: continuation,
                prefix: "auth-\(attempt)"
            )
            let result = try await harness.run(prompt: "hello")
            #expect(result.stopReason == .errored, "the premise: attempt \(attempt) really failed")
        }
        let afterAuthFailures = await unrelated.currentThreshold(model: "test-model")
        #expect(
            afterAuthFailures == settings.thresholdCharacters,
            "a rejected credential is not evidence about length and must move nothing"
        )

        let refusing = controller(settings)
        for attempt in 0..<2 {
            let harness = try makeHarness(
                ContinuationScript([.gatewayTimeout]),
                controller: refusing,
                continuation: continuation,
                prefix: "timeout-\(attempt)"
            )
            let result = try await harness.run(prompt: "hello")
            #expect(result.stopReason == .errored, "the premise: attempt \(attempt) really failed")
        }
        let afterTimeouts = await refusing.currentThreshold(model: "test-model")
        #expect(
            afterTimeouts < settings.thresholdCharacters,
            "the back-off itself still works — only the classification of the failure changed"
        )
        #expect(
            afterTimeouts >= settings.minimumThreshold,
            "and it never falls through the floor"
        )
    }

    /// Every failure that could plausibly be the undocumented length cap, and
    /// every failure that plainly is not, driven through the whole harness rather
    /// than asserted against the classifier directly — the classifier is private,
    /// and what matters is which of them reaches the learned state.
    @Test("only the length-plausible failures bound the search")
    func onlyLengthPlausibleFailuresCount() async throws {
        let settings = markedSettings(probeEvery: 1_000)
        let continuation = GatewayContinuationSettings(enabled: false, maxAttempts: 0, message: "Continue.")

        // kind, whether two in a row should move the threshold
        let cases: [(String, DoMoError.Kind, String, Bool)] = [
            ("connection refused", .transport, "connection refused", false),
            ("rate limit", .rateLimit(retryAfter: nil), "slow down", false),
            ("quota", .quotaExhausted, "monthly usage limit reached", false),
            ("configuration", .configuration, "no model selected", false),
            ("client error", .provider(status: 400, isRetryable: false), "invalid request", false),
            ("truncated response", .malformedResponse, "unterminated JSON", true),
            ("overloaded proxy", .provider(status: 503, isRetryable: true), "service unavailable", true),
            ("read timeout", .transport, "the request timed out after 90s", true),
        ]

        for (label, kind, message, shouldMove) in cases {
            let learner = controller(settings)
            for attempt in 0..<2 {
                let harness = try makeHarness(
                    ContinuationScript([.fatal(kind, message)]),
                    controller: learner,
                    continuation: continuation,
                    prefix: "kind-\(label)-\(attempt)"
                )
                _ = try await harness.run(prompt: "hello")
            }
            let threshold = await learner.currentThreshold(model: "test-model")
            if shouldMove {
                #expect(threshold < settings.thresholdCharacters, "\(label) should have bounded the search")
            } else {
                #expect(threshold == settings.thresholdCharacters, "\(label) is not evidence about length")
            }
        }
    }

    // MARK: - Steering carries the limit too

    /// A message typed while a run is in flight never passes through
    /// ``AgentHarness/run(messages:)`` — it is delivered at a turn boundary — so
    /// before the wrapper it was the one prompt on the wire with no limit on it.
    @Test("a steered message reaches the model carrying exactly one limit sentence")
    func steeringIsDecorated() async throws {
        let settings = markedSettings(probeEvery: 4)
        let box = SteeringBox(mode: .all)
        box.enqueue(.user(UserMessage(content: [.text("actually, do the other thing")])))

        let script = ContinuationScript([.answer(characters: 12)])
        let harness = try makeHarness(
            script,
            controller: controller(settings),
            continuation: GatewayContinuationSettings(enabled: false, maxAttempts: 0, message: "Continue."),
            steeringBox: box,
            prefix: "steer"
        )

        _ = try await harness.run(prompt: "write the thing")

        #expect(script.requestCount == 1)
        let asked = script.requestContexts.first?.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.text
        } ?? []
        #expect(asked.count == 2, "the prompt and the steered message both reached the model")
        #expect(asked.first == "write the thing\n\nLIMIT=500")
        #expect(
            asked.last == "actually, do the other thing\n\nLIMIT=500",
            "the steered message keeps the user's words and gains the same sentence"
        )
        for text in asked {
            #expect(markerCount(in: text) == 1, "exactly one limit sentence, never two")
        }

        // What went on the wire is what the session file holds, so a resumed
        // conversation shows the model the same instruction it was given.
        let persisted = try persistedUserTexts(of: await harness.sessionFilePath)
        #expect(persisted == asked)
    }

    /// The idempotence guarantee has to survive the steering path too: a message
    /// restored from a queue that already carries last turn's sentence must not
    /// arrive with two.
    @Test("a steered message that already carries a limit sentence is not given a second one")
    func steeringDecorationIsIdempotent() async throws {
        let settings = markedSettings(probeEvery: 4)
        let box = SteeringBox(mode: .all)
        box.enqueue(.user(UserMessage(content: [.text("resubmitted\n\nLIMIT=123")])))

        let script = ContinuationScript([.answer(characters: 12)])
        let harness = try makeHarness(
            script,
            controller: controller(settings),
            continuation: GatewayContinuationSettings(enabled: false, maxAttempts: 0, message: "Continue."),
            steeringBox: box,
            prefix: "steer-idem"
        )

        _ = try await harness.run(prompt: "write the thing")

        let steered = script.requestContexts.first?.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.text
        }.last
        #expect(steered == "resubmitted\n\nLIMIT=500")
        #expect(markerCount(in: steered ?? "") == 1)
    }

    /// Without a controller nothing decorates anything — the steering wrapper must
    /// not become a second, always-on rewriter of the user's text.
    @Test("no controller leaves a steered message exactly as it was typed")
    func steeringIsUntouchedWithoutAController() async throws {
        let box = SteeringBox(mode: .all)
        box.enqueue(.user(UserMessage(content: [.text("no limit here")])))

        let script = ContinuationScript([.answer(characters: 12)])
        let harness = try makeHarness(
            script,
            controller: nil,
            continuation: GatewayContinuationSettings(enabled: false, maxAttempts: 0, message: "Continue."),
            steeringBox: box,
            prefix: "steer-off"
        )

        _ = try await harness.run(prompt: "write the thing")

        let persisted = try persistedUserTexts(of: await harness.sessionFilePath)
        #expect(persisted == ["write the thing", "no limit here"])
    }

    // MARK: - Helpers

    private static func longestAssistantText(in messages: [Message]) -> Int {
        messages.reduce(into: 0) { longest, message in
            guard case .assistant(let assistant) = message else { return }
            longest = max(longest, assistant.text.count)
        }
    }
}
