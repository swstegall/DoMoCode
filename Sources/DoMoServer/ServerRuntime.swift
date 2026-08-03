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
    /// A steering request arrived after the active run had already settled.
    /// The client should retry it as a normal prompt.
    case sessionNotRunning
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

/// The model-facing context and the accounting snapshot that describes it.
///
/// Unlike ``messages(sessionID:)``, which is the lossless transcript shown in a
/// client's history pane, `messages` here has already crossed the active
/// compaction boundary and the context-output projection. It is therefore the
/// exact message list the next model request would start with, including pruning
/// and spill markers.
public struct ContextSnapshot: Sendable, Codable {
    public var messages: [Message]
    public var accounting: SessionAccounting?

    public init(messages: [Message], accounting: SessionAccounting?) {
        self.messages = messages
        self.accounting = accounting
    }
}

/// The result of an explicit `/compact` request.
public struct CompactionResult: Sendable, Codable, Hashable {
    public var compacted: Bool

    public init(compacted: Bool) {
        self.compacted = compacted
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
    /// Pending structured question ids, when this runtime supports the
    /// question round-trip. Optional so clients can read older servers.
    public var pendingQuestionIDs: [String]?
    public var subscribers: Int
    /// ISO8601, or nil when nothing is running. Lets a client say "running for
    /// 14m" instead of an undifferentiated spinner.
    public var runStartedAt: String?

    /// What this session has spent and how full its context is, or `nil` when the
    /// server could not work it out.
    ///
    /// Cumulative totals only. Per-*turn* numbers already reach a client without
    /// this: ``ServerEvent/messageEnd(_:)`` carries the whole ``DoMoLLM/Message``,
    /// and ``DoMoLLM/AssistantMessage`` encodes its `usage`, so a subscriber can
    /// fold turns itself. What it cannot do is recover the totals of a session it
    /// attached to halfway through — the turns it missed were never on its stream —
    /// which is why the running total is level-triggered and lives here.
    ///
    /// Optional for two independent reasons, both load-bearing. On the wire it is
    /// an **additive** field and `ServerClient.status` decodes with a plain
    /// `JSONDecoder`, so a payload from a server that predates it must still decode:
    /// an absent key means "not reported", never a decode failure that turns the
    /// diagnostic route into one more thing that is broken. In the server it is what
    /// ``ServerRuntime/status(sessionID:)`` degrades to when the session's harness
    /// cannot answer; see there for why that is deliberately not an error.
    ///
    /// A reader must not treat `nil` as zero. Zero is a claim about a session that
    /// spent nothing; `nil` says the server did not know.
    public var accounting: SessionAccounting?

    /// Messages accepted by the server but not yet delivered to the agent loop.
    /// Optional for compatibility with servers that predate Phase 9.
    public var queuedMessageCount: Int?
    /// The server's steering delivery mode, when reported.
    public var steeringMode: String?

    /// - Parameter accounting: Defaulted and **last**, so every existing
    ///   construction of this type keeps compiling untouched.
    public init(
        sessionID: String,
        running: Bool,
        pendingPermissionIDs: [String],
        subscribers: Int,
        runStartedAt: String?,
        accounting: SessionAccounting? = nil,
        queuedMessageCount: Int? = nil,
        steeringMode: String? = nil,
        pendingQuestionIDs: [String]? = nil
    ) {
        self.sessionID = sessionID
        self.running = running
        self.pendingPermissionIDs = pendingPermissionIDs
        self.pendingQuestionIDs = pendingQuestionIDs
        self.subscribers = subscribers
        self.runStartedAt = runStartedAt
        self.accounting = accounting
        self.queuedMessageCount = queuedMessageCount
        self.steeringMode = steeringMode
    }
}

/// A row in the session listing.
public struct SessionSummary: Sendable, Codable, Hashable {
    public let id: String
    public let path: String
    public let cwd: String
    public let timestamp: String
    public let name: String?
    public init(id: String, path: String, cwd: String, timestamp: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.cwd = cwd
        self.timestamp = timestamp
        self.name = name
    }
}

/// A model alias the client may select. The runtime remains the authority for
/// the stream factory; the client only needs a stable id and honest meter data.
public struct ModelOption: Sendable, Codable, Hashable {
    public let id: String
    public let provider: String
    public let contextWindow: Int?

