// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/utils/retry.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The retryability split, the quota-versus-throttle distinction, the
// `Retry-After` precedence rules and the error-body cap are ported from
// `packages/ai/src/utils/retry.ts`, `packages/ai/src/utils/overflow.ts`,
// `packages/ai/src/utils/error-body.ts` and
// `packages/ai/src/api/openai-codex-responses.ts`.

import Foundation
import SystemPackage

/// The one error type the whole harness speaks.
///
/// pi carries failure as a string: a provider catch block stringifies whatever
/// it caught into `AssistantMessage.errorMessage`, and every consumer that needs
/// to *do* something different re-derives the category by matching regexes
/// against that string. That is why `isRetryableAssistantError` and
/// `isContextOverflow` exist, why they each carry twenty-odd provider-specific
/// patterns, and why they must be kept in sync with each other. The
/// classification is real; storing it only as prose is the accident.
///
/// So the taxonomy is a stored property. Whoever is closest to the failure —
/// the HTTP layer that saw the status, the provider adapter that recognised the
/// vendor's wording — decides the ``Kind`` once. Everyone above switches on it.
///
/// A `Kind` earns its place by leading somewhere different. If two kinds would
/// always be handled identically they should be one kind; each case below names
/// the caller that treats it specially.
///
/// ## Typed throws
///
/// A leaf whose failure modes are all in this taxonomy should say so:
/// `func read(_ path: FilePath) throws(DoMoError) -> Data`. The caller then gets
/// an exhaustive `switch error.kind` with no `default:` and no `as?`.
///
/// Typed throws is *not* the right tool in two places:
///
/// - A leaf with a genuinely closed, self-contained error set should keep its
///   own type — ``JSONValueError`` is two cases about byte conversion and gains
///   nothing from being folded in here. Convert at the seam that publishes it.
/// - Anything spanning two subsystems. Swift has no union types, so a function
///   that can fail with `DoMoError` *or* a decoder's own error type must be
///   declared `throws` (that is, `throws(any Error)`); there is no
///   `throws(DoMoError | DecodingError)`. Rather than widen, convert: catch the
///   foreign error at the boundary and rethrow it as a `DoMoError` carrying it
///   as ``cause``. That is what ``init(wrapping:as:_:cancelled:)`` is for, and
///   it is the reason `cause` is `any Error` rather than a closed enum.
///
/// The cause chain can be `any Error` at no cost to `Sendable`: Swift 6 requires
/// `Error` conformers to be `Sendable`, so `any Error` is already a `Sendable`
/// existential.
public struct DoMoError: Error, Sendable {

    /// What kind of failure this is, and therefore what a caller should do next.
    public enum Kind: Sendable, Hashable {
        /// The request never reached a usable response: DNS, connect, TLS,
        /// socket reset, read timeout, or a stream that ended before its
        /// terminal event.
        ///
        /// Retryable. This is the bulk of pi's `RETRYABLE_PROVIDER_ERROR_PATTERN`
        /// — `getaddrinfo`, `ENOTFOUND`, `socket hang up`, `fetch failed`,
        /// `stream ended before message_stop` — collapsed into one kind, because
        /// every one of those patterns exists to reach the same decision.
        ///
        /// A truncated stream belongs here rather than in ``malformedResponse``:
        /// the bytes that arrived were well-formed, there were just not enough
        /// of them, and pi retries that.
        case transport

        /// The credential is missing, malformed, expired, or refused.
        ///
        /// Caller: the auth layer, which re-runs OAuth or prompts for a key.
        /// Never retried — the same credential fails the same way.
        case authentication

        /// Throttled, and expected to succeed after waiting.
        ///
        /// Caller: the retry loop, which sleeps `retryAfter` instead of its own
        /// exponential backoff when the server supplied one.
        case rateLimit(retryAfter: Duration?)

        /// The account is out of quota, budget, or credit.
        ///
        /// Distinct from ``rateLimit`` because waiting does not fix it. pi
        /// learned this the hard way and keeps a separate
        /// `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN`
        /// (`insufficient_quota`, `quota exceeded`, `Monthly usage limit
        /// reached`, `billing`) checked *before* the retryable patterns,
        /// because these arrive as HTTP 429 and would otherwise be retried
        /// until the budget is exhausted.
        ///
        /// Caller: the retry loop stops immediately; the UI says to top up.
        case quotaExhausted

