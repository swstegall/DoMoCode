// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - The strings this package actually produces

/// The failures `DoMoError.isGatewayTimeout` exists to recognise, spelled the
/// way the two sites that build them spell them.
///
/// The messages below are copies. DoMoCoreTests depends on DoMoCore alone, so
/// it cannot call `idleGuarded` or `LiteLLMClient.classifyTransport` to get the
/// real thing — which is precisely why they are pinned here: the classifier
/// reads prose, so a reworded message in DoMoLLM silently stops the
/// gateway-continuation loop from ever firing, with no compiler error and no
/// failing test anywhere near the edit. If one of these assertions fails after
/// a wording change in DoMoLLM, the wording change is the bug or this list is
/// stale — check `Transport.swift`'s `idleGuarded` and
/// `LiteLLMClient.classifyTransport` before touching the matcher.
@Suite("Gateway timeout classification — real failure strings")
struct GatewayTimeoutRealStringsTests {
    /// Stands in for `AsyncHTTPClient.HTTPClientError.readTimeout`. The real
    /// type is not reachable from this target (and not from DoMoCore either,
    /// which is the whole reason the classifier matches prose); what matters is
    /// that it stringifies to something containing `readTimeout`, since that is
    /// what `classifyTransport` itself keys on.
    struct ReadTimeoutStandIn: Error, CustomStringConvertible {
        var description: String { "HTTPClientError.readTimeout" }
    }

    /// Stands in for the `NIOConnectionError` a refused connect throws: the
    /// single most common misconfiguration (nothing listening on the gateway
    /// port), and the one transport failure that must NOT be continued — there
    /// is no half-finished answer on the far side of a socket that was never
    /// established.
    struct ConnectionRefusedStandIn: Error, CustomStringConvertible {
        var description: String {
            "NIOConnectionError(host: \"127.0.0.1\", port: 4000, "
                + "connectionErrors: [connection refused (errno: 61)])"
        }
    }

    /// `idleGuarded`'s silence branch — the stream committed, then went quiet.
    @Test("the idle-guard's stalled-stream message classifies as a gateway timeout")
    func idleGuardSilenceMessage() {
        let idle = Duration.seconds(120)
        let error = DoMoError(
            .transport,
            """
            The model stream stalled — no data for \(idle). \
            The connection was still open; it timed out.
            """
        )
        #expect(error.isGatewayTimeout)
    }

    /// `idleGuarded`'s overall branch — the turn outran its whole budget.
    @Test("the idle-guard's overall-deadline message classifies as a gateway timeout")
    func idleGuardDeadlineMessage() {
        let overall = Duration.seconds(600)
        let error = DoMoError(
            .transport,
            "The model stream exceeded its \(overall) deadline and timed out."
        )
        #expect(error.isGatewayTimeout)
    }

    /// `classifyTransport`'s rewrite of AsyncHTTPClient's uneditable 90-second
    /// read timeout, cause and all.
    @Test("the rewritten readTimeout message classifies as a gateway timeout")
    func classifyTransportReadTimeoutMessage() {
        let error = DoMoError(
            .transport,
            """
            The model stream went quiet for 90 seconds and the connection was dropped. \
            That 90-second limit belongs to the HTTP client and cannot be changed; \
            DOMOCODE_STREAM_TIMEOUT_MS only takes effect below it.
            """,
            cause: ReadTimeoutStandIn()
        )
        #expect(error.isGatewayTimeout)
    }

    /// The same failure with the sentence dropped: the enum name alone, down in
    /// the cause chain, still has to be enough. This is the assertion that keeps
    /// the classifier reading ``DoMoError/description`` rather than
    /// ``DoMoError/message``.
    @Test("a bare readTimeout cause is recognised through the cause chain")
    func readTimeoutReachedThroughTheCauseChain() {
        let error = DoMoError(.transport, "stream chat completion", cause: ReadTimeoutStandIn())
        #expect(error.isGatewayTimeout)
    }

