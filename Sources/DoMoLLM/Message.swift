// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation

// MARK: - Content blocks

/// One unit of message content.
///
/// Upstream splits this into three unrelated union types — one per role — so
/// that a `toolCall` can never appear in a user message. That split does not
/// survive the port intact: it costs three enums, three `Codable` conformances
/// and a conversion at every boundary, to enforce an invariant the wire format
/// does not enforce either. One flat enum, with the per-role subsets documented
/// on the message types, is the trade taken here.
///
/// Image content is deliberately absent. DoMoCode's tool surface is textual, and
/// a block kind nothing produces is a block kind every renderer and every
/// serializer still has to handle.
public enum ContentBlock: Sendable, Hashable {
    case text(TextBlock)
    case reasoning(ReasoningBlock)
    case toolCall(ToolCallBlock)
    case toolResult(ToolResultBlock)
}

extension ContentBlock {
    public static func text(_ text: String) -> ContentBlock {
        .text(TextBlock(text: text))
    }

    public var textBlock: TextBlock? {
        if case .text(let block) = self { return block }
        return nil
    }

    public var reasoningBlock: ReasoningBlock? {
        if case .reasoning(let block) = self { return block }
        return nil
    }

    public var toolCallBlock: ToolCallBlock? {
        if case .toolCall(let block) = self { return block }
        return nil
    }

    public var toolResultBlock: ToolResultBlock? {
        if case .toolResult(let block) = self { return block }
        return nil
    }
}

public struct TextBlock: Sendable, Hashable, Codable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// Model reasoning, when the gateway forwards it.
///
/// This block is decoration and nothing may depend on receiving it. LiteLLM
/// surfaces upstream reasoning under whichever of `reasoning_content`,
/// `reasoning`, or `reasoning_text` the origin provider used, with no lifecycle
/// guarantees and no promise that a turn which reasoned will say so.
public struct ReasoningBlock: Sendable, Hashable, Codable {
    public var text: String

    /// The wire field this arrived on, retained so a replayed assistant turn can
    /// echo it back under the same name.
    ///
    /// Providers behind the gateway are not symmetric here: an endpoint that
    /// emits `reasoning_content` rejects the same text replayed as `reasoning`.
    /// Guessing on replay is what breaks multi-turn reasoning continuity.
    public var signature: String?

    public init(text: String, signature: String? = nil) {
        self.text = text
        self.signature = signature
    }
}

/// A tool invocation requested by the model.
///
/// `arguments` is a decoded `JSONValue` rather than the raw string the wire
/// carries, because by the time a call is complete the string has served its
/// only purpose. In-flight fragments live on ``PartialToolCall`` instead.
public struct ToolCallBlock: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue = .object([:])) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The outcome of running a tool, addressed back to the call that requested it.
///
/// Doubles as the payload of a `tool`-role message; see ``Message/tool(_:)``.
/// The gateway matches results to calls by `toolCallID` alone, but `toolName` is
/// carried anyway — some upstreams require `name` on the wire, and recovering it
/// by scanning backwards for the matching assistant turn is work the model
/// already did for us.
public struct ToolResultBlock: Sendable, Hashable, Codable {
    public var toolCallID: String
    public var toolName: String
    public var output: String
    public var isError: Bool

    public init(toolCallID: String, toolName: String, output: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.output = output
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "toolCallId"
        case toolName
        case output
        case isError
    }
}

// MARK: ContentBlock Codable

extension ContentBlock: Codable {
    private enum Kind: String, Codable {
        case text
        case reasoning
        case toolCall
        case toolResult
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try TextBlock(from: decoder))
        case .reasoning: self = .reasoning(try ReasoningBlock(from: decoder))
        case .toolCall: self = .toolCall(try ToolCallBlock(from: decoder))
        case .toolResult: self = .toolResult(try ToolResultBlock(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let block):
            try container.encode(Kind.text, forKey: .type)
            try block.encode(to: encoder)
        case .reasoning(let block):
            try container.encode(Kind.reasoning, forKey: .type)
            try block.encode(to: encoder)
        case .toolCall(let block):
            try container.encode(Kind.toolCall, forKey: .type)
            try block.encode(to: encoder)
        case .toolResult(let block):
            try container.encode(Kind.toolResult, forKey: .type)
            try block.encode(to: encoder)
        }
    }
}

