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

/// Records the message lists handed to the summarizer and returns a fixed summary.
private final class SummarizerSpy: Sendable {
    private let calls = Mutex<[[Message]]>([])
    let text: String

    init(text: String) { self.text = text }

    var recorded: [[Message]] { calls.withLock { $0 } }

    func fn() -> Summarizer {
        { [self] messages in
            calls.withLock { $0.append(messages) }
            return text
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

/// A `Sendable`, lock-guarded message queue standing in for the interactive
/// steering box: a test appends to it from a streamFn (simulating a user typing
/// mid-run) and the harness's `getSteeringMessages` hook drains it.
private final class MessageQueue: Sendable {
    private let storage = Mutex<[Message]>([])
    func append(_ message: Message) { storage.withLock { $0.append(message) } }
    func drain() -> [Message] {
        storage.withLock { queued in
            let taken = queued
            queued.removeAll()
            return taken
        }
    }
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
        contextWindow: Int = 200_000,
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
        let queue = MessageQueue()
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
                queue.append(.user("also check the tests"))
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
        config.getSteeringMessages = { queue.drain() }

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
        #expect(summarized.count == 2)

        // The rebuilt context begins with the wrapped summary and then the tail.
        let context = try await harness.contextMessages()
        guard case .user(let first) = context.first else {
            Issue.record("context does not start with a user summary message")
            return
        }
        #expect(first.text.contains("SUMMARY"))
        #expect(first.text.contains("compacted into the following summary"))
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
