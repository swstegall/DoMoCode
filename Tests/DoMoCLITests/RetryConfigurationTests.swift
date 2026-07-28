// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The retry knobs: the raised default, the three new `DOMOCODE_RETRY_*`
// environment variables, and the fact that all of them reach the wire client.

import DoMoCLI
import DoMoCore
import DoMoLLM
import Foundation
import Testing

@Suite("Retry configuration")
struct RetryConfigurationTests {

    private func resolve(
        env: [String: String] = [:],
        project: Settings? = nil,
        user: Settings? = nil
    ) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(
            cli: CLIOverrides(), environment: env, project: project, user: user)
    }

    // MARK: Defaults

    @Test("The retry defaults are the ten-attempt budget, end to end")
    func defaults() throws {
        #expect(ResolvedConfiguration.defaultMaxRetries == 10)
        #expect(ResolvedConfiguration.defaultRetryBaseDelay == .seconds(1))
        #expect(ResolvedConfiguration.defaultRetryMaxDelay == .seconds(60))
        #expect(ResolvedConfiguration.defaultRetryDelayBudget == .seconds(300))

        let config = try resolve()
        #expect(config.maxRetries == 10)
        #expect(config.retryBaseDelay == .seconds(1))
        #expect(config.retryMaxDelay == .seconds(60))
        #expect(config.retryDelayBudget == .seconds(300))

        // The wire client is what actually retries; a default that stops at the
        // resolver is a default nobody gets.
        let client = config.clientConfiguration
        #expect(client.maxRetries == 10)
        #expect(client.baseRetryDelay == .seconds(1))
        #expect(client.maxRetryDelay == .seconds(60))
        #expect(client.retryDelayBudget == .seconds(300))
        #expect(client.maxPreConnectRetries == 1)
    }

    @Test("The library default and the CLI default agree")
    func libraryAndCLIAgree() {
        let library = LiteLLMClient.Configuration()
        #expect(library.maxRetries == ResolvedConfiguration.defaultMaxRetries)
        #expect(library.baseRetryDelay == ResolvedConfiguration.defaultRetryBaseDelay)
        #expect(library.maxRetryDelay == ResolvedConfiguration.defaultRetryMaxDelay)
        #expect(library.retryDelayBudget == ResolvedConfiguration.defaultRetryDelayBudget)
    }

    // MARK: Environment overrides

    @Test("Every retry knob is overridable from the environment")
    func environmentOverrides() throws {
        let config = try resolve(env: [
            EnvName.maxRetries: "4",
            EnvName.retryBaseMS: "250",
            EnvName.retryMaxMS: "5000",
            EnvName.retryBudgetMS: "30000",
        ])
        #expect(config.maxRetries == 4)
        #expect(config.retryBaseDelay == .milliseconds(250))
        #expect(config.retryMaxDelay == .milliseconds(5000))
        #expect(config.retryDelayBudget == .milliseconds(30000))
        #expect(config.clientConfiguration.baseRetryDelay == .milliseconds(250))
        #expect(config.clientConfiguration.retryDelayBudget == .milliseconds(30000))
    }

    /// Zero means "no budget", not "never sleep" — a zero ceiling would make
    /// every computed delay overshoot and silently disable retrying altogether.
    @Test("A retry budget of zero disables the budget rather than disabling retries")
    func zeroBudgetDisablesTheBudget() throws {
        let config = try resolve(env: [EnvName.retryBudgetMS: "0"])
        #expect(config.retryDelayBudget == nil)
        #expect(config.maxRetries == 10)
        #expect(config.clientConfiguration.retryDelayBudget == nil)
    }

    @Test("Settings-file values are honoured and the environment still beats them")
    func settingsFileAndPrecedence() throws {
        let user = Settings(maxRetries: 2, retryBaseMS: 100, retryMaxMS: 1000, retryBudgetMS: 2000)
        let project = Settings(retryBaseMS: 200)

        let fromFiles = try resolve(project: project, user: user)
        #expect(fromFiles.maxRetries == 2)
        #expect(fromFiles.retryBaseDelay == .milliseconds(200), "project must beat user")
        #expect(fromFiles.retryMaxDelay == .milliseconds(1000))
        #expect(fromFiles.retryDelayBudget == .milliseconds(2000))

        let fromEnv = try resolve(
            env: [EnvName.retryBaseMS: "50", EnvName.maxRetries: "9"], project: project, user: user)
        #expect(fromEnv.retryBaseDelay == .milliseconds(50))
        #expect(fromEnv.maxRetries == 9)
    }

    @Test(
        "A malformed retry knob is rejected rather than silently defaulted",
        arguments: [EnvName.retryBaseMS, EnvName.retryMaxMS, EnvName.retryBudgetMS]
    )
    func malformedValuesThrow(name: String) {
        #expect(throws: DoMoError.self) { try resolve(env: [name: "-1"]) }
        #expect(throws: DoMoError.self) { try resolve(env: [name: "soon"]) }
    }

    @Test("A negative retry knob in a settings file is rejected too")
    func negativeSettingsValueThrows() {
        #expect(throws: DoMoError.self) { try resolve(user: Settings(retryBaseMS: -1)) }
        #expect(throws: DoMoError.self) { try resolve(user: Settings(retryBudgetMS: -5)) }
    }

    @Test("The retry knobs round-trip through settings.json")
    func settingsCodingKeys() throws {
        let json = #"{"maxRetries":6,"retryBaseMs":300,"retryMaxMs":9000,"retryBudgetMs":45000}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.maxRetries == 6)
        #expect(settings.retryBaseMS == 300)
        #expect(settings.retryMaxMS == 9000)
        #expect(settings.retryBudgetMS == 45000)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
        #expect(decoded == settings)
    }

    /// The env names are documented in the README's configuration table; a typo
    /// here is a knob nobody can reach.
    @Test("The retry environment variable names are spelled as documented")
    func environmentNames() {
        #expect(EnvName.maxRetries == "DOMOCODE_MAX_RETRIES")
        #expect(EnvName.retryBaseMS == "DOMOCODE_RETRY_BASE_MS")
        #expect(EnvName.retryMaxMS == "DOMOCODE_RETRY_MAX_MS")
        #expect(EnvName.retryBudgetMS == "DOMOCODE_RETRY_BUDGET_MS")
    }
}
