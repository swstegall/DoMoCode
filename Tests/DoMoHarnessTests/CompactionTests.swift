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

    /// The entries-shaped `getLastAssistantUsage` that used to live here had no
    /// caller in any target and was deleted in Phase 5a rather than left dead for a
    /// second phase. `estimateContextTokens` performs the same anchoring over
    /// messages, and that is what the harness has always actually used.
    @Test("estimateContextTokens anchors on the most recent valid assistant usage, skipping failures")
    func anchorSkipsFailedTurns() {
        let messages = [
            assistant(totalTokens: 100),
            user(chars: 10),
            assistant(totalTokens: 300),
            assistant(totalTokens: 999, stopReason: .error),
        ]
        let estimate = estimateContextTokens(messages)
        #expect(estimate.usageTokens == 300)
        #expect(estimate.lastUsageIndex == 2)
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

    @Test("serializeConversation is deterministic and caps tool output")
    func serializeConversationIsStable() {
        let call = ToolCallBlock(
            id: "call",
            name: "read",
            arguments: .object(["z": .string("last"), "a": .int(1)])
        )
        let output = String(repeating: "x", count: 2_500)
        let messages: [Message] = [
            .user("inspect this"),
            .assistant(AssistantMessage(content: [.toolCall(call)], model: "m")),
            .tool(ToolResultBlock(toolCallID: "call", toolName: "read", output: output))
        ]

        let first = serializeConversation(messages)
        let second = serializeConversation(messages)
        #expect(first == second)
        #expect(first.contains("[User]: inspect this"))
        #expect(first.contains("[Assistant tool calls]: read({\"a\":1,\"z\":\"last\"})"))
        #expect(first.contains("[... 500 more characters truncated]"))
        #expect(first.count < output.count)
    }

    @Test("a later compaction carries the earlier file manifest forward")
    func fileManifestIsCumulative() throws {
        let prior = Compaction(
            summary: "old",
            tokensBefore: 100,
            retainedTail: [user(chars: 40)],
            readFiles: ["/old.swift"],
            modifiedFiles: ["/changed.swift"]
        )
        var path = [entry(.compaction(prior), id: "c0", parent: nil)]
        var parent = "c0"
        for index in 0..<8 {
            let message: Message
            if index == 6 {
                let call = ToolCallBlock(id: "read-new", name: "read", arguments: .object(["path": .string("/new.swift")]))
                message = .assistant(AssistantMessage(content: [.toolCall(call)], model: "m"))
            } else if index == 7 {
                message = user(chars: 40)
            } else {
                message = index.isMultiple(of: 2) ? user(chars: 40) : assistant(text: String(repeating: "y", count: 40), totalTokens: 0)
            }
            let id = "e\(index)"
            path.append(entry(.message(message), id: id, parent: parent))
            parent = id
        }

        let preparation = try #require(
            prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 1))
        )
        #expect(preparation.readFiles == ["/new.swift", "/old.swift"])
        #expect(preparation.modifiedFiles == ["/changed.swift"])

        let built = makeCompactionEntry(
            from: preparation,
            id: "c1",
            parentId: parent,
            timestamp: "t",
            summary: "new"
        )
        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        #expect(compaction.readFiles == ["/new.swift", "/old.swift"])
        #expect(compaction.modifiedFiles == ["/changed.swift"])
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
        ) { _ in SummarizerResult(text: "SHORT SUMMARY") }

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
            return SummarizerResult(text: "NEW SUMMARY")
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
            return SummarizerResult(text: "S")
        }
        #expect(await box.count == 1, "the summarizer receives one deterministic serialized message")
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

    // MARK: - Summarization usage

    /// The whole reason ``Summarizer`` returns a value instead of a `String`: this
    /// is the only path by which ``Compaction/usage`` — documented as "folded into
    /// session totals" — can ever be non-nil.
    @Test("compact carries the summarizer's reported usage onto the entry")
    func summarizerUsageReachesTheEntry() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        let built = try await compact(prep, id: "c", parentId: nil, timestamp: "t") { _ in
            SummarizerResult(text: "S", usage: Usage(input: 40, output: 7))
        }
        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        #expect(compaction.usage?.input == 40)
        #expect(compaction.usage?.output == 7)
    }

    @Test("an explicit usage argument wins over the summarizer's own report")
    func explicitUsageOverridesTheSummarizer() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        let built = try await compact(
            prep,
            id: "c",
            parentId: nil,
            timestamp: "t",
            usage: Usage(input: 999)
        ) { _ in SummarizerResult(text: "S", usage: Usage(input: 40)) }
        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        #expect(compaction.usage?.input == 999)
    }

    @Test("a summarizer that reports nothing leaves usage nil rather than zero")
    func unmeasuredSummarizerLeavesUsageNil() async throws {
        let path = alternatingPath(count: 12)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: CompactionSettings(keepRecentTokens: 30)))
        let built = try await compact(prep, id: "c", parentId: nil, timestamp: "t") { _ in
            SummarizerResult(text: "S")
        }
        guard case .compaction(let compaction) = built.payload else {
            Issue.record("expected a compaction payload")
            return
        }
        #expect(compaction.usage == nil, "\"not measured\" was recorded as a measurement of zero")
    }

    // MARK: - Prompts

    /// Moved verbatim out of `AgentHarness` so a CLI-built small-model summarizer
    /// and the harness fallback ask the same question. A prompt that drifted between
    /// them would summarize the same conversation two different ways depending on
    /// which component happened to make the call.
    @Test("the prior-summary preamble names the standing summary and carries it whole")
    func priorSummaryPreambleWrapsThePrevious() {
        let wrapped = CompactionPrompts.priorSummaryPreamble("EARLIER STORY")
        #expect(wrapped.hasSuffix("EARLIER STORY"))
        #expect(wrapped.contains("running summary of the conversation before this point"))
        #expect(wrapped.contains("Fold it into the new summary so nothing it records is lost:"))
        // The preamble ends its own sentence on its own line, so the previous
        // summary never runs into it.
        #expect(wrapped.hasPrefix("The following"))
        #expect(wrapped.contains("lost:\nEARLIER STORY"))
    }

    @Test("the summarization prompts are non-empty and distinct")
    func promptsAreDistinct() {
        #expect(CompactionPrompts.system.contains("summarizing a conversation"))
        #expect(CompactionPrompts.instruction.contains("Summarize the conversation so far"))
        #expect(CompactionPrompts.system != CompactionPrompts.instruction)
    }

    // MARK: - Settings decoding

    /// The synthesized decoder required all three keys, so the most natural thing a
    /// user could write was a hard parse failure of the whole settings file.
    @Test("a partial settings object decodes, filling the rest from the defaults")
    func partialSettingsDecode() throws {
        let decoder = JSONDecoder()
        let onlyEnabled = try decoder.decode(CompactionSettings.self, from: Data(#"{"enabled": false}"#.utf8))
        #expect(onlyEnabled.enabled == false)
        #expect(onlyEnabled.reserveTokens == CompactionSettings.default.reserveTokens)
        #expect(onlyEnabled.keepRecentTokens == CompactionSettings.default.keepRecentTokens)

        let empty = try decoder.decode(CompactionSettings.self, from: Data("{}".utf8))
        #expect(empty == CompactionSettings.default)

        let onlyReserve = try decoder.decode(CompactionSettings.self, from: Data(#"{"reserveTokens": 42}"#.utf8))
        #expect(onlyReserve.reserveTokens == 42)
        #expect(onlyReserve.enabled)
    }

    @Test("settings round-trip through the wire format")
    func settingsRoundTrip() throws {
        let original = CompactionSettings(enabled: false, reserveTokens: 11, keepRecentTokens: 22)
        let decoded = try JSONDecoder().decode(
            CompactionSettings.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("a negative budget is rejected by the decoder rather than silently corrected")
    func negativeBudgetsRejected() {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(CompactionSettings.self, from: Data(#"{"reserveTokens": -1}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(CompactionSettings.self, from: Data(#"{"keepRecentTokens": -1}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(CompactionOverrides.self, from: Data(#"{"reserveTokens": -5}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(CompactionOverrides.self, from: Data(#"{"keepRecentTokens": -5}"#.utf8))
        }
    }

    /// The memberwise initializer cannot throw, and a negative reserve is not merely
    /// odd — it pushes the trigger threshold above the window, so compaction never
    /// fires at all.
    @Test("the memberwise initializer clamps a negative budget to zero")
    func memberwiseClampsNegatives() {
        let settings = CompactionSettings(reserveTokens: -100, keepRecentTokens: -1)
        #expect(settings.reserveTokens == 0)
        #expect(settings.keepRecentTokens == 0)
    }

    // MARK: - Overrides

    @Test("overrides replace only the fields they state")
    func overridesApplySelectively() {
        let base = CompactionSettings(enabled: true, reserveTokens: 100, keepRecentTokens: 200)
        #expect(CompactionOverrides(enabled: false).applied(to: base)
            == CompactionSettings(enabled: false, reserveTokens: 100, keepRecentTokens: 200))
        #expect(CompactionOverrides(reserveTokens: 7).applied(to: base)
            == CompactionSettings(enabled: true, reserveTokens: 7, keepRecentTokens: 200))
        #expect(CompactionOverrides().applied(to: base) == base)
        // `model` has no home on the settings value and must not disturb it.
        #expect(CompactionOverrides(model: "cheap").applied(to: base) == base)
    }

    @Test("merging overrides is field by field, with the stronger layer winning per field")
    func overridesMergeFieldByField() {
        let user = CompactionOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 200, model: "user-model")
        let project = CompactionOverrides(keepRecentTokens: 999)
        let merged = project.merged(over: user)
        #expect(merged.keepRecentTokens == 999, "the stronger layer's own field did not win")
        #expect(merged.enabled == true, "a field the stronger layer is silent about was discarded")
        #expect(merged.reserveTokens == 100)
        #expect(merged.model == "user-model", "a whole-entry replacement swallowed the weaker layer's model")
    }

    @Test("an override decodes from a partial object and round-trips")
    func overridesDecode() throws {
        let decoded = try JSONDecoder().decode(
            CompactionOverrides.self,
            from: Data(#"{"keepRecentTokens": 5, "model": "small"}"#.utf8)
        )
        #expect(decoded.keepRecentTokens == 5)
        #expect(decoded.model == "small")
        #expect(decoded.enabled == nil, "an absent key decoded as a stated one")
        #expect(decoded.reserveTokens == nil)

        let round = try JSONDecoder().decode(
            CompactionOverrides.self,
            from: try JSONEncoder().encode(decoded)
        )
        #expect(round == decoded)
    }

    // MARK: - Clamping the budgets to the window

    /// The shipped defaults already exceed a 32K window, which is what made
    /// `shouldCompact` fire and `prepareCompaction` then find nothing to summarize —
    /// a run proceeding over-full, silently.
    @Test("budgets that claim more than half the window are scaled down, keeping their ratio")
    func clampScalesOversizedBudgets() {
        let clamped = CompactionSettings.default.clamped(toContextWindow: 32_000)
        #expect(clamped.reserveTokens + clamped.keepRecentTokens <= 16_000)
        #expect(clamped.reserveTokens > 0)
        #expect(clamped.keepRecentTokens > 0)
        // The ratio survives: the reserve was the smaller of the two and stays so.
        #expect(clamped.reserveTokens < clamped.keepRecentTokens)
        #expect(clamped.enabled == CompactionSettings.default.enabled)
    }

    @Test("budgets that already fit are returned untouched, and clamping twice changes nothing")
    func clampIsIdentityWhenItFitsAndIsIdempotent() {
        #expect(CompactionSettings.default.clamped(toContextWindow: 200_000) == CompactionSettings.default)
        let once = CompactionSettings.default.clamped(toContextWindow: 32_000)
        #expect(once.clamped(toContextWindow: 32_000) == once)
        // A non-positive window carries no information to clamp against.
        #expect(CompactionSettings.default.clamped(toContextWindow: 0) == CompactionSettings.default)
        #expect(CompactionSettings.default.clamped(toContextWindow: -1) == CompactionSettings.default)
    }

    @Test("clamping survives budgets whose sum does not fit in an Int")
    func clampSurvivesOverflow() {
        let absurd = CompactionSettings(reserveTokens: .max, keepRecentTokens: .max)
        let clamped = absurd.clamped(toContextWindow: 1000)
        #expect(clamped.reserveTokens + clamped.keepRecentTokens == 500)
    }

    /// The point of clamping, stated as behaviour rather than as arithmetic: with
    /// the raw budgets the recent window covers the entire history, so nothing is
    /// old enough to summarize and `prepareCompaction` returns `nil` — compaction
    /// fires, writes nothing, and says nothing.
    @Test("clamping is what lets a small window's compaction select anything at all")
    func clampingMakesPreparationPossible() throws {
        let path = alternatingPath(count: 40)
        let window = 400
        let raw = CompactionSettings(reserveTokens: 200, keepRecentTokens: 500)
        #expect(prepareCompaction(pathEntries: path, settings: raw) == nil,
                "the premise changed: the raw budgets no longer swallow this history")

        let clamped = raw.clamped(toContextWindow: window)
        #expect(clamped.reserveTokens + clamped.keepRecentTokens <= window / 2)
        let prep = try #require(prepareCompaction(pathEntries: path, settings: clamped))
        #expect(!prep.messagesToSummarize.isEmpty)
        #expect(!prep.retainedTail.isEmpty)
    }
}