    public init(id: String, provider: String = "litellm", contextWindow: Int? = nil) {
        self.id = id
        self.provider = provider
        self.contextWindow = contextWindow
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
        /// The loaded prompt resources. When present, the server adds matching
        /// skills to each turn and expands command templates before dispatch.
        public var promptWorkspace: PromptWorkspace?
        public var commandProcessor: PromptCommandProcessor?
        /// Resolves a command's optional model/reasoning override into the stream
        /// function that owns the concrete LLM client.
        public var commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)?
        /// The aliases exposed by the model picker. An empty list is replaced by
        /// the configured default model at runtime.
        public var modelOptions: [ModelOption]
        /// Resolves a selected alias to the concrete stream function owned by the
        /// CLI's LLM client.
        public var modelStreamFactory: (@Sendable (String) -> AgentStreamFn)?
        public var modelContextWindow: (@Sendable (String) -> Int?)?
        public var tools: [any AgentTool]
        /// Optional per-session resolver. The session id is part of the seam so
        /// tools such as `question` can route their answer to the right client.
        public var toolsForSession: (@Sendable (String, String) async -> [any AgentTool])?
        /// Resolves the current tool set before each assistant request. A server
        /// can use this to reflect MCP `tools/list_changed` without rebuilding
        /// every live session.
        public var getTools: (@Sendable (String) async -> [any AgentTool])?
        /// Rebuilds the prompt from the current tool names and user prompt.
        public var systemPromptForPromptAndTools: (@Sendable (String, [String]) -> String)?
        public var model: String
        public var streamFn: AgentStreamFn
        public var toolExecution: ToolExecutionMode
        public var maxTurns: Int?
        public var sessionDirectory: FilePath
        public var cwd: String
        public var permissions: PermissionRuntime?

        /// The model's context window in tokens, or `nil` when it is genuinely
        /// unknown — which is the default, because behind a gateway it usually is.
        ///
        /// Forwarded verbatim to ``DoMoHarness/AgentHarness/Configuration/contextWindow``
        /// and from there onto ``SessionStatus/accounting``, so a client's meter
        /// renders the server's actual answer. `nil` must reach the client as `nil`:
        /// a percentage computed against the compaction fallback would be
        /// indistinguishable on screen from one computed against a real window.
        public var contextWindow: Int?

        /// When and how aggressively the server's sessions compact.
        ///
        /// Defaulted rather than required because every existing construction of
        /// this type predates it, and because ``CompactionSettings/default`` is
        /// exactly what the harness used to apply on its own.
        public var compaction: CompactionSettings

        /// The summarization call compaction uses. `nil` keeps the harness's own
        /// default — a one-shot request through ``streamFn`` — so a server that
        /// configures nothing behaves byte-for-byte as it did.
        public var summarizer: Summarizer?

        /// How prompts typed during a run are delivered at turn boundaries.
        /// One-at-a-time is deliberately the safe default for interactive use.
        public var steeringMode: QueueDeliveryMode

        /// Optional hard USD ceiling for each assistant run.
        public var maxCostPerRun: Decimal?
        /// The committed HEAD recorded for each new session, when the serving
        /// process started inside a repository with a commit.
        public var sessionStartHead: String?
        /// Late-bound bridge used by a tool context to suspend the owning
        /// session on a structured question.
        public var questionBroker: QuestionBroker?

        /// - Parameters:
        ///   - contextWindow: See ``Config/contextWindow``.
        ///   - compaction: See ``Config/compaction``.
        ///   - summarizer: See ``Config/summarizer``.
        ///
        /// The three above are defaulted and **last**. A dozen files across the CLI
        /// and the test suites construct this initializer, so a non-defaulted
        /// parameter — or a new one inserted in the middle — is a build failure in
        /// every one of them.
        public init(
            systemPrompt: String,
            tools: [any AgentTool],
            model: String,
            streamFn: @escaping AgentStreamFn,
            toolExecution: ToolExecutionMode = .parallel,
            maxTurns: Int? = nil,
            sessionDirectory: FilePath,
            cwd: String,
            permissions: PermissionRuntime? = nil,
            contextWindow: Int? = nil,
            compaction: CompactionSettings = .default,
            summarizer: Summarizer? = nil,
            promptWorkspace: PromptWorkspace? = nil,
            commandProcessor: PromptCommandProcessor? = nil,
            commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)? = nil,
            modelOptions: [ModelOption] = [],
            modelStreamFactory: (@Sendable (String) -> AgentStreamFn)? = nil,
            modelContextWindow: (@Sendable (String) -> Int?)? = nil,
            steeringMode: QueueDeliveryMode = .oneAtATime,
            maxCostPerRun: Decimal? = nil,
            getTools: (@Sendable (String) async -> [any AgentTool])? = nil,
            systemPromptForPromptAndTools: (@Sendable (String, [String]) -> String)? = nil,
            toolsForSession: (@Sendable (String, String) async -> [any AgentTool])? = nil,
            questionBroker: QuestionBroker? = nil,
            sessionStartHead: String? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.promptWorkspace = promptWorkspace
            self.commandProcessor = commandProcessor
            self.commandStreamFactory = commandStreamFactory
            self.modelOptions = modelOptions
            self.modelStreamFactory = modelStreamFactory
            self.modelContextWindow = modelContextWindow
            self.tools = tools
            self.toolsForSession = toolsForSession
            self.getTools = getTools
            self.systemPromptForPromptAndTools = systemPromptForPromptAndTools
            self.model = model
            self.streamFn = streamFn
            self.toolExecution = toolExecution
            self.maxTurns = maxTurns
            self.sessionDirectory = sessionDirectory
            self.cwd = cwd
            self.permissions = permissions
            self.contextWindow = contextWindow
            self.compaction = compaction
            self.summarizer = summarizer
            self.steeringMode = steeringMode
            self.maxCostPerRun = maxCostPerRun
            self.sessionStartHead = sessionStartHead
            self.questionBroker = questionBroker
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
        let steeringBox: SteeringBox
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
        /// Structured questions awaiting an answer from the client.
        var pendingQuestions: [String: PendingQuestion] = [:]

