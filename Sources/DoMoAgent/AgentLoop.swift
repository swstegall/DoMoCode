// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/agent-loop.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Entry point

/// Runs one agent loop over the injected stream function and tool set.
///
/// Pure: no filesystem, no network, no persistence, no UI. Everything that
/// touches the world arrives injected — the ``AgentStreamFn`` that produces
/// assistant turns, the ``AgentTool``s that do work, and the ``AgentEventSink``
/// that renders progress. That is what makes it cheap to test exhaustively and
/// is why it lives in its own module.
///
/// The shape, ported from pi's `runLoop`, is two nested loops:
///
/// - **Inner loop** — one assistant turn per iteration: inject any steering
///   messages, stream the assistant response, dispatch its tool calls, append
///   the results. It continues while the last turn produced tool calls
///   (`hasMoreToolCalls`) or steering messages are queued.
/// - **Outer loop** — when the inner loop drains, it polls the follow-up queue.
///   A follow-up resumes the whole thing; nothing queued ends the run.
///
/// Stop conditions are named on ``RunStopReason``. `@concurrent` because this is
/// a module seam: everything it calls is plain `nonisolated async` and inherits
/// this off-caller context.
@concurrent
public func runAgentLoop(
    prompts: [Message],
    context: AgentContext,
    config: AgentLoopConfig,
    sink: any AgentEventSink,
    streamFn: AgentStreamFn
) async -> AgentRunResult {
    let systemPrompt = context.systemPrompt
    let toolDefinitions = context.tools.map(\.definition)
    let dispatch = ToolDispatch(tools: context.tools, config: config, sink: sink)

    // `transcript` is the full history sent to the model; `produced` is only what
    // this run added, which is what pi returns as `newMessages`.
    var transcript = context.messages
    var produced: [Message] = []

    func settle(_ reason: RunStopReason) async -> AgentRunResult {
        await sink.emit(.agentEnd(messages: produced, reason: reason))
        return AgentRunResult(messages: produced, stopReason: reason)
    }

    /// A cancelled run settles with a synthesized aborted assistant turn, in
    /// pi's `handleRunFailure` event shape (message start/end, turn_end,
    /// agent_end). The empty content and cleared usage are honest: nothing was
    /// produced this turn.
    func settleAborted() async -> AgentRunResult {
        let message = AssistantMessage(
            content: [],
            model: config.model,
            stopReason: .aborted,
            errorMessage: "Request was aborted"
        )
        await sink.emit(.messageStart(.assistant(message)))
        await sink.emit(.messageEnd(.assistant(message)))
        produced.append(.assistant(message))
        await sink.emit(.turnEnd(message: message, toolResults: []))
        return await settle(.aborted)
    }

    await sink.emit(.agentStart)
    await sink.emit(.turnStart)
    for prompt in prompts {
        await sink.emit(.messageStart(prompt))
        await sink.emit(.messageEnd(prompt))
        transcript.append(prompt)
        produced.append(prompt)
    }

    var firstTurn = true
    var turnCount = 0
    var lastBatchTerminated = false
    // Steering may already be queued (the user typed while the agent was idle).
    var pendingMessages = await drain(config.getSteeringMessages)

    // Outer loop: resumes when a follow-up arrives after the agent would stop.
    while true {
        var hasMoreToolCalls = true

        // Inner loop: assistant turns plus tool calls and steering injection.
        while hasMoreToolCalls || !pendingMessages.isEmpty {
            // Cancellation wins over everything: end with a clean aborted turn
            // rather than starting another provider request.
            if Task.isCancelled {
                return await settleAborted()
            }

            // Max-turn bound: stop before another LLM call rather than after, so
            // no `turn_start` is left dangling.
            if let maxTurns = config.maxTurns, turnCount >= maxTurns {
                return await settle(.maxTurnsReached)
            }

            if firstTurn {
                firstTurn = false
            } else {
                await sink.emit(.turnStart)
            }

            // Inject steering/pending messages before the assistant responds.
            if !pendingMessages.isEmpty {
                for message in pendingMessages {
                    await sink.emit(.messageStart(message))
                    await sink.emit(.messageEnd(message))
                    transcript.append(message)
                    produced.append(message)
                }
                pendingMessages = []
            }

            turnCount += 1
            let message = await streamAssistantResponse(
                context: Context(systemPrompt: systemPrompt, messages: transcript, tools: toolDefinitions),
                model: config.model,
                sink: sink,
                streamFn: streamFn
            )
            transcript.append(.assistant(message))
            produced.append(.assistant(message))

            // A failed or aborted turn ends the run immediately.
            if message.stopReason == .error {
                await sink.emit(.turnEnd(message: message, toolResults: []))
                return await settle(.errored)
            }
            if message.stopReason == .aborted {
                await sink.emit(.turnEnd(message: message, toolResults: []))
                return await settle(.aborted)
            }

            let toolCalls = message.toolCalls
            var toolResults: [ToolResultBlock] = []
            hasMoreToolCalls = false
            // Reset per turn: a turn with no tool calls (or a non-terminating
            // batch) must clear a `terminate` set by an earlier batch, or the
            // final stop reason goes stale when a follow-up/steering message
            // resumes the loop past the terminating turn.
            lastBatchTerminated = false
            if !toolCalls.isEmpty {
                // A `.length` stop may have truncated every tool call's
                // arguments; refuse them all rather than execute a plausible-but-
                // wrong call.
                let batch =
                    message.stopReason == .length
                    ? await dispatch.refuseTruncated(toolCalls, from: message)
                    : await dispatch.run(toolCalls, from: message)
                toolResults = batch.messages
                hasMoreToolCalls = !batch.terminate
                lastBatchTerminated = batch.terminate
                for block in toolResults {
                    transcript.append(.tool(block))
                    produced.append(.tool(block))
                }
            }

            await sink.emit(.turnEnd(message: message, toolResults: toolResults))

            if let shouldStopAfterTurn = config.shouldStopAfterTurn {
                let turnResult = TurnResult(message: message, toolResults: toolResults, messages: produced)
                if await shouldStopAfterTurn(turnResult) {
                    return await settle(.stoppedByHook)
                }
            }

            pendingMessages = await drain(config.getSteeringMessages)
        }

        // The agent would stop here. A follow-up message resumes it.
        let followUps = await drain(config.getFollowUpMessages)
        if !followUps.isEmpty {
            pendingMessages = followUps
            continue
        }
        break
    }

    return await settle(lastBatchTerminated ? .terminatedByTool : .completed)
}

