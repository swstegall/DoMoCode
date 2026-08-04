// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The classified failure has to survive the agent loop.
//
// `LiteLLMClient` finishes a 401/402/413/429 stream `throwing:` a fully
// classified `DoMoError`, and the loop used to flatten it into a string one
// frame later — which is why a failed run reached the user as the bare word
// "errored". These tests pin the two halves of the fix:
//
//  1. `AgentRunResult.failure` carries the error VALUE, `Kind` intact, so a
//     caller can tell "the gateway is down" from "your key is wrong" from "you
//     blew the context window" without parsing prose.
//  2. An `AgentEvent.notice` carrying the same classification reaches the sink
//     BEFORE `agent_end`, which is the only ordering a live UI can consume
//     (`AsyncStreamAgentSink` finishes its continuation on `agentEnd`).
//
// The negative half matters just as much: every clean ending — and every
// cancellation — must leave `failure` nil and emit no error notice. An
// interrupt drawn in red as a failure is a bug report the user then files.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Testing

// MARK: - Support

extension RecordingSink {
    /// Every notice the run emitted, in order.
    var notices: [AgentNotice] {
        events.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }
    /// Notices a UI would draw as a failure.
    var errorNotices: [AgentNotice] { notices.filter { $0.level == .error } }
    /// Index of the `agent_end` emission, or `events.count` if there was none.
    var agentEndIndex: Int {
        events.firstIndex { if case .agentEnd = $0 { true } else { false } } ?? events.count
    }
    var noticeIndices: [Int] {
        events.indices.filter { if case .notice = events[$0] { true } else { false } }
    }
}

/// A stream that fails the turn by throwing `error` before yielding anything.
private func throwingStream(_ error: any Error) -> AgentStreamFn {
    { _ in AsyncThrowingStream { $0.finish(throwing: error) } }
}

/// A foreign (non-`DoMoError`) failure, to prove the wrapping path. Plain, so
/// `String(describing:)` renders it as `"WidgetFault()"` — the exact spelling
/// the transcript used before the failure started being carried.
private struct WidgetFault: Error {}

// MARK: - The failure is carried, with its Kind

@Test func erroredRunCarriesTheClassifiedAuthenticationFailure() async {
    let sink = RecordingSink()

    let result = await runOnce(
        sink: sink,
        streamFn: throwingStream(
            DoMoError(.authentication, "stream chat completions: HTTP 401: Invalid API key")
        )
    )

    #expect(result.stopReason == .errored)
    #expect(result.failure?.kind == .authentication)
    #expect(result.failure?.description.contains("401") == true)
    // Byte-compat: the persisted transcript says exactly what it said before the
    // failure started being carried.
    #expect(
        result.assistantMessages.first?.errorMessage
            == "stream chat completions: HTTP 401: Invalid API key"
    )
}

@Test func eachProviderClassificationSurvivesIntact() async {
    let cases: [(DoMoError.Kind, String)] = [
        (.transport, "socket hang up"),
        (.authentication, "HTTP 401"),
        (.rateLimit(retryAfter: .seconds(3)), "HTTP 429"),
        (.quotaExhausted, "HTTP 402"),
        (.contextOverflow, "HTTP 413"),
        (.provider(status: 503, isRetryable: true), "HTTP 503"),
        (.malformedResponse, "unparseable SSE frame"),
        (.configuration, "no model selected"),
    ]
    for (kind, message) in cases {
        let sink = RecordingSink()
        let result = await runOnce(sink: sink, streamFn: throwingStream(DoMoError(kind, message)))
        #expect(result.stopReason == .errored)
        #expect(result.failure?.kind == kind, "\(kind) was not carried")
        #expect(result.failure?.description == message)
    }
}

@Test func aForeignThrowIsWrappedAsTransportWithoutChangingTheTranscript() async {
    let sink = RecordingSink()

    let result = await runOnce(sink: sink, streamFn: throwingStream(WidgetFault()))

    #expect(result.stopReason == .errored)
    #expect(result.failure?.kind == .transport)
    // The cause is kept, not flattened away.
    #expect(result.failure?.rootCause == "WidgetFault()")
    #expect(result.failure?.description.hasPrefix("The model request failed") == true)
    // Byte-compat with the old `String(describing: error)` spelling.
    #expect(result.assistantMessages.first?.errorMessage == "WidgetFault()")
}

@Test func aStreamThatEndsWithoutATerminalEventIsAMalformedResponse() async {
    let sink = RecordingSink()

    let result = await runOnce(sink: sink, streamFn: { _ in AsyncThrowingStream { $0.finish() } })

    #expect(result.stopReason == .errored)
    #expect(result.failure?.kind == .malformedResponse)
    #expect(result.failure?.description == "Stream ended without a terminal event")
    #expect(result.assistantMessages.first?.errorMessage == "Stream ended without a terminal event")
}

