// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Events

/// What a run reports as it advances, in the order a UI renders it.
///
/// A value enum, not a stream of references: every payload is a copy, so a
/// listener that keeps an event to diff against the next is diffing distinct
/// snapshots rather than one object mutating underneath it — the same trap
/// ``AssistantSnapshot`` documents on the LLM side.
///
/// The lifecycle nests: one ``agentStart`` … ``agentEnd`` per run, one
/// ``turnStart`` … ``turnEnd`` per assistant turn, and message events for every
/// user, assistant, and tool-result message. ``messageUpdate`` is emitted only
/// while an assistant turn streams; it forwards the underlying ``AssemblyEvent``
/// so a consumer that wants the incremental delta has it, alongside the best
/// known message state at the last boundary.
public enum AgentEvent: Sendable, Hashable {
    /// The run began. Always the first event.
    case agentStart

    /// The run finished. Always the last event. Carries every message this run
    /// produced and why it stopped, so a listener need not reconstruct either.
    case agentEnd(messages: [Message], reason: RunStopReason)

    /// An assistant turn began. Not emitted for the very first turn of a run,
    /// which the initial ``agentStart`` already implies — mirroring pi, whose
    /// `firstTurn` flag suppresses the duplicate.
    case turnStart

    /// An assistant turn finished, with the message it produced and the tool
    /// results (if any) that its tool calls yielded.
    case turnEnd(message: AssistantMessage, toolResults: [ToolResultBlock])

    /// A message entered the transcript. Emitted for user, assistant, and
    /// tool-result messages; for an assistant message it marks the start of
    /// streaming.
    case messageStart(Message)

    /// A streaming assistant message advanced. `message` is the best known state
    /// at the last stream boundary; `assembly` is the raw incremental event,
    /// including per-token deltas that carry no snapshot of their own.
    case messageUpdate(message: Message, assembly: AssemblyEvent)

    /// A message is complete. For an assistant message this is the final,
    /// billable turn; for tool results it immediately follows ``messageStart``.
    case messageEnd(Message)

    /// A tool call began executing. Emitted in assistant source order during the
    /// sequential preparation phase, before any tool runs.
    case toolExecutionStart(toolCallID: String, toolName: String, arguments: JSONValueBox)

    /// A tool call finished. Under parallel execution these fire in tool
    /// *completion* order, which is deliberately not the source order the
    /// matching tool-result messages are appended in — see ``ToolDispatch``.
    case toolExecutionEnd(toolCallID: String, toolName: String, result: AgentToolResult, isError: Bool)
}

/// A `JSONValue` wrapper so ``AgentEvent`` stays `Hashable`.
///
/// `JSONValue` is already `Hashable`; this box exists only to keep the argument
/// payload's intent legible at the call site (it is the raw, undecoded tool-call
/// arguments) and to leave room to attach display metadata later without
/// widening the event's public shape.
public struct JSONValueBox: Sendable, Hashable {
    public var value: JSONValue
    public init(_ value: JSONValue) { self.value = value }
}

// MARK: - Sink

/// Where a run delivers its events.
///
/// `emit` is `async` on purpose: a listener that does real work — persisting a
/// message, repainting a frame — provides backpressure, and the run does not
/// advance past an event until every listener has accepted it. This is pi's
/// `processEvents`, which `await`s each listener so a durable listener finishes
/// before the run is considered idle.
///
/// This is why the sink is a protocol and not an `AsyncStream`.
/// `AsyncStream.yield` is fire-and-forget: it returns immediately whether or not
/// anyone has consumed the value, which silently discards the ordering-in-
/// settlement guarantee the loop depends on. An adapter is offered for observer-
/// style consumers (``AsyncStreamAgentSink``), documented as *not* carrying that
/// guarantee.
public protocol AgentEventSink: Sendable {
    func emit(_ event: AgentEvent) async
}

// MARK: - AsyncStream adapter

/// Bridges a run to an `AsyncStream` for observer-style consumption.
///
/// Convenient, but weaker than the primary ``AgentEventSink`` contract: `emit`
/// here `yield`s and returns without waiting for the consumer, so events do
/// **not** apply backpressure and a slow consumer does not hold the run open.
/// Use it for passive observation (logging, metrics); use a bespoke
/// ``AgentEventSink`` when a listener must finish before the run settles.
public struct AsyncStreamAgentSink: AgentEventSink {
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private init(_ continuation: AsyncStream<AgentEvent>.Continuation) {
        self.continuation = continuation
    }

    public func emit(_ event: AgentEvent) async {
        continuation.yield(event)
        if case .agentEnd = event { continuation.finish() }
    }

    /// Pairs a sink with the stream it feeds. The stream finishes when the run
    /// emits ``AgentEvent/agentEnd``.
    public static func make() -> (sink: AsyncStreamAgentSink, events: AsyncStream<AgentEvent>) {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        return (AsyncStreamAgentSink(continuation), stream)
    }
}
