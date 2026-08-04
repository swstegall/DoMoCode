// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM
import Testing

@testable import DoMoAgent

/// The retry-visibility contract.
///
/// `AssemblyEvent.retrying` is yielded only before a 2xx commits the stream, so
/// it always arrives before the turn's first `.start`. The loop's fold used to
/// discard everything ahead of `.start`, which meant every retry the client ever
/// made was dropped on the floor: the run went quiet for the whole backoff and
/// no surface could say why. These pin the ordering that fixes it.
@Suite
struct RetryNoticeTests {

    private static func retrying(
        attempt: Int = 1,
        maxAttempts: Int = 10,
        delay: Duration = .seconds(8),
        reason: RetryNotice.Reason = .overloaded,
        message: String = "upstream at capacity"
    ) -> AssemblyEvent {
        .retrying(
            RetryNotice(
                attempt: attempt,
                maxAttempts: maxAttempts,
                delay: delay,
                reason: reason,
                message: message
            )
        )
    }

    private static func notices(_ sink: RecordingSink) -> [AgentNotice] {
        sink.events.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
    }

    /// The regression this whole change exists for: a retry ahead of `.start` is
    /// reported, not swallowed.
    @Test
    func aRetryBeforeTheStreamStartsReachesTheSink() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "hello", stopReason: .stop)
        script.insert(Self.retrying(attempt: 3, delay: .seconds(8)), at: 0)
        let stream = ScriptedStream([script])

        let result = await runOnce(sink: sink, streamFn: stream.fn)

        #expect(result.stopReason == .completed)
        let notices = Self.notices(sink)
        #expect(notices.count == 1)
        #expect(notices.first?.code == "retry")
        #expect(notices.first?.text == "Retrying in 8s (request 4/10) — provider busy")
        #expect(notices.first?.detail == "upstream at capacity")
        #expect(notices.first?.ttl == .seconds(8))
    }

    /// A retry is not a failure. `error` is the level that opens a *permanent*
    /// transcript row in the full-screen client and memoizes a failure kind; a
    /// waiting run must not take that door.
    @Test
    func aRetryIsAWarningNotAnError() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "hi", stopReason: .stop)
        script.insert(Self.retrying(), at: 0)

        _ = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        #expect(Self.notices(sink).first?.level == .warning)
        #expect(Self.notices(sink).first?.kind == nil)
    }

    /// The notice lands before the assistant message it belongs to, so a
    /// transcript that appends in arrival order reads in causal order.
    @Test
    func theNoticePrecedesTheMessageItPreparesFor() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "hello", stopReason: .stop)
        script.insert(Self.retrying(), at: 0)

        _ = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        let notice = sink.kinds.firstIndex(of: "notice(retry)")
        let start = sink.kinds.firstIndex(of: "messageStart(assistant)")
        #expect(notice != nil)
        #expect(start != nil)
        if let notice, let start { #expect(notice < start) }
    }

    /// Every attempt is reported, not just the first — the point is that a user
    /// watching a five-minute backoff sees it advancing.
    @Test
    func everyAttemptIsReported() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "eventually", stopReason: .stop)
        for attempt in (1...3).reversed() {
            script.insert(Self.retrying(attempt: attempt, delay: .seconds(attempt)), at: 0)
        }

        _ = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        let notices = Self.notices(sink)
        #expect(notices.count == 3)
        #expect(notices.map(\.text) == [
            "Retrying in 1s (request 2/10) — provider busy",
            "Retrying in 2s (request 3/10) — provider busy",
            "Retrying in 3s (request 4/10) — provider busy",
        ])
    }

    /// A retry that never clears produces retry notices AND the terminal error
    /// notice — they are different levels and different codes, so a surface can
    /// tell "still trying" from "gave up".
    @Test
    func givingUpStillReportsTheFailureSeparately() async {
        let sink = RecordingSink()
        let stream: AgentStreamFn = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(Self.retrying(attempt: 1, maxAttempts: 1))
                continuation.finish(
                    throwing: DoMoError(.provider(status: 503, isRetryable: true), "still overloaded"))
            }
        }

        let result = await runOnce(sink: sink, streamFn: stream)

        #expect(result.stopReason == .errored)
        let notices = Self.notices(sink)
        #expect(notices.map(\.code) == ["retry", "provider_error"])
        #expect(notices.map(\.level) == [.warning, .error])
    }

    @Test
    func aRecoveryEnvelopeReachesTheErrorNotice() async {
        let sink = RecordingSink()
        let envelope = RecoveryEnvelope(
            originalKind: "provider",
            status: 503,
            error: "upstream overloaded",
            model: "m",
            recursionPrevented: true
        )
        var script = assistantTurn(text: "", stopReason: .error)
        script.insert(.recovery(envelope), at: 0)

        let result = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        #expect(result.stopReason == .errored)
        #expect(sink.errorNotices.count == 1)
        #expect(sink.errorNotices.first?.code == "recovery")
        #expect(sink.errorNotices.first?.recovery == envelope)
        #expect((sink.noticeIndices.first ?? .max) < sink.agentEndIndex)
    }

    /// A turn that never retries emits no notice at all. Guards against a fold
    /// that reports something on the happy path.
    @Test
    func aCleanTurnEmitsNoNotice() async {
        let sink = RecordingSink()

        _ = await runOnce(sink: sink, streamFn: ScriptedStream([assistantTurn(text: "hi", stopReason: .stop)]).fn)

        #expect(Self.notices(sink).isEmpty)
    }

    /// An empty provider message must not become an empty `detail` line, because
    /// consumers render `detail` as its own row when it is present.
    @Test
    func anEmptyProviderMessageLeavesNoDetail() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "hi", stopReason: .stop)
        script.insert(Self.retrying(message: ""), at: 0)

        _ = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        #expect(Self.notices(sink).first?.detail == nil)
    }

    /// A retry notice is display, never conversation: it must not appear in the
    /// messages the run produces, or it would be replayed to the model.
    @Test
    func aRetryNoticeIsNotATranscriptMessage() async {
        let sink = RecordingSink()
        var script = assistantTurn(text: "hello", stopReason: .stop)
        script.insert(Self.retrying(), at: 0)

        let result = await runOnce(sink: sink, streamFn: ScriptedStream([script]).fn)

        // The user prompt plus one assistant turn, and nothing else — in
        // particular no synthesized message carrying the retry text.
        #expect(result.messages.count == 2)
        #expect(result.assistantMessages.count == 1)
        #expect(result.assistantMessages.first?.text == "hello")
        #expect(!result.messages.contains { "\($0)".contains("Retrying") })
    }
}
