// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Stream seam

/// The one dependency the loop has on the outside world: a function that turns a
/// request into a stream of assembly events.
///
/// Injecting it — rather than importing ``LiteLLMClient`` — is what keeps the
/// loop pure. A test drives a scripted stream; ``DoMoHarness`` wires the real
/// client. The `Context` argument already carries the tool *definitions* (from
/// ``AgentContext/tools``), so there is no separate tools parameter.
///
/// Contract, ported from pi's `StreamFn`: the function must not throw for a
/// request or provider failure. It encodes failure in the returned stream, as a
/// terminal ``AssemblyEvent/failed(_:)`` whose message carries `stopReason`
/// `.error` or `.aborted`. A thrown error is tolerated — the loop synthesizes a
/// terminal message from it — but it is the stream's job to avoid it.
public typealias AgentStreamFn = @Sendable (Context) -> AsyncThrowingStream<AssemblyEvent, any Error>

// MARK: - Tools

/// How the tool calls in a single assistant message are executed.
///
/// - `sequential`: each call is prepared, executed, and finalized before the
///   next begins.
/// - `parallel`: calls are prepared in source order, then run concurrently;
///   ``AgentEvent/toolExecutionEnd`` fires in completion order while the
///   tool-result messages are appended in source order.
public enum ToolExecutionMode: Sendable, Hashable {
    case sequential
    case parallel
}

/// A tool the loop can dispatch.
///
/// Deliberately *not* ``DoMoTools/Tool``: the agent loop must stay free of the
/// filesystem, the sandbox, and `ToolContext`. This is the seam ``DoMoHarness``
/// crosses, wrapping a real tool plus its bound context into one of these. The
/// loop only ever needs the schema (to advertise the tool) and a way to run it.
public protocol AgentTool: Sendable {
    /// The schema advertised to the model. Its `name` is what a tool call
    /// addresses.
    var definition: ToolDefinition { get }

    /// Per-tool execution-mode override. When any tool in a batch is
    /// `sequential`, the whole batch runs sequentially — pi's `hasSequentialToolCall`.
    var executionMode: ToolExecutionMode? { get }

    /// Runs the call against raw, undecoded arguments.
    ///
    /// Errors the model should see and correct come back as an
    /// ``AgentToolResult`` with ``AgentToolResult/isError`` set, never a throw —
    /// matching ``DoMoTools/Tool``. The one thing that may throw is
    /// ``DoMoError/Kind/cancelled``; the loop turns that into an aborted tool
    /// result rather than letting it escape.
    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult
}

extension AgentTool {
    public var executionMode: ToolExecutionMode? { nil }
}

/// What a tool produced, in the loop's vocabulary.
///
/// A narrower cousin of ``DoMoTools/ToolResult``: the loop needs the text the
/// model reads, the error flag, the early-termination hint, and opaque details
/// for a renderer — nothing that ties it to a concrete tool implementation.
public struct AgentToolResult: Sendable, Hashable {
    /// The text fed back to the model as the tool-result message body.
    public var output: String

    /// Whether this is an error the model should read and recover from.
    public var isError: Bool

    /// Hint that the agent should stop after this tool batch. Honored only when
    /// *every* finalized result in the batch sets it — see
    /// ``ToolDispatch``'s termination rule.
    public var terminate: Bool

    /// Arbitrary structured data for a renderer. Never sent to the model.
    public var details: JSONValue

    /// Image attachments the tool produced, carried to the model through
    /// ``ToolResultBlock/images``. Empty for text-only results — nearly all of
    /// them — and left untouched by the synthetic results the loop fabricates.
    public var images: [ImageBlock]

    public init(
        output: String,
        isError: Bool = false,
        terminate: Bool = false,
        details: JSONValue = .null,
        images: [ImageBlock] = []
    ) {
        self.output = output
        self.isError = isError
        self.terminate = terminate
        self.details = details
        self.images = images
    }
}

// MARK: - Patch

/// Absent versus explicitly-set, made a first-class distinction.
///
/// pi's `afterToolCall` merges with `??`: `afterResult.details ?? result.details`
/// treats an omitted field and a field the hook set to `undefined` identically,
/// which means the hook *cannot* clear a field — only replace it. That collapse
/// is invisible until a hook wants to wipe `details` and silently can't.
///
/// This models the two meanings honestly: ``keep`` leaves the original, ``set``
/// replaces it — and `set(.null)` / `set("")` is a real clear, distinct from
/// leaving the field alone. DoMoCore ships no such type, so it lives here.
public enum Patch<Value: Sendable>: Sendable {
    /// Leave the original value untouched.
    case keep
    /// Replace the original with this value (which may be an "empty" or "null"
    /// value, i.e. an explicit clear).
    case set(Value)

