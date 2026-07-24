// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/api/openai-completions.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation

// MARK: - Small open vocabularies

/// A message role.
///
/// A `String`-backed `enum` would be the obvious spelling and the wrong one: a
/// `RawRepresentable` enum fails to decode any value not in the case list, and
/// this field arrives from thirty-odd upstreams normalized by a proxy that is
/// itself several versions behind some of them. A struct with static members
/// reads the same at every call site and cannot fail.
public struct WireRole: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let system = WireRole(rawValue: "system")
    /// OpenAI's reasoning-model spelling of `system`. Accepted, never emitted:
    /// LiteLLM translates `system` for the models that need it.
    public static let developer = WireRole(rawValue: "developer")
    public static let user = WireRole(rawValue: "user")
    public static let assistant = WireRole(rawValue: "assistant")
    public static let tool = WireRole(rawValue: "tool")
}

/// The `reasoning_effort` request field.
///
/// Open for the same reason as ``WireRole``: gateway operators map aliases to
/// models whose accepted efforts are not OpenAI's, and a closed set means a
/// working configuration that this client refuses to express.
public struct ReasoningEffort: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let minimal = ReasoningEffort(rawValue: "minimal")
    public static let low = ReasoningEffort(rawValue: "low")
    public static let medium = ReasoningEffort(rawValue: "medium")
    public static let high = ReasoningEffort(rawValue: "high")
}

/// The `finish_reason` field.
///
/// Modeled as an enum with an ``unknown(_:)`` case rather than a raw string so
/// the mapping to ``StopReason`` happens once, here, instead of at every reader.
public enum FinishReason: Sendable, Hashable {
    case stop
    case length
    case toolCalls
    case functionCall
    case contentFilter
    case unknown(String)
}

extension FinishReason: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .stop: return "stop"
        case .length: return "length"
        case .toolCalls: return "tool_calls"
        case .functionCall: return "function_call"
        case .contentFilter: return "content_filter"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "stop", "end": self = .stop
        case "length", "max_tokens": self = .length
        case "tool_calls": self = .toolCalls
        case "function_call": self = .functionCall
        case "content_filter": self = .contentFilter
        default: self = .unknown(rawValue)
        }
    }
}

extension FinishReason: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StopReason {
    /// The harness-level reason a `finish_reason` implies.
    ///
    /// Upstream folds every unrecognized value into `error`; this keeps the raw
    /// token in ``StopReason/unknown(_:)`` instead. `content_filter` is a real
    /// refusal and stays an error.
    public init(finishReason: FinishReason) {
        switch finishReason {
        case .stop: self = .stop
        case .length: self = .length
        case .toolCalls, .functionCall: self = .toolUse
        case .contentFilter: self = .error
        case .unknown(let raw): self = .unknown(raw)
        }
    }

    /// The message to report alongside a stop reason derived from the wire, or
    /// `nil` when the turn ended normally.
    public static func errorMessage(for finishReason: FinishReason) -> String? {
        switch finishReason {
        case .stop, .length, .toolCalls, .functionCall:
            return nil
        case .contentFilter, .unknown:
            return "Provider finish_reason: \(finishReason.rawValue)"
        }
    }
}

// MARK: - Request

/// The `POST /chat/completions` body.
///
/// Deliberately small. Every field upstream sets from a per-provider compat
/// table — `store`, `prompt_cache_key`, `chat_template_kwargs`, the six
/// different spellings of "think harder" — is the gateway's problem now, and
/// carrying the knobs anyway would mean carrying the detection logic that
/// decides when to use them.
///
/// `max_tokens` rather than `max_completion_tokens`: LiteLLM accepts both and
/// translates to whatever the upstream wants, so the older spelling is the one
/// that also works against a plain OpenAI-compatible server.
public struct ChatCompletionRequest: Sendable, Hashable, Codable {
    public var model: String
    public var messages: [WireMessage]
    public var tools: [WireTool]?
    public var toolChoice: WireToolChoice?
    public var stream: Bool
    public var streamOptions: WireStreamOptions?
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoningEffort: ReasoningEffort?

