import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

// MARK: - Test support

/// A stream function that replays one canned assistant message per call, in order,
/// as a terminal-only assembly stream. The last scripted message repeats if the
/// loop asks for more turns than were scripted.
private final class ScriptedResponder: Sendable {
    private let responses: [AssistantMessage]
    private let index = Mutex<Int>(0)

    init(_ responses: [AssistantMessage]) { self.responses = responses }

    var callCount: Int { index.withLock { $0 } }

    func fn() -> AgentStreamFn {
        { [self] _ in
            let i = index.withLock { current -> Int in
                let value = current
                current += 1
                return value
            }
            let message = responses[min(i, responses.count - 1)]
            let terminal: AssemblyEvent = message.failure == nil ? .done(message) : .failed(message)
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: message.model)))
                continuation.yield(terminal)
                continuation.finish()
            }
        }
    }
}

/// Records the message lists handed to the summarizer and returns a fixed summary,
/// optionally with the usage a real summarization call would report.
private final class SummarizerSpy: Sendable {
    private let calls = Mutex<[[Message]]>([])
    let text: String
    let usage: Usage?

    init(text: String, usage: Usage? = nil) {
        self.text = text
        self.usage = usage
    }

    var recorded: [[Message]] { calls.withLock { $0 } }

    func fn() -> Summarizer {
        { [self] messages in
            calls.withLock { $0.append(messages) }
            return SummarizerResult(text: text, usage: usage)
        }
    }
}

/// Records every forwarded event so a test can prove the persistence sink forwards
/// to the UI sink as well as persisting.
private final class RecordingSink: AgentEventSink {
    private let storage = Mutex<[AgentEvent]>([])
    func emit(_ event: AgentEvent) async { storage.withLock { $0.append(event) } }
    var events: [AgentEvent] { storage.withLock { $0 } }
}

/// Captures the context message list handed to `streamFn` on each turn, so a test
/// can assert which turn a steering message first appears in.
private final class ContextRecorder: Sendable {
    private let storage = Mutex<[[Message]]>([])
    func record(_ messages: [Message]) { storage.withLock { $0.append(messages) } }
    var all: [[Message]] { storage.withLock { $0 } }
}

/// A terminal-only assembly stream for one canned assistant message.
private func terminalStream(_ message: AssistantMessage) -> AsyncThrowingStream<AssemblyEvent, any Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(.start(AssistantSnapshot(model: message.model)))
        continuation.yield(message.failure == nil ? .done(message) : .failed(message))
        continuation.finish()
    }
}

/// Deterministic, monotonic entry ids so a whole session file is reproducible.
private final class SequentialIDs: Sendable {
    private let counter = Mutex<Int>(0)
    private let prefix: String
    init(prefix: String) { self.prefix = prefix }
    func factory() -> @Sendable () -> String {
        { [self] in
            let value = counter.withLock { current -> Int in
                let taken = current
                current += 1
                return taken
            }
            return "\(prefix)-\(value)"
        }
    }
}

private struct EchoTool: AgentTool {
    let definition = ToolDefinition(name: "echo", description: "echo", parameters: JSONSchema())
    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        AgentToolResult(output: "echoed")
    }
}

@Suite("AgentHarness")
struct AgentHarnessTests {
    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-harness-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func assistant(_ text: String, usageInput: Int = 0, stopReason: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(
            content: [.text(text)],
            model: "test-model",
            usage: Usage(input: usageInput),
            stopReason: stopReason
        )
    }

    private func configuration(
        streamFn: @escaping AgentStreamFn,
        tools: [any AgentTool] = [],
        summarizer: Summarizer? = nil,
        compaction: CompactionSettings = CompactionSettings(enabled: false),
        contextWindow: Int? = nil,
        ids: SequentialIDs
    ) -> AgentHarness.Configuration {
        AgentHarness.Configuration(
            systemPrompt: "You are a test.",
            tools: tools,
            model: "test-model",
            streamFn: streamFn,
            summarizer: summarizer,
            compaction: compaction,
            contextWindow: contextWindow,
            now: { self.fixedDate },
            entryIDFactory: ids.factory()
        )
    }

    /// Reads the raw entries back from a session file, tolerantly.
    private func entries(of path: FilePath) throws -> [SessionTreeEntry] {
        try JSONLSessionStore.open(path: path).readEntries()
    }

    // MARK: - Persistence & resumability

