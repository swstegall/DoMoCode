import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

// MARK: - Test support

/// A monotonic clock that advances by a fixed step on every read.
///
/// Deterministic where a real clock is not: two reads bracketing one message
/// therefore always differ by exactly `step`, so an elapsed assertion can pin an
/// exact number instead of the useless `>= 0` this project has been bitten by.
/// A negative step models a clock that runs backwards, which a `ContinuousClock`
/// cannot do and an injected one can.
private final class SteppingClock: Sendable {
    private let base = ContinuousClock.Instant.now
    private let step: Duration
    private let reads = Mutex<Int>(0)

    init(step: Duration) { self.step = step }

    var readCount: Int { reads.withLock { $0 } }

    func fn() -> @Sendable () -> ContinuousClock.Instant {
        { [self] in
            let taken = reads.withLock { current -> Int in
                let value = current
                current += 1
                return value
            }
            return base.advanced(by: step * taken)
        }
    }
}

private final class TimingResponder: Sendable {
    private let responses: [AssistantMessage]
    private let index = Mutex<Int>(0)

    init(_ responses: [AssistantMessage]) { self.responses = responses }

    func fn() -> AgentStreamFn {
        { [self] _ in
            let i = index.withLock { current -> Int in
                let value = current
                current += 1
                return value
            }
            let message = responses[min(i, responses.count - 1)]
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: message.model)))
                continuation.yield(message.failure == nil ? .done(message) : .failed(message))
                continuation.finish()
            }
        }
    }
}

private final class TimingIDs: Sendable {
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

/// Records every event so the pairing of message boundaries can be checked rather
/// than assumed.
private final class EventLog: AgentEventSink {
    private let storage = Mutex<[AgentEvent]>([])
    func emit(_ event: AgentEvent) async { storage.withLock { $0.append(event) } }
    var events: [AgentEvent] { storage.withLock { $0 } }
}

/// Captures what a persistence sink asks to be written, with the interval it
/// measured.
private final class RecordingPersister: SessionMessagePersisting {
    struct Recorded: Sendable {
        var message: Message
        var elapsedMs: Int?
    }

    private let storage = Mutex<[Recorded]>([])

    func persistMessage(_ message: Message, elapsedMs: Int?) async throws {
        storage.withLock { $0.append(Recorded(message: message, elapsedMs: elapsedMs)) }
    }

    var recorded: [Recorded] { storage.withLock { $0 } }
}

private struct TimingEchoTool: AgentTool {
    let definition = ToolDefinition(name: "echo", description: "echo", parameters: JSONSchema())
    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        AgentToolResult(output: "echoed")
    }
}

@Suite("Session timing and ordering")
struct SessionTimingTests {
    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-timing-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func assistant(_ text: String, usageInput: Int = 0) -> AssistantMessage {
        AssistantMessage(
            content: [.text(text)],
            model: "test-model",
            usage: Usage(input: usageInput),
            stopReason: .stop
        )
    }

    private func configuration(
        streamFn: @escaping AgentStreamFn,
        tools: [any AgentTool] = [],
        summarizer: Summarizer? = nil,
        compaction: CompactionSettings = CompactionSettings(enabled: false),
        contextWindow: Int? = nil,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        ids: TimingIDs
    ) -> AgentHarness.Configuration {
        AgentHarness.Configuration(
            tools: tools,
            model: "test-model",
            streamFn: streamFn,
            summarizer: summarizer,
            toolExecution: .sequential,
            compaction: compaction,
            contextWindow: contextWindow,
            now: { self.fixedDate },
            monotonicNow: monotonicNow,
            entryIDFactory: ids.factory()
        )
    }

    private func entries(of path: FilePath) throws -> [SessionTreeEntry] {
        try JSONLSessionStore.open(path: path).readEntries()
    }

    // MARK: - The assumption the stopwatch rests on