        /// The request did not fit the model's context window.
        ///
        /// Caller: the session, which compacts the conversation and retries the
        /// turn. Not retryable as-is — replaying the same oversized request just
        /// fails again.
        ///
        /// Deliberately carries no token counts. pi's `isContextOverflow` is a
        /// boolean over two dozen provider phrasings and never extracts the
        /// numbers, because most providers do not report both sides of the
        /// comparison and compaction targets the configured window anyway. A
        /// payload nobody reads is a payload every provider adapter has to
        /// invent.
        case contextOverflow

        /// The provider answered, and the answer was a refusal.
        ///
        /// Caller: the retry loop (via ``isRetryable``) and the UI, which shows
        /// the status alongside the body.
        ///
        /// `isRetryable` is in the payload rather than derived from `status`
        /// because the two sources disagree. A status of 500 is retryable on its
        /// own, but pi also retries bodies with no status at all — `provider
        /// returned error`, `you can retry your request`, `try your request
        /// again` — and refuses to retry some 429s. The layer that read the body
        /// knows; the retry loop must not have to guess.
        case provider(status: Int?, isRetryable: Bool)

        /// A response arrived and could not be understood: unparseable JSON, an
        /// SSE event with a shape no version of the API documents, a tool call
        /// whose arguments are not an object.
        ///
        /// Caller: the stream decoder. Not retryable — a deterministic
        /// disagreement about the wire format does not heal on attempt two, and
        /// this is the kind that should be reported as a bug rather than
        /// absorbed.
        case malformedResponse

        /// A tool ran and failed.
        ///
        /// Caller: the agent loop, which is the reason this is not just
        /// "something went wrong". A tool failure is turned into an error tool
        /// result and fed back to the model, which then usually recovers; it
        /// does not end the turn and it does not reach the retry loop. pi does
        /// exactly this in `executePreparedToolCall` — catch, wrap in
        /// `createErrorToolResult`, keep going.
        case toolExecution(tool: String)

        /// A filesystem operation failed.
        ///
        /// Caller: the file tools and the UI. `errno` is switched on directly —
        /// a missing file and a permission denial lead to different prompts —
        /// and `path` is carried separately from the message so a renderer can
        /// shorten or highlight it without parsing prose back out.
        case file(path: FilePath?, errno: Errno?)

        /// The operation was cancelled.
        ///
        /// See the note on ``DoMoError/isCancellation``: this exists for leaves
        /// that must throw, and is meant to be converted into a well-formed
        /// terminal result before it reaches the UI, never reported as a
        /// failure.
        case cancelled

        /// Settings, environment, or model selection are wrong or incomplete.
        ///
        /// Caller: startup. Distinct from ``authentication`` because nothing is
        /// expired and no re-login helps — a human has to edit something.
        case configuration
    }

    public let kind: Kind

    /// What failed, in one line, in the voice the terminal will print.
    ///
    /// Holds only this layer's contribution. The underlying detail lives in
    /// ``cause`` and is appended by ``description``; duplicating it here is what
    /// produces the doubled messages pi's `messageCarriesBody` flag exists to
    /// suppress.
    public let message: String

    /// The error this one wraps, if any.
    public let cause: (any Error)?

    public init(_ kind: Kind, _ message: String, cause: (any Error)? = nil) {
        self.kind = kind
        self.message = message
        self.cause = cause
    }

    /// Wraps a caught error, adding context without discarding it.
    ///
    /// This is the shape of every provider catch block in pi, and the two
    /// non-obvious rules are both load-bearing:
    ///
    /// `cancelled` wins over everything, including the error's own identity.
    /// pi writes `output.stopReason = signal?.aborted ? "aborted" : "error"` —
    /// it consults the *signal*, not the exception, because tearing down an
    /// in-flight socket surfaces as an arbitrary transport error and there is no
    /// error type to test for. Trusting the error instead reports every user
    /// interrupt as a network failure.
    ///
    /// `kind` classifies only foreign errors. A `DoMoError` cause keeps the kind
    /// it was already given, because re-labelling is lossy in the direction that
    /// hurts: a `.contextOverflow` relabelled `.transport` by an outer catch
    /// stops triggering compaction and starts triggering a retry loop that
    /// cannot succeed.
    public init(
        wrapping error: any Error,
        as kind: Kind,
        _ message: String,
        cancelled: Bool = Task.isCancelled
    ) {
        if cancelled || Self.isCancellation(error) {
            self.kind = .cancelled
        } else if let inner = error as? DoMoError {
            self.kind = inner.kind
        } else {
            self.kind = kind
        }
        self.message = message
        self.cause = error
    }
}

