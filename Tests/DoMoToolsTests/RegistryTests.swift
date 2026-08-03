import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("registry")
struct RegistryTests {

    @Test("the builtin set has a stable order")
    func builtinSet() {
        let registry = ToolRegistry.builtin
        #expect(registry.names == [
            "read", "bash", "edit", "write", "grep", "find", "ls",
            "todowrite", "glob", "finish", "question", "webfetch", "background_process",
        ])
    }

    @Test("the coding set is read/bash/edit/write")
    func codingSet() {
        #expect(ToolRegistry.coding.names == ["read", "bash", "edit", "write"])
    }

    @Test("plan mode adds a terminating plan_exit tool")
    func planExitSet() async throws {
        let registry = ToolRegistry.builtin(includePlanExit: true)
        #expect(registry.names.last == "plan_exit")
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let result = try await registry.execute(
            "plan_exit",
            arguments: ["message": "ready"],
            in: fixture.context
        )
        #expect(result.terminate)
        #expect(result.text == "ready")
    }

    @Test("plan mode exposes task after plan_exit")
    func subagentSet() {
        let registry = ToolRegistry.builtin(includePlanExit: true, includeSubagent: true)
        #expect(registry.names.suffix(2) == ["plan_exit", "task"])
    }

    @Test("task forwards a focused request to its coordinator")
    func taskDispatch() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let coordinator = SubagentCoordinator()
        coordinator.setRunner { request in
            SubagentTaskResult(
                taskID: request.taskID,
                childSessionID: "child-session",
                status: .completed,
                output: "inspected: \(request.prompt)"
            )
        }
        let context = fixture.context.withQuestionHandler(
            nil,
            backgroundProcesses: fixture.context.backgroundProcesses,
            subagentCoordinator: coordinator,
            sessionID: "parent-session"
        )

        let result = try await TaskTool().execute(
            ["prompt": "inspect the parser", "agent": "explore"],
            in: context
        )

        #expect(!result.isError)
        #expect(result.text == "inspected: inspect the parser")
        #expect(result.details["child_session_id"]?.stringValue == "child-session")
    }

    @Test("dispatches by name")
    func dispatch() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "content")

        let result = try await ToolRegistry.builtin.execute(
            "read", arguments: ["path": "a.txt"], in: fixture.context)
        #expect(result.text == "content")
    }

    @Test("an unknown tool is an error result, not a throw")
    func unknownTool() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await ToolRegistry.builtin.execute(
            "nonexistent", arguments: [:], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Unknown tool: nonexistent"))
    }

    @Test("every tool exposes a name, description and object schema")
    func metadata() {
        for tool in ToolRegistry.builtin.all {
            #expect(!tool.name.isEmpty)
            #expect(!tool.description.isEmpty)
            #expect(tool.parameters.type == .single(.object))
        }
    }

    @Test("a supplied todo store is retained by the session registry")
    func sessionStateFactory() async throws {
        let store = TodoStore()
        let registry = ToolRegistry.builtin(todoStore: store)
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await registry.execute(
            "todowrite",
            arguments: [
                "todos": [[
                    "content": "inspect the registry",
                    "status": "in_progress",
                    "priority": "high",
                ]]
            ],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect((await store.snapshot()).first?.content == "inspect the registry")
    }

    @Test("registering the same name twice replaces in place")
    func replaceInPlace() {
        var registry = ToolRegistry([ReadTool()])
        registry.register(ReadTool())
        #expect(registry.names == ["read"])
    }
}
