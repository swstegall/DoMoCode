// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// How a failure reads to a human, decided once. `DoMoError` already carries the
// taxonomy (``DoMoError/Kind``); what was missing was a single place that turns
// that taxonomy into the three things every surface shows — a headline naming
// the class of failure, the message itself, and a hint about what to do. The
// full-screen transcript, the inline REPL and print-mode's JSON all reach the
// same strings from here rather than each inventing their own wording.
//
// The wire needs a payload-free spelling of a `Kind` too: a `ServerNotice`
// carries `kind: String?`, and a consumer holding only that label must be able
// to reach the same headline and hint. That is ``DoMoError/Kind/label`` and
// ``DoMoError/Kind/labeled(_:)``.

// MARK: - Wire labels

extension DoMoError.Kind {
    /// The stable snake_case label for this kind — what crosses a wire, so the
    /// taxonomy survives the trip instead of being re-derived from prose.
    ///
    /// Payload-free by design: a status code, a retry delay or an errno is
    /// display detail that is already spelled out in the message text, and
    /// putting it in the label would make the label unstable as a key.
    public var label: String {
        switch self {
        case .transport: return "transport"
        case .authentication: return "authentication"
        case .rateLimit: return "rate_limit"
        case .quotaExhausted: return "quota_exhausted"
        case .contextOverflow: return "context_overflow"
        case .provider: return "provider"
        case .malformedResponse: return "malformed_response"
        case .toolExecution: return "tool_execution"
        case .file: return "file"
        case .cancelled: return "cancelled"
        case .configuration: return "configuration"
        }
    }

    /// The kind a `label` names, payload-bearing kinds rebuilt at their least
    /// committal value.
    ///
    /// `nil` for an unrecognized label. That is the whole point: a newer
    /// producer's kind must read as "unclassified" — which
    /// ``ErrorPresentation/headline(for:)`` still gives a row title — and never
    /// as a *wrong* kind, which would send a reader after the wrong remedy.
    ///
    /// The rebuilt payloads are deliberately the least committal values in the
    /// taxonomy: `.rateLimit(retryAfter: nil)` says "no server-supplied delay"
    /// rather than inventing one, and `.provider(status: nil, isRetryable:
    /// false)` refuses to claim retryability the label never carried.
    public static func labeled(_ label: String) -> DoMoError.Kind? {
        switch label {
        case "transport": return .transport
        case "authentication": return .authentication
        case "rate_limit": return .rateLimit(retryAfter: nil)
        case "quota_exhausted": return .quotaExhausted
        case "context_overflow": return .contextOverflow
        case "provider": return .provider(status: nil, isRetryable: false)
        case "malformed_response": return .malformedResponse
        case "tool_execution": return .toolExecution(tool: "")
        case "file": return .file(path: nil, errno: nil)
        case "cancelled": return .cancelled
        case "configuration": return .configuration
        default: return nil
        }
    }
}

// MARK: - Presentation

/// How a failure reads to a human, shared by every surface that renders one.
public enum ErrorPresentation: Sendable {
    /// A short noun phrase naming the class of failure.
    ///
    /// Never `nil`: an unclassified error still needs a row title, and a row
    /// with no title reads as a rendering bug rather than as an error report.
    public static func headline(for kind: DoMoError.Kind?) -> String {
        switch kind {
        case .transport?: return "Cannot reach the gateway"
        case .authentication?: return "The gateway rejected the credential"
        case .rateLimit?: return "Rate limited"
        case .quotaExhausted?: return "Out of quota"
        case .contextOverflow?: return "The conversation no longer fits the context window"
        case .provider?: return "The gateway returned an error"
        case .malformedResponse?: return "The gateway's response could not be understood"
        case .toolExecution?: return "A tool failed"
        case .file?: return "A file operation failed"
        case .cancelled?: return "Cancelled"
        case .configuration?: return "Configuration problem"
        case nil: return "Something went wrong"
        }
    }

    /// What the user can do about it, or `nil` where there is nothing honest to
    /// say. A suggestion that only restates the error trains people to stop
    /// reading them.
    ///
    /// This is the body of ``DoMoError/recoverySuggestion``, lifted so a
    /// consumer holding only a wire label can reach it. `recoverySuggestion` now
    /// calls straight through, so there is exactly one copy of these strings.
    public static func hint(for kind: DoMoError.Kind?) -> String? {
        switch kind {
        case .transport?:
            return "Check network connectivity; this request can be retried."
        case .authentication?:
            return "Check that the provider credential is set and has not expired."
        case .rateLimit(let delay)?:
            return delay.map { "Rate limited. Retry in \($0)." }
                ?? "Rate limited. Retry after a short backoff."
        case .quotaExhausted?:
            return
                "The account is out of quota or credit. Waiting will not help — top up or switch model."
        case .contextOverflow?:
            return "The conversation no longer fits the model's context window. Compact it and retry."
        case .file(_, let errno)?:
            switch errno {
            case .noSuchFileOrDirectory: return "Check that the path exists."
            case .permissionDenied: return "Check file permissions."
            default: return nil
            }
        case .configuration?:
            return "Correct the configuration and start again."
        case .provider?, .malformedResponse?, .toolExecution?, .cancelled?:
            return nil
        case nil:
            return nil
        }
    }

    /// The three parts of an error row, from what a wire frame carries.
    ///
    /// `message` is provider- or gateway-controlled text, so it is redacted and
    /// truncated here — the latter with the same budget the provider-body cap
    /// uses. Escaping it for a terminal is still the *renderer's* job: a
    /// `DoMoCore` type cannot reach `DoMoTUI`'s `sanitizeUntrustedText`, and the
    /// truncation has to happen before the string is measured either way.
    ///
    /// Redaction is repeated here rather than trusted from upstream because this
    /// is the display edge that consumes a *wire* frame: a `ServerNotice` from
    /// another process, whose producer's version of this harness is not
    /// something a renderer can check. Over an already-scrubbed message it costs
    /// one `isEmpty` and one substring scan.
    ///
    /// Redacting before truncating is load-bearing: cutting first can split a
    /// registered literal in half, and half a secret matches neither the
    /// registry nor a prefix rule.
    public static func rows(
        label: String?,
        message: String
    ) -> (headline: String, message: String, hint: String?) {
        let kind = label.flatMap(DoMoError.Kind.labeled)
        return (
            headline(for: kind),
            DoMoError.truncating(Redaction.diagnostic(message)),
            hint(for: kind)
        )
    }
}