// MARK: - Retry

extension DoMoError {
    /// Whether retrying the identical operation could plausibly succeed.
    ///
    /// A property, not a free function over strings, so a call site cannot
    /// disagree with the layer that actually saw the failure.
    ///
    /// Note what is *not* retryable: ``Kind/contextOverflow`` and
    /// ``Kind/quotaExhausted`` both arrive looking transient (413/429) and both
    /// need the caller to change something first. Retrying either unchanged
    /// burns the budget for a guaranteed failure.
    public var isRetryable: Bool {
        switch kind {
        case .transport, .rateLimit:
            return true
        case .provider(_, let isRetryable):
            return isRetryable
        case .authentication, .quotaExhausted, .contextOverflow, .malformedResponse,
            .toolExecution, .file, .cancelled, .configuration:
            return false
        }
    }

    /// The delay the server asked for, when it asked for one.
    ///
    /// Only ever populated for ``Kind/rateLimit``; a retry loop should prefer it
    /// over its own backoff, subject to its own cap. pi caps server-requested
    /// 429 delays at 60s by default and fails fast beyond that rather than
    /// leaving the UI frozen on an invisible sleep.
    public var retryAfter: Duration? {
        if case .rateLimit(let delay) = kind { return delay }
        return nil
    }

    /// Whether an HTTP status alone justifies a retry.
    ///
    /// Ported from `isRetryableError` in pi's Codex transport (429, 500, 502,
    /// 503, 504, plus 524 via the 5xx range). 408 is included because pi's
    /// pattern list retries request timeouts by wording anyway.
    ///
    /// Deliberately narrow: it answers only the question a status code can
    /// answer. Retryability decided from a response *body* belongs to the
    /// provider adapter that understands that provider's vocabulary, and reaches
    /// callers through ``Kind/provider(status:isRetryable:)``.
    public static func isRetryableStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }
}

// MARK: - Cancellation

extension DoMoError {
    /// Whether this represents cancellation rather than failure.
    ///
    /// pi never lets an abort escape as an error. A cancelled turn produces a
    /// well-formed `AssistantMessage` with `stopReason: "aborted"` — content and
    /// token usage intact, `errorMessage` cleared — and the agent loop ends the
    /// turn cleanly. Even a cancellation that lands mid-backoff is rewritten
    /// into that same shape so that, in `retryAssistantCall`'s words, "callers
    /// do not need to care when cancellation happened".
    ///
    /// The Swift equivalent: any layer that can produce a partial result should
    /// return it with a cancelled terminal reason rather than throw. This kind
    /// exists for leaves that have no result to return, and for the boundary
    /// that has to classify what it caught. Anything that renders errors must
    /// check this first — an interrupt drawn in red as a failure is a bug
    /// report the user then files.
    public var isCancellation: Bool { kind == .cancelled }

    /// Whether a caught error is cancellation.
    ///
    /// Covers `CancellationError` (structured concurrency), `Errno.canceled`
    /// (`ECANCELED` from a syscall), and an already-classified ``DoMoError``.
    ///
    /// `Errno.interrupted` is *not* included: `EINTR` means a signal arrived
    /// mid-syscall and the call should be reissued, which is the opposite of
    /// what a cancellation check is asked to decide.
    ///
    /// This is a fallback. Where the caller knows the cancellation state — a
    /// task flag, a stop button — that state wins; see
    /// ``init(wrapping:as:_:cancelled:)``.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let domo = error as? DoMoError { return domo.isCancellation }
        if let errno = error as? Errno { return errno == .canceled }
        return false
    }
}

// MARK: - HTTP

extension DoMoError {
    /// Classifies an HTTP failure response.
    ///
    /// The single place a status code becomes a ``Kind``, so provider adapters
    /// only have to handle what is genuinely provider-specific.
    ///
    /// 403 maps to ``Kind/authentication`` alongside 401. Providers use it for
    /// both a rejected credential and a policy denial; an adapter that can tell
    /// them apart should build the kind itself rather than call this.
    ///
    /// 429 maps to ``Kind/rateLimit``, which is right for a throttle and wrong
    /// for an exhausted budget — pi sees `insufficient_quota` and `Monthly usage
    /// limit reached` arrive as 429. An adapter that reads the body and
    /// recognises quota wording must construct ``Kind/quotaExhausted`` instead;
    /// the status alone cannot distinguish them.
    public init(
        httpStatus: Int,
        message: String,
        retryAfter: Duration? = nil,
        cause: (any Error)? = nil
    ) {
        let kind: Kind
        switch httpStatus {
        case 401, 403:
            kind = .authentication
        case 402:
            kind = .quotaExhausted
        case 429:
            kind = .rateLimit(retryAfter: retryAfter)
        default:
            kind = .provider(status: httpStatus, isRetryable: Self.isRetryableStatus(httpStatus))
        }
        self.init(kind, message, cause: cause)
    }