    public init(
        model: String,
        messages: [WireMessage],
        tools: [WireTool]? = nil,
        toolChoice: WireToolChoice? = nil,
        stream: Bool = true,
        streamOptions: WireStreamOptions? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.stream = stream
        self.streamOptions = streamOptions
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
    }

    public enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case stream
        case streamOptions = "stream_options"
        case temperature
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

/// `stream_options`. Only `include_usage` exists, and it is the reason usage
/// arrives at all on a streamed request.
public struct WireStreamOptions: Sendable, Hashable, Codable {
    public var includeUsage: Bool

    public init(includeUsage: Bool = true) {
        self.includeUsage = includeUsage
    }

    public static let includingUsage = WireStreamOptions(includeUsage: true)

    public enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

/// A message as it appears on the wire, in either direction.
///
/// One flat struct covers all four roles because that is what the wire is: the
/// role decides which fields are meaningful and the server ignores the rest.
/// Splitting it per role buys nothing a decoder can rely on, since a response
/// `message` can and does carry vendor fields no role documents.
public struct WireMessage: Sendable, Hashable {
    public var role: WireRole

    /// Nullable, and null in practice on any assistant turn that only called
    /// tools. Encoded explicitly rather than omitted — the field being present
    /// and null is what the reference client sends, and some upstreams reject
    /// an assistant message with neither `content` nor `tool_calls` present.
    ///
    /// On an image-bearing input turn the wire carries `content` as an *array*
    /// of typed parts instead of a string; ``contentParts`` holds those, and when
    /// it is non-nil the array is what is encoded under `content` — `content`
    /// itself is then ignored.
    public var content: String?

    public var toolCalls: [WireToolCall]?

    /// Set on `tool` messages to address the call being answered.
    public var toolCallID: String?

    /// Tool name on a `tool` message. Only some upstreams require it.
    public var name: String?

    /// Replayed reasoning, echoed back under the field name it arrived on.
    public var reasoningContent: String?

    /// A typed content-part array, encoded under `content` in place of the string
    /// form when present. Only outbound image turns set it — responses always
    /// arrive as a string, so this stays `nil` after a decode.
    public var contentParts: [WirePart]?

    public init(
        role: WireRole,
        content: String? = nil,
        toolCalls: [WireToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil,
        reasoningContent: String? = nil,
        contentParts: [WirePart]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.reasoningContent = reasoningContent
        self.contentParts = contentParts
    }

    public enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
        case reasoningContent = "reasoning_content"
    }
}

extension WireMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(WireRole.self, forKey: .role) ?? .assistant
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        // Responses never send `content` as a parts array, so this is left nil
        // and the string form above is authoritative on the inbound path.
        contentParts = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let contentParts {
            try container.encode(contentParts, forKey: .content)
        } else {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }
}

/// One element of a Chat Completions `content` parts array.
///
/// Only the two kinds an image-bearing input turn needs: a `text` run and an
/// `image_url` pointing at an inline `data:` URL. This is never decoded off a
/// response — models answer with `content` as a plain string — so in practice it
/// is write-only, but `Codable` is kept symmetric so a round-trip test can assert
/// the exact shape.
public enum WirePart: Sendable, Hashable {
    case text(String)
    case imageURL(url: String)
}

extension WirePart: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    /// The nested `{"url": ...}` object OpenAI wraps an image reference in.
    private struct ImageURL: Codable {
        var url: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            self = .imageURL(url: try container.decode(ImageURL.self, forKey: .imageURL).url)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unrecognized content part type: \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
}

/// A complete tool call on an assistant message. The streaming counterpart is
/// ``WireToolCallDelta``, which shares no fields' optionality with this one.
public struct WireToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var type: String
    public var function: WireFunctionCall

