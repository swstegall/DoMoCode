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

        /// A brand-new file: numbering starts at zero and nothing has been spent.
        static let fresh = Seed(nextSeq: 0, usage: .zero, turns: 0)
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
    private static func seed(store: JSONLSessionStore, entries: [SessionTreeEntry]) throws -> Seed {
        let recovered = totals(from: entries)
        return Seed(nextSeq: try store.nextSequenceNumber(), usage: recovered.usage, turns: recovered.turns)
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
            case .message, .modelChange, .label, .sessionInfo, .leaf:
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
            contextWindow: Int? = nil,
            now: @escaping @Sendable () -> Date = { Date() },
            monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
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
            self.getSteeringMessages = getSteeringMessages
            self.getFollowUpMessages = getFollowUpMessages
            self.shouldStopAfterTurn = shouldStopAfterTurn
            self.beforeToolCall = beforeToolCall
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
        return AgentHarness(store: store, leaf: nil, configuration: configuration, seed: .fresh)
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
        let seed = try Self.seed(store: store, entries: tree.entries)
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
        let seed = try Self.seed(store: store, entries: tree.entries)
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
        let seed = try Self.seed(store: store, entries: tree.entries)
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
        let seed = try Self.seed(store: forked, entries: forkedTree.entries)
        return AgentHarness(store: forked, leaf: forkedTree.leafID, configuration: configuration, seed: seed)
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
            contextWindow: configuration.contextWindow,
            turns: recordedTurns
        )
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
        let persistenceSink = SessionPersistenceSink(
            persister: self,
            forward: sink,
            errorBox: errorBox,
            monotonicNow: configuration.monotonicNow
        )

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
        // nothing on it: ``persistMessage(_:elapsedMs:)`` writes the next entry with
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
    /// concrete client. The request carries ``CompactionPrompts/system`` and a
    /// trailing ``CompactionPrompts/instruction``; the terminal assistant message's
    /// text is the summary and **its usage is the price of producing it**, which is
    /// the only point at which summarization cost can enter the session's totals.
    /// A failed terminal turn throws, so compaction that could not summarize writes
    /// no entry — the correct outcome for a context that cannot be bounded.
    private var effectiveSummarizer: Summarizer {
        if let summarizer = configuration.summarizer { return summarizer }
        let streamFn = configuration.streamFn
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
    private func compactIfNeeded() async throws {
        // Re-clamped rather than trusting the constructor's clamp: `contextWindow`
        // and `compaction` are both `var`s on a struct the caller keeps, so the
        // pairing can be broken after construction. Idempotent when it already
        // holds.
        let window = configuration.contextWindow ?? Configuration.fallbackContextWindow
        let settings = configuration.compaction.clamped(toContextWindow: window)
        guard settings.enabled else { return }
        // Same reason as ``buildContextMessages()``: an empty tip is an empty branch,
        // and resolving `nil` here would measure — and then summarize — a path this
        // harness is not on, anchoring the checkpoint it writes at the root.
        guard let tip = leaf else { return }
        let tree = try SessionTree.load(from: store)
        let pathEntries = try tree.pathToRootOrCompaction(from: tip)
        let messages = ContextBuilder.messages(for: pathEntries)
        let estimate = estimateContextTokens(messages)
        guard shouldCompact(contextTokens: estimate.tokens, contextWindow: window, settings: settings) else { return }
        guard let preparation = prepareCompaction(pathEntries: pathEntries, settings: settings) else {
            return
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
    private static func decodeDecimal(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal {
        guard let text = try? container.decode(String.self, forKey: key) else {
            return try container.decode(Decimal.self, forKey: key)
        }
        guard let value = Decimal(string: text) else {
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
