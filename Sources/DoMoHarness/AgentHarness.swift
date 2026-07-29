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

    /// Every tip this harness has stood on, oldest first: the one it was opened
    /// with (if any), then each entry it has appended since.
    ///
    /// This is a **parent chain by construction**, not a log that happens to look
    /// like one: the only two places that move the tip — ``persistMessage(_:)`` and
    /// ``compactIfNeeded()`` — both write the new entry with `parentId: leaf` and
    /// then make it the tip, so element *i* is the parent of element *i+1*. That is
    /// what makes ``leafLineage`` a usable answer to "which ancestor of this tip
    /// does the file still have", for a caller re-opening a session whose file is
    /// behind the tip — see ``open(path:configuration:preferring:)``.
    ///
    /// It costs one entry id per persisted message, against a design that already
    /// re-parses the whole session file on every turn; the id is what the file
    /// stores anyway.
    private var leafChain: [String]

    /// The active tip. `nil` for a session with no entries yet. This is the one
    /// piece of mutable state the actor exists to protect — derived from
    /// ``leafChain`` rather than stored beside it, so the two cannot drift.
    private var leaf: String? { leafChain.last }

    private let configuration: Configuration

    /// Guards against a second concurrent ``run(prompt:sink:)``. Set and read only
    /// in the synchronous prologue of an actor method, so a re-entrant call sees it
    /// before its first await — pi's `phase !== "idle"` busy check.
    private var isRunning = false

    private init(store: JSONLSessionStore, leaf: String?, configuration: Configuration) {
        self.store = store
        self.leafChain = leaf.map { [$0] } ?? []
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

        /// Runs before each tool executes and may reject or rewrite the call. The
        /// permission engine's gate (Phase 8) is injected here; the loop already
        /// awaits it in `ToolDispatch.prepare` strictly before any side effect, but
        /// `AgentLoopConfig`'s field was previously never populated from the harness.
        /// `nil` means "no gate" — every tool runs. Contract: must honor cancellation.
        public var beforeToolCall: BeforeToolCallHook?

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
            shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)? = nil,
            beforeToolCall: BeforeToolCallHook? = nil
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
            self.beforeToolCall = beforeToolCall
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

    /// Opens an existing session file and continues from a tip the **caller**
    /// supplies, instead of recovering one from the file's last entry.
    ///
    /// ``open(path:configuration:)`` reconstructs the tip exactly as the store does
    /// — last entry wins — which is the right answer for a cold resume and the
    /// wrong one whenever a *live* harness already knows which branch the session
    /// is on. Two harnesses can share a file: `ServerRuntime.forceClearRun` walks
    /// away from a wedged run whose harness cannot be stopped and keeps its own
    /// persistence sink over the same file, so when that run eventually settles its
    /// late append becomes the file's last entry. Re-deriving a tip from the file
    /// at that point silently moves the session onto the abandoned run's dead
    /// branch, and because every later turn is then appended as a child of it, the
    /// recovered turn disappears from the model's context and not merely from the
    /// rendering. The live harness's own ``currentLeafID`` is the only authority on
    /// the branch a session is actually on; the file is the authority only on what
    /// is written to it.
    ///
    /// - Parameter leaf: The entry to continue from, which must be present in the
    ///   file — an absent tip is refused rather than quietly downgraded to the
    ///   file's own leaf, because that downgrade *is* the branch switch this entry
    ///   point exists to prevent. `nil` pins an **empty** tip (a session whose live
    ///   branch has nothing on it yet); it does not mean "use the file's".
    ///
    /// The refusal is right and is *not* a recovery path: the file is allowed to be
    /// behind a live tip, and a tip it lost can never come back, so a caller that
    /// must not fail — the force-clear lever — cannot be built on this entry point.
    /// It uses ``open(path:configuration:preferring:)``, which degrades along the
    /// live branch instead of refusing.
    public static func open(
        path: FilePath,
        configuration: Configuration,
        leaf: String?
    ) throws -> AgentHarness {
        let store = try JSONLSessionStore.open(
            path: path,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        // Checked here rather than trusted: a harness whose tip is not in its file
        // cannot build a context or persist a child, and every read of it would
        // throw far from the call that chose the tip.
        if let leaf {
            let tree = try SessionTree.load(from: store)
            guard tree.entry(withID: leaf) != nil else {
                throw DoMoError(
                    .file(path: path, errno: nil),
                    "Cannot open a session pinned to an entry that is not in the file: \(leaf)"
                )
            }
        }
        return AgentHarness(store: store, leaf: leaf, configuration: configuration)
    }

    /// Opens an existing session file and continues from the **first tip in
    /// `preferredLeaves` this file can actually resolve**, or from an explicitly
    /// empty branch when it can resolve none.
    ///
    /// This is the recovery counterpart to the strict ``open(path:configuration:leaf:)``
    /// above, and it exists because that strictness is unusable on its own for a
    /// caller that must not fail. `ServerRuntime.forceClearRun` is the lever of last
    /// resort for a session whose run cannot be stopped; the tip it must pin lives in
    /// the live harness's memory, and the *file* is explicitly allowed to be behind
    /// it — `JSONLines`' own append ("the previous process died between writing an
    /// entry and writing its newline"), ``SessionTree/load(from:onSkippedLine:)``
    /// ("a crash-truncated tail … never fatal — because this is the resume path"),
    /// ``persistMessage(_:)`` ("an interruption damages at most the final line").
    /// A tip the file lost can never come
    /// back, so a refusal there is not retryable the way every other re-open failure
    /// is: it is permanent, and it welds shut the one escape hatch the session has.
    ///
    /// Passing the live harness's ``leafLineage`` therefore degrades instead of
    /// refusing, and does so **by construction rather than by reasoning**: every
    /// candidate is an ancestor of the live tip, so whichever one is chosen is on the
    /// live branch — it can never be some other harness's branch, which is the one
    /// outcome the strict pin exists to prevent. Falling all the way through to `nil`
    /// keeps that property (an empty branch is nobody's) and keeps the session usable;
    /// the entries that survived stay on disk and reachable through the tree, they are
    /// simply no longer the branch this harness continues.
    ///
    /// A candidate is accepted only if the file can resolve its whole chain, not
    /// merely if the entry is present: the bulk read is tolerant of a malformed line
    /// *anywhere*, while ``SessionTree/branch(from:)`` and
    /// ``SessionTree/pathToRootOrCompaction(from:)`` throw on the hole it leaves. A
    /// present-but-unresolvable tip would open cleanly and then fail on every read
    /// and every turn — a session that takes prompts and answers none.
    public static func open(
        path: FilePath,
        configuration: Configuration,
        preferring preferredLeaves: [String]
    ) throws -> AgentHarness {
        let store = try JSONLSessionStore.open(
            path: path,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        let tree = try SessionTree.load(from: store)
        // Two tiers, strongest first.
        //
        // `branch(from:)` walks the full parent chain to the root; succeeding there
        // implies the shorter `pathToRootOrCompaction` walk a turn takes succeeds
        // too. But that implication only runs one way, and it is the CONVERSE this
        // gate needs. A compacted session resolves a turn only as far back as its
        // checkpoint, so a hole BELOW the checkpoint fails `branch` while leaving
        // every read a turn actually performs intact. Gating on `branch` alone
        // therefore rejected every candidate and fell through to an empty branch —
        // force-clear silently discarding a whole compacted conversation that was
        // still perfectly usable.
        //
        // So: prefer a candidate whose entire history resolves, and settle for one
        // that resolves as far as a turn will ever look. Both tiers only ever accept
        // an ancestor of the live tip, so the by-construction property holds — the
        // chosen leaf is on the live branch and can never be another harness's.
        let pinned = preferredLeaves.first { (try? tree.branch(from: $0)) != nil }
            ?? preferredLeaves.first { (try? tree.pathToRootOrCompaction(from: $0)) != nil }
        return AgentHarness(store: store, leaf: pinned, configuration: configuration)
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

    /// The current tip followed by the ancestors of it this harness itself knows,
    /// most recent first — see ``leafChain``.
    ///
    /// Ordered tip-first because that is the order a recovery wants to try them in:
    /// the tip if it can be had, then as little of the branch given up as possible.
    /// The list is what ``open(path:configuration:preferring:)`` consumes; it is
    /// empty exactly when the tip is.
    public var leafLineage: [String] { leafChain.reversed() }

    /// The messages the next turn would be seeded with, resolved from the current
    /// path exactly as ``run(prompt:sink:)`` resolves them.
    ///
    /// Exposed so a caller — and the resume test — can assert that a freshly opened
    /// harness reconstructs the identical context an uninterrupted run held.
    public func contextMessages() throws -> [Message] {
        try buildContextMessages()
    }

    // MARK: - Sealing an interrupted branch

    /// Answers every tool call on the current branch that nothing answers, with a
    /// synthetic error result, and returns the ids sealed.
    ///
    /// A branch is normally self-repairing: the loop dispatches the calls in an
    /// assistant turn and persists a result for each, even for a tool that failed or
    /// was aborted (``ToolDispatch`` synthesizes one), so a `tool_use` without its
    /// `tool_result` cannot survive a run that ends. It survives a run that *never*
    /// ends — which is exactly the situation a caller reaches for when it walks away
    /// from a wedged run and adopts the branch that run was standing on.
    ///
    /// Left alone, that branch is not merely untidy: the provider validates it.
    /// ``DoMoLLM/Context/hasToolHistory`` already records that Anthropic behind
    /// LiteLLM rejects a transcript whose tool history does not line up, and nothing
    /// between ``contextMessages()`` and the wire repairs anything —
    /// ``ContextBuilder`` projects entries verbatim. So a session "recovered" onto a
    /// dangling branch answers every later prompt with a 400 instead of a 409: the
    /// same dead session, one layer down.
    ///
    /// Calling this is what turns "the tip is answerable" from something that
    /// happens to hold into something the caller establishes. It is idempotent by
    /// construction — the seals it writes are themselves the answers it looks for —
    /// and writes nothing at all to a branch that is already complete.
    ///
    /// The results are persisted as their own `tool` entries through the normal
    /// append path, which is the same shape the loop writes, so nothing downstream
    /// can tell a sealed branch from an interrupted-and-answered one.
    ///
    /// They land at the tip, which is where the calls that need them are in the case
    /// this exists for — the branch ends on the turn that was interrupted. A branch
    /// that was *already* dangling further back is answered late rather than
    /// adjacent, which is strictly better than leaving it unanswered and is not a
    /// shape this method can produce: a branch it has sealed has nothing left to
    /// dangle, and it is called before the branch is ever run again.
    @discardableResult
    public func sealUnansweredToolCalls(reason: String) throws -> [String] {
        let unanswered = Self.unansweredToolCalls(in: try buildContextMessages())
        for call in unanswered {
            try persistMessage(.tool(ToolResultBlock(
                toolCallID: call.id,
                toolName: call.name,
                output: reason,
                isError: true
            )))
        }
        return unanswered.map(\.id)
    }

    /// The tool calls in `messages` that no tool result addresses, in the order they
    /// were requested.
    ///
    /// Answers are counted wherever they can appear: a `tool`-role message (what the
    /// loop persists) and a `toolResult` content block on any other role (what the
    /// wire shapes for providers that hoist results onto a user turn), so a call that
    /// *is* answered is never answered twice.
    public static func unansweredToolCalls(in messages: [Message]) -> [ToolCallBlock] {
        var answered: Set<String> = []
        for message in messages {
            switch message {
            case .tool(let result):
                answered.insert(result.toolCallID)
            case .user(let user):
                for case .toolResult(let result) in user.content { answered.insert(result.toolCallID) }
            case .assistant(let assistant):
                for case .toolResult(let result) in assistant.content { answered.insert(result.toolCallID) }
            case .system:
                continue
            }
        }
        var open: [ToolCallBlock] = []
        for case .assistant(let assistant) in messages {
            for case .toolCall(let call) in assistant.content where !answered.contains(call.id) {
                open.append(call)
            }
        }
        return open
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
    public func run(
        prompt: String,
        attachments: [ImageBlock] = [],
        sink: (any AgentEventSink)? = nil
    ) async throws -> AgentRunResult {
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
            beforeToolCall: configuration.beforeToolCall,
            getSteeringMessages: configuration.getSteeringMessages,
            getFollowUpMessages: configuration.getFollowUpMessages,
            shouldStopAfterTurn: configuration.shouldStopAfterTurn
        )
        let errorBox = PersistenceErrorBox()
        let persistenceSink = SessionPersistenceSink(persister: self, forward: sink, errorBox: errorBox)

        // The turn's user message carries the typed prompt plus any image
        // attachments (Phase 5.5). A text-only turn is byte-for-byte what it was.
        let promptMessage = Message.user(
            UserMessage(content: [.text(prompt)] + attachments.map { .image($0) })
        )
        let result = await runAgentLoop(
            prompts: [promptMessage],
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
        // An empty tip means an empty branch — NOT "ask the file". The resolvers
        // below read `nil` as "start from the file's leaf", which is right for a
        // cold read of a file and wrong for a harness that knows its own branch has
        // nothing on it: ``persistMessage(_:)`` writes the next entry with
        // `parentId: leaf`, i.e. as a new root, so a context resolved from someone
        // else's leaf would seed a turn with a conversation this branch is not on
        // and then answer it in a different place. Same-answering for every harness
        // that could exist before ``open(path:configuration:leaf:)`` (a `nil` tip
        // only ever came with an empty file); load-bearing for the ones that can now.
        guard let leaf else { return [] }
        return try ContextBuilder.buildContext(SessionTree.load(from: store), from: leaf)
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
        // Same reason as ``buildContextMessages()``: an empty tip is an empty branch,
        // and resolving `nil` here would measure — and then summarize — a path this
        // harness is not on, anchoring the checkpoint it writes at the root.
        guard let tip = leaf else { return }
        let tree = try SessionTree.load(from: store)
        let pathEntries = try tree.pathToRootOrCompaction(from: tip)
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
        leafChain.append(entry.id)
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
        leafChain.append(entry.id)
    }
}