// MARK: - Stop reasons

/// Why a turn ended, in the harness's vocabulary.
///
/// `.unknown` is the case that matters. Providers behind LiteLLM invent
/// `finish_reason` values freely, and upstream collapses every unrecognized one
/// into `error` with the raw string buried in a message. That is a lossy
/// decision made at the wrong layer: the agent loop wants to branch on the
/// value, and a string it has to parse back out of prose is not a value. The
/// raw token is kept verbatim instead, and callers that only care whether the
/// turn failed ask ``isFailure``.
public enum StopReason: Sendable, Hashable {
    /// The model finished its turn.
    case stop
    /// Output hit the token ceiling. The turn is incomplete.
    case length
    /// The model wants tools run; the loop should execute them and continue.
    case toolUse
    /// The provider reported a failure. See `AssistantMessage.errorMessage`.
    case error
    /// The caller cancelled.
    case aborted
    /// A `finish_reason` no version of the API documents, kept verbatim.
    case unknown(String)
}

extension StopReason {
    /// The canonical spelling, used for persistence and for diagnostics.
    public var rawValue: String {
        switch self {
        case .stop: return "stop"
        case .length: return "length"
        case .toolUse: return "toolUse"
        case .error: return "error"
        case .aborted: return "aborted"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "stop": self = .stop
        case "length": self = .length
        case "toolUse": self = .toolUse
        case "error": self = .error
        case "aborted": self = .aborted
        default: self = .unknown(rawValue)
        }
    }

    /// Whether the turn ended in a way the loop must not treat as success.
    ///
    /// `.unknown` counts. A reason nobody modeled is not evidence the model
    /// finished cleanly, and treating it as `.stop` silently truncates turns.
    public var isFailure: Bool {
        switch self {
        case .stop, .toolUse: return false
        case .length, .error, .aborted, .unknown: return true
        }
    }
}

extension StopReason: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StopReason: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - Usage and cost

/// Per-million-token prices for one model.
///
/// Injected rather than looked up: the catalog is a later concern, prices change
/// without notice, and a client that hardcodes them lies quietly for months.
public struct TokenRates: Sendable, Hashable, Codable {
    /// USD per million uncached prompt tokens.
    public var input: Decimal
    /// USD per million completion tokens.
    public var output: Decimal
    /// USD per million tokens served from the prompt cache.
    public var cacheRead: Decimal
    /// USD per million tokens written into the prompt cache.
    public var cacheWrite: Decimal

    public init(input: Decimal = 0, output: Decimal = 0, cacheRead: Decimal = 0, cacheWrite: Decimal = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let free = TokenRates()
}

/// A model's pricing, including any request-wide volume tiers.
public struct ModelCostRates: Sendable, Hashable, Codable {
    public var base: TokenRates

    /// Request-wide tiers. The highest threshold the request's total input
    /// exceeds applies to the whole request, not just to the tokens above it.
    public var tiers: [Tier]

    public struct Tier: Sendable, Hashable, Codable {
        /// Applies when total input usage exceeds this many tokens.
        public var inputTokensAbove: Int
        public var rates: TokenRates

        public init(inputTokensAbove: Int, rates: TokenRates) {
            self.inputTokensAbove = inputTokensAbove
            self.rates = rates
        }
    }

    public init(base: TokenRates, tiers: [Tier] = []) {
        self.base = base
        self.tiers = tiers
    }

    public init(
        input: Decimal = 0,
        output: Decimal = 0,
        cacheRead: Decimal = 0,
        cacheWrite: Decimal = 0,
        tiers: [Tier] = []
    ) {
        self.init(
            base: TokenRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite),
            tiers: tiers
        )
    }

    public static let free = ModelCostRates(base: .free)

