// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/agent-loop.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM
import Foundation

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
    let staticSystemPrompt = context.systemPrompt

    // `transcript` is the full history sent to the model; `produced` is only what
    // this run added, which is what pi returns as `newMessages`.
    var transcript = context.messages
    var produced: [Message] = []
    var recoveryDiagnosticAttempted = false

    /// Ends the run: reports the failure if there is one, closes the stream, and
    /// returns the result.
    ///
    /// The `failure` contract — only ``RunStopReason/errored`` carries one, and a
    /// cancellation never does — is enforced HERE rather than at the call
    /// sites, because every ending in this function funnels through this one
    /// place. That makes the invariant hold by construction: a future
    /// `settle(.completed, failure: x)` cannot produce a result that contradicts
    /// its own stop reason, and there is no case analysis anywhere else to get
    /// wrong.
    ///
    /// The notice is emitted BEFORE `agent_end` and only when a failure is
    /// actually carried, so it can never disagree with
    /// ``AgentRunResult/failure``. The order is load-bearing:
    /// ``AsyncStreamAgentSink`` finishes its continuation on `agentEnd`, so
    /// anything emitted after it is dropped on the floor.
    func settle(
        _ reason: RunStopReason,
        failure: DoMoError? = nil,
        recovery: RecoveryEnvelope? = nil
    ) async -> AgentRunResult {
        let carried: DoMoError?
        if reason == .errored, let failure, !failure.isCancellation {
            carried = failure
        } else {
            carried = nil
        }
        var finalRecovery = recovery
        if let recovery {
            let enriched = recovery.withSessionContext(
                recoverySessionContext(from: transcript)
            )
            finalRecovery = enriched
            if !recoveryDiagnosticAttempted,
               enriched.diagnosis == nil,
               let diagnostic = config.recoveryDiagnostic,
               config.recoveryDiagnosticTimeout > .zero
            {
                recoveryDiagnosticAttempted = true
                let request = RecoveryDiagnosticRequest(
                    envelope: enriched,
                    model: config.model,
                    maxOutputTokens: config.recoveryDiagnosticMaxOutputTokens,
                    timeout: config.recoveryDiagnosticTimeout,
                    readOnlyTools: config.recoveryDiagnosticTools
                )
                if let result = await runRecoveryDiagnostic(
                    diagnostic,
                    request: request,
                    timeout: config.recoveryDiagnosticTimeout
                ) {
                    finalRecovery = enriched.diagnosed(
                        result.diagnosis,
                        attemptedRemedies: result.attemptedRemedies,
                        userApprovedAction: result.userApprovedAction
                    )
                }
            }
        }
        if let finalRecovery {
            await sink.emit(.notice(AgentNotice(finalRecovery)))
        } else if let carried {
            await sink.emit(
                .notice(
                    AgentNotice(
                        level: .error,
                        code: noticeCode(for: carried.kind),
                        // The whole cause chain, one line, redacted, then
                        // capped: a gateway can answer with an entire HTML error
                        // page, and the innermost link of the chain is the one
                        // the HTTP client wrote — request URL and all. Redacting
                        // before the cap matters because truncating first can
                        // split a registered literal, and half a key matches
                        // neither the registry nor a prefix rule.
                        text: DoMoError.truncating(Redaction.diagnostic(carried.description)),
                        kind: carried.kind.label
                    )
                )
            )
        }
        await sink.emit(.agentEnd(messages: produced, reason: reason))
        return AgentRunResult(messages: produced, stopReason: reason, failure: carried)
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
    var accumulatedCost: Decimal = 0
    var lastBatchTerminated = false
    // Runaway guard state. `lastSignature` is the tool work of the previous turn
    // that did any; `repeatedTurns` is how many turns in a row have now produced
    // exactly that work, counting the turn that established it. See the check
    // after each `turn_end`.
    var lastSignature: TurnToolSignature?
    var repeatedTurns = 0
    // Steering may already be queued (the user typed while the agent was idle).
    var pendingMessages = config.drainSteeringBeforeFirstTurn
        ? await drain(config.getSteeringMessages)
        : []

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
            let tools = if let getTools = config.getTools {
                await getTools(config.model)
            } else {
                context.tools
            }
            let toolDefinitions = tools.map(\.definition)
            let systemPrompt = config.systemPromptForTools?(
                config.model,
                toolDefinitions.map(\.name)
            ) ?? staticSystemPrompt
            let dispatch = ToolDispatch(tools: tools, config: config, sink: sink)
            let outcome = await streamAssistantResponse(
                context: Context(systemPrompt: systemPrompt, messages: transcript, tools: toolDefinitions),
                model: config.model,
                sink: sink,
                streamFn: streamFn
            )
            let message = outcome.message
            transcript.append(.assistant(message))
            produced.append(.assistant(message))

            // A failed or aborted turn ends the run immediately.
            if message.stopReason == .error {
                await sink.emit(.turnEnd(message: message, toolResults: []))
                // `outcome.failure` is the provider's own classification, thrown
                // out of the stream and kept rather than stringified. The
                // fallback covers the other producer of an `.error` turn — an
                // assembly-produced `.failed` terminal, which knows only that
                // the provider refused, so `AssistantMessage.failure` answers
                // `.provider(status: nil, isRetryable: false)`. Coarse, but
                // never nil for a `.error` stop reason, so `.errored` always
                // carries evidence.
                return await settle(
                    .errored,
                    failure: outcome.failure ?? message.failure,
                    recovery: outcome.recovery
                )
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

            // Cost is known only once the assistant message is complete. A
            // turn that reaches the ceiling is therefore allowed to finish
            // dispatching and persisting its tool results, but the loop will
            // not issue another model request. Negative values are ignored so
            // a malformed provider response cannot buy additional work.
            if let maxCost = config.maxCostPerRun {
                let turnCost = message.usage.effectiveCostTotal
                if turnCost > 0 { accumulatedCost += turnCost }
                if accumulatedCost >= maxCost {
                    return await settle(.costLimitReached)
                }
            }

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
            // the design. A non-terminating trip can be handed to the optional
            // hook; an approval clears the streak and grants another window,
            // while a denial preserves `.noProgress`.
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
                    if lastBatchTerminated {
                        return await settle(.terminatedByTool)
                    }
                    let turnResult = TurnResult(message: message, toolResults: toolResults, messages: produced)
                    if let onNoProgress = config.onNoProgress, await onNoProgress(turnResult) {
                        // The user explicitly allowed another window. Clearing
                        // the streak means the next approval is another honest
                        // decision after the model has had a chance to change
                        // its behavior.
                        lastSignature = nil
                        repeatedTurns = 0
                    } else {
                        return await settle(.noProgress)
                    }
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

// MARK: - Recovery diagnostics

/// A tiny, cancellation-aware race around the optional diagnostic callback.
/// The callback is expected to use a transport that honors cancellation; the
/// normal CLI implementation does, so cancelling the losing child releases the
/// request rather than letting it spend a second turn after the envelope was
/// already settled.
private enum RecoveryDiagnosticRace: Sendable {
    case result(RecoveryDiagnosticResult?)
    case timedOut
}

private func runRecoveryDiagnostic(
    _ diagnostic: @escaping RecoveryDiagnosticFn,
    request: RecoveryDiagnosticRequest,
    timeout: Duration
) async -> RecoveryDiagnosticResult? {
    await withTaskGroup(of: RecoveryDiagnosticRace.self) { group in
        group.addTask {
            .result(await diagnostic(request))
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return .timedOut
            } catch {
                return .timedOut
            }
        }
        guard let winner = await group.next() else { return nil }
        group.cancelAll()
        if case .result(let result) = winner { return result }
        return nil
    }
}

/// Builds a small, redacted context window for a diagnostic request. Tool
/// output and tool arguments are omitted because they are both noisy and the
/// most likely place for command output to smuggle instructions into a second
/// model call. User/assistant prose still gives a provider diagnosis useful
/// local context without turning the recovery record into a transcript replay.
private func recoverySessionContext(from messages: [Message]) -> String? {
    let lines = messages.suffix(8).compactMap { message -> String? in
        switch message {
        case .user(let user) where !user.text.isEmpty:
            return "user: \(user.text)"
        case .assistant(let assistant) where !assistant.text.isEmpty:
            return "assistant: \(assistant.text)"
        case .system, .tool, .user, .assistant:
            return nil
        }
    }
    guard !lines.isEmpty else { return nil }
    let redacted = Redaction.diagnostic(lines.joined(separator: "\n"))
    return DoMoError.truncating(redacted, to: 2_048)
}

/// Which ``AgentNotice/code`` family a classified failure belongs to.
///
/// Derived from the KIND, not from the catch site that produced it. Two catch
/// sites deciding the code for themselves is exactly how the same 401 ends up
/// filed two different ways depending on which frame it was caught in; here
/// there is one rule and it reads off the classification the failing layer
/// already made.
///
/// Exhaustive with no `default`, so a new ``DoMoError/Kind`` is a compile error
/// in this file rather than a silent misfiling under whichever arm the default
/// happened to be.
private func noticeCode(for kind: DoMoError.Kind) -> String {
    switch kind {
    // Everything that names a step of the model request: the gateway could not
    // be reached, refused the credential, throttled us, ran the account dry,
    // rejected the request as too large, answered with an error, or answered
    // with something no version of the API documents.
    case .transport, .authentication, .rateLimit, .quotaExhausted, .contextOverflow, .provider,
        .malformedResponse:
        return "provider_error"
    // Everything the harness itself owns. `.cancelled` is unreachable — a
    // cancellation never becomes a notice — but naming it keeps the switch
    // total rather than relying on that being true.
    case .toolExecution, .file, .cancelled, .configuration:
        return "runtime_error"
    }
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
///
/// It returns the failure alongside the message rather than only the message,
/// because the message can only carry PROSE. The provider classified the failure
/// — authentication, quota, context overflow — and flattening that into
/// `errorMessage` one frame later left every consumer re-deriving the
/// classification from English. `failure` is `nil` for a turn that did not fail
/// and for one that was cancelled; a cancellation is not a failure.
private func streamAssistantResponse(
    context: Context,
    model: String,
    sink: any AgentEventSink,
    streamFn: AgentStreamFn
) async -> (
    message: AssistantMessage,
    failure: DoMoError?,
    recovery: RecoveryEnvelope?
) {
    var current: AssistantMessage?
    var startEmitted = false
    var recovery: RecoveryEnvelope?

    do {
        for try await event in streamFn(context) {
            if let terminal = event.terminalMessage {
                if !startEmitted {
                    await sink.emit(.messageStart(.assistant(terminal)))
                    startEmitted = true
                }
                await sink.emit(.messageEnd(.assistant(terminal)))
                // Nothing was thrown, so there is no classified error to carry.
                // A `.failed` terminal still reports itself through the
                // message's own `stopReason`; the caller falls back to
                // `AssistantMessage.failure` for it.
                return (terminal, nil, recovery)
            }

            if case .start(let snapshot) = event {
                let message = snapshot.message
                current = message
                await sink.emit(.messageStart(.assistant(message)))
                startEmitted = true
                continue
            }

            // MUST stay above the `startEmitted` guard. A retry is only ever
            // yielded before a 2xx commits the stream, so it always arrives
            // before `.start` — a guard placed above this drops every one of
            // them, which is precisely the bug this ordering fixes. See
            // ``AssemblyEvent/retrying(_:)``, which documents the requirement
            // at the producer.
            //
            // It rides the notice channel rather than `messageUpdate` because
            // every consumer's assembly switch has a `default:` that discards
            // an unrecognized case, and because a retry is not transcript
            // content: it is display-only and must not be persisted.
            if case .retrying(let retry) = event {
                await sink.emit(.notice(AgentNotice(retry)))
                continue
            }

            if case .recovery(let envelope) = event {
                recovery = envelope
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
        let unterminated = "Stream ended without a terminal event"
        return await synthesizeTerminal(
            current: current,
            model: model,
            startEmitted: startEmitted,
            cancelled: Task.isCancelled,
            failure: DoMoError(.malformedResponse, unterminated),
            errorMessage: unterminated,
            sink: sink,
            recovery: recovery
        )
    } catch {
        // `cancelled` is read ONCE and used for both decisions below. Reading
        // `Task.isCancelled` a second time inside `init(wrapping:as:_:)`'s
        // default argument could see a different answer — cancellation can land
        // between the two reads — and would produce a failure whose kind
        // disagrees with the terminal message's stop reason.
        let cancelled = DoMoError.isCancellation(error) || Task.isCancelled
        let classified = error as? DoMoError
        return await synthesizeTerminal(
            current: current,
            model: model,
            startEmitted: startEmitted,
            cancelled: cancelled,
            // A foreign error is wrapped, not relabelled: `init(wrapping:as:_:)`
            // keeps an inner `DoMoError`'s own kind and keeps the cause, so
            // nothing about the classification is invented here.
            failure: classified
                ?? DoMoError(
                    wrapping: error,
                    as: .transport,
                    "The model request failed",
                    cancelled: cancelled
                ),
            // `errorMessage` is the whole cause chain
            // (`DoMoError.description`), so no prose is lost relative to what
            // was carried before the failure value existed — with ONE
            // deliberate exception, which ``synthesizeTerminal`` applies: a
            // credential found in that prose is replaced. That breaks the
            // byte-compat this comment used to claim, and breaking it is the
            // point. This string is appended to the session JSONL and never
            // rewritten, so a gateway that echoed the API key back at us would
            // otherwise leave it on disk for the life of the session.
            errorMessage: classified?.description ?? String(describing: error),
            sink: sink,
            recovery: recovery
        )
    }
}

/// Builds and emits a terminal assistant message for a stream that neither
/// completed nor failed cleanly, preserving whatever partial content arrived.
///
/// `failure` is the classification the caller caught; it is returned only when
/// this is really a failure. The stop reason, the error text and the returned
/// failure all come out of the SAME `cancelled` branch, so they cannot disagree:
/// there is no arrangement of arguments that yields an `.aborted` message
/// carrying a failure, or an `.error` message that silently drops one.
///
/// The single assignment of `errorMessage` is also the single place a credential
/// can be stopped from reaching the transcript, which is why it is redacted
/// here rather than at the two call sites: this message is persisted to the
/// session JSONL and is never rewritten afterwards.
private func synthesizeTerminal(
    current: AssistantMessage?,
    model: String,
    startEmitted: Bool,
    cancelled: Bool,
    failure: DoMoError?,
    errorMessage: String,
    sink: any AgentEventSink,
    recovery: RecoveryEnvelope?
) async -> (
    message: AssistantMessage,
    failure: DoMoError?,
    recovery: RecoveryEnvelope?
) {
    let (stopReason, text, carried): (StopReason, String, DoMoError?) =
        cancelled
        ? (.aborted, "Request was aborted", nil)
        : (.error, errorMessage, failure)
    let message = AssistantMessage(
        content: current?.content ?? [],
        model: model,
        usage: current?.usage ?? .zero,
        stopReason: stopReason,
        errorMessage: Redaction.diagnostic(text)
    )
    if !startEmitted {
        await sink.emit(.messageStart(.assistant(message)))
    }
    await sink.emit(.messageEnd(.assistant(message)))
    return (message, carried, recovery)
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
        case .textDelta, .reasoningDelta, .toolCallDelta, .retrying, .recovery, .done, .failed:
            return nil
        }
    }
}
