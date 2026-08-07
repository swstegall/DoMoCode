// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/agent-harness.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoAgent
import DoMoCore
import DoMoGit
import DoMoLLM
import Foundation
import SystemPackage

private struct DirectToolDiscardingSink: AgentEventSink {
    func emit(_ event: AgentEvent) async {}
}

// MARK: - Harness

/// The stateful runtime that ties the session store, the tree/context builder, and
/// compaction to ``DoMoAgent``'s pure loop.
///
/// It is an `actor` for one reason: the mutable tip of the session — the leaf that
/// moves every time the loop appends a message — is touched *across* the loop's
/// awaits. ``run(prompt:sink:)`` suspends on ``runAgentLoop(prompts:context:config:sink:streamFn:)``
/// while the ``SessionPersistenceSink`` reentrantly calls ``persistMessage(_:elapsedMs:)``
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
    /// like one: the only two places that move the tip — ``persistMessage(_:elapsedMs:)`` and
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
    /// The model and stream selected for the current branch. The configuration
    /// remains the immutable set of tools and defaults; these values are the
    /// persisted, user-facing model choice.
    private var activeModel: String
    private var activeStreamFn: AgentStreamFn
    private var activeContextWindow: Int?

    /// The latest shadow tree on the active conversation branch. A checkpoint
    /// entry is still written when this id repeats: a conversation-only turn
    /// must remain undoable even when it did not edit a file.
    private var workspaceSnapshotID: String?
    private var workspaceStatusValue: WorkspaceSnapshotStatus

    /// Guards against a second concurrent ``run(prompt:sink:)``. Set and read only
    /// in the synchronous prologue of an actor method, so a re-entrant call sees it
    /// before its first await — pi's `phase !== "idle"` busy check.
    private var isRunning = false

    /// The ordering key the next appended entry gets, seeded from the file so a
    /// resumed session continues its numbering instead of restarting it and
    /// colliding with every entry already written.
    ///
    /// Incremented only *after* a successful append, so a write that throws does
    /// not burn a number and leave a gap that means nothing. (Gaps are legal — the
    /// key is an ordering key, not a count — but a gap should at least correspond
    /// to an entry that existed somewhere.)
    private var nextSeq: Int

    /// Everything this session has spent, cumulative across the whole file.
    ///
    /// One accumulator and one only. Two would mean `--serve` and `--inline`
    /// reporting different numbers for the same session the moment either drifted.
    private var accumulatedUsage: Usage

    /// Assistant turns recorded in this session file, seeded on open the same way
    /// ``accumulatedUsage`` is.
    private var recordedTurns: Int

    private init(store: JSONLSessionStore, leaf: String?, configuration: Configuration, seed: Seed) {
        self.store = store
        self.leafChain = leaf.map { [$0] } ?? []
        self.configuration = configuration
        self.activeModel = seed.model ?? configuration.model
        self.activeStreamFn = configuration.streamFnForModel?(seed.model ?? configuration.model) ?? configuration.streamFn
        self.activeContextWindow = configuration.contextWindowForModel?(seed.model ?? configuration.model)
            ?? configuration.contextWindow
        self.workspaceSnapshotID = seed.workspaceSnapshotID
        self.workspaceStatusValue = configuration.workspaceSnapshots == nil ? .snapshotsDisabled : .restored
        self.nextSeq = seed.nextSeq
        self.accumulatedUsage = seed.usage
        self.recordedTurns = seed.turns
    }

    // MARK: - Seeding from a file

    /// What a harness has to recover from a session file before it can extend it.
    private struct Seed: Sendable {
        var nextSeq: Int
        var usage: Usage
        var turns: Int
        var model: String?
        var workspaceSnapshotID: String?

        /// A brand-new file: numbering starts at zero and nothing has been spent.
        static let fresh = Seed(
            nextSeq: 0,
            usage: .zero,
            turns: 0,
            model: nil,
            workspaceSnapshotID: nil
        )
    }

    /// Everything a harness resumes with: the file's running totals, plus the
    /// ordering key its next append should carry.
    ///
    /// The counter comes from ``JSONLSessionStore/nextSequenceNumber()`` rather
    /// than from a `max` over `entries`, because the two disagree on exactly the
    /// case that matters: `entries` is the *tolerant* read, so a malformed or
    /// crash-truncated line is missing from it, and a file written before ordering
    /// keys existed has no `seq` to take a maximum of at all. The store counts raw
    /// lines for those, which over-counts — the safe direction.
    private static func seed(
        store: JSONLSessionStore,
        entries: [SessionTreeEntry],
        defaultModel: String,
        leafID: String?
    ) throws -> Seed {
        let recovered = totals(from: entries)
        // Model metadata follows the same active context path as a resumed turn.
        // A compacted checkpoint makes the path below it optional: the file may
        // have lost an old ancestor while the checkpoint still contains the
        // complete context the active branch needs. Requiring the full root path
        // here would reject the same usable branch that `open(preferring:)` just
        // selected.
        let activeEntries = try SessionTree(entries: entries).pathToRootOrCompaction(from: leafID)
        let model = activeEntries.reversed().compactMap { entry -> String? in
            if case .modelChange(_, let modelID) = entry.payload { return modelID }
            return nil
        }.first ?? defaultModel
        let workspaceSnapshotID = activeEntries.reversed().compactMap { entry -> String? in
            if case .workspaceCheckpoint(let snapshot) = entry.payload { return snapshot.id }
            return nil
        }.first
        return Seed(
            nextSeq: try store.nextSequenceNumber(),
            usage: recovered.usage,
            turns: recovered.turns,
            model: model,
            workspaceSnapshotID: workspaceSnapshotID
        )
    }

    /// Walk the file's entries once and recover what the session has spent.
    ///
    /// Over **every** entry in the file, not the active branch: the accounting is
    /// documented as cumulative across the session file, an abandoned branch was
    /// still paid for, and — the part that is not a preference — a branch walk
    /// throws on a structural hole, which would make opening a damaged session
    /// fail where it used to succeed. ``open(path:configuration:preferring:)``
    /// exists precisely because that refusal is unacceptable on the recovery path.
    private static func totals(from entries: [SessionTreeEntry]) -> (usage: Usage, turns: Int) {
        var usage = Usage.zero
        var turns = 0
        for entry in entries {
            switch entry.payload {
            case .message(.assistant(let assistant)):
                usage = usage + assistant.usage
                turns += 1
            case .compaction(let compaction):
                if let compactionUsage = compaction.usage { usage = usage + compactionUsage }
            case .branchSummary(let branch):
                if let branchUsage = branch.usage { usage = usage + branchUsage }
            case .message, .modelChange, .label, .leaf, .workspaceCheckpoint, .historyAction, .subagent,
                .recovery:
                break
            case .sessionInfo, .sessionStart:
                if let metadataUsage = entry.metadataUsage { usage = usage + metadataUsage }
                break
            }
        }
        return (usage, turns)
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

        /// Builds a prompt-aware system prompt for each turn. This is the seam
        /// used by keyword-triggered skills; the static `systemPrompt` remains the
        /// fallback for callers that do not load project resources.
        public var systemPromptForPrompt: (@Sendable (String) -> String)?

        /// The tools available to a run, already wrapped as ``AgentTool``s. The
        /// harness never imports `DoMoTools`; the caller crosses that seam and
        /// hands the bound tools in.
        public var tools: [any AgentTool]

        /// Resolves the tools for every assistant request. The selected model is
        /// passed to the resolver, so a caller can vary the set by model or
        /// refresh a session-scoped registry between turns. `nil` preserves the
        /// fixed ``tools`` behavior used by existing callers.
        public var getTools: (@Sendable (String) async -> [any AgentTool])?

        /// Rebuilds a prompt-aware system prompt from the current tool names.
        /// Returning a string keeps the definitions and prompt listing in sync.
        public var systemPromptForPromptAndTools: (@Sendable (String, [String]) -> String)?

        /// Optional bounded, non-recursive interpretation of a final provider
        /// failure. It is kept outside the ordinary stream function so a
        /// diagnostic request cannot accidentally become another agent turn.
        public var recoveryDiagnostic: RecoveryDiagnosticFn?

        /// Wall-clock cap for the optional recovery diagnostic sub-turn.
        public var recoveryDiagnosticTimeout: Duration

        /// Maximum completion tokens requested by the diagnostic sub-turn.
        public var recoveryDiagnosticMaxOutputTokens: Int

        /// Explicitly allowlisted read-only tools for failure diagnosis. The
        /// normal session tool set is deliberately not reused.
        public var recoveryDiagnosticTools: [any AgentTool]

        /// The model name stamped onto synthesized messages and used for
        /// compaction's summarization request. Model *selection* is the injected
        /// ``streamFn``'s job.
        public var model: String

        /// The one dependency on the outside world for an assistant turn.
        public var streamFn: AgentStreamFn

        /// Resolves a persisted model selection when a session is reopened. The
        /// default keeps every existing caller byte-for-byte unchanged.
        public var streamFnForModel: (@Sendable (String) -> AgentStreamFn)?

        /// Supplies the measured context window for a selected model alias.
        public var contextWindowForModel: (@Sendable (String) -> Int?)?

        /// The summarization LLM call. `nil` means "reuse the same client the run
        /// uses", realized as a one-shot request through ``streamFn`` — so the
        /// default summarizer is the same model without the harness importing a
        /// concrete client, and any caller can still substitute its own.
        public var summarizer: Summarizer?

        public var toolExecution: ToolExecutionMode

        public var maxTurns: Int?

        /// Optional hard USD ceiling for the assistant turns in one run.
        /// Forwarded to ``AgentLoopConfig/maxCostPerRun``.
        public var maxCostPerRun: Decimal?

        /// When and how aggressively automatic pre-turn compaction fires.
        ///
        /// Clamped at construction against ``contextWindow`` (see
        /// ``CompactionSettings/clamped(toContextWindow:)``), so a small model can
        /// never end up with budgets that swallow its whole window and make
        /// compaction a no-op. On a window the budgets already fit in — every
        /// default path — this is what the caller passed, unchanged.
        public var compaction: CompactionSettings

        /// The model's context window in tokens.
        ///
        /// `nil` means **genuinely unknown**, which is the default because behind a
        /// gateway it usually is: an alias names a deployment whose window this
        /// process was never told. A meter renders `nil` as `?`; it must never
        /// print a percentage of a guess, because a made-up denominator is
        /// indistinguishable from a measured one on screen.
        ///
        /// This is the meter's truth. It is *not* what compaction falls back on:
        /// ``fallbackContextWindow`` is, and only inside `compactIfNeeded`, where a
        /// guess is strictly better than nothing — an unknown small alias with no
        /// ceiling grows until the provider rejects the request, and a session that
        /// dies of context overflow is worse than one compacted a little early.
        public var contextWindow: Int?

        public var now: @Sendable () -> Date

        /// The monotonic clock elapsed times are measured against.
        ///
        /// Separate from ``now`` and not derived from it, for two independent
        /// reasons: a `Date` delta can go *negative* across an NTP step, and every
        /// harness test pins `now` to a single constant — which would make every
        /// elapsed assertion in the suite a vacuously passing `0`.
        public var monotonicNow: @Sendable () -> ContinuousClock.Instant

        public var entryIDFactory: @Sendable () -> String

        /// The committed Git HEAD visible when a new session starts. The harness
        /// stores it as a metadata entry without depending on the Git facade;
        /// `nil` means the caller found no repository or no commit.
        public var sessionStartHead: String?

        /// The private workspace snapshot source. `nil` disables snapshots and
        /// makes undo/redo report `snapshots-disabled` instead of claiming a
        /// file operation happened.
        public var workspaceSnapshots: (any WorkspaceSnapshotSource)?

        /// Polled by the loop at each turn boundary for messages to inject before
        /// the next assistant response — pi's "steering". A message a caller
        /// enqueues while a run is in flight reaches the *current* run's next turn.
        /// Forwarded verbatim into ``AgentLoopConfig/getSteeringMessages``; `nil`
        /// means "no steering", the print-mode default. Contract: must not throw,
        /// return `[]` when none.
        public var getSteeringMessages: (@Sendable () async -> [Message])?

        /// A thread-safe queue used when no explicit ``getSteeringMessages`` hook
        /// is supplied. Transports can enqueue while the loop is awaiting the
        /// model, and the loop drains the box at its next boundary.
        public var steeringBox: SteeringBox?

        /// Polled after the agent would otherwise stop; a non-empty return resumes
        /// the run with another turn. Forwarded into
        /// ``AgentLoopConfig/getFollowUpMessages``. Contract: must not throw.
        public var getFollowUpMessages: (@Sendable () async -> [Message])?

        /// A queue-backed fallback for ``getFollowUpMessages``.
        public var followUpBox: FollowUpBox?

        /// Consulted after each turn; returning `true` ends the run early.
        /// Forwarded into ``AgentLoopConfig/shouldStopAfterTurn``.
        public var shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)?

        /// Consulted when the no-progress guard trips. A surface can use this
        /// to turn a silent stop into an explicit permission decision.
        public var onNoProgress: (@Sendable (TurnResult) async -> Bool)?

        /// Runs before each tool executes and may reject or rewrite the call. The
        /// permission engine's gate (Phase 8) is injected here; the loop already
        /// awaits it in `ToolDispatch.prepare` strictly before any side effect, but
        /// `AgentLoopConfig`'s field was previously never populated from the harness.
        /// `nil` means "no gate" — every tool runs. Contract: must honor cancellation.
        public var beforeToolCall: BeforeToolCallHook?

        /// Observes and gates the complete tool lifecycle. Metadata from this
        /// hook is kept out of committed tool results.
        public var toolLifecycle: ToolLifecycleHook?

        /// Maximum duration for one lifecycle hook snapshot.
        public var toolLifecycleTimeout: Duration

        /// The adaptive response-character limit, or `nil` to send prompts
        /// exactly as the caller wrote them.
        ///
        /// One controller per process, shared by every harness a run spawns
        /// including subagents: what it learns is a fact about the *gateway*, and
        /// two controllers over one gateway would each have to rediscover the
        /// ceiling and would disagree while they did.
        ///
        /// It is an actor rather than a value because the learned state is
        /// read-modify-written across the awaits of a turn, and because a parent
        /// and its subagents decorate concurrently.
        public var responseLimit: ResponseLimitController?

        /// What a run does when the gateway times out mid-turn rather than the
        /// model refusing. See ``GatewayContinuationSettings``.
        public var gatewayContinuation: GatewayContinuationSettings

        public init(
            systemPrompt: String? = nil,
            systemPromptForPrompt: (@Sendable (String) -> String)? = nil,
            tools: [any AgentTool] = [],
            getTools: (@Sendable (String) async -> [any AgentTool])? = nil,
            systemPromptForPromptAndTools: (@Sendable (String, [String]) -> String)? = nil,
            model: String,
            streamFn: @escaping AgentStreamFn,
            streamFnForModel: (@Sendable (String) -> AgentStreamFn)? = nil,
            contextWindowForModel: (@Sendable (String) -> Int?)? = nil,
            summarizer: Summarizer? = nil,
            toolExecution: ToolExecutionMode = .parallel,
            maxTurns: Int? = nil,
            compaction: CompactionSettings = .default,
            contextWindow: Int? = nil,
            now: @escaping @Sendable () -> Date = { Date() },
            monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
            entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description },
            getSteeringMessages: (@Sendable () async -> [Message])? = nil,
            steeringBox: SteeringBox? = nil,
            getFollowUpMessages: (@Sendable () async -> [Message])? = nil,
            followUpBox: FollowUpBox? = nil,
            shouldStopAfterTurn: (@Sendable (TurnResult) async -> Bool)? = nil,
            beforeToolCall: BeforeToolCallHook? = nil,
            toolLifecycle: ToolLifecycleHook? = nil,
            toolLifecycleTimeout: Duration = .seconds(2),
            onNoProgress: (@Sendable (TurnResult) async -> Bool)? = nil,
            maxCostPerRun: Decimal? = nil,
            sessionStartHead: String? = nil,
            recoveryDiagnostic: RecoveryDiagnosticFn? = nil,
            recoveryDiagnosticTimeout: Duration = .seconds(8),
            recoveryDiagnosticMaxOutputTokens: Int = 512,
            recoveryDiagnosticTools: [any AgentTool] = [],
            responseLimit: ResponseLimitController? = nil,
            gatewayContinuation: GatewayContinuationSettings = .default
        ) {
            self.systemPrompt = systemPrompt
            self.systemPromptForPrompt = systemPromptForPrompt
            self.tools = tools
            self.getTools = getTools
            self.systemPromptForPromptAndTools = systemPromptForPromptAndTools
            self.recoveryDiagnostic = recoveryDiagnostic
            self.recoveryDiagnosticTimeout = recoveryDiagnosticTimeout
            self.recoveryDiagnosticMaxOutputTokens = max(1, min(2_048, recoveryDiagnosticMaxOutputTokens))
            self.recoveryDiagnosticTools = recoveryDiagnosticTools
            self.model = model
            self.streamFn = streamFn
            self.streamFnForModel = streamFnForModel
            self.contextWindowForModel = contextWindowForModel
            self.summarizer = summarizer
            self.toolExecution = toolExecution
            self.maxTurns = maxTurns
            self.maxCostPerRun = maxCostPerRun
            // Clamped here as well as at the point of use, because this value is a
            // `var` a caller can set afterwards; the check in `compactIfNeeded` is
            // the one that cannot be walked around, and this one is what makes the
            // effective settings inspectable.
            self.compaction = compaction.clamped(
                toContextWindow: contextWindow ?? Configuration.fallbackContextWindow
            )
            self.contextWindow = contextWindow
            self.now = now
            self.monotonicNow = monotonicNow
            self.entryIDFactory = entryIDFactory
            self.sessionStartHead = sessionStartHead
            self.getSteeringMessages = getSteeringMessages
            self.steeringBox = steeringBox
            self.getFollowUpMessages = getFollowUpMessages
            self.followUpBox = followUpBox
            self.shouldStopAfterTurn = shouldStopAfterTurn
            self.beforeToolCall = beforeToolCall
            self.toolLifecycle = toolLifecycle
            self.toolLifecycleTimeout = toolLifecycleTimeout
            self.onNoProgress = onNoProgress
            self.responseLimit = responseLimit
            self.gatewayContinuation = gatewayContinuation
            self.workspaceSnapshots = nil
        }

        /// The window compaction assumes when ``contextWindow`` is `nil`.
        ///
        /// A safety net, not a measurement. It is read only by compaction — the
        /// pre-turn check, and the budget clamp this initializer applies for it.
        /// Everything that *displays* a window reads ``contextWindow`` and renders
        /// `nil` as unknown, because a percentage computed against this number
        /// would look exactly like a real one.
        public static let fallbackContextWindow = 200_000
    }

    /// Per-command settings for one turn. A command can select a model and
    /// reasoning effort through the surface's stream factory, and can provide the
    /// original prompt's skill-expanded system prompt while the persisted user
    /// message contains the rendered template.
    public struct RunOverride: Sendable {
        public var model: String?
        public var streamFn: AgentStreamFn?
        public var systemPrompt: String?

        public init(
            model: String? = nil,
            streamFn: AgentStreamFn? = nil,
            systemPrompt: String? = nil
        ) {
            self.model = model
            self.streamFn = streamFn
            self.systemPrompt = systemPrompt
        }
    }

    // MARK: - Lifecycle

    /// Starts a brand-new session: creates the file, writes its header, and holds a
    /// harness whose tip is at the optional session-start checkpoint. The first
    /// ``run(prompt:sink:)`` appends the first conversation entries.
    public static func start(
        cwd: String,
        sessionDirectory: FilePath,
        configuration: Configuration,
        sessionID: String? = nil,
        parentSession: String? = nil
    ) throws -> AgentHarness {
        let store = try JSONLSessionStore.create(
            cwd: cwd,
            sessionDirectory: sessionDirectory,
            sessionID: sessionID,
            parentSession: parentSession,
            now: configuration.now,
            entryIDFactory: configuration.entryIDFactory
        )
        var leaf: String?
        var nextSeq = 0
        if let head = configuration.sessionStartHead {
            let entry = SessionTreeEntry(
                id: configuration.entryIDFactory(),
                parentId: nil,
                timestamp: JSONLSessionStore.iso8601(configuration.now()),
                payload: .sessionStart(head: head),
                seq: 0
            )
            try store.appendEntry(entry)
            leaf = entry.id
            nextSeq = 1
        }
        return AgentHarness(
            store: store,
            leaf: leaf,
            configuration: configuration,
            seed: Seed(
                nextSeq: nextSeq,
                usage: .zero,
                turns: 0,
                model: nil,
                workspaceSnapshotID: nil
            )
        )
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
        let seed = try Self.seed(
            store: store,
            entries: tree.entries,
            defaultModel: configuration.model,
            leafID: tree.leafID
        )
        return AgentHarness(store: store, leaf: tree.leafID, configuration: configuration, seed: seed)
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
        // Loaded unconditionally, including for `leaf: nil`. The tip check below
        // is only one of the two things the file is needed for: the ordering-key
        // and accounting seeds are the other, and a harness pinned to an empty tip
        // over a written file that skipped the load would restart `seq` at zero and
        // collide with every entry already in it.
        let tree = try SessionTree.load(from: store)
        // Checked here rather than trusted: a harness whose tip is not in its file
        // cannot build a context or persist a child, and every read of it would
        // throw far from the call that chose the tip.
        if let leaf {
            guard tree.entry(withID: leaf) != nil else {
                throw DoMoError(
                    .file(path: path, errno: nil),
                    "Cannot open a session pinned to an entry that is not in the file: \(leaf)"
                )
            }
        }
        let seed = try Self.seed(
            store: store,
            entries: tree.entries,
            defaultModel: configuration.model,
            leafID: leaf
        )
        return AgentHarness(store: store, leaf: leaf, configuration: configuration, seed: seed)
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
    /// ``persistMessage(_:elapsedMs:)`` ("an interruption damages at most the final line").
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
        let seed = try Self.seed(
            store: store,
            entries: tree.entries,
            defaultModel: configuration.model,
            leafID: pinned
        )
        return AgentHarness(store: store, leaf: pinned, configuration: configuration, seed: seed)
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
        // Seeded from the fork's OWN file, not from this harness's counters: the
        // fork is a different session file whose entries were re-chained on the way
        // in, so what it already contains is the only authority on where its
        // numbering and its totals stand.
        let forkedTree = try SessionTree.load(from: forked)
        if let head = configuration.sessionStartHead {
            let checkpoint = SessionTreeEntry(
                id: configuration.entryIDFactory(),
                parentId: forkedTree.leafID,
                timestamp: JSONLSessionStore.iso8601(configuration.now()),
                payload: .sessionStart(head: head),
                seq: try forked.nextSequenceNumber()
            )
            try forked.appendEntry(checkpoint)
        }
        let updatedForkedTree = try SessionTree.load(from: forked)
        let seed = try Self.seed(
            store: forked,
            entries: updatedForkedTree.entries,
            defaultModel: configuration.model,
            leafID: updatedForkedTree.leafID
        )
        return AgentHarness(store: forked, leaf: updatedForkedTree.leafID, configuration: configuration, seed: seed)
    }

    /// Clone the active branch into an independent session. Clone is a named
    /// alias at the harness layer; the persisted header and re-chained entries
    /// use the same safe fork primitive, while the separate command gives clients
    /// a discoverable copy operation.
    public func clone(sessionDirectory: FilePath) throws -> AgentHarness {
        try fork(sessionDirectory: sessionDirectory)
    }

    // MARK: - Inspection

    /// The file this session persists to.
    public var sessionFilePath: FilePath { store.path }

    /// The current tip.
    public var currentLeafID: String? { leaf }

    /// The model selected for the active branch. This is recovered from the last
    /// `model_change` entry when a session is reopened.
    public var currentModel: String { activeModel }

    /// The latest Git HEAD checkpoint on the active session branch, if one was
    /// recorded. Older sessions simply return `nil`.
    public func sessionStartHead() throws -> String? {
        try SessionTree.load(from: store)
            .branch(from: leaf)
            .reversed()
            .compactMap { entry -> String? in
                if case .sessionStart(let head) = entry.payload { return head }
                return nil
            }
            .first
    }

    /// The most recent user-visible session name, if one was recorded.
    public func sessionName() throws -> String? {
        try SessionTree.latestSessionName(in: SessionTree.load(from: store).branch(from: leaf))
    }

    /// The current tip followed by the ancestors of it this harness itself knows,
    /// most recent first — see ``leafChain``.
    ///
    /// Ordered tip-first because that is the order a recovery wants to try them in:
    /// the tip if it can be had, then as little of the branch given up as possible.
    /// The list is what ``open(path:configuration:preferring:)`` consumes; it is
    /// empty exactly when the tip is.
    public var leafLineage: [String] { leafChain.reversed() }

    /// The current truth about workspace snapshot support. This is deliberately
    /// an async probe: a configured source may become unavailable after launch,
    /// and the UI must not keep showing a stale success state.
    public func workspaceStatus() async -> WorkspaceSnapshotStatus {
        guard let source = configuration.workspaceSnapshots else {
            workspaceStatusValue = .snapshotsDisabled
            return .snapshotsDisabled
        }
        guard workspaceStatusValue != .unavailable else { return .unavailable }
        let status = await source.availability()
        workspaceStatusValue = status
        return status
    }

    /// The append-only timeline, including metadata, workspace checkpoints, and
    /// history actions. A caller can render this without projecting it into model
    /// messages or mistaking a file snapshot for an assistant response.
    public func timeline() throws -> [SessionTreeEntry] {
        try SessionTree.load(from: store).entries
    }

    /// The messages the next turn would be seeded with, resolved from the current
    /// path exactly as ``run(prompt:sink:)`` resolves them.
    ///
    /// Exposed so a caller — and the resume test — can assert that a freshly opened
    /// harness reconstructs the identical context an uninterrupted run held.
    public func contextMessages() throws -> [Message] {
        try buildContextMessages()
    }

    /// Execute a catalog command without involving the model. Tool resolution
    /// still comes from the current session/model resolver, and the shared
    /// dispatcher runs permission and lifecycle hooks before invoking it.
    public func executeDirectTool(
        command: String,
        sink: (any AgentEventSink)? = nil
    ) async throws(DoMoError) -> DirectToolInvocation {
        guard !isRunning else {
            throw DoMoError(.configuration, "AgentHarness is already running a turn")
        }
        isRunning = true
        defer { isRunning = false }

        let tools: [any AgentTool]
        if let resolver = configuration.getTools {
            tools = await resolver(activeModel)
        } else {
            tools = configuration.tools
        }
        let parsed = try DirectToolCommandParser.parse(command, tools: tools)
        let call = ToolCallBlock(
            id: "direct-\(UUIDv7.generate().description)",
            name: parsed.name,
            arguments: parsed.arguments
        )
        let assistant = AssistantMessage(
            content: [.toolCall(call)],
            model: activeModel,
            stopReason: .toolUse
        )
        let loopConfig = AgentLoopConfig(
            model: activeModel,
            toolExecution: configuration.toolExecution,
            beforeToolCall: configuration.beforeToolCall,
            toolLifecycle: configuration.toolLifecycle,
            toolLifecycleTimeout: configuration.toolLifecycleTimeout
        )
        let eventSink: any AgentEventSink = sink ?? DirectToolDiscardingSink()
        let result = await executeDirectToolCall(
            call,
            from: assistant,
            tools: tools,
            config: loopConfig,
            sink: eventSink
        )
        return DirectToolInvocation(toolName: parsed.name, result: result)
    }

    /// Write a compaction checkpoint for the current branch immediately.
    ///
    /// This is the explicit counterpart to the automatic pre-turn check. It is
    /// intentionally allowed even when automatic compaction is disabled: a user
    /// who asks for `/compact` is making a one-shot context-management decision,
    /// not changing the setting for future turns. The operation is idle-only so a
    /// checkpoint cannot race a persistence sink that is advancing the leaf.
    ///
    /// - Returns: `true` when a checkpoint was written, or `false` when the current
    ///   branch has no complete older history that can be compacted.
    @discardableResult
    public func compactNow() async throws -> Bool {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot compact while a turn is running")
        }
        isRunning = true
        defer { isRunning = false }
        return try await compactIfNeeded(force: true)
    }

    /// What this session has spent and how full its context is.
    ///
    /// The single accounting surface. Every renderer of a footer, a `/cost`
    /// command, or a server status payload reads it here rather than keeping its
    /// own running sum, because two accumulators over the same session is how
    /// `--serve` and `--inline` come to report different numbers for it.
    ///
    /// Throws for the same reason ``contextMessages()`` does: the context size is
    /// measured off the resolved path, and a path with a structural hole cannot be
    /// resolved. Reporting a size for a conversation that cannot be rebuilt would
    /// be a number about nothing.
    ///
    /// **On resumed sessions.** The totals are seeded by walking the file, so they
    /// are only as good as what the file records. Entries written before Phase 5a
    /// carry a `usage` whose `cost` is zero and no gateway-reported cost at all —
    /// no rate table ever reached the client that wrote them — so a session
    /// resumed across that boundary under-reports the cost of its earlier half.
    /// Token counts are unaffected; they were always real.
    public func accounting() async throws -> SessionAccounting {
        let contextTokens = estimateContextTokens(try buildContextMessages()).tokens
        return SessionAccounting(
            usage: accumulatedUsage,
            // `effectiveCostTotal`, never `cost.total`: the latter silently drops a
            // price the gateway itself reported.
            costTotal: accumulatedUsage.effectiveCostTotal,
            contextTokens: contextTokens,
            contextWindow: activeContextWindow,
            turns: recordedTurns
        )
    }

    // MARK: - Session metadata and tree navigation

    /// Persist a model selection and make it the default for subsequent turns.
    public func selectModel(
        provider: String,
        modelId: String,
        streamFn: AgentStreamFn? = nil,
        contextWindow: Int? = nil
    ) throws {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot change models while a turn is running")
        }
        try appendMetadata(.modelChange(provider: provider, modelId: modelId))
        activeModel = modelId
        activeStreamFn = streamFn
            ?? configuration.streamFnForModel?(modelId)
            ?? configuration.streamFn
        activeContextWindow = contextWindow
            ?? configuration.contextWindowForModel?(modelId)
            ?? configuration.contextWindow
    }

    /// Persist a display name. Passing `nil` clears it.
    public func rename(_ name: String?) throws {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot rename a session while a turn is running")
        }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try appendMetadata(.sessionInfo(name: clean?.isEmpty == true ? nil : clean))
    }

    /// Ask the active model for a short display title when the session has no
    /// explicit name yet. The title request is metadata, not a conversation turn,
    /// so it is persisted on the `session_info` entry with its usage and never
    /// appears in the transcript context.
    public func autoTitle() async throws -> String? {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot title a session while a turn is running")
        }
        guard try sessionName() == nil else { return nil }
        let messages = try buildContextMessages()
        guard !messages.isEmpty else { return nil }
        let request = Context(
            systemPrompt: "You create concise session titles. Reply with only a descriptive title of at most six words. Do not use quotes, markdown, or punctuation at the end.",
            messages: Array(messages.suffix(12)) + [
                .user(UserMessage(content: [.text("Give this coding session a useful short title.")]))
            ],
            tools: []
        )
        var terminal: AssistantMessage?
        for try await event in activeStreamFn(request) {
            if let message = event.terminalMessage { terminal = message }
        }
        guard let terminal else {
            throw DoMoError(.provider(status: nil, isRetryable: false), "Title generation produced no response")
        }
        if let failure = terminal.failure { throw failure }
        let title = Self.cleanGeneratedTitle(terminal.text)
        guard !title.isEmpty else { return nil }
        try appendMetadata(.sessionInfo(name: title), usage: terminal.usage)
        return title
    }

    /// Ask the active model for a one-line commit message for a diff without
    /// persisting the request as a conversation turn.
    public func generateCommitMessage(diff: String) async throws -> String? {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot generate a commit message while a turn is running")
        }
        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiff.isEmpty else { return nil }
        let boundedDiff = String(trimmedDiff.prefix(80_000))
        let request = Context(
            systemPrompt: "You write concise Git commit subjects. Reply with one imperative subject line, at most 72 characters, with no quotes, markdown, or trailing punctuation.",
            messages: [
                .user(UserMessage(content: [.text(
                    "Write a commit subject for this working-tree diff:\n\n\(boundedDiff)"
                )]))
            ],
            tools: []
        )
        var terminal: AssistantMessage?
        for try await event in activeStreamFn(request) {
            if let message = event.terminalMessage { terminal = message }
        }
        guard let terminal else {
            throw DoMoError(.provider(status: nil, isRetryable: false), "Commit-message generation produced no response")
        }
        if let failure = terminal.failure { throw failure }
        let line = terminal.text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_\"'#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(72))
    }

    /// Persist a bookmark on an entry. A nil label clears the bookmark.
    public func setLabel(targetID: String, label: String?) throws {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot label a session while a turn is running")
        }
        guard try SessionTree.load(from: store).entry(withID: targetID) != nil else {
            throw DoMoError(.file(path: store.path, errno: nil), "Session entry not found: \(targetID)")
        }
        try appendMetadata(.label(targetId: targetID, label: label))
    }

    /// Persist a delegated child lifecycle event without adding it to model
    /// context. The runtime may call this while the parent is running; unlike
    /// user-facing metadata such as rename, delegation is part of that run and
    /// must remain appendable during it.
    public func recordSubagentEvent(_ event: SubagentTaskEvent) throws {
        try appendMetadata(.subagent(event))
    }

    /// Move the active leaf to another node, recording a summary of the abandoned
    /// suffix before the navigation entry.
    public func moveLeaf(to targetID: String?) async throws {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot navigate the tree while a turn is running")
        }
        let tree = try SessionTree.load(from: store)
        if let targetID, tree.entry(withID: targetID) == nil {
            throw DoMoError(.file(path: store.path, errno: nil), "Session entry not found: \(targetID)")
        }
        guard targetID != leaf else { return }

        let currentPath = try leaf.map { try tree.branch(from: $0) } ?? []
        let targetPath = try targetID.map { try tree.branch(from: $0) } ?? []
        var commonCount = 0
        while commonCount < currentPath.count,
              commonCount < targetPath.count,
              currentPath[commonCount].id == targetPath[commonCount].id {
            commonCount += 1
        }
        let abandoned = Array(currentPath.dropFirst(commonCount))
        if !abandoned.isEmpty, let fromID = leaf {
            let preparation = prepareBranchEntries(abandoned)
            var summary = try await summarizeBranch(
                preparation,
                fromId: fromID,
                id: store.createEntryID(),
                parentId: leaf,
                timestamp: timestamp(),
                summarize: effectiveSummarizer
            )
            summary.seq = nextSeq
            try store.appendEntry(summary)
            nextSeq += 1
            leafChain.append(summary.id)
            if case .branchSummary(let branch) = summary.payload, let usage = branch.usage {
                accumulatedUsage = accumulatedUsage + usage
            }
        }

        _ = try store.moveLeaf(to: targetID, timestamp: timestamp(), seq: nextSeq)
        nextSeq += 1
        let movedTree = try SessionTree.load(from: store)
        let movedPath = try targetID.map { try movedTree.branch(from: $0) } ?? []
        leafChain = movedPath.map(\.id)
        let model = movedPath.reversed().compactMap { entry -> String? in
            if case .modelChange(_, let modelID) = entry.payload { return modelID }
            return nil
        }.first ?? configuration.model
        activeModel = model
        activeStreamFn = configuration.streamFnForModel?(model) ?? configuration.streamFn
        activeContextWindow = configuration.contextWindowForModel?(model) ?? configuration.contextWindow
    }

    private func appendMetadata(_ payload: SessionTreeEntry.Payload, usage: Usage? = nil) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: payload,
            seq: nextSeq,
            metadataUsage: usage
        )
        try store.appendEntry(entry)
        nextSeq += 1
        leafChain.append(entry.id)
        if let usage { accumulatedUsage = accumulatedUsage + usage }
    }

    private static func cleanGeneratedTitle(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard folded.count > 80 else { return folded }
        return String(folded.prefix(77)) + "…"
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
            // `elapsedMs: nil` — a seal is synthesized, not produced by a tool that
            // ran, so there is no interval to report and `0` would be a claim.
            try persistMessage(
                .tool(ToolResultBlock(
                    toolCallID: call.id,
                    toolName: call.name,
                    output: reason,
                    isError: true
                )),
                elapsedMs: nil
            )
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
        sink: (any AgentEventSink)? = nil,
        runOverride: RunOverride? = nil,
        drainSteeringBeforeFirstTurn: Bool = true
    ) async throws -> AgentRunResult {
        let promptMessage = Message.user(
            UserMessage(content: [.text(prompt)] + attachments.map { .image($0) })
        )
        return try await run(
            messages: [promptMessage],
            sink: sink,
            runOverride: runOverride,
            drainSteeringBeforeFirstTurn: drainSteeringBeforeFirstTurn
        )
    }

    /// Runs a sequence of already-constructed messages to completion.
    ///
    /// This is the hand-off used when a server run finishes at the same moment
    /// that a steering message arrives: the queued message can become the first
    /// prompt of the next run without being converted back into lossy text.
    @discardableResult
    public func run(
        messages: [Message],
        sink: (any AgentEventSink)? = nil,
        runOverride: RunOverride? = nil,
        drainSteeringBeforeFirstTurn: Bool = true
    ) async throws -> AgentRunResult {
        guard !messages.isEmpty else {
            throw DoMoError(.configuration, "AgentHarness cannot run an empty message list")
        }
        guard !isRunning else {
            throw DoMoError(.configuration, "AgentHarness is already running a turn")
        }
        isRunning = true
        defer { isRunning = false }

        // Decorated first, before anything else in this method can look at the
        // prompt. The decorated string is the one that goes on the wire AND the
        // one that is persisted — `executeLoop` hands these exact messages to
        // the loop, whose ``SessionPersistenceSink`` writes them to the session
        // file — so the transcript, the exports and a resumed context all show
        // what the model was actually asked. Decorating any later would put a
        // sentence on the wire that no reader of the session ever sees, and the
        // two records of one turn would disagree.
        let prepared = await decorateWithResponseLimit(messages, runOverride: runOverride)
        let promptMessages = prepared.messages
        let responseLimitTicket = prepared.ticket

        // Capture the pre-prompt workspace before compaction or any transcript
        // entry can move the active tip. Failure disables workspace history for
        // this runtime but does not turn an otherwise usable coding run into a
        // provider failure.
        await ensureWorkspaceBaseline()
        _ = try await compactIfNeeded()

        // Read off the DECORATED messages deliberately: this string feeds
        // keyword-triggered skill selection, and matching against a prompt that
        // differs from the one the model receives is how a skill silently stops
        // firing for the turn that needed it.
        let systemPromptInput = promptMessages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.text
        }.first ?? ""

        // Steering is wrapped here rather than forwarded verbatim, and this is the
        // one seam where that can be done once. A message typed while a run is in
        // flight reaches the model through this closure and never through
        // ``run(messages:)``, so an unwrapped steering path puts the single prompt
        // on the wire that carries no limit sentence — on the surface where it is
        // most likely to be a long request, since the user is correcting a run they
        // are watching. Decorating inside the harness means the client, the inline
        // REPL and the server all get it without each re-implementing it, and
        // cannot drift apart afterwards.
        //
        // Both sources are resolved first and the wrapper is applied to whichever
        // one won, so neither can escape it.
        let steeringSource: (@Sendable () async -> [Message])?
        if let configured = configuration.getSteeringMessages {
            steeringSource = configured
        } else if let box = configuration.steeringBox {
            steeringSource = { @Sendable in box.drain() }
        } else {
            steeringSource = nil
        }
        let steeringMessages: (@Sendable () async -> [Message])?
        if let steeringSource, let limitController = configuration.responseLimit {
            let limitModel = runOverride?.model ?? activeModel
            steeringMessages = { @Sendable in
                let drained = await steeringSource()
                guard !drained.isEmpty else { return drained }
                // The ticket is deliberately DISCARDED, so a steering message is
                // decorated and never recorded.
                //
                // A run holds exactly one ticket, and it describes the decorated
                // request the run was issued for. Keeping the steering ticket
                // instead would silently substitute a different offered limit for
                // the one the run is measuring; keeping both would fold two
                // outcomes out of one settled result, which the policy reads as
                // two independent observations of a gateway that answered once —
                // enough, on its own, to trip the two-failures-in-a-row back-off
                // from a single failure.
                //
                // The cost is that a limit offered on a steering message teaches
                // nothing, and that a probe cadence slot can be spent on a turn
                // whose answer is never scored. That is a lost probe, which the
                // next prompt re-offers. The alternative is wrong arithmetic on
                // the value the whole feature exists to learn.
                // Spelled with the type's own name rather than `Self`, so nothing
                // about this closure can be read — by a compiler or by a reader —
                // as capturing the harness instance it was built inside.
                return await AgentHarness.applyingResponseLimit(
                    to: drained,
                    controller: limitController,
                    model: limitModel
                ).messages
            }
        } else {
            steeringMessages = steeringSource
        }

        let followUpMessages: (@Sendable () async -> [Message])?
        if let configured = configuration.getFollowUpMessages {
            followUpMessages = configured
        } else if let box = configuration.followUpBox {
            followUpMessages = { @Sendable in box.drain() }
        } else {
            followUpMessages = nil
        }

        let systemPrompt = runOverride?.systemPrompt
            ?? configuration.systemPromptForPrompt?(systemPromptInput)
            ?? configuration.systemPrompt
        let systemPromptForTools: (@Sendable (String, [String]) -> String?)?
        if runOverride?.systemPrompt != nil {
            systemPromptForTools = nil
        } else if let configured = configuration.systemPromptForPromptAndTools {
            systemPromptForTools = { _, toolNames in
                configured(systemPromptInput, toolNames)
            }
        } else {
            systemPromptForTools = nil
        }
        let loopConfig = AgentLoopConfig(
            model: runOverride?.model ?? activeModel,
            toolExecution: configuration.toolExecution,
            maxTurns: configuration.maxTurns,
            beforeToolCall: configuration.beforeToolCall,
            toolLifecycle: configuration.toolLifecycle,
            toolLifecycleTimeout: configuration.toolLifecycleTimeout,
            getSteeringMessages: steeringMessages,
            drainSteeringBeforeFirstTurn: drainSteeringBeforeFirstTurn,
            getFollowUpMessages: followUpMessages,
            shouldStopAfterTurn: configuration.shouldStopAfterTurn,
            onNoProgress: configuration.onNoProgress,
            maxCostPerRun: configuration.maxCostPerRun,
            getTools: configuration.getTools,
            systemPromptForTools: systemPromptForTools,
            recoveryDiagnostic: configuration.recoveryDiagnostic,
            recoveryDiagnosticTimeout: configuration.recoveryDiagnosticTimeout,
            recoveryDiagnosticMaxOutputTokens: configuration.recoveryDiagnosticMaxOutputTokens,
            recoveryDiagnosticTools: configuration.recoveryDiagnosticTools
        )
        let errorBox = PersistenceErrorBox()
        let streamFn = runOverride?.streamFn ?? activeStreamFn

        /// Run the loop against a supplied context. The overflow retry calls
        /// this with no prompts after it has written a compaction checkpoint;
        /// replaying the original prompt there would duplicate it in the next
        /// model request and in the session file.
        func executeLoop(prompts: [Message], contextMessages: [Message]) async -> AgentRunResult {
            let context = AgentContext(
                systemPrompt: systemPrompt,
                messages: contextMessages,
                tools: configuration.tools
            )
            let persistenceSink = SessionPersistenceSink(
                persister: self,
                forward: sink,
                errorBox: errorBox,
                monotonicNow: configuration.monotonicNow
            )
            return await runAgentLoop(
                prompts: prompts,
                context: context,
                config: loopConfig,
                sink: persistenceSink,
                streamFn: streamFn
            )
        }

        var result = await executeLoop(
            prompts: promptMessages,
            contextMessages: try buildContextMessages()
        )

        // An explicit provider overflow is the common case. The message helper
        // also catches providers that silently accept an oversized input or
        // truncate it to a length-stop with no output. The latch is deliberately
        // scoped to this run: if the compacted request overflows again, the
        // second result is returned and no recovery loop can form.
        if needsOverflowRecovery(result), errorBox.first == nil {
            do {
                if try await compactAfterOverflow() {
                    let retry = await executeLoop(
                        prompts: [],
                        contextMessages: try buildContextMessages()
                    )
                    result = AgentRunResult(
                        messages: result.messages + retry.messages,
                        stopReason: retry.stopReason,
                        failure: retry.failure
                    )
                }
            } catch {
                // Preserve the provider failure that caused recovery. A
                // summarizer failure is not allowed to masquerade as a new
                // successful turn, and the original transcript remains intact.
            }
        }

        // What the DECORATED request is answerable for, read here and never again:
        // after overflow recovery, strictly before the first continuation attempt.
        //
        // The ticket describes one request — the one carrying the limit sentence.
        // The continuation asks a different question, with the harness's own
        // undecorated words and no limit on them at all, so reading the merged
        // result would let the continuation's long answer stand as proof that the
        // probe the gateway had just refused was delivered. That is not a rounding
        // error in the learning: it promotes the ceiling to the exact value the
        // gateway declined, and since a promotion is only undone by fresh failures
        // *at the new height*, the ratchet goes up and cannot come back down.
        //
        // Cancellation is sampled at the same instant for the same reason. The
        // continuation loop is the only suspension between here and the recording
        // below, and it runs only while `result.failure` is non-nil — so a run
        // whose evidence is `.delivered` reaches the record call with nothing
        // awaited in between, and a late interrupt has no path by which to turn a
        // refusal into a delivery.
        let responseLimitObservation = ResponseLimitObservation(
            evidence: Self.responseLimitEvidence(
                stopReason: result.stopReason,
                failure: result.failure,
                cancelled: Task.isCancelled
            ),
            characters: Self.longestAssistantText(in: result.messages)
        )

        // Gateway continuation, strictly downstream of overflow recovery: an
        // over-window request is repaired by compacting and re-asking, and only
        // a failure that survives *that* is a candidate for "the gateway hung up
        // while the model was still talking". Running it first would send a
        // "continue" prompt into a context that cannot fit, which cannot succeed
        // and would burn the whole attempt budget proving it.
        //
        // Termination is by construction, not by argument. `continuationAttempts`
        // rises once per iteration and is bounded by a cap that
        // ``GatewayContinuationSettings/effectiveMaxAttempts`` has already
        // clamped; a cancelled task stops it before another request; a
        // persistence error stops it, because a run that cannot record its
        // transcript must not grow one; a context that will not rebuild breaks
        // out rather than retrying the same unbuildable context; a failure that
        // is not a gateway timeout never enters it; and a retry that succeeds
        // clears `result.failure`, which is the condition that admitted it.
        let continuationCap = configuration.gatewayContinuation.effectiveMaxAttempts
        var continuationAttempts = 0
        while continuationAttempts < continuationCap,
              errorBox.first == nil,
              !Task.isCancelled,
              let failure = result.failure,
              failure.isGatewayTimeout {
            continuationAttempts += 1
            // Announced before the request, not after it: the point of the
            // notice is that a user watching a run that has been quiet for two
            // minutes learns it is still being driven. `warning`, matching the
            // retry notice — the turn has not failed, it is being carried on.
            await sink?.emit(.notice(AgentNotice(
                level: .warning,
                code: "gateway_continue",
                text: "Gateway timed out — continuing (\(continuationAttempts)/\(continuationCap))",
                detail: DoMoError.truncating(Redaction.diagnostic(failure.message), to: 200),
                kind: failure.kind.label
            )))
            // Rebuilt every iteration rather than reused: the timed-out turn
            // persisted its own partial transcript, and the continuation must be
            // asked against what the file now holds — otherwise the model is
            // asked to continue from a conversation missing the turn it is being
            // asked to continue.
            let contextMessages: [Message]
            do {
                contextMessages = try buildContextMessages()
            } catch {
                break
            }
            // NOT decorated with the response limit. The continuation prompt is
            // the harness's own words, not the user's turn, and a limit sentence
            // on it would both re-cap a response the user already asked to be
            // capped and make the ticket's accounting nonsense — the outcome is
            // recorded against the ONE limit this run offered.
            let retry = await executeLoop(
                prompts: [.user(UserMessage(content: [.text(configuration.gatewayContinuation.message)]))],
                contextMessages: contextMessages
            )
            result = AgentRunResult(
                messages: result.messages + retry.messages,
                stopReason: retry.stopReason,
                failure: retry.failure
            )
        }

        // Recorded before the persistence error is surfaced. A transcript that
        // could not be written is a failure of this process's filesystem and
        // says nothing whatever about what the gateway was willing to return,
        // which is the only question the learned ceiling answers.
        //
        // `responseLimitObservation`, never `result`: by this line `result` may
        // have been rewritten by one or more continuations, and those describe an
        // undecorated request this ticket was never issued for.
        if let ticket = responseLimitTicket {
            await recordResponseLimitOutcome(ticket, observation: responseLimitObservation)
        }

        if let error = errorBox.first {
            throw DoMoError(.file(path: store.path, errno: nil), "Failed to persist session transcript", cause: error)
        }
        return result
    }

    // MARK: - Adaptive response limit

    /// Appends the adaptive response-character limit to the prompt this run is
    /// about to send, returning the messages to run and the ticket the settled
    /// run is recorded against.
    ///
    /// The **last** `.user` message is the one decorated, because that is this
    /// turn's prompt; anything before it is history a caller replayed and
    /// re-capping it would put a second instruction into the model's context
    /// with no turn to apply it to. Within that message the **last** text block
    /// is rewritten, so an image-plus-caption prompt keeps its images and their
    /// ordering; a prompt with no text at all — an image-only turn — gains one
    /// rather than being the single case that silently escapes the limit.
    ///
    /// Returns the input unchanged, with a `nil` ticket, whenever there is no
    /// controller or no user message to decorate. A `nil` ticket is what makes
    /// ``recordResponseLimitOutcome(_:observation:)`` a no-op, so an undecorated
    /// run can never teach the ceiling anything.
    private func decorateWithResponseLimit(
        _ messages: [Message],
        runOverride: RunOverride?
    ) async -> (messages: [Message], ticket: ResponseLimitController.Ticket?) {
        guard let controller = configuration.responseLimit else { return (messages, nil) }
        // The model that will actually answer, which a per-command override can
        // change for one turn. The ceiling is learned per alias, so charging a
        // probe to the session's default model when a different one answered
        // would teach the wrong row.
        return await Self.applyingResponseLimit(
            to: messages,
            controller: controller,
            model: runOverride?.model ?? activeModel
        )
    }

    /// Puts the limit sentence on the last `.user` message of `messages`, using
    /// `controller`, and returns the ticket that request is owed back.
    ///
    /// `static`, and reading none of the harness's state, because it has two
    /// callers that must decorate *identically* and one of them is not on the
    /// actor: the steering wrapper runs inside the agent loop while
    /// ``run(messages:)`` is suspended on that loop, and hopping back onto the
    /// harness there would serialize a decoration behind the very run that is
    /// waiting for it. One implementation is also the only way the prompt path and
    /// the steering path cannot drift into decorating differently.
    private static func applyingResponseLimit(
        to messages: [Message],
        controller: ResponseLimitController,
        model: String
    ) async -> (messages: [Message], ticket: ResponseLimitController.Ticket?) {
        let promptIndex = messages.lastIndex { message in
            if case .user = message { return true }
            return false
        }
        guard let promptIndex, case .user(var user) = messages[promptIndex] else {
            return (messages, nil)
        }
        let textIndex = user.content.lastIndex { $0.textBlock != nil }
        let original = textIndex.flatMap { user.content[$0].textBlock?.text } ?? ""
        let decorated = await controller.decorate(original, model: model)
        if let textIndex {
            user.content[textIndex] = .text(decorated.text)
        } else {
            user.content.append(.text(decorated.text))
        }
        var updated = messages
        updated[promptIndex] = .user(user)
        return (updated, decorated.ticket)
    }

    /// What the decorated request — and only the decorated request — is
    /// answerable for.
    ///
    /// A value rather than two locals so the capture is a single statement that a
    /// later edit cannot half-move: the evidence and the length have to be read
    /// off the same result at the same instant, or the pair describes two
    /// different requests and means nothing.
    private struct ResponseLimitObservation: Sendable {
        var evidence: ResponseLimitEvidence
        var characters: Int
    }

    /// What one settled result says about the gateway's willingness to return a
    /// response of the offered length.
    ///
    /// The three answers are not "success, failure, maybe". They are three
    /// different questions the same result can answer, and folding any two of them
    /// together is what produced a learned ceiling that could only ever fall:
    ///
    /// - ``ResponseLimitEvidence/delivered`` — the gateway answered. How much it
    ///   returned is real evidence about where the ceiling is.
    /// - ``ResponseLimitEvidence/refusedPlausiblyForLength`` — the request died in
    ///   one of the few shapes an undocumented length cap actually takes on this
    ///   deployment. The gateway times out rather than saying "too long" (that is
    ///   the whole reason this feature exists); a proxy in front of it returns a
    ///   retryable 5xx; or the answer arrives cut off into something the decoder
    ///   cannot finish reading. None of those *prove* it was the length. They are
    ///   the only failures that could be, which is exactly what the binary search
    ///   needs in order to bound itself from above.
    /// - ``ResponseLimitEvidence/inconclusive`` — everything else. A refused
    ///   credential, a throttle, an exhausted budget, a context overflow, a bad
    ///   setting, a tool that failed, a connection that never reached the gateway,
    ///   and a turn the user interrupted all say precisely nothing about how many
    ///   characters would have come back. Counted as failures, two of them in a row
    ///   used to back the threshold down and write a bad point at the old one —
    ///   which is how a short outage pinned a healthy gateway's ceiling at the
    ///   floor for the life of the machine.
    ///
    /// Note the failure that is deliberately *not* in the middle case: a
    /// ``DoMoError/Kind/transport`` whose prose never mentions a timeout — a
    /// refused connection — is inconclusive, because nothing on the far side ever
    /// got the chance to refuse anything.
    private static func responseLimitEvidence(
        stopReason: RunStopReason,
        failure: DoMoError?,
        cancelled: Bool
    ) -> ResponseLimitEvidence {
        // Checked before the failure, because an interrupt is the one outcome that
        // can arrive wearing another failure's clothes: tearing down an in-flight
        // socket surfaces as an arbitrary transport error, and a stream torn down
        // mid-answer says "timed out" as readily as a gateway that gave up.
        if cancelled || stopReason == .aborted { return .inconclusive }
        guard let failure else {
            // No failure at all: the turn ran to a stop reason of its own — it
            // completed, hit a turn or cost budget, was stopped by a hook, or was
            // ended by a tool. Every one of those got an answer out of the gateway,
            // which is the only thing this measures.
            return .delivered
        }
        if failure.isCancellation { return .inconclusive }
        if failure.isGatewayTimeout { return .refusedPlausiblyForLength }
        switch failure.kind {
        case .malformedResponse:
            // A response the decoder could not finish reading is the shape a
            // silently truncated answer takes by the time it reaches here.
            return .refusedPlausiblyForLength
        case .provider(let status, let isRetryable):
            // A retryable 5xx from a proxy that is not one of the named timeout
            // statuses — 500 or 503 from a gateway that gave up on a long
            // generation. A 4xx is the model or the request being refused on its
            // merits and is not evidence about length; a non-retryable 5xx is the
            // layer that saw the body saying this will fail again identically.
            guard let status, isRetryable, (500..<600).contains(status) else { return .inconclusive }
            return .refusedPlausiblyForLength
        case .transport, .authentication, .rateLimit, .quotaExhausted, .contextOverflow,
            .toolExecution, .file, .cancelled, .configuration:
            return .inconclusive
        }
    }

    /// The LONGEST assistant text in `messages`, not the sum and not the last.
    ///
    /// The question the ceiling answers is "how much did the gateway deliver
    /// intact in one response", so a multi-turn run's total would claim credit no
    /// single response earned, and its last turn — routinely a one-line wrap-up
    /// after a tool loop — would throw away the evidence the run actually produced.
    private static func longestAssistantText(in messages: [Message]) -> Int {
        messages.reduce(into: 0) { longest, message in
            guard case .assistant(let assistant) = message else { return }
            longest = max(longest, assistant.text.count)
        }
    }

    /// Feeds one settled decorated request back into the adaptive
    /// response-character limit.
    ///
    /// Cancelled and otherwise unrelated failures are recorded as
    /// ``ResponseLimitEvidence/inconclusive`` rather than skipped. The two are
    /// equivalent to the learned values — `.inconclusive` is defined as touching
    /// none of them — and having one path rather than a guard plus a path is what
    /// stops the next person from adding a fourth outcome that quietly falls
    /// through the guard as a success.
    private func recordResponseLimitOutcome(
        _ ticket: ResponseLimitController.Ticket,
        observation: ResponseLimitObservation
    ) async {
        guard let controller = configuration.responseLimit else { return }
        await controller.record(
            ticket,
            evidence: observation.evidence,
            responseCharacters: observation.characters
        )
    }

    /// Whether a settled loop result is recoverable by compacting the branch
    /// immediately before its final assistant entry.
    private func needsOverflowRecovery(_ result: AgentRunResult) -> Bool {
        if case .contextOverflow = result.failure?.kind { return true }
        guard result.stopReason == .errored || result.stopReason == .completed,
              let assistant = result.messages.reversed().compactMap({ message -> AssistantMessage? in
                  guard case .assistant(let assistant) = message else { return nil }
                  return assistant
              }).first
        else { return false }

        // A successful stop with an over-window input is compacted before the
        // next prompt, but it already contains a usable answer and must not be
        // replayed. A length-stop with no output is the provider's truncation
        // form of overflow and does need the one recovery request.
        return isContextOverflow(assistant, contextWindow: activeContextWindow)
    }

    // MARK: - Persistence

    private func timestamp() -> String {
        JSONLSessionStore.iso8601(configuration.now())
    }

    private func buildContextMessages() throws -> [Message] {
        // An empty tip means an empty branch — NOT "ask the file". The resolvers
        // below read `nil` as "start from the file's leaf", which is right for a
        // cold read of a file and wrong for a harness that knows its own branch has
        // nothing on it: ``persistMessage(_:elapsedMs:)`` writes the next entry with
        // `parentId: leaf`, i.e. as a new root, so a context resolved from someone
        // else's leaf would seed a turn with a conversation this branch is not on
        // and then answer it in a different place. Same-answering for every harness
        // that could exist before ``open(path:configuration:leaf:)`` (a `nil` tip
        // only ever came with an empty file); load-bearing for the ones that can now.
        guard let leaf else { return [] }
        let outputPolicy = ContextOutputPolicy(
            spillDirectory: "\(store.path.string).context-output"
        )
        return try ContextBuilder.buildContext(
            SessionTree.load(from: store),
            from: leaf,
            outputPolicy: outputPolicy
        )
    }

    // MARK: - Workspace checkpoints

    /// Captures the worktree before the first prompt of a run. This entry is
    /// separate from the prompt message so undo can return to the exact
    /// conversation/file pair that existed before the run began.
    private func ensureWorkspaceBaseline() async {
        guard let source = configuration.workspaceSnapshots else {
            workspaceStatusValue = .snapshotsDisabled
            return
        }
        guard workspaceSnapshotID == nil else { return }
        do {
            let snapshot = try await source.track(from: nil)
            try appendWorkspaceCheckpoint(snapshot)
            workspaceSnapshotID = snapshot.id
            workspaceStatusValue = .restored
        } catch {
            // Snapshot support is an enhancement around the core transcript. A
            // missing Git worktree or an unreadable shadow directory disables the
            // enhancement for this run; it must not discard the user's prompt.
            workspaceStatusValue = .unavailable
        }
    }

    private func appendWorkspaceCheckpoint(_ snapshot: WorkspaceSnapshot) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: .workspaceCheckpoint(snapshot),
            seq: nextSeq
        )
        try store.appendEntry(entry)
        nextSeq += 1
        leafChain.append(entry.id)
    }

    // MARK: - Compaction

    /// The effective summarizer: the injected one, or a default that runs a
    /// one-shot summarization request through the same ``streamFn`` the run uses.
    ///
    /// Building it from `streamFn` rather than a stored `LiteLLMClient` is what lets
    /// "default to the same LLM client" hold without this module depending on a
    /// concrete client. The request carries ``CompactionPrompts/system`` and a
    /// trailing ``CompactionPrompts/instruction``; the terminal assistant message's
    /// text is the summary and **its usage is the price of producing it**, which is
    /// the only point at which summarization cost can enter the session's totals.
    /// A failed terminal turn throws, so compaction that could not summarize writes
    /// no entry — the correct outcome for a context that cannot be bounded.
    private var effectiveSummarizer: Summarizer {
        if let summarizer = configuration.summarizer { return summarizer }
        let streamFn = activeStreamFn
        return { messages in
            let request = Context(
                systemPrompt: CompactionPrompts.system,
                messages: messages + [.user(CompactionPrompts.instruction)],
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
            return SummarizerResult(text: terminal.text, usage: terminal.usage)
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
    ///
    /// This is where ``AgentHarness/Configuration/fallbackContextWindow`` earns its
    /// place. An unknown window is not a reason to stop bounding the context: an
    /// unbounded session grows until the provider rejects it, which is a harder
    /// failure than compacting a little early against a guess.
    private func compactIfNeeded(force: Bool = false) async throws -> Bool {
        // Re-clamped rather than trusting the constructor's clamp: `contextWindow`
        // and `compaction` are both `var`s on a struct the caller keeps, so the
        // pairing can be broken after construction. Idempotent when it already
        // holds.
        let window = activeContextWindow ?? Configuration.fallbackContextWindow
        let settings = configuration.compaction.clamped(toContextWindow: window)
        guard force || settings.enabled else { return false }
        // Same reason as ``buildContextMessages()``: an empty tip is an empty branch,
        // and resolving `nil` here would measure — and then summarize — a path this
        // harness is not on, anchoring the checkpoint it writes at the root.
        guard let tip = leaf else { return false }
        let tree = try SessionTree.load(from: store)
        let pathEntries = try tree.pathToRootOrCompaction(from: tip)
        let messages = try ContextBuilder.messages(
            for: pathEntries,
            outputPolicy: ContextOutputPolicy(
                spillDirectory: "\(store.path.string).context-output"
            )
        )
        let estimate = estimateContextTokens(messages)
        guard force || shouldCompact(contextTokens: estimate.tokens, contextWindow: window, settings: settings) else {
            return false
        }
        guard let preparation = prepareCompaction(pathEntries: pathEntries, settings: settings) else {
            return false
        }
        // Timed here rather than in the sink, because a compaction checkpoint is
        // not a `Message` and never passes through the event stream — the sink can
        // never see it, so this is the only place its duration exists.
        let startedAt = configuration.monotonicNow()
        var entry = try await compact(
            preparation,
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            summarize: effectiveSummarizer
        )
        entry.elapsedMs = elapsedMilliseconds(from: startedAt, to: configuration.monotonicNow())
        entry.seq = nextSeq
        try store.appendEntry(entry)
        nextSeq += 1
        leafChain.append(entry.id)
        // The summarization request is a billable model call. Folded here, at the
        // one place a compaction entry is appended, so it reaches the same total
        // every assistant turn does.
        if case .compaction(let compaction) = entry.payload, let usage = compaction.usage {
            accumulatedUsage = accumulatedUsage + usage
        }
        return true
    }

    /// Compact the active branch after an overflow that happened during a
    /// request. The failed assistant entry is already useful history, so it is
    /// left on disk, but the new checkpoint is parented to the entry before it
    /// and becomes the active leaf. This keeps the retry context free of the
    /// provider's error message without requiring destructive edits to JSONL.
    ///
    /// Returns `false` when there is no complete turn boundary to summarize.
    /// A single oversized prompt cannot be made smaller by this compactor; the
    /// caller then returns the original overflow rather than retrying unchanged.
    private func compactAfterOverflow() async throws -> Bool {
        let window = activeContextWindow ?? Configuration.fallbackContextWindow
        let settings = configuration.compaction.clamped(toContextWindow: window)
        guard settings.enabled, let failedID = leaf else { return false }

        let tree = try SessionTree.load(from: store)
        guard let failed = tree.entry(withID: failedID),
              case .message(.assistant) = failed.payload,
              let parentID = failed.parentId
        else { return false }

        let pathEntries = try tree.pathToRootOrCompaction(from: parentID)
        guard let preparation = prepareCompaction(pathEntries: pathEntries, settings: settings) else {
            return false
        }

        let startedAt = configuration.monotonicNow()
        var entry = try await compact(
            preparation,
            id: store.createEntryID(),
            parentId: parentID,
            timestamp: timestamp(),
            summarize: effectiveSummarizer
        )
        entry.elapsedMs = elapsedMilliseconds(from: startedAt, to: configuration.monotonicNow())
        entry.seq = nextSeq
        try store.appendEntry(entry)
        nextSeq += 1

        // The physical append makes this checkpoint the file's leaf even though
        // its parent intentionally skips the failed assistant entry. Rebuild the
        // in-memory lineage from the checkpoint so the next message follows the
        // same active branch that a reopened harness will see.
        let activeTree = try SessionTree.load(from: store)
        leafChain = try activeTree.branch(from: entry.id).map(\.id)
        if case .compaction(let compaction) = entry.payload, let usage = compaction.usage {
            accumulatedUsage = accumulatedUsage + usage
        }
        return true
    }
}

// MARK: - Session accounting

/// What a session has spent, and how much room it has left.
///
/// A snapshot value, produced by ``AgentHarness/accounting()``, so a renderer
/// holds a consistent set of numbers rather than sampling four properties that
/// can move between reads.
public struct SessionAccounting: Sendable, Hashable, Codable {
    /// Cumulative token usage across the whole session file: every assistant turn,
    /// plus every compaction and branch summary the session paid for.
    public var usage: Usage

    /// Cumulative cost, always ``DoMoLLM/Usage/effectiveCostTotal`` and never
    /// `cost.total` — the latter silently discards a price the gateway reported.
    public var costTotal: Decimal

    /// The size of the context the *next* turn would send.
    public var contextTokens: Int

    /// The model's window, or `nil` when it is genuinely unknown.
    ///
    /// A meter must render `nil` as "unknown" and not as a percentage: the
    /// fallback compaction uses is a safety net, and a percentage computed against
    /// it is indistinguishable on screen from one computed against a real number.
    public var contextWindow: Int?

    /// Assistant turns recorded in the session file.
    public var turns: Int

    public init(usage: Usage, costTotal: Decimal, contextTokens: Int, contextWindow: Int?, turns: Int) {
        self.usage = usage
        self.costTotal = costTotal
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.turns = turns
    }

    // MARK: - Wire form

    /// Written by hand for one field: ``costTotal``.
    ///
    /// This value is published over the REST surface, and a `Decimal` encoded by
    /// the synthesized conformance goes out as a JSON **number**. Swift reads that
    /// back into a `Decimal` losslessly; nothing else does. A JavaScript client
    /// parses `0.000003` into the nearest IEEE double and then accumulates the
    /// error the type exists to avoid — see ``DoMoLLM/Cost``, "`Decimal` and not
    /// `Double`", and `PrintUsageEncoding.decimalString`, which already emits the
    /// print stream's cost as a string for exactly this reason. Two published
    /// surfaces spelling the same quantity two incompatible ways is the drift, not
    /// merely the risk of it.
    ///
    /// So it encodes as its `description` — the exact decimal digits — and decodes
    /// from **either** a string or a number, which is what lets a payload written
    /// by an older server still read here without a protocol version bump. The
    /// tolerance is on the reading side only and deliberately: the wire form has
    /// one spelling, and it is the lossless one.
    ///
    /// Everything else keeps the synthesized shape exactly, ``contextWindow``
    /// included: it stays `encodeIfPresent`, so an unknown window writes no key
    /// rather than a `null` a reader could mistake for a number.
    private enum CodingKeys: String, CodingKey {
        case usage
        case costTotal
        case contextTokens
        case contextWindow
        case turns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usage: try container.decode(Usage.self, forKey: .usage),
            costTotal: try Self.decodeDecimal(from: container, forKey: .costTotal),
            contextTokens: try container.decode(Int.self, forKey: .contextTokens),
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow),
            turns: try container.decode(Int.self, forKey: .turns)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usage, forKey: .usage)
        try container.encode(costTotal.description, forKey: .costTotal)
        try container.encode(contextTokens, forKey: .contextTokens)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encode(turns, forKey: .turns)
    }

    /// A decimal written either as a string (what this type now emits) or as a
    /// JSON number (what it used to emit, and what an older peer still sends).
    ///
    /// A string that is not a decimal is an error rather than a zero: a total that
    /// could not be read is not a total of nothing.
    ///
    /// The string is read through ``DoMoLLM/DecimalText/strict(_:)`` and never
    /// through bare `Decimal(string:)`, which is the same defence
    /// `LiteLLM.parseResponseCost` applies to `x-litellm-response-cost` and for
    /// the same reasons: `Decimal(string:)` **prefix**-parses, so `"0.25 dollars"`
    /// and `"0.25xyz"` both come back as `0.25` — a plausible number nobody sent,
    /// silently accepted as a session's whole spend — and `"1_000"` comes back as
    /// `1`, off by three orders of magnitude. It is locale-influenced too, so the
    /// same payload read under a comma-decimal locale means something else. This
    /// is a published REST surface; a body that does not match the grammar is a
    /// body this cannot read, and saying so is the only honest answer.
    private static func decodeDecimal(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal {
        guard let text = try? container.decode(String.self, forKey: key) else {
            return try container.decode(Decimal.self, forKey: key)
        }
        guard let value = DecimalText.strict(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Expected a decimal number spelled as a string; got \"\(text)\""
            )
        }
        return value
    }
}

