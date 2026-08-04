// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 5a, the two non-client surfaces: what `-p` REPORTS about what it spent,
// and what the inline REPL's status strip says about the same session.
//
// The `--json` event stream is a published contract, so every assertion here is
// about keys being ADDED to the events that already existed — never renamed,
// never removed, never reordered (`PrintModeEndToEndTests` pins the sequence).
//
// The load-bearing test in this file is `configuredRatesMakeTheCostNonZero`.
// Without a rate table there is no cost in the stream at all, and every other
// assertion about cost in this file would pass just as happily against an
// implementation that hardcoded a constant. It is the one that proves the whole
// per-alias rates path — settings.json → `ModelRuntime` → `makeStreamFn` →
// `Usage.costed(at:)` → `AgentHarness.accounting()` → the wire — is actually live.
//
// Its counterpart is `anUnpricedRunOmitsCostRatherThanClaimingItWasFree`. A run
// nothing priced reports NO cost — not `"0"`, which is a claim that the run was
// free — and `aModelPricedAtZeroStillReportsZeroRatherThanUnknown` is the other
// side of that line: a price of zero somebody actually stated is still a price.

// `@testable` reaches two internals that should stay internal: ``StatusLine``, an
// internal UI component, and ``PrintUsageEncoding``, which is print mode's own wire
// encoder and has no business being public. Everything else this file touches —
// ``InlineAccountingSummary`` and the compiled binary — is reachable without it, so
// the new public API still survives a plain `import` in `-c release`.
@testable import DoMoCLI
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoTUI
import Foundation
import Testing

@Suite(.serialized)
struct PrintModeAccountingTests {

    // MARK: Scripted SSE

