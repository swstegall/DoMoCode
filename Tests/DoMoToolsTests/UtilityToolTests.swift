import DoMoCore
import DoMoTools
import Testing

@Suite("utility tools")
struct UtilityToolTests {
    @Test("todowrite replaces session state and returns checklist details")
    func todoWrite() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let store = TodoStore()
        let tool = TodoWriteTool(store: store)

        let result = try await tool.execute(
            [
                "todos": [
                    ["content": "first", "status": "pending", "priority": "medium"],
                    ["content": "second", "status": "completed", "priority": "low"],
                ]
            ],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.text.contains("[ ] first"))
        #expect(result.text.contains("[x] second (low)"))
        #expect(result.details["todos"]?.arrayValue?.count == 2)
        #expect((await store.snapshot()).map(\.status) == [.pending, .completed])
    }

    @Test("todowrite rejects malformed entries as a tool error")
    func malformedTodo() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await TodoWriteTool().execute(
            ["todos": [["content": "missing status"]]],
            in: fixture.context
        )

        #expect(result.isError)
        #expect(result.text.contains("status"))
    }

    @Test("glob uses the sandboxed find implementation")
    func glob() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("Sources/One.swift", "one")
        try fixture.write("Sources/Two.txt", "two")

        let result = try await GlobTool().execute(
            ["pattern": "**/*.swift"],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.text.contains("Sources/One.swift"))
        #expect(!result.text.contains("Sources/Two.txt"))
    }

    @Test("finish requests termination and keeps its message")
    func finish() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await FinishTool().execute(
            ["message": "Everything is done."],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.terminate)
        #expect(result.text == "Everything is done.")
    }
}
