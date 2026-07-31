import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

// MARK: - Test support

/// Replays one canned assistant message per call, in order, as a terminal-only
/// assembly stream. The last scripted message repeats.
private final class Responder: Sendable {
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

/// Returns a fixed summary plus the usage a real summarization call would report.
private final class Summarizing: Sendable {
    private let calls = Mutex<Int>(0)
    private let text: String
    private let usage: Usage?

    init(text: String, usage: Usage? = nil) {
        self.text = text
        self.usage = usage
    }

    var callCount: Int { calls.withLock { $0 } }

    func fn() -> Summarizer {
        { [self] _ in
            calls.withLock { $0 += 1 }
            return SummarizerResult(text: text, usage: usage)
        }
    }
}

private final class IDs: Sendable {
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

@Suite("SessionAccounting")
struct SessionAccountingTests {
    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-accounting-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func assistant(_ text: String, usage: Usage) -> AssistantMessage {
        AssistantMessage(content: [.text(text)], model: "test-model", usage: usage, stopReason: .stop)
    }

    private func configuration(
        streamFn: @escaping AgentStreamFn,
        summarizer: Summarizer? = nil,
        compaction: CompactionSettings = CompactionSettings(enabled: false),
        contextWindow: Int? = nil,
        ids: IDs
    ) -> AgentHarness.Configuration {
        AgentHarness.Configuration(
            model: "test-model",
            streamFn: streamFn,
            summarizer: summarizer,
            compaction: compaction,
            contextWindow: contextWindow,
            now: { self.fixedDate },
            entryIDFactory: ids.factory()
        )
    }

    // MARK: - The empty case

    @Test("a session with no entries accounts for nothing, and says so rather than guessing")
    func freshSessionAccountsNothing() async throws {
        let responder = Responder([assistant("hi", usage: Usage(input: 1))])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: IDs(prefix: "e"))
        )
        let accounting = try await harness.accounting()
        #expect(accounting.usage == .zero)
        #expect(accounting.costTotal == 0)
        #expect(accounting.contextTokens == 0)
        #expect(accounting.turns == 0)
        #expect(accounting.contextWindow == nil)
    }

    // MARK: - Accumulation