@Test func anAssemblyFailedTurnFallsBackToTheMessagesOwnFailure() async {
    // No throw at all: the assembly itself produced a `.failed` terminal, which
    // is the coarse-but-correct `.provider` classification.
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "", stopReason: .error)])

    let result = await runOnce(sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .errored)
    #expect(result.failure?.kind == .provider(status: nil, isRetryable: false))
    #expect(result.failure != nil)
}

// MARK: - A cancellation is not a failure

@Test func aCancelledRunReportsNoFailureAndNoErrorNotice() async {
    let started = Latch()
    let streamFn: AgentStreamFn = { _ in
        AsyncThrowingStream { continuation in
            let producer = Task {
                continuation.yield(.start(AssistantSnapshot(model: "m")))
                started.open()
                while !Task.isCancelled { await Task.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    let sink = RecordingSink()

    let task = Task { await runOnce(sink: sink, streamFn: streamFn) }
    await started.wait()
    task.cancel()
    let result = await task.value

    #expect(result.stopReason == .aborted)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func aStreamThrowingCancellationReportsNoFailure() async {
    let sink = RecordingSink()

    // The stream throws an already-classified cancellation without the task
    // itself being cancelled — the shape a torn-down socket takes.
    let result = await runOnce(
        sink: sink,
        streamFn: throwingStream(DoMoError(.cancelled, "Request was aborted"))
    )

    #expect(result.stopReason == .aborted)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func aStreamThrowingCancellationErrorReportsNoFailure() async {
    let sink = RecordingSink()

    let result = await runOnce(sink: sink, streamFn: throwingStream(CancellationError()))

    #expect(result.stopReason == .aborted)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

// MARK: - Every clean ending leaves it nil

@Test func aCompletedRunReportsNoFailure() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "hello", stopReason: .stop)])

    let result = await runOnce(sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .completed)
    #expect(result.failure == nil)
    #expect(sink.notices.isEmpty)
}

@Test func aTruncatedTurnIsNotAFailure() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "cut off", stopReason: .length)])

    let result = await runOnce(sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .completed)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func maxTurnsReachedReportsNoFailure() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse)])

    let result = await runOnce(
        context: AgentContext(tools: [echoTool("loop")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: 1),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .maxTurnsReached)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func stoppedByHookReportsNoFailure() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse)])

    let result = await runOnce(
        context: AgentContext(tools: [echoTool("loop")]),
        config: AgentLoopConfig(model: "test-model", shouldStopAfterTurn: { _ in true }),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .stoppedByHook)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func terminatedByToolReportsNoFailure() async {
    let sink = RecordingSink()
    let stop = FakeTool("stop") { _ in AgentToolResult(output: "stopping", terminate: true) }
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("stop")], stopReason: .toolUse)])

    let result = await runOnce(
        context: AgentContext(tools: [stop]),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .terminatedByTool)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

@Test func noProgressReportsNoFailure() async {
    // Two identical turns with a constant answer trip the guard at its floor.
    let sink = RecordingSink()
    let same = FakeTool("stuck") { _ in AgentToolResult(output: "same answer") }
    let stream = ScriptedStream(
        (0..<4).map { index in
            assistantTurn(toolCalls: [tc("stuck", id: "call-\(index)")], stopReason: .toolUse)
        }
    )

    let result = await runOnce(
        context: AgentContext(tools: [same]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 2),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.failure == nil)
    #expect(sink.errorNotices.isEmpty)
}

// MARK: - The notice reaches the sink

@Test func aProviderFailureEmitsOneErrorNoticeCarryingTheKindLabel() async {
    let sink = RecordingSink()

    let result = await runOnce(
        sink: sink,
        streamFn: throwingStream(DoMoError(.authentication, "HTTP 401: Invalid API key"))
    )

    #expect(result.failure?.kind == .authentication)
    #expect(sink.errorNotices.count == 1)
    let notice = sink.errorNotices.first
    #expect(notice?.level == .error)
    #expect(notice?.code == "provider_error")
    #expect(notice?.kind == "authentication")
    #expect(notice?.text.contains("Invalid API key") == true)
    // The kind label is the round-trippable one, so a wire consumer can rebuild
    // the classification without parsing the prose.
    #expect(DoMoError.Kind.labeled(notice?.kind ?? "") == .authentication)
}

@Test func theErrorNoticeArrivesBeforeAgentEnd() async {
    // `AsyncStreamAgentSink` finishes its continuation on `agentEnd`; a notice
    // emitted after it would never be delivered to a live UI.
    let sink = RecordingSink()

    _ = await runOnce(sink: sink, streamFn: throwingStream(DoMoError(.transport, "socket hang up")))

    #expect(sink.noticeIndices.count == 1)
    #expect((sink.noticeIndices.first ?? .max) < sink.agentEndIndex)
    #expect(sink.kinds.last == "agentEnd")
}