    /// The rates that apply to a request with this much total input.
    public func rates(forInputTokens inputTokens: Int) -> TokenRates {
        var matched = base
        var matchedThreshold = -1
        for tier in tiers where inputTokens > tier.inputTokensAbove && tier.inputTokensAbove > matchedThreshold {
            matched = tier.rates
            matchedThreshold = tier.inputTokensAbove
        }
        return matched
    }
}

/// What one turn cost, in USD.
///
/// `Decimal` and not `Double`: these are summed across every turn of a session
/// and displayed to two or four places, and binary floating point accumulates
/// visible drift over a few hundred additions of numbers like 0.000003.
public struct Cost: Sendable, Hashable, Codable {
    public var input: Decimal
    public var output: Decimal
    public var cacheRead: Decimal
    public var cacheWrite: Decimal

    public init(input: Decimal = 0, output: Decimal = 0, cacheRead: Decimal = 0, cacheWrite: Decimal = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Decimal { input + output + cacheRead + cacheWrite }

    public static let zero = Cost()

    public static func + (lhs: Cost, rhs: Cost) -> Cost {
        Cost(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// Token accounting for one turn.
///
/// `input` excludes cache reads and writes, which the wire reports as a subset
/// of `prompt_tokens`. Keeping them separated here is what lets cost be computed
/// without knowing which provider answered — see ``Usage/init(wire:)``, where
/// the subtraction happens once.
public struct Usage: Sendable, Hashable, Codable {
    /// Prompt tokens billed at the full input rate.
    public var input: Int
    /// Completion tokens. Already includes ``reasoning``.
    public var output: Int
    /// Prompt tokens served from cache.
    public var cacheRead: Int
    /// Prompt tokens written to cache.
    public var cacheWrite: Int
    /// Reasoning tokens, when reported. A subset of ``output``, not an addend.
    /// `nil` means the provider said nothing, which is not the same as zero.
    public var reasoning: Int?
    public var cost: Cost

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int? = nil,
        cost: Cost = .zero
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.cost = cost
    }

    public static let zero = Usage()

    public var totalTokens: Int { input + output + cacheRead + cacheWrite }

    /// This usage with ``cost`` recomputed from `rates`.
    ///
    /// A copy rather than a mutation: upstream mutates the usage object in place
    /// from inside the stream loop, which means every snapshot taken before the
    /// final chunk silently changes underneath its holder.
    public func costed(at rates: ModelCostRates?) -> Usage {
        guard let rates else { return self }
        let applicable = rates.rates(forInputTokens: input + cacheRead + cacheWrite)
        let million: Decimal = 1_000_000
        var copy = self
        copy.cost = Cost(
            input: applicable.input * Decimal(input) / million,
            output: applicable.output * Decimal(output) / million,
            cacheRead: applicable.cacheRead * Decimal(cacheRead) / million,
            cacheWrite: applicable.cacheWrite * Decimal(cacheWrite) / million
        )
        return copy
    }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning == nil && rhs.reasoning == nil
                ? nil : (lhs.reasoning ?? 0) + (rhs.reasoning ?? 0),
            cost: lhs.cost + rhs.cost
        )
    }
}

// MARK: - Tools

/// A tool as the model sees it.
///
/// `parameters` is a ``JSONSchema`` and not a free `JSONValue`: the same schema
/// validates the arguments that come back, and a schema the client cannot read
/// is a schema the client cannot check against.
public struct ToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Messages

/// One conversation turn.
///
/// Upstream models three roles and carries the system prompt beside the message
/// list. A fourth `system` case is added here because the Chat Completions wire
/// has one and LiteLLM deployments legitimately place system messages
/// mid-conversation; ``Context/systemPrompt`` remains the convenience for the
/// overwhelmingly common case of exactly one, at the front.
public enum Message: Sendable, Hashable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case tool(ToolResultBlock)
}

extension Message {
    public static func system(_ text: String) -> Message {
        .system(SystemMessage(content: text))
    }

    public static func user(_ text: String) -> Message {
        .user(UserMessage(content: [.text(text)]))
    }

    public var role: WireRole {
        switch self {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }
}

public struct SystemMessage: Sendable, Hashable, Codable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

/// Content is `.text` blocks. Other kinds are representable but not produced.
public struct UserMessage: Sendable, Hashable, Codable {
    public var content: [ContentBlock]

