// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 3: print mode now runs THROUGH `AgentHarness`, so every `-p` run persists
// its transcript to a session file and a later invocation can resume it. Phase 2
// drove `runAgentLoop` directly; the loop call, the context, and per-message
// persistence now belong to the harness, and this file keeps only the *edges*:
// the output channel, the translation of `AgentEvent`s into the newline-delimited
// JSON wire format the mode already emitted, and the mapping of `RunStopReason`
// to an exit code.
//
// The wire format is preserved byte-for-byte: the harness forwards every loop
// event to the sink below unchanged, so the same event `type`s, field shapes, and
// exit codes survive the move. The `--json` header sequence is reproduced by
// emitting `turn_start` and `response_metadata` from inside the stream seam (where
// the response headers become available) rather than from the loop, exactly as
// Phase 1/2 produced them.
//
// One Phase-1 behavior the harness cannot express through its `Configuration` is
// `shouldStopAfterTurn` — the rule that a turn ending on a *failing* stop reason
// (an unrecognized `finish_reason`, kept as `.unknown`) must end the run at exit
// 1 before another LLM call, rather than dispatching its tools and marching on to
// a later clean turn that would falsely report success. `AgentHarness.Configuration`
// exposes no loop-hook passthrough (see the report's "harness gap"), so this file
// reconstructs the effect at the one seam it does own: the injected `streamFn`
// refuses to start a turn once a failing turn has been seen (``RunGuard``).

import DoMoAgent
import DoMoCore
import DoMoHarness
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
    /// Watches each finished assistant turn so the stream seam can refuse the next
    /// one when this turn failed. See ``RunGuard`` and this file's header note on
    /// the harness gap.
    let runGuard: RunGuard

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
                // Record a failing (non-`.length`) turn before the loop dispatches
                // its tools and asks for the next turn: the stream seam reads this
                // to short-circuit, reproducing Phase 1's `shouldStopAfterTurn`.
                // Emit ordering makes this safe — `messageEnd` for turn N lands
                // before turn N+1's `streamFn` call, all on the loop's serial path.
                runGuard.blockIfFailing(assistant)
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

// MARK: - Run guard

/// Reproduces Phase 1's `shouldStopAfterTurn` at the CLI, because
/// ``AgentHarness/Configuration`` exposes no loop-hook passthrough.
///
/// Phase 1 short-circuited a run whose assistant turn ended on a failing stop
/// reason other than `.length` — most importantly an unrecognized `finish_reason`
/// kept as `.unknown` — *before* another provider request. Without that rule a
/// `.unknown` turn that also carried tool calls would run its tools and continue,
/// and a later clean turn would report the whole run as success (exit 0) over a
/// genuine provider failure.
///
/// The harness drives ``runAgentLoop`` itself and does not forward
/// `shouldStopAfterTurn`, so the only seam left is the injected `streamFn`. The
/// sink records the first failing turn here (``blockIfFailing(_:)``); the stream
/// seam consults ``blockingError`` and, once set, refuses to start the next turn
/// by finishing its stream with that error — which the loop settles as `.errored`
/// with no further request. A reference type so the sink and the escaping
/// `streamFn` closure share one instance; `Sendable` because the `Mutex` guards
/// the only mutable field.
final class RunGuard: Sendable {
    private let blocked = Mutex<DoMoError?>(nil)

    /// Records the first failing (non-`.length`) turn. Idempotent: a later failing
    /// turn does not replace the first, which is the one the run should report.
    func blockIfFailing(_ assistant: AssistantMessage) {
        let reason = assistant.stopReason
        guard reason.isFailure, reason != .length else { return }
        let error =
            assistant.failure
            ?? DoMoError(.provider(status: nil, isRetryable: false), "Turn failed: \(reason.rawValue)")
        blocked.withLock { if $0 == nil { $0 = error } }
    }

    /// The recorded failure, or `nil` when no failing turn has been seen. When
    /// non-`nil`, the stream seam must not start another turn.
    var blockingError: DoMoError? { blocked.withLock { $0 } }
}

// MARK: - Session source

/// Where a run's session comes from: a fresh file, a resumed one, or a fork of a
/// resumed one. The command resolves the flags into one of these; ``PrintMode``
/// turns it into the matching ``AgentHarness`` lifecycle call.
public enum SessionSource: Sendable {
    /// Start a brand-new session under the session directory.
    case new
    /// Resume the session at this file, appending to it.
    case resume(FilePath)
    /// Resume the session at this file but branch into a new file, leaving the
    /// original untouched — `--fork`.
    case fork(FilePath)
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
    /// Where this run's session file comes from — new, resumed, or forked.
    let sessionSource: SessionSource
    /// The directory a new (or forked) session file is created under.
    let sessionDirectory: FilePath

