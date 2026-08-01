// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import HTTPTypes
import Synchronization
import Testing

import DoMoLLM

// MARK: - Fixtures

private func dec(_ text: String) -> Decimal {
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        preconditionFailure("test fixture \"\(text)\" is not a decimal")
    }
    return value
}

private func frame(_ payload: String) -> [UInt8] {
    Array("data: \(payload)\n\n".utf8)
}

private let done = Array("data: [DONE]\n\n".utf8)

private let contentPayload =
    #"{"id":"chatcmpl-c","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"hi"},"finish_reason":null}]}"#
private let stopPayload =
    #"{"id":"chatcmpl-c","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#

/// The trailing usage-only frame. Every cost test below includes it, because it
/// is the frame that assigns a whole fresh ``Usage`` — a test that omits it would
/// pass even if the reported cost were written somewhere the frame destroys.
private let usagePayload =
    #"{"id":"chatcmpl-c","model":"m","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}"#

private let errorPayload =
    #"{"error":{"message":"litellm.InternalServerError: upstream died","type":"api_error","code":"500"}}"#

private let nonStreamingBody = """
    {"id":"chatcmpl-n","object":"chat.completion","created":1753280420,"model":"m",\
    "choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],\
    "usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}
    """

/// 3 USD per million input, 15 per million output. Against the fixture's 10
/// prompt and 3 completion tokens that is 0.00003 + 0.000045 = 0.000075 — a
/// number chosen so it can be asserted literally rather than by re-running the
/// same arithmetic the implementation runs.
private let testRates = ModelCostRates(input: 3, output: 15)
private let rateDerivedTotal = "0.000075"

// MARK: - Test doubles

/// Replays one response: a head with the given headers, then the given body
/// chunks. Deliberately much smaller than the retry-exercising double next door
/// — nothing here needs a retry.
private final class CostTransport: StreamingTransport {
    private let status: Int
    private let headers: [(String, String)]
    private let chunks: [[UInt8]]

    init(status: Int = 200, headers: [(String, String)], chunks: [[UInt8]]) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
    }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        var head = HTTPResponse(status: .init(code: status))
        for (name, value) in headers {
            guard let fieldName = HTTPField.Name(name) else { continue }
            head.headerFields.append(HTTPField(name: fieldName, value: value))
        }
        let chunks = self.chunks
        let stream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return StreamingResponse(head: head, body: stream)
    }
}

private final class MetadataSink: Sendable {
    private let stored = Mutex<ResponseMetadata?>(nil)
    func set(_ value: ResponseMetadata) { stored.withLock { $0 = value } }
    var value: ResponseMetadata? { stored.withLock { $0 } }
}

private func costClient(_ transport: any StreamingTransport) -> LiteLLMClient {
    LiteLLMClient(
        configuration: LiteLLMClient.Configuration(baseURL: "http://localhost:4000/v1", apiKey: "sk-test"),
        transport: transport
    )
}

private func terminal(
    _ stream: AsyncThrowingStream<AssemblyEvent, any Error>
) async throws -> AssemblyEvent {
    var last: AssemblyEvent?
    for try await event in stream { last = event }
    return try #require(last)
}

// MARK: - Header parsing

@Suite("Cost — x-litellm-response-cost parsing")
struct ResponseCostParsingTests {

    @Test(
        "Whole-string numeric forms parse, including the exponent form LiteLLM emits",
        arguments: [
            ("0", "0"),
            ("0.001", "0.001"),
            ("1e-05", "0.00001"),
            ("1E-5", "0.00001"),
            ("2.5e2", "250"),
            ("+0.5", "0.5"),
            ("  0.25  ", "0.25"),
            ("12", "12"),
        ]
    )
    func accepted(raw: String, expected: String) {
        #expect(LiteLLMClient.parseResponseCost(raw) == dec(expected))
    }

