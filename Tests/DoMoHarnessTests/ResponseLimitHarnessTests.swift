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

/// A model whose reply to each request is scripted, recording the context it was
/// asked with so a test can compare what the model saw against what was stored.
private final class LimitScript: Sendable {
    enum Reply: Sendable {
        /// A normal completed turn with `characters` characters of text.
        case answer(characters: Int)
        /// A turn the user interrupted, carrying the partial text it had
        /// produced — the case that makes the "a cancelled turn is not evidence"
        /// rule observable rather than vacuous.
        case aborted(characters: Int)
        /// The gateway timed out.
        case gatewayTimeout
    }

    private let replies: [Reply]
    private let requests = Mutex<[[Message]]>([])

    init(_ replies: [Reply]) { self.replies = replies }

    var requestContexts: [[Message]] { requests.withLock { $0 } }

    func fn() -> AgentStreamFn {
        { [self] context in
            let index = requests.withLock { recorded -> Int in
                recorded.append(context.messages)
                return recorded.count - 1
            }
            switch replies[min(index, replies.count - 1)] {
            case .answer(let characters):
                return Self.terminal(
                    AssistantMessage(
                        content: [.text(String(repeating: "x", count: characters))],
                        model: "test-model",
                        stopReason: .stop
                    )
                )
            case .aborted(let characters):
                return Self.terminal(
                    AssistantMessage(
                        content: [.text(String(repeating: "x", count: characters))],
                        model: "test-model",
                        stopReason: .aborted,
                        errorMessage: "Request was aborted"
                    )
                )
            case .gatewayTimeout:
                return AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: DoMoError(.provider(status: 504, isRetryable: true), "Gateway Time-out")
                    )
                }
            }
        }
    }

    private static func terminal(_ message: AssistantMessage) -> AsyncThrowingStream<AssemblyEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.start(AssistantSnapshot(model: message.model)))
            continuation.yield(message.stopReason == .stop ? .done(message) : .failed(message))
            continuation.finish()
        }
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

