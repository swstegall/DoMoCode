// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The per-alias plumbing, on the surfaces that had no test at all.
//
// Phase 5a's whole point is that a configured number reaches the run and comes
// back out. Three of those journeys were unverified, and the biggest one was the
// DEFAULT: with no flags, `domo` runs the two-pane client over an embedded
// `DoMoServer`, and every ingredient that server is built from comes out of
// `DoMoCodeCommand.buildServerRuntime`. A reviewer deleted `modelRuntime`,
// `compaction` and the summarizer from it — so every default session would bill
// $0.00, render `ctx N (?)` instead of a percentage, drop the alias's
// `reasoning_effort` and compact on stock budgets — and all 2,424 tests stayed
// green. `-p` and `--inline` were pinned; the one nobody tested is the one
// everybody uses.
//
// `--serve` is how that path is reachable from a test: it and the default client
// spawn through the SAME `buildServerRuntime`, so driving the server over its own
// HTTP surface exercises the default surface's wiring end to end, through the real
// compiled binary rather than around it.
//
// The other two journeys here are the summarizer's. `compaction.model` was parsed,
// merged, stored and asserted in unit tests while no production code read it, and
// `compactionSummarizer` could be made to return `nil` unconditionally with the
// full suite green — so "smallModel wired to a real summarizer", a headline
// deliverable, had nothing observing the summarizer being installed anywhere.
//
// Forcing a compaction from outside the process is the fiddly part, and the
// numbers below are chosen, not guessed. See `compactionBlock` for the
// arithmetic.

