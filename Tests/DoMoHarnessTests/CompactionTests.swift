import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite("Compaction")
struct CompactionTests {
    // MARK: - Fixtures

    /// A user message whose text is `count` characters, so its estimate is a
    /// known `ceil(count / 4)`.
    private func user(chars count: Int) -> Message {
        .user(UserMessage(content: [.text(String(repeating: "x", count: count))]))
    }

    /// An assistant message carrying a fixed context `Usage`, so it can anchor
    /// the token estimate.
    private func assistant(text: String = "", totalTokens: Int, stopReason: StopReason = .stop) -> Message {
        .assistant(
            AssistantMessage(
                content: text.isEmpty ? [] : [.text(text)],
                model: "test-model",
                usage: Usage(input: totalTokens),
                stopReason: stopReason
            )
        )
    }

    private func entry(_ payload: SessionTreeEntry.Payload, id: String, parent: String?) -> SessionTreeEntry {
        SessionTreeEntry(id: id, parentId: parent, timestamp: "2026-07-23T12:00:00.000Z", payload: payload)
    }

    // MARK: - Token estimation

    @Test("estimateTokens is ceil(chars / 4) over user text")
    func estimateTokensUser() {
        #expect(estimateTokens(user(chars: 0)) == 0)
        #expect(estimateTokens(user(chars: 1)) == 1)
        #expect(estimateTokens(user(chars: 4)) == 1)
        #expect(estimateTokens(user(chars: 5)) == 2)
        #expect(estimateTokens(user(chars: 400)) == 100)
    }

    @Test("estimateTokens counts assistant text, reasoning, and tool-call name plus arguments")
    func estimateTokensAssistant() {
        let call = ToolCallBlock(id: "1", name: "read", arguments: .object(["path": .string("/a")]))
        let message = Message.assistant(
            AssistantMessage(
                content: [.text("hello"), .reasoning(ReasoningBlock(text: "think")), .toolCall(call)],
                model: "m"
            )
        )
        // "hello"=5 + "think"=5 + "read"=4 + {"path":"/a"}=13 == 27 -> ceil(27/4)=7
        let argsChars = (try? call.arguments.encodedString())?.count ?? 0
        let expected = (5 + 5 + 4 + argsChars + 3) / 4
        #expect(estimateTokens(message) == expected)
    }

    @Test("calculateContextTokens is the usage total")
    func calculateContextTokensSumsUsage() {
        let usage = Usage(input: 100, output: 20, cacheRead: 5, cacheWrite: 3)
        #expect(calculateContextTokens(usage) == 128)
    }

    @Test("estimateContextTokens with no assistant usage sums the heuristic")
    func estimateContextNoUsage() {
        let messages = [user(chars: 400), user(chars: 40)]
        let estimate = estimateContextTokens(messages)
        #expect(estimate.tokens == 110)
        #expect(estimate.usageTokens == 0)
        #expect(estimate.trailingTokens == 110)
        #expect(estimate.lastUsageIndex == nil)
    }

    @Test("estimateContextTokens anchors on the last assistant usage and estimates the tail")
    func estimateContextAnchored() {
        let messages = [
            user(chars: 4000),
            assistant(totalTokens: 500),
            user(chars: 400),
        ]
        let estimate = estimateContextTokens(messages)
        // Anchor at index 1 (500 usage tokens); trailing = ceil(400/4)=100.
        #expect(estimate.usageTokens == 500)
        #expect(estimate.trailingTokens == 100)
        #expect(estimate.tokens == 600)
        #expect(estimate.lastUsageIndex == 1)
    }

    @Test("aborted and errored assistant turns are not valid usage anchors")
    func abortedUsageIgnored() {
        let messages = [assistant(totalTokens: 500, stopReason: .aborted)]
        let estimate = estimateContextTokens(messages)
        #expect(estimate.usageTokens == 0)
        #expect(estimate.lastUsageIndex == nil)
    }