    @Test("assistant usage accumulates across a session's turns, and turns are counted")
    func usageAccumulatesAcrossTurns() async throws {
        let responder = Responder([
            assistant("one", usage: Usage(input: 100, output: 10)),
            assistant("two", usage: Usage(input: 200, output: 20)),
        ])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), contextWindow: 50_000, ids: IDs(prefix: "a"))
        )
        _ = try await harness.run(prompt: "first")
        let afterOne = try await harness.accounting()
        #expect(afterOne.usage.input == 100)
        #expect(afterOne.usage.output == 10)
        #expect(afterOne.turns == 1)

        _ = try await harness.run(prompt: "second")
        let afterTwo = try await harness.accounting()
        #expect(afterTwo.usage.input == 300)
        #expect(afterTwo.usage.output == 20 + 10)
        #expect(afterTwo.turns == 2)
        #expect(afterTwo.contextWindow == 50_000)
    }

    /// The contract's standing rule: anyone summing session cost reads
    /// ``DoMoLLM/Usage/effectiveCostTotal``, never `cost.total`. A session that mixes
    /// a turn the gateway priced with a turn only local rates priced would otherwise
    /// report a total missing the gateway's number entirely.
    @Test("costTotal is the effective total, not the rate-derived breakdown's sum")
    func costTotalPrefersTheGatewaysNumber() async throws {
        let priced = assistant(
            "one",
            usage: Usage(input: 100, cost: Cost(input: 2), reportedCost: 5)
        )
        let unpriced = assistant("two", usage: Usage(input: 200, cost: Cost(input: 3)))
        let responder = Responder([priced, unpriced])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: IDs(prefix: "c"))
        )
        _ = try await harness.run(prompt: "first")
        _ = try await harness.run(prompt: "second")

        let accounting = try await harness.accounting()
        // The rate-derived breakdown alone says 5 — it never saw the gateway's price.
        #expect(accounting.usage.cost.total == 5)
        // The honest answer is the gateway's 5 for the first turn plus the local 3
        // for the second.
        #expect(accounting.costTotal == 8)
    }

    // MARK: - Context size

    @Test("contextTokens is the size of the context the next turn would send")
    func contextTokensMatchesTheNextTurnsContext() async throws {
        let responder = Responder([assistant("answer", usage: Usage(input: 100))])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), ids: IDs(prefix: "t"))
        )
        _ = try await harness.run(prompt: "hello")

        let accounting = try await harness.accounting()
        let expected = estimateContextTokens(try await harness.contextMessages()).tokens
        #expect(accounting.contextTokens == expected)
        // Anchored on the assistant turn's own reported usage, not on a character
        // count of two short messages.
        #expect(accounting.contextTokens == 100)
    }

    // MARK: - Resume

    @Test("a resumed harness recovers the session's totals by walking the file")
    func resumeRecoversTotals() async throws {
        let dir = makeSessionDirectory()
        let responder = Responder([
            assistant("one", usage: Usage(input: 100, output: 10, cost: Cost(input: 1), reportedCost: 4)),
            assistant("two", usage: Usage(input: 200, output: 20)),
        ])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), contextWindow: 50_000, ids: IDs(prefix: "l"))
        )
        _ = try await live.run(prompt: "first")
        _ = try await live.run(prompt: "second")
        let path = await live.sessionFilePath
        let liveAccounting = try await live.accounting()
        #expect(liveAccounting.turns == 2, "the premise is a session with turns to recover")
        #expect(liveAccounting.costTotal > 0)

        let resumed = try AgentHarness.open(
            path: path,
            configuration: configuration(
                streamFn: responder.fn(),
                contextWindow: 50_000,
                ids: IDs(prefix: "r")
            )
        )
        #expect(try await resumed.accounting() == liveAccounting,
                "a resumed session reported different totals for the same file")
    }

    @Test("a resumed harness keeps accumulating from where the file left off")
    func resumeThenContinueKeepsAccumulating() async throws {
        let dir = makeSessionDirectory()
        let responder = Responder([assistant("one", usage: Usage(input: 100))])
        let live = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: dir,
            configuration: configuration(streamFn: responder.fn(), ids: IDs(prefix: "l"))
        )
        _ = try await live.run(prompt: "first")
        let path = await live.sessionFilePath

        let resumed = try AgentHarness.open(
            path: path,
            configuration: configuration(
                streamFn: Responder([assistant("two", usage: Usage(input: 250))]).fn(),
                ids: IDs(prefix: "r")
            )
        )
        _ = try await resumed.run(prompt: "second")
        let accounting = try await resumed.accounting()
        #expect(accounting.usage.input == 350, "the resumed run restarted the total instead of continuing it")
        #expect(accounting.turns == 2)
    }

    // MARK: - Summarization cost

    /// A compaction is a real, billable model call. Before ``Summarizer`` returned
    /// usage there was no path by which its price could reach a total, so every
    /// session looked cheapest exactly where it worked hardest.
    @Test("a compaction's summarization usage is folded into the session's totals")
    func compactionUsageIsBilled() async throws {
        let text = String(repeating: "a", count: 40)
        let responder = Responder([assistant(text, usage: Usage(input: 5000))])
        let summarizer = Summarizing(text: "SUMMARY", usage: Usage(input: 321, output: 9))
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: summarizer.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: IDs(prefix: "k")
            )
        )
        let user = String(repeating: "b", count: 40)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)
        _ = try await harness.run(prompt: user)

        #expect(summarizer.callCount == 1, "the premise is a session that compacted exactly once")
        let accounting = try await harness.accounting()
        // Three assistant turns at 5,000 input each, plus the summarization call's
        // own 321 input and 9 output.
        #expect(accounting.usage.input == 3 * 5000 + 321)
        #expect(accounting.usage.output == 9)
        // A summarization is not a conversational turn.
        #expect(accounting.turns == 3)

        // …and the same numbers come back from the file alone.
        let resumed = try AgentHarness.open(
            path: await harness.sessionFilePath,
            configuration: configuration(
                streamFn: responder.fn(),
                summarizer: summarizer.fn(),
                compaction: CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 25),
                contextWindow: 1000,
                ids: IDs(prefix: "kr")
            )
        )
        #expect(try await resumed.accounting() == accounting)
    }

    /// The harness has no branch-summary append path of its own yet, but the seed
    /// walk has to fold one when a file carries it — otherwise the first component
    /// that writes one silently loses its cost on every subsequent resume.
    @Test("a branch summary already in the file contributes its usage on open")
    func branchSummaryUsageIsSeeded() async throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(
            cwd: "/work/project",
            sessionDirectory: dir,
            sessionID: "s1",
            now: { self.fixedDate },
            entryIDFactory: IDs(prefix: "b").factory()
        )
        let stamp = "2026-07-31T00:00:00.000Z"
        try store.appendEntry(
            SessionTreeEntry(
                id: "m0",
                parentId: nil,
                timestamp: stamp,
                payload: .message(.assistant(assistant("hi", usage: Usage(input: 40))))
            )
        )
        try store.appendEntry(
            SessionTreeEntry(
                id: "b0",
                parentId: "m0",
                timestamp: stamp,
                payload: .branchSummary(BranchSummary(fromId: "m0", summary: "aside", usage: Usage(input: 11)))
            )
        )

        let responder = Responder([assistant("x", usage: .zero)])
        let harness = try AgentHarness.open(
            path: store.path,
            configuration: configuration(streamFn: responder.fn(), ids: IDs(prefix: "bo"))
        )
        let accounting = try await harness.accounting()
        #expect(accounting.usage.input == 51, "the branch summary's usage was not folded into the total")
        #expect(accounting.turns == 1, "a branch summary was counted as a conversational turn")
    }
}
