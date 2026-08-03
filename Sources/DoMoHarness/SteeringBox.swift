// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoLLM
import Synchronization

/// Controls how messages waiting for an agent run are delivered.
public enum QueueDeliveryMode: String, Codable, Hashable, Sendable {
    /// Deliver every queued message at the next turn boundary.
    case all

    /// Deliver one queued message at each turn boundary.
    case oneAtATime = "one-at-a-time"
}

/// A small, thread-safe queue for messages typed while an agent is running.
///
/// The queue is intentionally independent of an actor. Interactive clients can
/// enqueue from a transport callback while the harness is suspended in a model
/// stream, and the agent loop can drain it from its async boundary without
/// holding a lock across an await.
public final class SteeringBox: Sendable {
    private struct State: Sendable {
        var messages: [Message]
        var mode: QueueDeliveryMode
    }

    private let state: Mutex<State>

    public init(mode: QueueDeliveryMode = .oneAtATime) {
        self.state = Mutex(State(messages: [], mode: mode))
    }

    public var mode: QueueDeliveryMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    public var count: Int {
        state.withLock { $0.messages.count }
    }

    public func enqueue(_ message: Message) {
        state.withLock { $0.messages.append(message) }
    }

    public func enqueue(contentsOf messages: [Message]) {
        guard !messages.isEmpty else { return }
        state.withLock { $0.messages.append(contentsOf: messages) }
    }

    /// Removes the next batch according to the current delivery mode.
    public func drain() -> [Message] {
        state.withLock { state in
            let amount = state.mode == .all ? state.messages.count : min(state.messages.count, 1)
            guard amount > 0 else { return [] }
            let messages = Array(state.messages.prefix(amount))
            state.messages.removeFirst(amount)
            return messages
        }
    }

    /// Removes every queued message, regardless of the delivery mode.
    public func drainAll() -> [Message] {
        state.withLock { state in
            let messages = state.messages
            state.messages.removeAll(keepingCapacity: true)
            return messages
        }
    }

    public func clear() {
        state.withLock { $0.messages.removeAll(keepingCapacity: true) }
    }
}

/// The follow-up queue has the same storage and delivery semantics as steering.
/// Keeping the alias makes the two loop hooks explicit at call sites without
/// duplicating a synchronization primitive.
public typealias FollowUpBox = SteeringBox
