// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

import DoMoLLM

/// JSON captured from a LiteLLM proxy, verbatim apart from shortened ids.
enum Fixtures {
    static let contentChunk = """
        {"id":"chatcmpl-C3kQ2vE","created":1753280411,"model":"gpt-4o-mini",\
        "object":"chat.completion.chunk","system_fingerprint":"fp_0705bf87c0",\
        "choices":[{"index":0,"delta":{"content":"Hello","role":"assistant"},\
        "logprobs":null,"finish_reason":null}]}
        """

    /// A tool-call turn: `content` is null, not absent.
    static let toolCallNullContentChunk = """
        {"id":"chatcmpl-C3kQ2vE","created":1753280412,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "role":"assistant","tool_calls":[{"index":1,"function":{"arguments":"",\
        "name":"list_files"},"id":"tooluse_ZK1aQ9xTRq2","type":"function"}]},\
        "logprobs":null,"finish_reason":null}]}
        """

    /// The trailing frame: usage arrives with an empty `choices` array.
    static let usageChunk = """
        {"id":"chatcmpl-C3kQ2vE","created":1753280414,"model":"gpt-4o-mini",\
        "object":"chat.completion.chunk","choices":[],"usage":{"completion_tokens":19,\
        "prompt_tokens":1031,"total_tokens":1050,"completion_tokens_details":\
        {"accepted_prediction_tokens":0,"audio_tokens":0,"reasoning_tokens":12,\
        "rejected_prediction_tokens":0},"prompt_tokens_details":{"audio_tokens":0,\
        "cached_tokens":1024}}}
        """

    /// A provider whose `finish_reason` nobody documents.
    static let unknownFinishChunk = """
        {"id":"chatcmpl-C3kQ2vE","created":1753280415,"model":"together/qwen3",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{},\
        "finish_reason":"eos"}]}
        """

    /// A failure delivered as a `data:` frame under an already-committed 200.
    static let errorFrame = """
        {"error":{"message":"litellm.RateLimitError: AnthropicException - rate_limit_error",\
        "type":"None","param":"None","code":"429"}}
        """

    /// Same shape, but the server sent `code` as a number.
    static let errorFrameNumericCode = """
        {"error":{"message":"upstream unavailable","type":"api_error","code":503}}
        """

    static let nonStreamingResponse = """
        {"id":"chatcmpl-C3kQ2vF","object":"chat.completion","created":1753280420,\
        "model":"claude-sonnet-4","choices":[{"index":0,"message":{"role":"assistant",\
        "content":null,"tool_calls":[{"id":"toolu_01A","type":"function","function":\
        {"name":"read","arguments":"{\\"path\\":\\"README.md\\"}"}}]},\
        "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1200,"completion_tokens":64,\
        "total_tokens":1264,"prompt_tokens_details":{"cached_tokens":900}}}
        """
}

func decodeChunk(_ json: String) throws -> ChatCompletionChunk {
    try ChatCompletionChunk.decode(sseData: json)
}

@Suite("Wire — chunk decoding")
struct ChunkDecodingTests {

    @Test("A content chunk decodes with its delta text")
    func contentChunk() throws {
        let chunk = try decodeChunk(Fixtures.contentChunk)
        #expect(chunk.id == "chatcmpl-C3kQ2vE")
        #expect(chunk.model == "gpt-4o-mini")
        #expect(chunk.choices.count == 1)
        #expect(chunk.choices[0].delta?.content == "Hello")
        #expect(chunk.choices[0].delta?.role == .assistant)
        #expect(chunk.choices[0].finishReason == nil)
    }

    @Test("content: null on a tool-call turn decodes rather than throwing")
    func nullContent() throws {
        let chunk = try decodeChunk(Fixtures.toolCallNullContentChunk)
        let delta = try #require(chunk.choices.first?.delta)
        #expect(delta.content == nil)
        let fragment = try #require(delta.toolCalls?.first)
        #expect(fragment.index == 1)
        #expect(fragment.id == "tooluse_ZK1aQ9xTRq2")
        #expect(fragment.function?.name == "list_files")
        #expect(fragment.function?.arguments == "")
    }

    @Test("The trailing usage frame carries an empty choices array")
    func trailingUsageFrame() throws {
        let chunk = try decodeChunk(Fixtures.usageChunk)
        #expect(chunk.choices.isEmpty)
        let usage = try #require(chunk.usage)
        #expect(usage.promptTokens == 1031)
        #expect(usage.completionTokens == 19)
        #expect(usage.promptTokensDetails?.cachedTokens == 1024)
        #expect(usage.completionTokensDetails?.reasoningTokens == 12)
    }