// MARK: - Persistence conformance

/// The explicit outcome shown by `/undo` and `/redo` surfaces.
public struct WorkspaceHistoryResult: Sendable, Hashable, Codable {
    public let operation: SessionHistoryOperation
    public let status: WorkspaceSnapshotStatus
    public let moved: Bool
    public let fromEntryID: String?
    public let targetEntryID: String?
    public let restoredPaths: [String]
    public let skippedPaths: [String]
    public let failedPaths: [String]

    public init(
        operation: SessionHistoryOperation,
        status: WorkspaceSnapshotStatus,
        moved: Bool,
        fromEntryID: String? = nil,
        targetEntryID: String? = nil,
        restoredPaths: [String] = [],
        skippedPaths: [String] = [],
        failedPaths: [String] = []
    ) {
        self.operation = operation
        self.status = status
        self.moved = moved
        self.fromEntryID = fromEntryID
        self.targetEntryID = targetEntryID
        self.restoredPaths = restoredPaths
        self.skippedPaths = skippedPaths
        self.failedPaths = failedPaths
    }

    public var isComplete: Bool {
        moved && status == .restored && skippedPaths.isEmpty && failedPaths.isEmpty
    }
}

extension AgentHarness: SessionMessagePersisting {
    /// Appends `message` as a child of the current tip and advances the tip to it.
    ///
    /// Actor-isolated, so the ``SessionPersistenceSink`` calling in from the loop's
    /// executor is serialized onto the actor: appends land in the emit order the
    /// loop produces, which is transcript order, so the file is a faithful,
    /// resumable replay. The append is crash-safe (one line, `write`-then-return),
    /// so an interruption damages at most the final line.
    ///
    /// This is also the single funnel every assistant turn passes through, which is
    /// why the session's running totals are folded here: one call site, so no
    /// future append path can add a turn to the transcript and forget to add it to
    /// the bill.
    public func persistMessage(_ message: Message, elapsedMs: Int?) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: .message(message),
            seq: nextSeq,
            elapsedMs: elapsedMs
        )
        try store.appendEntry(entry)
        // After the append, never before: a throwing write must not burn an
        // ordering key, and must not bill a turn that was never recorded.
        nextSeq += 1
        leafChain.append(entry.id)
        if case .assistant(let assistant) = message {
            accumulatedUsage = accumulatedUsage + assistant.usage
            recordedTurns += 1
        }
    }
}

