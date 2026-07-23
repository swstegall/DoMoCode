// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 2: the print-mode CLI is retrofitted onto `DoMoAgent`. The hand-rolled
// Phase-1 turn loop this file used to carry is gone — the run is now a single
// call into `runAgentLoop`, with the real `LiteLLMClient.streamCompletion` wired
// in as the injected `AgentStreamFn` and the `ToolRegistry` wrapped as the loop's
// `AgentTool` set. This file keeps only the *edges*: the output channel, the
// translation of `AgentEvent`s into the newline-delimited JSON wire format the
// mode already emitted, and the mapping of `RunStopReason` to an exit code.
//
// The wire format is preserved: the same event `type`s, the same field shapes,
// the same exit codes. The `--json` header sequence is reproduced by emitting
// `turn_start` and `response_metadata` from inside the stream seam (where the
// response headers become available) rather than from the loop, so their order
// relative to the streamed deltas is exactly what Phase 1 produced. See the notes
// on individual events for the two places DoMoAgent's richer event stream widens
// the old wire.

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoTools
import Foundation
import Synchronization
import SystemPackage

// MARK: - Output mode

/// How a run reports itself on stdout.
public enum OutputMode: Sendable, Hashable {
    /// Only the model's final text, matching pi's print (`-p`) mode.
    case text
    /// A newline-delimited JSON event stream, matching pi's `--mode json`.
    case json
}

// MARK: - Output channel

/// The one place the process writes to stdout and stderr.
///
/// stdout is reserved for program output — the final text, or the JSON event
/// stream — and stderr for everything diagnostic, exactly as the README requires
/// ("Logs go to stderr; stdout is reserved for the JSON protocol channel"). A
/// `Mutex` serializes writes because the streaming client's `onResponse` callback
/// fires on a different task from the loop consuming the stream, and two
/// unsynchronized writes to the same descriptor interleave their bytes.
///
/// It holds no stored `FileHandle` — it reaches the process-wide
/// `FileHandle.standardOutput`/`.standardError` accessors inside the lock — so it
/// is structurally `Sendable` with nothing to mark unchecked.
public final class OutputChannel: Sendable {
    private let gate = Mutex<Void>(())

    public init() {}

    public func writeOut(_ text: String) {
        gate.withLock { _ in
            try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        }
    }

    public func writeErr(_ text: String) {
        gate.withLock { _ in
            try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
        }
    }
}

// MARK: - Event log

/// Emits the JSON event stream. A no-op in text mode, so callers can emit
/// unconditionally and keep the two modes on one code path.
///
/// Events are encoded through ``JSONValue`` so keys sort deterministically —
/// the stream is meant to be scripted against, and a field order that shuffles
/// between runs is not scriptable. Each event is one line.
struct EventLog: Sendable {
    let channel: OutputChannel
    let mode: OutputMode

    func emit(_ type: String, _ fields: [String: JSONValue] = [:]) {
        guard mode == .json else { return }
        var object = fields
        object["type"] = .string(type)
        guard let line = try? JSONValue.object(object).encodedString() else { return }
        channel.writeOut(line + "\n")
    }
}

// MARK: - Tool adapter

/// Wraps a ``DoMoTools/Tool`` and its bound ``ToolContext`` as an ``AgentTool``.
///
/// This is the seam ``DoMoAgent`` was designed around: the loop stays free of the
/// filesystem and the sandbox, and the CLI crosses that boundary here by binding
/// each registered tool to the run's context. ``AgentToolResult/output`` is the
/// tool's textual result — the same string the Phase-1 loop fed back to the model
/// and surfaced as a `tool_result` event.
struct RegistryTool: AgentTool {
    let tool: any Tool
    let context: ToolContext

    var definition: ToolDefinition {
        ToolDefinition(name: tool.name, description: tool.description, parameters: tool.parameters)
    }

    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        // A tool failure returns an error `ToolResult`, never a throw — only
        // cancellation escapes, and the loop turns that into an aborted result.
        // No built-in tool sets `terminate`; the print run has no early-stop tool.
        let result = try await tool.execute(arguments, in: context)
        return AgentToolResult(output: result.text, isError: result.isError, details: result.details)
    }
}

// MARK: - Event sink

