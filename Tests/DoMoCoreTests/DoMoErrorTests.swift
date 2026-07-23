// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - Retryability

@Suite("DoMoError retryability")
struct DoMoErrorRetryTests {
    @Test("transport and rate limits retry; deterministic failures do not")
    func retryabilityByKind() {
        #expect(DoMoError(.transport, "reset").isRetryable)
        #expect(DoMoError(.rateLimit(retryAfter: nil), "slow down").isRetryable)

        #expect(!DoMoError(.authentication, "bad key").isRetryable)
        #expect(!DoMoError(.malformedResponse, "garbage").isRetryable)
        #expect(!DoMoError(.toolExecution(tool: "bash"), "exit 1").isRetryable)
        #expect(!DoMoError(.file(path: nil, errno: nil), "nope").isRetryable)
        #expect(!DoMoError(.configuration, "no model").isRetryable)
    }

    /// Ported from pi's "keeps provider limit errors non-retryable". A quota
    /// wall arrives as HTTP 429 and looks exactly like a throttle; retrying it
    /// spends the retry budget on a guaranteed failure.
    @Test("quota exhaustion is not a retryable rate limit")
    func quotaIsNotRetryable() {
        let quota = DoMoError(.quotaExhausted, "insufficient_quota")
        #expect(!quota.isRetryable)
        #expect(quota.retryAfter == nil)
    }

    /// Overflow is deterministic: the caller has to compact before the same
    /// request can succeed, so the retry loop must not swallow it.
    @Test("context overflow is not retryable")
    func overflowIsNotRetryable() {
        #expect(!DoMoError(.contextOverflow, "prompt is too long").isRetryable)
    }

    /// Ported from pi's "does not retry an aborted message".
    @Test("cancellation is never retryable")
    func cancellationIsNotRetryable() {
        #expect(!DoMoError(.cancelled, "aborted").isRetryable)
    }

    @Test("the provider payload decides, not the status")
    func providerRetryabilityIsCarried() {
        // No status at all, but the body said "you can retry your request".
        let prose = DoMoError(.provider(status: nil, isRetryable: true), "provider returned error")
        #expect(prose.isRetryable)

        // A 429 the adapter recognised as terminal.
        let terminal = DoMoError(.provider(status: 429, isRetryable: false), "GoUsageLimitError")
        #expect(!terminal.isRetryable)
    }

    @Test("retryAfter is exposed only for rate limits")
    func retryAfterIsScoped() {
        #expect(DoMoError(.rateLimit(retryAfter: .seconds(12)), "429").retryAfter == .seconds(12))
        #expect(DoMoError(.rateLimit(retryAfter: nil), "429").retryAfter == nil)
        #expect(DoMoError(.transport, "reset").retryAfter == nil)
    }

    @Test(
        "retryable statuses",
        arguments: [408, 429, 500, 502, 503, 504, 524, 599]
    )
    func retryableStatuses(status: Int) {
        #expect(DoMoError.isRetryableStatus(status))
    }

    @Test(
        "non-retryable statuses",
        arguments: [400, 401, 403, 404, 409, 413, 422, 600]
    )
    func nonRetryableStatuses(status: Int) {
        #expect(!DoMoError.isRetryableStatus(status))
    }
}

// MARK: - HTTP mapping

@Suite("DoMoError HTTP classification")
struct DoMoErrorHTTPTests {
    @Test("401 and 403 are authentication")
    func authStatuses() {
        #expect(DoMoError(httpStatus: 401, message: "unauthorized").kind == .authentication)
        #expect(DoMoError(httpStatus: 403, message: "forbidden").kind == .authentication)
    }

    @Test("402 is quota, not a rate limit")
    func paymentRequired() {
        #expect(DoMoError(httpStatus: 402, message: "payment required").kind == .quotaExhausted)
    }

    @Test("429 carries the server's delay through to the retry loop")
    func rateLimitCarriesDelay() {
        let error = DoMoError(httpStatus: 429, message: "slow down", retryAfter: .seconds(30))
        #expect(error.kind == .rateLimit(retryAfter: .seconds(30)))
        #expect(error.retryAfter == .seconds(30))
        #expect(error.isRetryable)
    }

    @Test("5xx becomes a retryable provider error carrying its status")
    func serverError() {
        let error = DoMoError(httpStatus: 503, message: "overloaded")
        #expect(error.kind == .provider(status: 503, isRetryable: true))
        #expect(error.isRetryable)
    }

