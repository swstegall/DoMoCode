// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `domo -p` never actually sent a gateway continuation.
//
// Print mode has no `shouldStopAfterTurn`, so it reconstructs it in the one seam
// it owns: once a turn ends on a failing stop reason, ``RunGuard`` makes the
// injected `streamFn` finish the next stream with the recorded error and issue no
// request. The harness's gateway-continuation loop re-drives `runAgentLoop` after
// a timed-out turn — and hit exactly that seam, so all ten sanctioned attempts
// were answered by a stream that never touched the socket. The run failed with
// the original timeout while the continuation loop reported, to nobody, that it
// was carrying on. `--serve` and the inline REPL got their continuations; `-p`
// got none, silently.
//
// The two directions have to be proved together, and that is what this file is
// for: a continuation must reach the gateway, and the runaway the guard was
// written to stop — a failing turn that carries tool calls, running them and
// marching on to a later clean turn that reports exit 0 over a provider failure —
// must still be stopped, INCLUDING inside a continuation that was sanctioned.
// `aSanctionedContinuationThatFailsAgainStillCannotMarchOn` is the load-bearing
// one: a "fix" that simply stops consulting the guard passes every other
// assertion here and fails that one.
//
// Assertions are on request BODIES rather than `requestCount`, because a failing
// turn also fires the one-shot recovery diagnostic, which is a real request to the
// same gateway. Counting requests would make these tests depend on how many
// diagnostics ran; asking which requests carried the continuation prompt does not.

// `@testable` reaches ``RunGuard``, which is print mode's own internal seam and
// has no business being public. The end-to-end tests below drive the compiled
// binary and need nothing from it.
@testable import DoMoCLI
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite(.serialized)
struct PrintModeContinuationTests {

    // MARK: Scripted SSE

    /// A clean one-turn answer. Used as the continuation's reply, and — in
    /// `aSanctionedContinuationThatFailsAgainStillCannotMarchOn` — as the trap:
    /// the clean turn queued behind a failing one, which a run that marched past
    /// the failure would report as success.
    private static let cleanAnswer = #"""
        data: {"id":"chatcmpl-c","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"continued."},"finish_reason":null}]}

        data: {"id":"chatcmpl-c","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-c","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":40,"completion_tokens":4,"total_tokens":44}}

        data: [DONE]


        """#

    /// An `ls` tool call finished with an *unrecognized* `finish_reason`, which
    /// ``StopReason`` keeps verbatim as `.unknown`. This is the shape ``RunGuard``
    /// exists for: a failure the agent loop does not short-circuit on, carrying
    /// tool calls it would otherwise dispatch before asking for another turn.
    private static let unknownFinishWithToolCall = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_ls_1","type":"function","function":{"name":"ls","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"flux_capacitor"}]}

        data: [DONE]


        """#

    /// The refusal that makes ``DoMoError/isGatewayTimeout`` true, which is the
    /// only failure the harness answers with a continuation. 504 rather than a
    /// mid-stream stall because the status is exact: the classification is not
    /// what these tests are about.
    private static let gatewayTimeout = (
        status: 504,
        reason: "Gateway Timeout",
        body: #"{"error":{"message":"upstream timed out","type":"server_error","code":"504"}}"#
    )

    /// One network attempt per completion, so the scripted 504 IS the turn's
    /// failure. With the shipping ten-retry budget the client would simply re-send
    /// and be served the next scripted body, and no continuation would ever be
    /// needed — the run would prove nothing.
    private static let noRetries = ["DOMOCODE_MAX_RETRIES": "0"]

    // MARK: The continuation reaches the gateway

    @Test
    func aTimedOutTurnIsFollowedByARealContinuationRequest() throws {
        // Every scripted body is the same clean answer, so nothing here depends on
        // which index the recovery diagnostic happens to consume.
        let gateway = try MockGateway(
            chatCompletionBodies: Array(repeating: Self.cleanAnswer, count: 4),
            refuseWith: Self.gatewayTimeout,
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "write the long thing", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            environment: Self.noRetries
        )

        // The whole defect in one assertion: a request carrying the harness's
        // continuation prompt actually arrived at the gateway. Before the fix the
        // seam answered every sanctioned attempt itself and this list was empty.
        let continuations = Self.continuationRequests(gateway)
        #expect(
            continuations.count == 1,
            "continuation requests: \(continuations.count), all requests: \(Self.summarize(gateway))"
        )

        // And it was a continuation, not a replay: the run recovered and reported
        // the continuation's answer as its own.
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(result.standardOutput == "continued.\n", "stdout: \(result.standardOutput.debugDescription)")

