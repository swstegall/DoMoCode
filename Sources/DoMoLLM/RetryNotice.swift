// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

/// One retry the client is about to perform, reported so a UI does not look
/// frozen while the client waits.
///
/// A retry is the only thing this client does that can hold a turn for minutes
/// without producing a byte. Before this type existed the retry loop slept
/// entirely inside ``LiteLLMClient/streamCompletion(model:context:temperature:maxTokens:reasoningEffort:toolChoice:rates:onResponse:)``
/// before any event was yielded, so the loop, the sink, the server and the TUI
/// all saw nothing but a long silence and the user saw "thinking…" for as long
/// as the backoff ran. Riding the event stream is what makes a ten-attempt
/// budget acceptable rather than a hang.
///
/// `Hashable` is load-bearing: this rides ``AssemblyEvent``, which is
/// `Sendable, Hashable`. Adding a non-`Hashable` field here silently breaks that
/// conformance and every consumer of it.
public struct RetryNotice: Sendable, Hashable {

    /// Why the client is retrying, in the vocabulary a user reads — not the
    /// vocabulary the wire used.
    public enum Reason: Sendable, Hashable {
        /// The provider said it was overloaded, at capacity, or 5xx'd.
        case overloaded
        /// A 429, or any response that named its own retry delay.
        case rateLimited
        /// No HTTP status at all: connect, TLS, socket, or read timeout.
        case transport
    }

    /// 1-based retry number. The first retry is `1`.
    public var attempt: Int

    /// The budget this call is working against
    /// (``LiteLLMClient/Configuration/maxRetries``).
    public var maxAttempts: Int

    /// How long the client will wait before the next request.
    public var delay: Duration

    public var reason: Reason

    /// The provider's own words, already truncated by the producer, for a
    /// detail line. May be empty.
    public var message: String

    public init(attempt: Int, maxAttempts: Int, delay: Duration, reason: Reason, message: String) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.reason = reason
        self.message = message
    }

    /// One line, ready for a status bar: `"Retrying in 8s (attempt 4/10) — provider busy"`.
    public var summary: String {
        "Retrying in \(Self.formatted(delay)) (attempt \(attempt)/\(maxAttempts)) — \(reason.label)"
    }

    /// A short human duration: `"500ms"`, `"1.5s"`, `"8s"`, `"60s"`.
    ///
    /// Milliseconds come from ``DoMoCore/DoMoError/wholeMilliseconds(_:)`` — the
    /// one saturating projection — rather than a local `seconds * 1000`, which
    /// traps on a `Duration` built from a hostile `Retry-After`.
    public static func formatted(_ duration: Duration) -> String {
        let ms = DoMoError.wholeMilliseconds(duration)
        if ms <= 0 { return "0ms" }
        if ms < 1000 { return "\(ms)ms" }
        // Round to a tenth of a second, then drop a trailing `.0`. Guarding the
        // add against overflow keeps a saturated `Int.max` from trapping here.
        let tenths = (ms / 100) + ((ms % 100) >= 50 ? 1 : 0)
        return tenths % 10 == 0 ? "\(tenths / 10)s" : "\(tenths / 10).\(tenths % 10)s"
    }

    /// The reason a classified failure implies.
    ///
    /// Anything that is neither a rate limit nor a transport failure reached the
    /// retry loop by being a retryable provider answer, which is by definition
    /// "the provider could not serve this right now".
    public static func reason(for error: DoMoError) -> Reason {
        switch error.kind {
        case .rateLimit: .rateLimited
        case .transport: .transport
        default: .overloaded
        }
    }
}

extension RetryNotice.Reason {
    /// The user-facing tail of ``RetryNotice/summary``.
    public var label: String {
        switch self {
        case .overloaded: "provider busy"
        case .rateLimited: "rate limited"
        case .transport: "connection problem"
        }
    }
}