/// Calls an optional queue closure, treating absence as "nothing queued".
private func drain(_ source: (@Sendable () async -> [Message])?) async -> [Message] {
    guard let source else { return [] }
    return await source()
}

// MARK: - One assistant turn

/// Streams a single assistant response, forwarding lifecycle events and returning
/// the finished message.
///
/// This is where the transcript is turned into a ``Context`` for the model. The
/// terminal ``AssemblyEvent`` (`.done`/`.failed`) carries the authoritative
/// message; boundary events refresh a best-known snapshot for ``AgentEvent/messageUpdate``.
///
/// It never rethrows. A stream that throws, or ends without a terminal event, is
/// turned into a synthesized terminal message — `.aborted` when the task was
/// cancelled, `.error` otherwise — so `CancellationError` and transport failures
/// never escape into the loop. This is pi's guarantee that a run always settles
/// with a well-formed transcript.
private func streamAssistantResponse(
    context: Context,
    model: String,
    sink: any AgentEventSink,
    streamFn: AgentStreamFn
) async -> AssistantMessage {
    var current: AssistantMessage?
    var startEmitted = false

    do {
        for try await event in streamFn(context) {
            if let terminal = event.terminalMessage {
                if !startEmitted {
                    await sink.emit(.messageStart(.assistant(terminal)))
                    startEmitted = true
                }
                await sink.emit(.messageEnd(.assistant(terminal)))
                return terminal
            }

            if case .start(let snapshot) = event {
                let message = snapshot.message
                current = message
                await sink.emit(.messageStart(.assistant(message)))
                startEmitted = true
                continue
            }

            guard startEmitted else { continue }
            if let snapshot = event.boundarySnapshot {
                current = snapshot.message
            }
            await sink.emit(
                .messageUpdate(message: .assistant(current ?? AssistantMessage(model: model)), assembly: event)
            )
        }

        // The stream ended without a terminal event. That is a truncated stream
        // if we were cancelled, a malformed one otherwise.
        return await synthesizeTerminal(
            current: current,
            model: model,
            startEmitted: startEmitted,
            cancelled: Task.isCancelled,
            errorMessage: "Stream ended without a terminal event",
            sink: sink
        )
    } catch {
        return await synthesizeTerminal(
            current: current,
            model: model,
            startEmitted: startEmitted,
            cancelled: DoMoError.isCancellation(error) || Task.isCancelled,
            errorMessage: (error as? DoMoError)?.description ?? String(describing: error),
            sink: sink
        )
    }
}

/// Builds and emits a terminal assistant message for a stream that neither
/// completed nor failed cleanly, preserving whatever partial content arrived.
private func synthesizeTerminal(
    current: AssistantMessage?,
    model: String,
    startEmitted: Bool,
    cancelled: Bool,
    errorMessage: String,
    sink: any AgentEventSink
) async -> AssistantMessage {
    let message = AssistantMessage(
        content: current?.content ?? [],
        model: model,
        usage: current?.usage ?? .zero,
        stopReason: cancelled ? .aborted : .error,
        errorMessage: cancelled ? "Request was aborted" : errorMessage
    )
    if !startEmitted {
        await sink.emit(.messageStart(.assistant(message)))
    }
    await sink.emit(.messageEnd(.assistant(message)))
    return message
}

extension AssemblyEvent {
    /// The snapshot an event carries, if any. Boundary events carry one; per-
    /// token deltas and terminal events do not.
    fileprivate var boundarySnapshot: AssistantSnapshot? {
        switch self {
        case .start(let snapshot),
            .textStart(_, let snapshot),
            .textEnd(_, _, let snapshot),
            .reasoningStart(_, let snapshot),
            .reasoningEnd(_, _, let snapshot),
            .toolCallStart(_, let snapshot),
            .toolCallEnd(_, _, let snapshot):
            return snapshot
        case .textDelta, .reasoningDelta, .toolCallDelta, .done, .failed:
            return nil
        }
    }
}
