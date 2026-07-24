// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
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
public actor ServerRuntime {

    /// The shared runtime ingredients, assembled once by the `serve` command and
    /// reused to build a fresh ``AgentHarness/Configuration`` per session.
    public struct Config: Sendable {
        public var systemPrompt: String
        public var tools: [any AgentTool]
        public var model: String
        public var streamFn: AgentStreamFn
        public var toolExecution: ToolExecutionMode
        public var maxTurns: Int?
        public var sessionDirectory: FilePath
        public var cwd: String

        public init(
            systemPrompt: String,
            tools: [any AgentTool],
            model: String,
            streamFn: @escaping AgentStreamFn,
            toolExecution: ToolExecutionMode = .sequential,
            maxTurns: Int? = nil,
            sessionDirectory: FilePath,
            cwd: String
        ) {
            self.systemPrompt = systemPrompt
            self.tools = tools
            self.model = model
            self.streamFn = streamFn
            self.toolExecution = toolExecution
            self.maxTurns = maxTurns
            self.sessionDirectory = sessionDirectory
            self.cwd = cwd
        }
    }

    /// One live session's mutable state. A reference type held only inside the
    /// actor, so its `runTask` mutation is serialized by the actor, not shared.
    private final class SessionState {
        let harness: AgentHarness
        let sink: BroadcastEventSink
        var runTask: Task<Void, Never>?

        init(harness: AgentHarness, sink: BroadcastEventSink) {
            self.harness = harness
            self.sink = sink
        }
    }

    private let config: Config
    private var sessions: [String: SessionState] = [:]

    public init(config: Config) {
        self.config = config
    }

    private func harnessConfiguration() -> AgentHarness.Configuration {
        AgentHarness.Configuration(
            systemPrompt: config.systemPrompt,
            tools: config.tools,
            model: config.model,
            streamFn: config.streamFn,
            toolExecution: config.toolExecution,
            maxTurns: config.maxTurns
        )
    }

    // MARK: Lifecycle

    /// Create a fresh session, or open an existing one when `resume` names a
    /// session file path or a session id.
    public func createSession(resume: String? = nil) async throws -> SessionRef {
        let configuration = harnessConfiguration()
        let harness: AgentHarness
        let id: String
        if let resume {
            let path = try resolveResume(resume)
            harness = try AgentHarness.open(path: path, configuration: configuration)
            id = try JSONLSessionStore(path: path).readHeader().id
        } else {
            id = UUIDv7.generate().description
            harness = try AgentHarness.start(
                cwd: config.cwd,
                sessionDirectory: config.sessionDirectory,
                configuration: configuration,
                sessionID: id
            )
        }
        let path = await harness.sessionFilePath
        sessions[id] = SessionState(harness: harness, sink: BroadcastEventSink())
        return SessionRef(id: id, path: path.string)
    }

    /// Fork a live session into a new file, leaving the original untouched.
    public func fork(sessionID: String) async throws -> SessionRef {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let forked = try await session.harness.fork(sessionDirectory: config.sessionDirectory)
        let path = await forked.sessionFilePath
        let id = try JSONLSessionStore(path: path).readHeader().id
        sessions[id] = SessionState(harness: forked, sink: BroadcastEventSink())
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
        session.runTask = Task { [weak self] in
            // A cancellation surfaces as an aborted run; any other error already
            // reached the client through the event stream, so there is nothing to
            // do here but let the run settle and free the slot.
            _ = try? await harness.run(prompt: prompt, attachments: attachments, sink: sink)
            await self?.finishRun(sessionID)
        }
    }

    private func finishRun(_ sessionID: String) {
        sessions[sessionID]?.runTask = nil
    }

    /// Cancel a running turn. The run settles cooperatively and clears its own slot.
    public func abort(sessionID: String) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        session.runTask?.cancel()
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

    private func resolveResume(_ value: String) throws -> FilePath {
        if FileManager.default.fileExists(atPath: value) { return FilePath(value) }
        let listings = (try? JSONLSessionStore.list(cwd: config.cwd, sessionDirectory: config.sessionDirectory)) ?? []
        guard let match = listings.first(where: { $0.header.id == value }) else {
            throw ServerRuntimeError.sessionNotFound
        }
        return match.path
    }
}