    @Test(
        "Anything that is not a whole plain number is refused rather than prefix-parsed",
        arguments: [
            // A duplicated header comes back comma-joined from HTTPField
            // subscripting; taking the prefix would under-report the request.
            "0.001, 0.001",
            "1.5x",
            "$0.001",
            "1.5 USD",
            "",
            "   ",
            "abc",
            // Decimal's own grammar accepts these; this one must not, because
            // each is a sign the sender meant something other than a price.
            ".5",
            "5.",
            "1,5",
            "NaN",
            "Infinity",
            "1e",
            "1e+",
            // Negative: not a price.
            "-0.001",
            // Overflow: Decimal answers nil rather than saturating, and a
            // saturated price would be worse than none.
            "1e1000",
        ]
    )
    func refused(raw: String) {
        #expect(LiteLLMClient.parseResponseCost(raw) == nil, "expected \"\(raw)\" to be refused")
    }

    @Test("An absent header is nil, not zero")
    func absentHeader() {
        #expect(LiteLLMClient.parseResponseCost(nil) == nil)
    }

    @Test("Parsing does not go through Double")
    func exactness() throws {
        let parsed = try #require(LiteLLMClient.parseResponseCost("3.00003"))
        #expect(parsed == dec("3.00003"))
        // The value a Double round-trip would have produced instead. Asserting
        // inequality is what makes the line above mean something.
        #expect(parsed != Decimal(Double(3.00003)))
    }
}

// MARK: - Usage arithmetic and persistence

@Suite("Cost — Usage")
struct UsageCostTests {

    @Test("effectiveCostTotal falls back to the rate-derived total")
    func fallsBackToRates() {
        let usage = Usage(input: 10, output: 3).costed(at: testRates)
        #expect(usage.reportedCost == nil)
        #expect(usage.effectiveCostTotal == dec(rateDerivedTotal))
    }

    @Test("A reported cost beats the rate-derived total without erasing it")
    func reportedBeatsRates() {
        var usage = Usage(input: 10, output: 3).costed(at: testRates)
        usage.reportedCost = dec("0.000123")
        #expect(usage.effectiveCostTotal == dec("0.000123"))
        // The breakdown is untouched: a single total cannot honestly be split
        // four ways, so the derived one stays available beside it.
        #expect(usage.cost.total == dec(rateDerivedTotal))
        #expect(usage.cost.input == dec("0.00003"))
    }

    @Test("Adding two turns with no reported cost leaves the sum unreported")
    func foldNeither() {
        let left = Usage(input: 10, output: 3).costed(at: testRates)
        let right = Usage(input: 10, output: 3).costed(at: testRates)
        let sum = left + right
        #expect(sum.reportedCost == nil)
        #expect(sum.effectiveCostTotal == dec("0.00015"))
    }

    @Test("A reported cost on the left folds in the right's derived total")
    func foldLeftOnly() {
        var left = Usage(input: 10, output: 3).costed(at: testRates)
        left.reportedCost = dec("0.5")
        let right = Usage(input: 10, output: 3).costed(at: testRates)
        let sum = left + right
        // 0.5 + 0.000075. If the unreported side contributed zero instead, a
        // session would look cheaper the longer it ran.
        #expect(sum.reportedCost == dec("0.500075"))
        #expect(sum.effectiveCostTotal == dec("0.500075"))
    }

    @Test("A reported cost on the right folds in the left's derived total")
    func foldRightOnly() {
        let left = Usage(input: 10, output: 3).costed(at: testRates)
        var right = Usage(input: 10, output: 3).costed(at: testRates)
        right.reportedCost = dec("0.25")
        let sum = left + right
        #expect(sum.reportedCost == dec("0.250075"))
    }

    @Test("Two reported costs add, ignoring both derived totals")
    func foldBoth() {
        var left = Usage(input: 10, output: 3).costed(at: testRates)
        left.reportedCost = dec("0.5")
        var right = Usage(input: 10, output: 3).costed(at: testRates)
        right.reportedCost = dec("0.25")
        let sum = left + right
        #expect(sum.reportedCost == dec("0.75"))
        #expect(sum.effectiveCostTotal == dec("0.75"))
    }

