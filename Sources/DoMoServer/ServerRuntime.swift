// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoPermissions
import Foundation
import Synchronization
import SystemPackage

// MARK: - Errors and value types

/// A failure the HTTP layer maps onto a status code.
public enum ServerRuntimeError: Error, Sendable, Equatable {
    /// No session with that id is live or on disk.
    case sessionNotFound
    /// A turn is already running for that session; only one runs at a time.
    case sessionBusy
}

/// A reference to a session, returned by create and fork.
public struct SessionRef: Sendable, Codable, Hashable {
    public let id: String
    public let path: String
    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

/// An authoritative snapshot of what the server believes about one session.
///
/// The server owns run state and the pending-prompt set; a client's copy is only
/// ever a fold of edge-triggered SSE frames, and every one of those edges can be
/// missed (a dropped frame on the bounded broadcast buffer, a half-open socket, a
/// run that never emits its close). This is the level-triggered answer, so a
/// wedged client can ask instead of guess.
public struct SessionStatus: Sendable, Codable, Hashable {
    public var sessionID: String
    public var running: Bool
    public var pendingPermissionIDs: [String]
    public var subscribers: Int
    /// ISO8601, or nil when nothing is running. Lets a client say "running for
    /// 14m" instead of an undifferentiated spinner.
    public var runStartedAt: String?