    @Test("getLastAssistantUsage returns the most recent valid assistant usage")
    func lastAssistantUsage() {
        let entries = [
            entry(.message(assistant(totalTokens: 100)), id: "a", parent: nil),
            entry(.message(user(chars: 10)), id: "b", parent: "a"),
            entry(.message(assistant(totalTokens: 300)), id: "c", parent: "b"),
            entry(.message(assistant(totalTokens: 999, stopReason: .error)), id: "d", parent: "c"),
        ]
        #expect(getLastAssistantUsage(entries)?.totalTokens == 300)
    }

    @Test("getLastAssistantUsage is nil when no assistant turn carries usage")
    func lastAssistantUsageNone() {
        let entries = [entry(.message(user(chars: 10)), id: "a", parent: nil)]
        #expect(getLastAssistantUsage(entries) == nil)
    }

    // MARK: - Threshold

    @Test("shouldCompact fires only over the window minus reserve")
    func shouldCompactThreshold() {
        let settings = CompactionSettings(reserveTokens: 1000)
        let window = 10_000
        // threshold = 9000
        #expect(shouldCompact(contextTokens: 8999, contextWindow: window, settings: settings) == false)
        #expect(shouldCompact(contextTokens: 9000, contextWindow: window, settings: settings) == false)
        #expect(shouldCompact(contextTokens: 9001, contextWindow: window, settings: settings) == true)
    }

    @Test("shouldCompact is disabled when settings say so")
    func shouldCompactDisabled() {
        let settings = CompactionSettings(enabled: false, reserveTokens: 1000)
        #expect(shouldCompact(contextTokens: 1_000_000, contextWindow: 10_000, settings: settings) == false)
    }

    @Test("default settings match pi's reserve and keep-recent budgets")
    func defaultSettings() {
        #expect(CompactionSettings.default.enabled)
        #expect(CompactionSettings.default.reserveTokens == 16384)
        #expect(CompactionSettings.default.keepRecentTokens == 20000)
    }

    // MARK: - File-operations digest

    @Test("computeFileLists demotes read-then-modified files to modified only")
    func fileListsDemotion() {
        var ops = FileOperations()
        ops.read = ["/a", "/b", "/c"]
        ops.edited = ["/b"]
        ops.written = ["/c"]
        let lists = computeFileLists(ops)
        #expect(lists.readFiles == ["/a"])
        #expect(lists.modifiedFiles == ["/b", "/c"])
    }

    @Test("fileOperations reads read/write/edit tool calls off assistant messages")
    func extractDigest() {
        func call(_ name: String, _ path: String) -> ContentBlock {
            .toolCall(ToolCallBlock(id: path, name: name, arguments: .object(["path": .string(path)])))
        }
        let messages: [Message] = [
            .assistant(AssistantMessage(content: [call("read", "/r"), call("edit", "/e"), call("write", "/w")], model: "m")),
            .assistant(AssistantMessage(content: [call("grep", "/ignored")], model: "m")),
        ]
        let ops = fileOperations(from: messages)
        #expect(ops.read == ["/r"])
        #expect(ops.edited == ["/e"])
        #expect(ops.written == ["/w"])
        let lists = computeFileLists(ops)
        let digest = formatFileOperations(readFiles: lists.readFiles, modifiedFiles: lists.modifiedFiles)
        #expect(digest.contains("<read-files>\n/r\n</read-files>"))
        #expect(digest.contains("<modified-files>\n/e\n/w\n</modified-files>"))
    }

    @Test("formatFileOperations is empty when nothing was touched")
    func emptyDigest() {
        #expect(formatFileOperations(readFiles: [], modifiedFiles: []) == "")
    }

    // MARK: - Selection

    /// A path of `count` alternating user/assistant message entries, each ~40
    /// chars (≈10 tokens per message), rooted with `nil` parent.
    private func alternatingPath(count: Int) -> [SessionTreeEntry] {
        var entries: [SessionTreeEntry] = []
        var parent: String?
        for i in 0..<count {
            let id = "e\(i)"
            let message: Message = i.isMultiple(of: 2) ? user(chars: 40) : assistant(text: String(repeating: "y", count: 40), totalTokens: 0)
            entries.append(entry(.message(message), id: id, parent: parent))
            parent = id
        }
        return entries
    }