    public init(content: [ContentBlock]) {
        self.content = content
    }

    public var text: String {
        content.compactMap(\.textBlock?.text).joined()
    }
}

/// One assistant turn, including everything needed to bill and replay it.
///
/// Content is `.text`, `.reasoning` and `.toolCall` blocks, in arrival order.
public struct AssistantMessage: Sendable, Hashable, Codable {
    public var content: [ContentBlock]

    /// The model that was asked for.
    public var model: String

    /// The model that actually answered, when it differs.
    ///
    /// Non-nil means a LiteLLM fallback fired or an alias resolved elsewhere.
    /// The UI must show this rather than repeating ``model``; claiming a request
    /// was served by a model that never saw it is the failure mode that makes
    /// gateway debugging impossible.
    public var responseModel: String?

    /// The upstream completion id, for correlating with gateway logs.
    public var responseID: String?

    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?

    public init(
        content: [ContentBlock] = [],
        model: String,
        responseModel: String? = nil,
        responseID: String? = nil,
        usage: Usage = .zero,
        stopReason: StopReason = .stop,
        errorMessage: String? = nil
    ) {
        self.content = content
        self.model = model
        self.responseModel = responseModel
        self.responseID = responseID
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case model
        case responseModel
        case responseID = "responseId"
        case usage
        case stopReason
        case errorMessage
    }

    /// All text content concatenated, which is what a plain-output mode prints.
    public var text: String {
        content.compactMap(\.textBlock?.text).joined()
    }

    public var toolCalls: [ToolCallBlock] {
        content.compactMap(\.toolCallBlock)
    }

    /// The model that answered, preferring the one that actually did.
    public var effectiveModel: String { responseModel ?? model }

    /// This turn expressed as a ``DoMoError``, or `nil` if it ended cleanly.
    ///
    /// Exists so the agent loop has one place to convert a terminal turn into
    /// the error taxonomy, instead of each caller re-deciding whether `.length`
    /// counts. A truncated turn does not: the content is real and the loop's
    /// job is to say so, not to throw it away.
    public var failure: DoMoError? {
        switch stopReason {
        case .stop, .toolUse, .length:
            return nil
        case .aborted:
            return DoMoError(.cancelled, errorMessage ?? "Request was aborted")
        case .error:
            return DoMoError(
                .provider(status: nil, isRetryable: false),
                errorMessage ?? "Provider returned an error stop reason"
            )
        case .unknown(let raw):
            return DoMoError(
                .provider(status: nil, isRetryable: false),
                errorMessage ?? "Unrecognized finish_reason: \(raw)"
            )
        }
    }
}

// MARK: Message Codable

extension Message: Codable {
    private enum CodingKeys: String, CodingKey {
        case role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(WireRole.self, forKey: .role)
        switch role {
        case .system, .developer: self = .system(try SystemMessage(from: decoder))
        case .user: self = .user(try UserMessage(from: decoder))
        case .assistant: self = .assistant(try AssistantMessage(from: decoder))
        case .tool: self = .tool(try ToolResultBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "Unrecognized message role: \(role.rawValue)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch self {
        case .system(let message): try message.encode(to: encoder)
        case .user(let message): try message.encode(to: encoder)
        case .assistant(let message): try message.encode(to: encoder)
        case .tool(let result): try result.encode(to: encoder)
        }
    }
}

// MARK: - Context

/// Everything sent to the model for one request.
public struct Context: Sendable, Hashable, Codable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [ToolDefinition] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }

    /// Whether the transcript already contains tool calls or tool results.
    ///
    /// Anthropic behind LiteLLM rejects a request whose history mentions tools
    /// when `tools` is absent entirely, so an empty array must be sent rather
    /// than the field omitted. This is what decides that.
    public var hasToolHistory: Bool {
        for message in messages {
            switch message {
            case .tool:
                return true
            case .assistant(let assistant):
                if assistant.content.contains(where: { $0.toolCallBlock != nil }) { return true }
            case .system, .user:
                continue
            }
        }
        return false
    }
}
