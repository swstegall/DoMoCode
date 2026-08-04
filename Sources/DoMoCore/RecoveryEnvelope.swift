// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A bounded, redacted description of a failed provider request.
///
/// This is deliberately a value type rather than a DoMoError extension. A
/// DoMoError keeps an arbitrary cause chain for local diagnostics and is not
/// Codable; a recovery envelope is the safe representation that may be stored,
/// replayed, sent over SSE, or supplied to a diagnostic model.
public struct RecoveryEnvelope: Sendable, Hashable, Codable {
    /// One retry that was actually scheduled before the failure became final.
    public struct Retry: Sendable, Hashable, Codable {
        public var number: Int
        public var requestNumber: Int
        public var maxAttempts: Int
        public var reason: String
        public var delayMilliseconds: Int

        public init(
            number: Int,
            requestNumber: Int,
            maxAttempts: Int,
            reason: String,
            delayMilliseconds: Int
        ) {
            self.number = max(1, number)
            self.requestNumber = max(1, requestNumber)
            self.maxAttempts = max(1, maxAttempts)
            self.reason = RecoveryEnvelope.safe(reason, limit: 80)
            self.delayMilliseconds = max(0, delayMilliseconds)
        }
    }

    public static let schemaVersion = 1

    /// The schema version for persisted and wire representations.
    public let version: Int
    /// DoMo's stable error-kind label, not provider prose.
    public let originalKind: String
    /// The HTTP status when a response head arrived.
    public let status: Int?
    /// Redacted and bounded provider body or transport detail.
    public let error: String
    /// Redacted response metadata useful for diagnosis.
    public let providerMetadata: [String: String]
    /// The alias requested by the session.
    public let model: String?
    /// Retry history, in schedule order.
    public let retryHistory: [Retry]
    /// Optional safe session context, already framed as untrusted data.
    public let sessionContext: String?
    /// Human-readable remedies attempted by the client, if any.
    public var attemptedRemedies: [String]
    /// A diagnostic model's bounded conclusion, when one was obtained.
    public var diagnosis: String?
    /// Whether the user explicitly approved a suggested mutation.
    public var userApprovedAction: Bool?
    /// True when the diagnostic sub-turn was not allowed to recurse.
    public let recursionPrevented: Bool

    public init(
        originalKind: String,
        status: Int? = nil,
        error: String,
        providerMetadata: [String: String] = [:],
        model: String? = nil,
        retryHistory: [Retry] = [],
        sessionContext: String? = nil,
        attemptedRemedies: [String] = [],
        diagnosis: String? = nil,
        userApprovedAction: Bool? = nil,
        recursionPrevented: Bool = true
    ) {
        self.version = Self.schemaVersion
        self.originalKind = Self.safe(originalKind, limit: 80)
        self.status = status
        self.error = Self.safe(error, limit: 4_096)

        let redactedHeaders = Redaction.redact(headers: providerMetadata)
        self.providerMetadata = Dictionary(
            redactedHeaders
                .sorted { $0.key < $1.key }
                .prefix(32)
                .map { ($0.key, Self.safe($0.value, limit: 512)) },
            uniquingKeysWith: { first, _ in first }
        )
        self.model = model.map { Self.safe($0, limit: 256) }
        self.retryHistory = Array(retryHistory.prefix(32))
        self.sessionContext = sessionContext.map { Self.safe($0, limit: 2_048) }
        self.attemptedRemedies = attemptedRemedies.prefix(16).map { Self.safe($0, limit: 256) }
        self.diagnosis = diagnosis.map { Self.safe($0, limit: 2_048) }
        self.userApprovedAction = userApprovedAction
        self.recursionPrevented = recursionPrevented
    }

    /// A clearly delimited, redacted prompt fragment for a diagnostic model.
    ///
    /// The provider response and session context are data, never instructions.
    /// The final cap is applied after redaction so a secret cannot be split at
    /// the boundary and survive into the diagnostic turn.
    public var untrustedModelInput: String {
        var lines = [
            "[UNTRUSTED DOMOCODE RECOVERY DATA]",
            "error_kind: \(originalKind)",
            "status: \(status.map(String.init) ?? "none")",
            "model: \(model ?? "unknown")",
            "provider_error: \(error)",
        ]
        if !providerMetadata.isEmpty {
            lines.append("provider_metadata: \(providerMetadata)")
        }
        if !retryHistory.isEmpty {
            lines.append(
                "retry_history: \(retryHistory.map { "\($0.number)/\($0.maxAttempts) \($0.reason) \($0.delayMilliseconds)ms" })"
            )
        }
        if let sessionContext, !sessionContext.isEmpty {
            lines.append("session_context: \(sessionContext)")
        }
        lines.append("[END UNTRUSTED DOMOCODE RECOVERY DATA]")
        return Self.safe(lines.joined(separator: "\n"), limit: 8_192)
    }

    /// Returns a copy with a bounded diagnostic conclusion.
    public func diagnosed(
        _ diagnosis: String,
        attemptedRemedies: [String] = [],
        userApprovedAction: Bool? = nil
    ) -> RecoveryEnvelope {
        var copy = self
        copy.diagnosis = Self.safe(diagnosis, limit: 2_048)
        copy.attemptedRemedies = attemptedRemedies.prefix(16).map { Self.safe($0, limit: 256) }
        copy.userApprovedAction = userApprovedAction
        return copy
    }

    /// Returns a copy with a bounded, redacted recent-session projection.
    /// Existing context wins so a producer that supplied a more authoritative
    /// safe context cannot be overwritten by a later UI projection.
    public func withSessionContext(_ context: String?) -> RecoveryEnvelope {
        guard sessionContext == nil, let context, !context.isEmpty else { return self }
        var copy = self
        copy = RecoveryEnvelope(
            originalKind: copy.originalKind,
            status: copy.status,
            error: copy.error,
            providerMetadata: copy.providerMetadata,
            model: copy.model,
            retryHistory: copy.retryHistory,
            sessionContext: context,
            attemptedRemedies: copy.attemptedRemedies,
            diagnosis: copy.diagnosis,
            userApprovedAction: copy.userApprovedAction,
            recursionPrevented: true
        )
        return copy
    }

    private static func safe(_ value: String, limit: Int) -> String {
        DoMoError.truncating(Redaction.diagnostic(value), to: max(0, limit))
    }
}
