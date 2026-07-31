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
        #expect(config.maxRetries == 10)
        #expect(config.timeout == .milliseconds(600_000))
        #expect(config.streamTimeout == .milliseconds(120_000))
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

    /// `0` disables the stream idle bound; it must never mean "fail instantly".
    ///
    /// Threaded through literally, a zero idle window fails every turn a few
    /// milliseconds after the response head — every request, against every
    /// gateway. `DOMOCODE_RETRY_BUDGET_MS` already established that 0 means
    /// "stop enforcing this", and this knob follows it.
    @Test
    func aZeroStreamTimeoutDisablesTheBoundRatherThanFailingEveryTurn() throws {
        // Asserted as the value the TRANSPORT receives, not merely as the value
        // the resolver holds. An earlier version of this fix mapped 0 to `nil`
        // and passed that down, where `?? defaultIdleTimeout` turned it straight
        // back into 120s — the config-level assertion still passed, and the
        // behaviour was the opposite of what the operator asked for.
        let disabled = try resolve(env: [EnvName.streamTimeoutMS: "0"])
        #expect(disabled.streamTimeout == .zero)
        #expect(disabled.clientConfiguration.streamIdleTimeout == .zero)

        let set = try resolve(env: [EnvName.streamTimeoutMS: "45000"])
        #expect(set.streamTimeout == .milliseconds(45_000))
        #expect(set.clientConfiguration.streamIdleTimeout == .milliseconds(45_000))
    }

    /// `DOMOCODE_TIMEOUT_MS=0` must not brick every request either.
    ///
    /// The overall deadline bounds time-to-response-head, so a literal zero fails
    /// each attempt in about a second — and it is the value the stream knob's
    /// "disabled" case falls back to, so a zero here would silently re-tighten the
    /// bound the operator just switched off. Unlike the stream knob there is no
    /// "no deadline" to express: AsyncHTTPClient needs one, so 0 means the default.
    @Test
    func aZeroOverallTimeoutFallsBackToTheDefault() throws {
        #expect(try resolve(env: [EnvName.timeoutMS: "0"]).timeout == ResolvedConfiguration.defaultTimeout)
        #expect(try resolve(env: [EnvName.timeoutMS: "5000"]).timeout == .milliseconds(5000))
    }

    @Test
    func logLevelIsLooselyParsed() throws {
        #expect(try resolve(env: [EnvName.logLevel: "DEBUG"]).logLevel == .debug)
        #expect(try resolve(env: [EnvName.logLevel: "nonsense"]).logLevel == .warning)
    }

    /// A settings.json written against an older build still loads.
    ///
    /// `DOMOCODE_OFFLINE` was removed rather than wired: nothing consumed it,
    /// and there was nothing for it to skip — no run path calls the model
    /// catalog and there are no version lookups. Decoding is `decodeIfPresent`
    /// per declared key and never enumerates the container, so a stale
    /// `"offline"` is ignored instead of throwing. This pins that, because the
    /// alternative is a user's config file failing to load after an upgrade.
    @Test
    func settingsIgnoresKeysThisBuildNoLongerKnows() throws {
        let json = #"{"model": "gpt-5", "offline": true, "somethingElse": 3}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.model == "gpt-5")
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

    // MARK: Pre-existing defects (Phase 5a)

    /// `DOMOCODE_SESSION_DIR=""` used to become `FilePath("")`.
    ///
    /// An exported-but-empty variable is how a shell spells "I set this and then
    /// unset it", and it is the one case `resolveConfigDirectory` had always
    /// guarded against and this path had not. `FilePath("")` is relative, so
    /// every session file went to the process's working directory — a different
    /// directory per invocation, with the previous session apparently lost.
    @Test
    func anEmptySessionDirectoryIsIgnoredAtEveryLayer() throws {
        let home = ["HOME": "/home/tester"]

        let emptyEnv = try resolve(env: home.merging([EnvName.sessionDir: ""]) { _, new in new })
        #expect(emptyEnv.sessionDirectory.string == "/home/tester/.domocode/sessions")

        // The file layers get the same guard, and fall through to the next one.
        let emptyProject = try resolve(
            env: home, project: Settings(sessionDir: ""), user: Settings(sessionDir: "/user/sessions")
        )
        #expect(emptyProject.sessionDirectory.string == "/user/sessions")

        // A real value still wins, or the guard would have eaten the setting.
        let set = try resolve(env: home.merging([EnvName.sessionDir: "/env/sessions"]) { _, new in new })
        #expect(set.sessionDirectory.string == "/env/sessions")
    }

    /// A project `"model": ""` used to beat a user's real model.
    ///
    /// The environment layer had always required a non-empty value; the two file
    /// layers had not, so an empty string in a settings.json won the precedence
    /// contest and produced a request with no model at all.
    @Test
    func anEmptyStringInASettingsFileIsNotASetting() throws {
        let config = try resolve(project: Settings(model: ""), user: Settings(model: "user-model"))
        #expect(config.model == "user-model")
        #expect(config.smallModel == "user-model")

        // The same for every other string knob, checked on one more so this is
        // not a claim about `model` alone.
        let urls = try resolve(project: Settings(baseURL: ""), user: Settings(baseURL: "http://user:4000/v1"))
        #expect(urls.baseURL == "http://user:4000/v1")
    }

    /// A bad number must name the file it is in, not an environment variable the
    /// user never set.
    ///
    /// `"timeoutMs": -1` in a settings.json used to report `DOMOCODE_TIMEOUT_MS
    /// must be non-negative`, which sends the reader to inspect an environment
    /// that is innocent while the offending line goes unmentioned.
    @Test
    func aNumericErrorNamesTheLayerThatSuppliedTheValue() throws {
        let fromProject = #expect(throws: DoMoError.self) {
            try resolve(project: Settings(timeoutMS: -1))
        }
        let projectText = try #require(fromProject?.description)
        #expect(projectText.contains("timeoutMs"))
        #expect(projectText.contains("project settings.json"))
        #expect(!projectText.contains(EnvName.timeoutMS))

        let fromUser = #expect(throws: DoMoError.self) {
            try resolve(user: Settings(maxRetries: -2))
        }
        let userText = try #require(fromUser?.description)
        #expect(userText.contains("maxRetries"))
        #expect(userText.contains("user settings.json"))
        #expect(!userText.contains(EnvName.maxRetries))

        // The environment layer keeps naming the variable, because there the
        // variable *is* the thing to edit.
        let fromEnv = #expect(throws: DoMoError.self) {
            try resolve(env: [EnvName.timeoutMS: "-1"])
        }
        let envText = try #require(fromEnv?.description)
        #expect(envText.contains(EnvName.timeoutMS))
    }

    /// An unparseable `logLevel` used to fall through to the next precedence
    /// layer in complete silence.
    ///
    /// It is still not fatal — nobody should lose a session over a typo in a log
    /// knob — but it is now reported, because the alternative is a user staring
    /// at a level they set and a harness plainly not using it.
    @Test
    func anUnparseableLogLevelIsReportedRatherThanIgnoredInSilence() throws {
        let config = try resolve(user: Settings(logLevel: "verbose"))
        #expect(config.logLevel == .warning)
        let warning = try #require(config.warnings.first)
        #expect(warning.contains("verbose"))
        #expect(warning.contains("user settings.json"))

        // A parseable level warns about nothing.
        #expect(try resolve(user: Settings(logLevel: "debug")).warnings.isEmpty)

        // A bad higher layer is reported *and* the next layer still wins, which
        // is the fall-through that used to happen silently.
        let mixed = try resolve(env: [EnvName.logLevel: "loud"], project: Settings(logLevel: "trace"))
        #expect(mixed.logLevel == .trace)
        #expect(mixed.warnings.contains(where: { $0.contains("loud") && $0.contains(EnvName.logLevel) }))
    }
}