    @Test("a run persists the user prompt and each assistant turn in transcript order")
    func runPersistsTranscript() async throws {
        let responder = ScriptedResponder([assistant("hi there")])
        let ids = SequentialIDs(prefix: "a")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: ids)
        )
        _ = try await harness.run(prompt: "hello")

        let path = await harness.sessionFilePath
        let recorded = try entries(of: path)
        #expect(recorded.count == 2)
        guard case .message(.user(let user)) = recorded[0].payload else {
            Issue.record("first entry is not a user message")
            return
        }
        #expect(user.text == "hello")
        guard case .message(.assistant(let asst)) = recorded[1].payload else {
            Issue.record("second entry is not an assistant message")
            return
        }
        #expect(asst.text == "hi there")
        // The chain is linear: the assistant entry is a child of the user entry.
        #expect(recorded[1].parentId == recorded[0].id)
    }

    @Test("tool results are persisted as their own entries between turns")
    func toolResultsPersisted() async throws {
        let responder = ScriptedResponder([
            AssistantMessage(
                content: [.toolCall(ToolCallBlock(id: "c1", name: "echo"))],
                model: "test-model",
                stopReason: .toolUse
            ),
            assistant("done"),
        ])
        let ids = SequentialIDs(prefix: "t")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), tools: [EchoTool()], ids: ids)
        )
        _ = try await harness.run(prompt: "please echo")

        let recorded = try entries(of: await harness.sessionFilePath)
        // user, assistant(tool call), tool result, assistant(done)
        #expect(recorded.count == 4)
        let roles = recorded.map { entry -> String in
            if case .message(let message) = entry.payload { return message.role.rawValue }
            return "?"
        }
        #expect(roles == ["user", "assistant", "tool", "assistant"])
    }

    @Test("the persistence sink forwards every event to the UI sink")
    func forwardsToUISink() async throws {
        let responder = ScriptedResponder([assistant("hi")])
        let ids = SequentialIDs(prefix: "f")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: ids)
        )
        let ui = RecordingSink()
        _ = try await harness.run(prompt: "hello", sink: ui)
        let kinds = ui.events.map(\.self)
        #expect(kinds.contains { if case .agentStart = $0 { return true } else { return false } })
        #expect(kinds.contains { if case .agentEnd = $0 { return true } else { return false } })
    }

    // MARK: - Steering passthrough

    @Test("a message queued mid-run is steered into the same run's next turn, not deferred")
    func steeringInjectsIntoCurrentRun() async throws {
        // Turn 1 emits a tool call (so the loop takes a second turn within the same
        // run) and, while it "streams", enqueues a steering message — exactly the
        // shape of a user typing mid-run. The loop drains the queue at the turn
        // boundary and must inject it before turn 2's request, so turn 2's context
        // carries the steering message and turn 1's does not.
        let queue = SteeringBox()
        let contexts = ContextRecorder()
        let turn = Mutex<Int>(0)
        let streamFn: AgentStreamFn = { context in
            let i = turn.withLock { value -> Int in
                let taken = value
                value += 1
                return taken
            }
            contexts.record(context.messages)
            if i == 0 {
                queue.enqueue(.user("also check the tests"))
                let message = AssistantMessage(
                    content: [.toolCall(ToolCallBlock(id: "c1", name: "echo"))],
                    model: "test-model",
                    stopReason: .toolUse
                )
                return terminalStream(message)
            }
            return terminalStream(
                AssistantMessage(content: [.text("done")], model: "test-model", stopReason: .stop)
            )
        }

        let ids = SequentialIDs(prefix: "steer")
        var config = configuration(streamFn: streamFn, tools: [EchoTool()], ids: ids)
        config.steeringBox = queue

        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: config
        )
        _ = try await harness.run(prompt: "start")

        // Two turns ran inside the single `run` call — the same run, not a new one.
        let recordedContexts = contexts.all
        #expect(recordedContexts.count == 2)

        // Turn 1's context predates the steering message; turn 2's includes it.
        let steer = Message.user("also check the tests")
        #expect(!recordedContexts[0].contains(steer))
        #expect(recordedContexts[1].contains(steer))

        // The steered user turn is persisted between the tool result and the final
        // assistant turn, so a resume replays it in order.
        let recorded = try entries(of: await harness.sessionFilePath)
        let roles = recorded.map { entry -> String in
            if case .message(let message) = entry.payload { return message.role.rawValue }
            return "?"
        }
        // user(start), assistant(tool call), tool result, user(steer), assistant(done)
        #expect(roles == ["user", "assistant", "tool", "user", "assistant"])
        guard case .message(.user(let steered)) = recorded[3].payload else {
            Issue.record("fourth entry is not the steered user message")
            return
        }
        #expect(steered.text == "also check the tests")
    }

    @Test("shouldStopAfterTurn forwarded from the configuration ends the run early")
    func shouldStopAfterTurnForwarded() async throws {
        // The stream would gladly run a second turn (turn 1 calls a tool), but the
        // configuration's stop hook fires after the first turn, so the run settles
        // with only one LLM call.
        let responder = ScriptedResponder([
            AssistantMessage(
                content: [.toolCall(ToolCallBlock(id: "c1", name: "echo"))],
                model: "test-model",
                stopReason: .toolUse
            ),
            assistant("should never be reached"),
        ])
        let ids = SequentialIDs(prefix: "stop")
        var config = configuration(streamFn: responder.fn(), tools: [EchoTool()], ids: ids)
        config.shouldStopAfterTurn = { _ in true }

        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: config
        )
        let result = try await harness.run(prompt: "start")

        #expect(result.stopReason == .stoppedByHook)
        // Only the first turn's request was made.
        #expect(responder.callCount == 1)
    }

    // MARK: - The runaway guard reaches every embedding

    @Test("an unbounded harness run is still stopped by the default no-progress guard")
    func defaultNoProgressGuardBoundsAnUnboundedRun() async throws {
        // `AgentHarness.Configuration.maxTurns` defaults to nil — unbounded — so
        // the ONLY thing that ends a stuck run is `AgentLoopConfig`'s
        // `noProgressLimit` default, inherited because `run(prompt:)` does not
        // pass the argument at all. That inheritance is the whole product effect
        // of the guard (server, print mode and the inline REPL all arrive here),
        // and nothing else in the suite pins it: a `noProgressLimit: nil` added
        // to that construction leaves every loop-level test green.
        //
        // 15 identical tool-call turns are scripted, then an answer. Guarded, the
        // run settles `.noProgress` on turn 12 and the answer is never requested.
        let stuckTurn = AssistantMessage(
            content: [.toolCall(ToolCallBlock(id: "c1", name: "echo"))],
            model: "test-model",
            stopReason: .toolUse
        )
        let responder = ScriptedResponder(Array(repeating: stuckTurn, count: 15) + [assistant("done")])
        let ids = SequentialIDs(prefix: "stuck")
        let config = configuration(streamFn: responder.fn(), tools: [EchoTool()], ids: ids)
        #expect(config.maxTurns == nil)

        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: config
        )
        let result = try await harness.run(prompt: "go")

        #expect(result.stopReason == .noProgress)
        #expect(responder.callCount == 12)
    }

    // MARK: - Resume correctness (the exit criterion)

    @Test("a fresh harness opened on a two-turn file rebuilds the identical next-turn context")
    func resumeReconstructsContext() async throws {
        let dir = makeSessionDirectory()
        let responder = ScriptedResponder([assistant("first answer"), assistant("second answer")])
        let ids = SequentialIDs(prefix: "r")
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: ids)
        )
        _ = try await live.run(prompt: "turn one")
        _ = try await live.run(prompt: "turn two")

        let path = await live.sessionFilePath
        let liveContext = try await live.contextMessages()

        // A brand-new harness on the same file, with its own fresh id factory, must
        // reconstruct exactly what the uninterrupted harness holds.
        let resumed = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "x"))
        )
        let resumedContext = try await resumed.contextMessages()

        #expect(resumedContext == liveContext)

        let expected: [Message] = [
            .user("turn one"),
            .assistant(assistant("first answer")),
            .user("turn two"),
            .assistant(assistant("second answer")),
        ]
        #expect(resumedContext == expected)
        #expect(await resumed.currentLeafID == live.currentLeafID)
    }

    /// The file is not an authority on which branch a session is on when two
    /// harnesses share it, because its leaf is "last entry wins". `ServerRuntime`
    /// force-clears a wedged run by re-opening the file while the run it abandoned
    /// is still alive over the same file, so the abandoned run's eventual append
    /// becomes that last entry — and a file-derived tip silently moves the session
    /// onto the dead branch, taking the recovered turn out of the context of every
    /// later turn. `open(path:configuration:leaf:)` is how a caller that still holds
    /// the live tip says so.
    @Test("open(leaf:) continues from the caller's tip, not from the file's last entry")
    func openPinnedToALeafIgnoresTheFileLeaf() async throws {
        let dir = makeSessionDirectory()
        let responder = ScriptedResponder([assistant("one"), assistant("two"), assistant("side")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath

        // A second harness over the SAME file, forked off the tip as it stood — the
        // shape force-clear leaves behind.
        let abandoned = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "dead"))
        )
        _ = try await live.run(prompt: "second")
        let liveLeaf = await live.currentLeafID
        // …and now the abandoned one settles, appending the file's new last entry on
        // a branch of its own.
        _ = try await abandoned.run(prompt: "stale")
        #expect(await abandoned.currentLeafID != liveLeaf, "both harnesses stayed on one branch")

        let fileLeafed = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "f"))
        )
        #expect(
            try await fileLeafed.contextMessages().contains(.user("stale")),
            "the file's leaf stopped landing on the abandoned branch — the premise of this seam changed"
        )
        #expect(!(try await fileLeafed.contextMessages().contains(.user("second"))))

        let pinned = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "p")),
            leaf: liveLeaf
        )
        #expect(await pinned.currentLeafID == liveLeaf)
        #expect(try await pinned.contextMessages() == (try await live.contextMessages()),
                "the pinned harness did not reconstruct the live branch")
        #expect(!(try await pinned.contextMessages().contains(.user("stale"))),
                "the pinned harness adopted the abandoned branch anyway")
    }

    @Test("open(leaf: nil) pins an empty tip rather than falling back to the file's")
    func openPinnedToNilIsAnEmptyTip() async throws {
        let responder = ScriptedResponder([assistant("one")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath

        let pinned = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "p")),
            leaf: nil
        )
        #expect(await pinned.currentLeafID == nil)
        #expect(try await pinned.contextMessages().isEmpty,
                "leaf: nil was treated as \"use the file's leaf\"")
    }

    /// Refused at construction rather than at the first read: a harness whose tip is
    /// not in its file can neither build a context nor persist a child, and falling
    /// back to the file's leaf would be exactly the branch switch this entry point
    /// exists to prevent.
    @Test("open(leaf:) refuses a tip that is not in the file")
    func openPinnedToAnAbsentLeafThrows() async throws {
        let responder = ScriptedResponder([assistant("one")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath

        #expect(throws: DoMoError.self) {
            try AgentHarness.open(
                path: path,
                configuration: self.configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "p")),
                leaf: "not-an-entry-in-this-file"
            )
        }
    }

    // MARK: - Opening against a file that is behind the live tip

    /// The strict pin above is right and, alone, unusable as a recovery path: the
    /// live tip lives in memory and the file is explicitly allowed to be behind it
    /// (`JSONLines.appendBytes`: "the previous process died between writing an entry
    /// and writing its newline"). A tip that is not in the file can never come back,
    /// so a caller that must not fail — `ServerRuntime.forceClearRun` is the lever of
    /// last resort — cannot be built on a refusal.
    ///
    /// `open(preferring:)` is that caller's entry point: the tip if the file has it,
    /// otherwise the nearest ancestor of it the file *can* resolve. Every candidate
    /// is an ancestor of the live tip, so whichever one it lands on is on the live
    /// branch by construction — it can never adopt someone else's.
    @Test("open(preferring:) falls back to the nearest ancestor the file still has")
    func openPreferringPicksTheNearestSurvivingAncestor() async throws {
        let responder = ScriptedResponder([assistant("one"), assistant("two")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        _ = try await live.run(prompt: "second")
        let path = await live.sessionFilePath
        let lineage = await live.leafLineage
        #expect(lineage.first == (await live.currentLeafID), "the lineage does not start at the tip")

        // The interruption the storage layer documents: the final line is gone, so
        // the tolerant bulk read no longer sees the entry the live tip names.
        try dropLastLine(of: path)
        let survivingTip = try #require(lineage.dropFirst().first)

        let recovered = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "r")),
            preferring: lineage
        )
        #expect(await recovered.currentLeafID == survivingTip,
                "the recovery did not land on the nearest surviving ancestor")
        let context = try await recovered.contextMessages()
        #expect(context.contains(.user("second")), "context that survived the damage was thrown away")
        #expect(!context.contains(where: { if case .assistant(let a) = $0 { a.text == "two" } else { false } }),
                "the torn entry came back")
    }

    /// Presence is not enough: the bulk read is tolerant of a malformed line
    /// *anywhere*, and the path resolvers throw on the hole it leaves. A candidate
    /// whose chain cannot be walked would give a harness that opens cleanly and then
    /// fails on every read — so the choice is made on what resolves, not on what is
    /// merely there.
    @Test("open(preferring:) skips a candidate whose chain the file cannot resolve")
    func openPreferringSkipsAnUnresolvableCandidate() async throws {
        let responder = ScriptedResponder([assistant("one"), assistant("two")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        _ = try await live.run(prompt: "second")
        let path = await live.sessionFilePath
        let lineage = await live.leafLineage
        // lineage is [assistant2, user2, assistant1, user1]; drop `user2` from the
        // middle so the tip is present but its parent chain has a hole.
        let hole = try #require(lineage.dropFirst().first)
        try removeEntryLine(of: path, id: hole)

        let recovered = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "r")),
            preferring: lineage
        )
        #expect(await recovered.currentLeafID == lineage.dropFirst(2).first,
                "the recovery pinned a tip whose own context cannot be built")
        // The point of skipping it: every read works.
        #expect(try await recovered.contextMessages().contains(.user("first")))
    }

    /// A compacted session resolves a turn only as far back as its checkpoint, so a
    /// hole BELOW that checkpoint leaves every read a turn actually performs intact.
    /// Gating candidates on ``SessionTree/branch(from:)`` alone — which walks the
    /// full chain to the root — therefore rejected a perfectly usable tip and fell
    /// through to an empty branch, silently discarding a whole compacted
    /// conversation. `branch` succeeding implies the shorter walk succeeds; it is the
    /// CONVERSE this gate needs, and the converse is false exactly at a checkpoint.
    @Test("open(preferring:) keeps a compacted branch whose hole is below the checkpoint")
    func openPreferringKeepsACompactedBranchWithAHoleBelowTheCheckpoint() async throws {
        let text = String(repeating: "a", count: 40)
        let responder = ScriptedResponder([
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
        ])
        let spy = SummarizerSpy(text: "SUMMARY")
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: spy.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: SequentialIDs(prefix: "live")
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await live.run(prompt: user)
        _ = try await live.run(prompt: user)
        _ = try await live.run(prompt: user)

        let path = await live.sessionFilePath
        let lineage = await live.leafLineage
        let tip = try #require(lineage.first)
        // The checkpoint summarized the first turn, so its entries are below it.
        // Removing the oldest one breaks the walk to the ROOT while leaving the walk
        // a turn takes — which stops at the checkpoint — completely intact.
        let oldest = try #require(lineage.last)
        try removeEntryLine(of: path, id: oldest)

        let recovered = try AgentHarness.open(
            path: path,
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: spy.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: SequentialIDs(prefix: "r")
            ),
            preferring: lineage
        )
        #expect(await recovered.currentLeafID == tip,
                "a usable compacted tip was rejected and the conversation discarded")
        let context = try await recovered.contextMessages()
        #expect(!context.isEmpty, "the recovery threw away a conversation a turn could still read")
        guard case .user(let first) = context.first else {
            Issue.record("the recovered context does not start with the compaction summary")
            return
        }
        #expect(first.text.contains("SUMMARY"), "the summary the checkpoint stands on was lost")
    }

    /// The floor. When nothing the harness stood on survives, the answer is an
    /// explicitly empty branch — never the file's own leaf, which is exactly the
    /// branch switch the pin exists to prevent.
    @Test("open(preferring:) falls back to an empty branch rather than to the file's leaf")
    func openPreferringFallsBackToAnEmptyBranch() async throws {
        let responder = ScriptedResponder([assistant("one")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath

        let recovered = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "r")),
            preferring: ["nothing-here", "nor-this"]
        )
        #expect(await recovered.currentLeafID == nil)
        #expect(try await recovered.contextMessages().isEmpty,
                "an unusable candidate list was treated as \"use the file's leaf\"")
    }

    // MARK: - Sealing a branch that ends mid-tool-call

    /// A branch whose last assistant turn calls a tool that never returned has a
    /// `tool_use` no `tool_result` answers, and Anthropic behind LiteLLM rejects such
    /// a request outright (the same validation `Context.hasToolHistory` exists for).
    /// Nothing downstream repairs it — `ContextBuilder` projects entries verbatim —
    /// so the repair has to happen where the branch is adopted.
    @Test("sealUnansweredToolCalls answers every dangling call and nothing else")
    func sealingAnsweredOnlyTheDanglingCalls() async throws {
        let responder = ScriptedResponder([assistant("one")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "s"))
        )
        // `elapsedMs: nil` throughout: these are appended outside the event stream,
        // so nothing timed them and `0` would be a claim about a stopwatch nobody
        // started.
        try await harness.persistMessage(.user("go"), elapsedMs: nil)
        try await harness.persistMessage(
            .assistant(AssistantMessage(
                content: [
                    .toolCall(ToolCallBlock(id: "answered", name: "echo")),
                    .toolCall(ToolCallBlock(id: "dangling", name: "park")),
                ],
                model: "test-model",
                stopReason: .toolUse
            )),
            elapsedMs: nil
        )
        try await harness.persistMessage(
            .tool(ToolResultBlock(toolCallID: "answered", toolName: "echo", output: "echoed")),
            elapsedMs: nil
        )

        let sealed = try await harness.sealUnansweredToolCalls(reason: "cleared")
        #expect(sealed == ["dangling"], "sealed the wrong set: \(sealed)")

        let context = try await harness.contextMessages()
        let results = context.compactMap { if case .tool(let result) = $0 { result } else { nil } }
        #expect(results.count == 2, "the seal did not land as its own tool-result entry")
        let seal = try #require(results.last)
        #expect(seal.toolCallID == "dangling")
        #expect(seal.isError, "the synthetic answer must read as a failure, not as a result")
        #expect(seal.output == "cleared")

        // Idempotent by construction: there is nothing unanswered left to answer.
        #expect(try await harness.sealUnansweredToolCalls(reason: "cleared").isEmpty)
        #expect(try await harness.contextMessages().count == context.count)
    }

    @Test("sealUnansweredToolCalls writes nothing to a branch that is already complete")
    func sealingACompleteBranchWritesNothing() async throws {
        let responder = ScriptedResponder([assistant("one")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "s"))
        )
        _ = try await harness.run(prompt: "hello")
        let path = await harness.sessionFilePath
        let before = try entries(of: path)

        #expect(try await harness.sealUnansweredToolCalls(reason: "cleared").isEmpty)
        #expect(try entries(of: path).count == before.count, "the seal appended to a complete branch")
    }

    /// Rewrite a session file with its final line removed.
    private func dropLastLine(of path: FilePath) throws {
        var lines = try lines(of: path)
        #expect(lines.count > 1)
        lines.removeLast()
        try write(lines, to: path)
    }

    /// Rewrite a session file with the line whose entry id is `id` removed — the
    /// malformed-middle-line case, which the bulk read drops just as tolerantly.
    private func removeEntryLine(of path: FilePath, id: String) throws {
        // Matched on the `id` field specifically, so the child that names it as its
        // `parentId` is left in place — the hole is the point.
        let kept = try lines(of: path).filter { !$0.contains("\"id\":\"\(id)\"") }
        try write(kept, to: path)
    }

    private func lines(of path: FilePath) throws -> [String] {
        try String(contentsOfFile: path.string, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func write(_ lines: [String], to path: FilePath) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    // MARK: - Compaction integration

    @Test("compaction fires before a turn when the last assistant usage crosses the threshold")
    func compactionFiresBeforeTurn() async throws {
        // Three turns of ~10-token messages; a large assistant usage anchors the
        // running estimate well above a small window, so compaction fires at the
        // start of the third run. keepRecentTokens=25 keeps [user2, asst2] and
        // summarizes [user1, asst1].
        let text = String(repeating: "a", count: 40)  // 40 chars => 10 tokens
        let responder = ScriptedResponder([
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
        ])
        let spy = SummarizerSpy(text: "SUMMARY")
        let ids = SequentialIDs(prefix: "c")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: spy.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: ids
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        // A compaction entry was written.
        let recorded = try entries(of: await harness.sessionFilePath)
        let compactions = recorded.compactMap { entry -> Compaction? in
            if case .compaction(let compaction) = entry.payload { return compaction }
            return nil
        }
        #expect(compactions.count == 1)

        // The summarizer saw the older messages, not the retained recent tail.
        #expect(spy.recorded.count == 1)
        let summarized = try #require(spy.recorded.first)
        #expect(summarized.count == 1)

        // The rebuilt context begins with the wrapped summary and then the tail.
        let context = try await harness.contextMessages()
        guard case .user(let first) = context.first else {
            Issue.record("context does not start with a user summary message")
            return
        }
        #expect(first.text.contains("SUMMARY"))
        #expect(first.text.contains("compacted into the following summary"))
    }

    /// The other half of "an empty tip is an empty branch": the pre-turn compaction
    /// check measures a path too, and resolving a `nil` tip there would summarize a
    /// conversation this harness is not on and then anchor the checkpoint it writes
    /// at the root — a second way for a pinned harness to be pulled onto the file's
    /// branch. Only ``AgentHarness/open(path:configuration:leaf:)`` can produce this
    /// state (an empty tip over a written file), which is why it went unnoticed.
    @Test("a harness pinned to an empty tip does not compact the file's branch")
    func compactionSkipsAnEmptyTip() async throws {
        let dir = makeSessionDirectory()
        let text = String(repeating: "a", count: 40)
        let responder = ScriptedResponder([
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
        ])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: SequentialIDs(prefix: "live"))
        )
        let user = String(repeating: "b", count: 40)
        _ = try await live.run(prompt: user)
        _ = try await live.run(prompt: user)
        let path = await live.sessionFilePath

        let spy = SummarizerSpy(text: "SUMMARY")
        let pinned = try AgentHarness.open(
            path: path,
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: spy.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: SequentialIDs(prefix: "p")
            ),
            leaf: nil
        )
        _ = try await pinned.run(prompt: "fresh")

        #expect(spy.recorded.isEmpty, "the empty-tip harness compacted a branch it is not on")
        let recorded = try entries(of: path)
        #expect(!recorded.contains { if case .compaction = $0.payload { true } else { false } },
                "a compaction checkpoint was written for a branch the harness is not on")
        // And its own turn really did land, as a new root.
        #expect(try await pinned.contextMessages().first == .user("fresh"))
    }

    /// ``Compaction/usage`` shipped with a doc comment saying it is "folded into
    /// session totals" and was `nil` in every session file ever written: the harness
    /// called `compact` without a `usage:` argument and had nothing to pass, because
    /// the summarizer returned only prose. This is the whole point of widening it.
    @Test("the summarizer's usage lands on the compaction entry it produced")
    func summarizerUsageReachesTheCompactionEntry() async throws {
        let text = String(repeating: "a", count: 40)
        let responder = ScriptedResponder([
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
            assistant(text, usageInput: 5000),
        ])
        let spy = SummarizerSpy(text: "SUMMARY", usage: Usage(input: 321, output: 12))
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: spy.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: SequentialIDs(prefix: "cu")
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        let recorded = try entries(of: await harness.sessionFilePath)
        let compactions = recorded.compactMap { entry -> Compaction? in
            if case .compaction(let compaction) = entry.payload { return compaction }
            return nil
        }
        #expect(compactions.count == 1)
        let usage = try #require(compactions.first?.usage, "the summarization call's usage was dropped on the floor")
        #expect(usage.input == 321)
        #expect(usage.output == 12)
    }

    /// The harness's own fallback summarizer drains the run's `streamFn`; the
    /// terminal assistant message it holds is the *only* place the price of that
    /// request exists. It also has to send the shared prompt text, or a session
    /// compacted by the CLI's small-model summarizer and one compacted here would
    /// be asking two different questions.
    @Test("the default summarizer sends the shared prompt text and reports the call's usage")
    func defaultSummarizerCarriesPromptAndUsage() async throws {
        let sawInstruction = Mutex<Bool>(false)
        let sawSystemPrompt = Mutex<Bool>(false)
        let text = String(repeating: "a", count: 40)
        let streamFn: AgentStreamFn = { context in
            let isSummarization = context.messages.contains(.user(CompactionPrompts.instruction))
            if isSummarization {
                sawInstruction.withLock { $0 = true }
                sawSystemPrompt.withLock { $0 = context.systemPrompt == CompactionPrompts.system }
                return terminalStream(AssistantMessage(
                    content: [.text("AUTOSUMMARY")],
                    model: "test-model",
                    usage: Usage(input: 777),
                    stopReason: .stop
                ))
            }
            return terminalStream(AssistantMessage(
                content: [.text(text)],
                model: "test-model",
                usage: Usage(input: 5000),
                stopReason: .stop
            ))
        }
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: streamFn,
                summarizer: nil,
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: SequentialIDs(prefix: "ds")
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        let instructionSeen = sawInstruction.withLock { $0 }
        let systemPromptSeen = sawSystemPrompt.withLock { $0 }
        #expect(instructionSeen, "the default summarizer did not send the shared instruction")
        #expect(systemPromptSeen, "the default summarizer did not send the shared system prompt")

        let recorded = try entries(of: await harness.sessionFilePath)
        let compaction = try #require(
            recorded.compactMap { entry -> Compaction? in
                if case .compaction(let compaction) = entry.payload { return compaction }
                return nil
            }.first
        )
        #expect(compaction.summary.hasPrefix("AUTOSUMMARY"))
        #expect(compaction.usage?.input == 777, "the default summarizer reported no usage for its own call")
    }

    @Test("a context overflow compacts the pre-failure branch and retries once")
    func overflowCompactsAndRetriesWithoutDuplicatingPrompt() async throws {
        let calls = Mutex<Int>(0)
        let streamFn: AgentStreamFn = { _ in
            let call = calls.withLock { value -> Int in
                let taken = value
                value += 1
                return taken
            }
            if call == 30 {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: DoMoError(.contextOverflow, "context length exceeded"))
                }
            }
            return terminalStream(AssistantMessage(
                content: [.text(String(repeating: "x", count: 4_000))],
                model: "test-model",
                stopReason: .stop
            ))
        }
        let spy = SummarizerSpy(text: "COMPACTED")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: streamFn,
                summarizer: spy.fn(),
                compaction: .default,
                contextWindow: nil,
                ids: SequentialIDs(prefix: "overflow")
            )
        )

        for index in 0..<30 {
            _ = try await harness.run(prompt: "turn-\(index)")
        }
        let result = try await harness.run(prompt: "turn-30")

        #expect(result.stopReason == .completed)
        #expect(result.failure == nil)
        #expect(calls.withLock { $0 } == 32, "one failed request plus one recovery request")
        #expect(spy.recorded.count == 1)

        let context = try await harness.contextMessages()
        #expect(!context.contains { message in
            guard case .assistant(let assistant) = message else { return false }
            return assistant.stopReason == .error
        })
        #expect(context.contains(.user("turn-30")), "the original prompt must be retained once")

        let recorded = try entries(of: await harness.sessionFilePath)
        #expect(recorded.contains { if case .compaction = $0.payload { true } else { false } })
    }

    /// `nil` means "genuinely unknown", and an unknown window is not a reason to
    /// let a context grow without limit — an unknown small alias would run until the
    /// provider rejected the request. The fallback is a compaction-only safety net,
    /// so a *known* larger window must still win over it.
    @Test("an unknown context window compacts against the fallback, a known one against itself")
    func unknownContextWindowUsesTheFallback() async throws {
        func harness(window: Int?, prefix: String, spy: SummarizerSpy) throws -> AgentHarness {
            let text = String(repeating: "a", count: 40)
            let responder = ScriptedResponder([
                assistant(text, usageInput: 250_000),
                assistant(text, usageInput: 250_000),
                assistant(text, usageInput: 250_000),
            ])
            return try AgentHarness.start(
                cwd: "/work/project",
                sessionDirectory: makeSessionDirectory(),
                configuration: configuration(
                    streamFn: responder.fn(),
                    summarizer: spy.fn(),
                    compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                    contextWindow: window,
                    ids: SequentialIDs(prefix: prefix)
                )
            )
        }
        let user = String(repeating: "b", count: 40)

        let unknownSpy = SummarizerSpy(text: "SUMMARY")
        let unknown = try harness(window: nil, prefix: "unk", spy: unknownSpy)
        #expect(try await unknown.accounting().contextWindow == nil,
                "an unknown window must not be reported as a number")
        _ = try await unknown.run(prompt: user)
        _ = try await unknown.run(prompt: user)
        _ = try await unknown.run(prompt: user)
        #expect(!unknownSpy.recorded.isEmpty, "an unknown window let the context grow unbounded")

        // 250K of context is comfortably inside a declared 1M window, so the same
        // session must NOT compact — proving the fallback is a fallback and not a
        // constant the check always uses.
        let knownSpy = SummarizerSpy(text: "SUMMARY")
        let known = try harness(window: 1_000_000, prefix: "kno", spy: knownSpy)
        _ = try await known.run(prompt: user)
        _ = try await known.run(prompt: user)
        _ = try await known.run(prompt: user)
        #expect(knownSpy.recorded.isEmpty, "a declared window was overruled by the fallback")
    }

    /// The shipped defaults (16384 + 20000) already exceed a 32K window, which made
    /// `shouldCompact` fire and `prepareCompaction` then return `nil` — the run
    /// proceeding over-full, with no entry written and nothing said.
    @Test("a window the compaction budgets would swallow clamps them; a roomy one does not")
    func compactionBudgetsAreClampedToTheWindow() {
        let stream: AgentStreamFn = { _ in AsyncThrowingStream { $0.finish() } }
        // The premise, asserted rather than assumed.
        #expect(CompactionSettings.default.reserveTokens + CompactionSettings.default.keepRecentTokens > 32_000)

        let small = AgentHarness.Configuration(
            model: "m",
            streamFn: stream,
            compaction: .default,
            contextWindow: 32_000
        )
        #expect(small.compaction.reserveTokens + small.compaction.keepRecentTokens <= 16_000)
        #expect(small.compaction.reserveTokens > 0)
        #expect(small.compaction.keepRecentTokens > 0)
        #expect(small.compaction.enabled)

        let roomy = AgentHarness.Configuration(
            model: "m",
            streamFn: stream,
            compaction: .default,
            contextWindow: 200_000
        )
        #expect(roomy.compaction == CompactionSettings.default, "a window with room to spare must change nothing")
    }

    /// The constructor's clamp is not the last word, and this is what makes the
    /// second one in `compactIfNeeded` load-bearing rather than defensive noise.
    /// ``AgentHarness/Configuration`` is a struct the caller keeps, and both
    /// `compaction` and `contextWindow` are `var`s: setting the window afterwards
    /// leaves budgets that were clamped against a completely different one.
    ///
    /// Delete the re-clamp and this session never compacts at all — and does so
    /// *silently*, which is the failure the clamp exists to prevent. A 1,000-token
    /// reserve against a 1,000-token window puts `shouldCompact`'s threshold at
    /// zero, so it fires on every turn; `prepareCompaction` then finds nothing
    /// older than a 1,000-token recent budget in a ~400-token path, returns `nil`,
    /// and the run proceeds over-full with no entry written and nothing said.
    @Test("a window set after construction re-clamps the budgets, so compaction still fires")
    func compactionReclampsAWindowChangedAfterConstruction() async throws {
        let asked = CompactionSettings(enabled: true, reserveTokens: 1_000, keepRecentTokens: 1_000)
        let text = String(repeating: "a", count: 400)
        let responder = ScriptedResponder([assistant(text, usageInput: 5_000)])
        let spy = SummarizerSpy(text: "SUMMARY")
        var config = configuration(
            streamFn: responder.fn(),
            summarizer: spy.fn(),
            compaction: asked,
            contextWindow: nil,
            ids: SequentialIDs(prefix: "rc")
        )
        // The premise: against the 200K fallback these budgets are roomy, so the
        // constructor's clamp left them exactly as written…
        #expect(config.compaction == asked, "the premise is budgets the constructor had no reason to touch")
        // …and now the pairing is broken from outside, which is the one thing a
        // clamp at construction cannot cover.
        config.contextWindow = 1_000

        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: config
        )
        let user = String(repeating: "b", count: 400)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        #expect(spy.recorded.count == 1, "compaction never summarized anything: the budgets were not re-clamped")
        let compactions = try entries(of: await harness.sessionFilePath).filter {
            if case .compaction = $0.payload { true } else { false }
        }
        #expect(compactions.count == 1, "no compaction entry was written")
    }

    @Test("compaction does not fire when disabled even over a tiny window")
    func compactionRespectsDisabled() async throws {
        let responder = ScriptedResponder([assistant("x", usageInput: 5000), assistant("y", usageInput: 5000)])
        let ids = SequentialIDs(prefix: "d")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                compaction: CompactionSettings(enabled: false),
                contextWindow: 100,
                ids: ids
            )
        )
        _ = try await harness.run(prompt: "one")
        _ = try await harness.run(prompt: "two")
        let recorded = try entries(of: await harness.sessionFilePath)
        #expect(!recorded.contains { if case .compaction = $0.payload { return true } else { return false } })
    }

    // MARK: - Fork

    @Test("fork copies the active path into a new file that names its parent")
    func forkCopiesPath() async throws {
        let dir = makeSessionDirectory()
        let responder = ScriptedResponder([assistant("answer")])
        let ids = SequentialIDs(prefix: "k")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: ids)
        )
        _ = try await harness.run(prompt: "hello")
        let originalPath = await harness.sessionFilePath

        let forked = try await harness.fork(sessionDirectory: dir)
        let forkedPath = await forked.sessionFilePath
        #expect(forkedPath != originalPath)

        let forkedStore = try JSONLSessionStore.open(path: forkedPath)
        let header = try forkedStore.readHeader()
        #expect(header.parentSession == originalPath.string)

        // Entry ids are preserved across the fork.
        let originalIDs = try entries(of: originalPath).map(\.id)
        let forkedIDs = try forkedStore.readEntries().map(\.id)
        #expect(forkedIDs == originalIDs)

        // The fork is independent: a run on it does not touch the original file.
        let responder2 = ScriptedResponder([assistant("forked answer")])
        let forked2 = try AgentHarness.open(
            path: forkedPath,
            configuration: configuration(streamFn: responder2.fn(), ids: SequentialIDs(prefix: "k2"))
        )
        _ = try await forked2.run(prompt: "on the fork")
        #expect(try entries(of: originalPath).count == 2)
        #expect(try forkedStore.readEntries().count == 4)
    }

    @Test("a second concurrent run is rejected")
    func rejectsReentrantRun() async throws {
        // A stream that blocks until released, so the first run is still in flight
        // when the second is attempted.
        let gate = Latch()
        let stream: AgentStreamFn = { _ in
            AsyncThrowingStream { continuation in
                Task {
                    await gate.wait()
                    let message = AssistantMessage(content: [.text("ok")], model: "test-model", stopReason: .stop)
                    continuation.yield(.done(message))
                    continuation.finish()
                }
            }
        }
        let ids = SequentialIDs(prefix: "g")
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: stream, ids: ids)
        )
        async let first: AgentRunResult = harness.run(prompt: "first")
        // Give the first run time to enter its loop and set the busy flag.
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: DoMoError.self) {
            _ = try await harness.run(prompt: "second")
        }
        gate.open()
        _ = try await first
    }
}

/// An async, one-shot gate. Opening it releases every current and future waiter.
private final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.open = true
            let pending = current.waiters
            current.waiters = []
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        if state.withLock({ $0.open }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { current -> Bool in
                if current.open { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