    @Test("4xx that is not auth or throttling is a terminal provider error")
    func clientError() {
        let error = DoMoError(httpStatus: 400, message: "bad request")
        #expect(error.kind == .provider(status: 400, isRetryable: false))
        #expect(!error.isRetryable)
    }

    @Test("the cause survives HTTP classification")
    func causeSurvives() {
        let inner = DoMoError(.transport, "socket hang up")
        let outer = DoMoError(httpStatus: 500, message: "upstream failed", cause: inner)
        #expect(outer.cause is DoMoError)
        #expect(outer.description == "upstream failed: socket hang up")
    }
}

// MARK: - Retry-After parsing

@Suite("Retry-After parsing")
struct DoMoErrorRetryAfterTests {
    /// Ported precedence rule: a provider that sends both sends a rounded-up
    /// whole second alongside the precise value, and taking the coarse one costs
    /// most of a second on every retry.
    @Test("retry-after-ms wins over retry-after")
    func millisecondsWin() {
        let delay = DoMoError.parseRetryAfter(retryAfter: "1", retryAfterMilliseconds: "250")
        #expect(delay == .milliseconds(250))
    }

    @Test("plain delta-seconds")
    func deltaSeconds() {
        #expect(DoMoError.parseRetryAfter(retryAfter: "30") == .seconds(30))
        #expect(DoMoError.parseRetryAfter(retryAfter: " 30 ") == .seconds(30))
    }

    @Test("fractional seconds are kept, not floored")
    func fractionalSeconds() {
        #expect(DoMoError.parseRetryAfter(retryAfter: "1.5") == .milliseconds(1500))
    }

    @Test("an HTTP-date is resolved against now")
    func httpDate() {
        let now = Date(timeIntervalSince1970: 784_111_777)  // 1994-11-06 08:49:37 GMT
        let delay = DoMoError.parseRetryAfter(
            retryAfter: "Sun, 06 Nov 1994 08:50:07 GMT",
            now: now
        )
        #expect(delay == .seconds(30))
    }

    /// A clock skewed forward, or a date the server already missed, must not
    /// produce a negative `Duration` — a retry loop that sleeps for it would
    /// either trap or spin.
    @Test("a past HTTP-date clamps to zero")
    func pastDateClamps() {
        let now = Date(timeIntervalSince1970: 784_111_777)
        let delay = DoMoError.parseRetryAfter(
            retryAfter: "Sun, 06 Nov 1994 08:00:00 GMT",
            now: now
        )
        #expect(delay == .zero)
    }

    @Test("a negative delta-seconds clamps to zero")
    func negativeSecondsClamp() {
        #expect(DoMoError.parseRetryAfter(retryAfter: "-5") == .zero)
        #expect(DoMoError.parseRetryAfter(retryAfter: "0", retryAfterMilliseconds: "-1") == .zero)
    }

    /// `Duration.seconds(_:)` traps on overflow and `Retry-After` comes from the
    /// far side of the wire, so an absurd value must clamp rather than crash.
    @Test("an absurd delay clamps instead of trapping")
    func absurdDelayClamps() {
        #expect(DoMoError.parseRetryAfter(retryAfter: "1e20") != nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "99999999999999999999999") != nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "0", retryAfterMilliseconds: "1e300") != nil)
    }

    @Test("unparseable input yields no delay rather than a wrong one")
    func unparseable() {
        #expect(DoMoError.parseRetryAfter(retryAfter: nil) == nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "") == nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "   ") == nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "soon") == nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "NaN") == nil)
        #expect(DoMoError.parseRetryAfter(retryAfter: "inf") == nil)
    }

    /// A bad `retry-after-ms` must fall through to `Retry-After` rather than
    /// short-circuiting the whole lookup.
    @Test("a malformed millisecond header falls back")
    func malformedMillisecondsFallBack() {
        #expect(
            DoMoError.parseRetryAfter(retryAfter: "2", retryAfterMilliseconds: "later")
                == .seconds(2)
        )
    }
}

// MARK: - Cancellation

@Suite("Cancellation")
struct DoMoErrorCancellationTests {
    @Test("recognises the forms cancellation actually arrives in")
    func recognisedForms() {
        #expect(DoMoError.isCancellation(CancellationError()))
        #expect(DoMoError.isCancellation(Errno.canceled))
        #expect(DoMoError.isCancellation(DoMoError(.cancelled, "stopped")))
    }

    /// `EINTR` means "reissue the call", which is the opposite answer.
    @Test("EINTR is not cancellation")
    func interruptedIsNotCancellation() {
        #expect(!DoMoError.isCancellation(Errno.interrupted))
        #expect(!DoMoError.isCancellation(DoMoError(.transport, "reset")))
    }

