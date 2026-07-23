// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import DoMoCore
import DoMoLLM
import Foundation
import Testing

@Suite
struct ConfigurationTests {

    private func resolve(
        cli: CLIOverrides = CLIOverrides(),
        env: [String: String] = [:],
        project: Settings? = nil,
        user: Settings? = nil
    ) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(cli: cli, environment: env, project: project, user: user)
    }

    // MARK: Defaults

    @Test
    func defaultsWhenNothingIsSet() throws {
        let config = try resolve()
        #expect(config.baseURL == "http://localhost:4000/v1")
        #expect(config.authHeaderName == "Authorization")
        #expect(config.authScheme == "Bearer")
        #expect(config.model == nil)
        #expect(config.apiKey == nil)
        #expect(config.maxRetries == 3)
        #expect(config.timeout == .milliseconds(600_000))
        #expect(config.streamTimeout == .milliseconds(30_000))
        #expect(config.offline == false)
        #expect(config.logLevel == .warning)
    }

    // MARK: Precedence

    @Test
    func cliBeatsEnvBeatsProjectBeatsUser() throws {
        let user = Settings(baseURL: "http://user:4000/v1", model: "user-model")
        let project = Settings(baseURL: "http://project:4000/v1", model: "project-model")
        let env = [EnvName.baseURL: "http://env:4000/v1", EnvName.model: "env-model"]
        let cli = CLIOverrides(baseURL: "http://cli:4000/v1", model: "cli-model")

        // Full stack: CLI wins.
        let all = try resolve(cli: cli, env: env, project: project, user: user)
        #expect(all.baseURL == "http://cli:4000/v1")
        #expect(all.model == "cli-model")

        // No CLI: env wins.
        let noCLI = try resolve(env: env, project: project, user: user)
        #expect(noCLI.baseURL == "http://env:4000/v1")
        #expect(noCLI.model == "env-model")

        // No CLI, no env: project wins over user.
        let noEnv = try resolve(project: project, user: user)
        #expect(noEnv.baseURL == "http://project:4000/v1")
        #expect(noEnv.model == "project-model")

        // Only user set.
        let onlyUser = try resolve(user: user)
        #expect(onlyUser.baseURL == "http://user:4000/v1")
        #expect(onlyUser.model == "user-model")
    }

    @Test
    func emptyEnvValueDoesNotOverride() throws {
        // An exported-but-empty variable should not win over a settings value.
        let project = Settings(model: "project-model")
        let config = try resolve(env: [EnvName.model: ""], project: project)
        #expect(config.model == "project-model")
    }

    // MARK: API key (secret from environment only)

    @Test
    func apiKeyFallbackChain() throws {
        #expect(try resolve(env: [EnvName.apiKey: "sk-domocode"]).apiKey == "sk-domocode")
        #expect(try resolve(env: ["LITELLM_API_KEY": "sk-litellm"]).apiKey == "sk-litellm")
        #expect(try resolve(env: ["OPENAI_API_KEY": "sk-openai"]).apiKey == "sk-openai")

        // DOMOCODE_API_KEY takes precedence over the others.
        let all = try resolve(env: [
            EnvName.apiKey: "sk-domocode",
            "LITELLM_API_KEY": "sk-litellm",
            "OPENAI_API_KEY": "sk-openai",
        ])
        #expect(all.apiKey == "sk-domocode")
    }

    @Test
    func apiKeyIsReadFromTheNamedEnvVarButNeverFromSettings() throws {
        // Settings names the variable; the value comes from the environment.
        let settings = Settings(apiKeyEnv: "MY_CUSTOM_KEY")
        let config = try resolve(env: ["MY_CUSTOM_KEY": "sk-custom"], project: settings)
        #expect(config.apiKey == "sk-custom")

        // A named-but-unset variable falls through to the default chain rather
        // than forcing an unauthenticated request.
        let fallback = try resolve(
            env: [EnvName.apiKey: "sk-default"],
            project: Settings(apiKeyEnv: "UNSET_VAR")
        )
        #expect(fallback.apiKey == "sk-default")
    }

    // MARK: Derived / parsed fields

    @Test
    func smallModelFallsBackToModel() throws {
        let config = try resolve(env: [EnvName.model: "big-model"])
        #expect(config.model == "big-model")
        #expect(config.smallModel == "big-model")

        let explicit = try resolve(env: [EnvName.model: "big", EnvName.smallModel: "small"])
        #expect(explicit.smallModel == "small")
    }

    @Test
    func reasoningEffortParsed() throws {
        let config = try resolve(env: [EnvName.reasoningEffort: "high"])
        #expect(config.reasoningEffort == ReasoningEffort.high)
    }

    @Test
    func timeoutAndRetriesParseFromEnvironment() throws {
        let config = try resolve(env: [
            EnvName.timeoutMS: "120000",
            EnvName.streamTimeoutMS: "5000",
            EnvName.maxRetries: "7",
        ])
        #expect(config.timeout == .milliseconds(120_000))
        #expect(config.streamTimeout == .milliseconds(5_000))
        #expect(config.maxRetries == 7)
    }

    @Test
    func invalidNumericEnvValueThrowsConfiguration() {
        #expect(throws: DoMoError.self) {
            try resolve(env: [EnvName.timeoutMS: "not-a-number"])
        }
        #expect(throws: DoMoError.self) {
            try resolve(env: [EnvName.maxRetries: "-1"])
        }
    }

    @Test
    func offlineAndLogLevelAreLooselyParsed() throws {
        #expect(try resolve(env: [EnvName.offline: "1"]).offline == true)
        #expect(try resolve(env: [EnvName.offline: "true"]).offline == true)
        #expect(try resolve(env: [EnvName.offline: "0"]).offline == false)
        #expect(try resolve(env: [EnvName.logLevel: "DEBUG"]).logLevel == .debug)
        #expect(try resolve(env: [EnvName.logLevel: "nonsense"]).logLevel == .warning)
    }

    @Test
    func clientConfigurationCarriesResolvedValues() throws {
        let config = try resolve(env: [
            EnvName.baseURL: "http://host:4000/v1",
            EnvName.apiKey: "sk-x",
            EnvName.authHeader: "X-Api-Key",
            EnvName.authScheme: "Token",
            EnvName.maxRetries: "2",
        ])
        let client = config.clientConfiguration
        #expect(client.baseURL == "http://host:4000/v1")
        #expect(client.apiKey == "sk-x")
        #expect(client.authHeaderName == "X-Api-Key")
        #expect(client.authScheme == "Token")
        #expect(client.maxRetries == 2)
    }

    // MARK: Settings file loading

    @Test
    func loadReturnsNilForMissingFileAndThrowsForMalformed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.json")
        #expect(try Settings.load(fromPath: missing.path) == nil)

        let valid = directory.appendingPathComponent("valid.json")
        try #"{"baseUrl":"http://x:4000/v1","model":"m","maxRetries":5}"#.write(
            to: valid, atomically: true, encoding: .utf8
        )
        let settings = try #require(try Settings.load(fromPath: valid.path))
        #expect(settings.baseURL == "http://x:4000/v1")
        #expect(settings.model == "m")
        #expect(settings.maxRetries == 5)

        let malformed = directory.appendingPathComponent("malformed.json")
        try "{ this is not json".write(to: malformed, atomically: true, encoding: .utf8)
        #expect(throws: DoMoError.self) {
            try Settings.load(fromPath: malformed.path)
        }
    }
}
