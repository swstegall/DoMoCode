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
    // Runaway guard state. `lastSignature` is the tool work of the previous turn
    // that did any; `repeatedTurns` is how many turns in a row have now produced
    // exactly that work, counting the turn that established it. See the check
    // after each `turn_end`.
    var lastSignature: TurnToolSignature?
    var repeatedTurns = 0
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

            // ── Runaway guard ────────────────────────────────────────────────
            // The replacement for a turn cap. It fires ONLY on a state that is
            // definitionally not progress — `noProgressLimit` turns in a row
            // that made the SAME tool calls and got back the SAME results — so
            // it cannot end a run that is doing varied work, however long that
            // work runs. That property is the whole point: a guard that could
            // stop a legitimate 200-turn refactor would be worse than the cap
            // it replaces, because it would be trusted.
            //
            // "The same" means every call's name AND arguments AND every
            // result's tool name, output and error flag, in order.
            // ``TurnToolSignature`` deliberately drops tool-call ids (fresh per
            // turn, so keeping them would make every turn unique and disable the
            // guard) and keeps outputs (dropping them would fire on a legitimate
            // poll whose answer keeps changing). Argument key ORDER cannot
            // matter: `JSONValue.object` is a `[String: JSONValue]`, whose
            // `Hashable` conformance is unordered, so two spellings of the same
            // object compare equal.
            //
            // EVERY turn that did tool work counts, with exactly one exception:
            // a turn with NO tool calls, which clears the streak. That turn is
            // not a repetition of anything — its "repetition" would be that it
            // did no tool work at all — and letting a run stop with
            // `.noProgress` for that reads as a bug.
            //
            // A turn whose batch asked to `terminate` is NOT an exception. It
            // counts like any other, and `terminate` decides only the REASON:
            // at the limit the run settles `.terminatedByTool` instead of
            // `.noProgress`, so the run is reported as ending the way a tool
            // asked it to. That is what the honest-reason requirement actually
            // needs (`terminate` is deliberately not part of
            // ``TurnToolSignature`` — it is not model-visible work — so a
            // `finish`-style tool reporting the same output every call would
            // otherwise be called a runaway on the very turn it stopped the run,
            // flipping print mode's exit code from 0 to 3). SKIPPING the guard
            // on such a turn would go much further and reset the streak, which
            // fails OPEN: a terminating tool plus any external message source
            // (steering, or a follow-up queue that always resumes) clears the
            // streak every turn or every other turn and disables the guard for
            // the whole run — unbounded, since `maxTurns` ships as `nil`. That
            // is precisely the embedder-disableable path the steering rule below
            // exists to prevent, so it is closed BY CONSTRUCTION here: the
            // counting branch has no case analysis to get wrong, and `terminate`
            // is read only when choosing which reason to settle.
            //
            // Steering, by contrast, is NOT a reset. The rule fires on repeated
            // tool work whether or not a human is typing, and that is deliberate
            // both ways: a model that keeps making the same call and getting the
            // same result while being corrected is precisely the stuck case, and
            // if an injected message cleared the streak, any embedder that
            // queues one every turn (a periodic status line, a nagging prompt)
            // would silently disable the only bound an unbounded run has. A user
            // whose steering does land sees the model do something different,
            // which changes the signature and resets the streak on its own.
            //
            // Deliberately NOT detected: longer cycles (A, B, A, B…). Catching
            // those needs a window and a similarity rule, and every such rule
            // can fire on real alternating work. Strict consecutive identity is
            // the only comparison that is safe to leave on by default.
            //
            // Checked after `turn_end` so the turn the user can see is complete
            // before the run settles, and before `shouldStopAfterTurn`, matching
            // the design. Note the hook is NOT consulted on the turn that trips
            // the guard: the run has already been decided, so the guard's reason
            // wins over `.stoppedByHook`.
            //
            // `nil` is the ONLY disable. Anything else clamps UP to 2 rather
            // than switching off, because this is the only bound on a run once
            // `maxTurns` is nil and it must fail closed: a limit below 2 cannot
            // be honoured literally (one turn is not a repetition of anything,
            // so "stop at the first tool call" would fire on perfectly varied
            // work), but answering a request for the strictest possible guard
            // with no guard at all is the wrong direction to fail. With
            // `limit >= 2` the streak below can only reach `limit` through the
            // `+= 1` branch, so exactly `limit` identical turns run and
            // `limit - 1` never stops the run.
            if let requestedLimit = config.noProgressLimit, !toolCalls.isEmpty {
                let limit = max(2, requestedLimit)
                let signature = TurnToolSignature(calls: toolCalls, results: toolResults)
                if signature == lastSignature {
                    repeatedTurns += 1
                } else {
                    lastSignature = signature
                    repeatedTurns = 1
                }
                if repeatedTurns >= limit {
                    return await settle(lastBatchTerminated ? .terminatedByTool : .noProgress)
                }
            } else {
                lastSignature = nil
                repeatedTurns = 0
            }

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
        case .textDelta, .reasoningDelta, .toolCallDelta, .retrying, .done, .failed:
            return nil
        }
    }
}