extension AgentHarness: SessionRecoveryPersisting {
    /// Appends a bounded recovery record after the run has settled. Recovery
    /// metadata is a real tree node so it survives resume and export, but the
    /// context builder deliberately projects it to no model message.
    public func persistRecovery(_ envelope: RecoveryEnvelope) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: .recovery(envelope),
            seq: nextSeq
        )
        try store.appendEntry(entry)
        nextSeq += 1
        leafChain.append(entry.id)
    }
}

extension AgentHarness: SessionWorkspaceCheckpointing {
    /// Append a private shadow-Git observation after each settled agent turn.
    ///
    /// Source failures become an explicit `unavailable` status and leave the
    /// conversation usable. A JSONL append failure remains throwing because it
    /// is transcript loss, not an optional workspace enhancement.
    public func persistWorkspaceCheckpoint() async throws {
        guard let source = configuration.workspaceSnapshots else {
            workspaceStatusValue = .snapshotsDisabled
            return
        }

        let snapshot: WorkspaceSnapshot
        do {
            snapshot = try await source.track(from: workspaceSnapshotID)
        } catch {
            workspaceStatusValue = .unavailable
            return
        }

        do {
            try appendWorkspaceCheckpoint(snapshot)
        } catch {
            workspaceStatusValue = .unavailable
            throw error
        }
        workspaceSnapshotID = snapshot.id
        workspaceStatusValue = .restored
    }
}