    /// Parses a server-supplied retry delay.
    ///
    /// Ported from `getRetryAfterDelayMs`. The precedence is the interesting
    /// part: the non-standard `retry-after-ms` is checked first because
    /// providers that send both send a coarse whole-second `Retry-After`
    /// alongside a precise millisecond value, and rounding a 200ms throttle up
    /// to a full second costs a second on every retry.
    ///
    /// `Retry-After` itself is either delta-seconds or an HTTP-date; both are
    /// accepted, and a date already in the past clamps to zero rather than
    /// producing a negative delay.
    ///
    /// `now` is injectable so the HTTP-date branch is testable.
    public static func parseRetryAfter(
        retryAfter: String?,
        retryAfterMilliseconds: String? = nil,
        now: Date = Date()
    ) -> Duration? {
        if let raw = retryAfterMilliseconds?.trimmingCharacters(in: .whitespacesAndNewlines),
            let millis = Double(raw), millis.isFinite
        {
            return .milliseconds(clamp(millis))
        }

        guard let raw = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let seconds = Double(raw), seconds.isFinite {
            return .seconds(clamp(seconds))
        }

        if let date = httpDate(raw) {
            return .seconds(clamp(date.timeIntervalSince(now)))
        }

        return nil
    }

    /// Clamps a parsed delay into the range `Duration` can hold.
    ///
    /// The floor stops a stale HTTP-date or a negative header from producing a
    /// negative delay, which a retry loop would either trap on or spin through.
    ///
    /// The ceiling is not policy — a retry loop applies its own cap, and pi
    /// defaults to failing fast past 60s rather than freezing the UI on an
    /// invisible sleep. It is arithmetic safety: `Duration.seconds(_:)` traps on
    /// overflow, and `Retry-After` is text from the far side of the wire, so
    /// `Retry-After: 1e20` must not be able to kill the process.
    private static func clamp(_ value: Double) -> Double {
        min(max(0, value), maximumDelaySeconds)
    }

    /// The largest delay the arithmetic downstream of `Duration` survives.
    ///
    /// `Double(Int64.max)` is *not* it: `Int64.max` is not representable as a
    /// `Double`, so the conversion rounds up to exactly 2^63, one past the end.
    /// `Duration.seconds(_:)` accepts that happily and produces a value whose
    /// `components` accessor then traps ("Not enough bits to represent the
    /// passed value") — moving the crash from the parser to whichever consumer
    /// first tries to read the number back out. `.nextDown` is the largest
    /// `Double` that still converts to `Int64`, so the clamped result is usable,
    /// not merely constructible.
    private static let maximumDelaySeconds = Double(Int64.max).nextDown

    /// Parses an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the only date
    /// form RFC 9110 requires a client to generate. `en_US_POSIX` is mandatory
    /// here: the format is English-and-GMT by specification, and any other
    /// locale silently fails to parse it on a machine set to that locale.
    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

// MARK: - Filesystem

extension DoMoError {
    /// Builds a filesystem error from an `Errno`.
    ///
    /// The `errno` is both baked into the message and kept as ``cause``, so a
    /// renderer gets a readable line and a caller keeps `error.cause as? Errno`.
    ///
    /// `action` is a verb phrase, not a sentence: `"read"`, `"create directory"`.
    /// It composes to `"read /etc/hosts: Permission denied"`.
    public static func file(
        _ errno: Errno,
        path: FilePath? = nil,
        while action: String
    ) -> DoMoError {
        let message =
            path.map { "\(action) \($0): \(errno)" }
            ?? "\(action): \(errno)"
        return DoMoError(.file(path: path, errno: errno), message, cause: errno)
    }
}

// MARK: - Cause chain

extension DoMoError {
    /// This error's message and those of its causes, outermost first.
    ///
    /// A cause that is itself a `DoMoError` is walked; a foreign error
    /// terminates the chain with its own description.
    ///
    /// A link is dropped when the layer above already spelled it out — pi's
    /// `messageCarriesBody` check, which exists because Anthropic's SDK folds
    /// the HTTP body into `error.message` while other SDKs do not, and printing
    /// both yields the same sentence twice. Doing the suppression here rather
    /// than at each catch site means the rule is applied once.
    public var causeChain: [String] {
        var links = [message]
        var next: (any Error)? = cause
        while let error = next {
            let text: String
            if let domo = error as? DoMoError {
                text = domo.message
                next = domo.cause
            } else {
                text = Self.describe(error)
                next = nil
            }
            if let last = links.last, last.contains(text) { continue }
            links.append(text)
        }
        return links
    }