    /// `classifyTransport`'s fallback branch on the misconfiguration it sees
    /// most: nothing listening on the gateway port.
    @Test("connection refused is not a gateway timeout")
    func connectionRefusedIsNotATimeout() {
        let bare = DoMoError(.transport, "connection refused")
        #expect(!bare.isGatewayTimeout)

        let stringified = DoMoError(
            .transport,
            String(describing: ConnectionRefusedStandIn()),
            cause: ConnectionRefusedStandIn()
        )
        #expect(!stringified.isGatewayTimeout)
    }

    /// The other transport failures pi's pattern list names, none of which mean
    /// "the far side ran out of time".
    @Test(
        "transport failures that are not timeouts",
        arguments: [
            "getaddrinfo ENOTFOUND gateway.internal",
            "socket hang up",
            "connection reset by peer",
            "stream ended before message_stop",
            "fetch failed",
            "",
        ]
    )
    func nonTimeoutTransportProse(message: String) {
        #expect(!DoMoError(.transport, message).isGatewayTimeout)
    }
}

// MARK: - Status codes

@Suite("Gateway timeout classification — statuses")
struct GatewayTimeoutStatusTests {
    /// 408 and 504 are the standard spellings; 522 and 524 are Cloudflare's,
    /// and a LiteLLM deployment behind Cloudflare is where they arrive from.
    @Test("the gateway timeout statuses", arguments: [408, 504, 522, 524])
    func timeoutStatuses(status: Int) {
        #expect(DoMoError(httpStatus: status, message: "upstream timed out").isGatewayTimeout)
        #expect(DoMoError(.provider(status: status, isRetryable: true), "").isGatewayTimeout)
    }

    /// The near misses. 502/503 mean the upstream was unreachable or refusing —
    /// there is nothing half-finished to continue from — and 500 is a generic
    /// fault. All three are retryable, and retrying is a different decision from
    /// asking the model to carry on.
    @Test("adjacent 5xx statuses are not gateway timeouts", arguments: [500, 502, 503, 520, 599])
    func adjacentServerStatuses(status: Int) {
        #expect(!DoMoError(httpStatus: status, message: "bad gateway").isGatewayTimeout)
    }

    @Test("client statuses are not gateway timeouts", arguments: [400, 404, 409, 413, 422])
    func clientStatuses(status: Int) {
        #expect(!DoMoError(httpStatus: status, message: "bad request").isGatewayTimeout)
    }

    /// A status-carrying refusal is classified by its status, not by its body.
    /// Gateways and models both say "timeout" in prose that means something
    /// else, and a 400 does not become resumable because the word appears in it.
    @Test("provider prose does not override the status")
    func providerProseIsIgnored() {
        let bodySaysTimeout = DoMoError(
            .provider(status: 400, isRetryable: false),
            "litellm.BadRequestError: timeout must be a positive number"
        )
        #expect(!bodySaysTimeout.isGatewayTimeout)

        let noStatus = DoMoError(
            .provider(status: nil, isRetryable: true),
            "provider returned error: the request timed out"
        )
        #expect(!noStatus.isGatewayTimeout)
    }
}

// MARK: - Kinds that must stay out

