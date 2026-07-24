// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import Synchronization

/// Fans a session's run events out to every attached SSE subscriber.
///
/// One instance per live session, installed as the `forward:` of the run's
/// ``DoMoHarness/SessionPersistenceSink`` — so durable persistence still happens
/// on the awaited path, and this sink is purely the network tap.
///
/// Its ``emit(_:)`` is deliberately **non-blocking**: it projects the event to a
/// ``ServerEvent`` and *yields* it into each subscriber's bounded stream, never
/// awaiting a consumer. That is the backpressure split the server design calls for
/// — the awaited-emit guarantee the in-process listeners rely on cannot be
/// extended across a socket, because one HTTP client that stopped reading would
/// stall the whole agent loop. A subscriber that falls behind instead drops its
/// oldest buffered frames (`.bufferingNewest`) and can recover current state over
/// REST. See the README, "Concurrency and isolation".
public final class BroadcastEventSink: AgentEventSink {

    private struct State {
        var subscribers: [Int: AsyncStream<ServerEvent>.Continuation] = [:]
        var nextID = 0
    }

    private let state = Mutex(State())

    /// How many frames a single slow subscriber may fall behind before its oldest
    /// unread frames drop. Large enough that a client keeping up loses nothing;
    /// bounded so one stuck client cannot grow memory without end.
    private let perSubscriberBuffer: Int

    public init(perSubscriberBuffer: Int = 512) {
        self.perSubscriberBuffer = perSubscriberBuffer
    }

    /// A live subscription: the stream to relay as SSE, and the id that
    /// unregisters it.
    public struct Subscription: Sendable {
        public let id: Int
        public let events: AsyncStream<ServerEvent>
    }

    /// Register a subscriber. The returned stream yields every event emitted after
    /// this call. Registration is dropped automatically when the stream terminates
    /// (the client disconnected, or its task was cancelled), so a handler need only
    /// stop iterating; ``unsubscribe(_:)`` is available for an explicit teardown.
    public func subscribe() -> Subscription {
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(perSubscriberBuffer)
        )
        let id = state.withLock { s -> Int in
            let id = s.nextID
            s.nextID += 1
            s.subscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id)
        }
        return Subscription(id: id, events: stream)
    }

    public func unsubscribe(_ id: Int) {
        // The lock is released before `finish()`, so the `onTermination` callback
        // it triggers re-enters `unsubscribe` cleanly (the second `removeValue`
        // returns nil) rather than deadlocking on this non-reentrant mutex.
        let continuation = state.withLock { $0.subscribers.removeValue(forKey: id) }
        continuation?.finish()
    }

    /// The number of attached subscribers — for diagnostics and tests.
    public var subscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    // MARK: AgentEventSink

    public func emit(_ event: AgentEvent) async {
        guard let serverEvent = ServerEvent.project(event) else { return }
        broadcast(serverEvent)
    }

    /// Push a server-originated frame — the opening ``ServerEvent/connected`` frame
    /// or a heartbeat — to every subscriber, on the same path run events take.
    public func broadcast(_ event: ServerEvent) {
        // Snapshot under the lock, yield outside it: `yield` is synchronous and
        // non-blocking, but holding the mutex across a fan-out is needless.
        let continuations = state.withLock { Array($0.subscribers.values) }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// Finish every subscriber stream, so open SSE responses complete rather than
    /// hang. Used on server shutdown.
    public func closeAll() {
        let continuations = state.withLock { s -> [AsyncStream<ServerEvent>.Continuation] in
            let values = Array(s.subscribers.values)
            s.subscribers.removeAll()
            return values
        }
        for continuation in continuations { continuation.finish() }
    }
}
