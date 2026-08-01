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
    ///
    /// - Parameter elapsedMs: How long the model call that produced this message
    ///   took, measured from its `messageStart` to its `messageEnd`. `nil` means
    ///   **nothing was measured**, which is not the same as "it took no time".
    ///
    ///   Only an assistant turn is ever timed. A user prompt, a steering
    ///   injection and a tool result are all *already finished* by the time the
    ///   loop announces them — their `messageStart` and `messageEnd` are emitted
    ///   back to back around a value that already exists — so there is no
    ///   interval to report for them and they persist with `nil`. Writing the `0`
    ///   those adjacent boundaries measure would be a claim about a stopwatch
    ///   nobody started, indistinguishable on the wire from a real measurement,
    ///   and — because a session file is append-only — permanent.
    func persistMessage(_ message: Message, elapsedMs: Int?) async throws
}

// MARK: - Monotonic elapsed time

/// Whole milliseconds between two monotonic instants, or `nil` when the interval
/// is not a measurement.
///
/// Milliseconds and not a `Duration` because this ends up in a JSON field that
/// other tools read, and a fixed integer unit is the only shape that survives that
/// trip unambiguously.
///
/// A negative interval returns `nil` rather than being floored to `0`. A
/// `ContinuousClock` cannot run backwards, so the only way to get one is an
/// injected clock that is not a clock — and answering `0` there would launder a
/// broken measurement into a plausible-looking one.
func elapsedMilliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int? {
    let components = (end - start).components
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    let milliseconds = components.seconds * 1_000 + components.attoseconds / attosecondsPerMillisecond
    guard milliseconds >= 0 else { return nil }
    return Int(clamping: milliseconds)
}

// MARK: - Message-scoped stopwatch

/// The instant the assistant message currently being streamed started.
///
/// A class around a `Mutex` for the same reason ``PersistenceErrorBox`` is one:
/// ``SessionPersistenceSink`` is a `struct` and its `emit` is non-mutating, so it
/// cannot hold the stopwatch itself. The event pairs it tracks are strictly
/// non-overlapping — every `messageStart` is followed by its own `messageEnd`
/// before another `messageStart`, in ``AgentLoop`` and in ``ToolDispatch`` alike,
/// including the parallel tool path, which emits result messages serially in phase
/// C — so a single slot is enough and a stack would be dead structure.
///
/// The slot is filled only for a message whose interval is a real measurement;
/// any other message boundary ``clear()``s it, so an untimed message can neither
/// start a stopwatch nor inherit one.
private final class MessageStopwatch: Sendable {
    private let startedAt = Mutex<ContinuousClock.Instant?>(nil)

    func start(_ instant: ContinuousClock.Instant) {
        startedAt.withLock { $0 = instant }
    }

    /// Forget any pending start without reading it.
    func clear() {
        startedAt.withLock { $0 = nil }
    }

    /// The pending start, cleared. A second `messageEnd` with no start between
    /// them therefore measures nothing rather than re-using a stale instant.
    func takeStart() -> ContinuousClock.Instant? {
        startedAt.withLock { pending in
            let taken = pending
            pending = nil
            return taken
        }
    }
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
///
/// This is also where an assistant turn's wall time is measured, because this is
/// the only place both ends of it are visible. The interval is **message**-scoped
/// (`messageStart` → `messageEnd`) and not turn-scoped: the turn events are not
/// balanced — the `maxTurns` return sits before a `turnStart`, and an aborted
/// settle emits a `turnEnd` for an iteration whose `turnStart` never fired — so a
/// turn-scoped stopwatch would silently mis-pair on exactly the runs whose timings
/// matter most.
///
/// **Only assistant messages are timed.** Every other message the loop announces
/// is complete before its `messageStart` is emitted: ``AgentLoop`` emits the
/// prompt's and each steering message's start and end on consecutive lines, and
/// ``ToolDispatch``'s `emitResultMessage` does the same for a tool result once the
/// tool has already returned. Timing those measures the two `await`s between the
/// emits and nothing else, and the `0` it yields is a lie a session file keeps
/// forever — it cannot be told from a genuinely instantaneous turn, and there is
/// no backfilling an append-only log. So they persist with `elapsedMs == nil`,
/// which is the field's documented spelling for "nothing was measured".
///
/// What an assistant turn's number actually is, stated exactly so nobody has to
/// guess: the interval from its **first stream boundary** to its terminal one.
/// `AgentLoop.streamAssistantResponse` emits `messageStart` when the assembly
/// yields `.start`, i.e. when the first chunk lands, so the wait *before* that —
/// connection, queueing, prompt processing — is outside the measurement. It is
/// streaming latency, not round-trip latency. A turn that never opened a stream
/// at all (a transport failure, or the synthesized `.aborted` settle) has both
/// boundaries emitted back to back and measures ~0, which is a true statement
/// about the settle it is measuring and the only interval that exists for it.
public struct SessionPersistenceSink: AgentEventSink {
    private let persister: any SessionMessagePersisting
    private let forward: (any AgentEventSink)?
    private let errorBox: PersistenceErrorBox

    /// The clock the stopwatch reads.
    ///
    /// Monotonic and injected, never `Configuration.now`: a `Date` delta can go
    /// negative across an NTP step, and every harness test pins `now` to one
    /// constant, which would make every elapsed assertion a vacuous `0`.
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    private let stopwatch = MessageStopwatch()

    public init(
        persister: any SessionMessagePersisting,
        forward: (any AgentEventSink)? = nil,
        errorBox: PersistenceErrorBox,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.persister = persister
        self.forward = forward
        self.errorBox = errorBox
        self.monotonicNow = monotonicNow
    }

    /// Whether this message's boundaries bracket work that was actually done.
    ///
    /// Only an assistant turn does: it is the one message the loop *produces*,
    /// by making a model call and streaming the answer between the two events.
    /// Every other message — the user prompt, a steering injection, a tool result
    /// — exists in full before its `messageStart` is emitted, so its boundaries
    /// bracket nothing and there is no interval to report.
    private static func isTimed(_ message: Message) -> Bool {
        if case .assistant = message { return true }
        return false
    }

    public func emit(_ event: AgentEvent) async {
        switch event {
        case .messageStart(let message):
            // The clock is not even read for an untimed message: reading it would
            // start a stopwatch whose only possible answer is a fabricated one.
            if Self.isTimed(message) { stopwatch.start(monotonicNow()) } else { stopwatch.clear() }
        case .messageEnd(let message):
            // Always taken, so the slot is cleared by whichever boundary arrives.
            // `nil` when no start was seen for this message — a message appended
            // by something other than the loop, or one that is not timed at all —
            // and never `0`, which would be a claim about a stopwatch nobody
            // started.
            let started = stopwatch.takeStart()
            let elapsed: Int? = Self.isTimed(message)
                ? started.flatMap { elapsedMilliseconds(from: $0, to: monotonicNow()) }
                : nil
            do {
                try await persister.persistMessage(message, elapsedMs: elapsed)
            } catch {
                errorBox.recordIfFirst(error)
            }
        case .agentStart, .agentEnd, .turnStart, .turnEnd, .messageUpdate,
            .toolExecutionStart, .toolExecutionEnd, .notice:
            break
        }
        await forward?.emit(event)
    }
}
