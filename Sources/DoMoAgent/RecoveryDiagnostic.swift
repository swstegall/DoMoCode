// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

/// The safe input given to an optional one-shot failure-diagnostic sub-turn.
///
/// The envelope has already redacted provider text and bounds every field. The
/// loop adds only a small, redacted recent-session projection; callers must treat
/// ``RecoveryDiagnosticRequest/untrustedInput`` as data, never as instructions.
public struct RecoveryDiagnosticRequest: Sendable {
    public let envelope: RecoveryEnvelope
    public let model: String
    public let maxOutputTokens: Int
    public let timeout: Duration

    public init(
        envelope: RecoveryEnvelope,
        model: String,
        maxOutputTokens: Int = 512,
        timeout: Duration = .seconds(8)
    ) {
        self.envelope = envelope
        self.model = model
        self.maxOutputTokens = max(1, min(2_048, maxOutputTokens))
        self.timeout = timeout
    }

    /// A clearly delimited prompt fragment. It is intentionally not a system
    /// prompt: the diagnostic caller supplies its own system instruction and
    /// must keep this entire value in a user/data message.
    public var untrustedInput: String { envelope.untrustedModelInput }
}

/// The bounded conclusion returned by a diagnostic sub-turn.
public struct RecoveryDiagnosticResult: Sendable {
    public let diagnosis: String
    public let attemptedRemedies: [String]
    public let userApprovedAction: Bool?

    public init(
        diagnosis: String,
        attemptedRemedies: [String] = [],
        userApprovedAction: Bool? = nil
    ) {
        self.diagnosis = diagnosis
        self.attemptedRemedies = attemptedRemedies
        self.userApprovedAction = userApprovedAction
    }
}

/// A host-provided, non-recursive diagnostic request.
///
/// Returning `nil` is the safe fallback: the original classified provider
/// failure remains authoritative. The callback must not call the agent loop
/// again; production wiring uses a direct one-shot completion with no tools.
public typealias RecoveryDiagnosticFn = @Sendable (
    RecoveryDiagnosticRequest
) async -> RecoveryDiagnosticResult?
