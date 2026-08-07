// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// MARK: - Gateway continuation

/// What a run does when the gateway between it and the model hangs up mid-turn.
///
/// A LiteLLM deployment in front of a slow model answers a long turn with a 504
/// (or a read timeout that never becomes a status at all) while the model itself
/// is still perfectly willing to keep going. The transcript up to that point is
/// already persisted, so the recovery that costs least is to ask the same
/// conversation to carry on rather than to fail the whole turn and make the user
/// retype the prompt.
///
/// This is deliberately *not* a retry policy. A retry re-sends the identical
/// request in the hope the transport behaves; this sends a **new, short** user
/// turn on top of the history the timed-out turn already wrote, which is why it
/// lives in the harness (which owns the session file) rather than in the LLM
/// client (which owns one request). The two compose: the client's retries are
/// exhausted first, and only the failure that survives them reaches here.
///
/// Every field is a bound on how much a failing gateway is allowed to cost. See
/// ``effectiveMaxAttempts`` for the one that cannot be walked around.
public struct GatewayContinuationSettings: Sendable, Hashable, Codable {
    /// Whether a gateway timeout is answered with a continuation prompt at all.
    ///
    /// `false` restores the plain behavior: the run settles on the timeout and
    /// the caller sees the failure.
    public var enabled: Bool

    /// How many continuation prompts one run may send.
    ///
    /// Counted per ``AgentHarness/run(messages:sink:runOverride:drainSteeringBeforeFirstTurn:)``,
    /// not per session: a run that needed ten continuations and finally answered
    /// starts the next turn with a fresh budget, because the next turn is fresh
    /// evidence about the gateway.
    public var maxAttempts: Int

    /// The continuation prompt itself.
    ///
    /// Short on purpose. It is appended to a conversation the model can already
    /// see in full, so anything longer only spends context restating what the
    /// transcript above it already says.
    public var message: String

    public init(
        enabled: Bool = true,
        maxAttempts: Int = 10,
        message: String = "Refer to previous context and continue."
    ) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
        self.message = message
    }

    public static let `default` = GatewayContinuationSettings()

    /// The ceiling no configuration can raise.
    ///
    /// The continuation loop re-prompts a model on failure, which is the exact
    /// shape that bills a user forever if it can spin. Config validation already
    /// rejects an out-of-range `maxAttempts`, but validation is a *layer*, and
    /// this value also arrives by ``Codable`` decode — which bypasses the
    /// initializer entirely and can therefore carry `Int.max` from a hand-edited
    /// settings file. The cap is applied where the loop reads the number, so
    /// there is no path to an unbounded loop rather than merely no known one.
    public static let attemptHardCap = 100

    /// How many continuation prompts this configuration actually permits.
    ///
    /// Folds ``enabled`` in as zero rather than leaving it a second condition a
    /// future caller could forget, and clamps at both ends: a negative
    /// ``maxAttempts`` from a malformed file means "none", never a loop whose
    /// bound is below its counter's start.
    public var effectiveMaxAttempts: Int {
        guard enabled else { return 0 }
        return max(0, min(maxAttempts, Self.attemptHardCap))
    }
}