    /// Applies the patch to an existing value.
    public func apply(to original: Value) -> Value {
        switch self {
        case .keep: return original
        case .set(let value): return value
        }
    }
}

extension Patch: Equatable where Value: Equatable {}
extension Patch: Hashable where Value: Hashable {}

// MARK: - Hooks

/// What the model requested and how it was prepared, handed to ``BeforeToolCallHook``.
public struct BeforeToolCallContext: Sendable {
    /// The assistant message that requested the call.
    public var assistantMessage: AssistantMessage
    /// The raw tool-call block.
    public var toolCall: ToolCallBlock
    /// The arguments about to be passed to the tool.
    public var arguments: JSONValue

    public init(assistantMessage: AssistantMessage, toolCall: ToolCallBlock, arguments: JSONValue) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.arguments = arguments
    }
}

/// The before-hook's verdict: proceed (optionally rewriting arguments) or reject.
public struct BeforeToolCallResult: Sendable {
    public enum Decision: Sendable {
        /// Run the tool. `arguments` may rewrite the call's arguments; ``Patch/keep``
        /// leaves them as the model sent them.
        case proceed(arguments: Patch<JSONValue>)
        /// Do not run the tool. `reason` becomes the error tool-result text.
        case reject(reason: String)
    }

    public var decision: Decision
    public init(decision: Decision) { self.decision = decision }

    /// Run the tool unchanged.
    public static let proceed = BeforeToolCallResult(decision: .proceed(arguments: .keep))
    /// Run the tool with rewritten arguments.
    public static func rewrite(_ arguments: JSONValue) -> BeforeToolCallResult {
        BeforeToolCallResult(decision: .proceed(arguments: .set(arguments)))
    }
    /// Block the tool; `reason` is shown to the model as an error result.
    public static func reject(_ reason: String) -> BeforeToolCallResult {
        BeforeToolCallResult(decision: .reject(reason: reason))
    }
}

/// What the tool produced, before the after-hook runs, handed to ``AfterToolCallHook``.
public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCallBlock
    public var arguments: JSONValue
    /// The executed result, before any override is applied.
    public var result: AgentToolResult
    /// Whether the executed result is currently treated as an error.
    public var isError: Bool

    public init(
        assistantMessage: AssistantMessage,
        toolCall: ToolCallBlock,
        arguments: JSONValue,
        result: AgentToolResult,
        isError: Bool
    ) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.arguments = arguments
        self.result = result
        self.isError = isError
    }
}

/// The after-hook's field-by-field override of a tool result.
///
/// Every field is a ``Patch``: ``Patch/keep`` leaves the executed value, ``Patch/set(_:)``
/// replaces it — including an explicit clear, which pi's `??` merge could not
/// express. No deep merge is performed; `output` and `details` replace in full.
public struct AfterToolCallResult: Sendable {
    public var output: Patch<String>
    public var details: Patch<JSONValue>
    public var isError: Patch<Bool>
    public var terminate: Patch<Bool>

    public init(
        output: Patch<String> = .keep,
        details: Patch<JSONValue> = .keep,
        isError: Patch<Bool> = .keep,
        terminate: Patch<Bool> = .keep
    ) {
        self.output = output
        self.details = details
        self.isError = isError
        self.terminate = terminate
    }

    /// Leave the executed result untouched.
    public static let unchanged = AfterToolCallResult()
}

/// Runs after arguments are prepared and before the tool executes. May rewrite
/// or reject the call. Must honor cancellation itself; the loop also checks after
/// it returns.
public typealias BeforeToolCallHook = @Sendable (BeforeToolCallContext) async -> BeforeToolCallResult

/// Runs after the tool executes and before its result events are emitted. May
/// override parts of the result.
public typealias AfterToolCallHook = @Sendable (AfterToolCallContext) async -> AfterToolCallResult

// MARK: - Run configuration

