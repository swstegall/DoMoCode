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
    func jsonModeEmitsEventsInStableOrder() async throws {
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

        // The full wire sequence for a two-turn (tool call, then final text) run.
        // Locking the order down guards the retrofit against silently reshuffling
        // the stream a script depends on: `turn_start` precedes `response_metadata`
        // within each turn, tool events sit between the turns, and the run closes
        // on a single `result`.
        let types = try Self.parseEventStream(result.standardOutput).compactMap { $0["type"]?.stringValue }
        #expect(
            types == [
                "session_start",
                "user",
                "turn_start",
                "response_metadata",
                "assistant",
                "tool_use",
                "tool_result",
                "turn_start",
                "response_metadata",
                "text_delta",
                "text_delta",
                "assistant",
                "result",
            ],
            "actual: \(types)"
        )
    }

    @Test
    func maxTurnsExitsNonZeroWithMessage() async throws {
        // The model keeps asking to run a tool; with a one-turn budget the run is
        // cut off before it can produce a final answer.
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomocode(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--max-turns", "1",
            ],
            workspace: workspace
        )

        // Hitting the budget is a non-completion: a distinct non-zero exit, a
        // message on stderr, and nothing on stdout — there is no final answer.
        #expect(result.exitCode == 2, "stderr: \(result.standardError)")
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("max-turns"))
        // The budget stops the run before a second LLM call is made.
        #expect(gateway.requestCount == 1)
    }

    /// Turn 1: a `ls` tool call, but finished with an *unrecognized*
    /// `finish_reason` — a value no version of the API documents, which
    /// ``StopReason`` keeps verbatim as `.unknown`. Phase 1 treated this as a hard
    /// terminal error (exit 1) before running the tool.
    static let unknownFinishWithToolCall = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_ls_1","type":"function","function":{"name":"ls","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"flux_capacitor"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    @Test
    func unknownFinishReasonWithToolCallsFailsRatherThanReportingSuccess() async throws {
        // An unrecognized finish_reason is a provider failure. Phase 1 exited 1 on
        // it. The retrofit's loop only short-circuits on `.error`/`.aborted`, so a
        // `.unknown` turn that also carries tool calls would otherwise run those
        // tools and continue — and if a later turn finished cleanly, the run would
        // report SUCCESS (exit 0) on that failure. Two scripted turns reproduce
        // exactly that trap: the unknown turn calls a tool, and a clean final-text
        // turn is queued behind it. The run must still fail.
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.unknownFinishWithToolCall, Self.finalTextTurn]
        )
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

        // The failing stop reason ends the run: exit 1, its verbatim token on
        // stderr, and no clean `result` on stdout.
        #expect(result.exitCode == 1, "stderr: \(result.standardError)")
        #expect(result.standardError.contains("flux_capacitor"))

        // The run stopped at the failing turn — it did not march on to the queued
        // clean turn, so the second body was never requested.
        #expect(gateway.requestCount == 1)

        let types = try Self.parseEventStream(result.standardOutput).compactMap { $0["type"]?.stringValue }
        // No `result` event: the run did not complete successfully.
        #expect(!types.contains("result"))
        // It closes on `error`, not `result`.
        #expect(types.last == "error")
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