// MARK: - Workspace undo and redo

extension AgentHarness {
    /// Restore the previous checkpoint and move the active conversation tip to
    /// the same checkpoint. The operation is append-only: the history action is
    /// written physically at the current tip, then the recovered leaf points at
    /// the target ancestor.
    public func undo() async throws -> WorkspaceHistoryResult {
        try await moveWorkspaceHistory(.undo)
    }

    /// Reapply the most recent undo when no new conversation or navigation entry
    /// has superseded it.
    public func redo() async throws -> WorkspaceHistoryResult {
        try await moveWorkspaceHistory(.redo)
    }

    private func moveWorkspaceHistory(_ operation: SessionHistoryOperation) async throws -> WorkspaceHistoryResult {
        guard !isRunning else {
            throw DoMoError(.configuration, "Cannot change workspace history while a turn is running")
        }
        guard let source = configuration.workspaceSnapshots else {
            return WorkspaceHistoryResult(operation: operation, status: .snapshotsDisabled, moved: false)
        }

        let available = await workspaceStatus()
        guard available != .unavailable else {
            return WorkspaceHistoryResult(operation: operation, status: .unavailable, moved: false)
        }

        let tree = try SessionTree.load(from: store)
        switch operation {
        case .undo:
            return try await undo(in: tree, source: source, status: available)
        case .redo:
            return try await redo(in: tree, source: source, status: available)
        }
    }

