// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The Phase 1 exit criterion, exercised for real: the compiled `domocode` binary
// is driven over a loopback socket against a mock OpenAI-compatible gateway,
// through a two-turn conversation where turn 1 calls a tool and turn 2 produces
// the final text. This is deliberately not a unit test of the loop in isolation —
// it spawns the actual executable and asserts on its stdout and exit code.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct PrintModeEndToEndTests {

    // MARK: Scripted SSE

    /// Turn 1: the assistant streams a single `ls` tool call (id + name on the
    /// first fragment, arguments concatenated across a second), then a
    /// `tool_calls` finish and a usage-only trailing frame. Raw string so the
    /// JSON-escaped `arguments` value is written verbatim.
    static let toolCallTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_ls_1","type":"function","function":{"name":"ls","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    /// Turn 2: the assistant streams final text across two deltas, then a `stop`
    /// finish and usage.
    static let finalTextTurn = #"""
        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"I found "},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"the files."},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":6,"total_tokens":66}}

        data: [DONE]


        """#

    // MARK: Tests

    @Test
    func textModeRunsTwoTurnToolLoopAndPrintsFinalText() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomocode(
            arguments: ["-p", "list the files here", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        // pi's print text mode emits only the final assistant turn's text.
        #expect(result.standardOutput == "I found the files.\n")

        // Two HTTP round-trips: the tool-call turn and the final-text turn.
        #expect(gateway.requestCount == 2)

        // The second request must carry the tool result fed back to the model —
        // proof the loop actually dispatched `ls` and appended its output.
        let secondBody = gateway.requests[1].body
        #expect(secondBody.contains("hello.txt"), "second request body: \(secondBody)")
        #expect(secondBody.contains("\"role\":\"tool\""))
    }

    @Test
    func jsonModeEmitsToolAndResultEvents() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomocode(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let types = events.compactMap { $0["type"]?.stringValue }
        #expect(types.contains("session_start"))
        #expect(types.contains("tool_use"))
        #expect(types.contains("tool_result"))
        #expect(types.contains("result"))

        // The tool actually ran: its result event carries the real `ls` output.
        let toolResult = try #require(events.first { $0["type"]?.stringValue == "tool_result" })
        #expect(toolResult["name"]?.stringValue == "ls")
        #expect(toolResult["isError"]?.boolValue == false)
        let toolOutput = toolResult["output"]?.stringValue ?? ""
        #expect(toolOutput.contains("hello.txt"))

        // A single tool_use for `ls`, addressed by the streamed call id.
        let toolUse = try #require(events.first { $0["type"]?.stringValue == "tool_use" })
        #expect(toolUse["name"]?.stringValue == "ls")
        #expect(toolUse["id"]?.stringValue == "call_ls_1")

        // The response headers surfaced from the initial response block.
        let metadata = try #require(events.first { $0["type"]?.stringValue == "response_metadata" })
        #expect(metadata["callId"]?.stringValue == "mock-call-0")
        #expect(metadata["fellBack"]?.boolValue == false)

        let final = try #require(events.first { $0["type"]?.stringValue == "result" })
        #expect(final["text"]?.stringValue == "I found the files.")
    }

    @Test
    func missingModelExitsNonZeroWithMessage() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        // No --model, no DOMOCODE_MODEL, no settings file → a configuration error.
        let result = try runDomocode(
            arguments: ["-p", "hello", "--base-url", "http://127.0.0.1:1/v1"],
            workspace: workspace
        )
        #expect(result.exitCode != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("model"))
    }

    // MARK: Event stream parsing

    private static func parseEventStream(_ output: String) throws -> [JSONValue] {
        try output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONValue(parsing: String($0)) }
    }
}