    /// A single-slot stopwatch is only correct if message boundaries never nest and
    /// never overlap. The turn events explicitly do not have that property — the
    /// `maxTurns` return sits before a `turnStart`, and an aborted settle emits a
    /// `turnEnd` for an iteration whose `turnStart` never fired — so this is checked
    /// rather than assumed for the events the stopwatch actually uses.
    @Test("message start and end events are strictly paired, never nested")
    func messageEventsAreStrictlyPaired() async throws {
        let responder = TimingResponder([
            AssistantMessage(
                content: [.toolCall(ToolCallBlock(id: "c1", name: "echo"))],
                model: "test-model",
                stopReason: .toolUse
            ),
            assistant("done"),
        ])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                tools: [TimingEchoTool()],
                ids: TimingIDs(prefix: "pair")
            )
        )
        let log = EventLog()
        _ = try await harness.run(prompt: "please echo", sink: log)

        var open = 0
        var deepest = 0
        var pairs = 0
        for event in log.events {
            switch event {
            case .messageStart:
                open += 1
                deepest = max(deepest, open)
            case .messageEnd:
                open -= 1
                pairs += 1
                #expect(open >= 0, "a messageEnd arrived with no messageStart ahead of it")
            default:
                break
            }
        }
        #expect(open == 0, "a messageStart was never closed")
        #expect(deepest == 1, "message boundaries nested — a single-slot stopwatch would mis-measure")
        // user, assistant(tool call), tool result, assistant(done).
        #expect(pairs == 4)
    }

    // MARK: - Elapsed measurement

    @Test("every persisted message carries the interval measured across its own boundaries")
    func messagesCarryMeasuredElapsedTime() async throws {
        let clock = SteppingClock(step: .milliseconds(7))
        let responder = TimingResponder([assistant("hi there")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                monotonicNow: clock.fn(),
                ids: TimingIDs(prefix: "ms")
            )
        )
        _ = try await harness.run(prompt: "hello")

        let recorded = try entries(of: await harness.sessionFilePath)
        #expect(recorded.count == 2)
        // Two reads bracket each message, and the clock advances 7ms per read. A
        // `compactMap` so an unmeasured entry shortens the list and fails, rather
        // than needing an optional literal on the right.
        #expect(recorded.compactMap(\.elapsedMs) == [7, 7])
        #expect(clock.readCount == 4, "the stopwatch read the clock a different number of times than it timed")
    }

    /// `nil` is "nothing was measured". `0` would be a claim about a stopwatch
    /// nobody started, and it is indistinguishable on the wire from a genuinely
    /// instantaneous message.
    @Test("a clock that runs backwards yields no measurement rather than a zero one")
    func backwardsClockMeasuresNothing() async throws {
        let clock = SteppingClock(step: .milliseconds(-10))
        let responder = TimingResponder([assistant("hi")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                monotonicNow: clock.fn(),
                ids: TimingIDs(prefix: "back")
            )
        )
        _ = try await harness.run(prompt: "hello")

        let recorded = try entries(of: await harness.sessionFilePath)
        #expect(recorded.count == 2)
        let measured = recorded.compactMap(\.elapsedMs)
        #expect(measured.isEmpty, "a negative interval was laundered into a number: \(measured)")
    }

    /// A compaction checkpoint is not a `Message` and never travels the event
    /// stream, so the sink can never see it. If it is not timed where it is built,
    /// the single most expensive thing a session does is the one thing with no
    /// duration recorded.
    @Test("the compaction entry is stamped with how long its summarization took")
    func compactionEntryIsTimed() async throws {
        let clock = SteppingClock(step: .milliseconds(3))
        let text = String(repeating: "a", count: 40)
        let responder = TimingResponder([assistant(text, usageInput: 5000)])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: { _ in SummarizerResult(text: "SUMMARY") },
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                monotonicNow: clock.fn(),
                ids: TimingIDs(prefix: "ct")
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        let recorded = try entries(of: await harness.sessionFilePath)
        let compactions = recorded.filter { if case .compaction = $0.payload { true } else { false } }
        #expect(compactions.count == 1, "the premise is a session that compacted exactly once")
        let checkpoint = try #require(compactions.first)
        #expect(checkpoint.elapsedMs == 3, "the summarization call was never timed")
    }

    // MARK: - The sink's stopwatch, directly

    @Test("the sink times a message across its own boundaries and clears the slot after")
    func sinkStopwatchMeasuresAndClears() async {
        let persister = RecordingPersister()
        let clock = SteppingClock(step: .milliseconds(5))
        let sink = SessionPersistenceSink(
            persister: persister,
            errorBox: PersistenceErrorBox(),
            monotonicNow: clock.fn()
        )
        await sink.emit(.messageStart(.user("hi")))
        await sink.emit(.messageEnd(.user("hi")))
        // A second end with no start ahead of it: the slot was cleared, so nothing
        // is measured rather than a stale instant being reused.
        await sink.emit(.messageEnd(.user("bye")))

        let recorded = persister.recorded
        #expect(recorded.count == 2)
        #expect(recorded[0].elapsedMs == 5)
        #expect(recorded[1].elapsedMs == nil, "a cleared stopwatch was re-read and produced a fabricated interval")
    }

    /// The widened requirement is on a public protocol, so the old spelling has to
    /// keep working for an embedding that implements or calls it.
    @Test("the pre-timing persistMessage spelling still works and reports no measurement")
    func legacyPersistSpellingForwards() async throws {
        let persister = RecordingPersister()
        try await persister.persistMessage(.user("no stopwatch here"))
        #expect(persister.recorded.count == 1)
        #expect(persister.recorded[0].elapsedMs == nil)
        #expect(persister.recorded[0].message == .user("no stopwatch here"))
    }

    // MARK: - Ordering keys

    @Test("entries are numbered in append order and a resumed harness continues past the file")
    func seqNumbersAppendOrderAndResumes() async throws {
        let responder = TimingResponder([assistant("one"), assistant("two")])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: TimingIDs(prefix: "sq"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath
        #expect(try entries(of: path).compactMap(\.seq) == [0, 1])

        let resumed = try AgentHarness.open(
            path: path,
            configuration: configuration(streamFn: responder.fn(), ids: TimingIDs(prefix: "sr"))
        )
        _ = try await resumed.run(prompt: "second")
        #expect(try entries(of: path).compactMap(\.seq) == [0, 1, 2, 3],
                "a resumed session restarted its numbering and collided with the file")
    }

    /// The key is assigned to an entry that was written. A failed append must not
    /// consume one, or a gap in the file corresponds to nothing that ever existed.
    @Test("an append that throws does not burn an ordering key")
    func failedAppendDoesNotBurnASeq() async throws {
        let responder = TimingResponder([assistant("one")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: TimingIDs(prefix: "burn"))
        )
        _ = try await harness.run(prompt: "first")
        let path = await harness.sessionFilePath
        #expect(try entries(of: path).compactMap(\.seq) == [0, 1])

        // Take the whole directory out from under the store so the next append
        // cannot open the file at all, then put the file back byte-for-byte.
        let saved = try String(contentsOfFile: path.string, encoding: .utf8)
        let directory = path.removingLastComponent()
        try FileManager.default.removeItem(atPath: directory.string)
        await #expect(throws: DoMoError.self) {
            try await harness.persistMessage(.user("this cannot be written"))
        }
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        try saved.write(toFile: path.string, atomically: true, encoding: .utf8)

        try await harness.persistMessage(.user("this one lands"))
        #expect(try entries(of: path).compactMap(\.seq) == [0, 1, 2],
                "the failed append consumed an ordering key")
    }

    @Test("a fork continues numbering past everything its own file already carries")
    func forkNumbersPastItsOwnFile() async throws {
        let dir = makeSessionDirectory()
        let responder = TimingResponder([assistant("one"), assistant("forked")])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: TimingIDs(prefix: "fk"))
        )
        _ = try await harness.run(prompt: "first")

        let forked = try await harness.fork(sessionDirectory: dir)
        let forkedPath = await forked.sessionFilePath
        let inherited = try entries(of: forkedPath).compactMap(\.seq)
        _ = try await forked.run(prompt: "on the fork")

        let after = try entries(of: forkedPath)
        let appended = after.suffix(2).compactMap(\.seq)
        #expect(appended.count == 2, "the fork's own appends carry no ordering key")
        let highestInherited = inherited.max() ?? -1
        #expect(appended.allSatisfy { $0 > highestInherited },
                "the fork reused an ordering key its file already contains")
        #expect(appended == [highestInherited + 1, highestInherited + 2])
    }
}