    /// pi's rule, from every provider catch block:
    /// `stopReason = signal.aborted ? "aborted" : "error"`. Tearing down an
    /// in-flight socket surfaces as an arbitrary transport error, so the
    /// cancellation flag has to beat the error's own identity — otherwise every
    /// user interrupt is reported as a network failure.
    @Test("the cancellation flag beats the caught error's identity")
    func flagWinsOverError() {
        let socketError = DoMoError(.transport, "connection reset by peer")
        let wrapped = DoMoError(
            wrapping: socketError,
            as: .transport,
            "stream anthropic-messages",
            cancelled: true
        )
        #expect(wrapped.kind == .cancelled)
        #expect(wrapped.isCancellation)
        #expect(!wrapped.isRetryable)
        #expect(wrapped.cause is DoMoError)
    }

    @Test("a bare CancellationError is classified even without the flag")
    func bareCancellationError() {
        let wrapped = DoMoError(
            wrapping: CancellationError(),
            as: .transport,
            "read file",
            cancelled: false
        )
        #expect(wrapped.kind == .cancelled)
    }

    /// Relabelling is lossy in the direction that hurts: an overflow relabelled
    /// as transport stops triggering compaction and starts triggering a retry
    /// loop that cannot succeed.
    @Test("wrapping does not relabel an already-classified error")
    func wrappingPreservesInnerKind() {
        let inner = DoMoError(.contextOverflow, "prompt is too long: 213462 tokens > 200000 maximum")
        let outer = DoMoError(wrapping: inner, as: .transport, "turn failed", cancelled: false)
        #expect(outer.kind == .contextOverflow)
        #expect(!outer.isRetryable)
    }

    @Test("a foreign error takes the supplied kind")
    func foreignErrorTakesKind() {
        let outer = DoMoError(
            wrapping: JSONValueError.invalidUTF8,
            as: .malformedResponse,
            "decode tool arguments",
            cancelled: false
        )
        #expect(outer.kind == .malformedResponse)
        #expect(outer.cause is JSONValueError)
    }

    @Test("only the cancelled kind reports as cancellation")
    func isCancellationProperty() {
        #expect(DoMoError(.cancelled, "aborted").isCancellation)
        #expect(!DoMoError(.transport, "aborted").isCancellation)
    }
}

// MARK: - Cause chain

@Suite("Cause chains")
struct DoMoErrorCauseChainTests {
    struct Underlying: Error, CustomStringConvertible {
        var description: String { "ENOSPC while flushing" }
    }

    struct Localized: Error, LocalizedError {
        var errorDescription: String? { "the disk filled up" }
    }

    @Test("a chain reads outermost-first on one line")
    func chainOrder() {
        let root = DoMoError(.file(path: "/tmp/a", errno: .ioError), "write /tmp/a: Input/output error")
        let middle = DoMoError(.toolExecution(tool: "write"), "tool write failed", cause: root)
        let outer = DoMoError(.provider(status: nil, isRetryable: false), "turn failed", cause: middle)

        #expect(
            outer.causeChain == [
                "turn failed", "tool write failed", "write /tmp/a: Input/output error",
            ]
        )
        #expect(outer.description == "turn failed: tool write failed: write /tmp/a: Input/output error")
        #expect(outer.rootCause == "write /tmp/a: Input/output error")
    }

    @Test("a foreign error terminates the chain with its own description")
    func foreignTerminator() {
        let error = DoMoError(.file(path: nil, errno: nil), "flush session", cause: Underlying())
        #expect(error.causeChain == ["flush session", "ENOSPC while flushing"])
    }

    @Test("a LocalizedError contributes its written text, not the synthesized one")
    func localizedTerminator() {
        let error = DoMoError(.file(path: nil, errno: nil), "flush session", cause: Localized())
        #expect(error.rootCause == "the disk filled up")
    }

    /// pi's `messageCarriesBody` case: some SDKs fold the underlying detail into
    /// the message and some do not, and printing both yields the same sentence
    /// twice. `DoMoError.file` is exactly that shape — errno in the message and
    /// errno as the cause.
    @Test("a cause already spelled out in the message is not repeated")
    func duplicateSuppression() {
        let error = DoMoError.file(.permissionDenied, path: "/etc/hosts", while: "read")
        #expect(error.description == "read /etc/hosts: Permission denied")
        #expect(error.causeChain.count == 1)
    }

    @Test("a single error has no root cause distinct from itself")
    func singleLink() {
        let error = DoMoError(.transport, "connection refused")
        #expect(error.causeChain == ["connection refused"])
        #expect(error.rootCause == "connection refused")
        #expect(error.failureReason == nil)
    }

    @Test("the underlying error survives the wrap and stays castable")
    func underlyingIsPreserved() {
        let error = DoMoError.file(.noSuchFileOrDirectory, path: "/nope", while: "open")
        #expect(error.cause as? Errno == .noSuchFileOrDirectory)
        #expect(error.kind == .file(path: "/nope", errno: .noSuchFileOrDirectory))
    }
}

