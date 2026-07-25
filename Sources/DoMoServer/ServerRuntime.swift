// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoPermissions
import Foundation
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
            let path = try resolveResume(resume)
            let resumedID = try JSONLSessionStore(path: path).readHeader().id
            // Already live? Return it rather than standing up a second harness over
            // the same file — that would orphan the running task and leave the
            // existing SSE subscribers attached to a sink no run feeds.
            if let existing = sessions[resumedID] {
                return SessionRef(id: resumedID, path: await existing.harness.sessionFilePath.string)
            }
            harness = try AgentHarness.open(path: path, configuration: harnessConfiguration(sessionID: resumedID))
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
        sessions[id] = makeState(harness: harness, sink: BroadcastEventSink())
        return SessionRef(id: id, path: path.string)
    }

    /// Fork a live session into a new file, leaving the original untouched.
    public func fork(sessionID: String) async throws -> SessionRef {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let forked = try await session.harness.fork(sessionDirectory: config.sessionDirectory)
        let path = await forked.sessionFilePath
        let id = try JSONLSessionStore(path: path).readHeader().id
        // `fork` reuses the PARENT's configuration, whose permission hook is bound to
        // the parent's sessionID — a prompt from the forked run would route to the
        // wrong session and hang. Re-open the forked file with a correctly-bound
        // config (only when gating is on; ungated forks keep the cheap path).
        let harness: AgentHarness
        if config.permissions != nil {
            harness = try AgentHarness.open(path: path, configuration: harnessConfiguration(sessionID: id))
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
        let sink = session.sink
        let token = session.token
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
    private func finishRun(_ sessionID: String, token: Int) {
        guard sessions[sessionID]?.token == token else { return }
        sessions[sessionID]?.runTask = nil
    }

    /// Cancel a running turn. The run settles cooperatively and clears its own slot.
    /// A run suspended on a permission prompt is NOT resumed by cancelling its task,
    /// so drain any pending prompts as rejects (else the tool fiber leaks forever).
    public func abort(sessionID: String) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        session.runTask?.cancel()
        drainPending(session, reason: "The tool call was aborted.")
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

    /// The broadcast sink for a live session, for the SSE handler to subscribe to.
    public func sink(for sessionID: String) throws -> BroadcastEventSink {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        return session.sink
    }

    // MARK: Reads

    public func listSessions() throws -> [SessionSummary] {
        let listings = try JSONLSessionStore.list(cwd: config.cwd, sessionDirectory: config.sessionDirectory)
        return listings.map {
            SessionSummary(id: $0.header.id, path: $0.path.string, cwd: $0.header.cwd, timestamp: $0.header.timestamp)
        }
    }

    /// The linear root-to-leaf message path of a session — what a client renders
    /// as the transcript. Reads from disk, so it works for a session that is live
    /// or one that only exists as a file.
    public func messages(sessionID: String) async throws -> [Message] {
        let tree = try SessionTree.load(from: JSONLSessionStore(path: try await sessionPath(sessionID)))
        return try tree.branch().compactMap { entry in
            if case .message(let message) = entry.payload { return message }
            return nil
        }
    }

    /// The direct children of a node (or of the tree roots when `parent` is nil),
    /// in chronological order — the branch-navigation primitive.
    public func children(sessionID: String, parent: String?) async throws -> [SessionTreeEntry] {
        let tree = try SessionTree.load(from: JSONLSessionStore(path: try await sessionPath(sessionID)))
        return tree.children(of: parent)
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
        let listings = (try? JSONLSessionStore.list(cwd: config.cwd, sessionDirectory: config.sessionDirectory)) ?? []
        guard let match = listings.first(where: { $0.header.id == id }) else {
            throw ServerRuntimeError.sessionNotFound
        }
        return match.path
    }

    /// Resolve `resume` strictly as a session id within this cwd's session
    /// directory — never as a raw filesystem path. A client is loopback-and-token
    /// trusted, but treating the value as a path would let it open and *append to*
    /// any JSONL file the process can read, outside the session scope; keeping it an
    /// id keeps a session contained to the directory `listSessions` exposes.
    private func resolveResume(_ value: String) throws -> FilePath {
        let listings = (try? JSONLSessionStore.list(cwd: config.cwd, sessionDirectory: config.sessionDirectory)) ?? []
        guard let match = listings.first(where: { $0.header.id == value }) else {
            throw ServerRuntimeError.sessionNotFound
        }
        return match.path
    }
}
