// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `DoMoError.recoverySuggestion` used to hold these strings itself; it now calls
// `ErrorPresentation.hint(for:)`. That refactor is only safe if it is invisible,
// so the first suite below pins the OLD wording verbatim — every literal here was
// copied out of the pre-refactor `recoverySuggestion` switch. A future edit to
// the shared strings has to come through this file.

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - The reduction is byte-identical

@Suite("recoverySuggestion is byte-identical after moving to ErrorPresentation")
struct RecoverySuggestionParityTests {

    /// One value per `DoMoError.Kind` case, so a new case makes the round-trip
    /// test below fail rather than quietly skip.
    private static let everyKind: [DoMoError.Kind] = [
        .transport,
        .authentication,
        .rateLimit(retryAfter: nil),
        .rateLimit(retryAfter: .seconds(30)),
        .quotaExhausted,
        .contextOverflow,
        .provider(status: 500, isRetryable: true),
        .malformedResponse,
        .toolExecution(tool: "bash"),
        .file(path: nil, errno: nil),
        .file(path: "/tmp/x", errno: .noSuchFileOrDirectory),
        .file(path: "/tmp/x", errno: .permissionDenied),
        .file(path: "/tmp/x", errno: .ioError),
        .cancelled,
        .configuration,
    ]

    @Test("Every kind's suggestion is exactly the string it was before")
    func exactStrings() {
        func suggestion(_ kind: DoMoError.Kind) -> String? {
            DoMoError(kind, "boom").recoverySuggestion
        }

        #expect(suggestion(.transport) == "Check network connectivity; this request can be retried.")
        #expect(
            suggestion(.authentication)
                == "Check that the provider credential is set and has not expired."
        )
        #expect(
            suggestion(.rateLimit(retryAfter: nil)) == "Rate limited. Retry after a short backoff."
        )
        // Interpolated from the `Duration` itself, so the exact spelling is
        // whatever `Duration.description` gives — pinned by construction, not by
        // a hand-copied literal.
        #expect(
            suggestion(.rateLimit(retryAfter: .seconds(30)))
                == "Rate limited. Retry in \(Duration.seconds(30))."
        )
        #expect(
            suggestion(.quotaExhausted)
                == "The account is out of quota or credit. Waiting will not help — top up or switch model."
        )
        #expect(
            suggestion(.contextOverflow)
                == "The conversation no longer fits the model's context window. Compact it and retry."
        )
        #expect(suggestion(.provider(status: 500, isRetryable: true)) == nil)
        #expect(suggestion(.malformedResponse) == nil)
        #expect(suggestion(.toolExecution(tool: "bash")) == nil)
        #expect(suggestion(.cancelled) == nil)
        #expect(suggestion(.configuration) == "Correct the configuration and start again.")

        // The file kind branches on errno, not on the kind alone.
        #expect(suggestion(.file(path: "/tmp/x", errno: .noSuchFileOrDirectory)) == "Check that the path exists.")
        #expect(suggestion(.file(path: "/tmp/x", errno: .permissionDenied)) == "Check file permissions.")
        #expect(suggestion(.file(path: "/tmp/x", errno: .ioError)) == nil)
        #expect(suggestion(.file(path: nil, errno: nil)) == nil)
    }

    @Test("The property and the shared helper cannot disagree")
    func propertyDelegatesToHelper() {
        for kind in Self.everyKind {
            #expect(DoMoError(kind, "boom").recoverySuggestion == ErrorPresentation.hint(for: kind))
        }
    }
}

// MARK: - Wire labels

@Suite("DoMoError.Kind labels")
struct ErrorKindLabelTests {

    private static let oneOfEachKind: [DoMoError.Kind] = [
        .transport,
        .authentication,
        .rateLimit(retryAfter: .seconds(5)),
        .quotaExhausted,
        .contextOverflow,
        .provider(status: 502, isRetryable: true),
        .malformedResponse,
        .toolExecution(tool: "read"),
        .file(path: "/tmp/x", errno: .permissionDenied),
        .cancelled,
        .configuration,
    ]