@testable import DoMoCLI
import DoMoCore
import DoMoHarness
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct SurfaceWiringTests {

    // MARK: Scripted SSE

    /// One complete assistant turn of plain text, with the usage frame that
    /// decides every number this file asserts.
    ///
    /// `totalTokens` is what ``DoMoHarness/estimateContextTokens(_:)`` anchors on —
    /// it trusts the provider's count for everything up to the last assistant turn
    /// — so it, and not the size of the transcript, is what compaction compares
    /// against the window.
    static func textTurn(
        _ text: String,
        promptTokens: Int = 60,
        completionTokens: Int = 6,
        totalTokens: Int = 66
    ) -> String {
        """
        data: {"id":"chatcmpl-x","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\(text)"},"finish_reason":null}]}

        data: {"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":\(promptTokens),"completion_tokens":\(completionTokens),"total_tokens":\(totalTokens)}}

        data: [DONE]


        """
    }

    // MARK: Forcing a compaction

    /// The compaction block the compaction tests in this file configure, and why
    /// these particular numbers.
    ///
    /// With `contextWindow: 100`:
    ///
    /// - `clamped(toContextWindow:)` leaves them alone, because `40 + 10` is
    ///   exactly the half-window budget. (The SHIPPED defaults do not survive that
    ///   clamp — `16384 + 20000` scales down to a reserve of 22, a trigger at 78 —
    ///   which is what makes a run that ignores this block visibly different: it
    ///   never compacts at all.)
    /// - `shouldCompact` fires above `100 - 40 = 60` tokens, and every scripted
    ///   turn reports 66.
    /// - `findCutIndex` walks back from the end accumulating tokens until it
    ///   reaches `keepRecentTokens: 10`, then cuts at the first USER message at or
    ///   after that point. So the third prompt is the first one where anything is
    ///   old enough to summarize, and the second prompt must be long enough to
    ///   carry the accumulator past 10 on its own — see ``promptB``.
    static let compactionBlock = #""compaction": {"reserveTokens": 40, "keepRecentTokens": 10}"#

    /// `{"modelOverrides": {"mock-model": {"contextWindow": 100}}}`, the small
    /// window the block above is sized against.
    static let tinyWindowOverride = #""modelOverrides": {"mock-model": {"contextWindow": 100}}"#

    static let promptA = "first question about the project"
    /// Long ON PURPOSE: it has to be worth more than `keepRecentTokens` (10 tokens
    /// ≈ 40 characters at the four-characters-per-token estimate) by itself, or the
    /// cut lands before it and nothing is old enough to summarize.
    static let promptB =
        "second question, deliberately long so the recent-context budget is exhausted by this message alone"
    static let promptC = "third question"
    /// Short on purpose: the LAST message must be worth less than
    /// `keepRecentTokens`, or the cut never reaches back to a user message.
    static let shortAnswer = "ok."

    // MARK: - The default surface: rates, window, effort

    /// The default surface bills at the alias's configured rates, reports the
    /// alias's declared context window, and sends the alias's reasoning effort.
    ///
    /// All three come off the one ``ModelRuntime`` `buildServerRuntime` resolves.
    /// Deleting it left every default-surface session billing $0.00 and rendering
    /// `ctx N (?)` with nothing failing.
    @Test
    func theDefaultSurfaceBillsAtTheConfiguredRatesAndReportsTheDeclaredWindow() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                Self.textTurn("all done.", promptTokens: 42, completionTokens: 8, totalTokens: 50)
            ]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        // A window that is nothing like the 200 000-token compaction fallback, so a
        // fallback leaking into the meter cannot be mistaken for the real answer.
        try Self.writeUserSettings(
            workspace,
            #"""
            {"modelOverrides": {"mock-model": {"contextWindow": 321000, "input": 3, "output": 15, "reasoningEffort": "high"}}}
            """#
        )

        let server = try ServeProcess(
            arguments: ["--serve", "--port", "0", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        defer { server.terminate() }

        let ready = try #require(
            await server.waitUntilListening(timeout: .seconds(60)),
            "domo --serve never announced a bound port. stderr: \(server.capturedStandardError)"
        )
        let sessionID = try await server.createSession(ready)
        try await server.startPrompt(ready, sessionID: sessionID, prompt: "hello")

        let settled = await ServeEndToEndTests.poll(timeout: .seconds(60)) {
            (try? await server.isRunning(ready, sessionID: sessionID)) == false
        }
        #expect(settled, "the served run never settled. stderr: \(server.capturedStandardError)")

        // 1. The request carried the ALIAS's reasoning effort. The global setting is
        //    unset here, so `high` can only have come from the override.
        #expect(gateway.requestCount == 1)
        let request = try JSONValue(parsing: gateway.requests[0].body)
        #expect(request["model"]?.stringValue == "mock-model")
        #expect(request["reasoning_effort"]?.stringValue == "high", "request: \(gateway.requests[0].body)")

        // 2. The session's own totals, off the server's status route — the same
        //    payload the client's footer reads.
        let status = try await Self.get(ready, path: "/session/\(sessionID)/status")
        let accounting = try #require(
            status["accounting"]?.objectValue,
            "the server reported no accounting: \(status)"
        )
        // CONTROL: the turn was billed at all.
        #expect(accounting["usage"]?["input"]?.intValue == 42, "accounting: \(accounting)")
        #expect(accounting["usage"]?["output"]?.intValue == 8)

        // The declared window, not `nil` (which renders `?`) and not the 200K
        // fallback.
        #expect(accounting["contextWindow"]?.intValue == 321_000, "accounting: \(accounting)")

        // 42 input at $3/M plus 8 output at $15/M. Asserted as a value and not
        // merely as "non-zero", so a hardcoded constant cannot satisfy it.
        //
        // A STRING on the wire, and compared as an exact `Decimal`: the whole
        // point of encoding it that way is that the number never round-trips
        // through a Double, so asserting it through one would test the opposite
        // of what the encoding exists for.
        let raw = try #require(accounting["costTotal"]?.stringValue, "accounting: \(accounting)")
        let cost = try #require(Decimal(string: raw), "costTotal not a decimal: \(raw)")
        #expect(cost > 0, "the whole per-alias rates path is dead on the default surface")
        #expect(cost == Decimal(string: "0.000246"), "costTotal: \(cost)")
    }

    // MARK: - The default surface: compaction and its summarizer

    /// The default surface compacts on the CONFIGURED budgets, using the
    /// CONFIGURED small model.
    ///
    /// Two deletions die here, and they fail differently — which is the point of
    /// asserting on the third request rather than on a count:
    ///
    /// - Drop `compaction:` from `buildServerRuntime` and the stock budgets clamp
    ///   to a trigger of 78 tokens against this 100-token window, so nothing ever
    ///   compacts: there are three requests, not four.
    /// - Drop `summarizer:` and the harness's built-in fallback summarizes through
    ///   the run's own `streamFn`, so the third request is there but carries
    ///   `mock-model`.
    @Test
    func theDefaultSurfaceCompactsOnTheConfiguredBudgetsWithTheConfiguredSmallModel() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                Self.textTurn(Self.shortAnswer),
                Self.textTurn(Self.shortAnswer),
                Self.textTurn("Earlier the user asked about the project."),
                Self.textTurn("done."),
            ]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            """
            {"smallModel": "small-model", \(Self.compactionBlock), \(Self.tinyWindowOverride)}
            """
        )

        let server = try ServeProcess(
            arguments: ["--serve", "--port", "0", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        defer { server.terminate() }

        let ready = try #require(
            await server.waitUntilListening(timeout: .seconds(60)),
            "domo --serve never announced a bound port. stderr: \(server.capturedStandardError)"
        )
        let sessionID = try await server.createSession(ready)
        for prompt in [Self.promptA, Self.promptB, Self.promptC] {
            try await server.startPrompt(ready, sessionID: sessionID, prompt: prompt)
            let settled = await ServeEndToEndTests.poll(timeout: .seconds(60)) {
                (try? await server.isRunning(ready, sessionID: sessionID)) == false
            }
            #expect(settled, "a served run never settled. stderr: \(server.capturedStandardError)")
        }

        try Self.expectCompactionRanWithTheSmallAlias(gateway, alias: "small-model")

        // And the meter still reports the declared window, which is what makes the
        // compaction budgets above the ones that were actually applied.
        let status = try await Self.get(ready, path: "/session/\(sessionID)/status")
        #expect(status["accounting"]?["contextWindow"]?.intValue == 100, "status: \(status)")
    }

    // MARK: - Print mode: compaction.model is read

    /// `compaction.model` selects the summarization alias, and print mode installs
    /// the resulting summarizer.
    ///
    /// `smallModel` is deliberately NOT set here: it defaults to the session's own
    /// model, so before `compaction.model` was read this configuration produced no
    /// summarizer at all and the harness summarized with `mock-model`. It is also
    /// the test that keeps print mode's `compaction:` and `summarizer:` arguments
    /// honest — the only two of `PrintMode`'s per-alias arguments that had nothing
    /// observing them.
    @Test
    func printModeSummarizesWithTheAliasCompactionModelNames() async throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                Self.textTurn(Self.shortAnswer),
                Self.textTurn(Self.shortAnswer),
                Self.textTurn("Earlier the user asked about the project."),
                Self.textTurn("done."),
            ]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            """
            {"compaction": {"model": "compactor-model", "reserveTokens": 40, "keepRecentTokens": 10}, \
            \(Self.tinyWindowOverride)}
            """
        )

        // Three runs on one session: the third is the first whose history has
        // anything old enough to summarize (see `compactionBlock`).
        // `DOMOCODE_SMALL_MODEL` is blanked because the environment outranks the
        // settings file, and this test's premise is that NOTHING named a small
        // model — a developer with that variable exported would otherwise install a
        // summarizer this test did not configure.
        let environment = ["DOMOCODE_SMALL_MODEL": ""]
        for (index, prompt) in [Self.promptA, Self.promptB, Self.promptC].enumerated() {
            let arguments =
                ["-p", prompt, "--model", "mock-model", "--base-url", gateway.baseURL]
                + (index == 0 ? [] : ["--continue"])
            let result = try runDomo(arguments: arguments, workspace: workspace, environment: environment)
            #expect(result.exitCode == 0, "run \(index) stderr: \(result.standardError)")
        }

        try Self.expectCompactionRanWithTheSmallAlias(gateway, alias: "compactor-model")
    }

    // MARK: - Resolution warnings are diagnostics like any other

    /// A warning quotes the value it could not understand, so it has to be scrubbed
    /// on the way out.
    ///
    /// `logLevel` is an interpolating field, so a one-line typo —
    /// `"{env:MY_GATEWAY_KEY}"` where a level belongs — resolves the gateway
    /// credential and then prints it to stderr and into whatever CI log is
    /// capturing that.
    ///
    /// The needle carries NO pattern trigger (no `sk-`, no colon, nothing a rule
    /// keys on), so ``DoMoCore/Redaction/patterns(_:)`` cannot mask it and only the
    /// literal registry can. That makes this the end-to-end proof of the whole
    /// handshake: the key is registered at startup, and the warning is emitted
    /// through the same vault.
    ///
    /// It is deliberately not `{env:DOMOCODE_API_KEY}` — the three built-in
    /// credential variables are on ``DoMoCore/InterpolationPolicy/deniedEnvironmentNames``
    /// and refused outright, which is a different (and already tested) defence. A
    /// key under an operator's own name is the case that gets through.
    @Test
    func resolutionWarningsAreRedactedBeforeTheyReachStderr() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.textTurn("done.")])
        gateway.start()
        defer { gateway.stop() }

        let secret = "gatewaysecretvalue123"
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            #"{"apiKeyEnv": "MY_GATEWAY_KEY", "logLevel": "{env:MY_GATEWAY_KEY}"}"#
        )

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            // `DOMOCODE_LOG_LEVEL` is blanked because the environment layer wins the
            // log level outright, and a level it parses short-circuits the settings
            // layers before they can complain about anything.
            environment: ["MY_GATEWAY_KEY": secret, "DOMOCODE_LOG_LEVEL": ""]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        // CONTROL: the warning was emitted at all, and still says what was wrong —
        // a redactor that ate the line would pass the leak checks below.
        #expect(
            result.standardError.contains("is not a log level"),
            "no warning reached stderr: \(result.standardError)"
        )
        // A value too long to be a level name is MEASURED, never echoed — not
        // even a prefix of it. Truncating instead was tried and was worse than
        // both alternatives: the scrub only replaces what the vault was told
        // about, `logLevel` is not a credential-shaped key so nothing registered
        // this value, and the surviving prefix was twelve characters of the
        // secret itself.
        #expect(
            result.standardError.contains("-character value"),
            "the value should be measured, not quoted: \(result.standardError)"
        )
        #expect(!result.standardError.contains(secret), "the key leaked to stderr: \(result.standardError)")
        #expect(
            !result.standardError.contains(secret.prefix(8)),
            "a prefix of the key leaked to stderr: \(result.standardError)"
        )
        #expect(!result.standardOutput.contains(secret), "stdout: \(result.standardOutput)")
    }

    // MARK: - Secret registration

    /// Every `mcpServers[*].environment` value is registered as a secret,
    /// regardless of what it is called.
    ///
    /// The name-based rules cannot help here: this variable is spelled `GH_PAT`,
    /// which announces nothing, and its value matches no pattern. Deleting the
    /// `registerAll` line — the defence the design notes call out by that exact
    /// name — used to leave the whole suite green.
    @Test
    func registerProcessSecretsRegistersEveryMcpEnvironmentValue() throws {
        // Unique per run, and free of any pattern trigger (no colon, no `sk-`, no
        // `ghp_`), so anything that masks it did so because it was REGISTERED.
        let secret = "wiringSecret\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let probe = "the MCP child was handed \(secret) on startup"

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            """
            {"mcpServers": {"gh": {"command": ["/bin/true"], "environment": {"GH_PAT": "\(secret)"}}}}
            """
        )

        let configuration = try ResolvedConfiguration.load(
            cli: CLIOverrides(),
            environment: [
                "DOMOCODE_CONFIG_DIR": workspace.configDirectory.path,
                "HOME": workspace.homeDirectory.path,
            ],
            workingDirectory: FilePath(workspace.workDirectory.path)
        )
        // CONTROL: the value survived resolution, so there is something to register.
        #expect(configuration.mcpServers["gh"]?.environment?["GH_PAT"] == secret)
        // CONTROL: the vault does not already mask it — otherwise the assertion
        // below would hold no matter what `registerProcessSecrets` did. The vault is
        // process-wide and every other suite in this process shares it, so this is
        // asserted on the bare value, which is unique to this run.
        #expect(Redaction.diagnostic(secret) == secret)

        DoMoCodeCommand.registerProcessSecrets(configuration)

        let scrubbed = Redaction.diagnostic(probe)
        #expect(!scrubbed.contains(secret), "the MCP environment value was never registered: \(scrubbed)")
        #expect(scrubbed.contains("[redacted]"), "scrubbed: \(scrubbed)")
        // The surrounding prose is untouched: a redactor that ate the sentence
        // would also "pass" the check above.
        #expect(scrubbed.hasPrefix("the MCP child was handed "), "scrubbed: \(scrubbed)")
    }

    // MARK: - Helpers

    /// The shared verdict of the two compaction tests: four model requests, and the
    /// third one is a SUMMARIZATION carrying `alias`.
    private static func expectCompactionRanWithTheSmallAlias(
        _ gateway: MockGateway,
        alias: String
    ) throws {
        let requests = gateway.requests
        #expect(
            requests.count == 4,
            "expected 3 turns plus one compaction; got \(requests.count) requests — nothing compacted"
        )
        guard requests.count == 4 else { return }

        // CONTROL: the ordinary turns went to the session's own model, so a
        // summarizer that had simply taken over the whole run cannot pass.
        for index in [0, 1, 3] {
            let body = try JSONValue(parsing: requests[index].body)
            #expect(body["model"]?.stringValue == "mock-model", "request \(index): \(requests[index].body)")
        }

        // The compaction request: the summarization prompt, sent to the small alias.
        let summarization = try JSONValue(parsing: requests[2].body)
        #expect(
            requests[2].body.contains(CompactionPrompts.instruction),
            "request 2 is not a summarization: \(requests[2].body)"
        )
        #expect(
            summarization["model"]?.stringValue == alias,
            "the summarization went to the wrong model: \(requests[2].body)"
        )
    }

    private static func writeUserSettings(_ workspace: Workspace, _ json: String) throws {
        try json.write(
            to: workspace.configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// One authenticated GET against the running server, parsed.
    private static func get(_ ready: ServeProcess.Ready, path: String) async throws -> JSONValue {
        guard let url = URL(string: "http://127.0.0.1:\(ready.port)\(path)") else {
            throw MockGatewayError("bad URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(ready.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw MockGatewayError("GET \(path) -> \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return try JSONValue(parsing: data)
    }
}