    public init(
        sessionID: String,
        running: Bool,
        pendingPermissionIDs: [String],
        subscribers: Int,
        runStartedAt: String?
    ) {
        self.sessionID = sessionID
        self.running = running
        self.pendingPermissionIDs = pendingPermissionIDs
        self.subscribers = subscribers
        self.runStartedAt = runStartedAt
    }
}

/// A row in the session listing.
public struct SessionSummary: Sendable, Codable, Hashable {
    public let id: String
    public let path: String
    public let cwd: String
    public let timestamp: String
    public init(id: String, path: String, cwd: String, timestamp: String) {
        self.id = id
        self.path = path
        self.cwd = cwd
        self.timestamp = timestamp
    }
}

// MARK: - ServerRuntime

/// Owns the server's live sessions and the shared ingredients each ``AgentHarness``
/// is built from.
///
/// An `actor` because every mutation — creating a session, starting or clearing a
/// run task — must be serialized against the SSE and REST handlers that touch the
/// same registry from different request tasks. The harness it wraps is itself an
/// actor, so a call chain here is two hops; that is the price of not sharing
/// mutable run state across the socket by hand.
///
/// A run is aborted by **cancelling its `Task`** — ``AgentHarness`` has no abort
/// method, by design, because the loop and stream already honour cooperative
/// cancellation. The task is retained so ``abort(sessionID:)`` can reach it, and
/// cleared when the run settles so the next prompt is admitted.
///
/// Three limitations are accepted under the single-client-first posture and would be
/// revisited for multi-client: ``abort(sessionID:)`` cancels whatever run currently
/// holds the slot, so a stale abort landing in the brief window after one run ends
/// and the next begins could stop the wrong turn; a prompt pipelined in that same
/// window may see a transient `sessionBusy` and succeed on retry; and live sessions
/// are never evicted from the map, so a client that creates without bound grows
/// memory and disk (it is only ever throttling itself).
public actor ServerRuntime {

    /// The shared runtime ingredients, assembled once by the `serve` command and
    /// reused to build a fresh ``AgentHarness/Configuration`` per session.
    /// The permission engine's ingredients (Phase 8b). The runtime builds a fresh
    /// engine PER SESSION (each needs its own `sessionID`, which the `PermissionRequest`
    /// carries to route the round-trip back), so `Config` holds the ingredients, not a
    /// prebuilt hook. `nil` runs every tool ungated (tests, back-compat).
    public struct PermissionRuntime: Sendable {
        public let ruleset: Ruleset
        public let factory: PermissionRequestFactory
        public let persist: @Sendable (Ruleset) async -> Void
        public init(
            ruleset: Ruleset,
            factory: PermissionRequestFactory,
            persist: @escaping @Sendable (Ruleset) async -> Void
        ) {
            self.ruleset = ruleset
            self.factory = factory
            self.persist = persist
        }
    }

    public struct Config: Sendable {
        public var systemPrompt: String
        public var tools: [any AgentTool]
        public var model: String
        public var streamFn: AgentStreamFn
        public var toolExecution: ToolExecutionMode
        public var maxTurns: Int?
        public var sessionDirectory: FilePath
        public var cwd: String
        public var permissions: PermissionRuntime?

        public init(
            systemPrompt: String,
            tools: [any AgentTool],
            model: String,
            streamFn: @escaping AgentStreamFn,
            toolExecution: ToolExecutionMode = .sequential,
            maxTurns: Int? = nil,
            sessionDirectory: FilePath,
            cwd: String,
            permissions: PermissionRuntime? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.tools = tools
            self.model = model
            self.streamFn = streamFn
            self.toolExecution = toolExecution
            self.maxTurns = maxTurns
            self.sessionDirectory = sessionDirectory
            self.cwd = cwd
            self.permissions = permissions
        }
    }

    /// One run's tap on a session's shared ``BroadcastEventSink``, which can be
    /// switched off for good.
    ///
    /// ``forceClearRun(sessionID:)`` walks away from a run that by construction
    /// cannot be stopped — it holds the slot precisely because nothing can unwind
    /// it — while carrying the session's sink across to the replacement state, so
    /// attached SSE subscribers survive. Without this gate the abandoned run keeps
    /// broadcasting into that shared sink whenever it eventually settles: a
    /// `tool_end` for a call the client never saw start, a foreign assistant
    /// message, a spurious `turn_end`, and — the damaging one — a terminal
    /// `agent_end`. A client folds `agent_end` into `runState = .idle` while a
    /// *different* run is actually holding the slot, so the spinner stops, the user
    /// types, and the server answers 409 "a turn is already running". That is the
    /// exact "the session stopped accepting prompts" symptom this whole feature
    /// exists to remove, re-created by its own escape hatch.
    ///
    /// ``finishRun(_:token:)``'s token guard protects the SLOT; this protects the
    /// STREAM. Both are needed: they are consulted at different moments by
    /// different threads, and neither implies the other.
    ///
    /// The flag is a `Mutex` rather than actor state because ``emit(_:)`` is called
    /// from the run's task on whatever executor the loop is on, while ``detach()``
    /// is called from the runtime actor.
    private final class RunSink: AgentEventSink {
        private let inner: BroadcastEventSink
        private let live = Mutex(true)

        init(_ inner: BroadcastEventSink) {
            self.inner = inner
        }

        /// Silence this run permanently. Idempotent; never un-does.
        func detach() {
            live.withLock { $0 = false }
        }

        func emit(_ event: AgentEvent) async {
            guard live.withLock({ $0 }) else { return }
            await inner.emit(event)
        }

        /// A server-originated frame on behalf of this run (its terminal
        /// `agent_end` when the loop could not emit its own), gated identically.
        func broadcast(_ event: ServerEvent) {
            guard live.withLock({ $0 }) else { return }
            inner.broadcast(event)
        }
    }

    /// One live session's mutable state. A reference type held only inside the
    /// actor, so its `runTask` mutation is serialized by the actor, not shared.
    ///
    /// `token` is a Sendable identity a run can carry into its completion hop, so a
    /// run that finishes after its session was replaced does not clear the
    /// replacement's slot (the state object itself is not Sendable and cannot cross
    /// into the run Task).
    private final class SessionState {
        let token: Int
        let harness: AgentHarness
        let sink: BroadcastEventSink
        var runTask: Task<Void, Never>?
        /// The gate on the current run's output. Retained beside `runTask` so
        /// ``forceClearRun(sessionID:)`` can silence a run it is abandoning.
        var runSink: RunSink?
        /// When the run currently holding the slot was admitted; nil when idle.
        /// Set beside `runTask` and cleared beside it, so the pair cannot drift.
        var runStartedAt: Date?
        /// Permission prompts awaiting a client answer, keyed by request id. The
        /// engine's prompter suspends on the continuation; a REST answer (or an
        /// abort/shutdown) resumes it. Held only inside the actor, never shared.
        var pending: [String: PendingApproval] = [:]

        init(token: Int, harness: AgentHarness, sink: BroadcastEventSink) {
            self.token = token
            self.harness = harness
            self.sink = sink
        }
    }

    /// A suspended permission prompt: the original request (so a re-attaching client
    /// can be told about it) and the continuation to resume with the answer.
    private struct PendingApproval {
        let request: PermissionRequest
        let continuation: CheckedContinuation<PermissionReply, Never>
    }

    private let config: Config
    private var sessions: [String: SessionState] = [:]
    private var nextToken = 0

    public init(config: Config) {
        self.config = config
    }

    private func makeState(harness: AgentHarness, sink: BroadcastEventSink) -> SessionState {
        let token = nextToken
        nextToken += 1
        return SessionState(token: token, harness: harness, sink: sink)
    }

    /// Build the harness configuration for one session, wiring the permission gate
    /// bound to THIS session's id (so a prompt routes its answer back to this
    /// session's pending map). The prompter is `self.awaitPermission` — the runtime
    /// that owns the pending map already exists, so no `PrompterBox` is needed.
    private func harnessConfiguration(sessionID: String) -> AgentHarness.Configuration {
        var beforeToolCall: BeforeToolCallHook?
        if let permissions = config.permissions {
            let engine = PermissionEngine(
                ruleset: permissions.ruleset,
                prompt: { [weak self] request in
                    guard let self else { return .reject(message: "The server is shutting down.") }
                    return await self.awaitPermission(request)
                },
                persist: permissions.persist
            )
            beforeToolCall = permissionHook(engine: engine, factory: permissions.factory, sessionID: sessionID)
        }
        return AgentHarness.Configuration(
            systemPrompt: config.systemPrompt,
            tools: config.tools,
            model: config.model,
            streamFn: config.streamFn,
            toolExecution: config.toolExecution,
            maxTurns: config.maxTurns,
            beforeToolCall: beforeToolCall
        )
    }

    // MARK: Permission round-trip

    /// The engine's prompter for a server session: store the continuation, broadcast
    /// the ask to the SSE subscribers, and suspend. A client answers over REST via
    /// ``resolvePermission(sessionID:requestID:reply:)``; abort/shutdown resume it as
    /// a reject. Runs on this actor, so `withCheckedContinuation` stores + broadcasts
    /// synchronously and then releases the actor while the run parks.
    func awaitPermission(_ request: PermissionRequest) async -> PermissionReply {
        // Already being aborted → reject without suspending (closes the store race).
        if Task.isCancelled { return .reject(message: "The tool call was aborted.") }
        guard let session = sessions[request.sessionID] else {
            return .reject(message: "No session is available to approve this tool call.")
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<PermissionReply, Never>) in
            session.pending[request.id] = PendingApproval(request: request, continuation: continuation)
            session.sink.broadcast(permissionEvent(request))
        }
    }