    @Test("Every kind has a distinct label that round-trips")
    func labelsAreUniqueAndRoundTrip() {
        let labels = Self.oneOfEachKind.map(\.label)
        #expect(labels.count == 11)
        #expect(Set(labels).count == 11, "two kinds share a label: \(labels)")
        for kind in Self.oneOfEachKind {
            #expect(DoMoError.Kind.labeled(kind.label)?.label == kind.label)
        }
    }

    @Test("A label is payload-free, so payload differences do not change it")
    func labelsIgnorePayload() {
        #expect(DoMoError.Kind.rateLimit(retryAfter: nil).label == DoMoError.Kind.rateLimit(retryAfter: .seconds(9)).label)
        #expect(
            DoMoError.Kind.provider(status: nil, isRetryable: false).label
                == DoMoError.Kind.provider(status: 503, isRetryable: true).label
        )
        #expect(
            DoMoError.Kind.file(path: nil, errno: nil).label
                == DoMoError.Kind.file(path: "/x", errno: .ioError).label
        )
    }

    @Test("An unrecognized label is unclassified, never misclassified")
    func unknownLabelIsNil() {
        #expect(DoMoError.Kind.labeled("wormhole") == nil)
        #expect(DoMoError.Kind.labeled("") == nil)
        // A kind a NEWER producer invented must not be silently read as some
        // other kind — it reads as "no kind", which still gets a row title.
        #expect(ErrorPresentation.headline(for: nil) == "Something went wrong")
        #expect(ErrorPresentation.hint(for: nil) == nil)
    }

    @Test("A rebuilt kind is the least committal value, never an invented one")
    func rebuiltPayloadsAreNeutral() {
        #expect(DoMoError.Kind.labeled("rate_limit") == .rateLimit(retryAfter: nil))
        #expect(DoMoError.Kind.labeled("provider") == .provider(status: nil, isRetryable: false))
        #expect(DoMoError.Kind.labeled("file") == .file(path: nil, errno: nil))
        #expect(DoMoError.Kind.labeled("tool_execution") == .toolExecution(tool: ""))
        // ...and specifically it does not claim retryability the label never carried.
        #expect(DoMoError(DoMoError.Kind.labeled("provider")!, "x").isRetryable == false)
    }
}

// MARK: - Rows

@Suite("ErrorPresentation.rows")
struct ErrorPresentationRowTests {

    @Test("Rows are headline + truncated message + hint, from a wire label alone")
    func rowsFromLabel() {
        let parts = ErrorPresentation.rows(label: "authentication", message: "401 from gateway")
        #expect(parts.headline == "The gateway rejected the credential")
        #expect(parts.message == "401 from gateway")
        #expect(parts.hint == "Check that the provider credential is set and has not expired.")
    }

    @Test("An absent or unknown label still produces a complete row")
    func rowsWithoutLabel() {
        for label in [nil, "wormhole"] as [String?] {
            let parts = ErrorPresentation.rows(label: label, message: "something")
            #expect(parts.headline == "Something went wrong")
            #expect(parts.message == "something")
            #expect(parts.hint == nil)
        }
    }

    @Test("A gateway's HTML error page is truncated at the provider-body cap")
    func rowsTruncateTheMessage() {
        let huge = String(repeating: "x", count: DoMoError.maxErrorBodyCharacters + 500)
        let parts = ErrorPresentation.rows(label: "provider", message: huge)
        #expect(parts.message == DoMoError.truncating(huge))
        #expect(parts.message.count < huge.count)
        #expect(parts.message.hasSuffix("[truncated 500 chars]"))
    }

    @Test("Every headline is non-empty, including the unclassified one")
    func headlinesAreAlwaysPresent() {
        let kinds: [DoMoError.Kind?] = [
            nil, .transport, .authentication, .rateLimit(retryAfter: nil), .quotaExhausted,
            .contextOverflow, .provider(status: nil, isRetryable: false), .malformedResponse,
            .toolExecution(tool: ""), .file(path: nil, errno: nil), .cancelled, .configuration,
        ]
        for kind in kinds { #expect(!ErrorPresentation.headline(for: kind).isEmpty) }
    }
}