    @Test("Token and reasoning folding is unchanged by the cost fold")
    func foldTokens() {
        var left = Usage(input: 10, output: 3, reasoning: 2)
        left.reportedCost = dec("0.5")
        let right = Usage(input: 1, output: 1)
        let sum = left + right
        #expect(sum.input == 11)
        #expect(sum.output == 4)
        #expect(sum.reasoning == 2)
    }

    @Test("A usage with no reported cost writes no key, so old session lines stay byte-identical")
    func encodesNothingWhenUnreported() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(Usage(input: 10, output: 3)), as: UTF8.self)
        #expect(!json.contains("reportedCost"))
        #expect(json.contains("\"input\":10"))
    }

    @Test("A reported cost round-trips through JSON exactly")
    func roundTrips() throws {
        var usage = Usage(input: 10, output: 3).costed(at: testRates)
        usage.reportedCost = dec("3.00003")
        let data = try JSONEncoder().encode(usage)
        #expect(String(decoding: data, as: UTF8.self).contains("reportedCost"))
        let decoded = try JSONDecoder().decode(Usage.self, from: data)
        #expect(decoded == usage)
        #expect(decoded.reportedCost == dec("3.00003"))
    }

    @Test("totalTokens saturates rather than trapping on numbers that arrived over a socket")
    func totalTokensSaturates() throws {
        // DECODED, not constructed, because that is the actual door: a
        // `SessionAccounting` comes off the `/status` body and an assistant
        // `usage` off the SSE `message_end` frame, both through a plain
        // `JSONDecoder` with no bounds applied anywhere on the way in. The
        // full-screen footer then reads `totalTokens` every frame, so a plain `+`
        // here is a SIGTRAP that takes the whole TUI session down — in debug and
        // in release alike.
        let json = """
            {"input":9223372036854775807,"output":9223372036854775807,\
            "cacheRead":9223372036854775807,"cacheWrite":9223372036854775807,\
            "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
            """
        let usage = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
        // Proof the decoder really carried the value through — without this the
        // assertion below could pass on a usage that was quietly clamped on ingest.
        #expect(usage.input == Int.max)
        #expect(usage.cacheWrite == Int.max)
        #expect(usage.totalTokens == Int.max)
    }

    @Test("Folding two extreme turns clamps instead of trapping")
    func additionSaturates() {
        // The other half of the same door: the client folds `message_end` usages
        // onto a running delta with this operator.
        let extreme = Usage(
            input: Int.max, output: Int.max, cacheRead: Int.max, cacheWrite: Int.max,
            reasoning: Int.max
        )
        let sum = extreme + extreme
        #expect(sum.input == Int.max)
        #expect(sum.output == Int.max)
        #expect(sum.cacheRead == Int.max)
        #expect(sum.cacheWrite == Int.max)
        #expect(sum.reasoning == Int.max)
        #expect(sum.totalTokens == Int.max)
    }

    @Test("The clamp leaves ordinary arithmetic exactly as it was")
    func saturationDoesNotDisturbOrdinarySums() {
        // What the fix must NOT do: change any number a real provider produces.
        #expect(Usage(input: 10, output: 3, cacheRead: 5, cacheWrite: 2).totalTokens == 20)
        #expect((Usage(input: 10, output: 3) + Usage(input: 1, output: 1)).totalTokens == 15)
        // Negative values are not a shape the wire should ever produce, but they
        // decode, and they must clamp at the OTHER end rather than wrapping round
        // to a huge positive total.
        #expect(Usage(input: -5, output: 2).totalTokens == -3)
        #expect((Usage(input: Int.min, output: 0) + Usage(input: Int.min, output: 0)).input == Int.min)
        #expect(Usage(input: Int.min, output: Int.min).totalTokens == Int.min)
    }

    @Test("A session line written before reported costs existed still decodes")
    func decodesLegacyLine() throws {
        let legacy = """
            {"input":10,"output":3,"cacheRead":0,"cacheWrite":0,\
            "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
            """
        let decoded = try JSONDecoder().decode(Usage.self, from: Data(legacy.utf8))
        #expect(decoded.input == 10)
        #expect(decoded.reportedCost == nil)
    }
}