    private func checkpointBranch(
        in tree: SessionTree,
        from leafID: String?
    ) throws -> [(entry: SessionTreeEntry, snapshot: WorkspaceSnapshot)] {
        try tree.branch(from: leafID).compactMap { entry in
            guard case .workspaceCheckpoint(let snapshot) = entry.payload else { return nil }
            return (entry: entry, snapshot: snapshot)
        }
    }

    private func undo(
        in tree: SessionTree,
        source: any WorkspaceSnapshotSource,
        status: WorkspaceSnapshotStatus
    ) async throws -> WorkspaceHistoryResult {
        let checkpoints = try checkpointBranch(in: tree, from: leaf)
        guard checkpoints.count >= 2,
              let current = checkpoints.last,
              let target = checkpoints.dropLast().last
        else {
            return WorkspaceHistoryResult(operation: .undo, status: status, moved: false)
        }

        let targetIndex = checkpoints.count - 2
        let intervening = Array(checkpoints.dropFirst(targetIndex + 1).map(\.snapshot))
        let plan = WorkspaceRevertPlanner.plan(
            current: current.snapshot,
            target: target.snapshot,
            intervening: intervening
        )
        let restored: WorkspaceRestoreResult
        do {
            restored = try await source.restore(plan)
        } catch {
            workspaceStatusValue = .unavailable
            return WorkspaceHistoryResult(operation: .undo, status: .unavailable, moved: false)
        }
        guard restored.status == .restored, restored.failedPaths.isEmpty else {
            workspaceStatusValue = restored.status
            return WorkspaceHistoryResult(
                operation: .undo,
                status: restored.status,
                moved: false,
                fromEntryID: current.entry.id,
                targetEntryID: target.entry.id,
                restoredPaths: restored.restoredPaths,
                skippedPaths: restored.skippedPaths,
                failedPaths: restored.failedPaths
            )
        }

        let action = SessionHistoryAction(
            operation: .undo,
            fromEntryID: current.entry.id,
            targetEntryID: target.entry.id,
            fromSnapshotID: current.snapshot.id,
            targetSnapshotID: target.snapshot.id,
            paths: plan.paths,
            restoredPaths: restored.restoredPaths,
            skippedPaths: restored.skippedPaths,
            failedPaths: restored.failedPaths,
            status: restored.status
        )
        try appendHistoryAction(action)
        workspaceSnapshotID = target.snapshot.id
        let movedTree = try SessionTree.load(from: store)
        try adoptBranch(in: movedTree, targetID: target.entry.id)
        workspaceStatusValue = restored.status
        return WorkspaceHistoryResult(
            operation: .undo,
            status: restored.status,
            moved: true,
            fromEntryID: current.entry.id,
            targetEntryID: target.entry.id,
            restoredPaths: restored.restoredPaths,
            skippedPaths: restored.skippedPaths,
            failedPaths: restored.failedPaths
        )
    }