/// Everything the loop knows about the run that is not the transcript itself.
public struct AgentContext: Sendable {
    /// The system prompt sent with every request.
    public var systemPrompt: String?
    /// The transcript that already exists when the run starts. New messages are
    /// appended after it.
    public var messages: [Message]
    /// The tools available this run. Their ``AgentTool/definition``s are what the
    /// model is told about.
    public var tools: [any AgentTool]

    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [any AgentTool] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

/// Tuning and hooks for a run. Everything is optional with a sane default, so the
/// minimal call is `AgentLoopConfig()`.
public struct AgentLoopConfig: Sendable {
    /// The model name stamped onto messages the loop synthesizes (aborts, stream
    /// failures). Not used to select a model — the injected ``AgentStreamFn``
    /// owns that.
    public var model: String

    /// Default execution strategy for a multi-tool-call turn. A tool's own
    /// ``AgentTool/executionMode`` can force `sequential` regardless.
    public var toolExecution: ToolExecutionMode

    /// Upper bound on assistant turns (LLM calls) in one run. `nil` is unbounded.
    /// When reached mid-work, the run ends with ``RunStopReason/maxTurnsReached``
    /// rather than starting another turn. A guard against a model that loops on
    /// tool calls forever; pi leaves this to the embedding app, DoMoCode bakes it
    /// into the pure loop so every embedding gets it.
    public var maxTurns: Int?

    /// Before-execution hook; see ``BeforeToolCallHook``.
    public var beforeToolCall: BeforeToolCallHook?

    /// After-execution hook; see ``AfterToolCallHook``.
    public var afterToolCall: AfterToolCallHook?

    /// Polled at each turn boundary for messages to inject before the next
    /// assistant response. This is "steering" — the user typed while the agent
    /// worked. Contract: must not throw; return `[]` when none.
    public var getSteeringMessages: (@Sendable () async -> [Message])?

    /// Polled after the agent would otherwise stop. Non-empty means the loop
    /// resumes with another turn. This is the follow-up queue. Contract: must not
    /// throw; return `[]` when none.
    public var getFollowUpMessages: (@Sendable () async -> [Message])?

    /// Consulted after each ``AgentEvent/turnEnd``. Returning `true` ends the run
    /// with ``RunStopReason/stoppedByHook`` before polling steering or follow-up.
    public var shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)?

    public init(
        model: String = "unknown",
        toolExecution: ToolExecutionMode = .parallel,
        maxTurns: Int? = nil,
        beforeToolCall: BeforeToolCallHook? = nil,
        afterToolCall: AfterToolCallHook? = nil,
        getSteeringMessages: (@Sendable () async -> [Message])? = nil,
        getFollowUpMessages: (@Sendable () async -> [Message])? = nil,
        shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)? = nil
    ) {
        self.model = model
        self.toolExecution = toolExecution
        self.maxTurns = maxTurns
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.shouldStopAfterTurn = shouldStopAfterTurn
    }
}

// MARK: - Results

/// A completed turn's data, handed to ``AgentLoopConfig/shouldStopAfterTurn`` and
/// carried in ``TurnOutcome``.
public struct TurnResult: Sendable {
    /// The assistant message that completed the turn.
    public var message: AssistantMessage
    /// The tool results from this turn's tool calls, in source order.
    public var toolResults: [ToolResultBlock]
    /// Every message this run has produced so far.
    public var messages: [Message]

    public init(message: AssistantMessage, toolResults: [ToolResultBlock], messages: [Message]) {
        self.message = message
        self.toolResults = toolResults
        self.messages = messages
    }
}

/// Why a run ended. Each case names a distinct stop condition, so a caller
/// branches on the value rather than re-deriving it.
public enum RunStopReason: Sendable, Hashable {
    /// The model finished with no tool calls and nothing queued to resume it.
    case completed
    /// The assistant turn ended with `stopReason == .error`.
    case errored
    /// The run was cancelled, or an assistant turn ended `stopReason == .aborted`.
    case aborted
    /// The ``AgentLoopConfig/maxTurns`` bound was hit.
    case maxTurnsReached
    /// ``AgentLoopConfig/shouldStopAfterTurn`` returned `true`.
    case stoppedByHook
    /// Every tool in the final batch set ``AgentToolResult/terminate``.
    case terminatedByTool
}

/// The outcome of a run: the messages it produced and why it stopped.
public struct AgentRunResult: Sendable {
    /// Every message this run appended — prompts, assistant turns, tool results,
    /// injected steering and follow-up messages — in transcript order. Does not
    /// include the pre-existing ``AgentContext/messages``, matching pi's
    /// `newMessages`.
    public var messages: [Message]
    public var stopReason: RunStopReason

    public init(messages: [Message], stopReason: RunStopReason) {
        self.messages = messages
        self.stopReason = stopReason
    }
}
