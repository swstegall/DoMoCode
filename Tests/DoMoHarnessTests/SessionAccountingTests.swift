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

    // MARK: - Numbers the provider chose

    /// A `Usage` as it actually arrives: decoded off a frame, with no bounds
    /// applied anywhere on the way in.
    private func wireUsage(input: Int, output: Int = 0) throws -> Usage {
        let json = """
            {"input":\(input),"output":\(output),"cacheRead":0,"cacheWrite":0,\
            "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
            """
        return try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    }

    /// Clamping ``DoMoLLM/Usage/totalTokens`` did not close this door — it moved the
    /// trap one frame down, from a client reading `/status` into the process that
    /// serves it. ``AgentHarness/accounting()`` runs the context estimate over the
    /// same unbounded number, and the estimate ADDS to it.
    ///
    /// The trailing user message is the whole point of the shape here. With the
    /// assistant turn last, it is the estimate's anchor and nothing is added to it,
    /// which is why every accounting test written before this one walked straight
    /// past the trap: the boundary is "is there a message after the anchor", and
    /// they were all on the safe side of it.
    @Test("an absurd provider-reported usage is accounted for rather than trapping the process")
    func absurdProviderUsageDoesNotTrapAccounting() async throws {
        let usage = try wireUsage(input: Int.max, output: Int.max)
        #expect(usage.input == Int.max, "the premise is a usage the decoder carried through unclamped")
        #expect(usage.totalTokens == Int.max, "the premise is a usage whose own total already saturated")

        let responder = Responder([assistant("answer", usage: usage)])
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeSessionDirectory(),
            configuration: configuration(streamFn: responder.fn(), contextWindow: 200_000, ids: IDs(prefix: "sat"))
        )
        _ = try await harness.run(prompt: "hello")
        // Anything after the anchor turns the estimate into `Int.max + n`.
        try await harness.persistMessage(.user("and one more thing"), elapsedMs: nil)

        let accounting = try await harness.accounting()
        #expect(accounting.contextTokens == Int.max, "the estimate did not clamp: \(accounting.contextTokens)")
        #expect(accounting.usage.input == Int.max)
        #expect(accounting.usage.totalTokens == Int.max)
        #expect(accounting.turns == 1)

        // The estimate's own parts must agree with the total it reports, or the
        // clamp merely hid the sum instead of saturating it.
        let estimate = estimateContextTokens(try await harness.contextMessages())
        #expect(estimate.usageTokens == Int.max)
        #expect(estimate.trailingTokens > 0, "the premise is a message after the anchor")
        #expect(estimate.tokens == Int.max)
    }

    /// The same number reaches compaction, which adds the standing summary's size to
    /// the estimate before deciding what to cut. This is the second frame down: the
    /// harness runs it *before every turn*, so a session whose provider reported an
    /// absurd count could not take another turn at all.
    @Test("a compaction over an absurd usage measures rather than trapping")
    func absurdProviderUsageDoesNotTrapCompactionMath() throws {
        let stamp = "2026-07-31T00:00:00.000Z"
        let absurd = try wireUsage(input: Int.max)
        let prior = SessionTreeEntry(
            id: "c0",
            parentId: nil,
            timestamp: stamp,
            payload: .compaction(Compaction(
                summary: "SUMMARY",
                tokensBefore: 10,
                retainedTail: [
                    .user("older"),
                    .assistant(assistant("answer", usage: absurd)),
                ]
            ))
        )
        let tail = SessionTreeEntry(
            id: "m1",
            parentId: "c0",
            timestamp: stamp,
            payload: .message(.user("and one more thing"))
        )

        let preparation = try #require(
            prepareCompaction(
                pathEntries: [prior, tail],
                settings: CompactionSettings(enabled: true, reserveTokens: 1, keepRecentTokens: 1)
            ),
            "the premise is a path with a prior checkpoint and something older than the recent budget"
        )
        #expect(preparation.previousSummary == "SUMMARY",
                "the premise is a standing summary whose size is added to the estimate")
        #expect(preparation.tokensBefore == Int.max,
                "the standing summary's size was added to a saturated estimate without clamping")
    }

    // MARK: - The wire form

    private func snapshot(costTotal: Decimal, contextWindow: Int? = nil) -> SessionAccounting {
        SessionAccounting(
            usage: Usage(input: 3, output: 4),
            costTotal: costTotal,
            contextTokens: 7,
            contextWindow: contextWindow,
            turns: 2
        )
    }

    private func encodedText(_ accounting: SessionAccounting) throws -> String {
        String(decoding: try JSONEncoder().encode(accounting), as: UTF8.self)
    }

    /// The print stream already publishes cost as a **string**
    /// (`PrintUsageEncoding.decimalString`) because a JSON number is parsed into an
    /// IEEE double by every non-Swift client, which is precisely the drift
    /// ``DoMoLLM/Cost`` chose `Decimal` to avoid. `/status` publishes the same
    /// quantity, so it must spell it the same way; two published surfaces
    /// disagreeing about one number is the defect, not a risk of one.
    @Test("costTotal crosses the wire as an exact decimal string, not as a JSON number")
    func costTotalEncodesAsAString() throws {
        let value = try #require(Decimal(string: "0.000000123456789"))
        let text = try encodedText(snapshot(costTotal: value))
        #expect(text.contains(#""costTotal":"0.000000123456789""#),
                "costTotal was not published as an exact decimal string: \(text)")
    }

    @Test("an exact decimal survives the round trip unchanged, integers and zero included")
    func decimalRoundTripsExactly() throws {
        for spelling in ["0", "8", "0.000000123456789", "1234567890.123456789012345"] {
            let value = try #require(Decimal(string: spelling))
            let original = snapshot(costTotal: value, contextWindow: 128_000)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SessionAccounting.self, from: data)
            #expect(decoded.costTotal == value, "\(spelling) came back as \(decoded.costTotal)")
            #expect(decoded == original, "the round trip changed something other than the cost: \(spelling)")
        }
    }

    /// A `/status` payload whose `costTotal` is spelled `literal`.
    ///
    /// The `usage` half is produced by encoding a real ``DoMoLLM/Usage`` rather than
    /// written out by hand, so this fixture pins the one field it is about and stays
    /// correct if `Usage`'s own wire form ever changes underneath it.
    private func payload(costTotalLiteral literal: String) throws -> Data {
        let usage = String(decoding: try JSONEncoder().encode(Usage(input: 3, output: 4)), as: UTF8.self)
        return Data(#"{"usage":\#(usage),"costTotal":\#(literal),"contextTokens":7,"turns":2}"#.utf8)
    }

    /// An older server wrote `costTotal` as a JSON number. Still accepting that
    /// shape is what lets the encoding change without bumping the protocol version:
    /// the tolerance is on the reading side only, and deliberately — the wire form
    /// itself has exactly one spelling, and it is the lossless one.
    @Test("a payload that spells costTotal as a JSON number still decodes")
    func theOlderNumberSpellingStillDecodes() throws {
        let decoded = try JSONDecoder().decode(SessionAccounting.self, from: try payload(costTotalLiteral: "0.25"))
        #expect(decoded.costTotal == Decimal(string: "0.25"))
        #expect(decoded.contextWindow == nil, "an absent window must decode as unknown")
        #expect(decoded.usage.input == 3)
        #expect(decoded.turns == 2)
    }

    /// A total that could not be read is not a total of nothing.
    @Test("a costTotal that is not a number is refused rather than read as zero")
    func anUnparseableCostTotalThrows() throws {
        let data = try payload(costTotalLiteral: #""free""#)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SessionAccounting.self, from: data)
        }
    }

    /// `"free"` is the easy half of that rule and it hid the hard half: bare
    /// `Decimal(string:)` does not refuse a string that merely *begins* with a
    /// number, it **prefix-parses** it. Every spelling below came back as a
    /// plausible, wrong total that nobody sent —
    ///
    ///     "0.25 dollars" -> 0.25      "0.25xyz" -> 0.25
    ///     "1_000"        -> 1         "0x10"    -> 0
    ///
    /// — which is a session's entire reported spend, off by up to three orders of
    /// magnitude, with nothing anywhere saying so. It is locale-influenced as well:
    /// the same body read where the decimal separator is a comma means something
    /// else again. `LiteLLM.parseResponseCost` already defends the identical hazard
    /// on `x-litellm-response-cost` with a strict whole-string grammar, and this is
    /// the same quantity crossing the same kind of boundary, so it uses the same
    /// grammar — the one in ``DoMoLLM/DecimalText``, not a second copy of it.
    @Test("a costTotal string is parsed whole, never prefix-parsed into a wrong price")
    func aPrefixParseableCostTotalIsRefused() throws {
        let refused = [
            "0.25 dollars", "0.25xyz", "1_000", "0x10",
            // Neighbours of the same grammar, so the fix cannot be a substring check
            // against the four above: a trailing comma-joined duplicate header, the
            // spellings `Decimal` accepts and this does not, and empty text.
            "0.001, 0.001", ".5", "5.", "1,5", "", " ", "NaN", "Infinity", "+", "1e", "1e+",
        ]
        for spelling in refused {
            let data = try payload(costTotalLiteral: "\"\(spelling)\"")
            #expect(throws: DecodingError.self, "\"\(spelling)\" was accepted as a cost total") {
                _ = try JSONDecoder().decode(SessionAccounting.self, from: data)
            }
        }
    }

    /// What the strictness must NOT cost: every spelling a real payload carries has
    /// to keep decoding, exponent form included — LiteLLM stringifies a Python
    /// float, so `1e-05` is what a small per-request cost actually looks like — and
    /// surrounding whitespace is trimmed rather than treated as corruption.
    @Test("the spellings a real payload uses still decode, exactly")
    func strictParsingStillAcceptsRealPayloads() throws {
        let accepted: [(String, String)] = [
            ("0", "0"), ("8", "8"), ("0.25", "0.25"), ("1e-05", "0.00001"), ("1E-05", "0.00001"),
            ("-0.5", "-0.5"), ("+0.5", "0.5"), (" 0.25 ", "0.25"),
            ("0.000000123456789", "0.000000123456789"),
        ]
        for (spelling, expected) in accepted {
            let data = try payload(costTotalLiteral: "\"\(spelling)\"")
            let decoded = try JSONDecoder().decode(SessionAccounting.self, from: data)
            #expect(decoded.costTotal == Decimal(string: expected, locale: nil),
                    "\"\(spelling)\" decoded as \(decoded.costTotal)")
        }
    }

    /// The hand-written encoder has to keep every other field's shape byte-for-byte,
    /// and this is the one that is not merely cosmetic: an unknown window must write
    /// **no key**, because a client cannot tell a `null` — or worse, a fallback
    /// number — from a measured one.
    @Test("an unknown context window still writes no key at all")
    func anUnknownWindowWritesNoKey() throws {
        let unknown = try encodedText(snapshot(costTotal: 1, contextWindow: nil))
        #expect(!unknown.contains("contextWindow"), "an unknown window encoded a key: \(unknown)")
        #expect(unknown.contains(#""contextTokens":7"#), "the payload lost a field: \(unknown)")
        let known = try encodedText(snapshot(costTotal: 1, contextWindow: 128_000))
        #expect(known.contains(#""contextWindow":128000"#), "a known window was not published: \(known)")
    }
}