    public init(id: String, type: String = "function", function: WireFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct WireFunctionCall: Sendable, Hashable, Codable {
    public var name: String
    /// JSON, as a string. The wire never sends this as an object.
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct WireTool: Sendable, Hashable, Codable {
    public var type: String
    public var function: Function

    public struct Function: Sendable, Hashable, Codable {
        public var name: String
        public var description: String?
        public var parameters: JSONSchema?

        public init(name: String, description: String? = nil, parameters: JSONSchema? = nil) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public init(type: String = "function", function: Function) {
        self.type = type
        self.function = function
    }

    public init(_ tool: ToolDefinition) {
        self.init(
            function: Function(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            )
        )
    }
}

/// `tool_choice`, which is a string for three of its four values and an object
/// for the fourth. Encoded by hand for that reason.
public enum WireToolChoice: Sendable, Hashable {
    case auto
    case none
    case required
    case function(name: String)
}

extension WireToolChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case function
    }

    private struct NamedFunction: Codable {
        var name: String
    }

    public init(from decoder: any Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            switch raw {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default: self = .auto
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let named = try container.decode(NamedFunction.self, forKey: .function)
        self = .function(name: named.name)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .auto, .none, .required:
            var container = encoder.singleValueContainer()
            try container.encode(stringValue)
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(NamedFunction(name: name), forKey: .function)
        }
    }

    private var stringValue: String {
        switch self {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .function: return "function"
        }
    }
}

// MARK: - Streaming chunks

/// One `data:` frame of a streamed completion.
///
/// Every field is optional including `choices`, because the trailing usage frame
/// carries an empty array and mid-stream failures arrive as a frame with nothing
/// but ``error`` under an HTTP status that already said 200.
public struct ChatCompletionChunk: Sendable, Hashable, Codable {
    public var id: String?
    public var object: String?
    public var created: Int?
    public var model: String?
    public var choices: [ChunkChoice]
    public var usage: WireUsage?

    /// Present when the gateway failed after committing a 200. The stream is
    /// over at this point whether or not `[DONE]` follows.
    public var error: WireError?

    public init(
        id: String? = nil,
        object: String? = nil,
        created: Int? = nil,
        model: String? = nil,
        choices: [ChunkChoice] = [],
        usage: WireUsage? = nil,
        error: WireError? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.error = error
    }

    public enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        choices = try container.decodeIfPresent([ChunkChoice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(WireUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(WireError.self, forKey: .error)
    }

    /// Decodes one SSE data payload. `[DONE]` is not JSON and is not handled
    /// here; the frame reader must recognize it before calling.
    public static func decode(sseData: String) throws(DoMoError) -> ChatCompletionChunk {
        do {
            return try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(sseData.utf8))
        } catch {
            throw DoMoError(
                .malformedResponse,
                "Could not decode SSE chunk: \(DoMoError.truncating(sseData, to: 512))",
                cause: error
            )
        }
    }
}

public struct ChunkChoice: Sendable, Hashable, Codable {
    public var index: Int?
    public var delta: ChunkDelta?
    public var finishReason: FinishReason?

    /// Non-standard, and real: a few upstreams report usage per choice instead
    /// of on the chunk. Cheap to read, and the alternative is a turn that bills
    /// as free.
    public var usage: WireUsage?

    public init(
        index: Int? = nil,
        delta: ChunkDelta? = nil,
        finishReason: FinishReason? = nil,
        usage: WireUsage? = nil
    ) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
        self.usage = usage
    }

    public enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
        case usage
    }
}

public struct ChunkDelta: Sendable, Hashable, Codable {
    public var role: WireRole?

    /// Null on a tool-call turn, and null is not the same as absent — though
    /// both mean "no text this frame", so both decode to `nil`.
    public var content: String?

    public var reasoningContent: String?
    public var reasoning: String?
    public var reasoningText: String?

    /// Anthropic-shaped thinking blocks, forwarded verbatim by LiteLLM. Decoded
    /// so they survive a round trip and are otherwise untouched: they have no
    /// lifecycle guarantees and nothing may branch on them.
    public var thinkingBlocks: [JSONValue]?

    public var toolCalls: [WireToolCallDelta]?

    public init(
        role: WireRole? = nil,
        content: String? = nil,
        reasoningContent: String? = nil,
        reasoning: String? = nil,
        reasoningText: String? = nil,
        thinkingBlocks: [JSONValue]? = nil,
        toolCalls: [WireToolCallDelta]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.reasoning = reasoning
        self.reasoningText = reasoningText
        self.thinkingBlocks = thinkingBlocks
        self.toolCalls = toolCalls
    }