    public init(
        client: LiteLLMClient,
        model: String,
        reasoningEffort: ReasoningEffort?,
        registry: ToolRegistry,
        toolContext: ToolContext,
        workingDirectory: FilePath,
        mode: OutputMode,
        maxTurns: Int,
        channel: OutputChannel,
        sessionSource: SessionSource,
        sessionDirectory: FilePath
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
        self.sessionSource = sessionSource
        self.sessionDirectory = sessionDirectory
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
    /// A *conversational* failure never throws: ``DoMoAgent`` settles every run —
    /// provider error, aborted turn, hitting ``maxTurns`` — with a
    /// ``RunStopReason`` rather than an escaping error, and each maps to a
    /// non-zero exit code with a message on stderr, because a headless caller
    /// scripts against the exit code. What *does* throw now is an
    /// infrastructure failure the harness surfaces: a `--resume`/`--session`
    /// target that is not a session, or a disk write that could not durably
    /// record the transcript. Those are real ``DoMoError``s the command turns
    /// into a non-zero exit — a run that could not persist must not report
    /// success.
    public func run(prompt: String) async throws -> Int32 {
        let tools = agentTools

        // One shared counter across the run's LLM calls, and one guard that lets
        // the stream seam refuse a turn after a failing one (the harness has no
        // `shouldStopAfterTurn`). Both are shared by reference into the escaping
        // `streamFn` and the sink.
        let turnCounter = TurnCounter()
        let runGuard = RunGuard()

        let configuration = AgentHarness.Configuration(
            systemPrompt: Self.systemPrompt(workingDirectory: workingDirectory, toolNames: registry.names),
            tools: tools,
            model: model,
            streamFn: streamFunction(counter: turnCounter, runGuard: runGuard),
            // Sequential to preserve Phase 1's strictly source-ordered tool
            // dispatch: `tool_use`/`tool_result` events, and the tool-result
            // messages fed back to the model, appear in the model's own call
            // order. Parallel would reorder the completion-order `tool_result`s.
            toolExecution: .sequential,
            maxTurns: maxTurns
        )

        let harness = try await makeHarness(configuration: configuration)

        let sink = PrintEventSink(
            channel: channel,
            mode: mode,
            sessionModel: model,
            workingDirectory: workingDirectory,
            toolNames: tools.map(\.definition.name),
            runGuard: runGuard
        )

        let result = try await harness.run(prompt: prompt, sink: sink)
        return finish(result: result, turns: turnCounter.value)
    }

    /// Builds the harness for this run's ``SessionSource``: a new file, an opened
    /// one (resume), or a fork of an opened one. Resolution errors — a session
    /// file that is missing or not a session — surface here as a ``DoMoError`` and
    /// become a non-zero exit, which is what a scripted caller expects of a bad
    /// `--resume`/`--session` argument.
    private func makeHarness(configuration: AgentHarness.Configuration) async throws -> AgentHarness {
        switch sessionSource {
        case .new:
            return try AgentHarness.start(
                cwd: workingDirectory.string,
                sessionDirectory: sessionDirectory,
                configuration: configuration
            )
        case .resume(let path):
            return try AgentHarness.open(path: path, configuration: configuration)
        case .fork(let path):
            let base = try AgentHarness.open(path: path, configuration: configuration)
            return try await base.fork(sessionDirectory: sessionDirectory)
        }
    }

    // MARK: Stream seam

    /// The injected ``AgentStreamFn``: one LLM call, wrapping
    /// ``LiteLLMClient/streamCompletion`` — unless a prior turn failed, in which
    /// case it refuses to start another turn.
    ///
    /// `turn_start` is emitted here, synchronously, before the request is built —
    /// so it precedes the `response_metadata` the header callback emits once the
    /// head arrives, reproducing Phase 1's header ordering (`turn_start`, then
    /// `response_metadata`, then the streamed deltas). The counter advances once
    /// per call, which is once per assistant turn.
    ///
    /// When ``RunGuard/blockingError`` is set, the seam finishes the stream with
    /// that error and makes no request: the loop turns a thrown stream into a
    /// terminal `.error` turn and settles `.errored`, so the run stops at the
    /// failing turn (exit 1) without a further provider call — the effect Phase 1
    /// got from `shouldStopAfterTurn`.
    private func streamFunction(counter: TurnCounter, runGuard: RunGuard) -> AgentStreamFn {
        { context in
            if let blocking = runGuard.blockingError {
                return AsyncThrowingStream { $0.finish(throwing: blocking) }
            }
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