    private func redo(
        in tree: SessionTree,
        source: any WorkspaceSnapshotSource,
        status: WorkspaceSnapshotStatus
    ) async throws -> WorkspaceHistoryResult {
        guard let last = tree.entries.last,
              case .historyAction(let previous) = last.payload,
              previous.operation == .undo,
              tree.leafID == previous.targetEntryID,
              let fromEntry = tree.entry(withID: previous.fromEntryID),
              let targetEntry = tree.entry(withID: previous.targetEntryID),
              case .workspaceCheckpoint(let fromSnapshot) = fromEntry.payload,
              case .workspaceCheckpoint(let targetSnapshot) = targetEntry.payload
        else {
            return WorkspaceHistoryResult(operation: .redo, status: status, moved: false)
        }

        let plan = WorkspaceRevertPlan(
            expectedCurrentID: targetSnapshot.id,
            targetID: fromSnapshot.id,
            paths: previous.paths
        )
        let restored: WorkspaceRestoreResult
        do {
            restored = try await source.restore(plan)
        } catch {
            workspaceStatusValue = .unavailable
            return WorkspaceHistoryResult(operation: .redo, status: .unavailable, moved: false)
        }
        guard restored.status == .restored, restored.failedPaths.isEmpty else {
            workspaceStatusValue = restored.status
            return WorkspaceHistoryResult(
                operation: .redo,
                status: restored.status,
                moved: false,
                fromEntryID: targetEntry.id,
                targetEntryID: fromEntry.id,
                restoredPaths: restored.restoredPaths,
                skippedPaths: restored.skippedPaths,
                failedPaths: restored.failedPaths
            )
        }

        let action = SessionHistoryAction(
            operation: .redo,
            fromEntryID: targetEntry.id,
            targetEntryID: fromEntry.id,
            fromSnapshotID: targetSnapshot.id,
            targetSnapshotID: fromSnapshot.id,
            paths: previous.paths,
            restoredPaths: restored.restoredPaths,
            skippedPaths: restored.skippedPaths,
            failedPaths: restored.failedPaths,
            status: restored.status
        )
        try appendHistoryAction(action)
        workspaceSnapshotID = fromSnapshot.id
        let movedTree = try SessionTree.load(from: store)
        try adoptBranch(in: movedTree, targetID: fromEntry.id)
        workspaceStatusValue = restored.status
        return WorkspaceHistoryResult(
            operation: .redo,
            status: restored.status,
            moved: true,
            fromEntryID: targetEntry.id,
            targetEntryID: fromEntry.id,
            restoredPaths: restored.restoredPaths,
            skippedPaths: restored.skippedPaths,
            failedPaths: restored.failedPaths
        )
    }

    private func appendHistoryAction(_ action: SessionHistoryAction) throws {
        let entry = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: leaf,
            timestamp: timestamp(),
            payload: .historyAction(action),
            seq: nextSeq
        )
        try store.appendEntry(entry)
        nextSeq += 1
    }

    private func adoptBranch(in tree: SessionTree, targetID: String?) throws {
        let path = try targetID.map { try tree.branch(from: $0) } ?? []
        leafChain = path.map(\.id)
        let model = path.reversed().compactMap { entry -> String? in
            if case .modelChange(_, let modelID) = entry.payload { return modelID }
            return nil
        }.first ?? configuration.model
        activeModel = model
        activeStreamFn = configuration.streamFnForModel?(model) ?? configuration.streamFn
        activeContextWindow = configuration.contextWindowForModel?(model) ?? configuration.contextWindow
    }
}