// MARK: - Filesystem

@Suite("Filesystem errors")
struct DoMoErrorFileTests {
    @Test("message composes the action, the path and the errno")
    func messageComposition() {
        let error = DoMoError.file(.permissionDenied, path: "/etc/shadow", while: "read")
        #expect(error.message == "read /etc/shadow: Permission denied")
    }

    @Test("a pathless operation omits the path rather than printing an empty one")
    func pathlessOperation() {
        let error = DoMoError.file(.badFileDescriptor, while: "close session log")
        #expect(error.message == "close session log: Bad file descriptor")
        #expect(error.kind == .file(path: nil, errno: .badFileDescriptor))
    }
}

// MARK: - User-facing text

@Suite("User-facing text")
struct DoMoErrorDescriptionTests {
    @Test("errorDescription and localizedDescription agree with description")
    func localizedErrorConformance() {
        let error = DoMoError(.transport, "connection refused")
        #expect(error.errorDescription == "connection refused")
        #expect(error.localizedDescription == "connection refused")
    }

    @Test("failureReason surfaces the root cause when the chain is deep")
    func failureReason() {
        let inner = DoMoError(.transport, "getaddrinfo ENOTFOUND api.anthropic.com")
        let outer = DoMoError(.provider(status: nil, isRetryable: true), "request failed", cause: inner)
        #expect(outer.failureReason == "getaddrinfo ENOTFOUND api.anthropic.com")
    }

    @Test("a rate limit tells the user how long")
    func rateLimitSuggestion() {
        let error = DoMoError(.rateLimit(retryAfter: .seconds(30)), "429")
        #expect(error.recoverySuggestion?.contains("30") == true)
    }

    /// Waiting is the wrong advice for a quota wall, which is the whole reason
    /// it is a separate kind.
    @Test("quota advice does not suggest waiting")
    func quotaSuggestion() {
        let suggestion = DoMoError(.quotaExhausted, "insufficient_quota").recoverySuggestion
        #expect(suggestion?.contains("Waiting will not help") == true)
    }

    @Test("no suggestion where there is nothing honest to say")
    func silentKinds() {
        #expect(DoMoError(.cancelled, "aborted").recoverySuggestion == nil)
        #expect(DoMoError(.toolExecution(tool: "bash"), "exit 1").recoverySuggestion == nil)
        #expect(DoMoError(.provider(status: 400, isRetryable: false), "bad").recoverySuggestion == nil)
        #expect(DoMoError.file(.ioError, while: "read").recoverySuggestion == nil)
    }

    @Test("filesystem advice is errno-specific")
    func fileSuggestions() {
        #expect(
            DoMoError.file(.noSuchFileOrDirectory, while: "open").recoverySuggestion?
                .contains("path") == true
        )
        #expect(
            DoMoError.file(.permissionDenied, while: "open").recoverySuggestion?
                .contains("permissions") == true
        )
    }
}

// MARK: - Truncation

@Suite("Error body truncation")
struct DoMoErrorTruncationTests {
    @Test("text under the cap is returned unchanged")
    func underCap() {
        #expect(DoMoError.truncating("short", to: 10) == "short")
        #expect(DoMoError.truncating(String(repeating: "x", count: 10), to: 10).count == 10)
    }

    /// The suffix format is ported verbatim from pi's `truncateErrorText`; it
    /// shows up in output and in fixtures.
    @Test("the suffix reports how much was cut")
    func overCap() {
        let text = String(repeating: "x", count: 15)
        #expect(DoMoError.truncating(text, to: 10) == "xxxxxxxxxx... [truncated 5 chars]")
    }

    /// pi counts UTF-16 units; counting graphemes here means a truncated string
    /// is never cut through the middle of a character.
    @Test("truncation never splits a grapheme cluster")
    func graphemeSafety() {
        let text = String(repeating: "👩‍👩‍👧", count: 5)
        let truncated = DoMoError.truncating(text, to: 2)
        #expect(truncated.hasPrefix("👩‍👩‍👧👩‍👩‍👧"))
        #expect(truncated.hasSuffix("... [truncated 3 chars]"))
    }