@Test func aFinalProviderFailureGetsOneBoundedDiagnosticSubturn() async {
    let sink = RecordingSink()
    let calls = Box(0)
    let requests = Box<[RecoveryDiagnosticRequest]>([])
    let diagnostic: RecoveryDiagnosticFn = { request in
        calls.withLock { $0 += 1 }
        requests.withLock { $0.append(request) }
        return RecoveryDiagnosticResult(
            diagnosis: "the gateway rejected the request before producing a response",
            attemptedRemedies: ["checked the classified response", "did not mutate configuration"]
        )
    }
    let envelope = RecoveryEnvelope(
        originalKind: "authentication",
        status: 401,
        error: "invalid key",
        model: "test-model"
    )
    let readOnlyTool = FakeTool("diagnostic_read") { _ in
        AgentToolResult(output: "safe inspection")
    }
    let stream: AgentStreamFn = { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.recovery(envelope))
            continuation.finish(throwing: DoMoError(.authentication, "invalid key"))
        }
    }

    let result = await runOnce(
        prompt: "inspect the gateway",
        config: AgentLoopConfig(
            model: "test-model",
            recoveryDiagnostic: diagnostic,
            recoveryDiagnosticTimeout: .seconds(1),
            recoveryDiagnosticTools: [readOnlyTool]
        ),
        sink: sink,
        streamFn: stream
    )

    #expect(result.stopReason == .errored)
    #expect(calls.value == 1)
    #expect(requests.value.count == 1)
    #expect(requests.value[0].untrustedInput.contains("UNTRUSTED DOMOCODE RECOVERY DATA"))
    #expect(requests.value[0].envelope.sessionContext?.contains("user: inspect the gateway") == true)
    #expect(requests.value[0].readOnlyTools.map(\.definition.name) == ["diagnostic_read"])
    #expect(sink.errorNotices.count == 1)
    #expect(sink.errorNotices.first?.recovery?.diagnosis?.contains("gateway rejected") == true)
    #expect(sink.errorNotices.first?.recovery?.attemptedRemedies.count == 2)
    #expect((sink.noticeIndices.first ?? .max) < sink.agentEndIndex)
}

@Test func aDiagnosticCallbackCannotRecurseOrRunWhenItsBudgetIsDisabled() async {
    let sink = RecordingSink()
    let calls = Box(0)
    let diagnostic: RecoveryDiagnosticFn = { _ in
        calls.withLock { $0 += 1 }
        return RecoveryDiagnosticResult(diagnosis: "should not be called")
    }
    let stream: AgentStreamFn = { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.recovery(RecoveryEnvelope(
                originalKind: "provider",
                status: 503,
                error: "busy"
            )))
            continuation.finish(throwing: DoMoError(.provider(status: 503, isRetryable: true), "busy"))
        }
    }

    _ = await runOnce(
        config: AgentLoopConfig(
            model: "test-model",
            recoveryDiagnostic: diagnostic,
            recoveryDiagnosticTimeout: .zero
        ),
        sink: sink,
        streamFn: stream
    )

    #expect(calls.value == 0)
    #expect(sink.errorNotices.first?.recovery?.diagnosis == nil)
}

@Test func aHarnessSideFailureIsFiledAsARuntimeError() async {
    let sink = RecordingSink()

    _ = await runOnce(
        sink: sink,
        streamFn: throwingStream(DoMoError(.configuration, "no model selected"))
    )

    #expect(sink.errorNotices.first?.code == "runtime_error")
    #expect(sink.errorNotices.first?.kind == "configuration")
}

@Test func theNoticeAndTheRunResultNeverDisagree() async {
    // One emission per failure, and exactly when `failure` is set — the two are
    // produced by the same branch, and this is what pins that.
    let scenarios: [(any Error, Bool)] = [
        (DoMoError(.authentication, "HTTP 401"), true),
        (DoMoError(.cancelled, "aborted"), false),
        (CancellationError(), false),
        (WidgetFault(), true),
    ]
    for (error, expectsFailure) in scenarios {
        let sink = RecordingSink()
        let result = await runOnce(sink: sink, streamFn: throwingStream(error))
        #expect((result.failure != nil) == expectsFailure, "\(error)")
        #expect(sink.errorNotices.count == (expectsFailure ? 1 : 0), "\(error)")
        if let failure = result.failure {
            #expect(sink.errorNotices.first?.kind == failure.kind.label)
            #expect(sink.errorNotices.first?.text == DoMoError.truncating(failure.description))
        }
    }
}

@Test func aHugeProviderBodyIsCappedInTheNotice() async {
    // A gateway can answer with an entire HTML error page; the notice is one
    // line and must not become the payload problem.
    let sink = RecordingSink()
    let body = String(repeating: "x", count: DoMoError.maxErrorBodyCharacters + 500)

    _ = await runOnce(sink: sink, streamFn: throwingStream(DoMoError(.provider(status: 500, isRetryable: true), body)))

    let text = sink.errorNotices.first?.text ?? ""
    #expect(text.count < body.count)
    #expect(text.hasSuffix("chars]"))
}
