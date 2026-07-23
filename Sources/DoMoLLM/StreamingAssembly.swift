// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/api/openai-completions.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation
import Synchronization

// MARK: - Partial view

/// A tool call as it stands mid-stream.
///
/// `arguments` is parsed with ``PartialJSON`` from whatever fragment has
/// arrived, so a preview can render `{"path": "src/ma` as a half-typed path
/// instead of nothing. It is derived at snapshot time rather than stored: the
/// fragment grows one token at a time and re-parsing on every delta is
/// quadratic in the argument length, which for a large file write is the
/// difference between a smooth stream and a stalled one.
public struct PartialToolCall: Sendable, Hashable {
    /// The `delta.tool_calls[].index` this call streams under.
    public var streamIndex: Int

    /// Position in the assistant message's content, in arrival order. Not the
    /// same number as ``streamIndex`` and not derivable from it.
    public var blockIndex: Int

    /// Empty until the fragment that carries it arrives — normally the first.
    public var id: String

    /// Likewise empty until announced. A call with no name yet is not callable
    /// and must not be dispatched.
    public var name: String

    /// The raw `function.arguments` text concatenated so far.
    public var argumentFragment: String

    /// ``argumentFragment`` parsed, repairing truncation.
    public var arguments: JSONValue

    public var argumentsCompleteness: PartialJSONCompleteness

    public init(
        streamIndex: Int,
        blockIndex: Int,
        id: String,
        name: String,
        argumentFragment: String,
        arguments: JSONValue,
        argumentsCompleteness: PartialJSONCompleteness
    ) {
        self.streamIndex = streamIndex
        self.blockIndex = blockIndex
        self.id = id
        self.name = name
        self.argumentFragment = argumentFragment
        self.arguments = arguments
        self.argumentsCompleteness = argumentsCompleteness
    }

    /// Whether the fragment parsed without repair, i.e. the call is dispatchable
    /// as it stands.
    public var argumentsAreComplete: Bool { argumentsCompleteness == .complete }

    public var block: ToolCallBlock {
        ToolCallBlock(id: id, name: name, arguments: arguments)
    }
}

public enum SnapshotBlock: Sendable, Hashable {
    case text(TextBlock)
    case reasoning(ReasoningBlock)
    case toolCall(PartialToolCall)
}

/// An immutable view of an assistant turn in progress.
///
/// Every field is a value copy. Upstream hands renderers the same mutable
/// `partial` object on every event, so a consumer that keeps one to diff against
/// the next is diffing an object against itself.
public struct AssistantSnapshot: Sendable, Hashable {
    public var model: String
    public var responseModel: String?
    public var responseID: String?
    public var blocks: [SnapshotBlock]
    public var usage: Usage

    /// `nil` until a `finish_reason` arrives or the stream is terminated.
    public var stopReason: StopReason?

    public var errorMessage: String?

    /// True once no further content can arrive.
    public var isFinished: Bool

    public init(
        model: String,
        responseModel: String? = nil,
        responseID: String? = nil,
        blocks: [SnapshotBlock] = [],
        usage: Usage = .zero,
        stopReason: StopReason? = nil,
        errorMessage: String? = nil,
        isFinished: Bool = false
    ) {
        self.model = model
        self.responseModel = responseModel
        self.responseID = responseID
        self.blocks = blocks
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.isFinished = isFinished
    }

    /// All text so far, which is what a live preview prints.
    public var text: String {
        blocks.reduce(into: "") { accumulated, block in
            if case .text(let text) = block { accumulated += text.text }
        }
    }

    public var toolCalls: [PartialToolCall] {
        blocks.compactMap { block in
            if case .toolCall(let call) = block { return call }
            return nil
        }
    }

    /// This snapshot as a finished message.
    ///
    /// Valid to call mid-stream; the result is simply a message whose tool
    /// arguments are the repaired parse of an incomplete fragment. Callers that
    /// must not dispatch a half-formed call check
    /// ``PartialToolCall/argumentsAreComplete`` first.
    public var message: AssistantMessage {
        AssistantMessage(
            content: blocks.map { block in
                switch block {
                case .text(let text): return .text(text)
                case .reasoning(let reasoning): return .reasoning(reasoning)
                case .toolCall(let call): return .toolCall(call.block)
                }
            },
            model: model,
            responseModel: responseModel,
            responseID: responseID,
            usage: usage,
            stopReason: stopReason ?? .stop,
            errorMessage: errorMessage
        )
    }
}