    @Test("a real provider body is capped at the default")
    func defaultCap() {
        let body = String(repeating: "e", count: DoMoError.maxErrorBodyCharacters + 1)
        #expect(DoMoError.truncating(body).hasSuffix("... [truncated 1 chars]"))
    }
}

// MARK: - Type-level guarantees

@Suite("Type-level guarantees")
struct DoMoErrorTypeTests {
    /// A leaf whose failures are all in the taxonomy declares them, and the
    /// caller gets an exhaustive switch with no `default:`.
    func readConfig(_ path: FilePath) throws(DoMoError) -> String {
        throw DoMoError.file(.noSuchFileOrDirectory, path: path, while: "read")
    }

    @Test("typed throws narrows a leaf to this taxonomy")
    func typedThrows() {
        do {
            _ = try readConfig("/nope")
            Issue.record("expected a throw")
        } catch {
            // `error` is statically `DoMoError` here, not `any Error`.
            switch error.kind {
            case .file(let path, let errno):
                #expect(path == "/nope")
                #expect(errno == .noSuchFileOrDirectory)
            case .transport, .authentication, .rateLimit, .quotaExhausted, .contextOverflow,
                .provider, .malformedResponse, .toolExecution, .cancelled, .configuration:
                Issue.record("wrong kind: \(error.kind)")
            }
        }
    }

    actor Collector {
        var seen: [String] = []
        func record(_ error: DoMoError) { seen.append(error.description) }
    }

    /// The chain holds `any Error`, which is `Sendable` in Swift 6 because
    /// `Error` requires it. This test is here so that stops being true loudly.
    @Test("an error with a foreign cause crosses an isolation boundary")
    func sendableAcrossActors() async {
        let error = DoMoError(
            wrapping: JSONValueError.invalidUTF8,
            as: .malformedResponse,
            "decode response",
            cancelled: false
        )
        let collector = Collector()
        await collector.record(error)
        #expect(await collector.seen.count == 1)
    }
}

// MARK: - Regressions

@Suite("DoMoError regressions")
struct DoMoErrorRegressionTests {
    /// `Double(Int64.max)` rounds up to 2^63, which is one past `Int64.max`.
    /// Clamping to it produced a `Duration` that could be *built* but not read:
    /// `components` trapped with "Not enough bits to represent the passed
    /// value", so the crash landed on whichever consumer formatted or slept on
    /// the delay rather than on the parser that made it. Asserting `!= nil` is
    /// not enough; the value has to survive being taken apart.
    @Test(
        "an absurd delay clamps to a Duration that can still be read back",
        arguments: [
            "1e20", "99999999999999999999999", "9223372036854775807",
            "9.3e18", "1e19", "inf ", "1e308",
        ]
    )
    func absurdDelayStaysUsable(header: String) {
        guard let delay = DoMoError.parseRetryAfter(retryAfter: header) else { return }
        let components = delay.components
        #expect(components.seconds >= 0)
        #expect(components.seconds <= Int64.max)
        #expect(delay >= .zero)
    }

    @Test("an absurd retry-after-ms clamps to a readable Duration too")
    func absurdMillisecondsStayUsable() {
        let delay = DoMoError.parseRetryAfter(retryAfter: "0", retryAfterMilliseconds: "1e300")
        #expect(delay != nil)
        #expect(delay!.components.seconds >= 0)
    }

    /// `String.prefix(_:)` traps on a negative length, and a caller computing a
    /// remaining display budget subtracts its way there.
    @Test("a non-positive cap truncates rather than trapping")
    func nonPositiveCap() {
        #expect(DoMoError.truncating("abcdef", to: 0) == "... [truncated 6 chars]")
        #expect(DoMoError.truncating("abcdef", to: -10) == "... [truncated 6 chars]")
        #expect(DoMoError.truncating("", to: -10) == "")
    }

    /// Header values that reach this parser with the line terminator still
    /// attached must not silently lose the server's delay and fall back to
    /// blind exponential backoff.
    @Test("a header value with a stray line terminator still parses")
    func trailingCarriageReturn() {
        #expect(DoMoError.parseRetryAfter(retryAfter: "30\r\n") == .seconds(30))
        #expect(DoMoError.parseRetryAfter(retryAfter: "1", retryAfterMilliseconds: "250\r") == .milliseconds(250))
    }
}