// MARK: - Streaming

@Suite("Cost — streaming")
struct StreamingCostTests {

    @Test("A reported cost survives the trailing usage frame, which replaces Usage wholesale")
    func survivesTrailingUsageFrame() throws {
        let assembly = StreamingAssembly(model: "m", rates: testRates)
        assembly.setReportedCost(dec("0.000123"))
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: contentPayload))
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: stopPayload))
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: usagePayload))
        let message = try #require(assembly.finish().last?.terminalMessage)

        // Proof the clobbering frame really was ingested — without this the
        // assertion below could pass on a stream that never reached it.
        #expect(message.usage.input == 10)
        #expect(message.usage.output == 3)
        #expect(message.usage.reportedCost == dec("0.000123"))
        #expect(message.usage.effectiveCostTotal == dec("0.000123"))
        #expect(message.usage.cost.total == dec(rateDerivedTotal))
    }

    @Test("The header cost beats the rate-derived cost end to end")
    func headerBeatsRates() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-response-cost", "0.000123")],
            chunks: [frame(contentPayload), frame(stopPayload), frame(usagePayload), done]
        )
        let sink = MetadataSink()
        let event = try await terminal(
            costClient(transport).streamCompletion(
                model: "m",
                context: Context(messages: [.user("hi")]),
                rates: testRates,
                onResponse: { sink.set($0) }
            )
        )
        let message = try #require(event.terminalMessage)
        #expect(message.stopReason == .stop)
        #expect(message.usage.input == 10)
        #expect(message.usage.effectiveCostTotal == dec("0.000123"))
        #expect(message.usage.cost.total == dec(rateDerivedTotal))
        #expect(sink.value?.responseCost == dec("0.000123"))
    }

    @Test("With no cost header the turn reports exactly what the rates say")
    func noHeaderUsesRates() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-call-id", "c1")],
            chunks: [frame(contentPayload), frame(stopPayload), frame(usagePayload), done]
        )
        let sink = MetadataSink()
        let event = try await terminal(
            costClient(transport).streamCompletion(
                model: "m",
                context: Context(messages: [.user("hi")]),
                rates: testRates,
                onResponse: { sink.set($0) }
            )
        )
        let message = try #require(event.terminalMessage)
        #expect(message.usage.reportedCost == nil)
        #expect(message.usage.effectiveCostTotal == dec(rateDerivedTotal))
        #expect(sink.value?.responseCost == nil)
    }

    @Test("A malformed cost header is discarded, not prefix-parsed into a wrong price")
    func malformedHeaderIgnored() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-response-cost", "0.001, 0.001")],
            chunks: [frame(contentPayload), frame(stopPayload), frame(usagePayload), done]
        )
        let event = try await terminal(
            costClient(transport).streamCompletion(
                model: "m",
                context: Context(messages: [.user("hi")]),
                rates: testRates
            )
        )
        let message = try #require(event.terminalMessage)
        #expect(message.usage.reportedCost == nil)
        #expect(message.usage.effectiveCostTotal == dec(rateDerivedTotal))
    }

    @Test("A turn that dies mid-stream still reports what it was billed")
    func failedTurnKeepsCost() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-response-cost", "0.004")],
            chunks: [frame(contentPayload), frame(errorPayload)]
        )
        let event = try await terminal(
            costClient(transport).streamCompletion(
                model: "m",
                context: Context(messages: [.user("hi")]),
                rates: testRates
            )
        )
        guard case .failed(let message) = event else {
            Issue.record("expected .failed, got \(event)")
            return
        }
        #expect(message.text == "hi")
        #expect(message.stopReason == .error)
        // No usage frame ever arrived, so the derived cost is zero and the
        // gateway's number is the only honest one there is.
        #expect(message.usage.cost.total == 0)
        #expect(message.usage.reportedCost == dec("0.004"))
        #expect(message.usage.effectiveCostTotal == dec("0.004"))
    }

    @Test("A cost of zero is a stated price, not a missing one")
    func zeroIsReported() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-response-cost", "0.0")],
            chunks: [frame(contentPayload), frame(stopPayload), frame(usagePayload), done]
        )
        let event = try await terminal(
            costClient(transport).streamCompletion(
                model: "m",
                context: Context(messages: [.user("hi")]),
                rates: testRates
            )
        )
        let message = try #require(event.terminalMessage)
        #expect(message.usage.reportedCost == 0)
        #expect(message.usage.effectiveCostTotal == 0)
        // The rate-derived total is still there and still non-zero, so this is
        // not passing merely because nothing was costed.
        #expect(message.usage.cost.total == dec(rateDerivedTotal))
    }
}