// MARK: - Events

/// What the assembler reports as chunks arrive.
///
/// Snapshots ride only on boundaries — a block opening, a block closing, and the
/// terminal event — and never on a delta. Upstream attaches one to every event
/// including each token, which means a renderer that ignores them still pays to
/// build them, and the events themselves are the wrong granularity for a diffing
/// renderer that repaints at a fixed frame rate. Deltas carry the incremental
/// text; a consumer that wants full state between boundaries reads
/// ``StreamingAssembly/snapshot``.
public enum AssemblyEvent: Sendable, Hashable {
    case start(AssistantSnapshot)

    case textStart(blockIndex: Int, snapshot: AssistantSnapshot)
    case textDelta(blockIndex: Int, delta: String)
    case textEnd(blockIndex: Int, text: String, snapshot: AssistantSnapshot)

    case reasoningStart(blockIndex: Int, snapshot: AssistantSnapshot)
    case reasoningDelta(blockIndex: Int, delta: String)
    case reasoningEnd(blockIndex: Int, text: String, snapshot: AssistantSnapshot)

    case toolCallStart(blockIndex: Int, snapshot: AssistantSnapshot)
    case toolCallDelta(blockIndex: Int, delta: String)
    case toolCallEnd(blockIndex: Int, toolCall: ToolCallBlock, snapshot: AssistantSnapshot)

    /// The turn ended and its content is usable, truncation included.
    case done(AssistantMessage)

    /// The turn ended in a way the loop must not treat as a completed answer.
    case failed(AssistantMessage)
}

extension AssemblyEvent {
    /// The terminal message, if this is a terminal event.
    public var terminalMessage: AssistantMessage? {
        switch self {
        case .done(let message), .failed(let message): return message
        default: return nil
        }
    }

    public var isTerminal: Bool { terminalMessage != nil }
}

// MARK: - The assembler

/// Accumulates streamed chunks into one assistant message.
///
/// A reference type on purpose. The alternative — a struct threaded through the
/// decode loop — makes the live preview a separate copy that the renderer has to
/// be handed on every frame, and makes it possible to accumulate into a stale
/// copy. State lives here; every value that leaves is an immutable snapshot.
///
/// Guarded by a `Mutex` rather than an actor: there is no async work under the
/// lock, and ``snapshot`` must be readable synchronously from a renderer that is
/// on another isolation domain.
public final class StreamingAssembly: Sendable {
    private struct ToolCallState {
        var blockIndex: Int
        var id: String
        var name: String
        var fragment: String
    }

    private enum Slot {
        case text(String)
        case reasoning(text: String, signature: String?)
        case toolCall(streamIndex: Int)
    }

    private struct State {
        let model: String
        let rates: ModelCostRates?

        var responseModel: String?
        var responseID: String?

        var slots: [Slot] = []

        /// Keyed by `delta.tool_calls[].index`, never indexed into an array by
        /// it. The index is not reliably zero-based — Bedrock behind LiteLLM
        /// starts at 1 — and is not guaranteed dense, so an array indexed by it
        /// either traps or silently writes into the wrong call.
        var toolCalls: [Int: ToolCallState] = [:]

        var toolCallIndexByID: [String: Int] = [:]
        var lastToolCallIndex: Int?

        var textSlot: Int?
        var reasoningSlot: Int?

        var usage: Usage = .zero
        var finishReason: FinishReason?
        var stopReason: StopReason?
        var errorMessage: String?

        var started = false
        var terminated = false
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - model: the model that was *requested*. A chunk reporting a different
    ///     one means the gateway fell back, and that is surfaced separately as
    ///     ``AssistantSnapshot/responseModel`` rather than overwriting this.
    ///   - rates: per-model prices. `nil` leaves cost at zero, which is the
    ///     honest answer for a model whose price is not known.
    public init(model: String, rates: ModelCostRates? = nil) {
        state = Mutex(State(model: model, rates: rates))
    }

