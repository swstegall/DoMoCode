// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

/// A retry must be VISIBLE, and visible in the right channel.
///
/// Retries were silent end to end: the client emitted a notice, and the loop
/// discarded it before any surface could see it. With a ten-attempt budget and a
/// five-minute sleep ceiling, that made a busy gateway indistinguishable from a
/// hung one — the exact failure mode the retry budget was widened to survive.
///
/// These drive the real binary against a gateway that refuses once and then
/// answers, so they prove the whole path: HTTP 503 → classify → `.retrying` →
/// the loop's fold → `AgentEvent.notice` → print mode's stderr line.
@Suite
struct RetryVisibilityEndToEndTests {

    private static let finalTextTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"recovered."},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """#

    private static let overloaded = (
        status: 503,
        reason: "Service Unavailable",
        body: #"{"error":{"message":"upstream is at capacity","type":"server_error","code":"overloaded"}}"#
    )

    /// The regression test proper: one 503, one retry, and the run still
    /// succeeds — with the wait reported on stderr.
    @Test
    func aRetriedRunSaysSoOnStderrAndStillSucceeds() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: Self.overloaded,
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: [
                "-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL,
                // Keep the wall-clock cost to the first backoff step only.
                "--max-turns", "1",
            ],
            workspace: workspace,
            environment: ["DOMOCODE_RETRY_BASE_MS": "1", "DOMOCODE_RETRY_MAX_MS": "1"]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        // The refused attempt did not consume the scripted body, so the answer
        // still arrives.
        #expect(result.standardOutput == "recovered.\n")
        // Two round-trips: the refusal and the retry that succeeded.
        #expect(gateway.requestCount == 2)

        #expect(
            result.standardError.contains("Retrying in"),
            "stderr should report the wait: \(result.standardError)")
        #expect(result.standardError.contains("provider busy"))
        #expect(result.standardError.contains("attempt 1/"))
    }

    /// stdout is a scripted contract. A retry line on it would corrupt every
    /// caller that pipes `-p` into something.
    @Test
    func theRetryLineNeverTouchesStdout() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: Self.overloaded,
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: [
                "-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL,
                "--max-turns", "1",
            ],
            workspace: workspace,
            environment: ["DOMOCODE_RETRY_BASE_MS": "1", "DOMOCODE_RETRY_MAX_MS": "1"]
        )

        #expect(result.standardOutput == "recovered.\n")
        #expect(!result.standardOutput.contains("Retrying"))
        #expect(!result.standardOutput.contains("…"))
    }

    /// `--json` publishes an exact, ordered event vocabulary that scripts parse.
    /// A retry is a diagnostic, so it goes to stderr in this mode too — and adds
    /// no member to that vocabulary.
    @Test
    func jsonModeKeepsItsEventVocabularyAndStillReportsOnStderr() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: Self.overloaded,
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: [
                "-p", "hello", "--json", "--model", "mock-model", "--base-url", gateway.baseURL,
                "--max-turns", "1",
            ],
            workspace: workspace,
            environment: ["DOMOCODE_RETRY_BASE_MS": "1", "DOMOCODE_RETRY_MAX_MS": "1"]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(result.standardError.contains("Retrying in"))

        // Every stdout line is a JSON event, and none of them is a notice.
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.hasPrefix("{"), "stdout line is not JSON: \(line)")
            #expect(!line.contains("\"type\":\"notice\""), "notice leaked into the JSON stream: \(line)")
            #expect(!line.contains("Retrying"), "retry text leaked into the JSON stream: \(line)")
        }
    }

    /// A run that never retries must be byte-identical on both channels to what
    /// it was before retries were reported at all.
    @Test
    func aCleanRunGainsNoOutput() throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(result.standardOutput == "recovered.\n")
        #expect(!result.standardError.contains("Retrying"))
    }

    /// An unretryable refusal must not be reported as a retry. A 401 never
    /// clears on its own and is failed immediately.
    @Test
    func anUnretryableRefusalReportsNoRetry() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: (
                status: 401, reason: "Unauthorized",
                body: #"{"error":{"message":"Invalid API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#
            )
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 1)
        #expect(!result.standardError.contains("Retrying"))
        // Exactly one attempt: an unretryable status is not slept on.
        #expect(gateway.requestCount == 1)
    }
}