        // A `-p` caller is told why the run was carried on, on stderr, where the
        // retry notice already lives — stdout stays byte-clean for a pipe.
        #expect(result.standardError.contains("Gateway timed out"), "stderr: \(result.standardError)")
        #expect(result.standardError.contains("continuing (1/"), "stderr: \(result.standardError)")
        #expect(!result.standardOutput.contains("Gateway"), "stdout: \(result.standardOutput.debugDescription)")
    }

    // MARK: The runaway is still blocked

    @Test
    func anUnknownFinishWithToolCallsStillEndsTheRunBeforeAnotherRequest() throws {
        // The original trap: a `.unknown` turn that carries tool calls, with a
        // clean turn queued behind it. Without the guard the loop runs `ls`, asks
        // again, gets the clean turn, and reports the whole run as success.
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.unknownFinishWithToolCall, Self.cleanAnswer]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: ["-p", "list the files here", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            environment: Self.noRetries
        )

        #expect(result.exitCode == 1, "stderr: \(result.standardError)")
        #expect(result.standardOutput.isEmpty, "stdout: \(result.standardOutput.debugDescription)")
        #expect(result.standardError.contains("flux_capacitor"), "stderr: \(result.standardError)")

        // Exactly one model request: the failing turn. The queued clean turn was
        // never asked for.
        let modelRequests = Self.modelRequests(gateway)
        #expect(modelRequests.count == 1, "model requests: \(Self.summarize(gateway))")
        // No request ever carried a tool result. The loop does dispatch the
        // failing turn's `ls` locally — the guard stops the run at the NEXT model
        // request, not at the tool — so this is the assertion that says the result
        // was never fed back and no later turn was asked for.
        #expect(!Self.anyRequestCarriesAToolResult(gateway), "requests: \(Self.summarize(gateway))")
        // An unrecognized `finish_reason` is not a gateway timeout, so the harness
        // never sanctions a continuation and the guard is never lifted.
        #expect(Self.continuationRequests(gateway).isEmpty, "requests: \(Self.summarize(gateway))")
    }

    /// The one that tells the fix apart from removing the guard.
    ///
    /// A continuation IS sanctioned here — the run starts on a 504 — and its own
    /// first turn then fails with tool calls, with a clean turn queued behind it.
    /// The exemption is for one attempt, not for the rest of the run: the guard
    /// re-arms on that failing turn, so the tool result never reaches the gateway
    /// and the clean turn is never served. An implementation that stopped
    /// consulting the guard once a continuation was granted exits 0 here.
    @Test
    func aSanctionedContinuationThatFailsAgainStillCannotMarchOn() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                // Enough copies that the failing body is what the continuation is
                // served regardless of how many recovery diagnostics ran first…
                Self.unknownFinishWithToolCall,
                Self.unknownFinishWithToolCall,
                Self.unknownFinishWithToolCall,
                // …and the trap sits behind all of them, reachable only by a run
                // that marched past a failing turn.
                Self.cleanAnswer,
            ],
            refuseWith: Self.gatewayTimeout,
            refusalLimit: 1
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: ["-p", "list the files here", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            environment: Self.noRetries
        )

        // CONTROL: the exemption really was used, so the assertions below are
        // about a run that got its continuation rather than one that never
        // reached the path at all.
        #expect(Self.continuationRequests(gateway).count == 1, "requests: \(Self.summarize(gateway))")

        // And it stopped dead at the continuation's own failing turn.
        #expect(result.exitCode == 1, "stderr: \(result.standardError)")
        #expect(result.standardOutput.isEmpty, "stdout: \(result.standardOutput.debugDescription)")
        #expect(result.standardError.contains("flux_capacitor"), "stderr: \(result.standardError)")
        #expect(!Self.anyRequestCarriesAToolResult(gateway), "requests: \(Self.summarize(gateway))")
    }

    // MARK: Request classification

    /// A failing turn also fires the one-shot recovery diagnostic, which is a real
    /// request to the same gateway — and one that quotes recent session context
    /// back, so it can carry the continuation sentence without anything having
    /// asked the model to continue. It is identified by its own system prompt.
    private static func isRecoveryDiagnostic(_ request: RecordedRequest) -> Bool {
        request.body.contains("provider failure diagnostician")
    }

    /// The requests that asked the MODEL to answer this run's conversation:
    /// completions, minus the diagnostic and minus the model catalog.
    private static func modelRequests(_ gateway: MockGateway) -> [RecordedRequest] {
        gateway.requests.filter { request in
            request.method == "POST" && !isRecoveryDiagnostic(request)
        }
    }

    /// The requests carrying the harness's continuation prompt. Taken from
    /// ``GatewayContinuationSettings`` rather than spelled out, so a reworded
    /// default cannot make this silently match nothing.
    ///
    /// "Carrying", not "introducing": once a continuation is injected it stays in
    /// the transcript, so every later request in the same run replays it. That is
    /// what makes an empty result the sharp signal — it means no continuation ever
    /// reached the gateway — while a count above one means the run kept asking
    /// after the continuation, which each caller asserts about explicitly.
    private static func continuationRequests(_ gateway: MockGateway) -> [RecordedRequest] {
        modelRequests(gateway).filter { $0.body.contains(GatewayContinuationSettings.default.message) }
    }

    /// Whether any request fed a tool RESULT back to the model — the observable
    /// signature of the loop having dispatched a failing turn's tool calls and
    /// asked for another turn.
    private static func anyRequestCarriesAToolResult(_ gateway: MockGateway) -> Bool {
        gateway.requests.contains { $0.body.contains("\"role\":\"tool\"") }
    }

    /// A short description of what the gateway saw, for failure messages.
    private static func summarize(_ gateway: MockGateway) -> String {
        gateway.requests
            .map { request in
                let label = isRecoveryDiagnostic(request) ? "diagnostic" : "model"
                let continued = request.body.contains(GatewayContinuationSettings.default.message)
                return "\(request.method) \(request.path) [\(label)\(continued ? ", continuation" : "")]"
            }
            .joined(separator: ", ")
    }
}