        init(token: Int, harness: AgentHarness, sink: BroadcastEventSink, steeringBox: SteeringBox) {
            self.token = token
            self.harness = harness
            self.sink = sink
            self.steeringBox = steeringBox
        }
    }

    /// A suspended permission prompt: the original request (so a re-attaching client
    /// can be told about it) and the continuation to resume with the answer.
    private struct PendingApproval {
        let request: PermissionRequest
        let continuation: CheckedContinuation<PermissionReply, Never>
    }

    private struct PendingQuestion {
        let sessionID: String
        let questions: [ServerQuestionPrompt]
        let continuation: CheckedContinuation<[ServerQuestionAnswer]?, Never>
    }

    private let config: Config
    private var sessions: [String: SessionState] = [:]
    private var nextToken = 0

    public init(config: Config) {
        self.config = config
        config.questionBroker?.setHandler { [weak self] sessionID, questions in
            guard let self else { return nil }
            return await self.awaitQuestion(sessionID: sessionID, questions: questions)
        }
    }

    /// The one command registry shared by every client surface. Templates are
    /// intentionally absent from the descriptor wire value; the server remains
    /// the authority that expands them.
    public func commands() -> CommandRegistry {
        config.promptWorkspace?.commands ?? .builtIn
    }

    public func models() -> [ModelOption] {
        if config.modelOptions.isEmpty {
            return [ModelOption(id: config.model, contextWindow: config.contextWindow)]
        }
        return config.modelOptions
    }

    private func makeState(
        harness: AgentHarness,
        sink: BroadcastEventSink,
        steeringBox: SteeringBox
    ) -> SessionState {
        let token = nextToken
        nextToken += 1
        return SessionState(token: token, harness: harness, sink: sink, steeringBox: steeringBox)
    }

    private func makeSteeringBox() -> SteeringBox {
        SteeringBox(mode: config.steeringMode)
    }

