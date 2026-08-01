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
// The SAME three-line deletion at the `--inline` call site was survivable too,
// and the first version of this file said `--inline` "was pinned" while leaving
// it exactly as unpinned as the default surface had been: the REPL tests build an
// `InteractiveMode` with arguments of their own, so nothing anywhere observed
// what the COMMAND hands that surface. The inline REPL refuses to start without a
// terminal ("cannot enable raw mode: fd 0 is not a terminal"), so it is driven
// here on a real pty, and its own status strip — which is where that surface
// draws the numbers — is read back off the terminal.
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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    // MARK: - The inline surface: rates, window, effort, compaction

    /// The alias override the inline test configures: a tiny window, a price, and
    /// a reasoning effort no global setting states.
    ///
    /// One override carries all three because they arrive on one
    /// ``DoMoLLM/ModelRuntime``, which is the single argument under test: the
    /// `100`-token window is what the compaction block below is sized against
    /// (see ``compactionBlock``) AND what turns the status strip's context meter
    /// into a number this test can name, and the rates are what turn its cost
    /// segment into one.
    static let pricedTinyWindowOverride =
        #""modelOverrides": {"mock-model": {"contextWindow": 100, "input": 3, "output": 15, "reasoningEffort": "high"}}"#

    /// `--inline` runs on the ALIAS's resolved runtime and the CONFIGURED
    /// compaction budgets, summarizing with the CONFIGURED small model.
    ///
    /// The three arguments `DoMoCodeCommand` hands `InteractiveMode.make` —
    /// `modelRuntime:`, `compaction:`, `summarizer:` — each die separately here,
    /// and all three could be deleted with the whole suite green before this
    /// existed:
    ///
    /// * Delete `modelRuntime:` and `make` builds a bare `ModelRuntime` from the
    ///   alias name: no reasoning effort on the wire, no rates (`$0.00?`), and no
    ///   declared window — so the meter reads `ctx 66 (?)` and compaction falls
    ///   back to its 200K guess, which this conversation never reaches.
    /// * Delete `compaction:` and the stock budgets clamp to a trigger of 78
    ///   tokens against this 100-token window, so nothing ever compacts: three
    ///   requests, not four.
    /// * Delete `summarizer:` and the harness's own fallback summarizes through
    ///   the run's `streamFn`, so the third request is there but carries
    ///   `mock-model`.
    ///
    /// A pty and three typed prompts is the price of admission: this surface has
    /// no HTTP door like `--serve` and refuses to start without a terminal.
    @Test
    func theInlineSurfaceRunsOnTheAliasRuntimeAndTheConfiguredCompaction() throws {
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
            {"smallModel": "small-model", \(Self.compactionBlock), \(Self.pricedTinyWindowOverride)}
            """
        )

        let terminal = try InlineTerminal()
        defer { terminal.tearDown() }
        try terminal.launch(
            arguments: ["--inline", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(terminal.waitUntilPainted(), "the inline REPL never painted a frame: \(terminal.text)")

        // Three prompts on one session: the third is the first whose history has
        // anything old enough to summarize (see `compactionBlock`).
        #expect(
            terminal.submit(Self.promptA, until: { gateway.requestCount >= 1 }),
            "the first prompt was never accepted"
        )
        terminal.settle()
        #expect(
            terminal.submit(Self.promptB, until: { gateway.requestCount >= 2 }),
            "the second prompt was never accepted"
        )
        terminal.settle()
        #expect(
            terminal.submit(Self.promptC, until: { gateway.requestCount >= 3 }),
            "the third prompt was never accepted"
        )
        // The summarization and the turn that follows it both land after that third
        // submit, and neither needs another keystroke — so this waits rather than
        // typing, and an Enter on an emptied editor cannot add a fourth run.
        let compacted = terminal.wait(timeout: .seconds(60)) { gateway.requestCount >= 4 }
        #expect(compacted, "the inline run never compacted: \(gateway.requestCount) requests")
        terminal.settle()

        // 1. The compaction budgets and the small alias.
        try Self.expectCompactionRanWithTheSmallAlias(gateway, alias: "small-model")

        // 2. The request carried the ALIAS's reasoning effort. Nothing else states
        //    one: the global setting is unset and the environment is swept.
        let first = try #require(gateway.requests.first, "the inline REPL never reached the gateway")
        let firstTurn = try JSONValue(parsing: first.body)
        #expect(firstTurn["reasoning_effort"]?.stringValue == "high", "request 0: \(first.body)")

        // 3. …and the numbers came back out onto the screen. Every scripted turn
        //    reports 66 of the declared 100 tokens, and 60 input at $3/M plus 6
        //    output at $15/M is $0.00027 a turn — so both segments are values this
        //    test names, not merely "something non-empty".
        let screen = terminal.text
        #expect(
            screen.contains("ctx 66 (66%)"),
            "the inline meter never showed the declared window: \(Self.strip(screen))"
        )
        #expect(
            screen.contains("$0.00027"),
            "the inline strip never billed at the configured rates: \(Self.strip(screen))"
        )
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
        //
        // This test's premise is that NOTHING named a small model, and a
        // developer with `DOMOCODE_SMALL_MODEL` exported would otherwise install a
        // summarizer it did not configure — which is exactly what happened, and
        // why ``isolatedChildEnvironment(inherited:workspace:extra:)`` now sweeps
        // every `DOMOCODE_*` name out of the child rather than blanking one of
        // them here. A per-test blanking is a defence against the variable
        // somebody already thought of.
        for (index, prompt) in [Self.promptA, Self.promptB, Self.promptC].enumerated() {
            let arguments =
                ["-p", prompt, "--model", "mock-model", "--base-url", gateway.baseURL]
                + (index == 0 ? [] : ["--continue"])
            let result = try runDomo(arguments: arguments, workspace: workspace)
            #expect(result.exitCode == 0, "run \(index) stderr: \(result.standardError)")
        }

        try Self.expectCompactionRanWithTheSmallAlias(gateway, alias: "compactor-model")
    }

    // MARK: - Resolution warnings are diagnostics like any other

    /// A secret SHORT enough to be quoted back is scrubbed on the way out.
    ///
    /// `logLevel` is an interpolating field, so a one-line typo —
    /// `"{env:MY_HELPER_TOKEN}"` where a level belongs — resolves a credential and
    /// then prints it to stderr and into whatever CI log is capturing that. The
    /// only thing standing between the two is
    /// `DoMoCodeCommand.execute`'s `Redaction.diagnostic(warning)`.
    ///
    /// **Every number in this test is a boundary, and the first version of it sat
    /// on the wrong side of one.** It used a twenty-one-character needle, which
    /// ``DoMoCLI/ResolvedConfiguration/quotable(_:)`` MEASURES rather than quotes
    /// — so the value never reached the warning at all, the scrub had nothing to
    /// do, and deleting the scrub left the whole suite green. Eight characters is
    /// the only length that tests it:
    ///
    /// * shorter, and ``DoMoCore/RedactionVault/register(_:)`` refuses to register
    ///   it (`minimumSecretLength`), so the vault could not mask it if it tried;
    ///   the test would pass on a technicality.
    /// * longer than a level name, and `quotable` measures it instead of quoting
    ///   it — the vacuous case above. Eight is the length of `critical`, the
    ///   longest level there is, and therefore the longest value worth quoting.
    ///
    /// The needle also carries NO pattern trigger (no `sk-`, no colon, nothing a
    /// rule keys on), so ``DoMoCore/Redaction/patterns(_:)`` cannot mask it, and it
    /// is not the variable `apiKeyEnv` names — nothing on the gateway-credential
    /// path gets to clean it up either.
    ///
    /// What is left is one specific line, and the ORDERING is what makes this
    /// exact rather than suggestive. `quotable` scrubs too, but it runs while the
    /// settings are being resolved, and at that moment the vault has never heard
    /// of this value: interpolated values are registered only for
    /// credential-carrying keys and `logLevel` is not one, and the literal in the
    /// `mcpServers` block is registered by
    /// ``DoMoCLI/DoMoCodeCommand/registerProcessSecrets(_:)``, which runs AFTER
    /// `load` has already built the warning string. So the placeholder can only
    /// have arrived at the print site — `Redaction.diagnostic(warning)` — and
    /// removing the same `mcpServers` block puts `(got "Zq7mVt4p")` on stderr,
    /// which is how that was checked rather than assumed.
    @Test
    func aShortSecretQuotedByAWarningIsScrubbedBeforeItReachesStderr() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.textTurn("done.")])
        gateway.start()
        defer { gateway.stop() }

        // Exactly eight characters — see this test's note. Mixed case and a digit
        // so it cannot collide with ordinary prose on stderr.
        let secret = "Zq7mVt4p"
        #expect(secret.count == 8, "the needle's length is the whole experiment")

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            #"""
            {"mcpServers": {"helper": {"command": ["/bin/true"], "environment": {"HELPER_TOKEN": "\#(secret)"}}}, \#
            "logLevel": "{env:MY_HELPER_TOKEN}"}
            """#
        )

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            // `DOMOCODE_LOG_LEVEL` is blanked because the environment layer wins the
            // log level outright, and a level it parses short-circuits the settings
            // layers before they can complain about anything.
            environment: ["MY_HELPER_TOKEN": secret, "DOMOCODE_LOG_LEVEL": ""]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        // CONTROL: the warning was emitted at all, and still says what was wrong —
        // a redactor that ate the line would pass the leak check below.
        #expect(
            result.standardError.contains("is not a log level"),
            "no warning reached stderr: \(result.standardError)"
        )
        // The value was QUOTED (this length is short enough to be), and what got
        // quoted is the placeholder. This is the positive half: without the scrub
        // the same warning reads `(got "Zq7mVt4p")`, and a change that stopped
        // quoting short values altogether would fail here rather than turn the
        // leak check below into a formality.
        #expect(
            result.standardError.contains("\"\(Redaction.placeholder)\""),
            "the warning did not quote a scrubbed value: \(result.standardError)"
        )
        #expect(!result.standardError.contains(secret), "the token leaked to stderr: \(result.standardError)")
        #expect(!result.standardOutput.contains(secret), "stdout: \(result.standardOutput)")
    }

    /// A value too LONG to be a level name is measured, never echoed — not even a
    /// prefix of it.
    ///
    /// This is the length cut, and only the length cut: nothing here registers the
    /// value, so the scrub above has nothing to say about it and deleting the
    /// scrub leaves this test green. That is the point of keeping the two apart —
    /// one test per defence, each failing for its own reason.
    ///
    /// Truncating instead of measuring was tried and was worse than both
    /// alternatives: the scrub only replaces what the vault was told about,
    /// `logLevel` is not a credential-shaped key so nothing registers this value,
    /// and the surviving prefix was twelve characters of the secret itself.
    @Test
    func aValueTooLongToBeALogLevelIsMeasuredAndNeverQuoted() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.textTurn("done.")])
        gateway.start()
        defer { gateway.stop() }

        let secret = "gatewaysecretvalue123"
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeUserSettings(
            workspace,
            #"{"logLevel": "{env:MY_GATEWAY_KEY}"}"#
        )

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            environment: ["MY_GATEWAY_KEY": secret, "DOMOCODE_LOG_LEVEL": ""]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(
            result.standardError.contains("is not a log level"),
            "no warning reached stderr: \(result.standardError)"
        )
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

    /// A terminal capture reduced to something readable in a failure message:
    /// escape sequences dropped, and only the last few hundred characters kept.
    ///
    /// The full capture is tens of kilobytes of cursor motion, and a failure
    /// nobody can read is a failure nobody diagnoses.
    private static func strip(_ text: String) -> String {
        var result = ""
        var inEscape = false
        for character in text {
            if character == "\u{1b}" {
                inEscape = true
                continue
            }
            if inEscape {
                // CSI/OSC parameters are all below `@`; the first byte at or above
                // it ends the sequence.
                if character.asciiValue.map({ $0 >= 0x40 }) ?? true { inEscape = false }
                continue
            }
            result.append(character)
        }
        return String(result.suffix(600))
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

// MARK: - The inline REPL, on a real terminal

/// A `domo --inline` running on a pseudo-terminal, plus the two gestures a test
/// needs: type a prompt, and read the screen back.
///
/// The inline REPL enables raw mode on fd 0 and refuses to start otherwise
/// ("cannot enable raw mode: fd 0 is not a terminal"), so there is no pipe-driven
/// way to reach it. ``FullScreenClientPTYTests`` owns a rig of the same shape for
/// the full-screen client; its copy is `private` to that file and drives one
/// prompt, while this one submits several in sequence and keeps the whole capture
/// so the status strip can be read out of it.
private final class InlineTerminal {
    private let master: Int32
    private let slave: FileHandle
    private let process = Process()
    private var captured: [UInt8] = []

    /// Alt-screen entry is the full-screen client's start signal; the inline REPL
    /// stays in the normal buffer, so its start signal is its first frame — the
    /// prompt row it paints before it reads a key.
    static let promptHint = "enter to send"

    init() throws {
        let descriptor = posix_openpt(O_RDWR | O_NOCTTY)
        guard descriptor >= 0 else { throw MockGatewayError("posix_openpt failed: \(errno)") }
        guard grantpt(descriptor) == 0, unlockpt(descriptor) == 0, let name = ptsname(descriptor) else {
            _ = close(descriptor)
            throw MockGatewayError("pty setup failed: \(errno)")
        }
        // Non-blocking, so draining never parks the test on a child that has
        // simply stopped painting.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        guard let handle = FileHandle(forUpdatingAtPath: String(cString: name)) else {
            _ = close(descriptor)
            throw MockGatewayError("could not open pty slave \(String(cString: name))")
        }
        master = descriptor
        slave = handle
    }

    /// Everything the child has written so far.
    var text: String { String(decoding: captured, as: UTF8.self) }

    func launch(arguments: [String], workspace: Workspace) throws {
        process.executableURL = domoBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = workspace.workDirectory
        // A freshly opened pty reports a 0×0 window; the size resolver falls back
        // to these, and 100 columns is wide enough for the whole status strip —
        // the REPL drops it segment by segment on a narrower terminal.
        process.environment = isolatedChildEnvironment(
            workspace: workspace,
            extra: ["COLUMNS": "100", "LINES": "30"]
        )
        process.standardInput = slave
        process.standardOutput = slave
        // stderr on its own pipe, so a log line cannot be mistaken for something
        // the UI painted.
        process.standardError = Pipe()
        try process.run()
    }

    func tearDown() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? slave.close()
        _ = close(master)
    }

    /// Everything the child has written since the last drain, appended.
    func drain() {
        var scratch = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = scratch.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            captured.append(contentsOf: scratch[0..<count])
        }
    }

    /// Type bytes at the child, exactly as a terminal would.
    func type(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            guard sent > 0 else { return }
            offset += sent
        }
    }

    /// Drain until `condition` holds or the deadline passes.
    func wait(timeout: Duration, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            drain()
            if condition() { return true }
            usleep(100_000)
        }
        drain()
        return condition()
    }

    func waitUntilPainted(timeout: Duration = .seconds(30)) -> Bool {
        wait(timeout: timeout) { text.contains(Self.promptHint) }
    }

    /// Let the current turn finish and the next frame paint, draining throughout.
    ///
    /// Typing the next prompt into a still-running turn QUEUES it rather than
    /// starting it, which would reorder the conversation this test's compaction
    /// arithmetic is sized against.
    func settle() {
        _ = wait(timeout: .milliseconds(1_500)) { false }
    }

    /// Type `prompt`, press Enter, and wait for `condition`.
    ///
    /// Enter is a SEPARATE write, a beat after the text: stdin framing treats a
    /// newline arriving in the same read as the characters before it as pasted
    /// content and inserts it in the editor instead of submitting. It is re-sent
    /// about once a second while waiting, because a keystroke that landed before
    /// raw mode was armed is simply gone — and because an Enter on an emptied
    /// editor submits nothing, that retry cannot manufacture an extra run.
    func submit(_ prompt: String, until condition: () -> Bool) -> Bool {
        type(prompt)
        usleep(400_000)
        type("\r")
        var ticks = 0
        return wait(timeout: .seconds(30)) {
            if condition() { return true }
            ticks += 1
            if ticks % 10 == 0 { type("\r") }
            return false
        }
    }
}
