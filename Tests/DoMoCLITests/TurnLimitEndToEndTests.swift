// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The turn limit, driven through the REAL binary.
//
// The reported defect was that a run silently stopped at twenty turns with no
// human able to intervene, so the regression has to be a run that goes PAST
// twenty and finishes — and it has to be the compiled `domo`, because the fan-out
// from `--max-turns` down to `AgentLoopConfig.maxTurns` crosses four layers and a
// unit test of any one of them would have kept passing while the CLI still sent
// its own `20`.
//
// The paired assertion is the one that keeps this honest: with no turn cap, the
// runaway guard is the ONLY bound left, so a genuinely stuck run must still stop.
// Both cases are exercised here, against the same binary, with their exit codes.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct TurnLimitEndToEndTests {

    // MARK: Scripted SSE

    /// One assistant turn that calls `ls` on `path`, then finishes with
    /// `tool_calls` so the loop dispatches the call and comes back for another
    /// turn.
    ///
    /// `path` is a parameter because it is what makes each turn DIFFERENT: the
    /// runaway guard compares tool calls and their results turn-to-turn, so a
    /// script of twenty-five identical calls would stop for lack of progress and
    /// prove nothing about the turn cap. Varying the path is the difference
    /// between "a long run that is working" and "a stuck run", which is precisely
    /// the distinction the two guards are supposed to draw.
    static func toolCallTurn(id: String, path: String) -> String {
        let arguments = #"{\"path\": \"\#(path)\"}"#
        return """
            data: {"id":"\(id)","object":"chat.completion.chunk","model":"mock-model","choices":\
            [{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,\
            "id":"call_\(id)","type":"function","function":{"name":"ls","arguments":""}}]},\
            "finish_reason":null}]}

            data: {"id":"\(id)","object":"chat.completion.chunk","choices":[{"index":0,"delta":\
            {"tool_calls":[{"index":0,"function":{"arguments":"\(arguments)"}}]},"finish_reason":null}]}

            data: {"id":"\(id)","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},\
            "finish_reason":"tool_calls"}]}

            data: [DONE]


            """
    }

    /// The final turn: plain text, `stop`, no tool call.
    static func finalTextTurn(_ text: String) -> String {
        """
        data: {"id":"final","object":"chat.completion.chunk","model":"mock-model","choices":\
        [{"index":0,"delta":{"role":"assistant","content":"\(text)"},"finish_reason":null}]}

        data: {"id":"final","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},\
        "finish_reason":"stop"}]}

        data: [DONE]


        """
    }

    /// `count` turns of varied tool work, then a final answer. The directories the
    /// script `ls`es are created by ``workspaceWithDirectories(_:)``, so every turn
    /// gets a distinct call AND a distinct result.
    static func variedScript(turns count: Int, finalText: String) -> [String] {
        (0..<count).map { toolCallTurn(id: "t\($0)", path: "d\($0)") } + [finalTextTurn(finalText)]
    }

    static func workspaceWithDirectories(_ count: Int) throws -> Workspace {
        let workspace = try Workspace()
        for index in 0..<count {
            let directory = workspace.workDirectory.appendingPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "file\(index)\n".write(
                to: directory.appendingPathComponent("f\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        return workspace
    }

    // MARK: The headline regression

    /// THE USER'S COMPLAINT, as a test. Twenty-five turns of real work followed by
    /// a final answer, with no `--max-turns` anywhere: this run completes cleanly.
    ///
    /// On the previous code the CLI passed `20` into every runtime and this exact
    /// script exited 2 at turn 20 with a half-finished working tree.
    @Test
    func noMaxTurnsFlagRunsPastTwentyTurns() async throws {
        let turns = 25
        let gateway = try MockGateway(chatCompletionBodies: Self.variedScript(turns: turns, finalText: "all done."))
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Self.workspaceWithDirectories(turns)
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "walk every directory", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(result.standardOutput.contains("all done."))
        // 25 tool turns + the final text turn. Anything less means a bound fired.
        #expect(gateway.requestCount == turns + 1, "stderr: \(result.standardError)")
        // And the unbounded run is not silent: text mode says it is still alive.
        #expect(
            result.standardError.contains("still working — turn 25"),
            "no progress heartbeat on stderr: \(result.standardError)"
        )
        // stdout stays the answer channel — the heartbeat is stderr-only.
        #expect(!result.standardOutput.contains("still working"))
    }

    /// `--max-turns 0` is the explicit spelling of unlimited, for a caller that
    /// builds its argument list programmatically and cannot simply omit a flag.
    /// It must NOT mean "zero turns": the loop emits `agent_start`/`turn_start`
    /// before its first bound check, so a literal 0 would settle a run with a
    /// dangling `turn_start`.
    @Test
    func maxTurnsZeroMeansUnlimited() async throws {
        let turns = 25
        let gateway = try MockGateway(chatCompletionBodies: Self.variedScript(turns: turns, finalText: "zero is unlimited."))
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Self.workspaceWithDirectories(turns)
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: [
                "-p", "walk every directory", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--max-turns", "0",
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(result.standardOutput.contains("zero is unlimited."))
        #expect(gateway.requestCount == turns + 1)
    }

    /// A negative budget is the one value that is neither a limit nor "unlimited",
    /// so it stays a usage error — with a message that names the new rule.
    @Test
    func negativeMaxTurnsIsAUsageError() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        // `--max-turns=-1` rather than a separate argument: a bare `-1` is parsed
        // as an option name, not as this option's value.
        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--max-turns=-1"],
            workspace: workspace
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains("--max-turns must be 0 (unlimited) or greater"),
            "stderr: \(result.standardError)"
        )
    }

    // MARK: The exit-code contract

    /// Exit `2` is unchanged and still reachable — it just has to be ASKED for
    /// now. The message names the limit that was hit and how to lift it, because
    /// with no default limit "you hit the limit" is otherwise a puzzle.
    @Test
    func askedForMaxTurnsStillExitsTwoAndSaysHowToLiftIt() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: (0..<3).map { Self.toolCallTurn(id: "t\($0)", path: ".") }
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--max-turns", "3", "--json",
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 2, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 3)
        #expect(result.standardError.contains("Reached --max-turns limit (3)"), "stderr: \(result.standardError)")
        #expect(result.standardError.contains("there is no turn limit by default"))
        // The machine-readable half a script reads is byte-for-byte what it was.
        let events = try Self.parseEventStream(result.standardOutput)
        let errorEvent = events.last { $0["type"]?.stringValue == "error" }
        #expect(errorEvent?["stopReason"]?.stringValue == "maxTurns", "stdout: \(result.standardOutput)")
    }

    /// Exit `3`: the runaway guard, which is what an unbounded run is protected by.
    ///
    /// The script asks for the SAME `ls` fifteen times over; the guard's default is
    /// twelve consecutive identical turns, so the run stops there — without a
    /// `--max-turns` anywhere — and reports a reason that tells the operator that
    /// raising a limit would change nothing.
    @Test
    func noProgressExitsThreeWithNoTurnLimitSet() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: (0..<15).map { Self.toolCallTurn(id: "same\($0)", path: ".") }
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: ["-p", "keep listing", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 3, "stderr: \(result.standardError)")
        #expect(result.standardOutput.isEmpty, "stdout: \(result.standardOutput)")
        #expect(result.standardError.contains("made no progress"), "stderr: \(result.standardError)")
        // Exactly the default streak, so a wrong limit shows up as a wrong count
        // rather than as a still-passing test.
        #expect(gateway.requestCount == 12, "stderr: \(result.standardError)")
    }

    // MARK: The JSON stream is unchanged

    /// The stderr heartbeat is a text-mode decision, and this is what pins it: a
    /// long `--json` run emits exactly the event types it always did, and nothing
    /// goes to stderr that looks like progress.
    ///
    /// A script consuming the JSON stream reads its `type` list; adding a
    /// per-turn event there would be a wire break dressed up as an improvement.
    @Test
    func jsonStreamGainsNoEventTypesOnALongRun() async throws {
        let turns = 25
        let gateway = try MockGateway(chatCompletionBodies: Self.variedScript(turns: turns, finalText: "done."))
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Self.workspaceWithDirectories(turns)
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: [
                "-p", "walk every directory", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        let types = Set(try Self.parseEventStream(result.standardOutput).compactMap { $0["type"]?.stringValue })
        #expect(
            types == [
                "session_start", "user", "turn_start", "response_metadata", "assistant",
                "tool_use", "tool_result", "text_delta", "result",
            ],
            "actual: \(types.sorted())"
        )
        #expect(!result.standardError.contains("still working"), "stderr: \(result.standardError)")
    }

    // MARK: Parsing

    /// Every non-empty stdout line as a JSON object.
    static func parseEventStream(_ output: String) throws -> [JSONValue] {
        try output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONValue(parsing: Data($0.utf8)) }
    }
}
