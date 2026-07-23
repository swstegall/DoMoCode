import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite("ContextBuilder")
struct ContextBuilderTests {
    private func ts(_ n: Int) -> String {
        let seconds = n < 10 ? "0\(n)" : "\(n)"
        return "2026-07-23T12:00:\(seconds).000Z"
    }

    private func userEntry(_ id: String, parent: String?, _ n: Int, _ text: String) -> SessionTreeEntry {
        SessionTreeEntry(id: id, parentId: parent, timestamp: ts(n), payload: .message(.user(text)))
    }

    private func assistantEntry(_ id: String, parent: String?, _ n: Int, _ text: String) -> SessionTreeEntry {
        let message = Message.assistant(AssistantMessage(content: [.text(text)], model: "m"))
        return SessionTreeEntry(id: id, parentId: parent, timestamp: ts(n), payload: .message(message))
    }

    private func userText(_ message: Message) -> String? {
        if case .user(let user) = message { return user.text }
        return nil
    }

    // MARK: - Ordering

    @Test("messages come out oldest-first, the reverse of the leaf-to-root walk")
    func chronologicalOrder() throws {
        let tree = SessionTree(entries: [
            userEntry("a", parent: nil, 1, "first"),
            assistantEntry("b", parent: "a", 2, "second"),
            userEntry("c", parent: "b", 3, "third"),
        ])
        let messages = try ContextBuilder.buildContext(tree)
        #expect(messages.count == 3)
        #expect(userText(messages[0]) == "first")
        #expect(userText(messages[2]) == "third")
    }

    // MARK: - Metadata

    @Test("metadata entries contribute no message")
    func metadataContributesNothing() throws {
        let tree = SessionTree(entries: [
            userEntry("a", parent: nil, 1, "hello"),
            SessionTreeEntry(id: "m", parentId: "a", timestamp: ts(2), payload: .modelChange(provider: "p", modelId: "x")),
            SessionTreeEntry(id: "l", parentId: "m", timestamp: ts(3), payload: .label(targetId: "a", label: "mark")),
            SessionTreeEntry(id: "s", parentId: "l", timestamp: ts(4), payload: .sessionInfo(name: "My session")),
            assistantEntry("b", parent: "s", 5, "hi"),
        ])
        let messages = try ContextBuilder.buildContext(tree)
        // Only the two real messages survive; model_change/label/session_info drop.
        #expect(messages.count == 2)
        #expect(userText(messages[0]) == "hello")
    }

    // MARK: - Compaction

    @Test("context stops at a compaction boundary and includes its summary")
    func compactionBoundaryWithRetainedTail() throws {
        let retained = [Message.user("kept request")]
        let compaction = Compaction(summary: "earlier work", tokensBefore: 1234, retainedTail: retained)
        let tree = SessionTree(entries: [
            userEntry("a", parent: nil, 1, "ancient"),
            assistantEntry("b", parent: "a", 2, "ancient reply"),
            SessionTreeEntry(id: "k", parentId: "b", timestamp: ts(3), payload: .compaction(compaction)),
            userEntry("c", parent: "k", 4, "after compaction"),
        ])
        let messages = try ContextBuilder.buildContext(tree)
        // "ancient"/"ancient reply" are replaced by the summary; the summary,
        // the retained tail, and the post-compaction message remain.
        #expect(messages.count == 3)
        let summaryText = userText(messages[0]) ?? ""
        #expect(summaryText.contains("earlier work"))
        #expect(summaryText.contains("<summary>"))
        #expect(userText(messages[1]) == "kept request")
        #expect(userText(messages[2]) == "after compaction")
    }

    @Test("a legacy firstKeptEntryId compaction reselects the kept span")
    func compactionLegacyFirstKept() throws {
        let compaction = Compaction(summary: "recap", tokensBefore: 10, firstKeptEntryId: "b")
        let tree = SessionTree(entries: [
            userEntry("a", parent: nil, 1, "dropped"),
            userEntry("b", parent: "a", 2, "kept"),
            SessionTreeEntry(id: "k", parentId: "b", timestamp: ts(3), payload: .compaction(compaction)),
            userEntry("c", parent: "k", 4, "newest"),
        ])
        let messages = try ContextBuilder.buildContext(tree)
        // summary + b (from firstKeptEntryId) + c; a is dropped.
        #expect(messages.count == 3)
        #expect(userText(messages[0])?.contains("recap") == true)
        #expect(userText(messages[1]) == "kept")
        #expect(userText(messages[2]) == "newest")
    }

    // MARK: - Branch summary

    @Test("a branch summary with text becomes a wrapped message; an empty one is dropped")
    func branchSummaryProjection() throws {
        let withText = SessionTreeEntry(
            id: "bs", parentId: "a", timestamp: ts(2),
            payload: .branchSummary(BranchSummary(fromId: "x", summary: "explored A"))
        )
        let tree = SessionTree(entries: [userEntry("a", parent: nil, 1, "root"), withText])
        let messages = try ContextBuilder.buildContext(tree)
        #expect(messages.count == 2)
        #expect(userText(messages[1])?.contains("explored A") == true)
        #expect(userText(messages[1])?.contains("came back from") == true)

        let empty = SessionTreeEntry(
            id: "bs2", parentId: "a", timestamp: ts(2),
            payload: .branchSummary(BranchSummary(fromId: "x", summary: ""))
        )
        let treeEmpty = SessionTree(entries: [userEntry("a", parent: nil, 1, "root"), empty])
        #expect(try ContextBuilder.buildContext(treeEmpty).count == 1)
    }

    // MARK: - Failure surfacing

    @Test("a dangling parentId on the active path throws instead of truncating context")
    func danglingThrows() {
        let tree = SessionTree(entries: [userEntry("child", parent: "ghost", 1, "orphan")])
        #expect(throws: DoMoError.self) { try ContextBuilder.buildContext(tree) }
    }
}
