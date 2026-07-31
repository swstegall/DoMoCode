// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one shared stream factory, exercised against a real loopback gateway
// rather than a hand-built fake client — because the whole point of the factory
// is *which arguments reach the wire*, and only a real request can answer that.
// A test that stubbed `LiteLLMClient` would pass while `rates:` was dropped on
// the floor, which is exactly the class of bug this file exists to catch.
//
// `@testable` because the two factory functions are internal by design: all
// three call sites live inside DoMoCLI, and making them public would publish a
// seam nobody outside the module is meant to use.

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import DoMoCLI

// MARK: - Scripted SSE

/// One `chat/completions` answer: a single text block, a `stop` finish, and a
/// trailing usage-only frame (which is where token counts actually arrive on a
/// streamed request).
private func textTurnBody(
    text: String,
    responseModel: String = "mock-deployment",
    promptTokens: Int,
    completionTokens: Int
) -> String {
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    return """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"\(responseModel)","choices":[{"index":0,"delta":{"role":"assistant","content":"\(escaped)"},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":\(promptTokens),"completion_tokens":\(completionTokens),"total_tokens":\(promptTokens + completionTokens)}}

        data: [DONE]


        """
}

// MARK: - Recorders

/// Captures every response head the factory reported, from whatever task the
/// streaming client happened to deliver it on.
private final class MetadataRecorder: Sendable {
    private let storage = Mutex<[ResponseMetadata]>([])
    func record(_ metadata: ResponseMetadata) { storage.withLock { $0.append(metadata) } }
    var all: [ResponseMetadata] { storage.withLock { $0 } }
}

/// A stream function that answers every turn with one canned message and counts
/// how many times it was asked.
///
/// It stands in for ``PrintMode``'s stream seam, whose ``TurnCounter`` advances on
/// exactly this call and whose count is reported as the terminal `result` event's
/// `turns` field. Counting calls here is counting `turn_start`s there.
private final class CountingResponder: Sendable {
    private let counter = Mutex<Int>(0)
    private let message: AssistantMessage

    init(_ message: AssistantMessage) { self.message = message }

    var calls: Int { counter.withLock { $0 } }

    func fn() -> AgentStreamFn {
        { [self] _ in
            counter.withLock { $0 += 1 }
            return Self.terminalStream(message)
        }
    }

    /// A terminal-only assembly stream for one canned assistant message, matching
    /// the shape `DoMoHarness`'s own tests use.
    private static func terminalStream(
        _ message: AssistantMessage
    ) -> AsyncThrowingStream<AssemblyEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.start(AssistantSnapshot(model: message.model)))
            continuation.yield(.done(message))
            continuation.finish()
        }
    }
}

/// Counts summarization calls and answers with a fixed summary.
private final class SummarizerCounter: Sendable {
    private let counter = Mutex<Int>(0)
    var calls: Int { counter.withLock { $0 } }

    func fn() -> Summarizer {
        { [self] _ in
            counter.withLock { $0 += 1 }
            return SummarizerResult(text: "SUMMARY", usage: Usage(input: 7, output: 3))
        }
    }
}

// MARK: - Helpers

/// How many non-overlapping times `needle` appears in `haystack`.
private func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}

/// The body of the first completion request the gateway saw. `GET /models` is
/// never issued on this path, but filtering on the method keeps the assertion
/// honest if that ever changes.
private func firstCompletionBody(_ gateway: MockGateway) throws -> String {
    try #require(gateway.requests.first(where: { $0.method == "POST" })?.body)
}

private func makeClient(_ gateway: MockGateway) -> LiteLLMClient {
    LiteLLMClient(
        configuration: LiteLLMClient.Configuration(
            baseURL: gateway.baseURL,
            apiKey: "sk-test",
            // No retries: every scripted answer here is either a success or a
            // terminal refusal, and a retry budget would only add wall time.
            maxRetries: 0,
            maxPreConnectRetries: 0
        )
    )
}

