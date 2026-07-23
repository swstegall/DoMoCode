// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The Phase 3 exit criterion, exercised for real across TWO processes: a first
// `domocode -p` run persists a session, and a SECOND invocation with `--continue`
// resumes it against the same mock gateway. The proof is in the wire — the second
// process's request must carry the first turn's messages — so a unit test of the
// harness does not substitute. Both invocations spawn the actual compiled binary.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct SessionResumeEndToEndTests {

    /// A single-turn assistant reply that streams `content` across two deltas and
    /// finishes on `stop` — one LLM call, no tool calls, so each invocation makes
    /// exactly one request.
    private static func finalTextBody(id: String, content: String) -> String {
        let (first, second) = Self.split(content)
        let escapedFirst = Self.jsonEscape(first)
        let escapedSecond = Self.jsonEscape(second)
        return """
            data: {"id":"\(id)","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\(escapedFirst)"},"finish_reason":null}]}

            data: {"id":"\(id)","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\(escapedSecond)"},"finish_reason":null}]}

            data: {"id":"\(id)","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: {"id":"\(id)","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":4,"total_tokens":24}}

            data: [DONE]


            """
    }

    private static func split(_ content: String) -> (String, String) {
        guard content.count > 1 else { return (content, "") }
        let mid = content.index(content.startIndex, offsetBy: content.count / 2)
        return (String(content[..<mid]), String(content[mid...]))
    }

    private static func jsonEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Cross-process resume

    @Test
    func continueCarriesTheFirstTurnsContextIntoASecondProcess() async throws {
        let firstReply = "Noted: the number is 4242."
        let gateway = try MockGateway(chatCompletionBodies: [
            Self.finalTextBody(id: "chatcmpl-a", content: firstReply),
            Self.finalTextBody(id: "chatcmpl-b", content: "You mentioned 4242."),
        ])
        gateway.start()
        defer { gateway.stop() }

        // One workspace shared across both invocations, so the second run's session
        // directory and sanitized-cwd path match the first's — that is what lets
        // --continue find the file the first run wrote.
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let firstPrompt = "Please remember the number 4242 for later."
        let first = try runDomocode(
            arguments: ["-p", firstPrompt, "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(first.exitCode == 0, "stderr: \(first.standardError)")
        #expect(first.standardOutput == firstReply + "\n")

        // A session file was written under the isolated config dir's sessions tree.
        let sessionsRoot = workspace.configDirectory.appendingPathComponent("sessions")
        let sessionFiles = Self.sessionFiles(under: sessionsRoot)
        #expect(sessionFiles.count == 1, "expected exactly one session file, found \(sessionFiles)")

        let secondPrompt = "What number did I ask you to remember?"
        let second = try runDomocode(
            arguments: ["--continue", "-p", secondPrompt, "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(second.exitCode == 0, "stderr: \(second.standardError)")

        // Two processes, two requests total. The second request is the resumed run.
        #expect(gateway.requestCount == 2)
        let resumedRequest = gateway.requests[1].body

        // The heart of the exit criterion: the resumed process rebuilt the prior
        // context from the persisted file, so its request carries the first turn's
        // user prompt AND assistant reply, followed by the new prompt.
        #expect(resumedRequest.contains(firstPrompt), "resumed request missing user turn 1: \(resumedRequest)")
        #expect(resumedRequest.contains("4242"), "resumed request missing assistant turn 1: \(resumedRequest)")
        #expect(resumedRequest.contains(secondPrompt), "resumed request missing user turn 2: \(resumedRequest)")

        // The resume appended to the SAME file rather than starting a new one.
        #expect(Self.sessionFiles(under: sessionsRoot).count == 1)
    }

    // MARK: Fork

    @Test
    func forkResumesContextButWritesANewFile() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [
            Self.finalTextBody(id: "chatcmpl-a", content: "First answer about 4242."),
            Self.finalTextBody(id: "chatcmpl-b", content: "Second answer."),
        ])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let firstPrompt = "Remember 4242."
        let first = try runDomocode(
            arguments: ["-p", firstPrompt, "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(first.exitCode == 0, "stderr: \(first.standardError)")

        let sessionsRoot = workspace.configDirectory.appendingPathComponent("sessions")
        #expect(Self.sessionFiles(under: sessionsRoot).count == 1)

        let second = try runDomocode(
            arguments: ["--fork", "-p", "Continue on a branch.", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(second.exitCode == 0, "stderr: \(second.standardError)")

        // The fork carried the first turn's context...
        #expect(gateway.requests[1].body.contains(firstPrompt), "fork request missing prior context")
        // ...into a brand-new file: the original is left untouched, so there are now two.
        #expect(Self.sessionFiles(under: sessionsRoot).count == 2)
    }

    // MARK: Errors

    @Test
    func resumeWithUnknownIdFailsWithAClearError() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        // No gateway needed: resolution fails before any model call.
        let result = try runDomocode(
            arguments: [
                "--resume", "no-such-session-id", "-p", "hi",
                "--model", "mock-model", "--base-url", "http://127.0.0.1:1/v1",
            ],
            workspace: workspace
        )
        #expect(result.exitCode != 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("no-such-session-id"))
    }

    @Test
    func continueWithNoPriorSessionFailsWithAClearError() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomocode(
            arguments: ["--continue", "-p", "hi", "--model", "mock-model", "--base-url", "http://127.0.0.1:1/v1"],
            workspace: workspace
        )
        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("No previous session"))
    }

    // MARK: Helpers

    /// Every `.jsonl` session file anywhere under `root`, recursively (the store
    /// nests them one sanitized-cwd directory deep).
    private static func sessionFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}
