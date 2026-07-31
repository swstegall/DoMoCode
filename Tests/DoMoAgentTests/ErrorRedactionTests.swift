// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `errorMessage` is the one string in a transcript that is written from
// gateway-controlled prose, and it is written FOREVER: the agent loop assigns
// it to the assistant message, the harness appends that message to the session
// JSONL, and nothing ever rewrites the file. A LiteLLM 401 body quotes back the
// API key it was given, so before redaction a single mistyped key ended up on
// disk in plaintext for the life of the session — and, because the harness also
// re-emits the message over SSE, in `-p --json`, on stderr and in both
// interactive surfaces, in four other places besides.
//
// These tests pin BOTH halves of the scope rule, and the second half is the one
// that is easy to get wrong:
//
//  - `errorMessage` and the error `notice` are redacted.
//  - Tool ARGUMENTS and tool OUTPUT and the user's own prompt are NOT. Those are
//    conversation state, replayed verbatim into the next request's context, and
//    a redactor that touched them would corrupt the conversation on resume —
//    turning a user's own `sk-`-shaped string in a source file into `[redacted]`
//    in the model's view of what it just read.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Testing

// MARK: - Fixtures

/// An `sk-proj-`-shaped key: prefix plus enough run characters to clear the
/// pattern rule's sixteen-character minimum.
private let leakedKey = "sk-proj-z9y8x7w6v5u4t3s2r1q0ponm"

/// A stream that fails the turn by throwing `error` before yielding anything.
private func failingStream(_ error: any Error) -> AgentStreamFn {
    { _ in AsyncThrowingStream { $0.finish(throwing: error) } }
}

// MARK: - errorMessage

@Suite("Error redaction — the persisted errorMessage")
struct PersistedErrorMessageRedactionTests {

    @Test("A gateway 401 that echoes the key never reaches the transcript with it")
    func errorMessageIsRedacted() async throws {
        let sink = RecordingSink()
        let result = await runOnce(
            sink: sink,
            streamFn: failingStream(
                DoMoError(.authentication, "Invalid API key \(leakedKey) provided")
            )
        )

        #expect(result.stopReason == .errored)
        // The classification is untouched — redaction rewrites prose, not kinds.
        #expect(result.failure?.kind == .authentication)
        let message = try #require(result.assistantMessages.first?.errorMessage)
        #expect(!message.contains("sk-proj-"))
        #expect(!message.contains(leakedKey))
        #expect(message.contains(Redaction.placeholder))
        #expect(message.contains("Invalid API key"))
    }

    /// The cause chain is where a *transport* failure hides a credential, and it
    /// is flattened into `errorMessage` by `DoMoError.description` — so the
    /// redaction has to run on the flattened string, not on the outermost
    /// message.
    @Test("A credential buried in the cause chain is redacted too")
    func causeChainIsRedacted() async throws {
        let inner = DoMoError(.transport, "connect to https://svc:\(leakedKey)@gateway.internal failed")
        let sink = RecordingSink()
        let result = await runOnce(
            sink: sink,
            streamFn: failingStream(DoMoError(.transport, "The model request failed", cause: inner))
        )

        let message = try #require(result.assistantMessages.first?.errorMessage)
        #expect(message.contains("The model request failed"))
        #expect(!message.contains(leakedKey))
        #expect(message.contains(Redaction.placeholder))
        // The host stays readable: it answers "which endpoint refused me?" and
        // is not the secret.
        #expect(message.contains("gateway.internal"))
    }

    @Test("An error notice carries the same scrubbed text to the UI")
    func errorNoticeIsRedacted() async throws {
        let sink = RecordingSink()
        _ = await runOnce(
            sink: sink,
            streamFn: failingStream(DoMoError(.authentication, "rejected token \(leakedKey)"))
        )

        let notice = try #require(sink.errorNotices.first)
        #expect(!notice.text.contains(leakedKey))
        #expect(notice.text.contains(Redaction.placeholder))
        #expect(notice.kind == "authentication")
    }