private func drainTerminal(
    _ stream: AsyncThrowingStream<AssemblyEvent, any Error>
) async throws -> AssistantMessage? {
    var terminal: AssistantMessage?
    for try await event in stream {
        if let message = event.terminalMessage { terminal = message }
    }
    return terminal
}

private func makeSessionDirectory() -> FilePath {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("domocode-factory-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return FilePath(base.path)
}

// MARK: - Tests

@Suite(.serialized)
struct ModelStreamFactoryTests {

    // MARK: makeStreamFn

    @Test("the turn stream sends the runtime's alias, reasoning effort and cost rates")
    func streamFnCarriesTheWholeRuntime() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [textTurnBody(text: "ok", promptTokens: 1000, completionTokens: 500)]
        )
        gateway.start()
        defer { gateway.stop() }

        let runtime = ModelRuntime(
            model: "tiny-model",
            reasoningEffort: .high,
            rates: ModelCostRates(input: 3, output: 15),
            contextWindow: 4096
        )
        let streamFn = makeStreamFn(client: makeClient(gateway), runtime: runtime)
        let terminal = try await drainTerminal(streamFn(Context(messages: [.user("hi")])))

        let message = try #require(terminal)
        #expect(message.text == "ok")

        let body = try firstCompletionBody(gateway)
        #expect(body.contains("\"model\":\"tiny-model\""), "request body: \(body)")
        // The alias-level reasoning effort has to survive the hop; a factory that
        // forgets it silently downgrades a reasoning model to its default effort.
        #expect(body.contains("\"reasoning_effort\":\"high\""), "request body: \(body)")

        // 1000 input at $3/M plus 500 output at $15/M. Zero if `rates` never
        // reached `streamCompletion` — which is the whole failure mode: a session
        // that reports every turn as free.
        #expect(message.usage.input == 1000)
        #expect(message.usage.output == 500)
        #expect(message.usage.cost.total == Decimal(string: "0.0105"))
    }

    @Test("a turn with no cost rates reports no cost, rather than a made-up one")
    func streamFnWithoutRatesReportsZeroCost() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [textTurnBody(text: "ok", promptTokens: 1000, completionTokens: 500)]
        )
        gateway.start()
        defer { gateway.stop() }

        let streamFn = makeStreamFn(client: makeClient(gateway), runtime: ModelRuntime(model: "tiny-model"))
        let terminal = try await drainTerminal(streamFn(Context(messages: [.user("hi")])))
        let message = try #require(terminal)

        // The control for the assertion above: the tokens are identical, so a cost
        // of zero here is the rates argument doing something rather than the
        // arithmetic happening to land on the same number either way.
        #expect(message.usage.input == 1000)
        #expect(message.usage.cost.total == 0)
        #expect(message.usage.effectiveCostTotal == 0)

        let body = try firstCompletionBody(gateway)
        #expect(!body.contains("reasoning_effort"), "request body: \(body)")
    }

    @Test("the turn stream reports the response head to its caller")
    func streamFnForwardsTheResponseHead() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [textTurnBody(text: "ok", promptTokens: 10, completionTokens: 2)]
        )
        gateway.start()
        defer { gateway.stop() }

        let recorder = MetadataRecorder()
        let streamFn = makeStreamFn(
            client: makeClient(gateway),
            runtime: ModelRuntime(model: "tiny-model"),
            onResponse: { recorder.record($0) }
        )
        _ = try await drainTerminal(streamFn(Context(messages: [.user("hi")])))

        // This callback is the ONLY place `attemptedFallbacks` is visible, so a
        // surface that cannot see it cannot honour the README's "say so rather
        // than lie" requirement. The gateway stamps a call id it can be recognised
        // by.
        let metadata = try #require(recorder.all.first)
        #expect(metadata.status == 200)
        #expect(metadata.callID == "mock-call-0")
        #expect(metadata.modelID == "mock-deployment")
    }

    // MARK: makeSummarizer

    @Test("the summarizer sends the shared compaction prompts to the named model")
    func summarizerSendsSharedPrompts() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [textTurnBody(text: "a summary", promptTokens: 1000, completionTokens: 500)]
        )
        gateway.start()
        defer { gateway.stop() }

        let summarize = makeSummarizer(
            client: makeClient(gateway),
            model: "small-model",
            runtime: ModelRuntime(
                model: "not-the-wire-model",
                reasoningEffort: .low,
                rates: ModelCostRates(input: 1, output: 2)
            )
        )
        let result = try await summarize([.user("the older history")])

        #expect(result.text == "a summary")
        // Without this the compaction entry's `usage` is nil forever, and a
        // session's cost silently excludes the calls it worked hardest on.
        let usage = try #require(result.usage)
        #expect(usage.input == 1000)
        #expect(usage.output == 500)
        #expect(usage.cost.total == Decimal(string: "0.002"))

        let body = try firstCompletionBody(gateway)
        // `model:` decides the request, not `runtime.model`.
        #expect(body.contains("\"model\":\"small-model\""), "request body: \(body)")
        #expect(!body.contains("not-the-wire-model"), "request body: \(body)")
        #expect(body.contains("\"reasoning_effort\":\"low\""), "request body: \(body)")
        // The prompts are referenced, not re-typed: if the harness's text and the
        // CLI's ever drift apart, this stops matching.
        #expect(body.contains(CompactionPrompts.system), "request body: \(body)")
        #expect(body.contains(CompactionPrompts.instruction), "request body: \(body)")
        #expect(body.contains("the older history"), "request body: \(body)")
    }

    @Test("the summarizer does not re-apply the prior-summary preamble")
    func summarizerDoesNotDoubleThePriorSummary() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [textTurnBody(text: "a summary", promptTokens: 10, completionTokens: 2)]
        )
        gateway.start()
        defer { gateway.stop() }

        let summarize = makeSummarizer(
            client: makeClient(gateway),
            model: "small-model",
            runtime: ModelRuntime(model: "small-model")
        )
        // `compact` prepends the preamble itself before calling a summarizer, so
        // this is exactly the message list a real compaction hands over. Adding it
        // again here would send the standing summary twice and bill for it twice.
        let preamble = CompactionPrompts.priorSummaryPreamble("THE EARLIER STORY")
        _ = try await summarize([.user(preamble), .user("what happened next")])

        let body = try firstCompletionBody(gateway)
        #expect(occurrences(of: "THE EARLIER STORY", in: body) == 1, "request body: \(body)")
        #expect(
            occurrences(of: "The following is the running summary", in: body) == 1,
            "request body: \(body)"
        )
    }

    @Test("a summarization the gateway refuses throws instead of summarizing to nothing")
    func summarizerThrowsOnRefusal() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [],
            refuseWith: (status: 401, reason: "Unauthorized", body: #"{"error":{"message":"no"}}"#)
        )
        gateway.start()
        defer { gateway.stop() }

        let summarize = makeSummarizer(
            client: makeClient(gateway),
            model: "small-model",
            runtime: ModelRuntime(model: "small-model")
        )
        // An empty or truncated "summary" would silently delete the conversation
        // it was supposed to preserve, so the failure has to escape.
        await #expect(throws: (any Error).self) {
            _ = try await summarize([.user("history")])
        }
    }

    @Test("a summarization that dies mid-stream throws rather than summarizing to the fragment")
    func summarizerThrowsOnAMidStreamFailure() async throws {
        // A committed 200 whose body turns into an error frame: the stream does not
        // throw — it ends on a `failed` terminal message carrying whatever text had
        // already arrived. Returning that fragment as the summary would replace the
        // conversation with three words of it, permanently, in the session file.
        let dyingBody = """
            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"half a summ"},"finish_reason":null}]}

            data: {"error":{"message":"upstream exploded","type":"server_error"}}

            data: [DONE]


            """
        let gateway = try MockGateway(chatCompletionBodies: [dyingBody])
        gateway.start()
        defer { gateway.stop() }

        let summarize = makeSummarizer(
            client: makeClient(gateway),
            model: "small-model",
            runtime: ModelRuntime(model: "small-model")
        )
        await #expect(throws: (any Error).self) {
            _ = try await summarize([.user("history")])
        }
    }

    // MARK: The turn-count defect a real summarizer fixes

    /// The mechanism, demonstrated before the fix is claimed.
    ///
    /// ``AgentHarness``'s built-in summarizer runs its request through
    /// `configuration.streamFn`. Under `-p` that IS ``PrintMode``'s stream seam —
    /// the one that emits `turn_start` and advances the ``TurnCounter`` whose value
    /// becomes the terminal `result` event's `turns` field. So a compaction adds a
    /// phantom turn to a run's reported turn count and a phantom `turn_start` to
    /// the JSON stream a script is reading.
    ///
    /// The counting stream function here stands in for that seam exactly: it is
    /// invoked once per turn and once more per compaction.
    @Test("with no summarizer, compaction re-enters the session's own stream function")
    func compactionThroughStreamFnInflatesTheTurnCount() async throws {
        let responder = CountingResponder(Self.compactableAssistant)
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: Self.compactingConfiguration(streamFn: responder.fn(), summarizer: nil)
        )

        for _ in 0..<3 { _ = try await harness.run(prompt: Self.turnPrompt) }

        // Asserted first: if compaction never fired, the call count below would be
        // three for the wrong reason and the test would prove nothing.
        let compactions = try Self.compactionCount(of: await harness.sessionFilePath)
        #expect(compactions == 1)
        // Three turns were asked for. Four requests were made, and the fourth is
        // the one the `turns` field lies about.
        #expect(responder.calls == 4)
    }

    @Test("an installed summarizer keeps compaction off the session's stream function")
    func installedSummarizerLeavesTheTurnCountHonest() async throws {
        let responder = CountingResponder(Self.compactableAssistant)
        let spy = SummarizerCounter()
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: Self.compactingConfiguration(streamFn: responder.fn(), summarizer: spy.fn())
        )

        for _ in 0..<3 { _ = try await harness.run(prompt: Self.turnPrompt) }

        // Same compaction, same three turns — but the summarization went somewhere
        // else, so the count a surface reports is the count the user asked for.
        let compactions = try Self.compactionCount(of: await harness.sessionFilePath)
        #expect(compactions == 1)
        #expect(spy.calls == 1)
        #expect(responder.calls == 3)
    }

    // MARK: Compaction fixtures

    /// A ~10-token answer whose reported usage sits well above the window below,
    /// so the pre-turn estimate crosses the compaction threshold.
    private static let compactableAssistant = AssistantMessage(
        content: [.text(String(repeating: "a", count: 40))],
        model: "test-model",
        usage: Usage(input: 5000),
        stopReason: .stop
    )

    /// A ~10-token prompt, so the retained-tail budget below cuts between the
    /// two user turns rather than swallowing everything.
    private static let turnPrompt = String(repeating: "b", count: 40)

    private static func compactingConfiguration(
        streamFn: @escaping AgentStreamFn,
        summarizer: Summarizer?
    ) -> AgentHarness.Configuration {
        AgentHarness.Configuration(
            systemPrompt: "You are a test.",
            model: "test-model",
            streamFn: streamFn,
            summarizer: summarizer,
            // 5000 estimated tokens against a 1000-token window with a 100-token
            // reserve: the threshold is crossed from the second run onward, and the
            // 25-token recent budget leaves the first user/assistant pair to
            // summarize once a second user turn exists.
            compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
            contextWindow: 1000
        )
    }

    private static func compactionCount(of path: FilePath) throws -> Int {
        try JSONLSessionStore.open(path: path)
            .readEntries()
            .filter { entry in
                if case .compaction = entry.payload { return true }
                return false
            }
            .count
    }
}