    // MARK: Reading

    public var snapshot: AssistantSnapshot {
        state.withLock { Self.snapshot(of: $0) }
    }

    /// The turn as it stands. Mid-stream this is a preview, not a result.
    public var message: AssistantMessage {
        state.withLock { Self.snapshot(of: $0).message }
    }

    /// In-flight tool calls, keyed by their stream index.
    public var partialToolCalls: [Int: PartialToolCall] {
        state.withLock { current in
            current.toolCalls.reduce(into: [:]) { result, entry in
                result[entry.key] = Self.partialToolCall(streamIndex: entry.key, state: entry.value)
            }
        }
    }

    /// Whether any chunk reported a `finish_reason`.
    ///
    /// A stream that ends without one was cut short, however clean the bytes
    /// looked; ``finish()`` turns that into a failure.
    public var hasFinishReason: Bool {
        state.withLock { $0.finishReason != nil }
    }

    public var isTerminated: Bool {
        state.withLock { $0.terminated }
    }

    // MARK: Feeding

    /// Folds one chunk in and reports what changed.
    ///
    /// Returns no events once the stream has terminated, so a late frame after
    /// an error cannot resurrect a failed turn.
    public func ingest(_ chunk: ChatCompletionChunk) -> [AssemblyEvent] {
        state.withLock { current in
            guard !current.terminated else { return [] }

            if let error = chunk.error {
                return Self.terminate(
                    &current,
                    stopReason: .error,
                    errorMessage: error.summary
                )
            }

            var events: [AssemblyEvent] = []

            if current.responseID == nil { current.responseID = chunk.id }
            if let model = chunk.model, !model.isEmpty, model != current.model, current.responseModel == nil {
                current.responseModel = model
            }
            if let usage = chunk.usage {
                current.usage = Usage(wire: usage).costed(at: current.rates)
            }

            if !current.started {
                current.started = true
                events.append(.start(Self.snapshot(of: current)))
            }

            // The trailing usage frame carries an empty `choices` array. It is
            // the only frame that does, and dropping out here is what makes it
            // a usage-only frame rather than a decode failure.
            guard let choice = chunk.choices.first else { return events }

            if chunk.usage == nil, let usage = choice.usage {
                current.usage = Usage(wire: usage).costed(at: current.rates)
            }

            if let finishReason = choice.finishReason {
                current.finishReason = finishReason
                current.stopReason = StopReason(finishReason: finishReason)
                if current.errorMessage == nil {
                    current.errorMessage = StopReason.errorMessage(for: finishReason)
                }
            }

            guard let delta = choice.delta else { return events }

            if let content = delta.content, !content.isEmpty {
                let slot = Self.ensureTextSlot(&current, events: &events)
                if case .text(let existing) = current.slots[slot] {
                    current.slots[slot] = .text(existing + content)
                }
                events.append(.textDelta(blockIndex: slot, delta: content))
            }

            if let reasoning = delta.reasoningDelta {
                let slot = Self.ensureReasoningSlot(&current, signature: reasoning.field, events: &events)
                if case .reasoning(let existing, let signature) = current.slots[slot] {
                    current.slots[slot] = .reasoning(text: existing + reasoning.text, signature: signature)
                }
                events.append(.reasoningDelta(blockIndex: slot, delta: reasoning.text))
            }

            for fragment in delta.toolCalls ?? [] {
                Self.apply(fragment, to: &current, events: &events)
            }

            return events
        }
    }

    /// Closes every open block and produces the terminal event.
    ///
    /// Idempotent. Call it when the frame reader sees `[DONE]` or the body ends.
    /// A stream that produced no `finish_reason` fails here rather than
    /// silently passing off a truncated turn as a complete one.
    public func finish() -> [AssemblyEvent] {
        state.withLock { current in
            guard !current.terminated else { return [] }
            if current.stopReason == nil {
                return Self.terminate(
                    &current,
                    stopReason: .error,
                    errorMessage: "Stream ended without finish_reason"
                )
            }
            return Self.terminate(&current, stopReason: current.stopReason, errorMessage: current.errorMessage)
        }
    }