// MARK: - Non-streaming

@Suite("Cost — non-streaming")
struct NonStreamingCostTests {

    @Test("complete() carries the reported cost on the message, not only on the callback")
    func completeCarriesCost() async throws {
        let transport = CostTransport(
            headers: [("x-litellm-response-cost", "0.0009")],
            chunks: [Array(nonStreamingBody.utf8)]
        )
        let message = try await costClient(transport).complete(
            model: "m",
            context: Context(messages: [.user("hi")]),
            rates: testRates
        )
        #expect(message.usage.input == 10)
        #expect(message.usage.cost.total == dec(rateDerivedTotal))
        #expect(message.usage.reportedCost == dec("0.0009"))
        #expect(message.usage.effectiveCostTotal == dec("0.0009"))
    }

    @Test("complete() with no cost header leaves the rate-derived total in charge")
    func completeWithoutHeader() async throws {
        let transport = CostTransport(headers: [], chunks: [Array(nonStreamingBody.utf8)])
        let message = try await costClient(transport).complete(
            model: "m",
            context: Context(messages: [.user("hi")]),
            rates: testRates
        )
        #expect(message.usage.reportedCost == nil)
        #expect(message.usage.effectiveCostTotal == dec(rateDerivedTotal))
    }
}

// MARK: - ModelOverride

@Suite("ModelOverride")
struct ModelOverrideTests {

    private func decode(_ json: String) throws -> ModelOverride {
        try JSONDecoder().decode(ModelOverride.self, from: Data(json.utf8))
    }

    @Test("The flat authoring shape decodes")
    func flatShape() throws {
        let override = try decode(
            """
            {"contextWindow":128000,"input":3.0,"output":15.0,"cacheRead":0.3,\
            "cacheWrite":3.75,"reasoningEffort":"high"}
            """
        )
        #expect(override.contextWindow == 128_000)
        #expect(override.reasoningEffort == .high)
        #expect(override.rates?.base.input == dec("3"))
        #expect(override.rates?.base.output == dec("15"))
        #expect(override.rates?.base.cacheRead == dec("0.3"))
        #expect(override.rates?.base.cacheWrite == dec("3.75"))
        #expect(override.rates?.tiers.isEmpty == true)
    }

    @Test("The nested shape decodes to the same value as the flat one")
    func nestedShape() throws {
        let nested = try decode(
            """
            {"contextWindow":128000,"rates":{"base":{"input":3.0,"output":15.0,\
            "cacheRead":0.3,"cacheWrite":3.75},"tiers":[]},"reasoningEffort":"high"}
            """
        )
        let flat = try decode(
            """
            {"contextWindow":128000,"input":3.0,"output":15.0,"cacheRead":0.3,\
            "cacheWrite":3.75,"reasoningEffort":"high"}
            """
        )
        #expect(nested == flat)
        #expect(nested.rates?.base.cacheWrite == dec("3.75"))
    }