    /// Answer a pending prompt (REST-driven). Idempotent: a stale/duplicate answer for
    /// an already-resolved id is a no-op (abort/shutdown may have drained it), so a
    /// double POST is not a 500.
    public func resolvePermission(sessionID: String, requestID: String, reply: PermissionReply) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard let approval = session.pending.removeValue(forKey: requestID) else { return }
        approval.continuation.resume(returning: reply)
        session.sink.broadcast(.permissionResolved(id: requestID))
    }

    /// The still-open prompts for a session, as wire events — so a (re)connecting or
    /// session-switching client can reconcile a prompt it missed on the drop-oldest
    /// SSE stream (otherwise the run would hang forever with no one to answer).
    public func pendingPermissions(sessionID: String) throws -> [ServerEvent] {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        return session.pending.values.map { permissionEvent($0.request) }
    }

    private func permissionEvent(_ request: PermissionRequest) -> ServerEvent {
        .permissionRequest(
            id: request.id,
            sessionID: request.sessionID,
            permission: request.permission,
            patterns: request.patterns,
            always: request.always,
            metadata: request.metadata,
            disableAlways: request.disableAlways
        )
    }

    // MARK: Lifecycle

    /// Create a fresh session, or open an existing one when `resume` names a
    /// session file path or a session id.
    public func createSession(resume: String? = nil) async throws -> SessionRef {
        // The session id must be known BEFORE building the harness config, so the
        // permission hook can be bound to it (a prompt routes its answer by sessionID).
        let harness: AgentHarness
        let id: String
        if let resume {
            let path = try await resolveResume(resume)
            let resumedID = try await Self.readSessionID(at: path)
            // Already live? Return it rather than standing up a second harness over
            // the same file — that would orphan the running task and leave the
            // existing SSE subscribers attached to a sink no run feeds.
            if let existing = sessions[resumedID] {
                return SessionRef(id: resumedID, path: await existing.harness.sessionFilePath.string)
            }
            harness = try await Self.reopen(path: path, configuration: harnessConfiguration(sessionID: resumedID))
            id = resumedID
        } else {
            id = UUIDv7.generate().description
            harness = try AgentHarness.start(
                cwd: config.cwd,
                sessionDirectory: config.sessionDirectory,
                configuration: harnessConfiguration(sessionID: id),
                sessionID: id
            )
        }
        let path = await harness.sessionFilePath
        // Re-check after every suspension above, for the same reason as the first
        // check: a concurrent resume of the same id must not replace a live session
        // and strand its run and its subscribers. `harness` is dropped unused.
        if sessions[id] != nil { return SessionRef(id: id, path: path.string) }
        sessions[id] = makeState(harness: harness, sink: BroadcastEventSink())
        return SessionRef(id: id, path: path.string)
    }

    /// Fork a live session into a new file, leaving the original untouched.
    public func fork(sessionID: String) async throws -> SessionRef {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let forked = try await session.harness.fork(sessionDirectory: config.sessionDirectory)
        let path = await forked.sessionFilePath
        let id = try await Self.readSessionID(at: path)
        // `fork` reuses the PARENT's configuration, whose permission hook is bound to
        // the parent's sessionID — a prompt from the forked run would route to the
        // wrong session and hang. Re-open the forked file with a correctly-bound
        // config (only when gating is on; ungated forks keep the cheap path).
        let harness: AgentHarness
        if config.permissions != nil {
            harness = try await Self.reopen(path: path, configuration: harnessConfiguration(sessionID: id))
        } else {
            harness = forked
        }
        sessions[id] = makeState(harness: harness, sink: BroadcastEventSink())
        return SessionRef(id: id, path: path.string)
    }

    // MARK: Runs

    /// Start a turn on a session. Returns immediately; the run advances in a
    /// retained ``Task`` whose events flow to the session's broadcast sink.
    ///
    /// Throws ``ServerRuntimeError/sessionBusy`` if a run is already in flight —
    /// the single-turn-at-a-time rule the harness enforces internally, surfaced
    /// here as a 409 rather than swallowed inside a fire-and-forget task.
    public func startRun(sessionID: String, prompt: String, attachments: [ImageBlock]) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        let harness = session.harness
        // NOT `session.sink` directly: everything this run emits goes through a gate
        // the runtime can close, so a run that ``forceClearRun(sessionID:)`` walked
        // away from cannot narrate itself into a stream a later run owns. See
        // ``RunSink``.
        let sink = RunSink(session.sink)
        let token = session.token
        session.runSink = sink
        session.runStartedAt = Date()
        session.runTask = Task { [weak self] in
            do {
                _ = try await harness.run(prompt: prompt, attachments: attachments, sink: sink)
            } catch is CancellationError {
                // Aborted before the loop emitted its own close.
                sink.broadcast(.agentEnd(reason: "aborted"))
            } catch {
                // A failure before agentStart (compaction, context build) or a
                // persistence error after the loop settled would otherwise leave the
                // stream with no terminal frame. Guarantee exactly one close per
                // accepted prompt, so a subscriber never hangs.
                sink.broadcast(.agentEnd(reason: "errored"))
            }
            await self?.finishRun(sessionID, token: token)
        }
    }

    /// Clear the run slot, but only if the session is still the one that started the
    /// run — a session replaced since must not have a completing run nil its
    /// successor's slot.
    ///
    /// This guard used to be dead code (no code path ever replaced a live
    /// `SessionState`). ``forceClearRun(sessionID:)`` makes it load-bearing: the
    /// doomed run it walks away from may settle at any later moment, and when it
    /// does its completion hop must not free a slot that a *different*, healthy run
    /// now holds. `ServerRuntimeForceClearTests.forceClearTokenGuardProtectsTheNextRun`
    /// pins exactly that.
    private func finishRun(_ sessionID: String, token: Int) {
        guard let session = sessions[sessionID], session.token == token else { return }
        session.runTask = nil
        session.runSink = nil
        // Cleared beside `runTask`, so `status` can never report `running: false`
        // next to a stale start time a client would render as "running for 14m".
        session.runStartedAt = nil
    }

    /// Cancel a running turn. The run settles cooperatively and clears its own slot.
    /// A run suspended on a permission prompt is NOT resumed by cancelling its task,
    /// so drain any pending prompts as rejects (else the tool fiber leaks forever).
    /// - Returns: whether a run was actually in flight. A client uses this to tell
    ///   "aborted" from "there was nothing to abort" — the latter means its own view
    ///   of the run state is stale, which it can then self-correct rather than leave
    ///   the user pressing a key that appears to do nothing.
    @discardableResult
    public func abort(sessionID: String) throws -> Bool {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let wasRunning = session.runTask != nil
        session.runTask?.cancel()
        drainPending(session, reason: "The tool call was aborted.")
        return wasRunning
    }

    /// Free the run slot **unconditionally**, whatever the run is doing.
    ///
    /// ``abort(sessionID:)`` only *cancels*: it never nils `runTask`, so clearing
    /// the slot depends entirely on the run reaching ``finishRun(_:token:)``. A run
    /// parked on something that cannot observe cancellation — an uncancellable tool,
    /// a stalled-but-open socket before the transport's idle guard existed — holds
    /// the slot for the life of the process, and every later prompt on that session
    /// 409s. That is the "I had to make a new session" bug. This is the lever that
    /// gets the session back without one.
    ///
    /// The `SessionState` is *replaced* rather than patched, because
    /// ``DoMoHarness/AgentHarness/run(prompt:attachments:sink:)`` guards on its own
    /// `isRunning` flag and clears it only in its own `defer`: a wedged run leaves
    /// that flag set forever, so reusing the harness would make the very next prompt
    /// fail with "already running a turn" and the wedge would simply move. Re-opening
    /// from the session file re-derives the leaf and every persisted message, so the
    /// only thing lost is the un-persisted tail of a run that was already dead.
    ///
    /// The session's ``BroadcastEventSink`` is carried across the replacement, so
    /// every attached SSE subscriber survives — the same care `createSession(resume:)`
    /// takes for a live session — and the new state's `token` makes the existing
    /// `finishRun` guard no-op the doomed run's completion hop if it ever settles.
    ///
    /// Because the abandoned run is still alive, two things it shares with the
    /// session have to be taken away from it:
    ///
    /// - **The stream.** Its ``RunSink`` is detached here, so nothing it emits when
    ///   it finally settles — least of all a terminal `agent_end` — reaches the
    ///   subscribers a *different* run is now feeding.
    /// - **The transcript.** Its ``DoMoHarness/SessionPersistenceSink`` still writes
    ///   to the same JSONL file, and the file's leaf is "last entry wins", so a late
    ///   append moves the file leaf onto the dead branch. Every live read therefore
    ///   walks back from the *live harness's* tip instead — see ``messages(sessionID:)``
    ///   — and the replacement harness below is opened **pinned to that same live
    ///   tip**, never to the file's. Both halves are required: reading around the
    ///   file leaf achieves nothing if this method re-derives one. A press of this
    ///   lever after the abandoned run has settled would otherwise re-anchor the
    ///   session onto the dead branch, and because every later turn is then appended
    ///   as a child of it, the recovered turn leaves the model's *context* and not
    ///   merely the rendering. It is also why nothing is replaced when nothing was
    ///   held (below): a press on an idle session was enough to do it, and this is
    ///   documented as a safe thing to do.
    ///
    ///   Two residuals, both stated plainly because the first version of this
    ///   comment claimed a coverage it did not have:
    ///
    ///   1. A genuinely **cold** re-open — a later process, where the live tip died
    ///      with the one that held it and the file is all there is. Distinguishing
    ///      the abandoned branch there is a session-format change. The recovered
    ///      turn is still on disk and reachable via ``children(sessionID:parent:)``,
    ///      not lost.
    ///   2. The live tip is read immediately before the re-open, which parses the
    ///      whole file off-actor; a doomed run that persists a message *during* that
    ///      parse leaves it off the branch this clear pins. That tail belongs to the
    ///      run being abandoned, which is the tail this lever exists to walk away
    ///      from, and closing the window exactly would need the harness to be able
    ///      to stop writing on command — which is precisely what a wedged run
    ///      cannot be made to do.
    ///
    /// It is **atomic**: the replacement harness is opened before anything is
    /// cancelled or drained, so a failure to re-open the session file leaves the
    /// session exactly as it was and the call can simply be retried. Half-clearing
    /// a session — cancelled and drained but still holding its slot on a harness
    /// whose `isRunning` is stuck — would be strictly worse than not trying.
    ///
    /// It is also safely **repeatable and concurrent**: a caller whose session was
    /// replaced while it was opening the file (a double-press on the diagnostics
    /// panel's force-clear row) reports "nothing held" rather than throwing
    /// `sessionNotFound` for a session that is plainly right there.
    ///
    /// - Returns: whether anything was actually holding the session.
    @discardableResult
    public func forceClearRun(sessionID: String) async throws -> Bool {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        // Read synchronously, before the first suspension, so "was anything held"
        // cannot be answered from a stale snapshot.
        guard session.runTask != nil || !session.pending.isEmpty else {
            // Nothing to free. Replacing the state anyway is not harmlessly wasted
            // work: rebuilding a harness means re-opening the file, and an earlier
            // force-clear's abandoned run may since have moved the file's leaf onto
            // its dead branch — so a press on an *idle* session was enough to
            // re-anchor the live session there for good. Say nothing was held, touch
            // nothing.
            //
            // The terminal frame is still sent: a client only presses this because
            // it believes a run is in flight, and its run state is edge-triggered,
            // so the frame is what un-pins the spinner it is sitting on.
            session.sink.broadcast(.agentEnd(reason: "aborted"))
            return false
        }
        // Both reads on the SAME harness object, so a replacement landing between
        // them cannot pair one state's path with another's tip.
        let harness = session.harness
        let path = await harness.sessionFilePath
        // The branch this session is actually on. The doomed run keeps its own
        // persistence sink over `path`, and the file's leaf is "last entry wins", so
        // the file is not an authority on the live branch — this harness is.
        let liveLeaf = await harness.currentLeafID
        // Opened FIRST, while nothing has been mutated yet — and OFF this actor,
        // because it parses the whole session file and this lever is pulled exactly
        // when the runtime is already unhealthy and every other session's calls are
        // the last thing that should queue behind it.
        //
        // `leaf:` refuses a tip that is not in the file rather than falling back to
        // the file's own, so the replacement cannot silently land on another branch;
        // a refusal leaves the session untouched and the call retryable, which is the
        // same stance as any other failure to re-open.
        let fresh = try await Self.reopen(
            path: path,
            configuration: harnessConfiguration(sessionID: sessionID),
            leaf: liveLeaf
        )
        // Re-check after the suspensions above: a concurrent shutdown or a
        // concurrent force-clear must win rather than be clobbered by a state built
        // from a stale snapshot. `fresh` is simply dropped in that case — nothing
        // has been mutated yet, which is the point of opening first.
        guard let current = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard current === session else { return false }

        // Silence the doomed run BEFORE the swap, so there is no window in which it
        // can emit into a sink the replacement state already owns.
        session.runSink?.detach()
        session.runTask?.cancel()
        drainPending(session, reason: "The run was cleared at the client's request.")
        sessions[sessionID] = makeState(harness: fresh, sink: session.sink)
        // Terminal frame for anyone still attached: the client's run state is
        // edge-triggered, so without this it stays pinned on "thinking…". Sent on
        // the raw sink — this frame is the runtime's, not the abandoned run's.
        session.sink.broadcast(.agentEnd(reason: "aborted"))
        return true
    }

    /// The server's authoritative view of one session — see ``SessionStatus``.
    public func status(sessionID: String) throws -> SessionStatus {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        return SessionStatus(
            sessionID: sessionID,
            running: session.runTask != nil,
            // Sorted so the projection is stable across calls; the pending map is
            // a dictionary and its iteration order is not.
            pendingPermissionIDs: session.pending.keys.sorted(),
            subscribers: session.sink.subscriberCount,
            runStartedAt: session.runStartedAt.map(Self.iso8601)
        )
    }

    /// Matches `JSONLSessionStore.iso8601`, which is internal to DoMoHarness.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Resume every pending prompt on `session` with a reject, and tell subscribers to
    /// dismiss each modal. Idempotent (empties the map).
    private func drainPending(_ session: SessionState, reason: String) {
        let approvals = session.pending
        session.pending.removeAll()
        for (id, approval) in approvals {
            approval.continuation.resume(returning: .reject(message: reason))
            session.sink.broadcast(.permissionResolved(id: id))
        }
    }

    /// Whether a turn is currently in flight for `sessionID`.
    ///
    /// The runtime is the only authority on this — the client's copy is reset on every
    /// session selection — so a client attaching mid-turn asks rather than assumes.
    /// An unknown session is not running.
    public func isRunning(sessionID: String) -> Bool {
        sessions[sessionID]?.runTask != nil
    }

    /// The broadcast sink for a live session, for the SSE handler to subscribe to.
    public func sink(for sessionID: String) throws -> BroadcastEventSink {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        return session.sink
    }

    // MARK: Reads

    // Every read below parses whole JSONL files. That work used to run **while
    // holding this actor**, so a large session stalled `startRun`, `abort`,
    // `resolvePermission` and the `isRunning` read that produces the SSE
    // `connected(running:)` frame for as long as the parse took — seconds, on a
    // long transcript — which both hurt latency and widened every run-state race.
    // The resolution stays on the actor (it reads `sessions`); the parsing hops
    // off through the `@concurrent` helpers.
    //
    // `@concurrent` is load-bearing, not decoration: under
    // NonisolatedNonsendingByDefault an unmarked `async func` runs on the
    // CALLER's actor, which here is this one — i.e. exactly the bug being fixed.

    public func listSessions() async throws -> [SessionSummary] {
        try await Self.loadListing(cwd: config.cwd, sessionDirectory: config.sessionDirectory)
    }

    /// The linear root-to-leaf message path of a session — what a client renders
    /// as the transcript. Reads from disk, so it works for a session that is live
    /// or one that only exists as a file.
    ///
    /// For a **live** session the walk starts from the harness's own tip, not from
    /// the file's last-written entry. Those are normally the same entry, and were
    /// assumed to be until ``forceClearRun(sessionID:)`` existed: the run it
    /// abandons keeps its own persistence sink over the same file, so when it
    /// finally settles its late append becomes the file's leaf and a file-leaf walk
    /// returns the **dead** branch — the recovered prompt and the model's answer to
    /// it simply disappear from the transcript. The live harness is the authority on
    /// which branch this session is actually on; the file is only the authority on
    /// what is on it.
    public func messages(sessionID: String) async throws -> [Message] {
        switch try await readLocation(sessionID) {
        case .live(let path, let tip):
            // An empty tip is an empty branch, not "ask the file": the harness will
            // append its next entry as a root, so answering with whatever branch the
            // file happens to end on would render a conversation this session is not
            // on and is not about to continue.
            guard let tip else { return [] }
            return try await Self.loadMessages(at: path, from: tip)
        case .file(let path):
            return try await Self.loadMessages(at: path, from: nil)
        }
    }

    /// The direct children of a node (or of the tree roots when `parent` is nil),
    /// in chronological order — the branch-navigation primitive.
    ///
    /// Deliberately NOT leaf-relative: `SessionTree.children(of:)` filters entries
    /// by `parentId` and never consults the leaf, so the force-clear hazard
    /// ``messages(sessionID:)`` guards against does not exist here. Showing *both*
    /// children of the fork point is the correct answer for branch navigation — it
    /// is how a client reaches the abandoned run's tail at all.
    public func children(sessionID: String, parent: String?) async throws -> [SessionTreeEntry] {
        try await Self.loadChildren(at: try await sessionPath(sessionID), parent: parent)
    }

    /// Which file to read, and on whose authority the tip is chosen.
    ///
    /// Two cases rather than one optional tip, because `nil` would have to mean two
    /// different things — "this live branch is empty" and "nobody is live, so use
    /// the file's leaf" — and the difference is exactly what the force-clear hazard
    /// turns on.
    private enum ReadLocation {
        /// A live session: walk from the harness's own tip. `tip == nil` is an empty
        /// branch, not an invitation to consult the file.
        case live(path: FilePath, tip: String?)
        /// A session that is only a file. Its own leaf is the only answer there is.
        case file(path: FilePath)
    }

    private func readLocation(_ id: String) async throws -> ReadLocation {
        guard let session = sessions[id] else {
            return .file(path: try await Self.locate(
                id: id,
                cwd: config.cwd,
                sessionDirectory: config.sessionDirectory
            ))
        }
        // Both reads on the SAME harness object, so a replacement landing between
        // them cannot pair one state's path with another's leaf.
        let harness = session.harness
        return .live(path: await harness.sessionFilePath, tip: await harness.currentLeafID)
    }

    @concurrent
    private static func loadMessages(at path: FilePath, from leaf: String?) async throws -> [Message] {
        let tree = try SessionTree.load(from: JSONLSessionStore(path: path))
        // `branch(from:)` throws on a tip that is not in the file rather than
        // silently falling back to the file's leaf: falling back is exactly the
        // behaviour whose loss of the recovered turn this parameter exists to
        // prevent, and a refusal is the store's own stance on a broken chain.
        return try tree.branch(from: leaf).compactMap { entry in
            if case .message(let message) = entry.payload { return message }
            return nil
        }
    }

    /// Re-open a session file off this actor. `@concurrent` is load-bearing: an
    /// unmarked `async func` would run on the caller's actor — this one — which is
    /// the whole thing being avoided.
    @concurrent
    private static func reopen(
        path: FilePath,
        configuration: AgentHarness.Configuration
    ) async throws -> AgentHarness {
        try AgentHarness.open(path: path, configuration: configuration)
    }

    /// Re-open a session file off this actor, continuing from `leaf` rather than
    /// from the file's last entry — see ``forceClearRun(sessionID:)``. A separate
    /// entry point rather than an optional parameter on the one above, so "which
    /// tip" is always a decision a caller made rather than a default it inherited.
    @concurrent
    private static func reopen(
        path: FilePath,
        configuration: AgentHarness.Configuration,
        leaf: String?
    ) async throws -> AgentHarness {
        try AgentHarness.open(path: path, configuration: configuration, leaf: leaf)
    }

    /// Read a session file's header id off this actor.
    @concurrent
    private static func readSessionID(at path: FilePath) async throws -> String {
        try JSONLSessionStore(path: path).readHeader().id
    }

    @concurrent
    private static func loadChildren(at path: FilePath, parent: String?) async throws -> [SessionTreeEntry] {
        let tree = try SessionTree.load(from: JSONLSessionStore(path: path))
        return tree.children(of: parent)
    }

    @concurrent
    private static func loadListing(cwd: String, sessionDirectory: FilePath) async throws -> [SessionSummary] {
        try JSONLSessionStore.list(cwd: cwd, sessionDirectory: sessionDirectory).map {
            SessionSummary(id: $0.header.id, path: $0.path.string, cwd: $0.header.cwd, timestamp: $0.header.timestamp)
        }
    }

    /// The on-disk path of a session that is only a file, resolved off the actor —
    /// `JSONLSessionStore.list` scans and header-parses the whole directory.
    @concurrent
    private static func locate(id: String, cwd: String, sessionDirectory: FilePath) async throws -> FilePath {
        let listings = (try? JSONLSessionStore.list(cwd: cwd, sessionDirectory: sessionDirectory)) ?? []
        guard let match = listings.first(where: { $0.header.id == id }) else {
            throw ServerRuntimeError.sessionNotFound
        }
        return match.path
    }

    // MARK: Shutdown

    /// Cancel every run and finish every open SSE stream, so a graceful shutdown
    /// does not leave clients hanging.
    public func shutdown() {
        for session in sessions.values {
            session.runTask?.cancel()
            drainPending(session, reason: "The server is shutting down.")
            session.sink.closeAll()
        }
        sessions.removeAll()
    }

    // MARK: Path resolution

    private func sessionPath(_ id: String) async throws -> FilePath {
        if let session = sessions[id] { return await session.harness.sessionFilePath }
        return try await Self.locate(id: id, cwd: config.cwd, sessionDirectory: config.sessionDirectory)
    }

    /// Resolve `resume` strictly as a session id within this cwd's session
    /// directory — never as a raw filesystem path. A client is loopback-and-token
    /// trusted, but treating the value as a path would let it open and *append to*
    /// any JSONL file the process can read, outside the session scope; keeping it an
    /// id keeps a session contained to the directory `listSessions` exposes.
    private func resolveResume(_ value: String) async throws -> FilePath {
        try await Self.locate(id: value, cwd: config.cwd, sessionDirectory: config.sessionDirectory)
    }
}