/// Translates ``AgentEvent``s into the print mode's JSON wire events.
///
/// Stateless — every field is a `let` and no event mutates it, so the sink is
/// trivially `Sendable` with no lock. The two pieces of run-spanning state the
/// old loop tracked live elsewhere now: the turn counter is owned by the stream
/// seam (``PrintMode/streamFunction(counter:)``), which is the one place a turn's
/// LLM call begins; and the final message and stop reason come back on the loop's
/// ``AgentRunResult``, so the terminal `result`/`error` event is emitted after the
/// loop returns rather than from ``AgentEvent/agentEnd``.
///
/// Two families of ``AgentEvent`` are intentionally dropped: ``AgentEvent/turnStart``
/// and ``AgentEvent/turnEnd`` (the wire's `turn_start` is emitted from the stream
/// seam instead, so it lands before `response_metadata` as Phase 1 had it), and
/// the `messageStart`/`messageEnd` of tool-result messages (the `tool_result`
/// event already comes from ``AgentEvent/toolExecutionEnd``, and mapping the
/// message too would double it).
struct PrintEventSink: AgentEventSink {
    let channel: OutputChannel
    let mode: OutputMode
    let sessionModel: String
    let workingDirectory: FilePath
    let toolNames: [String]

    private var log: EventLog { EventLog(channel: channel, mode: mode) }

    func emit(_ event: AgentEvent) async {
        switch event {
        case .agentStart:
            log.emit(
                "session_start",
                [
                    "model": .string(sessionModel),
                    "workingDirectory": .string(workingDirectory.string),
                    "tools": .array(toolNames.map(JSONValue.string)),
                ]
            )

        case .messageStart(let message):
            // The user prompt (and any injected steering/follow-up user message)
            // is announced once, when it enters the transcript, ahead of the turn
            // it precedes — matching Phase 1's `user` event position.
            if case .user(let user) = message {
                log.emit("user", ["text": .string(user.text)])
            }

        case .messageUpdate(_, let assembly):
            switch assembly {
            case .textDelta(_, let delta):
                log.emit("text_delta", ["text": .string(delta)])
            case .reasoningDelta(_, let delta):
                log.emit("reasoning_delta", ["text": .string(delta)])
            default:
                break
            }

        case .messageEnd(let message):
            if case .assistant(let assistant) = message {
                emitAssistant(assistant)
            }

        case .toolExecutionStart(let toolCallID, let toolName, let arguments):
            log.emit(
                "tool_use",
                [
                    "id": .string(toolCallID),
                    "name": .string(toolName),
                    "arguments": arguments.value,
                ]
            )

        case .toolExecutionEnd(let toolCallID, let toolName, let result, let isError):
            log.emit(
                "tool_result",
                [
                    "id": .string(toolCallID),
                    "name": .string(toolName),
                    "isError": .bool(isError),
                    "output": .string(result.output),
                ]
            )

        case .turnStart, .turnEnd, .agentEnd:
            break
        }
    }

    private func emitAssistant(_ assistant: AssistantMessage) {
        log.emit(
            "assistant",
            [
                "text": .string(assistant.text),
                "stopReason": .string(assistant.stopReason.rawValue),
                "model": .string(assistant.model),
                "responseModel": assistant.responseModel.map(JSONValue.string) ?? .null,
                "toolCalls": .array(
                    assistant.toolCalls.map { call in
                        .object(["id": .string(call.id), "name": .string(call.name), "arguments": call.arguments])
                    }
                ),
                "usage": .object([
                    "input": .int(assistant.usage.input),
                    "output": .int(assistant.usage.output),
                    "cacheRead": .int(assistant.usage.cacheRead),
                    "cacheWrite": .int(assistant.usage.cacheWrite),
                ]),
            ]
        )
    }
}

// MARK: - Turn counter

/// A run-spanning count of LLM calls, shared by reference between the stream seam
/// (which advances it and emits `turn_start`) and the terminal `result` event
/// (which reads it back as `turns`).
///
/// A reference box around a ``Mutex`` rather than the `Mutex` itself: `Mutex` is
/// non-copyable, so it cannot be captured into the escaping ``AgentStreamFn``
/// closure — a class holding one can. `Sendable` because the `Mutex` guards the
/// only mutable field.
final class TurnCounter: Sendable {
    private let count = Mutex<Int>(0)

    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }

    var value: Int { count.withLock { $0 } }
}

// MARK: - Print mode

/// Runs a single prompt to completion and prints the result.
///
/// `Sendable` because its stored dependencies are, and because the injected
/// stream function captures pieces of it across an isolation boundary.
public struct PrintMode: Sendable {

    let client: LiteLLMClient
    let model: String
    let reasoningEffort: ReasoningEffort?
    let registry: ToolRegistry
    let toolContext: ToolContext
    let workingDirectory: FilePath
    let mode: OutputMode
    let maxTurns: Int
    let channel: OutputChannel