    @Test("An ordinary failure message is byte-identical after redaction")
    func ordinaryErrorMessageIsUnchanged() async throws {
        // Colons and a `://` are pattern-rule triggers, so this really does run
        // through the regexes rather than short-circuiting ahead of them.
        let text = "stream chat completions: HTTP 503: no healthy upstream at http://gateway.local/v1"
        let sink = RecordingSink()
        let result = await runOnce(
            sink: sink,
            streamFn: failingStream(DoMoError(.provider(status: 503, isRetryable: true), text))
        )

        #expect(result.assistantMessages.first?.errorMessage == text)
        #expect(sink.errorNotices.first?.text == text)
    }
}

// MARK: - What must NOT be redacted

@Suite("Error redaction — the scope boundary")
struct RedactionScopeTests {

    /// A user's own source file can legitimately contain an `sk-`-shaped string
    /// (a fixture, a docs example, a revoked key in a changelog). Tool output is
    /// replayed verbatim into the next request, so rewriting it would show the
    /// model something other than what it read.
    @Test("A tool result carrying an sk--shaped string is not altered")
    func toolOutputIsNotRedacted() async throws {
        let body = "config.example:3:  api_key = \(leakedKey)"
        let grep = FakeTool("grep") { _ in AgentToolResult(output: body) }
        let stream = ScriptedStream([
            assistantTurn(toolCalls: [tc("grep")], stopReason: .toolUse),
            assistantTurn(text: "found it", stopReason: .stop),
        ])
        let sink = RecordingSink()

        let result = await runOnce(
            context: AgentContext(tools: [grep]),
            sink: sink,
            streamFn: stream.fn
        )

        #expect(result.stopReason == .completed)
        let output = try #require(result.toolResults.first?.output)
        #expect(output == body)
        #expect(output.contains(leakedKey))
    }

    @Test("A tool call's arguments are not altered")
    func toolArgumentsAreNotRedacted() async throws {
        let echo = FakeTool("echo") { arguments in
            AgentToolResult(output: arguments["pattern"]?.stringValue ?? "<missing>")
        }
        let call = tc("echo", arguments: .object(["pattern": .string(leakedKey)]))
        let stream = ScriptedStream([
            assistantTurn(toolCalls: [call], stopReason: .toolUse),
            assistantTurn(stopReason: .stop),
        ])
        let sink = RecordingSink()

        let result = await runOnce(
            context: AgentContext(tools: [echo]),
            sink: sink,
            streamFn: stream.fn
        )

        // The tool saw the argument exactly as the model sent it…
        #expect(result.toolResults.first?.output == leakedKey)
        // …and the transcript still carries it, so a resume replays the same call.
        let assistant = try #require(result.assistantMessages.first)
        #expect(assistant.toolCalls.first?.arguments["pattern"]?.stringValue == leakedKey)
    }

    @Test("The user's own prompt text is not altered")
    func promptTextIsNotRedacted() async throws {
        let prompt = "rotate \(leakedKey) for me"
        let sink = RecordingSink()
        let result = await runOnce(
            prompt: prompt,
            sink: sink,
            streamFn: ScriptedStream([assistantTurn(text: "ok", stopReason: .stop)]).fn
        )

        let first = try #require(result.messages.first)
        guard case .user(let user) = first else {
            Issue.record("expected the prompt to be the first produced message")
            return
        }
        #expect(user.text == prompt)
    }
}

// MARK: - The display edge

@Suite("Error redaction — ErrorPresentation.rows")
struct ErrorPresentationRedactionTests {

    /// `rows` consumes a wire frame from another process, whose producer's
    /// version of this harness a renderer cannot check — so it scrubs again
    /// rather than trusting upstream.
    @Test("An error row never renders a credential")
    func rowsRedactTheMessage() {
        let parts = ErrorPresentation.rows(
            label: "authentication",
            message: "gateway rejected \(leakedKey) (request 8f21)"
        )

        #expect(parts.headline == "The gateway rejected the credential")
        #expect(!parts.message.contains(leakedKey))
        #expect(parts.message.contains(Redaction.placeholder))
        // Still diagnosable: the correlation id a user would quote survives.
        #expect(parts.message.contains("request 8f21"))
    }

    @Test("An error row with nothing to hide is unchanged")
    func rowsLeaveOrdinaryMessagesAlone() {
        let text = "HTTP 503: no healthy upstream at http://gateway.local/v1"
        let parts = ErrorPresentation.rows(label: "provider", message: text)

        #expect(parts.message == text)
    }
}
