// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM
import Testing

@Suite("Replay tool executor")
struct ReplayToolExecutorTests {
    @Test("replays a recorded result by tool-call id")
    func replaysByID() async throws {
        let first = call(id: "call-1", name: "read", path: "a.txt")
        let second = call(id: "call-2", name: "read", path: "b.txt")
        let executor = try ReplayToolExecutor(messages: trajectory([
            (first, "contents a"),
            (second, "contents b"),
        ]))

        let result = try await executor.execute(second)
        #expect(result.output == "contents b")
        #expect((await executor.remainingCallIDs()) == ["call-1"])

        let firstResult = try await executor.execute(first)
        #expect(firstResult.output == "contents a")
        #expect(await executor.isExhausted())
    }

    @Test("replays the complete stream in request order")
    func replaysAllInOrder() async throws {
        let first = call(id: "call-1", name: "one", path: "a")
        let second = call(id: "call-2", name: "two", path: "b")
        let executor = try ReplayToolExecutor(messages: trajectory([
            (first, "one result"),
            (second, "two result"),
        ]))

        let results = try await executor.replayAll()
        #expect(results.map(\.output) == ["one result", "two result"])
        #expect(await executor.recordedCallCount() == 2)
        #expect(await executor.isExhausted())
    }

    @Test("rejects argument drift and duplicate consumption")
    func rejectsDriftAndDuplicates() async throws {
        let original = call(id: "call-1", name: "read", path: "a.txt")
        let executor = try ReplayToolExecutor(messages: trajectory([(original, "ok")]))
        let changed = call(id: "call-1", name: "read", path: "other.txt")

        await #expect(throws: DoMoError.self) {
            _ = try await executor.execute(changed)
        }
        _ = try await executor.execute(original)
        await #expect(throws: DoMoError.self) {
            _ = try await executor.execute(original)
        }
    }

    @Test("rejects incomplete and mismatched recorded trajectories")
    func rejectsIncompleteAndMismatchedTrajectories() async {
        let call = call(id: "call-1", name: "read", path: "a.txt")
        let assistant = Message.assistant(
            AssistantMessage(content: [.toolCall(call)], model: "m", stopReason: .toolUse)
        )

        #expect(throws: DoMoError.self) {
            _ = try ReplayToolExecutor(messages: [assistant])
        }
        #expect(throws: DoMoError.self) {
            _ = try ReplayToolExecutor(messages: [
                assistant,
                .tool(ToolResultBlock(toolCallID: "call-1", toolName: "write", output: "ok")),
            ])
        }
        #expect(throws: DoMoError.self) {
            _ = try ReplayToolExecutor(messages: [
                .tool(ToolResultBlock(toolCallID: "orphan", toolName: "read", output: "ok")),
            ])
        }
    }

    private func call(id: String, name: String, path: String) -> ToolCallBlock {
        ToolCallBlock(id: id, name: name, arguments: .object(["path": .string(path)]))
    }

    private func trajectory(_ pairs: [(ToolCallBlock, String)]) -> [Message] {
        pairs.flatMap { call, output in
            [
                .assistant(
                    AssistantMessage(
                        content: [.toolCall(call)],
                        model: "m",
                        stopReason: .toolUse
                    )
                ),
                .tool(ToolResultBlock(toolCallID: call.id, toolName: call.name, output: output)),
            ]
        }
    }
}