    /// Turn 1: one `ls` tool call (auto-allowed, read-only), billed 42 prompt /
    /// 8 completion tokens. No `completion_tokens_details`, so the provider has
    /// said nothing whatsoever about reasoning.
    static let toolCallTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_ls_1","type":"function","function":{"name":"ls","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \".\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    /// Turn 2: the final answer, billed 60 prompt / 6 completion tokens. Again
    /// nothing about reasoning.
    static let finalTextTurn = #"""
        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"I found "},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"the files."},"finish_reason":null}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":6,"total_tokens":66}}

        data: [DONE]


        """#

    /// A one-turn answer whose usage frame DOES report reasoning tokens — the
    /// only difference from ``finalTextTurn``'s tail.
    static let reasoningTurn = #"""
        data: {"id":"chatcmpl-r","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Thought about it."},"finish_reason":null}]}

        data: {"id":"chatcmpl-r","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-r","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":6,"total_tokens":66,"completion_tokens_details":{"reasoning_tokens":7}}}

        data: [DONE]


        """#

    /// The same one-turn answer with the details object ABSENT. Paired with
    /// ``reasoningTurn`` so the two runs differ in exactly one wire field.
    static let noReasoningTurn = #"""
        data: {"id":"chatcmpl-n","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Thought about it."},"finish_reason":null}]}

        data: {"id":"chatcmpl-n","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-n","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":60,"completion_tokens":6,"total_tokens":66}}

        data: [DONE]


        """#

    // MARK: The assistant event

    @Test
    func jsonAssistantEventCarriesTokenCountsAndCost() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")
        // Priced, because `cost` is REPORTED only when something priced the run —
        // an unpriced run omits the key rather than claiming `"0"`. See
        // `anUnpricedRunOmitsCostRatherThanClaimingItWasFree`.
        try Self.writeUserSettings(
            workspace,
            #"{"modelOverrides": {"mock-model": {"input": 3, "output": 15}}}"#
        )

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let types = events.compactMap { $0["type"]?.stringValue }
        let assistants = events.filter { $0["type"]?.stringValue == "assistant" }
        #expect(assistants.count == 2, "types: \(types)")

        // Turn 1's own numbers, not the run's: the `assistant` event is per-turn.
        let first = try #require(assistants.first?["usage"]?.objectValue)
        #expect(first["input"]?.intValue == 42)
        #expect(first["output"]?.intValue == 8)
        #expect(first["cacheRead"]?.intValue == 0)
        #expect(first["cacheWrite"]?.intValue == 0)

        // Cost is a JSON STRING and not a number, because `JSONValue`'s only
        // fractional number is `.double` and a Decimal cost must not round-trip
        // through binary floating point.
        let cost = try #require(first["cost"]?.stringValue, "usage carried no cost: \(first)")
        #expect(Decimal(string: cost) != nil, "cost is not a parseable decimal: \(cost)")

        // Turn 2 reports its own, different numbers — proof this is the turn's
        // usage rather than one value stamped on every event.
        let second = try #require(assistants.last?["usage"]?.objectValue)
        #expect(second["input"]?.intValue == 60)
        #expect(second["output"]?.intValue == 6)
    }

    // MARK: Reasoning — absent is not zero

    @Test
    func reasoningIsAbsentWhenUnreportedAndPresentWhenReported() async throws {
        // 1) The gateway says nothing about reasoning: the key must not appear.
        //    `nil` and `0` are different claims, which is the entire reason
        //    `Usage.reasoning` is Optional.
        let silent = try MockGateway(chatCompletionBodies: [Self.noReasoningTurn])
        silent.start()
        defer { silent.stop() }

        let quietWorkspace = try Workspace()
        defer { quietWorkspace.cleanUp() }

        let quiet = try runDomo(
            arguments: ["-p", "think", "--model", "mock-model", "--base-url", silent.baseURL, "--json"],
            workspace: quietWorkspace
        )
        #expect(quiet.exitCode == 0, "stderr: \(quiet.standardError)")

        let quietEvents = try Self.parseEventStream(quiet.standardOutput)
        let quietUsage = try #require(
            quietEvents.first { $0["type"]?.stringValue == "assistant" }?["usage"]?.objectValue
        )
        // Anchor on a key that IS there, so "no reasoning key" cannot pass by the
        // whole object having gone missing.
        #expect(quietUsage["output"]?.intValue == 6)
        #expect(quietUsage["reasoning"] == nil, "reasoning must be absent, not 0: \(quietUsage)")

        // 2) The same run, one wire field different: the key appears with the
        //    reported count.
        let talkative = try MockGateway(chatCompletionBodies: [Self.reasoningTurn])
        talkative.start()
        defer { talkative.stop() }

        let loudWorkspace = try Workspace()
        defer { loudWorkspace.cleanUp() }

        let loud = try runDomo(
            arguments: ["-p", "think", "--model", "mock-model", "--base-url", talkative.baseURL, "--json"],
            workspace: loudWorkspace
        )
        #expect(loud.exitCode == 0, "stderr: \(loud.standardError)")

        let loudEvents = try Self.parseEventStream(loud.standardOutput)
        let loudUsage = try #require(
            loudEvents.first { $0["type"]?.stringValue == "assistant" }?["usage"]?.objectValue
        )
        #expect(loudUsage["reasoning"]?.intValue == 7, "usage: \(loudUsage)")
        // The run total carries it forward too.
        let loudResult = try #require(
            loudEvents.first { $0["type"]?.stringValue == "result" }?["usage"]?.objectValue
        )
        #expect(loudResult["reasoning"]?.intValue == 7, "result usage: \(loudResult)")
    }

    // MARK: The terminal result event

    @Test
    func resultEventCarriesTheSessionTotal() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")
        // Priced, for the same reason as the assistant-event test above: an
        // unpriced run reports no `cost` at all.
        try Self.writeUserSettings(
            workspace,
            #"{"modelOverrides": {"mock-model": {"input": 3, "output": 15}}}"#
        )

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let final = try #require(events.first { $0["type"]?.stringValue == "result" })

        // The two keys that were already published keep their meaning.
        #expect(final["text"]?.stringValue == "I found the files.")
        #expect(final["turns"]?.intValue == 2)

        // The added one is a SUM across both turns (42+60, 8+6) and not a copy of
        // the last turn's usage — 60/6 would also be a plausible-looking answer,
        // so this is the assertion that tells the two apart.
        let total = try #require(final["usage"]?.objectValue, "result carried no usage: \(final)")
        #expect(total["input"]?.intValue == 102)
        #expect(total["output"]?.intValue == 14)
        #expect(total["cacheRead"]?.intValue == 0)
        #expect(total["cacheWrite"]?.intValue == 0)
        #expect(total["cost"]?.stringValue != nil)
        // Neither turn mentioned reasoning, so neither does the total.
        #expect(total["reasoning"] == nil, "result usage: \(total)")
    }

    // MARK: The rates path is live

    @Test
    func configuredRatesMakeTheCostNonZero() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")
        // The user settings file, at `<DOMOCODE_CONFIG_DIR>/settings.json`. Prices
        // are per million tokens.
        try Self.writeUserSettings(
            workspace,
            #"{"modelOverrides": {"mock-model": {"input": 3, "output": 15}}}"#
        )

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let assistants = events.filter { $0["type"]?.stringValue == "assistant" }
        #expect(assistants.count == 2)

        // Turn 1: 42 input at $3/M + 8 output at $15/M.
        let firstCost = try #require(assistants.first?["usage"]?["cost"]?.stringValue)
        #expect(Decimal(string: firstCost) == Decimal(string: "0.000246"), "turn 1 cost: \(firstCost)")
        // Turn 2: 60 input + 6 output. A different number, so a single hardcoded
        // constant cannot satisfy both.
        let secondCost = try #require(assistants.last?["usage"]?["cost"]?.stringValue)
        #expect(Decimal(string: secondCost) == Decimal(string: "0.00027"), "turn 2 cost: \(secondCost)")

        // And the run total is their sum, carried by the harness's one accumulator.
        let final = try #require(events.first { $0["type"]?.stringValue == "result" })
        let totalCost = try #require(final["usage"]?["cost"]?.stringValue)
        #expect(Decimal(string: totalCost) == Decimal(string: "0.000516"), "total cost: \(totalCost)")
        #expect(Decimal(string: totalCost) != 0, "the whole rates path is dead if this is zero")
    }

    // MARK: Unpriced is not free

    /// With no rates configured, nothing on any surface may state a cost.
    ///
    /// The stream used to emit `"cost":"0"` and stderr `$0` for this run, which is
    /// not a missing number but a WRONG one: it says the run was free about a model
    /// whose price nobody ever wrote down. The same file already omits `reasoning`
    /// when the provider said nothing, and the same phase renders an unknown context
    /// window as `?` — this is that rule applied to the third unknown.
    @Test
    func anUnpricedRunOmitsCostRatherThanClaimingItWasFree() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let final = try #require(events.first { $0["type"]?.stringValue == "result" })
        let total = try #require(final["usage"]?.objectValue, "result carried no usage: \(final)")
        #expect(total["cost"] == nil, "an unpriced run claimed a cost: \(total)")
        // CONTROL: the usage object is still there and still real. "No cost key" is
        // equally true of a run that emitted no usage at all.
        #expect(total["input"]?.intValue == 102)
        #expect(total["output"]?.intValue == 14)

        // Per-turn, the same rule.
        let assistants = events.filter { $0["type"]?.stringValue == "assistant" }
        #expect(assistants.count == 2)
        for assistant in assistants {
            let usage = try #require(assistant["usage"]?.objectValue)
            #expect(usage["cost"] == nil, "an unpriced turn claimed a cost: \(usage)")
        }
    }

    /// The human-facing half: `cost unknown`, never `$0`.
    @Test
    func anUnpricedTextRunSaysCostUnknownOnStderr() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let result = try runDomo(
            arguments: ["-p", "list the files here", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        // CONTROL: the line was printed at all, with the tokens the run really used.
        #expect(result.standardError.contains("session total: 116 tokens"), "stderr: \(result.standardError)")
        #expect(result.standardError.contains("cost unknown"), "stderr: \(result.standardError)")
        #expect(!result.standardError.contains("$0"), "stderr claimed a free run: \(result.standardError)")
        // stdout stays byte-clean whatever the cost line says.
        #expect(result.standardOutput == "I found the files.\n", "stdout: \(result.standardOutput.debugDescription)")
    }

    /// The case the fix above must NOT break: a model an operator priced AT ZERO.
    ///
    /// "Nobody stated a price" and "the operator stated a price of zero" are
    /// different facts, and only the first is unknown. An implementation that
    /// decided on the total instead of on whether rates exist — `total == 0 ?
    /// unknown : known` — passes every other test in this file and fails this one.
    @Test
    func aModelPricedAtZeroStillReportsZeroRatherThanUnknown() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")
        try Self.writeUserSettings(
            workspace,
            #"{"modelOverrides": {"mock-model": {"input": 0, "output": 0}}}"#
        )

        let result = try runDomo(
            arguments: [
                "-p", "list the files here", "--model", "mock-model",
                "--base-url", gateway.baseURL, "--json",
            ],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let events = try Self.parseEventStream(result.standardOutput)
        let final = try #require(events.first { $0["type"]?.stringValue == "result" })
        let cost = try #require(
            final["usage"]?["cost"]?.stringValue,
            "a stated price of zero was reported as unknown: \(final)"
        )
        #expect(Decimal(string: cost) == 0, "cost: \(cost)")
        #expect(final["usage"]?["input"]?.intValue == 102)
    }

    // MARK: Text mode stays pipeable

    @Test
    func textModeStdoutIsOnlyTheAnswerAndTheTotalGoesToStderr() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.toolCallTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")
        try Self.writeUserSettings(
            workspace,
            #"{"modelOverrides": {"mock-model": {"input": 3, "output": 15}}}"#
        )

        let result = try runDomo(
            arguments: ["-p", "list the files here", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        // Byte-identical to what `-p` printed before there was any accounting:
        // the final answer and nothing else. This is what makes `-p` pipeable, so
        // it is an equality and not a `contains`.
        #expect(
            result.standardOutput == "I found the files.\n",
            "stdout: \(result.standardOutput.debugDescription)"
        )

        // The human-facing total is on stderr, where the retry notice and the
        // turn heartbeat already live.
        #expect(result.standardError.contains("session total"), "stderr: \(result.standardError)")
        #expect(result.standardError.contains("116 tokens"), "stderr: \(result.standardError)")
        #expect(result.standardError.contains("$0.000516"), "stderr: \(result.standardError)")
    }

    // MARK: The decision itself

    /// ``PrintUsageEncoding/reportableCost(_:ratesConfigured:reportedCost:)`` has
    /// three independent reasons to call a cost known, and each is pinned here.
    ///
    /// The end-to-end tests above can only reach the first of them. The third —
    /// "the total is not zero, so obviously something knows" — exists for the
    /// `--resume` case, where the harness seeds its totals by walking a file an
    /// EARLIER invocation priced: dropping that clause would re-report a real,
    /// non-zero, already-billed session as unknown.
    @Test
    func aCostIsKnownWhenRatesOrTheGatewayOrTheTotalItselfSaysSo() {
        let unpriced = PrintUsageEncoding.reportableCost(0, ratesConfigured: false, reportedCost: nil)
        #expect(unpriced == nil)

        // A rate table, even one that prices the model at zero.
        #expect(PrintUsageEncoding.reportableCost(0, ratesConfigured: true, reportedCost: nil) == 0)
        // The gateway billed it, even at zero.
        #expect(PrintUsageEncoding.reportableCost(0, ratesConfigured: false, reportedCost: 0) == 0)
        // A non-zero total from a session someone else priced (a resumed run).
        let resumed = PrintUsageEncoding.reportableCost(
            Decimal(string: "0.000516")!,
            ratesConfigured: false,
            reportedCost: nil
        )
        #expect(resumed == Decimal(string: "0.000516"))
    }

    // MARK: Helpers

    private static func writeUserSettings(_ workspace: Workspace, _ json: String) throws {
        try json.write(
            to: workspace.configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func parseEventStream(_ output: String) throws -> [JSONValue] {
        try output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try JSONValue(parsing: String($0)) }
    }
}

// MARK: - The inline REPL's status strip

/// ``InlineAccountingSummary`` is the inline REPL's half of the same job, and it
/// is pure, so it is tested directly rather than through a pty.
@Suite
struct InlineAccountingSummaryTests {

    private func accounting(
        tokens: Int = 0,
        cost: Decimal = 0,
        contextTokens: Int = 0,
        contextWindow: Int? = nil,
        turns: Int = 1
    ) -> SessionAccounting {
        SessionAccounting(
            usage: Usage(input: tokens),
            costTotal: cost,
            contextTokens: contextTokens,
            contextWindow: contextWindow,
            turns: turns
        )
    }

    /// The headline rule of the whole phase: an unknown window renders `?`, never
    /// a percentage of the 200K compaction fallback.
    @Test
    func anUnknownContextWindowRendersAQuestionMarkAndNeverAPercentage() {
        let text = InlineAccountingSummary.text(
            accounting(tokens: 12_345, cost: Decimal(string: "0.0031")!, contextTokens: 50_000)
        )
        #expect(text.contains("ctx 50.0k (?)"), "text: \(text)")
        // 50_000 of the 200_000 fallback would be "25%". Nothing here may be a
        // percentage, so the character itself must not appear anywhere in the row.
        #expect(!text.contains("%"), "a percentage of a guess leaked in: \(text)")
    }

    @Test
    func aKnownContextWindowRendersItsPercentage() {
        let text = InlineAccountingSummary.text(
            accounting(tokens: 12_345, contextTokens: 50_000, contextWindow: 200_000)
        )
        #expect(text.contains("ctx 50.0k (25%)"), "text: \(text)")
    }

    /// A window smaller than the fallback proves the percentage is computed
    /// against the model's OWN window: 50_000 of 100_000 is 50%, and 25% would be
    /// the answer for anything that quietly reached for the 200K fallback.
    @Test
    func thePercentageUsesTheModelsWindowRatherThanTheFallback() {
        let text = InlineAccountingSummary.text(
            accounting(tokens: 1, contextTokens: 50_000, contextWindow: 100_000)
        )
        #expect(text.contains("(50%)"), "text: \(text)")
    }

    /// Past the window is reported, not pinned at 100 — the next turn is what
    /// compacts, and how far past it has gone is the useful part.
    @Test
    func aContextOverItsWindowReportsTheRealPercentage() {
        let text = InlineAccountingSummary.text(
            accounting(tokens: 1, contextTokens: 300_000, contextWindow: 200_000)
        )
        #expect(text.contains("(150%)"), "text: \(text)")
    }

    @Test
    func costIsTheExactDecimalAndNotARoundedDouble() {
        let text = InlineAccountingSummary.text(accounting(cost: Decimal(string: "0.000516")!))
        // Two decimal places would render this as "$0.00" — a session that spent
        // half a cent reported as free.
        #expect(text.contains("$0.000516"), "text: \(text)")
    }

    /// A session that ran and still totals zero is a session nobody priced, and
    /// says so. A session that has not run yet is genuinely at zero.
    @Test
    func aZeroCostOnASessionThatRanIsMarkedUnknown() {
        let ran = InlineAccountingSummary.text(accounting(tokens: 500, cost: 0, turns: 2))
        #expect(ran.contains("$0.00?"), "text: \(ran)")

        let untouched = InlineAccountingSummary.text(accounting(tokens: 0, cost: 0, turns: 0))
        #expect(untouched.contains("$0.00"), "text: \(untouched)")
        #expect(!untouched.contains("$0.00?"), "text: \(untouched)")
    }

    @Test
    func tokenCountsAreCompacted() {
        #expect(InlineAccountingSummary.compact(0) == "0")
        #expect(InlineAccountingSummary.compact(999) == "999")
        #expect(InlineAccountingSummary.compact(1000) == "1.0k")
        #expect(InlineAccountingSummary.compact(12_345) == "12.3k")
        #expect(InlineAccountingSummary.compact(12_360) == "12.4k")
        // The rollover: one decimal place still fits below 999_950, and "1000.0k"
        // is never printed.
        #expect(InlineAccountingSummary.compact(999_949) == "999.9k")
        #expect(InlineAccountingSummary.compact(999_950) == "1.0M")
        #expect(InlineAccountingSummary.compact(1_450_000) == "1.5M")
    }

    /// Nothing known yet is an EMPTY strip, not a row of confident zeros.
    @Test
    func noAccountingRendersNothing() {
        #expect(InlineAccountingSummary.text(nil).isEmpty)
    }
}

// MARK: - The status row that carries it

/// The strip has to share one row with the REPL's affordances, and the renderer
/// treats an over-wide row as fatal — so how the two are fitted together is worth
/// its own assertions.
@Suite
@MainActor
struct StatusLineTrailingTests {

    @Test
    func anEmptyTrailingLeavesTheRowExactlyAsItWas() {
        let line = StatusLine()
        line.text = "  esc to interrupt"
        #expect(line.render(width: 40) == ["  esc to interrupt"])
    }

    @Test
    func theTrailingIsRightAlignedAgainstTheRow() {
        let line = StatusLine()
        line.text = "left"
        line.trailing = "right"
        let rows = line.render(width: 20)
        #expect(rows == ["left" + String(repeating: " ", count: 11) + "right"])
        // Exactly the row's width — one column over is what the renderer refuses.
        #expect(rows[0].count == 20)
    }

    /// The accounting segment stays whole while the affordance strip becomes a
    /// marquee window when the row narrows.
    @Test
    func theTrailingIsDroppedWholeRatherThanTruncated() {
        let line = StatusLine()
        line.text = "left"
        line.trailing = "$0.0312"
        // 4 + 2 columns of gap + 7 = 13, the narrowest row that fits both.
        #expect(line.render(width: 13) == ["left  $0.0312"])
        // One column narrower: the left side scrolls instead of hiding the meter.
        #expect(line.render(width: 12) == ["lef  $0.0312"])
    }

    @Test
    func actionableInlineTextCanTakePriorityOverAccounting() {
        let line = StatusLine()
        line.preservesTextWhenCrowded = true
        line.text = "  @ file · / command · enter to send · esc to interrupt"
        line.trailing = "tok 10 · $0.00? · ctx 10 (?)"
        #expect(line.render(width: 60) == [line.text])
    }

    @Test
    func aTrailingWiderThanTheRowNeverProducesAnOverWideLine() {
        let line = StatusLine()
        line.text = "hints"
        line.trailing = "tok 12.3k · $0.000516 · ctx 4.2k (2%)"
        let rows = line.render(width: 10)
        #expect(rows.count == 1)
        #expect(rows[0] == "hints")
    }

    /// The left side still fits as a marquee window beside a whole accounting
    /// segment, and the composed row never overhangs.
    @Test
    func anOverlongLeftSideIsStillClippedToWidth() {
        let line = StatusLine()
        line.text = String(repeating: "x", count: 40)
        line.trailing = "tok 0"
        let rows = line.render(width: 10)
        // Asserted on VISIBLE width because marquee output may carry ANSI state,
        // while over-wide is the failure that matters to AltScreenCore.
        #expect(rows.count == 1)
        #expect(visibleWidth(rows[0]) == 10)
        #expect(rows[0].hasPrefix(String(repeating: "x", count: 3)))
        #expect(rows[0].contains("tok 0"))
    }

    @Test
    func anOverlongLeftSideScrollsAfterItsLeadingPause() {
        let line = StatusLine()
        line.text = "0123456789"
        line.clock = { 1.1 }
        let initial = line.render(width: 5)[0]
        line.clock = { 2.2 }
        let moved = line.render(width: 5)[0]
        #expect(initial == "01234")
        #expect(moved != initial)
        #expect(visibleWidth(moved) == 5)
    }
}