// MARK: - The guard itself

/// ``RunGuard`` is pure and shared by reference between the event sink and the
/// stream seam, so the exemption's bounds are pinned directly rather than through
/// ten scripted timeouts.
@Suite
struct RunGuardContinuationTests {

    private func failingTurn(
        _ reason: StopReason = .unknown("flux_capacitor"),
        message: String
    ) -> AssistantMessage {
        AssistantMessage(model: "mock-model", stopReason: reason, errorMessage: message)
    }

    /// The property the whole fix rests on: standing down for one continuation is
    /// not the same as switching the guard off.
    @Test
    func aClearedGuardRearmsOnTheNextFailingTurn() {
        let guardState = RunGuard(continuationAllowance: 10)
        guardState.blockIfFailing(failingTurn(message: "first failure"))
        #expect(guardState.blockingError != nil)

        #expect(guardState.allowGatewayContinuation())
        #expect(guardState.blockingError == nil)

        // The continuation's own turn fails: the guard records THIS failure and
        // blocks again, so the loop cannot run its tools and ask for one more.
        guardState.blockIfFailing(failingTurn(message: "second failure"))
        let rearmed = guardState.blockingError
        #expect(rearmed != nil)
        #expect(rearmed?.message.contains("second failure") == true, "error: \(String(describing: rearmed))")
    }

    /// The allowance is a hard count, and it is spent only on a real clearance.
    @Test
    func theAllowanceIsFiniteAndIsNotSpentWhenNothingWasBlocked() {
        let guardState = RunGuard(continuationAllowance: 1)

        // Nothing is blocked, so nothing needed clearing and the single allowed
        // clearance is still available.
        #expect(guardState.allowGatewayContinuation() == false)

        guardState.blockIfFailing(failingTurn(message: "first failure"))
        #expect(guardState.allowGatewayContinuation())

        // Budget spent: a second announcement cannot buy another turn.
        guardState.blockIfFailing(failingTurn(message: "second failure"))
        #expect(guardState.allowGatewayContinuation() == false)
        #expect(guardState.blockingError != nil)
    }

    /// `gatewayContinuation.enabled = false` resolves to an allowance of zero,
    /// which must behave exactly as the guard did before it had an exemption.
    @Test
    func aZeroAllowanceNeverLiftsTheGuard() {
        let guardState = RunGuard(continuationAllowance: 0)
        guardState.blockIfFailing(failingTurn(message: "boom"))
        #expect(guardState.allowGatewayContinuation() == false)
        #expect(guardState.blockingError != nil)
    }

    /// CONTROL for the tests above: the guard's admission rule is unchanged by the
    /// state refactor the exemption needed. A clean turn and a `.length` turn are
    /// not failures the run must stop on — `.length` is how a long answer is
    /// continued in the first place.
    @Test
    func aCleanOrLengthTurnStillDoesNotBlockAnything() {
        let guardState = RunGuard(continuationAllowance: 10)
        guardState.blockIfFailing(AssistantMessage(model: "mock-model", stopReason: .stop))
        #expect(guardState.blockingError == nil)
        guardState.blockIfFailing(AssistantMessage(model: "mock-model", stopReason: .length))
        #expect(guardState.blockingError == nil)
        guardState.blockIfFailing(AssistantMessage(model: "mock-model", stopReason: .toolUse))
        #expect(guardState.blockingError == nil)
    }
}
