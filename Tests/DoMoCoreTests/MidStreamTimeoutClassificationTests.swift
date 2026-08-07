// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The mid-answer stall — a gateway that commits a 200, streams half a reply and
// then goes quiet — is the ONLY timeout with partial work worth resuming, and it
// was the one timeout the gateway-continuation loop never fired for.
//
// Why it was invisible: that failure is deliberately not thrown. Throwing it
// would discard the half answer, so the LLM client keeps the content and ends
// the stream with a terminal `.failed` MESSAGE instead. A message carries prose
// and a stop reason, not a kind, so `AssistantMessage.failure` rebuilds it as
// `.provider(status: nil, isRetryable: false)` — at which point
// `DoMoError.isGatewayTimeout`, which reads a `.transport` kind plus its prose,
// answers false and the run just ends.
//
// `DoMoError.init?(recovery:)` is the repair: the client already wrote the
// classification down in the `RecoveryEnvelope` it emits for the same failure a
// moment before that terminal message, precisely so "the taxonomy survives the
// trip instead of being re-derived from prose". These tests pin the read side of
// that, and pin the strings the producers actually write — DoMoCoreTests depends
// on DoMoCore alone, so it cannot call `idleGuarded` or
// `LiteLLMClient.classifyTransport` and get the real thing.

import Foundation
import Testing

import DoMoCore

/// The envelope the client builds for a failure, spelled the way
/// `LiteLLMClient.makeRecoveryEnvelope` spells it: the kind's wire label, the
/// whole cause chain as the detail, and — on the mid-stream path — the status of
/// the response that COMMITTED, which is a 200.
private enum MidStreamFixtures {
    static func envelope(for error: DoMoError, status: Int? = 200) -> RecoveryEnvelope {
        RecoveryEnvelope(
            originalKind: error.kind.label,
            status: status,
            error: error.description,
            model: "test-model",
            recursionPrevented: true
        )
    }

    /// `idleGuarded`'s silence branch, verbatim, at the shipped 120s default.
    static let stalled = DoMoError(
        .transport,
        """
        The model stream stalled — no data for \(Duration.seconds(120)). \
        The connection was still open; it timed out.
        """
    )

    /// `idleGuarded`'s overall branch, verbatim, at the shipped 600s default.
    static let deadlineExceeded = DoMoError(
        .transport,
        "The model stream exceeded its \(Duration.seconds(600)) deadline and timed out."
    )

    /// Stands in for `AsyncHTTPClient.HTTPClientError.readTimeout`, which fires
    /// underneath the idle guard for any silence budget at or above 90 seconds —
    /// including the 120s default — and therefore reaches the same catch.
    struct ReadTimeoutStandIn: Error, CustomStringConvertible {
        var description: String { "HTTPClientError.readTimeout" }
    }
}

// MARK: - The failure that had no way through

@Suite("Mid-stream failures — the kind survives the terminal message")
struct MidStreamTerminalClassificationTests {
    /// The reported defect, end to end at the seam: a stall is raised as
    /// `.transport` with "it timed out", is recorded in the envelope, and comes
    /// back out of it still classifiable as a gateway timeout — which is what
    /// makes the harness send a continuation instead of ending the run.
    @Test("a stalled stream is still a gateway timeout after the round trip")
    func stalledStreamSurvivesTheEnvelope() {
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: MidStreamFixtures.stalled))

        #expect(rebuilt?.kind == .transport)
        #expect(rebuilt?.isGatewayTimeout == true)
    }

    /// This is the shape the loop had to fall back on before the envelope was
    /// consulted: the same prose, flattened onto the kind
    /// `AssistantMessage.failure` invents for an `.error` stop reason. It
    /// classifies false — which is the bug, stated as an assertion so that
    /// deleting the envelope route makes a test fail rather than a feature go
    /// quiet.
    @Test("the coarse rebuild the fallback produces is not recognised")
    func theCoarseFallbackLosesTheTimeout() {
        let coarse = DoMoError(
            .provider(status: nil, isRetryable: false),
            MidStreamFixtures.stalled.description
        )
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: MidStreamFixtures.stalled))

        // Same prose, same failure; only the kind differs, and only the kind
        // decides.
        #expect(!coarse.isGatewayTimeout)
        #expect(rebuilt?.isGatewayTimeout == true)
    }

    @Test("the overall-deadline stall survives the round trip")
    func deadlineExceededSurvivesTheEnvelope() {
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: MidStreamFixtures.deadlineExceeded))

        #expect(rebuilt?.kind == .transport)
        #expect(rebuilt?.isGatewayTimeout == true)
    }

    /// The envelope carries `description` — message AND cause chain — so a
    /// timeout whose only evidence is the enum name of a foreign error survives
    /// too. That is the case the HTTP client's own uneditable 90-second read
    /// timeout arrives as.
    @Test("a timeout named only in the cause chain survives the round trip")
    func causeChainWordingSurvivesTheEnvelope() {
        let thrown = DoMoError(
            .transport,
            "stream chat completion",
            cause: MidStreamFixtures.ReadTimeoutStandIn()
        )
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: thrown))

        // The outer message alone says nothing about time.
        #expect(!DoMoError(.transport, "stream chat completion").isGatewayTimeout)
        #expect(rebuilt?.isGatewayTimeout == true)
    }

    /// The other direction, and the one that must not regress: a socket that was
    /// refused never reached a model, so there is no half-finished answer to
    /// continue and a continuation prompt would be a wasted turn. It keeps its
    /// `.transport` kind — it is still retryable — and stays out of the
    /// continuation loop.
    @Test("connection refused stays out of the continuation loop")
    func connectionRefusedIsNotAGatewayTimeout() {
        let refused = DoMoError(
            .transport,
            "NIOConnectionError(host: \"127.0.0.1\", port: 4000, "
                + "connectionErrors: [connection refused (errno: 61)])"
        )
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: refused, status: nil))

        #expect(rebuilt?.kind == .transport)
        #expect(rebuilt?.isRetryable == true)
        #expect(rebuilt?.isGatewayTimeout == false)
    }

    /// Rebuilding adds no prose of its own, so it cannot leak anything the
    /// envelope had not already scrubbed — and the scrubbing does not disturb the
    /// wording the classifier reads.
    @Test("the rebuilt failure carries the envelope's already-redacted text")
    func rebuiltProseIsTheEnvelopesOwn() {
        let leaky = DoMoError(
            .transport,
            "The model stream stalled after sending sk-1234567890ABCDEFGH and it timed out."
        )
        let envelope = MidStreamFixtures.envelope(for: leaky)
        let rebuilt = DoMoError(recovery: envelope)

        #expect(rebuilt?.description == envelope.error)
        #expect(rebuilt?.description.contains("sk-1234567890ABCDEFGH") == false)
        #expect(rebuilt?.isGatewayTimeout == true)
    }
}

