import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoMemory
import Foundation
import SystemPackage
import Testing

@Suite("session recall")
struct SessionRecallTests {

    @Test("ranks user text, finds files and tool errors, and excludes reasoning and success")
    func indexesAllowedHistory() throws {
        let fixture = try RecallFixture.make()
        defer { fixture.remove() }

        var parent: String?
        parent = try fixture.append(
            .message(.user("We decided to use SQLite for durable memory.")),
            parent: parent
        )
        parent = try fixture.append(
            .message(
                .assistant(
                    AssistantMessage(
                    content: [
                        .reasoning(ReasoningBlock(text: "reasoning-only-secret")),
                        .text("We decided to use SQLite for durable memory."),
                        .toolCall(
                            ToolCallBlock(
                                id: "call-1",
                                name: "write",
                                arguments: ["path": "Sources/Memory.swift"]
                            )
                        ),
                    ],
                    model: "test"
                    )
                )
            ),
            parent: parent
        )
        parent = try fixture.append(
            .message(
                .tool(
                    ToolResultBlock(
                        toolCallID: "call-success",
                        toolName: "bash",
                        output: "successful-output-only",
                        isError: false
                    )
                )
            ),
            parent: parent
        )
        _ = try fixture.append(
            .message(
                .tool(
                    ToolResultBlock(
                        toolCallID: "call-error",
                        toolName: "bash",
                        output: "tool-error-only: compiler could not find Memory.swift",
                        isError: true
                    )
                )
            ),
            parent: parent
        )

        let index = SessionRecallIndex(cwd: fixture.cwd, sessionDirectory: fixture.sessions)
        let decisions = try index.search(query: "SQLite durable memory", limit: 5)
        #expect(!decisions.isEmpty)
        #expect(decisions.first?.category == .user)
        #expect(decisions.contains { $0.category == .assistant })

        let fileHits = try index.search(query: "Memory.swift", limit: 5)
        #expect(fileHits.contains { $0.category == .file && $0.snippet.contains("Sources/Memory.swift") })

        let errorHits = try index.search(query: "compiler could not find", limit: 5)
        #expect(errorHits.contains { $0.category == .toolError })

        let reasoningHits = try index.search(query: "reasoning-secret", limit: 5)
        let successHits = try index.search(query: "successful-output", limit: 5)
        #expect(reasoningHits.isEmpty)
        #expect(successHits.isEmpty)
    }

    @Test("elides the middle while preserving the end of a long excerpt")
    func middleElision() {
        let value = "prefix-" + String(repeating: "middle-", count: 50) + "-suffix"
        let shortened = SessionRecallIndex.elideMiddle(value, limit: 40)
        #expect(shortened.count <= 40)
        #expect(shortened.hasPrefix("prefix-"))
        #expect(shortened.hasSuffix("-suffix"))
        #expect(shortened.contains("middle omitted"))
    }

    @Test("rejects a blank query")
    func emptyQuery() throws {
        let fixture = try RecallFixture.make()
        defer { fixture.remove() }
        let index = SessionRecallIndex(cwd: fixture.cwd, sessionDirectory: fixture.sessions)
        #expect(throws: SessionRecallError.emptyQuery) {
            _ = try index.search(query: "   ", limit: 5)
        }
    }
}

private struct RecallFixture {
    let root: URL
    let sessions: FilePath
    let cwd: String
    let store: JSONLSessionStore

    static func make() throws -> RecallFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = FilePath(root.appendingPathComponent("sessions").path)
        let cwd = root.appendingPathComponent("workspace").path
        let store = try JSONLSessionStore.create(
            cwd: cwd,
            sessionDirectory: sessions,
            sessionID: "session-recall-test",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return RecallFixture(root: root, sessions: sessions, cwd: cwd, store: store)
    }

    func append(_ payload: SessionTreeEntry.Payload, parent: String?) throws -> String {
        let id = store.createEntryID()
        try store.appendEntry(
            SessionTreeEntry(
                id: id,
                parentId: parent,
                timestamp: "2026-08-03T12:00:00Z",
                payload: payload
            )
        )
        return id
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