    /// The innermost message in the chain — what actually failed.
    public var rootCause: String { causeChain[causeChain.count - 1] }

    /// Describes a foreign error for display.
    ///
    /// `String(describing:)` rather than `localizedDescription`, because the
    /// latter renders an ordinary Swift error as "The operation couldn't be
    /// completed. (MyModule.MyError error 1.)", which is worse than useless in a
    /// terminal. `LocalizedError` conformers get their own text, which is the
    /// signal that someone wrote a human-readable string on purpose.
    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}

// MARK: - Description

extension DoMoError: CustomStringConvertible {
    /// The full chain, outermost first, joined with `": "`.
    ///
    /// Reads as one line — `"send request: connection reset by peer"` — which is
    /// what a terminal wants; the alternative, an indented cause tree, costs
    /// four lines to say the same thing and does not survive being embedded in
    /// another message.
    public var description: String {
        causeChain.joined(separator: ": ")
    }
}

extension DoMoError: LocalizedError {
    public var errorDescription: String? { description }

    /// The root cause, when there is one distinct from ``message``.
    ///
    /// `description` already contains it; this exists for renderers that want to
    /// show the summary and the underlying failure in different places.
    public var failureReason: String? {
        let chain = causeChain
        return chain.count > 1 ? chain[chain.count - 1] : nil
    }

    /// What the user can do about it.
    ///
    /// `nil` where there is nothing honest to say. A suggestion that only
    /// restates the error trains people to stop reading them.
    public var recoverySuggestion: String? {
        switch kind {
        case .transport:
            return "Check network connectivity; this request can be retried."
        case .authentication:
            return "Check that the provider credential is set and has not expired."
        case .rateLimit(let delay):
            return delay.map { "Rate limited. Retry in \($0)." }
                ?? "Rate limited. Retry after a short backoff."
        case .quotaExhausted:
            return
                "The account is out of quota or credit. Waiting will not help — top up or switch model."
        case .contextOverflow:
            return "The conversation no longer fits the model's context window. Compact it and retry."
        case .file(_, let errno):
            switch errno {
            case .noSuchFileOrDirectory: return "Check that the path exists."
            case .permissionDenied: return "Check file permissions."
            default: return nil
            }
        case .configuration:
            return "Correct the configuration and start again."
        case .provider, .malformedResponse, .toolExecution, .cancelled:
            return nil
        }
    }
}

// MARK: - Text

extension DoMoError {
    /// The cap pi applies to a provider error body, in characters.
    public static let maxErrorBodyCharacters = 4000

    /// Truncates provider text to a length a terminal can survive.
    ///
    /// Ported from `truncateErrorText`, including the suffix format, since it is
    /// visible in output and in pi's fixtures. Provider bodies can be an entire
    /// HTML error page; the count is reported so it is clear something was cut
    /// rather than that the provider sent something truncated.
    ///
    /// Counts `Character`s where pi counts UTF-16 units, so a multi-scalar
    /// emoji is one here and two there. The cap is a display budget, not a
    /// protocol constant, and a grapheme count is the one that keeps the string
    /// well-formed.
    ///
    /// Not applied automatically by ``init(_:_:cause:)``: silently rewriting a
    /// message the caller composed is the kind of surprise that gets discovered
    /// in a log file at 3am. Call it on the untrusted part.
    public static func truncating(
        _ text: String,
        to maxCharacters: Int = maxErrorBodyCharacters
    ) -> String {
        // `prefix(_:)` traps on a negative length, and `maxCharacters` is
        // routinely a remaining-budget subtraction at the call site.
        let cap = max(0, maxCharacters)
        guard text.count > cap else { return text }
        let head = text.prefix(cap)
        return "\(head)... [truncated \(text.count - cap) chars]"
    }
}