    @Test("Unknown vendor fields are ignored, not fatal")
    func unknownFieldsIgnored() throws {
        let chunk = try decodeChunk(
            """
            {"id":"x","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null,\
            "matched_stop":151645}],"provider_specific_fields":{"whatever":true}}
            """
        )
        #expect(chunk.choices[0].delta?.content == "hi")
    }

    @Test("A chunk with no choices key at all still decodes")
    func missingChoices() throws {
        let chunk = try decodeChunk(#"{"id":"x","object":"chat.completion.chunk"}"#)
        #expect(chunk.choices.isEmpty)
    }

    @Test("Malformed JSON becomes a malformedResponse DoMoError")
    func malformedChunk() {
        #expect(throws: DoMoError.self) {
            _ = try ChatCompletionChunk.decode(sseData: "{not json")
        }
        do {
            _ = try ChatCompletionChunk.decode(sseData: "{not json")
        } catch {
            #expect(error.kind == .malformedResponse)
        }
    }
}

@Suite("Wire — finish reasons")
struct FinishReasonTests {

    @Test("Documented reasons map to stop reasons")
    func knownReasons() {
        #expect(StopReason(finishReason: .stop) == .stop)
        #expect(StopReason(finishReason: .length) == .length)
        #expect(StopReason(finishReason: .toolCalls) == .toolUse)
        #expect(StopReason(finishReason: .functionCall) == .toolUse)
        #expect(StopReason(finishReason: .contentFilter) == .error)
    }

    @Test("An undocumented finish_reason survives as .unknown with its raw text")
    func unknownReason() throws {
        let chunk = try decodeChunk(Fixtures.unknownFinishChunk)
        let reason = try #require(chunk.choices.first?.finishReason)
        #expect(reason == .unknown("eos"))
        #expect(reason.rawValue == "eos")
        #expect(StopReason(finishReason: reason) == .unknown("eos"))
        #expect(StopReason.errorMessage(for: reason) == "Provider finish_reason: eos")
    }

    @Test("finish_reason round-trips through Codable, unknown values included")
    func roundTrip() throws {
        for reason: FinishReason in [.stop, .length, .toolCalls, .functionCall, .contentFilter, .unknown("eos")] {
            let data = try JSONEncoder().encode(reason)
            #expect(try JSONDecoder().decode(FinishReason.self, from: data) == reason)
        }
    }

    @Test("Aliases collapse onto the documented reason")
    func aliases() {
        #expect(FinishReason(rawValue: "end") == .stop)
        #expect(FinishReason(rawValue: "max_tokens") == .length)
    }

    @Test("StopReason round-trips, unknown included")
    func stopReasonRoundTrip() throws {
        for reason: StopReason in [.stop, .length, .toolUse, .error, .aborted, .unknown("eos")] {
            let data = try JSONEncoder().encode(reason)
            #expect(try JSONDecoder().decode(StopReason.self, from: data) == reason)
        }
        #expect(StopReason.unknown("eos").isFailure)
        #expect(!StopReason.toolUse.isFailure)
    }
}

@Suite("Wire — errors")
struct WireErrorTests {

    @Test("An error frame is recognized inside an already-committed 200")
    func errorFrame() throws {
        let error = try #require(WireErrorEnvelope.sniff(sseData: Fixtures.errorFrame))
        #expect(error.code == "429")
        #expect(error.message?.contains("RateLimitError") == true)
        #expect(error.summary.contains("code: 429"))
    }

    @Test("A numeric error code decodes as a string instead of failing")
    func numericCode() throws {
        let error = try #require(WireErrorEnvelope.sniff(sseData: Fixtures.errorFrameNumericCode))
        #expect(error.code == "503")
        #expect(error.type == "api_error")
    }

    @Test("A normal chunk is not mistaken for an error frame")
    func noFalsePositive() {
        #expect(WireErrorEnvelope.sniff(sseData: Fixtures.contentChunk) == nil)
        #expect(WireErrorEnvelope.sniff(sseData: Fixtures.usageChunk) == nil)
    }

    @Test("An error carried on a chunk decodes on the chunk itself")
    func errorOnChunk() throws {
        let chunk = try decodeChunk(Fixtures.errorFrame)
        #expect(chunk.error?.code == "429")
    }

    @Test("A wire error converts into the DoMoError taxonomy")
    func asDoMoError() throws {
        let error = try #require(WireErrorEnvelope.sniff(sseData: Fixtures.errorFrame))
        let converted = error.asDoMoError(status: 429, isRetryable: true)
        #expect(converted.kind == .provider(status: 429, isRetryable: true))
        #expect(converted.isRetryable)
    }
}

