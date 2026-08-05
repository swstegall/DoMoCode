// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM
import Testing

private struct DirectSchemaTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "read",
            description: "Read a file",
            parameters: JSONSchema.object(
                .required("path", .string()),
                .optional("enabled", .boolean()),
                .optional("offset", .integer())
            )
        )
    }

    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        AgentToolResult(output: "ok")
    }
}

@Test("Direct commands map positional paths and schema flags")
func parsesDirectToolArguments() throws {
    let parsed = try DirectToolCommandParser.parse(
        #"/read "foo bar.txt" --offset 3 --enabled"#,
        tools: [DirectSchemaTool()]
    )

    #expect(parsed.name == "read")
    #expect(
        parsed.arguments == .object([
            "path": .string("foo bar.txt"),
            "offset": .int(3),
            "enabled": .bool(true),
        ])
    )
}

@Test("Direct dispatch preserves the shared tool lifecycle")
func directDispatchEmitsLifecycleAndRunsTool() async {
    let seen = Box<JSONValue>(.null)
    let tool = FakeTool("read") { arguments in
        seen.withLock { $0 = arguments }
        return AgentToolResult(output: "read ok")
    }
    let sink = RecordingSink()
    let config = AgentLoopConfig(
        model: "test-model",
        beforeToolCall: { _ in .proceed }
    )
    let call = ToolCallBlock(
        id: "direct-read",
        name: "read",
        arguments: .object(["path": .string("foo.txt")])
    )
    let assistant = AssistantMessage(
        content: [.toolCall(call)],
        model: "test-model",
        stopReason: .toolUse
    )

    let result = await executeDirectToolCall(
        call,
        from: assistant,
        tools: [tool],
        config: config,
        sink: sink
    )

    #expect(result.output == "read ok")
    #expect(seen.value == .object(["path": .string("foo.txt")]))
    #expect(sink.toolEndOrder == ["read"])
    #expect(sink.events.count == 4)
}