    /// Build the harness configuration for one session, wiring the permission gate
    /// bound to THIS session's id (so a prompt routes its answer back to this
    /// session's pending map). The prompter is `self.awaitPermission` — the runtime
    /// that owns the pending map already exists, so no `PrompterBox` is needed.
    private func harnessConfiguration(
        sessionID: String,
        steeringBox: SteeringBox
    ) -> AgentHarness.Configuration {
        let steeringReader: @Sendable () async -> [Message] = { [weak self, steeringBox] in
            guard let self else { return steeringBox.drain() }
            return await self.drainSteering(sessionID: sessionID, box: steeringBox)
        }
        var beforeToolCall: BeforeToolCallHook?
        var onNoProgress: (@Sendable (TurnResult) async -> Bool)? = nil
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
            onNoProgress = doomLoopHook(engine: engine, sessionID: sessionID)
        }
        var systemPromptForPrompt: (@Sendable (String) -> String)?
        if let workspace = config.promptWorkspace {
            systemPromptForPrompt = { prompt in workspace.systemPrompt(for: prompt) }
        }
        let toolsForTurn: (@Sendable (String) async -> [any AgentTool])?
        if let resolver = config.toolsForSession {
            toolsForTurn = { model in await resolver(sessionID, model) }
        } else {
            toolsForTurn = config.getTools
        }
        return AgentHarness.Configuration(
            systemPrompt: config.promptWorkspace?.baseSystemPrompt ?? config.systemPrompt,
            systemPromptForPrompt: systemPromptForPrompt,
            tools: config.tools,
            getTools: toolsForTurn,
            systemPromptForPromptAndTools: config.systemPromptForPromptAndTools,
            model: config.model,
            streamFn: config.streamFn,
            streamFnForModel: config.modelStreamFactory,
            contextWindowForModel: config.modelContextWindow,
            // The three below are the whole reason `Config` carries them: a value
            // that stops here is a knob a user can set and nothing reads. The
            // harness clamps `compaction` against `contextWindow` in its own
            // initializer, so nothing is decided here beyond forwarding.
            summarizer: config.summarizer,
            toolExecution: config.toolExecution,
            maxTurns: config.maxTurns,
            compaction: config.compaction,
            contextWindow: config.contextWindow,
            getSteeringMessages: steeringReader,
            steeringBox: steeringBox,
            beforeToolCall: beforeToolCall,
            onNoProgress: onNoProgress,
            maxCostPerRun: config.maxCostPerRun,
            sessionStartHead: config.sessionStartHead
        )
    }

    /// Drain a session's box and publish the level-triggered count immediately.
    /// The identity check prevents an abandoned harness from reporting the queue
    /// state of a replacement session after force-clear or fork.
    private func drainSteering(sessionID: String, box: SteeringBox) -> [Message] {
        let messages = box.drain()
        guard !messages.isEmpty,
              let session = sessions[sessionID], session.steeringBox === box
        else { return messages }
        session.sink.broadcast(.queueUpdate(count: box.count, mode: box.mode.rawValue))
        return messages
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

    // MARK: Structured question round-trip

    /// Suspend the current tool call until the owning client answers the
    /// structured question batch. The broker keeps the DoMoTools dependency at
    /// the CLI edge while the runtime speaks only its wire DTOs.
    private func awaitQuestion(
        sessionID: String,
        questions: [ServerQuestionPrompt]
    ) async -> [ServerQuestionAnswer]? {
        guard !questions.isEmpty, !Task.isCancelled, let session = sessions[sessionID] else {
            return nil
        }
        let requestID = UUIDv7.generate().description
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<[ServerQuestionAnswer]?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                session.pendingQuestions[requestID] = PendingQuestion(
                    sessionID: sessionID,
                    questions: questions,
                    continuation: continuation
                )
                session.sink.broadcast(
                    .questionRequest(id: requestID, sessionID: sessionID, questions: questions)
                )
            }
        }, onCancel: {
            Task { [weak self] in
                try? await self?.resolveQuestion(sessionID: sessionID, requestID: requestID, answers: nil)
            }
        })
    }

    /// Resolve a pending structured question. A missing request is a harmless
    /// duplicate or a cancellation race, matching permission resolution.
    public func resolveQuestion(
        sessionID: String,
        requestID: String,
        answers: [ServerQuestionAnswer]?
    ) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard let question = session.pendingQuestions.removeValue(forKey: requestID) else { return }
        question.continuation.resume(returning: answers)
        session.sink.broadcast(.questionResolved(id: requestID))
    }

    /// The still-open structured questions for reconnect reconciliation.
    public func pendingQuestions(sessionID: String) throws -> [ServerEvent] {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        return session.pendingQuestions.map { id, question in
            .questionRequest(id: id, sessionID: question.sessionID, questions: question.questions)
        }
    }

    // MARK: Lifecycle

    /// Create a fresh session, or open an existing one when `resume` names a
    /// session file path or a session id.
    public func createSession(resume: String? = nil) async throws -> SessionRef {
        // The session id must be known BEFORE building the harness config, so the
        // permission hook can be bound to it (a prompt routes its answer by sessionID).
        let harness: AgentHarness
        let steeringBox: SteeringBox
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
            steeringBox = makeSteeringBox()
            harness = try await Self.reopen(
                path: path,
                configuration: harnessConfiguration(sessionID: resumedID, steeringBox: steeringBox)
            )
            id = resumedID
        } else {
            id = UUIDv7.generate().description
            steeringBox = makeSteeringBox()
            harness = try AgentHarness.start(
                cwd: config.cwd,
                sessionDirectory: config.sessionDirectory,
                configuration: harnessConfiguration(sessionID: id, steeringBox: steeringBox),
                sessionID: id
            )
        }
        let path = await harness.sessionFilePath
        // Re-check after every suspension above, for the same reason as the first
        // check: a concurrent resume of the same id must not replace a live session
        // and strand its run and its subscribers. `harness` is dropped unused.
        if sessions[id] != nil { return SessionRef(id: id, path: path.string) }
        sessions[id] = makeState(harness: harness, sink: BroadcastEventSink(), steeringBox: steeringBox)
        return SessionRef(id: id, path: path.string)
    }

    /// Fork a live session into a new file, leaving the original untouched.
    public func fork(sessionID: String) async throws -> SessionRef {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let forked = try await session.harness.fork(sessionDirectory: config.sessionDirectory)
        let path = await forked.sessionFilePath
        let id = try await Self.readSessionID(at: path)
        // `fork` reuses the PARENT's configuration, whose permission hook and
        // steering box are both bound to the parent. Re-open the forked file with
        // fresh per-session state even when permissions are disabled.
        let steeringBox = makeSteeringBox()
        let harness = try await Self.reopen(
            path: path,
            configuration: harnessConfiguration(sessionID: id, steeringBox: steeringBox)
        )
        sessions[id] = makeState(harness: harness, sink: BroadcastEventSink(), steeringBox: steeringBox)
        return SessionRef(id: id, path: path.string)
    }

    // MARK: Runs

    /// Start a turn on a session. Returns immediately; the run advances in a
    /// retained ``Task`` whose events flow to the session's broadcast sink.
    ///
    /// Throws ``ServerRuntimeError/sessionBusy`` when the caller is trying to
    /// start a second normal run. A client that is intentionally typing while a
    /// run is active uses ``steer(sessionID:prompt:attachments:)`` instead.
    public func startRun(sessionID: String, prompt: String, attachments: [ImageBlock]) throws {
        let message = Message.user(
            UserMessage(content: [.text(prompt)] + attachments.map { .image($0) })
        )
        try startRun(
            sessionID: sessionID,
            messages: [message],
            commandPrompt: prompt,
            attachments: attachments
        )
    }

    /// Queue a prompt for the active run. The message is delivered by the harness
    /// at its next steering boundary and is acknowledged with a `queue_update` SSE
    /// frame. If the run settled in the tiny race between the client's state and
    /// this call, the client retries through the ordinary prompt route.
    public func steer(sessionID: String, prompt: String, attachments: [ImageBlock]) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask != nil else { throw ServerRuntimeError.sessionNotRunning }
        session.steeringBox.enqueue(
            .user(UserMessage(content: [.text(prompt)] + attachments.map { .image($0) }))
        )
        session.sink.broadcast(
            .queueUpdate(count: session.steeringBox.count, mode: session.steeringBox.mode.rawValue)
        )
    }

    /// Admit either a normal prompt (which still passes through the command
    /// processor) or already-queued messages promoted into the next run after a
    /// completion/steering race.
    private func startRun(
        sessionID: String,
        messages: [Message],
        commandPrompt: String?,
        attachments: [ImageBlock],
        drainSteeringBeforeFirstTurn: Bool = true
    ) throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        let harness = session.harness
        // NOT `session.sink` directly: everything this run emits goes through a gate
        // the runtime can close, so a run that ``forceClearRun(sessionID:)`` walked
        // away from cannot narrate itself into a stream a later run owns. See
        // ``RunSink``.
        let sink = RunSink(session.sink)
        let token = session.token
        let commandProcessor = config.commandProcessor
        let commandStreamFactory = config.commandStreamFactory
        let promptWorkspace = config.promptWorkspace
        let baseSystemPrompt = config.promptWorkspace?.baseSystemPrompt ?? config.systemPrompt
        session.runSink = sink
        session.runStartedAt = Date()
        session.runTask = Task { [weak self] in
            do {
                // A run the LOOP settled as `.errored` has already narrated itself:
                // ``DoMoAgent`` emits its classified failure as an `AgentEvent.notice`
                // from inside `settle`, immediately before `agent_end`, and that
                // notice is projected onto this same stream. Re-broadcasting
                // `result.failure` here would put the identical row on the screen
                // twice — the frame is not missing, only the frames for the failures
                // the loop never saw are, and those all arrive as a throw.
                if let commandPrompt {
                    let resolution: PromptCommandResolution
                    if let processor = commandProcessor {
                        resolution = try await processor.resolve(commandPrompt)
                    } else {
                        resolution = .prompt(
                            text: commandPrompt,
                            model: nil,
                            reasoningEffort: nil,
                            systemPrompt: baseSystemPrompt
                        )
                    }
                    switch resolution {
                    case .local(let action):
                        throw DoMoError(.configuration, "/\(action.rawValue) is a client-local command")
                    case .unknown(let name):
                        throw DoMoError(.configuration, "Unknown command /\(name)")
                    case .prompt(let rendered, let commandModel, let reasoningEffort, let systemPrompt):
                        var runOverride: AgentHarness.RunOverride?
                        if commandModel != nil || reasoningEffort != nil || commandStreamFactory != nil {
                            let stream = commandStreamFactory?(commandModel, reasoningEffort)
                            runOverride = AgentHarness.RunOverride(
                                model: commandModel,
                                streamFn: stream,
                                systemPrompt: systemPrompt
                            )
                        } else {
                            runOverride = AgentHarness.RunOverride(systemPrompt: systemPrompt)
                        }
                        _ = try await harness.run(
                            prompt: rendered,
                            attachments: attachments,
                            sink: sink,
                            runOverride: runOverride
                        )
                    }
                } else {
                    let promptForSystem = messages.compactMap { message -> String? in
                        guard case .user(let user) = message else { return nil }
                        return user.text
                    }.first ?? ""
                    let systemPrompt = promptWorkspace?.systemPrompt(for: promptForSystem) ?? baseSystemPrompt
                    _ = try await harness.run(
                        messages: messages,
                        sink: sink,
                        runOverride: AgentHarness.RunOverride(systemPrompt: systemPrompt),
                        drainSteeringBeforeFirstTurn: drainSteeringBeforeFirstTurn
                    )
                }
            } catch is CancellationError {
                // Aborted before the loop emitted its own close.
                sink.broadcast(.agentEnd(reason: "aborted"))
            } catch {
                // A failure before agentStart (compaction, context build) or a
                // persistence error after the loop settled would otherwise leave the
                // stream with no terminal frame. Guarantee exactly one close per
                // accepted prompt, so a subscriber never hangs.
                //
                // Say WHAT failed, and say it BEFORE the close: a client folds
                // `agent_end` into "idle", and a reason that arrives after the run is
                // already idle reads as belonging to nothing. `agent_end(reason:
                // "errored")` on its own is a three-word status line and an empty
                // pane — which is exactly the report this frame exists to answer.
                let failure = error as? DoMoError
                    ?? DoMoError(wrapping: error, as: .configuration, "The turn could not be run")
                // An interrupt drawn in red as a failure is a bug report the user then
                // files. A cancellation that did not surface as `CancellationError`
                // (a torn-down socket classified by the layer that caught it) lands
                // here, and must still close as an abort rather than an error.
                if failure.isCancellation {
                    sink.broadcast(.agentEnd(reason: "aborted"))
                } else {
                    sink.broadcast(Self.noticeEvent(failure))
                    sink.broadcast(.agentEnd(reason: "errored"))
                }
            }
            await self?.finishRun(sessionID, token: token)
        }
    }

    /// One wire notice from a classified failure the run threw.
    ///
    /// The full cause chain becomes the text, capped HERE rather than at render
    /// time: a gateway can answer with an entire HTML error page, and an
    /// uncapped chain would make the SSE frame itself the payload problem for
    /// every attached subscriber. The taxonomy rides along as
    /// ``DoMoCore/DoMoError/Kind/label`` so a client renders a headline and a
    /// recovery hint without parsing prose.
    private static func noticeEvent(_ error: DoMoError) -> ServerEvent {
        .notice(ServerNotice(
            level: .error,
            code: noticeCode(for: error.kind),
            text: DoMoError.truncating(error.description),
            kind: error.kind.label
        ))
    }

    /// Which notice family a classified failure belongs to.
    ///
    /// Read off the KIND, never off the catch site — the same rule the agent
    /// loop applies to the failures it settles, so the same 401 is filed the
    /// same way whether it arrived through the loop's own stream or was thrown
    /// out of `harness.run`'s pre-turn compaction. Filing everything that can
    /// throw here as `runtime_error` would be the easy answer and the wrong
    /// one: compaction issues a real model request, so a gateway refusal
    /// genuinely does reach this catch.
    ///
    /// Exhaustive with no `default`, so a new ``DoMoCore/DoMoError/Kind`` is a
    /// compile error here rather than a silent misfiling.
    private static func noticeCode(for kind: DoMoError.Kind) -> String {
        switch kind {
        case .transport, .authentication, .rateLimit, .quotaExhausted, .contextOverflow, .provider,
            .malformedResponse:
            return "provider_error"
        case .toolExecution, .file, .cancelled, .configuration:
            return "runtime_error"
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
        let nextMessages = session.steeringBox.drain()
        session.runTask = nil
        session.runSink = nil
        // Cleared beside `runTask`, so `status` can never report `running: false`
        // next to a stale start time a client would render as "running for 14m".
        session.runStartedAt = nil

        guard !nextMessages.isEmpty else { return }

        // A message can arrive after the loop's final steering poll but before
        // this completion hop. Promote it immediately instead of leaving an idle
        // session with an accepted-but-never-delivered queue entry. The promoted
        // run skips its initial steering poll; its first queued message is already
        // the initial prompt, and the remaining queue is consumed one boundary at
        // a time by the normal loop poll.
        session.sink.broadcast(
            .queueUpdate(count: session.steeringBox.count, mode: session.steeringBox.mode.rawValue)
        )
        do {
            try startRun(
                sessionID: sessionID,
                messages: nextMessages,
                commandPrompt: nil,
                attachments: [],
                drainSteeringBeforeFirstTurn: false
            )
        } catch {
            let failure = error as? DoMoError
                ?? DoMoError(wrapping: error, as: .configuration, "The queued turn could not be run")
            session.sink.broadcast(Self.noticeEvent(failure))
            session.sink.broadcast(.agentEnd(reason: "errored"))
        }
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
    ///   — and the replacement harness below is opened **pinned to the live branch**
    ///   (that tip, or the nearest ancestor of it the file can still resolve), never
    ///   to the file's leaf. Both halves are required: reading around the
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
    /// It is **total**: it does not refuse. Every decision this method makes about
    /// which branch to keep degrades along the live branch instead of throwing, and
    /// the floor — an explicitly empty branch — is still a branch this session owns.
    /// That property is the whole value of a lever of last resort: a refusal here is
    /// not a retryable failure but a session that can never be cleared, because the
    /// state that produced the refusal (a live tip the file does not have) can never
    /// change back. Only the file itself failing to open or append can still stop it,
    /// and that fails the whole session, not this method.
    ///
    /// It leaves the session **usable**, not merely unblocked. The branch it adopts
    /// ends on a tool call that never returned — that is what the lever is *for* — so
    /// before returning it persists a synthetic error result for every unanswered
    /// call on that branch, exactly as ``drainPending(_:reason:)`` answers a parked
    /// permission prompt. Without it the recovered session trades a 409 it cannot
    /// clear for a 400 it cannot clear (see ``DoMoLLM/Context/hasToolHistory``), which
    /// is the same dead session one layer down.
    ///
    /// It is **atomic**: the replacement harness is opened and sealed before anything
    /// is cancelled, drained or replaced, so a failure in either leaves the session
    /// exactly as it was and the call can simply be retried. Half-clearing a session —
    /// cancelled and drained but still holding its slot on a harness whose `isRunning`
    /// is stuck — would be strictly worse than not trying. The seal writes to the
    /// session file, so a caller that loses the race below leaves those entries behind
    /// on a branch nothing continues; that is the price of preparing before mutating,
    /// and it is invisible to every reader, which walks from a live tip.
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
        // The branch this session is actually on, tip first. The doomed run keeps its
        // own persistence sink over `path`, and the file's leaf is "last entry wins",
        // so the file is not an authority on the live branch — this harness is.
        let liveBranch = await harness.leafLineage
        // Opened FIRST, while nothing has been mutated yet — and OFF this actor,
        // because it parses the whole session file and this lever is pulled exactly
        // when the runtime is already unhealthy and every other session's calls are
        // the last thing that should queue behind it.
        //
        // `preferring:` never falls back to the file's own leaf — that fallback IS
        // the branch switch this pin exists to prevent — but it also never refuses:
        // it takes the live tip when the file has it and the nearest ancestor of the
        // live tip it can resolve otherwise, both of which are on the live branch by
        // construction. That distinction is the whole point of the entry point. A
        // strict pin makes this lever THROW, permanently and identically on every
        // retry, whenever the file is behind the live tip — the crash-truncated tail
        // the storage layer explicitly tolerates elsewhere is enough — and a lever of
        // last resort that can refuse is a session that can never be cleared.
        let steeringBox = makeSteeringBox()
        let fresh = try await Self.reopen(
            path: path,
            configuration: harnessConfiguration(sessionID: sessionID, steeringBox: steeringBox),
            preferring: liveBranch
        )
        // The branch this lever adopts ends, by the nature of what it is for, on an
        // assistant turn that called a tool which never returned — so nothing ever
        // wrote the `tool_result` that call requires. Nothing downstream repairs
        // that: `ContextBuilder` projects entries verbatim and there is no sanitizer
        // between here and the wire, so every later prompt would be rejected by the
        // provider (see `Context.hasToolHistory`) and the session would trade its 409
        // for a permanent 400. Sealing here — through the FRESH harness, before it is
        // ever handed a prompt — makes "the live tip is always answerable" an
        // invariant this lever ESTABLISHES rather than one that happens to hold.
        //
        // Still in the preparation phase: no runtime state has been touched, so like
        // the re-open, an I/O failure here leaves the session exactly as it was and
        // the call retryable. It runs on the fresh harness's actor, not this one, so
        // the parse it does is off this actor for the same reason the re-open is.
        try await fresh.sealUnansweredToolCalls(reason: Self.clearedReason)
        // Re-check after the suspensions above, and with no suspension between here
        // and the swap: a concurrent shutdown or a concurrent force-clear must win
        // rather than be clobbered by a state built from a stale snapshot. `fresh` is
        // simply dropped in that case — no runtime state has been touched, which is
        // the point of preparing first. What it wrote while sealing stays in the file
        // as a branch nothing continues; every reader walks from a live tip, so it is
        // unreachable rather than confusing.
        guard let current = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard current === session else { return false }

        // Silence the doomed run BEFORE the swap, so there is no window in which it
        // can emit into a sink the replacement state already owns.
        session.runSink?.detach()
        session.runTask?.cancel()
        drainPending(session, reason: Self.clearedReason)
        session.steeringBox.clear()
        sessions[sessionID] = makeState(harness: fresh, sink: session.sink, steeringBox: steeringBox)
        session.sink.broadcast(.queueUpdate(count: 0, mode: steeringBox.mode.rawValue))
        // Terminal frame for anyone still attached: the client's run state is
        // edge-triggered, so without this it stays pinned on "thinking…". Sent on
        // the raw sink — this frame is the runtime's, not the abandoned run's.
        session.sink.broadcast(.agentEnd(reason: "aborted"))
        return true
    }

    /// What the client is told, and what the model is told, about a call this lever
    /// walked away from. One string for both: a parked permission prompt and a parked
    /// tool call are the same event from the session's point of view, and the model's
    /// copy of it should read the same as the user's.
    private static let clearedReason = "The run was cleared at the client's request."

    /// The server's authoritative view of one session — see ``SessionStatus``.
    ///
    /// **Accounting failures degrade; they do not propagate.**
    /// ``DoMoHarness/AgentHarness/accounting()`` throws exactly when the session's
    /// active path cannot be resolved — a structural hole in the branch it is
    /// standing on — which is to say, on precisely the damaged session a client
    /// reaches for this route to diagnose. Letting that throw out would 500 the one
    /// endpoint whose job is to answer "is a turn still running, and what is it
    /// waiting on"; the run state would be lost along with the numbers, and a client
    /// whose spinner is pinned by a missed SSE edge would have nothing left to ask.
    /// The totals are the *addition* to this payload. Run state is the reason it
    /// exists, and it must survive the addition failing. So a failure becomes
    /// `accounting: nil`, which ``SessionStatus/accounting`` already has to mean
    /// "not reported" for the older-server case.
    ///
    /// **The run-state half is snapshotted before the hop below.** Awaiting the
    /// harness suspends, and this actor is reentrant, so reading `session` again
    /// afterwards could pair a `running` from one moment with a pending set from
    /// another — and this value's whole purpose is to be a self-consistent answer a
    /// client adopts wholesale.
    ///
    /// **Two things this does not insulate against**, stated because the degradation
    /// above could be read as covering more than it does:
    ///
    /// 1. A harness that cannot be *reached*, as opposed to one that cannot answer.
    ///    This awaits it, so a session whose harness actor is blocked leaves the
    ///    request waiting rather than answering with `nil`. That is the same
    ///    exposure ``messages(sessionID:)`` and ``forceClearRun(sessionID:)`` already
    ///    carry — both read from the harness too — and closing it would need a
    ///    supervision layer this server does not have.
    /// 2. Cost. `accounting()` re-parses the whole session file to measure the
    ///    current context, so polling this route on a long transcript is not free
    ///    and serializes against the harness's own work.
    public func status(sessionID: String) async throws -> SessionStatus {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let running = session.runTask != nil
        // Sorted so the projection is stable across calls; the pending map is
        // a dictionary and its iteration order is not.
        let pendingPermissionIDs = session.pending.keys.sorted()
        let pendingQuestionIDs = session.pendingQuestions.keys.sorted()
        let subscribers = session.sink.subscriberCount
        let runStartedAt = session.runStartedAt.map(Self.iso8601)
        return SessionStatus(
            sessionID: sessionID,
            running: running,
            pendingPermissionIDs: pendingPermissionIDs,
            subscribers: subscribers,
            runStartedAt: runStartedAt,
            accounting: try? await session.harness.accounting(),
            queuedMessageCount: session.steeringBox.count,
            steeringMode: session.steeringBox.mode.rawValue,
            pendingQuestionIDs: pendingQuestionIDs
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
        let questions = session.pendingQuestions
        session.pendingQuestions.removeAll()
        for (id, question) in questions {
            question.continuation.resume(returning: nil)
            session.sink.broadcast(.questionResolved(id: id))
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

    /// The full tree snapshot used by the client's `/tree` picker. Metadata stays
    /// in the existing session-entry vocabulary, so labels and branch summaries
    /// are visible without inventing a second wire representation.
    public func tree(sessionID: String) async throws -> [SessionTreeEntry] {
        try await Self.loadTree(at: try await sessionPath(sessionID))
    }

    /// Persist a model selection for a session and make it the stream used by its
    /// next turn.
    public func changeModel(sessionID: String, modelID: String) async throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        guard let option = models().first(where: { $0.id == modelID }) else {
            throw DoMoError(.configuration, "Unknown model: \(modelID)")
        }
        try await session.harness.selectModel(
            provider: option.provider,
            modelId: option.id,
            streamFn: config.modelStreamFactory?(option.id),
            contextWindow: option.contextWindow ?? config.modelContextWindow?(option.id) ?? config.contextWindow
        )
    }

    public func renameSession(sessionID: String, name: String?) async throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        try await session.harness.rename(name)
    }

    /// Generate and persist a display title through the session's active model.
    /// A live session is required because the selected model and stream factory
    /// belong to its harness; the client revives disk-only sessions before calling.
    public func autoTitle(sessionID: String) async throws -> String? {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        return try await session.harness.autoTitle()
    }

    public func label(sessionID: String, targetID: String, label: String?) async throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        try await session.harness.setLabel(targetID: targetID, label: label)
    }

    public func moveLeaf(sessionID: String, targetID: String?) async throws {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        try await session.harness.moveLeaf(to: targetID)
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

    /// Force one compaction checkpoint on an idle session. Automatic compaction
    /// settings do not suppress an explicit user request.
    public func compact(sessionID: String) async throws -> CompactionResult {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        guard session.runTask == nil else { throw ServerRuntimeError.sessionBusy }
        return CompactionResult(compacted: try await session.harness.compactNow())
    }

    /// Return the exact projected context the next turn would send, rather than
    /// the lossless transcript returned by ``messages(sessionID:)``.
    public func context(sessionID: String) async throws -> ContextSnapshot {
        guard let session = sessions[sessionID] else { throw ServerRuntimeError.sessionNotFound }
        let messages = try await session.harness.contextMessages()
        return ContextSnapshot(messages: messages, accounting: try? await session.harness.accounting())
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

    /// Re-open a session file off this actor, continuing from the live branch
    /// `preferring` describes rather than from the file's last entry — see
    /// ``forceClearRun(sessionID:)``. A separate entry point rather than an optional
    /// parameter on the one above, so "which tip" is always a decision a caller made
    /// rather than a default it inherited.
    @concurrent
    private static func reopen(
        path: FilePath,
        configuration: AgentHarness.Configuration,
        preferring leaves: [String]
    ) async throws -> AgentHarness {
        try AgentHarness.open(path: path, configuration: configuration, preferring: leaves)
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
    private static func loadTree(at path: FilePath) async throws -> [SessionTreeEntry] {
        try SessionTree.load(from: JSONLSessionStore(path: path)).entries
    }

    @concurrent
    private static func loadListing(cwd: String, sessionDirectory: FilePath) async throws -> [SessionSummary] {
        try JSONLSessionStore.list(cwd: cwd, sessionDirectory: sessionDirectory).map {
            let name: String?
            if let branch = try? SessionTree.load(from: JSONLSessionStore(path: $0.path)).branch() {
                name = SessionTree.latestSessionName(in: branch)
            } else {
                name = nil
            }
            return SessionSummary(
                id: $0.header.id,
                path: $0.path.string,
                cwd: $0.header.cwd,
                timestamp: $0.header.timestamp,
                name: name
            )
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