    public init(
        client: LiteLLMClient,
        model: String,
        reasoningEffort: ReasoningEffort?,
        registry: ToolRegistry,
        toolContext: ToolContext,
        workingDirectory: FilePath,
        mode: OutputMode,
        maxTurns: Int,
        channel: OutputChannel
    ) {
        self.client = client
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.registry = registry
        self.toolContext = toolContext
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.maxTurns = maxTurns
        self.channel = channel
    }

    private var log: EventLog { EventLog(channel: channel, mode: mode) }

    /// The registered tools bound to this run's context, in registration order so
    /// the wire tool list the model sees is stable across runs (prompt-cache
    /// friendly). Their ``AgentTool/definition``s are what the loop advertises.
    private var agentTools: [any AgentTool] {
        registry.all.map { RegistryTool(tool: $0, context: toolContext) }
    }

    // MARK: The run

    /// Runs the prompt and returns the process exit code.
    ///
    /// Never throws for an ordinary failure: ``DoMoAgent`` settles every run —
    /// provider error, aborted turn, hitting ``maxTurns`` — with a
    /// ``RunStopReason`` rather than an escaping error, and each maps to a
    /// non-zero exit code with a message on stderr, because a headless caller
    /// scripts against the exit code. The `throws` on the signature is kept for
    /// the caller's `try`; nothing in the body reaches it today.
    public func run(prompt: String) async throws -> Int32 {
        let tools = agentTools
        let context = AgentContext(
            systemPrompt: Self.systemPrompt(workingDirectory: workingDirectory, toolNames: registry.names),
            messages: [],
            tools: tools
        )
        let config = AgentLoopConfig(
            model: model,
            // Sequential to preserve Phase 1's strictly source-ordered tool
            // dispatch: `tool_use`/`tool_result` events, and the tool-result
            // messages fed back to the model, appear in the model's own call
            // order. Parallel would reorder the completion-order `tool_result`s.
            toolExecution: .sequential,
            maxTurns: maxTurns,
            // Phase 1 treated any turn whose stop reason was itself a failure as
            // terminal (exit 1) *before* looking at its tool calls — including an
            // unrecognized `finish_reason` (`.unknown`). The loop only short-
            // circuits on `.error`/`.aborted`, so without this a `.unknown` turn
            // that also carries tool calls would run those tools and continue; if
            // a later turn then finished cleanly the whole run would report
            // success (exit 0) on what Phase 1 called a hard failure. Stop the run
            // at the failing turn so `finish` reports it (exit 1). `.length` is a
            // failure too but is deliberately recoverable — the batch is refused
            // and the model retried — so it is excluded, matching Phase 1.
            shouldStopAfterTurn: { turn in
                let reason = turn.message.stopReason
                return reason.isFailure && reason != .length
            }
        )
        let sink = PrintEventSink(
            channel: channel,
            mode: mode,
            sessionModel: model,
            workingDirectory: workingDirectory,
            toolNames: tools.map(\.definition.name)
        )

        // One shared counter across the run's LLM calls. The stream seam is the
        // only place a turn's request begins, so it is where `turn_start` is
        // emitted and the counter advances; the terminal `result` reads it back.
        let turnCounter = TurnCounter()

        let result = await runAgentLoop(
            prompts: [.user(prompt)],
            context: context,
            config: config,
            sink: sink,
            streamFn: streamFunction(counter: turnCounter)
        )

        return finish(result: result, turns: turnCounter.value)
    }

    // MARK: Stream seam

    /// The injected ``AgentStreamFn``: one LLM call, wrapping
    /// ``LiteLLMClient/streamCompletion``.
    ///
    /// `turn_start` is emitted here, synchronously, before the request is built —
    /// so it precedes the `response_metadata` the header callback emits once the
    /// head arrives, reproducing Phase 1's header ordering (`turn_start`, then
    /// `response_metadata`, then the streamed deltas). The counter advances once
    /// per call, which is once per assistant turn.
    private func streamFunction(counter: TurnCounter) -> AgentStreamFn {
        { context in
            let turn = counter.next()
            log.emit("turn_start", ["turn": .int(turn)])
            return client.streamCompletion(
                model: model,
                context: context,
                reasoningEffort: reasoningEffort,
                onResponse: { metadata in onMetadata(metadata) }
            )
        }
    }