@Suite("Response limit in the harness")
struct ResponseLimitHarnessTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-limit-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private func makeHarness(
        _ script: LimitScript,
        controller: ResponseLimitController?,
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
                responseLimit: controller,
                // Off throughout this suite: a gateway timeout here is being used
                // as evidence about the limit, and letting the continuation loop
                // answer it would make the recorded outcome the continuation's
                // rather than the probe's.
                gatewayContinuation: GatewayContinuationSettings(enabled: false)
            )
        )
    }

    private func controller(_ settings: ResponseLimitSettings) -> ResponseLimitController {
        ResponseLimitController(settings: settings, store: InMemoryResponseLimitStore())
    }

    /// What `decorate` produces for `text` on a controller in its initial state.
    ///
    /// Read off a second, untouched controller rather than hard-coded, so this
    /// suite asserts that the harness persists *exactly what the policy renders*
    /// without also restating the policy's own formatting — which
    /// `ResponseLimitTests` owns.
    private func decoration(of text: String, settings: ResponseLimitSettings) async -> String {
        await controller(settings).decorate(text, model: "test-model").text
    }

    private func persistedUserMessages(of path: FilePath) throws -> [UserMessage] {
        try JSONLSessionStore.open(path: path).readEntries().compactMap { entry in
            guard case .message(.user(let user)) = entry.payload else { return nil }
            return user
        }
    }

    // MARK: - What is stored is what was sent

    @Test("the decorated prompt is what reaches the model AND what reaches the session file")
    func decoratedPromptIsPersisted() async throws {
        let settings = ResponseLimitSettings.default
        let expected = await decoration(of: "hello", settings: settings)
        #expect(expected != "hello", "the premise: a default-configured limit changes the prompt")
        #expect(expected.hasPrefix("hello"), "the user's own words must survive in front")

        let script = LimitScript([.answer(characters: 12)])
        let harness = try makeHarness(script, controller: controller(settings), prefix: "persist")

        _ = try await harness.run(prompt: "hello")

        let sent = script.requestContexts
        #expect(sent.count == 1)
        guard let lastSent = sent.first?.last, case .user(let asked) = lastSent else {
            Issue.record("the model was not asked with a user message")
            return
        }
        #expect(asked.text == expected)

        let stored = try persistedUserMessages(of: await harness.sessionFilePath)
        #expect(stored.map(\.text) == [expected])
        #expect(stored.map(\.text) == [asked.text], "the wire and the file must not disagree")
    }

    @Test("no controller leaves the prompt exactly as the caller wrote it")
    func undecoratedWithoutAController() async throws {
        let script = LimitScript([.answer(characters: 12)])
        let harness = try makeHarness(script, controller: nil, prefix: "none")

        _ = try await harness.run(prompt: "hello")

        let stored = try persistedUserMessages(of: await harness.sessionFilePath)
        #expect(stored.map(\.text) == ["hello"])
    }

    // MARK: - Which message, and which block inside it

    @Test("only the last user message is decorated; earlier ones are history")
    func decoratesTheLastUserMessage() async throws {
        let settings = ResponseLimitSettings.default
        let expected = await decoration(of: "newest", settings: settings)
        let script = LimitScript([.answer(characters: 12)])
        let harness = try makeHarness(script, controller: controller(settings), prefix: "last")

        _ = try await harness.run(messages: [
            .user(UserMessage(content: [.text("older")])),
            .user(UserMessage(content: [.text("newest")])),
        ])

        let stored = try persistedUserMessages(of: await harness.sessionFilePath)
        #expect(stored.map(\.text) == ["older", expected])
    }

    @Test("images and earlier text blocks survive; the last text block is the one rewritten")
    func imagesSurviveDecoration() async throws {
        let settings = ResponseLimitSettings.default
        let expected = await decoration(of: "caption", settings: settings)
        let image = ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let script = LimitScript([.answer(characters: 12)])
        let harness = try makeHarness(script, controller: controller(settings), prefix: "image")

        _ = try await harness.run(messages: [
            .user(UserMessage(content: [.text("preamble"), .image(image), .text("caption")]))
        ])

        let stored = try persistedUserMessages(of: await harness.sessionFilePath)
        #expect(stored.count == 1)
        #expect(stored.first?.content.count == 3)
        #expect(stored.first?.content[0].textBlock?.text == "preamble")
        #expect(stored.first?.content[1].imageBlock == image)
        #expect(stored.first?.content[2].textBlock?.text == expected)
    }

    @Test("an image-only prompt gains a text block rather than escaping the limit")
    func imageOnlyPromptGainsTheLimit() async throws {
        let settings = ResponseLimitSettings.default
        let expected = await decoration(of: "", settings: settings)
        let image = ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let script = LimitScript([.answer(characters: 12)])
        let harness = try makeHarness(script, controller: controller(settings), prefix: "imageonly")

        _ = try await harness.run(messages: [.user(UserMessage(content: [.image(image)]))])

        let stored = try persistedUserMessages(of: await harness.sessionFilePath)
        #expect(stored.count == 1)
        #expect(stored.first?.content.count == 2)
        #expect(stored.first?.content[0].imageBlock == image, "the image must stay first and intact")
        #expect(stored.first?.content[1].textBlock?.text == expected)
    }

    // MARK: - What the settled run teaches

    /// The pair is the point: identical evidence — 600 characters of assistant
    /// text against a probe offered at 550 — moves the ceiling when the turn
    /// completed and must move nothing when the turn was interrupted. Drop the
    /// abort guard and the first half of this test starts reporting 550.
    @Test("an interrupted run teaches the ceiling nothing; the same text from a completed run teaches it")
    func abortedRunsAreNotEvidence() async throws {
        var settings = ResponseLimitSettings.default
        settings.probeEvery = 1

        let interrupted = controller(settings)
        let abortedHarness = try makeHarness(
            LimitScript([.aborted(characters: 600)]),
            controller: interrupted,
            prefix: "abort"
        )
        let abortedResult = try await abortedHarness.run(prompt: "write it")
        let afterAbort = await interrupted.currentThreshold(model: "test-model")
        #expect(abortedResult.stopReason == .aborted, "the premise: this run really was interrupted")
        #expect(
            afterAbort == settings.thresholdCharacters,
            "an interrupted turn is not evidence that the gateway delivered anything"
        )

        let completed = controller(settings)
        let completedHarness = try makeHarness(
            LimitScript([.answer(characters: 600)]),
            controller: completed,
            prefix: "ok"
        )
        let completedResult = try await completedHarness.run(prompt: "write it")
        let afterSuccess = await completed.currentThreshold(model: "test-model")
        #expect(completedResult.stopReason == .completed)
        #expect(
            afterSuccess > settings.thresholdCharacters,
            "a successful probe must raise the learned ceiling"
        )
    }

    /// A failed probe has to be *recorded*, which a "threshold did not move"
    /// assertion alone cannot show — not moving is also what happens when
    /// nothing was recorded at all. So the failure is read back through the
    /// probe that follows it: the search now has an upper bound, so the next
    /// probe lands between the ceiling and the point that failed rather than
    /// back on it.
    @Test("a failed probe bounds the search, and the next probe lands below the point that failed")
    func failedProbeIsRecorded() async throws {
        var settings = ResponseLimitSettings.default
        settings.probeEvery = 1

        let learner = controller(settings)
        let failing = try makeHarness(
            LimitScript([.gatewayTimeout]),
            controller: learner,
            prefix: "fail"
        )
        let failed = try await failing.run(prompt: "write it")
        let afterFailure = await learner.currentThreshold(model: "test-model")
        #expect(failed.stopReason == .errored, "the premise: the probe really failed")
        #expect(
            afterFailure == settings.thresholdCharacters,
            "a failed probe bounds the search from above; it does not move the known-good ceiling"
        )

        // The same controller, one gateway: the second turn's probe must respect
        // what the first turn learned.
        let recovering = try makeHarness(
            LimitScript([.answer(characters: 600)]),
            controller: learner,
            prefix: "fail-2"
        )
        _ = try await recovering.run(prompt: "write it again")
        let afterRecovery = await learner.currentThreshold(model: "test-model")

        let firstProbe = settings.thresholdCharacters
            + (settings.thresholdCharacters * settings.jumpPercentage) / 100
        #expect(afterRecovery > settings.thresholdCharacters, "the successful probe still raised the ceiling")
        #expect(
            afterRecovery < firstProbe,
            "the second probe repeated the limit that had just failed instead of halving toward it"
        )
    }

    /// A short answer is not a refusal. The model may simply have had little to
    /// say, and treating that as "the gateway truncated us" would walk the
    /// ceiling down over a conversation of one-line replies.
    @Test("a short successful answer leaves the ceiling where it was")
    func shortAnswersAreInconclusive() async throws {
        var settings = ResponseLimitSettings.default
        settings.probeEvery = 1

        let learner = controller(settings)
        let harness = try makeHarness(
            LimitScript([.answer(characters: 12)]),
            controller: learner,
            prefix: "short"
        )

        _ = try await harness.run(prompt: "write it")
        let threshold = await learner.currentThreshold(model: "test-model")

        #expect(threshold == settings.thresholdCharacters)
    }
}