@Suite("Gateway timeout classification — other kinds")
struct GatewayTimeoutOtherKindTests {
    /// Every remaining kind, each carrying prose that would match if the kind
    /// were not consulted first. Continuing any of these is either useless or
    /// actively wrong: a throttle wants a wait, an overflow gets bigger, a bad
    /// credential fails identically, and a cancellation is the user's decision.
    @Test("prose only counts for a transport failure")
    func proseDoesNotLeakIntoOtherKinds() {
        #expect(!DoMoError(.rateLimit(retryAfter: .seconds(30)), "request timed out; slow down").isGatewayTimeout)
        #expect(!DoMoError(.quotaExhausted, "monthly usage deadline reached").isGatewayTimeout)
        #expect(!DoMoError(.contextOverflow, "prompt is too long — the request timed out").isGatewayTimeout)
        #expect(!DoMoError(.authentication, "token expired past its deadline").isGatewayTimeout)
        #expect(!DoMoError(.malformedResponse, "stream stalled mid-frame").isGatewayTimeout)
        #expect(!DoMoError(.toolExecution(tool: "bash"), "command timed out after 120s").isGatewayTimeout)
        #expect(!DoMoError(.configuration, "no model configured; startup timeout").isGatewayTimeout)
        #expect(!DoMoError.file(.timedOut, path: "/tmp/session.jsonl", while: "lock").isGatewayTimeout)
    }

    /// The shape `classifyTransport` produces when the user hits the stop key
    /// while a stalled stream is being torn down: the cancellation wins the
    /// kind, and the timeout wording survives in the cause. Continuing here
    /// would restart a turn the user just stopped.
    @Test("a cancellation wrapping a timeout is not a gateway timeout")
    func cancellationBeatsTheProse() {
        let stalled = DoMoError(
            .transport,
            "The model stream stalled — no data for 120.0 seconds. The connection was still open; it timed out."
        )
        let aborted = DoMoError(.cancelled, "Request was aborted", cause: stalled)
        #expect(!aborted.isGatewayTimeout)
        #expect(stalled.isGatewayTimeout)
    }
}

// MARK: - Matching mechanics

@Suite("Gateway timeout classification — matching")
struct GatewayTimeoutMatchingTests {
    /// The gateway's own casing is not something this package controls; a body
    /// forwarded verbatim arrives however the far side wrote it.
    @Test(
        "the match is case-insensitive",
        arguments: [
            "Gateway Timeout",
            "The request TIMED OUT",
            "Stream Stalled",
            "DEADLINE exceeded",
            "litellm.Timeout: APITimeoutError - Request timed out.",
        ]
    )
    func caseInsensitiveWordings(message: String) {
        #expect(DoMoError(.transport, message).isGatewayTimeout)
    }

    /// A timeout classified two layers down still reaches a caller holding only
    /// the outermost error — which is what the agent loop and the continuation
    /// loop actually hold.
    @Test("a wrapped chain is matched through every link")
    func wrappedChainIsMatched() {
        let inner = DoMoError(.transport, "The model stream exceeded its 600.0 seconds deadline and timed out.")
        let middle = DoMoError(wrapping: inner, as: .transport, "stream chat completion", cancelled: false)
        let outer = DoMoError(wrapping: middle, as: .transport, "turn failed", cancelled: false)

        #expect(outer.kind == .transport)
        #expect(outer.isGatewayTimeout)
        // Nothing in the two outer messages says "timeout"; only the chain does.
        #expect(!DoMoError(.transport, "turn failed").isGatewayTimeout)
        #expect(!DoMoError(.transport, "stream chat completion").isGatewayTimeout)
    }

    /// Both predicates are true for a timeout, and they are not the same
    /// question: the retry loop replays the identical request, the continuation
    /// loop sends a new turn. This pins that neither one was implemented in
    /// terms of the other.
    @Test("retryability and gateway-timeout are independent answers")
    func independentFromRetryability() {
        let timeout = DoMoError(.transport, "the model stream timed out")
        #expect(timeout.isRetryable)
        #expect(timeout.isGatewayTimeout)

        let refused = DoMoError(.transport, "connection refused")
        #expect(refused.isRetryable)
        #expect(!refused.isGatewayTimeout)

        let throttled = DoMoError(.rateLimit(retryAfter: nil), "429")
        #expect(throttled.isRetryable)
        #expect(!throttled.isGatewayTimeout)

        let overflow = DoMoError(.contextOverflow, "prompt is too long")
        #expect(!overflow.isRetryable)
        #expect(!overflow.isGatewayTimeout)
    }
}