    @Test("findCutIndex cuts at a user boundary and bounds the retained tail by the budget")
    func cutAtBudget() {
        // 10 messages of ~10 tokens each (100 total); keepRecentTokens 30.
        let path = alternatingPath(count: 10)
        let messages = path.compactMap { entry -> Message? in
            if case .message(let m) = entry.payload { return m }
            return nil
        }
        let cut = findCutIndex(messages, keepRecentTokens: 30)
        // Something older is summarized, and the retained tail begins at a user
        // boundary and stays within the recent budget (pi keeps the boundary at or
        // after where the budget fills, so the tail is bounded above by it).
        #expect(cut > 0)
        if case .user = messages[cut] {} else { Issue.record("cut is not a user boundary") }
        let retained = messages[cut...].reduce(0) { $0 + estimateTokens($1) }
        #expect(retained > 0)
        #expect(retained <= 30)
    }

    @Test("findCutIndex with no user boundary summarizes nothing")
    func cutNoBoundary() {
        let messages: [Message] = [
            assistant(text: "a", totalTokens: 0),
            assistant(text: "b", totalTokens: 0),
        ]
        #expect(findCutIndex(messages, keepRecentTokens: 1) == 0)
    }

    @Test("prepareCompaction preserves the most recent turns and summarizes the older ones")
    func prepareSelects() throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        // Older messages are summarized, recent ones retained, and together they
        // account for every projected message.
        #expect(!prep.messagesToSummarize.isEmpty)
        #expect(!prep.retainedTail.isEmpty)
        #expect(prep.messagesToSummarize.count + prep.retainedTail.count == 12)
        // The retained tail is bounded by roughly the recent budget, well under the
        // full context.
        let retainedTokens = prep.retainedTail.reduce(0) { $0 + estimateTokens($1) }
        #expect(retainedTokens < prep.tokensBefore)
        // firstKeptEntryId points at a real entry in the path.
        let ids = Set(path.map(\.id))
        #expect(prep.firstKeptEntryId.map { ids.contains($0) } ?? false)
    }

    @Test("prepareCompaction returns nil for an empty path")
    func prepareEmpty() {
        #expect(prepareCompaction(pathEntries: [], settings: .default) == nil)
    }

    @Test("prepareCompaction returns nil when the path is already tipped by a compaction")
    func prepareAlreadyCompacted() {
        let compaction = Compaction(summary: "s", tokensBefore: 100, retainedTail: [])
        let path = [entry(.compaction(compaction), id: "c", parent: nil)]
        #expect(prepareCompaction(pathEntries: path, settings: .default) == nil)
    }

    @Test("prepareCompaction returns nil when nothing is old enough to summarize")
    func prepareNothingOld() {
        // A tiny path well under the keep-recent budget: everything is retained.
        let path = alternatingPath(count: 2)
        #expect(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 100_000)) == nil)
    }

    @Test("prepareCompaction folds a prior checkpoint's summary and retained tail into the next run")
    func prepareWithPriorCompaction() throws {
        // A prior compaction carrying a retained tail, then fresh turns.
        let priorTail = [user(chars: 40), assistant(text: String(repeating: "z", count: 40), totalTokens: 0)]
        let prior = Compaction(summary: "PRIOR SUMMARY", tokensBefore: 5000, retainedTail: priorTail)
        var path = [entry(.compaction(prior), id: "c0", parent: nil)]
        var parent = "c0"
        for i in 0..<8 {
            let id = "e\(i)"
            let message: Message = i.isMultiple(of: 2) ? user(chars: 40) : assistant(text: String(repeating: "y", count: 40), totalTokens: 0)
            path.append(entry(.message(message), id: id, parent: parent))
            parent = id
        }
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        #expect(prep.previousSummary == "PRIOR SUMMARY")
        // The prior tail (2 msgs) plus 8 new message entries = 10 projected messages.
        #expect(prep.messagesToSummarize.count + prep.retainedTail.count == 10)
        // tokensBefore includes the standing summary's own weight.
        #expect(prep.tokensBefore > estimateContextTokens(priorTail).tokens)
    }

    // MARK: - Entry construction and async compaction

    @Test("makeCompactionEntry appends the file digest and round-trips through the wire format")
    func entryRoundTrips() throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        var enriched = prep
        enriched.readFiles = ["/read.swift"]
        enriched.modifiedFiles = ["/mod.swift"]
        let built = makeCompactionEntry(
            from: enriched,
            id: "comp",
            parentId: path.last?.id,
            timestamp: "2026-07-23T12:00:00.000Z",
            summary: "SUMMARY BODY"
        )
        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        #expect(compaction.summary.hasPrefix("SUMMARY BODY"))
        #expect(compaction.summary.contains("<read-files>\n/read.swift\n</read-files>"))
        #expect(compaction.summary.contains("<modified-files>\n/mod.swift\n</modified-files>"))
        #expect(compaction.retainedTail == enriched.retainedTail)

        let data = try JSONEncoder().encode(built)
        let decoded = try JSONDecoder().decode(SessionTreeEntry.self, from: data)
        #expect(decoded == built)
    }

    @Test("a placed compaction bounds the rebuilt context to the summary plus retained tail")
    func placedCompactionBounds() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        let built = try await compact(
            prep,
            id: "comp",
            parentId: path.last?.id,
            timestamp: "2026-07-23T12:00:00.000Z"
        ) { _ in "SHORT SUMMARY" }

        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        // The context rebuilt from the checkpoint alone is the summary message plus
        // the retained tail — and that is smaller than the pre-compaction size.
        let summaryMessage = Message.user(UserMessage(content: [.text(compaction.summary)]))
        let rebuilt = [summaryMessage] + (compaction.retainedTail ?? [])
        let rebuiltTokens = estimateContextTokens(rebuilt).tokens
        #expect(rebuiltTokens < prep.tokensBefore)
    }

    @Test("compact feeds a prior checkpoint's summary to the summarizer so it is not lost")
    func priorSummaryReachesSummarizer() async throws {
        // A path that already crosses a compaction: the prior summary must reach
        // the summarizer, or the early history it stands for is dropped for good
        // the second time the path compacts.
        let marker = "PRIOR_SUMMARY_MARKER"
        let priorTail = [user(chars: 40), assistant(text: String(repeating: "z", count: 40), totalTokens: 0)]
        let prior = Compaction(summary: marker, tokensBefore: 5000, retainedTail: priorTail)
        var path = [entry(.compaction(prior), id: "c0", parent: nil)]
        var parent = "c0"
        for i in 0..<8 {
            let id = "e\(i)"
            let message: Message = i.isMultiple(of: 2) ? user(chars: 40) : assistant(text: String(repeating: "y", count: 40), totalTokens: 0)
            path.append(entry(.message(message), id: id, parent: parent))
            parent = id
        }
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        #expect(prep.previousSummary == marker)

        actor Capture {
            var seen = false
            func mark(_ hit: Bool) { seen = seen || hit }
        }
        let cap = Capture()
        _ = try await compact(prep, id: "c1", parentId: "e7", timestamp: "t") { messages in
            var hit = false
            for message in messages {
                if case .user(let u) = message {
                    for block in u.content where block.textBlock?.text.contains(marker) == true { hit = true }
                }
            }
            await cap.mark(hit)
            return "NEW SUMMARY"
        }
        #expect(await cap.seen, "prior summary must be handed to the summarizer")
    }

    @Test("compact does not inject a prior-summary message when there is no prior checkpoint")
    func noPriorSummaryNoInjection() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        #expect(prep.previousSummary == nil)
        actor Box { var count = 0; func set(_ c: Int) { count = c } }
        let box = Box()
        _ = try await compact(prep, id: "c", parentId: nil, timestamp: "t") { messages in
            await box.set(messages.count)
            return "S"
        }
        #expect(await box.count == prep.messagesToSummarize.count)
    }

    @Test("compact surfaces a thrown summarizer error unchanged")
    func summarizerThrows() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom.self) {
            _ = try await compact(prep, id: "c", parentId: nil, timestamp: "t") { _ in throw Boom() }
        }
    }
}
