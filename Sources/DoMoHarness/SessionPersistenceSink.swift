// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/agent-harness.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Synchronization

// MARK: - Persistence seam

/// The append side of the harness: the one operation a persistence sink needs of
/// the session that owns the mutable tip.
///
/// It is a protocol rather than a direct ``AgentHarness`` reference so the sink is
/// decoupled from the actor's full surface, and — more importantly — so the
/// append-and-advance stays *on* the actor. The tip moves as messages persist, and
/// only the actor may move it; the sink calls in from the loop's executor and the
/// hop is what serializes writes without a lock held across the loop's awaits.
public protocol SessionMessagePersisting: Sendable {
    /// Durably append `message` as a new tree entry and advance the leaf to it.
    /// Throwing is a real disk failure — the sink cannot surface it through the
    /// non-throwing ``AgentEventSink/emit(_:)``, so it is captured instead (see
    /// ``PersistenceErrorBox``).
    func persistMessage(_ message: Message) async throws
}

// MARK: - Deferred-error box

/// Holds the first persistence error seen during a run so the harness can rethrow
/// it after the loop settles.
///
/// ``AgentEventSink/emit(_:)`` is non-throwing by contract — a listener applies
/// backpressure but never fails the run — yet a `write()` to a full disk genuinely
/// can fail. Swallowing it would let a run report success over a truncated
/// transcript, which is the exact failure the crash-safe append exists to prevent.
/// The first error is recorded and the rest ignored (they are almost always the
/// same underlying fault) and the harness checks this once the loop returns.
public final class PersistenceErrorBox: Sendable {
    private let storage = Mutex<(any Error)?>(nil)

    public init() {}

    public func recordIfFirst(_ error: any Error) {
        storage.withLock { if $0 == nil { $0 = error } }
    }

    public var first: (any Error)? {
        storage.withLock { $0 }
    }
}

// MARK: - Sink

/// An ``AgentEventSink`` that persists the transcript as it streams and forwards
/// every event to an optional UI sink.
///
/// This is pi's `handleAgentEvent`, narrowed to Phase 3: on each ``AgentEvent/messageEnd``
/// the message becomes a durable tree entry and the leaf advances, so a crash at
/// any point leaves a readable prefix of exactly the messages that had settled.
/// `messageEnd` — not `messageStart` — is the persistence boundary because that is
/// where a message is final: an assistant turn's `messageStart` marks the *start*
/// of streaming and its content is not yet billable or complete. The user prompt,
/// each assistant turn, each tool result, and any injected steering/follow-up
/// message all pass through `messageEnd` in transcript order, so persisting there
/// records the whole conversation once, in order, with no duplication.
///
/// Persist-then-forward mirrors pi, where `appendMessage` precedes the listener
/// dispatch for `message_end`: the durable write lands before the UI is told the
/// message is done, so a UI that reacts by re-reading the file always sees it.
public struct SessionPersistenceSink: AgentEventSink {
    private let persister: any SessionMessagePersisting
    private let forward: (any AgentEventSink)?
    private let errorBox: PersistenceErrorBox

    public init(
        persister: any SessionMessagePersisting,
        forward: (any AgentEventSink)? = nil,
        errorBox: PersistenceErrorBox
    ) {
        self.persister = persister
        self.forward = forward
        self.errorBox = errorBox
    }

    public func emit(_ event: AgentEvent) async {
        if case .messageEnd(let message) = event {
            do {
                try await persister.persistMessage(message)
            } catch {
                errorBox.recordIfFirst(error)
            }
        }
        await forward?.emit(event)
    }
}