@Suite("Wire — usage and cost")
struct UsageTests {

    @Test("Cache reads are subtracted out of prompt_tokens")
    func cacheReadSubtracted() throws {
        let chunk = try decodeChunk(Fixtures.usageChunk)
        let usage = Usage(wire: try #require(chunk.usage))
        #expect(usage.input == 1031 - 1024)
        #expect(usage.cacheRead == 1024)
        #expect(usage.cacheWrite == 0)
        #expect(usage.output == 19)
        #expect(usage.reasoning == 12)
        #expect(usage.totalTokens == 7 + 19 + 1024)
    }

    @Test("Unreported reasoning tokens stay nil rather than becoming zero")
    func reasoningNotReported() throws {
        let usage = Usage(wire: try JSONDecoder().decode(
            WireUsage.self,
            from: Data(#"{"prompt_tokens":10,"completion_tokens":2}"#.utf8)
        ))
        #expect(usage.reasoning == nil)
    }

    @Test("DeepSeek's prompt_cache_hit_tokens is read as a cache read")
    func deepseekSpelling() throws {
        let usage = Usage(wire: try JSONDecoder().decode(
            WireUsage.self,
            from: Data(#"{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":60}"#.utf8)
        ))
        #expect(usage.cacheRead == 60)
        #expect(usage.input == 40)
    }

    @Test("Anthropic cache writes forwarded at the top level are counted")
    func cacheWrite() throws {
        let usage = Usage(wire: try JSONDecoder().decode(
            WireUsage.self,
            from: Data(#"{"prompt_tokens":100,"completion_tokens":5,"cache_creation_input_tokens":30}"#.utf8)
        ))
        #expect(usage.cacheWrite == 30)
        #expect(usage.input == 70)
    }

    @Test("A prompt smaller than its reported cache counts does not go negative")
    func neverNegative() {
        let usage = Usage(
            wire: WireUsage(
                promptTokens: 10,
                completionTokens: 1,
                promptTokensDetails: .init(cachedTokens: 40)
            )
        )
        #expect(usage.input == 0)
    }

    @Test("Cost is computed in Decimal from injected rates")
    func cost() {
        let rates = ModelCostRates(input: 3, output: 15, cacheRead: Decimal(string: "0.3")!, cacheWrite: Decimal(string: "3.75")!)
        let usage = Usage(input: 1_000_000, output: 1000, cacheRead: 2000, cacheWrite: 4000).costed(at: rates)
        #expect(usage.cost.input == 3)
        #expect(usage.cost.output == Decimal(string: "0.015"))
        #expect(usage.cost.cacheRead == Decimal(string: "0.0006"))
        #expect(usage.cost.cacheWrite == Decimal(string: "0.015"))
        #expect(usage.cost.total == Decimal(string: "3.0306"))
    }

    @Test("No rates means no claimed cost")
    func noRates() {
        let usage = Usage(input: 1_000_000, output: 1000).costed(at: nil)
        #expect(usage.cost == .zero)
    }

    @Test("A volume tier applies to the whole request once its threshold is crossed")
    func tiers() {
        let rates = ModelCostRates(
            input: Decimal(string: "1.25")!,
            output: 10,
            tiers: [
                .init(inputTokensAbove: 200_000, rates: TokenRates(input: Decimal(string: "2.50")!, output: 15))
            ]
        )
        let small = Usage(input: 100_000, output: 1000).costed(at: rates)
        #expect(small.cost.input == Decimal(string: "0.125"))

        // Cache reads and writes count toward the threshold, so this crosses it
        // on 150k uncached plus 100k cached.
        let large = Usage(input: 150_000, output: 1000, cacheRead: 100_000).costed(at: rates)
        #expect(large.cost.input == Decimal(string: "0.375"))
        #expect(large.cost.output == Decimal(string: "0.015"))
    }

    @Test("Usage adds without losing the nil/zero distinction on reasoning")
    func addition() {
        let a = Usage(input: 10, output: 5)
        let b = Usage(input: 1, output: 2, reasoning: 2)
        #expect((a + a).reasoning == nil)
        #expect((a + b).reasoning == 2)
        #expect((a + b).input == 11)
    }
}

@Suite("Wire — request bodies")
struct RequestTests {

    private func encoded(_ request: ChatCompletionRequest) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONValue(parsing: try encoder.encode(request))
    }

    @Test("A streaming request asks for usage and names the model")
    func streamingRequest() throws {
        let context = Context(systemPrompt: "You are helpful.", messages: [.user("hi")])
        let request = ChatCompletionRequest(model: "claude-sonnet-4", context: context, temperature: 0.2, maxTokens: 4096)
        let json = try encoded(request)

        #expect(json["model"] == "claude-sonnet-4")
        #expect(json["stream"] == true)
        #expect(json["stream_options"]?["include_usage"] == true)
        #expect(json["temperature"] == 0.2)
        #expect(json["max_tokens"] == 4096)
        #expect(json["messages"]?[0]?["role"] == "system")
        #expect(json["messages"]?[0]?["content"] == "You are helpful.")
        #expect(json["messages"]?[1]?["role"] == "user")
        #expect(json["messages"]?[1]?["content"] == "hi")
        #expect(json["tools"] == nil)
        #expect(json["reasoning_effort"] == nil)
    }

    @Test("Tools carry their JSON Schema")
    func tools() throws {
        let tool = ToolDefinition(
            name: "read",
            description: "Read a file",
            parameters: .object(
                properties: [
                    .required("path", .string(description: "Absolute path")),
                    .optional("limit", .integer()),
                ]
            )
        )
        let request = ChatCompletionRequest(
            model: "m",
            context: Context(messages: [.user("go")], tools: [tool]),
            reasoningEffort: .high,
            toolChoice: .auto
        )
        let json = try encoded(request)

        #expect(json["tools"]?[0]?["type"] == "function")
        #expect(json["tools"]?[0]?["function"]?["name"] == "read")
        #expect(json["tools"]?[0]?["function"]?["parameters"]?["type"] == "object")
        #expect(json["tools"]?[0]?["function"]?["parameters"]?["properties"]?["path"]?["type"] == "string")
        #expect(json["tools"]?[0]?["function"]?["parameters"]?["required"] == ["path"])
        #expect(json["tool_choice"] == "auto")
        #expect(json["reasoning_effort"] == "high")
    }

    @Test("tool_choice for a named function encodes as an object")
    func namedToolChoice() throws {
        let request = ChatCompletionRequest(
            model: "m",
            context: Context(messages: [.user("go")]),
            toolChoice: .function(name: "read")
        )
        let json = try encoded(request)
        #expect(json["tool_choice"]?["type"] == "function")
        #expect(json["tool_choice"]?["function"]?["name"] == "read")

        let data = try JSONEncoder().encode(WireToolChoice.function(name: "read"))
        #expect(try JSONDecoder().decode(WireToolChoice.self, from: data) == .function(name: "read"))
    }

    @Test("An empty tools array is sent when the transcript mentions tools")
    func emptyToolsWithHistory() throws {
        let context = Context(
            messages: [
                .user("go"),
                .assistant(
                    AssistantMessage(
                        content: [.toolCall(ToolCallBlock(id: "c1", name: "read", arguments: ["path": "a"]))],
                        model: "m",
                        stopReason: .toolUse
                    )
                ),
                .tool(ToolResultBlock(toolCallID: "c1", toolName: "read", output: "contents")),
            ]
        )
        #expect(context.hasToolHistory)
        let json = try encoded(ChatCompletionRequest(model: "m", context: context))
        #expect(json["tools"] == .array([]))
    }

    @Test("An assistant tool-call turn sends content: null, not an omitted key")
    func assistantNullContent() throws {
        let message = Message.assistant(
            AssistantMessage(
                content: [.toolCall(ToolCallBlock(id: "c1", name: "read", arguments: ["path": "README.md"]))],
                model: "m",
                stopReason: .toolUse
            )
        )
        let wire = try #require(WireMessage.encoding(message).first)
        #expect(wire.content == nil)
        #expect(wire.toolCalls?.first?.function.arguments == #"{"path":"README.md"}"#)

        let json = try JSONValue(parsing: try JSONEncoder().encode(wire))
        #expect(json["content"] == JSONValue.null)
    }

    @Test("An assistant turn with neither text nor tool calls is dropped")
    func emptyAssistantDropped() {
        let message = Message.assistant(AssistantMessage(model: "m", stopReason: .aborted))
        #expect(WireMessage.encoding(message).isEmpty)
    }

    @Test("An empty tool result gets a placeholder rather than an empty string")
    func emptyToolResult() throws {
        let wire = try #require(
            WireMessage.encoding(
                .tool(ToolResultBlock(toolCallID: "c1", toolName: "bash", output: "")),
                includeToolResultName: true
            ).first
        )
        #expect(wire.content == "(no tool output)")
        #expect(wire.toolCallID == "c1")
        #expect(wire.name == "bash")
    }

    @Test("The tool result name is omitted unless asked for")
    func toolResultNameOptional() throws {
        let wire = try #require(
            WireMessage.encoding(.tool(ToolResultBlock(toolCallID: "c1", toolName: "bash", output: "ok"))).first
        )
        #expect(wire.name == nil)
    }

    @Test("An unrecognized role decodes rather than throwing")
    func openRoleVocabulary() throws {
        let message = try JSONDecoder().decode(
            WireMessage.self,
            from: Data(#"{"role":"developer","content":"be brief"}"#.utf8)
        )
        #expect(message.role == .developer)
        #expect(message.role.rawValue == "developer")
    }
}

@Suite("Wire — non-streaming responses")
struct ResponseTests {

    @Test("A tool-call response with null content assembles into a message")
    func toolCallResponse() throws {
        let response = try JSONDecoder().decode(
            ChatCompletionResponse.self,
            from: Data(Fixtures.nonStreamingResponse.utf8)
        )
        let message = AssistantMessage(
            response: response,
            model: "claude-sonnet-4",
            rates: ModelCostRates(input: 3, output: 15)
        )

        #expect(message.stopReason == .toolUse)
        #expect(message.responseModel == nil)
        #expect(message.responseID == "chatcmpl-C3kQ2vF")
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls[0].id == "toolu_01A")
        #expect(message.toolCalls[0].name == "read")
        #expect(message.toolCalls[0].arguments["path"] == "README.md")
        #expect(message.usage.cacheRead == 900)
        #expect(message.usage.input == 300)
        #expect(message.failure == nil)
    }

    @Test("A response answered by a different model reports the fallback")
    func fallbackReported() throws {
        let response = try JSONDecoder().decode(
            ChatCompletionResponse.self,
            from: Data(
                """
                {"id":"x","model":"gpt-4o-mini","choices":[{"index":0,"message":\
                {"role":"assistant","content":"hi"},"finish_reason":"stop"}]}
                """.utf8
            )
        )
        let message = AssistantMessage(response: response, model: "claude-sonnet-4")
        #expect(message.responseModel == "gpt-4o-mini")
        #expect(message.effectiveModel == "gpt-4o-mini")
        #expect(message.text == "hi")
    }

    @Test("A response with no finish_reason is a failure, not a silent success")
    func missingFinishReason() throws {
        let response = try JSONDecoder().decode(
            ChatCompletionResponse.self,
            from: Data(#"{"id":"x","choices":[{"index":0,"message":{"content":"hi"}}]}"#.utf8)
        )
        let message = AssistantMessage(response: response, model: "m")
        #expect(message.stopReason == .error)
        #expect(message.failure != nil)
    }
}

@Suite("Wire — harness model")
struct HarnessModelTests {

    @Test("Messages round-trip through Codable with their role preserved")
    func messageRoundTrip() throws {
        let messages: [Message] = [
            .system("be brief"),
            .user("read the file"),
            .assistant(
                AssistantMessage(
                    content: [
                        .reasoning(ReasoningBlock(text: "think", signature: "reasoning_content")),
                        .text("on it"),
                        .toolCall(ToolCallBlock(id: "c1", name: "read", arguments: ["path": "a.txt"])),
                    ],
                    model: "m",
                    responseModel: "m-fallback",
                    responseID: "resp-1",
                    usage: Usage(input: 5, output: 6, cost: Cost(input: 1)),
                    stopReason: .toolUse
                )
            ),
            .tool(ToolResultBlock(toolCallID: "c1", toolName: "read", output: "hello", isError: false)),
        ]
        let data = try JSONEncoder().encode(messages)
        #expect(try JSONDecoder().decode([Message].self, from: data) == messages)
    }

    @Test("Content blocks are tagged by type on the wire")
    func contentBlockTagging() throws {
        let json = try JSONValue(parsing: try JSONEncoder().encode(ContentBlock.text("hi")))
        #expect(json["type"] == "text")
        #expect(json["text"] == "hi")
    }

    @Test("A truncated turn is not a failure; an unknown stop reason is")
    func failureClassification() {
        #expect(AssistantMessage(model: "m", stopReason: .length).failure == nil)
        #expect(AssistantMessage(model: "m", stopReason: .stop).failure == nil)
        #expect(AssistantMessage(model: "m", stopReason: .toolUse).failure == nil)
        #expect(AssistantMessage(model: "m", stopReason: .unknown("eos")).failure?.kind
            == .provider(status: nil, isRetryable: false))
        #expect(AssistantMessage(model: "m", stopReason: .aborted).failure?.kind == .cancelled)
        #expect(AssistantMessage(model: "m", stopReason: .aborted).failure?.isCancellation == true)
    }
}
