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
    ///   Only a turn whose model call actually started is ever timed. A user
    ///   prompt, a steering injection, a tool result — and an assistant turn whose
    ///   stream never opened — are all *already finished* by the time the loop
    ///   announces them: their `messageStart` and `messageEnd` are emitted back to
    ///   back around a value that already exists, so there is no interval to
    ///   report for them and they persist with `nil`. Writing the `0` those
    ///   adjacent boundaries measure would be a claim about a stopwatch nobody
    ///   started, indistinguishable on the wire from a real measurement, and —
    ///   because a session file is append-only — permanent.
    func persistMessage(_ message: Message, elapsedMs: Int?) async throws

    // There is deliberately NO `persistMessage(_:)` convenience overload, and its
    // absence is a source break this project chose to take rather than an
    // oversight. The parameterless default that used to sit here supplied
    // `elapsedMs: nil` for any conformer that had not been updated — which is
    // exactly the conformer that most needs to be told. `elapsedMs` is written
    // once into an append-only log and can never be backfilled, so a conformer
    // that silently records nothing records nothing forever; a compile error is
    // the only feedback that arrives in time. And the "an embedding's call sites
    // are not ours to break" argument the default was kept for does not hold here:
    // `Package.swift` exports exactly two products, the `domo` executable and the
    // `DoMoCore` library, so `DoMoHarness` is not reachable from outside this
    // package and no foreign type can be conforming to this protocol. Every call
    // site in the repository already passes the argument. If `DoMoHarness` is ever
    // published as a product, restore the default here — do not re-add it at a
    // call site.
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
/// **Only a turn whose model call actually started is timed.** Every other message
/// the loop announces is complete before its `messageStart` is emitted: ``AgentLoop``
/// emits the prompt's and each steering message's start and end on consecutive
/// lines, and ``ToolDispatch``'s `emitResultMessage` does the same for a tool
/// result once the tool has already returned. Timing those measures the two
/// `await`s between the emits and nothing else, and the `0` it yields is a lie a
/// session file keeps forever — it cannot be told from a genuinely instantaneous
/// turn, and there is no backfilling an append-only log. So they persist with
/// `elapsedMs == nil`, which is the field's documented spelling for "nothing was
/// measured".
///
/// What an assistant turn's number actually is, stated exactly so nobody has to
/// guess: the interval from its **first stream boundary** to its terminal one.
/// `AgentLoop.streamAssistantResponse` emits `messageStart` when the assembly
/// yields `.start`, i.e. when the first chunk lands, so the wait *before* that —
/// connection, queueing, prompt processing — is outside the measurement. It is
/// streaming latency, not round-trip latency.
///
/// A turn that never opened a stream at all — a transport failure, or the
/// synthesized `.aborted` settle — is therefore **not** timed either, and this
/// used to be the one hole in the rule above. Its two boundaries are emitted back
/// to back by `synthesizeTerminal` around a message that already existed, exactly
/// like a prompt's, so the `~0` between them measures the emit and not the turn.
/// The field's own documentation says an untimed message persists with `nil`, and
/// a failed turn is no exception: it records `nil` too. See
/// ``opensAModelCall(_:)`` for how the two kinds of `messageStart` are told apart,
/// and for why a stream that opened and *then* failed keeps its real number.
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

    /// Whether this `messageStart` marks a model call that actually started.
    ///
    /// Being an assistant turn is necessary and — this is the part the role check
    /// alone got wrong — not sufficient. An assistant turn is the one message the
    /// loop *produces*, by opening a stream and assembling the answer between the
    /// two events; every other message (the user prompt, a steering injection, a
    /// tool result) exists in full before its `messageStart` is emitted, so its
    /// boundaries bracket nothing.
    ///
    /// But an assistant turn whose stream never opened is in exactly that second
    /// category, and it is the case this field's documentation is most emphatic
    /// about. `AgentLoop.synthesizeTerminal` fabricates a `messageStart` for a turn
    /// that died before its first chunk — a refused connection, a transport
    /// failure, a cancellation — so that every `messageEnd` still has a partner for
    /// a UI to close against; the two are emitted on consecutive lines around a
    /// message that was complete before either of them. Timing those measures two
    /// `await`s, and the `0` it wrote is precisely the permanent, unbackfillable
    /// lie the `nil` spelling exists to avoid.
    ///
    /// The signal is the message the *start* boundary carries. A live `.start`
    /// snapshot cannot carry a verdict: `StreamingAssembly` emits `.start` before
    /// it reads that chunk's `finish_reason`, so its `stopReason` is unset (hence
    /// `.stop`) and its `errorMessage` is `nil`, always. A `messageStart` carrying
    /// anything else is carrying a turn that had already stopped, which is only
    /// ever the fabricated boundary.
    ///
    /// A stream that opened and *then* failed keeps its measurement, which is the
    /// case that must not be lost: its `messageStart` came from the real `.start`,
    /// before the failure existed, and the interval up to the failure is real. That
    /// is also why this is asked at `messageStart` and never at `messageEnd` —
    /// asking at the end would see the `.error` terminal and throw away a genuine
    /// measurement.
    private static func opensAModelCall(_ message: Message) -> Bool {
        guard case .assistant(let assistant) = message else { return false }
        return assistant.stopReason == .stop && assistant.errorMessage == nil
    }

    /// Whether the message closing a pair could be the assistant turn a stopwatch
    /// was started for. Belt and braces: the slot is only ever filled by an
    /// assistant `messageStart`, so this can only differ from that if the loop's
    /// boundaries ever mis-pair, and a mis-paired interval must not be written.
    private static func isAssistantTurn(_ message: Message) -> Bool {
        if case .assistant = message { return true }
        return false
    }

    public func emit(_ event: AgentEvent) async {
        switch event {
        case .messageStart(let message):
            // The clock is not even read for an untimed message: reading it would
            // start a stopwatch whose only possible answer is a fabricated one.
            if Self.opensAModelCall(message) { stopwatch.start(monotonicNow()) } else { stopwatch.clear() }
        case .messageEnd(let message):
            // Always taken, so the slot is cleared by whichever boundary arrives.
            // `nil` when no start was seen for this message — a message appended
            // by something other than the loop, one that is not timed at all, or a
            // turn whose stream never opened — and never `0`, which would be a
            // claim about a stopwatch nobody started.
            let started = stopwatch.takeStart()
            let elapsed: Int? = Self.isAssistantTurn(message)
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
