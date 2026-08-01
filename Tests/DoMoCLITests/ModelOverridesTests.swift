// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The per-model half of the configuration vocabulary: what an operator can say
// about one alias that the gateway will not say, how the two settings files
// merge when they both say something, and what `modelRuntime(for:)` hands the
// surfaces that actually run a turn.

import DoMoCLI
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite
struct ModelOverridesTests {

    private func resolve(
        cli: CLIOverrides = CLIOverrides(),
        env: [String: String] = [:],
        project: Settings? = nil,
        user: Settings? = nil
    ) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(cli: cli, environment: env, project: project, user: user)
    }

    // MARK: Decoding

    /// Both authoring shapes have to survive the trip through `Settings`, not
    /// merely through `ModelOverride` on its own — a settings file is where they
    /// are actually written.
    @Test
    func settingsCarryModelOverridesInBothAuthoringShapes() throws {
        let json = """
            {
              "contextWindow": 128000,
              "modelOverrides": {
                "flat": {
                  "contextWindow": 400000,
                  "input": "1.25",
                  "output": "10",
                  "reasoningEffort": "high"
                },
                "nested": {
                  "rates": {
                    "base": {"input": 3, "output": 15},
                    "tiers": [{"inputTokensAbove": 200000, "rates": {"input": 6, "output": 22.5}}]
                  }
                }
              },
              "compaction": {"enabled": false, "reserveTokens": 4096, "model": "cheap"}
            }
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.contextWindow == 128_000)

        let flat = try #require(settings.modelOverrides?["flat"])
        #expect(flat.contextWindow == 400_000)
        #expect(flat.rates?.base.input == Decimal(string: "1.25"))
        #expect(flat.rates?.base.output == 10)
        // Unstated prices are zero, not inherited from anywhere.
        #expect(flat.rates?.base.cacheRead == 0)
        #expect(flat.reasoningEffort == ReasoningEffort.high)

        let nested = try #require(settings.modelOverrides?["nested"])
        // Silence about the window is `nil`, not the global 128000 above: the
        // two are different statements and only `modelRuntime(for:)` combines them.
        #expect(nested.contextWindow == nil)
        #expect(nested.rates?.base.input == 3)
        #expect(nested.rates?.rates(forInputTokens: 250_000).input == 6)

        #expect(settings.compaction?.enabled == false)
        #expect(settings.compaction?.reserveTokens == 4096)
        #expect(settings.compaction?.keepRecentTokens == nil)
        #expect(settings.compaction?.model == "cheap")
    }

    /// A settings file naming an unpriced model must not silently claim it is free.
    @Test
    func anOverrideThatStatesNoPriceHasNoRates() throws {
        let json = #"{"modelOverrides": {"m": {"contextWindow": 1000}}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.modelOverrides?["m"]?.rates == nil)
    }

    // MARK: The two merges

    /// `modelOverrides` merges per key with the **whole entry replaced**.
    ///
    /// The alternative — merging field by field — produces a price table neither
    /// file wrote: half a project's prices layered over half a user's, billed
    /// against a window a third party chose.
    @Test
    func modelOverridesReplaceTheWholeEntryPerKeyProjectOverUser() throws {
        let user = Settings(modelOverrides: [
            "shared": ModelOverride(
                contextWindow: 100,
                rates: ModelCostRates(input: 1, output: 2),
                reasoningEffort: .low
            ),
            "userOnly": ModelOverride(contextWindow: 200),
        ])
        let project = Settings(modelOverrides: ["shared": ModelOverride(contextWindow: 300)])

        let config = try resolve(project: project, user: user)
        let shared = try #require(config.override(for: "shared"))
        #expect(shared.contextWindow == 300)
        // The user's prices and effort are gone, not folded in. This is the
        // assertion that distinguishes the two merge rules.
        #expect(shared.rates == nil)
        #expect(shared.reasoningEffort == nil)

        // A key the project is silent about survives untouched.
        #expect(config.override(for: "userOnly")?.contextWindow == 200)
        #expect(config.override(for: "neverMentioned") == nil)
    }

    /// The lookup is exact. A gateway may serve `openai/gpt-5` and `gpt-5` as two
    /// different models at two different prices, and guessing they are one would
    /// bill a session at the wrong rate in silence.
    @Test
    func theOverrideLookupIsExact() throws {
        let config = try resolve(
            user: Settings(modelOverrides: ["openai/gpt-5": ModelOverride(contextWindow: 400_000)])
        )
        #expect(config.override(for: "openai/gpt-5")?.contextWindow == 400_000)
        #expect(config.override(for: "gpt-5") == nil)
        #expect(config.override(for: "OPENAI/GPT-5") == nil)
    }

    /// `compaction` merges **field by field**, deliberately unlike
    /// `modelOverrides`: a project tuning one dial must not discard the user's
    /// choice of summarization model.
    @Test
    func compactionMergesFieldByFieldProjectOverUser() throws {
        let user = Settings(
            compaction: CompactionOverrides(
                enabled: false, reserveTokens: 1000, keepRecentTokens: 2000, model: "cheap"
            )
        )
        let project = Settings(compaction: CompactionOverrides(keepRecentTokens: 5000))

        let config = try resolve(project: project, user: user)
        #expect(config.compaction.keepRecentTokens == 5000)
        // The fields the project is silent about are the user's, still.
        #expect(config.compaction.enabled == false)
        #expect(config.compaction.reserveTokens == 1000)
        #expect(config.compactionModel == "cheap")
    }

    @Test
    func configuringNoCompactionLeavesTheHarnessDefaultsAlone() throws {
        let bare = try resolve()
        #expect(bare.compaction == CompactionSettings.default)
        #expect(bare.compactionModel == nil)

        // An empty string is not a model name.
        let blank = try resolve(user: Settings(compaction: CompactionOverrides(model: "")))
        #expect(blank.compactionModel == nil)
    }

    // MARK: ModelRuntime

    /// An alias-level `reasoningEffort` beats the global one, because it is the
    /// more specific statement about this model.
    @Test
    func anAliasReasoningEffortBeatsTheGlobalSetting() throws {
        let config = try resolve(
            env: [EnvName.reasoningEffort: "low"],
            user: Settings(
                modelOverrides: [
                    "gpt-5": ModelOverride(
                        contextWindow: 400_000,
                        rates: ModelCostRates(input: 1, output: 2),
                        reasoningEffort: .high
                    )
                ],
                contextWindow: 64_000
            )
        )

        let specific = config.modelRuntime(for: "gpt-5")
        #expect(specific.model == "gpt-5")
        #expect(specific.reasoningEffort == ReasoningEffort.high)
        #expect(specific.contextWindow == 400_000)
        #expect(specific.rates?.base.output == 2)

        // An alias with no entry falls back to the global effort and the global
        // window, and has no prices at all.
        let general = config.modelRuntime(for: "some-other-model")
        #expect(general.model == "some-other-model")
        #expect(general.reasoningEffort == ReasoningEffort.low)
        #expect(general.contextWindow == 64_000)
        #expect(general.rates == nil)
    }

    /// An unknown window stays `nil` all the way to the runtime.
    ///
    /// Substituting a fallback here would be the whole bug this phase exists to
    /// prevent: a meter cannot tell a guessed denominator from a measured one,
    /// so it would render a confident percentage of a number nobody stated.
    @Test
    func anUnknownContextWindowStaysUnknown() throws {
        let config = try resolve(env: [EnvName.model: "mystery"])
        #expect(config.contextWindow == nil)
        #expect(config.modelRuntime(for: "mystery").contextWindow == nil)
    }

    /// There is exactly one fallback window in the package, and it belongs to
    /// the harness.
    ///
    /// `ResolvedConfiguration.defaultContextWindow` used to sit here as a second
    /// copy of it — declared, pinned to the harness's number by a test, and read
    /// by nothing at all. A constant nobody calls cannot make the CLI and the
    /// harness agree; it can only give a later contributor a plausible-looking
    /// number to substitute into a meter. It is gone, and what remains is the
    /// claim that actually matters: an unstated window reaches the harness as
    /// `nil`, and the harness — the only code that must have a number to compact
    /// against — supplies its own.
    @Test
    func theOnlyFallbackContextWindowBelongsToTheHarness() throws {
        #expect(AgentHarness.Configuration.fallbackContextWindow == 200_000)

        let unstated = try resolve(user: Settings(model: "mystery"))
        #expect(unstated.contextWindow == nil)
        #expect(unstated.modelRuntime(for: "mystery").contextWindow == nil)

        // And a stated one is passed through untouched rather than clamped to
        // the harness's floor in either direction.
        let stated = try resolve(user: Settings(contextWindow: 8_000))
        #expect(stated.modelRuntime(for: "mystery").contextWindow == 8_000)
        let large = try resolve(user: Settings(contextWindow: 1_000_000))
        #expect(large.modelRuntime(for: "mystery").contextWindow == 1_000_000)
    }

    // MARK: Validation

    /// A window of zero is not "small", it is a claim that no message fits.
    @Test
    func aStatedContextWindowMustBeARealCount() throws {
        #expect(throws: DoMoError.self) { try resolve(user: Settings(contextWindow: 0)) }

        let negative = #expect(throws: DoMoError.self) {
            try resolve(project: Settings(contextWindow: -1))
        }
        let text = try #require(negative?.description)
        #expect(text.contains("contextWindow"))
        #expect(text.contains("project settings.json"))

        #expect(try resolve(user: Settings(contextWindow: 1)).contextWindow == 1)
    }

    // MARK: apiKeyEnvName

    /// The configured credential variable's *name* has to survive resolution, or
    /// the two places that scrub the gateway credential out of a child process
    /// cannot know to scrub it — and a user who names their own variable hands
    /// that credential to every MCP server and every command the model runs.
    @Test
    func theConfiguredAPIKeyVariableNameIsCarriedForScrubbing() throws {
        #expect(try resolve(project: Settings(apiKeyEnv: "MY_KEY")).apiKeyEnvName == "MY_KEY")
        #expect(try resolve(user: Settings(apiKeyEnv: "USER_KEY")).apiKeyEnvName == "USER_KEY")

        // Project over user, and an empty name is not a name.
        let bothSet = try resolve(
            project: Settings(apiKeyEnv: "PROJECT_KEY"), user: Settings(apiKeyEnv: "USER_KEY")
        )
        #expect(bothSet.apiKeyEnvName == "PROJECT_KEY")

        let blankProject = try resolve(
            project: Settings(apiKeyEnv: ""), user: Settings(apiKeyEnv: "USER_KEY")
        )
        #expect(blankProject.apiKeyEnvName == "USER_KEY")

        #expect(try resolve().apiKeyEnvName == nil)

        // The name is carried whether or not the variable holds anything: the
        // scrub has to happen either way.
        let unset = try resolve(project: Settings(apiKeyEnv: "NEVER_EXPORTED"))
        #expect(unset.apiKeyEnvName == "NEVER_EXPORTED")
        #expect(unset.apiKey == nil)
    }
}
