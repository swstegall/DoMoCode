import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("registry")
struct RegistryTests {

    @Test("the builtin set has all seven tools in a stable order")
    func builtinSet() {
        let registry = ToolRegistry.builtin
        #expect(registry.names == ["read", "bash", "edit", "write", "grep", "find", "ls"])
    }

    @Test("the coding set is read/bash/edit/write")
    func codingSet() {
        #expect(ToolRegistry.coding.names == ["read", "bash", "edit", "write"])
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

    @Test("registering the same name twice replaces in place")
    func replaceInPlace() {
        var registry = ToolRegistry([ReadTool()])
        registry.register(ReadTool())
        #expect(registry.names == ["read"])
    }
}