    public enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case reasoningText = "reasoning_text"
        case thinkingBlocks = "thinking_blocks"
        case toolCalls = "tool_calls"
    }

    /// The first non-empty reasoning field, with the name it was found under.
    ///
    /// Order is load-bearing: some gateways emit `reasoning_content` *and*
    /// `reasoning` with identical text, and taking both doubles the transcript.
    public var reasoningDelta: (field: String, text: String)? {
        if let text = reasoningContent, !text.isEmpty { return ("reasoning_content", text) }
        if let text = reasoning, !text.isEmpty { return ("reasoning", text) }
        if let text = reasoningText, !text.isEmpty { return ("reasoning_text", text) }
        return nil
    }
}

/// One fragment of a streamed tool call.
///
/// `index` is the only correlation key, `id` and `function.name` arrive once on
/// the first fragment for that index, and `function.arguments` is a string
/// concatenated across arbitrarily many frames that is not valid JSON until the
/// last one.
public struct WireToolCallDelta: Sendable, Hashable, Codable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: FunctionDelta?

    public struct FunctionDelta: Sendable, Hashable, Codable {
        public var name: String?
        public var arguments: String?

        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(index: Int? = nil, id: String? = nil, type: String? = nil, function: FunctionDelta? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

// MARK: - Non-streaming response

public struct ChatCompletionResponse: Sendable, Hashable, Codable {
    public var id: String?
    public var object: String?
    public var created: Int?
    public var model: String?
    public var choices: [ResponseChoice]
    public var usage: WireUsage?
    public var error: WireError?

    public init(
        id: String? = nil,
        object: String? = nil,
        created: Int? = nil,
        model: String? = nil,
        choices: [ResponseChoice] = [],
        usage: WireUsage? = nil,
        error: WireError? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.error = error
    }

    public enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        choices = try container.decodeIfPresent([ResponseChoice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(WireUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(WireError.self, forKey: .error)
    }
}

public struct ResponseChoice: Sendable, Hashable, Codable {
    public var index: Int?
    public var message: WireMessage?
    public var finishReason: FinishReason?

    public init(index: Int? = nil, message: WireMessage? = nil, finishReason: FinishReason? = nil) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }

    public enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

// MARK: - Usage

public struct WireUsage: Sendable, Hashable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var promptTokensDetails: PromptTokensDetails?
    public var completionTokensDetails: CompletionTokensDetails?

    /// DeepSeek's spelling of cached prompt tokens.
    public var promptCacheHitTokens: Int?

    /// Anthropic's cache-write count, forwarded by LiteLLM at the top level.
    public var cacheCreationInputTokens: Int?

    public struct PromptTokensDetails: Sendable, Hashable, Codable {
        public var cachedTokens: Int?
        public var cacheWriteTokens: Int?

        public init(cachedTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
            self.cachedTokens = cachedTokens
            self.cacheWriteTokens = cacheWriteTokens
        }

        public enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }

    public struct CompletionTokensDetails: Sendable, Hashable, Codable {
        public var reasoningTokens: Int?

        public init(reasoningTokens: Int? = nil) {
            self.reasoningTokens = reasoningTokens
        }

        public enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        promptTokensDetails: PromptTokensDetails? = nil,
        completionTokensDetails: CompletionTokensDetails? = nil,
        promptCacheHitTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptTokensDetails = promptTokensDetails
        self.completionTokensDetails = completionTokensDetails
        self.promptCacheHitTokens = promptCacheHitTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    public enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

extension Usage {
    /// Reads wire usage into the harness shape.
    ///
    /// `prompt_tokens` is the total and includes cache reads and writes, so both
    /// are subtracted out to leave the tokens billed at the full input rate.
    /// Cached tokens are *not* subtracted from each other — the documented
    /// semantics are that `cached_tokens` counts reads, and a provider that
    /// reports writes separately is reporting a different thing, not correcting
    /// the first number.
    ///
    /// Cost is left at zero; apply rates with ``Usage/costed(at:)``.
    public init(wire: WireUsage) {
        let prompt = wire.promptTokens ?? 0
        let cacheRead = wire.promptTokensDetails?.cachedTokens ?? wire.promptCacheHitTokens ?? 0
        let cacheWrite = wire.promptTokensDetails?.cacheWriteTokens ?? wire.cacheCreationInputTokens ?? 0
        self.init(
            input: max(0, prompt - cacheRead - cacheWrite),
            output: wire.completionTokens ?? 0,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            // Left nil when unreported. Upstream coerces to 0, which claims the
            // provider said "no reasoning tokens" when it said nothing at all.
            reasoning: wire.completionTokensDetails?.reasoningTokens,
            cost: .zero
        )
    }
}

// MARK: - Errors

/// The `error` object, whether it arrived as an HTTP error body or as a `data:`
/// frame inside an already-committed 200.
public struct WireError: Sendable, Hashable, Codable {
    public var message: String?
    public var type: String?

    /// A string. Servers occasionally send a number here anyway, so the decoder
    /// accepts both and normalizes — typing this `Int` is the classic way to
    /// turn a readable provider error into an unreadable decoding error.
    public var code: String?

    public var param: String?

    public init(message: String? = nil, type: String? = nil, code: String? = nil, param: String? = nil) {
        self.message = message
        self.type = type
        self.code = code
        self.param = param
    }

    public enum CodingKeys: String, CodingKey {
        case message, type, code, param
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        param = try container.decodeIfPresent(String.self, forKey: .param)
        if let code = try? container.decodeIfPresent(String.self, forKey: .code) {
            self.code = code
        } else if let code = try? container.decodeIfPresent(Int.self, forKey: .code) {
            self.code = String(code)
        } else {
            self.code = nil
        }
    }

    /// A one-line rendering for the UI and for ``DoMoError/message``.
    public var summary: String {
        var detail: [String] = []
        if let type, !type.isEmpty { detail.append("type: \(type)") }
        if let code, !code.isEmpty { detail.append("code: \(code)") }
        let joined = detail.joined(separator: ", ")
        guard let message, !message.isEmpty else {
            return detail.isEmpty ? "Provider returned an unspecified error" : joined
        }
        return detail.isEmpty ? message : "\(message) (\(joined))"
    }

    /// This error as a ``DoMoError``.
    ///
    /// Classified `.provider` and non-retryable by default: an error frame under
    /// a committed 200 has no status to consult, and the retry decision belongs
    /// to the layer that saw the HTTP response and its `retry-after` headers.
    public func asDoMoError(status: Int? = nil, isRetryable: Bool = false) -> DoMoError {
        DoMoError(.provider(status: status, isRetryable: isRetryable), summary)
    }
}

/// A `data:` frame carrying nothing but an error.
///
/// Its own type because that frame is the whole payload — there is no `choices`,
/// no `id`, and no HTTP status left to consult, the 200 having already shipped.
public struct WireErrorEnvelope: Sendable, Hashable, Codable {
    public var error: WireError

    public init(error: WireError) {
        self.error = error
    }

    /// Whether this JSON payload is an error frame rather than a chunk.
    ///
    /// Sniffing rather than trusting the status is mandatory here: LiteLLM
    /// commits a 200 and then fails, and a decoder that assumes success reads
    /// the failure as an empty chunk and reports a silently truncated turn.
    public static func sniff(sseData: String) -> WireError? {
        guard sseData.contains("\"error\"") else { return nil }
        return try? JSONDecoder().decode(WireErrorEnvelope.self, from: Data(sseData.utf8)).error
    }
}

// MARK: - Building a request from a Context

extension ChatCompletionRequest {
    /// Builds the request body for a context.
    ///
    /// Assistant text is sent as a plain string and never as an array of text
    /// parts. That is not a stylistic choice: some models mirror the content
    /// block structure back into their own output when they see it, producing
    /// nested `[{"type":"text","text":"[{...}]"}]` garbage.
    ///
    /// When the transcript mentions tools but no tools are supplied, an empty
    /// `tools` array is sent rather than omitting the field, because Anthropic
    /// behind the gateway rejects the request otherwise.
    ///
    /// `includeImageContent: false` strips every image part, collapsing an
    /// image-bearing user turn back to its text and dropping the hoisted user
    /// message a tool-result image would produce. It exists as a seam for a
    /// future text-only-model gate; DoMoCode does not hard-gate on the advisory
    /// model catalog, so the default keeps images on.
    public init(
        model: String,
        context: Context,
        stream: Bool = true,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        toolChoice: WireToolChoice? = nil,
        includeToolResultNames: Bool = false,
        includeImageContent: Bool = true
    ) {
        var messages: [WireMessage] = []
        if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
            messages.append(WireMessage(role: .system, content: systemPrompt))
        }
        for message in context.messages {
            messages.append(
                contentsOf: WireMessage.encoding(
                    message,
                    includeToolResultName: includeToolResultNames,
                    includeImageContent: includeImageContent
                )
            )
        }

        let tools: [WireTool]?
        if !context.tools.isEmpty {
            tools = context.tools.map(WireTool.init)
        } else if context.hasToolHistory {
            tools = []
        } else {
            tools = nil
        }

        self.init(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            stream: stream,
            streamOptions: stream ? .includingUsage : nil,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort
        )
    }
}

extension WireMessage {
    /// The wire messages one harness message becomes.
    ///
    /// Returns zero messages for an assistant turn with neither text nor tool
    /// calls — an aborted turn that produced nothing. Providers reject those
    /// ("either content or tool_calls, but not none"), and replaying one turns a
    /// recoverable abort into a hard failure on the next request.
    public static func encoding(
        _ message: Message,
        includeToolResultName: Bool = false,
        includeImageContent: Bool = true
    ) -> [WireMessage] {
        switch message {
        case .system(let system):
            return [WireMessage(role: .system, content: system.content)]

        case .user(let user):
            // A text-only turn — the common case — stays a plain string. Images
            // force the typed content-part array; `includeImageContent: false`
            // strips them, folding the turn back to just its text.
            let images = user.content.compactMap(\.imageBlock)
            if images.isEmpty || !includeImageContent {
                return [WireMessage(role: .user, content: user.text)]
            }
            let parts: [WirePart] = (user.text.isEmpty ? [] : [.text(user.text)])
                + images.map { .imageURL(url: $0.dataURL) }
            return [WireMessage(role: .user, contentParts: parts)]

        case .assistant(let assistant):
            let text = assistant.content.compactMap(\.textBlock?.text).joined()
            let calls = assistant.toolCalls
            if text.isEmpty && calls.isEmpty { return [] }

            let reasoningBlocks = assistant.content.compactMap(\.reasoningBlock)
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            return [
                WireMessage(
                    role: .assistant,
                    content: text.isEmpty ? nil : text,
                    toolCalls: calls.isEmpty
                        ? nil
                        : calls.map { call in
                            WireToolCall(
                                id: call.id,
                                function: WireFunctionCall(
                                    name: call.name,
                                    // A tool call whose arguments will not
                                    // re-encode is still worth replaying with an
                                    // empty object: dropping it orphans the tool
                                    // result that follows it.
                                    arguments: (try? call.arguments.encodedString()) ?? "{}"
                                )
                            )
                        },
                    reasoningContent: reasoningBlocks.isEmpty
                        ? nil
                        : reasoningBlocks.map(\.text).joined(separator: "\n")
                )
            ]

        case .tool(let result):
            // The OpenAI `tool` role cannot carry image parts, so any images are
            // hoisted into a synthetic `user` message that immediately follows —
            // pi does exactly this. The tool text itself still goes back under the
            // `tool` role so the call stays addressed by its id.
            let images = includeImageContent ? result.images : []
            let toolText = result.output.isEmpty
                // An empty tool result is a protocol violation for several
                // upstreams, so silence gets a placeholder — one that points at
                // the hoisted image when that is all the tool produced.
                ? (images.isEmpty ? "(no tool output)" : "(see attached image)")
                : result.output
            let toolMsg = WireMessage(
                role: .tool,
                content: toolText,
                toolCallID: result.toolCallID,
                name: includeToolResultName ? result.toolName : nil
            )
            if images.isEmpty { return [toolMsg] }
            let hoist = WireMessage(
                role: .user,
                contentParts: [.text("Attached image(s) from tool result:")]
                    + images.map { .imageURL(url: $0.dataURL) }
            )
            return [toolMsg, hoist]
        }
    }
}