    /// Terminates the turn as cancelled, keeping whatever content arrived.
    public func abort(reason: String = "Request was aborted") -> [AssemblyEvent] {
        state.withLock { current in
            guard !current.terminated else { return [] }
            return Self.terminate(&current, stopReason: .aborted, errorMessage: reason)
        }
    }

    /// Terminates the turn on an error frame or a transport failure.
    public func fail(_ error: WireError) -> [AssemblyEvent] {
        state.withLock { current in
            guard !current.terminated else { return [] }
            return Self.terminate(&current, stopReason: .error, errorMessage: error.summary)
        }
    }

    /// Terminates the turn on a client-side error.
    public func fail(_ error: DoMoError) -> [AssemblyEvent] {
        state.withLock { current in
            guard !current.terminated else { return [] }
            return Self.terminate(
                &current,
                stopReason: error.isCancellation ? .aborted : .error,
                errorMessage: error.description
            )
        }
    }

    // MARK: Block bookkeeping

    private static func ensureTextSlot(_ current: inout State, events: inout [AssemblyEvent]) -> Int {
        if let slot = current.textSlot { return slot }
        current.slots.append(.text(""))
        let slot = current.slots.count - 1
        current.textSlot = slot
        events.append(.textStart(blockIndex: slot, snapshot: snapshot(of: current)))
        return slot
    }

    private static func ensureReasoningSlot(
        _ current: inout State,
        signature: String,
        events: inout [AssemblyEvent]
    ) -> Int {
        if let slot = current.reasoningSlot { return slot }
        current.slots.append(.reasoning(text: "", signature: signature))
        let slot = current.slots.count - 1
        current.reasoningSlot = slot
        events.append(.reasoningStart(blockIndex: slot, snapshot: snapshot(of: current)))
        return slot
    }

    /// Resolves the stream index a fragment belongs to.
    ///
    /// `index` is the documented key and is used whenever present. The two
    /// fallbacks exist because some OpenAI-compatible servers omit it entirely
    /// on continuation fragments: an `id` that has been seen before identifies
    /// the call, and failing that the most recently touched call is the only
    /// defensible guess, since a server that omits both cannot be streaming two
    /// calls at once and expecting anyone to tell them apart.
    private static func resolveIndex(_ fragment: WireToolCallDelta, in current: State) -> Int {
        if let index = fragment.index { return index }
        if let id = fragment.id, let index = current.toolCallIndexByID[id] { return index }
        return current.lastToolCallIndex ?? 0
    }

    private static func apply(
        _ fragment: WireToolCallDelta,
        to current: inout State,
        events: inout [AssemblyEvent]
    ) {
        let index = resolveIndex(fragment, in: current)

        if current.toolCalls[index] == nil {
            current.slots.append(.toolCall(streamIndex: index))
            let blockIndex = current.slots.count - 1
            current.toolCalls[index] = ToolCallState(blockIndex: blockIndex, id: "", name: "", fragment: "")
            events.append(.toolCallStart(blockIndex: blockIndex, snapshot: snapshot(of: current)))
        }

        guard var call = current.toolCalls[index] else { return }
        current.lastToolCallIndex = index

        if let id = fragment.id, !id.isEmpty {
            if call.id.isEmpty { call.id = id }
            current.toolCallIndexByID[id] = index
        }
        if let name = fragment.function?.name, !name.isEmpty, call.name.isEmpty {
            call.name = name
        }

        let delta = fragment.function?.arguments ?? ""
        call.fragment += delta
        current.toolCalls[index] = call

        events.append(.toolCallDelta(blockIndex: call.blockIndex, delta: delta))
    }