    @Test("Encoding produces the nested shape and round-trips")
    func encodesNested() throws {
        let original = ModelOverride(
            contextWindow: 200_000,
            rates: ModelCostRates(
                base: TokenRates(input: dec("3.00003"), output: 15),
                tiers: [ModelCostRates.Tier(inputTokensAbove: 200_000, rates: TokenRates(input: 6, output: 22.5))]
            ),
            reasoningEffort: .medium
        )
        let data = try JSONEncoder().encode(original)
        let text = String(decoding: data, as: UTF8.self)
        // The nested spelling, not the flat one: `base` and `tiers` live under
        // `rates`, and the tier threshold survives.
        #expect(text.contains("\"rates\""))
        #expect(text.contains("\"base\""))
        #expect(text.contains("\"inputTokensAbove\":200000"))
        #expect(text.contains("3.00003"))
        #expect(try JSONDecoder().decode(ModelOverride.self, from: data) == original)
    }

    @Test("A price quoted as a string keeps every digit the author typed")
    func stringPricesAreExact() throws {
        let override = try decode(#"{"input":"3.00003","output":"1e-05"}"#)
        #expect(override.rates?.base.input == dec("3.00003"))
        // A Double round-trip would have produced this instead.
        #expect(override.rates?.base.input != Decimal(Double(3.00003)))
        #expect(override.rates?.base.output == dec("0.00001"))
    }

    @Test("A price written as a JSON number keeps every digit too")
    func numberPricesAreExact() throws {
        let override = try decode(#"{"input":3.00003}"#)
        #expect(override.rates?.base.input == dec("3.00003"))
        #expect(override.rates?.base.input != Decimal(Double(3.00003)))
    }

    @Test("Tiers decode in both shapes")
    func tiers() throws {
        let flat = try decode(
            #"{"input":3,"tiers":[{"inputTokensAbove":200000,"rates":{"input":6,"output":22.5}}]}"#
        )
        #expect(flat.rates?.tiers.count == 1)
        #expect(flat.rates?.tiers.first?.inputTokensAbove == 200_000)
        #expect(flat.rates?.rates(forInputTokens: 300_000).input == dec("6"))
        #expect(flat.rates?.rates(forInputTokens: 100).input == dec("3"))

        let nested = try decode(
            #"{"rates":{"base":{"input":3},"tiers":[{"inputTokensAbove":200000,"rates":{"input":6,"output":22.5}}]}}"#
        )
        #expect(nested == flat)
    }

    @Test("An override that states only a context window claims nothing about price")
    func windowOnly() throws {
        let override = try decode(#"{"contextWindow":64000}"#)
        #expect(override.contextWindow == 64_000)
        // Not `.free`: nobody said this model is free.
        #expect(override.rates == nil)
        #expect(override.reasoningEffort == nil)
    }

    @Test("An empty object decodes to an override that says nothing")
    func emptyObject() throws {
        #expect(try decode("{}") == ModelOverride())
    }

    @Test("A negative price is rejected in every spelling")
    func rejectsNegativeRates() {
        #expect(throws: DecodingError.self) { try decode(#"{"input":-1}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"input":"-1"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"output":-0.5}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"cacheRead":-0.5}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"cacheWrite":-0.5}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"rates":{"base":{"input":-1}}}"#) }
        #expect(throws: DecodingError.self) {
            try decode(#"{"tiers":[{"inputTokensAbove":1,"rates":{"input":-1}}]}"#)
        }
    }

    @Test("A price that is not a number is rejected rather than prefix-parsed")
    func rejectsJunkPriceStrings() {
        #expect(throws: DecodingError.self) { try decode(#"{"input":"3.0 USD"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"input":"$3"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"input":true}"#) }
    }

    @Test("A non-positive context window is rejected")
    func rejectsBadContextWindow() {
        #expect(throws: DecodingError.self) { try decode(#"{"contextWindow":0}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"contextWindow":-1}"#) }
    }

    @Test("Stating prices in both shapes at once is an error, not a coin flip")
    func rejectsMixedShapes() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"rates":{"base":{"input":3}},"input":9}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"rates":{"base":{"input":3}},"tiers":[]}"#)
        }
    }

    @Test("A null price reads as unstated, not as zero")
    func nullPrice() throws {
        let override = try decode(#"{"input":null,"output":15}"#)
        #expect(override.rates?.base.input == 0)
        #expect(override.rates?.base.output == dec("15"))
        #expect(try decode(#"{"input":null}"#).rates == nil)
    }
}
