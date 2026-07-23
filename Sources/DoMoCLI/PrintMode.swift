// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// This file is deliberately an *ad-hoc* agent loop. Phase 2 replaces it wholesale
// with `DoMoAgent` — a pure, heavily unit-tested turn machine — and the README's
// roadmap says exactly that: "Phase 2 — The agent loop. DoMoAgent as a pure,
// heavily unit-tested function; Phase 1's ad-hoc loop is retrofitted onto it."
// So this ports only the *shape* of pi's `runLoop` (stream a turn, dispatch tool
// calls, append results, repeat until the model stops), not its steering queues,
// parallel/sequential execution modes, compaction, or stop-condition hooks. When
// something here reads thinner than pi, that is the intended Phase-1 narrowing,
// not an oversight.

import DoMoCore
import DoMoExec
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

/// Emits the JSON event stream. A no-op in text mode, so the loop can call it
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

// MARK: - Print mode

/// Runs a single prompt to completion and prints the result.
///
/// `Sendable` because its stored dependencies are, and because the streaming
/// client's header callback captures pieces of it across an isolation boundary.
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

    /// The tool set as the model sees it, in registration order so the wire tool
    /// list is stable across runs (prompt-cache friendliness carries over even to
    /// this throwaway loop).
    private var toolDefinitions: [ToolDefinition] {
        registry.all.map { ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    // MARK: The loop

    /// Runs the prompt and returns the process exit code.
    ///
    /// Never throws for an ordinary failure: a provider error, an aborted turn, or
    /// hitting ``maxTurns`` all resolve to a non-zero exit code with a message on
    /// stderr, because a headless caller scripts against the exit code, not a
    /// stack trace. It rethrows only a genuine setup fault (an un-buildable
    /// request) that has no meaningful terminal turn.
    public func run(prompt: String) async throws -> Int32 {
        var messages: [Message] = [.user(prompt)]
        let tools = toolDefinitions

        log.emit(
            "session_start",
            [
                "model": .string(model),
                "workingDirectory": .string(workingDirectory.string),
                "tools": .array(tools.map { .string($0.name) }),
            ]
        )
        log.emit("user", ["text": .string(prompt)])

        for turn in 1...max(1, maxTurns) {
            log.emit("turn_start", ["turn": .int(turn)])

            let context = Context(
                systemPrompt: Self.systemPrompt(workingDirectory: workingDirectory, toolNames: registry.names),
                messages: messages,
                tools: tools
            )

            let assistant: AssistantMessage
            do {
                assistant = try await streamTurn(context: context)
            } catch let error as DoMoError {
                return fail(error)
            }

            messages.append(.assistant(assistant))
            emitAssistant(assistant)

            // A terminal turn that did not end cleanly ends the run. `.length` is
            // not terminal on its own — it means the model was cut off and its
            // (possibly truncated) tool calls are handled below — so it is not
            // caught here.
            switch assistant.stopReason {
            case .error, .aborted, .unknown:
                let message = assistant.errorMessage ?? "Request \(assistant.stopReason.rawValue)"
                log.emit("error", ["message": .string(message), "stopReason": .string(assistant.stopReason.rawValue)])
                channel.writeErr(message + "\n")
                return 1
            case .stop, .toolUse, .length:
                break
            }

            let toolCalls = assistant.toolCalls
            if toolCalls.isEmpty {
                finishText(assistant)
                log.emit("result", ["text": .string(assistant.text), "turns": .int(turn)])
                return 0
            }

            // A `length` stop means the output was cut off mid-serialization, so
            // every tool call in the message may carry silently truncated
            // arguments — the repaired parse can even validate. None are safe to
            // run; fail each so the model re-issues it. Ported from pi's
            // `failToolCallsFromTruncatedMessage`.
            if assistant.stopReason == .length {
                for call in toolCalls {
                    let text = """
                        Tool call "\(call.name)" was not executed: the response hit the output token limit, \
                        so its arguments may be truncated. Re-issue the tool call with complete arguments.
                        """
                    appendToolResult(&messages, call: call, output: text, isError: true)
                }
                continue
            }

            do {
                try await dispatch(toolCalls, into: &messages)
            } catch {
                // `error` is a `DoMoError` — `dispatch` has typed throws.
                // Tool failures come back as error results, not throws, so anything
                // that escapes here is cancellation or an unexpected fault — either
                // way the run cannot continue. Feeding the model a fabricated result
                // would be worse than stopping.
                let reason = error.isCancellation ? "aborted" : "error"
                log.emit("error", ["message": .string(error.description), "stopReason": .string(reason)])
                channel.writeErr(error.description + "\n")
                return 1
            }
        }

        // The model still wanted to act when the turn budget ran out. This is a
        // genuine non-completion, so it is a non-zero exit with nothing written to
        // stdout — there is no clean final answer to print.
        let message = "Reached --max-turns limit (\(maxTurns)) before the model produced a final response"
        log.emit("error", ["message": .string(message), "stopReason": .string("maxTurns")])
        channel.writeErr(message + "\n")
        return 2
    }

    // MARK: One streamed turn

    /// Streams one assistant turn to its terminal message, emitting deltas in
    /// JSON mode. A pre-stream failure (bad status, dead connection after retries)
    /// is thrown as a ``DoMoError``; a mid-stream failure arrives as a terminal
    /// message whose ``AssistantMessage/stopReason`` the caller inspects.
    private func streamTurn(context: Context) async throws -> AssistantMessage {
        let stream = client.streamCompletion(
            model: model,
            context: context,
            reasoningEffort: reasoningEffort,
            onResponse: { metadata in onMetadata(metadata) }
        )

        var terminal: AssistantMessage?
        do {
            for try await event in stream {
                switch event {
                case .textDelta(_, let delta):
                    log.emit("text_delta", ["text": .string(delta)])
                case .reasoningDelta(_, let delta):
                    log.emit("reasoning_delta", ["text": .string(delta)])
                case .done(let message), .failed(let message):
                    terminal = message
                default:
                    break
                }
            }
        } catch let error as DoMoError {
            throw error
        } catch {
            throw DoMoError(wrapping: error, as: .transport, "streaming completion failed")
        }

        guard let terminal else {
            throw DoMoError(.malformedResponse, "Stream ended without a terminal message")
        }
        return terminal
    }

    // MARK: Tool dispatch

    /// Runs each requested tool in order and appends its result to the transcript.
    ///
    /// A tool that *fails* comes back as an error ``ToolResult`` (never a throw —
    /// see ``ToolResult``) and is fed straight back to the model, which is how the
    /// loop recovers instead of aborting. Only cancellation throws out of here.
    private func dispatch(_ toolCalls: [ToolCallBlock], into messages: inout [Message]) async throws(DoMoError) {
        for call in toolCalls {
            log.emit(
                "tool_use",
                [
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": call.arguments,
                ]
            )
            let result = try await registry.execute(call.name, arguments: call.arguments, in: toolContext)
            let output = result.text
            log.emit(
                "tool_result",
                [
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "isError": .bool(result.isError),
                    "output": .string(output),
                ]
            )
            appendToolResult(&messages, call: call, output: output, isError: result.isError)
        }
    }

    private func appendToolResult(_ messages: inout [Message], call: ToolCallBlock, output: String, isError: Bool) {
        messages.append(
            .tool(ToolResultBlock(toolCallID: call.id, toolName: call.name, output: output, isError: isError))
        )
    }

    // MARK: Output

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

    private func fail(_ error: DoMoError) -> Int32 {
        log.emit("error", ["message": .string(error.description), "stopReason": .string("error")])
        channel.writeErr(error.description + "\n")
        return 1
    }

    // MARK: System prompt

    /// A minimal coding-assistant system prompt.
    ///
    /// Deliberately terse: Phase 2's harness owns the real prompt (with
    /// `AGENTS.md` loading, skills, and the tuned coding instructions). This one
    /// exists only to make the Phase-1 tool loop behave sensibly end to end.
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