    /// Surfaces the initial response headers. The fallback signal is the one that
    /// changes behavior: when a LiteLLM fallback fired, a different model answered
    /// than was requested, and the README is explicit that the UI must say so
    /// "rather than lie". So the warning goes to stderr in *both* modes.
    private func onMetadata(_ metadata: ResponseMetadata) {
        log.emit(
            "response_metadata",
            [
                "status": .int(metadata.status),
                "callId": metadata.callID.map(JSONValue.string) ?? .null,
                "modelId": metadata.modelID.map(JSONValue.string) ?? .null,
                "attemptedFallbacks": metadata.attemptedFallbacks.map(JSONValue.int) ?? .null,
                "fellBack": .bool(metadata.fellBack),
            ]
        )
        if metadata.fellBack {
            let served = metadata.modelID ?? "an unknown model"
            channel.writeErr(
                "warning: request fell back — answered by \(served), not the requested model \(model)\n"
            )
        }
    }

    // MARK: Termination

    /// Maps the loop's outcome to a process exit code, emitting the terminal
    /// `result` or `error` event and, in text mode, the final answer.
    ///
    /// This is the one place the run decides success from failure, so the exit-code
    /// contract lives here: a clean completion is `0`, hitting ``maxTurns`` is `2`,
    /// and every other non-completion is `1`.
    private func finish(result: AgentRunResult, turns: Int) -> Int32 {
        let lastAssistant = Self.lastAssistant(in: result.messages)

        switch result.stopReason {
        case .completed, .terminatedByTool, .stoppedByHook:
            // A run can "complete" on a turn whose stop reason is itself a
            // failure the loop does not short-circuit on — an unrecognized
            // `finish_reason`. ``AssistantMessage/failure`` is the single place
            // that decision lives (`.length` is not a failure; `.unknown` is), so
            // defer to it rather than re-deciding here.
            if let lastAssistant, lastAssistant.failure != nil {
                return fail(lastAssistant)
            }
            if let lastAssistant { finishText(lastAssistant) }
            log.emit("result", ["text": .string(lastAssistant?.text ?? ""), "turns": .int(turns)])
            return 0

        case .errored, .aborted:
            return fail(lastAssistant)

        case .maxTurnsReached:
            // The model still wanted to act when the turn budget ran out. A
            // genuine non-completion: a distinct exit code, and nothing on stdout
            // — there is no clean final answer to print.
            let message = "Reached --max-turns limit (\(maxTurns)) before the model produced a final response"
            log.emit("error", ["message": .string(message), "stopReason": .string("maxTurns")])
            channel.writeErr(message + "\n")
            return 2
        }
    }

    /// Emits the `error` event for a failed terminal turn and returns exit `1`.
    /// The stop reason and message come from the turn itself so a scripted caller
    /// reads the same values Phase 1 reported.
    private func fail(_ assistant: AssistantMessage?) -> Int32 {
        let stopReason = assistant?.stopReason.rawValue ?? "error"
        let message = assistant?.errorMessage ?? "Request \(stopReason)"
        log.emit("error", ["message": .string(message), "stopReason": .string(stopReason)])
        channel.writeErr(message + "\n")
        return 1
    }

    /// Prints the final assistant text in text mode, one text block per line to
    /// match pi's print mode. A no-op in JSON mode, where the `result` event
    /// carries the text instead.
    private func finishText(_ assistant: AssistantMessage) {
        guard mode == .text else { return }
        for block in assistant.content {
            if let text = block.textBlock {
                channel.writeOut(text.text + "\n")
            }
        }
    }

    /// The last assistant message a run produced, which carries the final answer
    /// (on success) or the failing stop reason and message (on error).
    private static func lastAssistant(in messages: [Message]) -> AssistantMessage? {
        for message in messages.reversed() {
            if case .assistant(let assistant) = message { return assistant }
        }
        return nil
    }

    // MARK: System prompt

    /// A minimal coding-assistant system prompt.
    ///
    /// Deliberately terse: a later phase's harness owns the real prompt (with
    /// `AGENTS.md` loading, skills, and the tuned coding instructions). This one
    /// exists only to make the print loop behave sensibly end to end.
    static func systemPrompt(workingDirectory: FilePath, toolNames: [String]) -> String {
        """
        You are DoMoCode, a coding assistant operating headlessly in a terminal.

        The working directory is \(workingDirectory.string). You have these tools: \
        \(toolNames.joined(separator: ", ")). Use them to inspect and modify files and to \
        run shell commands as needed to accomplish the user's request. Prefer acting with \
        the tools over guessing. When the task is complete, reply with a short, direct final \
        answer and no further tool calls.
        """
    }
}
