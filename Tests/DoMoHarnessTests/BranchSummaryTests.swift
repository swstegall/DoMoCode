import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite("BranchSummary")
struct BranchSummaryTests {
    private func user(chars count: Int) -> Message {
        .user(UserMessage(content: [.text(String(repeating: "x", count: count))]))
    }

    private func assistant(chars count: Int) -> Message {
        .assistant(AssistantMessage(content: [.text(String(repeating: "y", count: count))], model: "m"))
    }

    private func entry(_ payload: SessionTreeEntry.Payload, id: String, parent: String?) -> SessionTreeEntry {
        SessionTreeEntry(id: id, parentId: parent, timestamp: "2026-07-23T12:00:00.000Z", payload: payload)
    }

    private func messagePath(_ messages: [Message]) -> [SessionTreeEntry] {
        var entries: [SessionTreeEntry] = []
        var parent: String?
        for (i, message) in messages.enumerated() {
            let id = "e\(i)"
            entries.append(entry(.message(message), id: id, parent: parent))
            parent = id
        }
        return entries
    }

    // MARK: - Selection

    @Test("prepareBranchEntries collects all messages, oldest first, with no budget")
    func collectsAll() {
        let messages = [user(chars: 40), assistant(chars: 40), user(chars: 40)]
        let prep = prepareBranchEntries(messagePath(messages))
        #expect(prep.messages == messages)
        #expect(prep.totalTokens == messages.reduce(0) { $0 + estimateTokens($1) })
    }

    @Test("prepareBranchEntries drops bare tool-result messages")
    func dropsToolResults() {
        let path = [
            entry(.message(user(chars: 40)), id: "a", parent: nil),
            entry(.message(.tool(ToolResultBlock(toolCallID: "1", toolName: "read", output: "data"))), id: "b", parent: "a"),
        ]
        let prep = prepareBranchEntries(path)
        #expect(prep.messages.count == 1)
        if case .user = prep.messages[0] {} else { Issue.record("tool result was not dropped") }
    }

    @Test("prepareBranchEntries stops at the token budget, keeping newest messages")
    func respectsBudget() {
        // Six ~10-token messages; budget 25 keeps the two newest whole.
        let messages = (0..<6).map { _ in user(chars: 40) }
        let prep = prepareBranchEntries(messagePath(messages), tokenBudget: 25)
        #expect(prep.totalTokens <= 25)
        #expect(prep.messages.count == 2)
        // The kept messages are the newest, still oldest-first in the result.
        #expect(prep.messages == Array(messages.suffix(2)))
    }

    @Test("prepareBranchEntries digests file operations across the whole branch")
    func digestsFiles() {
        let call = ToolCallBlock(id: "1", name: "edit", arguments: .object(["path": .string("/branch.swift")]))
        let path = [
            entry(.message(.assistant(AssistantMessage(content: [.toolCall(call)], model: "m"))), id: "a", parent: nil),
            entry(.message(user(chars: 20)), id: "b", parent: "a"),
        ]
        let prep = prepareBranchEntries(path)
        #expect(prep.modifiedFiles == ["/branch.swift"])
    }

    @Test("prepareBranchEntries on an empty branch yields no messages")
    func emptyBranch() {
        let prep = prepareBranchEntries([])
        #expect(prep.messages.isEmpty)
        #expect(prep.totalTokens == 0)
    }

    // MARK: - Entry construction and async summarization

    @Test("makeBranchSummaryEntry brackets the summary with preamble and digest and round-trips")
    func entryRoundTrips() throws {
        var prep = prepareBranchEntries(messagePath([user(chars: 40)]))
        prep.modifiedFiles = ["/m.swift"]
        let built = makeBranchSummaryEntry(
            from: prep,
            fromId: "leaf-7",
            id: "bs",
            parentId: "leaf-7",
            timestamp: "2026-07-23T12:00:00.000Z",
            summary: "BRANCH BODY"
        )
        guard case .branchSummary(let branch) = built.payload else {
            Issue.record("expected a branch-summary payload")
            return
        }
        #expect(branch.fromId == "leaf-7")
        #expect(branch.summary.contains("explored a different conversation branch"))
        #expect(branch.summary.contains("BRANCH BODY"))
        #expect(branch.summary.contains("<modified-files>\n/m.swift\n</modified-files>"))

        let data = try JSONEncoder().encode(built)
        let decoded = try JSONDecoder().decode(SessionTreeEntry.self, from: data)
        #expect(decoded == built)
    }

    @Test("summarizeBranch runs the injected summarizer over the selected messages")
    func summarizeRuns() async throws {
        let prep = prepareBranchEntries(messagePath([user(chars: 40), assistant(chars: 40)]))
        let built = try await summarizeBranch(
            prep,
            fromId: "leaf",
            id: "bs",
            parentId: "leaf",
            timestamp: "t"
        ) { messages in
            "summarized \(messages.count) messages"
        }
        guard case .branchSummary(let branch) = built.payload else {
            Issue.record("expected a branch-summary payload")
            return
        }
        #expect(branch.summary.contains("summarized 2 messages"))
    }

    @Test("summarizeBranch on an empty branch writes a fixed note without calling the summarizer")
    func emptyBranchSkipsSummarizer() async throws {
        let prep = prepareBranchEntries([])
        let built = try await summarizeBranch(
            prep,
            fromId: "leaf",
            id: "bs",
            parentId: "leaf",
            timestamp: "t"
        ) { _ in
            Issue.record("summarizer must not run for an empty branch")
            return "unexpected"
        }
        guard case .branchSummary(let branch) = built.payload else {
            Issue.record("expected a branch-summary payload")
            return
        }
        #expect(branch.summary == "No content to summarize")
    }

    @Test("summarizeBranch surfaces a thrown summarizer error unchanged")
    func summarizerThrows() async throws {
        let prep = prepareBranchEntries(messagePath([user(chars: 40)]))
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await summarizeBranch(prep, fromId: "l", id: "bs", parentId: nil, timestamp: "t") { _ in throw Boom() }
        }
    }
}
