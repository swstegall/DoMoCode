// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/agent-harness.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation
import SystemPackage

// MARK: - Harness

/// The stateful runtime that ties the session store, the tree/context builder, and
/// compaction to ``DoMoAgent``'s pure loop.
///
/// It is an `actor` for one reason: the mutable tip of the session — the leaf that
/// moves every time the loop appends a message — is touched *across* the loop's
/// awaits. ``run(prompt:sink:)`` suspends on ``runAgentLoop(prompts:context:config:sink:streamFn:)``
/// while the ``SessionPersistenceSink`` reentrantly calls ``persistMessage(_:)``
/// to advance the leaf; making the harness an actor is what serializes those
/// appends without ever holding a lock across the loop's suspension. The store
/// itself is a stateless value (``JSONLSessionStore``) — everything durable lives
/// in the file; the only in-memory state here is the tip and the injected config.
///
/// This is the run/persist/compact/resume spine of pi's `AgentHarness`. Most of
/// the feature surface pi layers on top — model/tool mutation entries, retry
/// policy, thinking level — is deliberately not ported; the shape below is where
/// those would attach. The loop's turn-boundary hooks (steering, follow-up, and
/// the stop-after-turn predicate), however, *are* forwarded: ``Configuration``
/// exposes them and ``run(prompt:sink:)`` threads them into the ``AgentLoopConfig``,
/// so an embedding can inject a message typed mid-run into the *current* run's
/// next turn — pi's real steering semantics — rather than deferring it to a fresh
/// run.
public actor AgentHarness {
    /// The stateless persistence backend. Re-derives the tree from the file per
    /// read; owns no tip.
    private let store: JSONLSessionStore

    /// The active tip. `nil` for a session with no entries yet. This is the one
    /// piece of mutable state the actor exists to protect.
    private var leaf: String?

    private let configuration: Configuration

    /// Guards against a second concurrent ``run(prompt:sink:)``. Set and read only
    /// in the synchronous prologue of an actor method, so a re-entrant call sees it
    /// before its first await — pi's `phase !== "idle"` busy check.
    private var isRunning = false

    private init(store: JSONLSessionStore, leaf: String?, configuration: Configuration) {
        self.store = store
        self.leaf = leaf
        self.configuration = configuration
    }

    // MARK: - Configuration

    /// Everything a harness needs that is not the session file itself.
    ///
    /// A single `Sendable` value so the same config can seed a session and its
    /// forks unchanged. `now` and `entryIDFactory` are injected — never read from a
    /// global clock or `UUIDv7.generate()` directly — so a test pins both and the
    /// resulting session file is byte-deterministic.
    public struct Configuration: Sendable {
        /// The system prompt sent with every request.
        public var systemPrompt: String?

        /// The tools available to a run, already wrapped as ``AgentTool``s. The
        /// harness never imports `DoMoTools`; the caller crosses that seam and
        /// hands the bound tools in.
        public var tools: [any AgentTool]

        /// The model name stamped onto synthesized messages and used for
        /// compaction's summarization request. Model *selection* is the injected
        /// ``streamFn``'s job.
        public var model: String

        /// The one dependency on the outside world for an assistant turn.
        public var streamFn: AgentStreamFn

        /// The summarization LLM call. `nil` means "reuse the same client the run
        /// uses", realized as a one-shot request through ``streamFn`` — so the
        /// default summarizer is the same model without the harness importing a
        /// concrete client, and any caller can still substitute its own.
        public var summarizer: Summarizer?

        public var toolExecution: ToolExecutionMode

        public var maxTurns: Int?

        /// When and how aggressively automatic pre-turn compaction fires.
        public var compaction: CompactionSettings

        /// The model's context window in tokens, the ceiling compaction measures
        /// the running context against.
        public var contextWindow: Int

        public var now: @Sendable () -> Date

        public var entryIDFactory: @Sendable () -> String

        /// Polled by the loop at each turn boundary for messages to inject before
        /// the next assistant response — pi's "steering". A message a caller
        /// enqueues while a run is in flight reaches the *current* run's next turn.
        /// Forwarded verbatim into ``AgentLoopConfig/getSteeringMessages``; `nil`
        /// means "no steering", the print-mode default. Contract: must not throw,
        /// return `[]` when none.
        public var getSteeringMessages: (@Sendable () async -> [Message])?

        /// Polled after the agent would otherwise stop; a non-empty return resumes
        /// the run with another turn. Forwarded into
        /// ``AgentLoopConfig/getFollowUpMessages``. Contract: must not throw.
        public var getFollowUpMessages: (@Sendable () async -> [Message])?

        /// Consulted after each turn; returning `true` ends the run early.
        /// Forwarded into ``AgentLoopConfig/shouldStopAfterTurn``.
        public var shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)?

        public init(
            systemPrompt: String? = nil,
            tools: [any AgentTool] = [],
            model: String,
            streamFn: @escaping AgentStreamFn,
            summarizer: Summarizer? = nil,
            toolExecution: ToolExecutionMode = .parallel,
            maxTurns: Int? = nil,
            compaction: CompactionSettings = .default,
            contextWindow: Int = 200_000,
            now: @escaping @Sendable () -> Date = { Date() },
            entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description },
            getSteeringMessages: (@Sendable () async -> [Message])? = nil,
            getFollowUpMessages: (@Sendable () async -> [Message])? = nil,
            shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)? = nil
        ) {
            self.systemPrompt = systemPrompt
            self.tools = tools
            self.model = model
            self.streamFn = streamFn
            self.summarizer = summarizer
            self.toolExecution = toolExecution
            self.maxTurns = maxTurns
            self.compaction = compaction
            self.contextWindow = contextWindow
            self.now = now
            self.entryIDFactory = entryIDFactory
            self.getSteeringMessages = getSteeringMessages
            self.getFollowUpMessages = getFollowUpMessages
            self.shouldStopAfterTurn = shouldStopAfterTurn
        }
    }

    // MARK: - Lifecycle

    /// Starts a brand-new session: creates the file, writes its header, and holds a
    /// harness whose tip is empty. The first ``run(prompt:sink:)`` appends the
    /// first entries.
    public static func start(
        cwd: String,
        sessionDirectory: FilePath,
        configuration: Configuration,
        sessionID: String? = nil
    ) throws -> AgentHarness {
        let store = try JSONLSessionStore.create(
            cwd: cwd,
            sessionDirectory: sessionDirectory,
            sessionID: sessionID,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        return AgentHarness(store: store, leaf: nil, configuration: configuration)
    }

    /// Opens an existing session file and reconstructs the tip.
    ///
    /// This is the resume entry point and the exit criterion: it rebuilds the leaf
    /// from the last written entry exactly as the store does, so the next
    /// ``run(prompt:sink:)`` builds the same context an uninterrupted run would
    /// have had. The header is validated eagerly (a mistyped path is an error now,
    /// not a silent empty session); the *entries* are read tolerantly, so a
    /// crash-truncated tail still resumes — pi's read asymmetry, preserved.
    public static func open(
        path: FilePath,
        configuration: Configuration
    ) throws -> AgentHarness {
        let store = try JSONLSessionStore.open(
            path: path,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        let tree = try SessionTree.load(from: store)
        return AgentHarness(store: store, leaf: tree.leafID, configuration: configuration)
    }

    /// Forks the active path into a new session file whose header names this
    /// session as its parent, returning a harness over the fork.
    ///
    /// The fork extracts the root→leaf path into a fresh file (pi's
    /// `createBranchedSession`), preserving entry ids so references into the branch
    /// keep resolving. The returned harness carries the same ``Configuration`` and
    /// is independent thereafter — appends to it never touch this session's file.
    public func fork(sessionDirectory: FilePath) throws -> AgentHarness {
        guard let leaf else {
            throw DoMoError(.file(path: store.path, errno: nil), "Cannot fork a session with no entries")
        }
        let forked = try store.createBranchedSession(
            leafID: leaf,
            sessionDirectory: sessionDirectory,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        return AgentHarness(store: forked, leaf: try forked.leafID(), configuration: configuration)
    }

    // MARK: - Inspection

    /// The file this session persists to.
    public var sessionFilePath: FilePath { store.path }

    /// The current tip.
    public var currentLeafID: String? { leaf }

    /// The messages the next turn would be seeded with, resolved from the current
    /// path exactly as ``run(prompt:sink:)`` resolves them.
    ///
    /// Exposed so a caller — and the resume test — can assert that a freshly opened
    /// harness reconstructs the identical context an uninterrupted run held.
    public func contextMessages() throws -> [Message] {
        try buildContextMessages()
    }

    // MARK: - Run

    /// Runs one turn to completion: optionally compacts, builds the context from
    /// the persisted path, drives the loop, and persists every message as it lands.
    ///
    /// The sequence is pi's spine. Compaction is checked *before* the turn so an
    /// over-full context is summarized before another request is built. The context
    /// is then projected from the leaf, the loop runs against the injected
    /// ``streamFn`` and tools, and a ``SessionPersistenceSink`` writes each
    /// `messageEnd` to disk while forwarding events to `sink`. After the loop
    /// settles, a persistence error captured during the run (which `emit` could not
    /// throw) is surfaced here, so a run that could not durably record its
    /// transcript fails loudly rather than returning a lie.
    @discardableResult
    public func run(prompt: String, sink: (any AgentEventSink)? = nil) async throws -> AgentRunResult {
        guard !isRunning else {
            throw DoMoError(.configuration, "AgentHarness is already running a turn")
        }
        isRunning = true
        defer { isRunning = false }

        try await compactIfNeeded()

        let context = AgentContext(
            systemPrompt: configuration.systemPrompt,
            messages: try buildContextMessages(),
            tools: configuration.tools
        )
        let config = AgentLoopConfig(
            model: configuration.model,
            toolExecution: configuration.toolExecution,
            maxTurns: configuration.maxTurns,
            getSteeringMessages: configuration.getSteeringMessages,
            getFollowUpMessages: configuration.getFollowUpMessages,
            shouldStopAfterTurn: configuration.shouldStopAfterTurn
        )
        let errorBox = PersistenceErrorBox()
        let persistenceSink = SessionPersistenceSink(persister: self, forward: sink, errorBox: errorBox)

        let result = await runAgentLoop(
            prompts: [.user(prompt)],
            context: context,
            config: config,
            sink: persistenceSink,
            streamFn: configuration.streamFn
        )

        if let error = errorBox.first {
            throw DoMoError(.file(path: store.path, errno: nil), "Failed to persist session transcript", cause: error)
        }
        return result
    }

    // MARK: - Persistence

    private func timestamp() -> String {
        JSONLSessionStore.iso8601(configuration.now())
    }

    private func buildContextMessages() throws -> [Message] {
        try ContextBuilder.buildContext(SessionTree.load(from: store), from: leaf)
    }

    // MARK: - Compaction

    /// The effective summarizer: the injected one, or a default that runs a
    /// one-shot summarization request through the same ``streamFn`` the run uses.
    ///
    /// Building it from `streamFn` rather than a stored `LiteLLMClient` is what lets
    /// "default to the same LLM client" hold without this module depending on a
    /// concrete client. The request carries a summarization system prompt and a
    /// trailing instruction; the terminal assistant message's text is the summary.
    /// A failed terminal turn throws, so compaction that could not summarize writes
    /// no entry — the correct outcome for a context that cannot be bounded.
    private var effectiveSummarizer: Summarizer {
        if let summarizer = configuration.summarizer { return summarizer }
        let streamFn = configuration.streamFn
        return { messages in
            let request = Context(
                systemPrompt: Self.summarizationSystemPrompt,
                messages: messages + [.user(Self.summarizationInstruction)],
                tools: []
            )
            var terminal: AssistantMessage?
            for try await event in streamFn(request) {
                if let message = event.terminalMessage { terminal = message }
            }
            guard let terminal else {
                throw DoMoError(.provider(status: nil, isRetryable: false), "Summarization produced no response")
            }
            if let failure = terminal.failure { throw failure }
            return terminal.text
        }
    }

    /// Runs pre-turn compaction when the running context has grown close enough to
    /// the window, then advances the leaf to the compaction checkpoint so the next
    /// ``buildContextMessages()`` resolves to it.
    ///
    /// Token math and entry construction are the pure ``prepareCompaction(pathEntries:settings:)``
    /// / ``compact(_:id:parentId:timestamp:usage:summarize:)`` from the compaction
    /// module; this method only decides *whether* to fire (from the last assistant
    /// `Usage`-anchored estimate) and appends the result. A path that has nothing
    /// older than the recent budget yields no preparation and nothing is written.
    private func compactIfNeeded() async throws {
        guard configuration.compaction.enabled else { return }
        let tree = try SessionTree.load(from: store)
        let pathEntries = try tree.pathToRootOrCompaction(from: leaf)
        let messages = ContextBuilder.messages(for: pathEntries)
        let estimate = estimateContextTokens(messages)
        guard
            shouldCompact(
                contextTokens: estimate.tokens,
                contextWindow: configuration.contextWindow,
                settings: configuration.compaction
            )
        else { return }
        guard let preparation = prepareCompaction(pathEntries: pathEntries, settings: configuration.compaction) else {
            return
        }
        let entry = try await compact(
            preparation,
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            summarize: effectiveSummarizer
        )
        try store.appendEntry(entry)
        leaf = entry.id
    }

    // MARK: - Summarization prompt

    /// The summarization prompt is intentionally terse and lives here, at the
    /// orchestrator that constructs the model call, not in the pure compaction
    /// layer. pi's richer templates would slot in the same place.
    private static let summarizationSystemPrompt =
        "You are summarizing a conversation so it can be continued with less context. "
        + "Produce a concise, faithful summary that preserves decisions, open questions, and any "
        + "facts the assistant will need to continue the task."

    private static let summarizationInstruction =
        "Summarize the conversation so far, preserving everything needed to continue."
}

// MARK: - Persistence conformance

extension AgentHarness: SessionMessagePersisting {
    /// Appends `message` as a child of the current tip and advances the tip to it.
    ///
    /// Actor-isolated, so the ``SessionPersistenceSink`` calling in from the loop's
    /// executor is serialized onto the actor: appends land in the emit order the
    /// loop produces, which is transcript order, so the file is a faithful,
    /// resumable replay. The append is crash-safe (one line, `write`-then-return),
    /// so an interruption damages at most the final line.
    public func persistMessage(_ message: Message) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: .message(message)
        )
        try store.appendEntry(entry)
        leaf = entry.id
    }
}
