import DoMoCore
import DoMoTools
import Foundation
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

    @Test("webfetch validates the scheme and preserves response details")
    func webFetch() async throws {
        let fixture = try await ToolFixture.make(
            webFetch: { url in
                #expect(url.absoluteString == "https://example.test/docs")
                return WebFetchResponse(
                    statusCode: 200,
                    contentType: "text/plain",
                    data: Data("hello from the web".utf8)
                )
            }
        )
        defer { fixture.removeCleanup() }

        let result = try await WebFetchTool().execute(
            ["url": "https://example.test/docs"],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.text == "hello from the web")
        #expect(result.details["statusCode"]?.intValue == 200)
        #expect(result.details["contentType"]?.stringValue == "text/plain")
    }

    @Test("webfetch refuses non-web URLs")
    func webFetchInvalidURL() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await WebFetchTool().execute(
            ["url": "file:///etc/passwd"],
            in: fixture.context
        )

        #expect(result.isError)
        #expect(result.text.contains("only http and https"))
    }

    @Test("question returns structured selections through its handler")
    func question() async throws {
        let fixture = try await ToolFixture.make(
            questionHandler: { questions in
                #expect(questions.count == 1)
                #expect(questions[0].options.map(\.label) == ["Use SQLite", "Use JSON"])
                return [QuestionAnswer(selectedLabels: ["Use SQLite"])]
            }
        )
        defer { fixture.removeCleanup() }

        let result = try await QuestionTool().execute(
            [
                "questions": [[
                    "header": "Storage",
                    "question": "Which storage should we use?",
                    "options": [
                        ["label": "Use SQLite", "description": "Queryable"],
                        ["label": "Use JSON"],
                    ],
                ]]
            ],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.text.contains("Which storage should we use?: Use SQLite"))
        #expect(result.details["answers"]?.arrayValue?.count == 1)
    }

    @Test("question fails closed without an interactive handler")
    func questionHeadless() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await QuestionTool().execute(
            [
                "questions": [[
                    "question": "Continue?",
                    "options": [["label": "Yes"]],
                ]]
            ],
            in: fixture.context
        )

        #expect(result.isError)
        #expect(result.text.contains("headless"))
    }

    @Test("background_process keeps a session child addressable across calls")
    func backgroundProcess() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let started = try await BackgroundProcessTool().execute(
            ["action": "start", "command": "printf 'started\\n'; sleep 30"],
            in: fixture.context
        )
        #expect(!started.isError)
        let id = started.details["id"]?.stringValue
        #expect(id != nil)

        var polled = ToolResult.error("not polled")
        for _ in 0..<50 {
            polled = try await BackgroundProcessTool().execute(
                ["action": "poll", "id": .string(id ?? "")],
                in: fixture.context
            )
            if polled.text.contains("started") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(polled.text.contains("started"))

        let killed = try await BackgroundProcessTool().execute(
            ["action": "kill", "id": .string(id ?? "")],
            in: fixture.context
        )
        #expect(!killed.isError)
        await fixture.context.backgroundProcesses.shutdown()
    }
}
