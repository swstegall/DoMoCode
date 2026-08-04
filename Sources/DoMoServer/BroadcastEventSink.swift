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
        var sequencedSubscribers: [Int: AsyncStream<SequencedServerEvent>.Continuation] = [:]
        var history: [SequencedServerEvent] = []
        var nextSequence = 0
        var nextID = 0
    }

    private let state = Mutex(State())

    /// How many frames a single slow subscriber may fall behind before its oldest
    /// unread frames drop. Large enough that a client keeping up loses nothing;
    /// bounded so one stuck client cannot grow memory without end.
    private let perSubscriberBuffer: Int
    /// How much resumable history is retained in memory. A reconnecting client
    /// whose cursor is older than this window still gets the authoritative
    /// connected/status reconciliation; it is never given an unbounded replay.
    private let historyLimit: Int

    public init(perSubscriberBuffer: Int = 512, historyLimit: Int = 2048) {
        self.perSubscriberBuffer = perSubscriberBuffer
        self.historyLimit = max(1, historyLimit)
    }

    /// A live subscription: the stream to relay as SSE, and the id that
    /// unregisters it.
    public struct Subscription: Sendable {
        public let id: Int
        public let events: AsyncStream<ServerEvent>
    }

    /// A subscription that includes the durable-in-process session cursor.
    public struct SequencedSubscription: Sendable {
        public let id: Int
        public let events: AsyncStream<SequencedServerEvent>
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

    /// Register a cursor-aware subscriber. History is yielded while the state
    /// lock is held and the live subscription is installed under that same lock,
    /// so replayed events and newly emitted events cannot be reordered or leave
    /// a gap between the two paths.
    public func subscribe(after sequence: Int) -> SequencedSubscription {
        let (stream, continuation) = AsyncStream<SequencedServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(perSubscriberBuffer)
        )
        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            for event in state.history where event.sequence > sequence {
                continuation.yield(event)
            }
            state.sequencedSubscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.unsubscribe(id)
        }
        return SequencedSubscription(id: id, events: stream)
    }

    public func unsubscribe(_ id: Int) {
        // The lock is released before `finish()`, so the `onTermination` callback
        // it triggers re-enters `unsubscribe` cleanly (the second `removeValue`
        // returns nil) rather than deadlocking on this non-reentrant mutex.
        let continuations = state.withLock { state -> (
            AsyncStream<ServerEvent>.Continuation?,
            AsyncStream<SequencedServerEvent>.Continuation?
        ) in
            (
                state.subscribers.removeValue(forKey: id),
                state.sequencedSubscribers.removeValue(forKey: id)
            )
        }
        continuations.0?.finish()
        continuations.1?.finish()
    }

    /// The number of attached subscribers — for diagnostics and tests.
    public var subscriberCount: Int {
        state.withLock { $0.subscribers.count + $0.sequencedSubscribers.count }
    }

    /// Return every retained event after a cursor, ordered by the global session
    /// sequence. The result is bounded by `historyLimit` by construction.
    public func history(after sequence: Int = 0) -> [SequencedServerEvent] {
        state.withLock { state in
            state.history.filter { $0.sequence > sequence }
        }
    }

    /// The last sequence assigned to this session sink.
    public var currentSequence: Int {
        state.withLock { $0.nextSequence }
    }

    /// Continue a cursor from durable session-client state after a server
    /// restart. This only moves the counter forward; it never manufactures a
    /// replay row, so the next live event remains strictly after the client's
    /// last acknowledged sequence.
    public func seedSequence(_ sequence: Int) {
        guard sequence > 0 else { return }
        state.withLock { state in
            state.nextSequence = max(state.nextSequence, sequence)
        }
    }

    // MARK: AgentEventSink

    public func emit(_ event: AgentEvent) async {
        guard let serverEvent = ServerEvent.project(event) else { return }
        broadcast(serverEvent)
    }

    /// Push a server-originated frame — the opening ``ServerEvent/connected`` frame
    /// or a heartbeat — to every subscriber, on the same path run events take.
    public func broadcast(_ event: ServerEvent) {
        // Allocate the sequence and snapshot every subscriber under one lock.
        // `yield` is synchronous and non-blocking, so it is safe to perform it
        // after releasing the lock while preserving the captured order.
        let snapshot = state.withLock { state -> (
            [AsyncStream<ServerEvent>.Continuation],
            [AsyncStream<SequencedServerEvent>.Continuation],
            SequencedServerEvent
        ) in
            state.nextSequence += 1
            let sequenced = SequencedServerEvent(sequence: state.nextSequence, event: event)
            state.history.append(sequenced)
            if state.history.count > historyLimit {
                state.history.removeFirst(state.history.count - historyLimit)
            }
            return (
                Array(state.subscribers.values),
                Array(state.sequencedSubscribers.values),
                sequenced
            )
        }
        for continuation in snapshot.0 {
            continuation.yield(event)
        }
        for continuation in snapshot.1 {
            continuation.yield(snapshot.2)
        }
    }

    /// Finish every subscriber stream, so open SSE responses complete rather than
    /// hang. Used on server shutdown.
    public func closeAll() {
        let continuations = state.withLock { s -> (
            [AsyncStream<ServerEvent>.Continuation],
            [AsyncStream<SequencedServerEvent>.Continuation]
        ) in
            let values = Array(s.subscribers.values)
            let sequencedValues = Array(s.sequencedSubscribers.values)
            s.subscribers.removeAll()
            s.sequencedSubscribers.removeAll()
            return (values, sequencedValues)
        }
        for continuation in continuations.0 { continuation.finish() }
        for continuation in continuations.1 { continuation.finish() }
    }
}