// MARK: - What the label can and cannot carry

@Suite("Mid-stream failures — envelope fidelity")
struct MidStreamEnvelopeFidelityTests {
    /// Every kind the client can record survives as itself. This is the
    /// assertion that catches label drift: `originalKind` is written by
    /// `Kind.label` and read by `Kind.labeled(_:)`, and if the two ever disagree
    /// the mid-stream classification silently reverts to the coarse fallback with
    /// nothing failing anywhere near the edit.
    @Test(
        "every recordable kind round-trips through its label",
        arguments: [
            DoMoError.Kind.transport,
            .authentication,
            .rateLimit(retryAfter: .seconds(30)),
            .quotaExhausted,
            .contextOverflow,
            .provider(status: 503, isRetryable: true),
            .malformedResponse,
            .toolExecution(tool: "bash"),
            .cancelled,
            .configuration,
        ]
    )
    func labelsRoundTrip(kind: DoMoError.Kind) {
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: DoMoError(kind, "failed")))

        #expect(rebuilt?.kind.label == kind.label)
    }

    /// The payloads a label does not carry are not reinvented: `labeled(_:)`
    /// rebuilds at the least committal value, and this pins that nothing here
    /// tries to be cleverer than the wire format.
    @Test("payload-bearing kinds come back at their least committal value")
    func payloadsAreNotInvented() {
        let throttled = DoMoError(recovery: MidStreamFixtures.envelope(
            for: DoMoError(.rateLimit(retryAfter: .seconds(30)), "slow down")))
        // The server-supplied delay is gone with the payload, which is the
        // honest answer: the label never carried it, and inventing one would put
        // a fabricated wait in front of a retry loop.
        #expect(throttled?.kind == .rateLimit(retryAfter: nil))

        let refused = DoMoError(recovery: MidStreamFixtures.envelope(
            for: DoMoError(.provider(status: 503, isRetryable: true), "busy")))
        #expect(refused?.kind == .provider(status: nil, isRetryable: false))
    }

    /// The envelope's status is deliberately NOT folded into a rebuilt
    /// `.provider`. On this path it is the status of the response that COMMITTED
    /// — a 200 — so it never described the failure at all; claiming it as the
    /// error's status would report "the gateway answered 200 and that was the
    /// problem".
    @Test("the envelope's status does not become the error's status")
    func statusIsNotFoldedIn() {
        let committed = DoMoError(recovery: MidStreamFixtures.envelope(
            for: DoMoError(.provider(status: nil, isRetryable: false), "mid-stream error frame"),
            status: 200))

        #expect(committed?.kind == .provider(status: nil, isRetryable: false))
        #expect(committed?.isGatewayTimeout == false)
    }

    /// A kind this build does not know reads as unclassified rather than as
    /// whichever arm a `default:` happened to be — the rule `labeled(_:)` was
    /// written for. The caller then falls back to the coarse message failure,
    /// which is exactly where it was before.
    @Test("an unrecognized label is not a guess", arguments: ["", "gateway_stall", "TRANSPORT", "provider "])
    func unknownLabelsRebuildToNothing(label: String) {
        let envelope = RecoveryEnvelope(originalKind: label, error: "something happened")

        #expect(DoMoError(recovery: envelope) == nil)
    }

    /// A throttle, an overflow, a bad credential and an exhausted budget all
    /// carry timeout-ish prose from time to time, and continuing any of them is
    /// useless or worse. The kind decides, and it comes back intact.
    @Test(
        "failures that must not be continued are not continued",
        arguments: [
            (DoMoError.Kind.rateLimit(retryAfter: nil), "request timed out; slow down"),
            (.contextOverflow, "prompt is too long — the request timed out"),
            (.authentication, "token expired past its deadline"),
            (.quotaExhausted, "monthly usage deadline reached"),
        ]
    )
    func nonContinuableKindsStayNonContinuable(kind: DoMoError.Kind, prose: String) {
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(for: DoMoError(kind, prose)))

        #expect(rebuilt?.isGatewayTimeout == false)
    }

    /// A cancellation rebuilds as one, which is what lets the agent loop drop it
    /// rather than settle `.errored` carrying a failure `settle` would then
    /// refuse to report — leaving an errored run with no evidence.
    @Test("a cancelled envelope is recognisable as a cancellation")
    func cancellationIsRecognisable() {
        let rebuilt = DoMoError(recovery: MidStreamFixtures.envelope(
            for: DoMoError(.cancelled, "Request was aborted")))

        #expect(rebuilt?.isCancellation == true)
    }
}