    /// Emits the close events for every open block, then the terminal event.
    private static func terminate(
        _ current: inout State,
        stopReason: StopReason?,
        errorMessage: String?
    ) -> [AssemblyEvent] {
        current.stopReason = stopReason
        current.errorMessage = errorMessage ?? current.errorMessage
        current.terminated = true

        var events: [AssemblyEvent] = []
        if !current.started {
            current.started = true
            events.append(.start(snapshot(of: current)))
        }

        let final = snapshot(of: current)
        for (blockIndex, block) in final.blocks.enumerated() {
            switch block {
            case .text(let text):
                events.append(.textEnd(blockIndex: blockIndex, text: text.text, snapshot: final))
            case .reasoning(let reasoning):
                events.append(.reasoningEnd(blockIndex: blockIndex, text: reasoning.text, snapshot: final))
            case .toolCall(let call):
                events.append(.toolCallEnd(blockIndex: blockIndex, toolCall: call.block, snapshot: final))
            }
        }

        let message = final.message
        events.append(message.failure == nil ? .done(message) : .failed(message))
        return events
    }

    // MARK: Snapshotting

    private static func partialToolCall(streamIndex: Int, state: ToolCallState) -> PartialToolCall {
        let parsed = PartialJSON.parseStreaming(state.fragment.isEmpty ? nil : state.fragment)
        return PartialToolCall(
            streamIndex: streamIndex,
            blockIndex: state.blockIndex,
            id: state.id,
            name: state.name,
            argumentFragment: state.fragment,
            arguments: parsed.value,
            argumentsCompleteness: parsed.completeness
        )
    }

    private static func snapshot(of current: State) -> AssistantSnapshot {
        var blocks: [SnapshotBlock] = []
        blocks.reserveCapacity(current.slots.count)
        for slot in current.slots {
            switch slot {
            case .text(let text):
                blocks.append(.text(TextBlock(text: text)))
            case .reasoning(let text, let signature):
                blocks.append(.reasoning(ReasoningBlock(text: text, signature: signature)))
            case .toolCall(let streamIndex):
                guard let call = current.toolCalls[streamIndex] else { continue }
                blocks.append(.toolCall(partialToolCall(streamIndex: streamIndex, state: call)))
            }
        }
        return AssistantSnapshot(
            model: current.model,
            responseModel: current.responseModel,
            responseID: current.responseID,
            blocks: blocks,
            usage: current.usage,
            stopReason: current.stopReason,
            errorMessage: current.errorMessage,
            isFinished: current.terminated
        )
    }
}

// MARK: - Non-streaming assembly

extension AssistantMessage {
    /// Builds a message from a non-streaming response.
    ///
    /// Shares the streaming path's leniency: a missing `choices` array, a null
    /// `content`, and an unrecognized `finish_reason` are all survivable, and a
    /// tool call whose `arguments` will not parse strictly is repaired rather
    /// than dropped — the model asked for something, and refusing to say what
    /// helps nobody.
    public init(response: ChatCompletionResponse, model: String, rates: ModelCostRates? = nil) {
        var content: [ContentBlock] = []
        let choice = response.choices.first

        if let text = choice?.message?.content, !text.isEmpty {
            content.append(.text(text))
        }
        if let reasoning = choice?.message?.reasoningContent, !reasoning.isEmpty {
            content.append(.reasoning(ReasoningBlock(text: reasoning, signature: "reasoning_content")))
        }
        for call in choice?.message?.toolCalls ?? [] {
            content.append(
                .toolCall(
                    ToolCallBlock(
                        id: call.id,
                        name: call.function.name,
                        arguments: PartialJSON.parseStreaming(call.function.arguments).value
                    )
                )
            )
        }

        let responseModel: String? = {
            guard let reported = response.model, !reported.isEmpty, reported != model else { return nil }
            return reported
        }()

        let stopReason: StopReason
        var errorMessage: String?
        if let error = response.error {
            stopReason = .error
            errorMessage = error.summary
        } else if let finishReason = choice?.finishReason {
            stopReason = StopReason(finishReason: finishReason)
            errorMessage = StopReason.errorMessage(for: finishReason)
        } else {
            stopReason = .error
            errorMessage = "Response contained no finish_reason"
        }

        self.init(
            content: content,
            model: model,
            responseModel: responseModel,
            responseID: response.id,
            usage: response.usage.map { Usage(wire: $0).costed(at: rates) } ?? .zero,
            stopReason: stopReason,
            errorMessage: errorMessage
        )
    }
}
