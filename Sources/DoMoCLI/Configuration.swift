// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM
import DoMoMCP
import Foundation
import Logging
import SystemPackage

// MARK: - Environment variable names

/// The `DOMOCODE_*` environment variables, spelled exactly as the README's
/// Configuration table documents them. Centralized so the names are declared
/// once and cannot drift between the resolver and its tests.
public enum EnvName {
    public static let baseURL = "DOMOCODE_BASE_URL"
    public static let apiKey = "DOMOCODE_API_KEY"
    public static let authHeader = "DOMOCODE_AUTH_HEADER"
    public static let authScheme = "DOMOCODE_AUTH_SCHEME"
    public static let model = "DOMOCODE_MODEL"
    public static let smallModel = "DOMOCODE_SMALL_MODEL"
    public static let reasoningEffort = "DOMOCODE_REASONING_EFFORT"
    public static let timeoutMS = "DOMOCODE_TIMEOUT_MS"
    public static let streamTimeoutMS = "DOMOCODE_STREAM_TIMEOUT_MS"
    public static let maxRetries = "DOMOCODE_MAX_RETRIES"
    public static let retryBaseMS = "DOMOCODE_RETRY_BASE_MS"
    public static let retryMaxMS = "DOMOCODE_RETRY_MAX_MS"
    public static let retryBudgetMS = "DOMOCODE_RETRY_BUDGET_MS"
    public static let configDir = "DOMOCODE_CONFIG_DIR"
    public static let sessionDir = "DOMOCODE_SESSION_DIR"
    public static let logLevel = "DOMOCODE_LOG_LEVEL"
    public static let offline = "DOMOCODE_OFFLINE"

    /// The secret-key fallback chain. `DOMOCODE_API_KEY` first, then the two
    /// names other tools already set, so an existing LiteLLM or OpenAI
    /// environment works with no extra configuration.
    public static let apiKeyFallbacks = [apiKey, "LITELLM_API_KEY", "OPENAI_API_KEY"]
}

// MARK: - Settings file

/// A `settings.json` file, every field optional.
///
/// This is the persisted, *non-secret* layer of configuration. It deliberately
/// has no field that holds an API key: a secret in a world-readable JSON file is
/// the mistake this omission prevents. ``apiKeyEnv`` names the environment
/// variable to read instead — the name is not a secret, the value never touches
/// disk.
public struct Settings: Sendable, Hashable, Codable {
    public var baseURL: String?
    public var model: String?
    public var smallModel: String?
    public var authHeader: String?
    public var authScheme: String?
    public var reasoningEffort: String?
    public var timeoutMS: Int?
    public var streamTimeoutMS: Int?
    public var maxRetries: Int?
    public var retryBaseMS: Int?
    public var retryMaxMS: Int?
    public var retryBudgetMS: Int?
    public var logLevel: String?
    public var offline: Bool?
    public var sessionDir: String?

    /// The *name* of the environment variable holding the API key. Never the key.
    public var apiKeyEnv: String?

    /// Stdio-local MCP servers, keyed by a namespacing prefix (Phase 8c). Rides
    /// settings.json, so a project's servers are trust-gated by the existing gate.
    public var mcpServers: [String: MCPServerConfig]?

    public init(
        baseURL: String? = nil,
        model: String? = nil,
        smallModel: String? = nil,
        authHeader: String? = nil,
        authScheme: String? = nil,
        reasoningEffort: String? = nil,
        timeoutMS: Int? = nil,
        streamTimeoutMS: Int? = nil,
        maxRetries: Int? = nil,
        retryBaseMS: Int? = nil,
        retryMaxMS: Int? = nil,
        retryBudgetMS: Int? = nil,
        logLevel: String? = nil,
        offline: Bool? = nil,
        sessionDir: String? = nil,
        apiKeyEnv: String? = nil,
        mcpServers: [String: MCPServerConfig]? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.smallModel = smallModel
        self.authHeader = authHeader
        self.authScheme = authScheme
        self.reasoningEffort = reasoningEffort
        self.timeoutMS = timeoutMS
        self.streamTimeoutMS = streamTimeoutMS
        self.maxRetries = maxRetries
        self.retryBaseMS = retryBaseMS
        self.retryMaxMS = retryMaxMS
        self.retryBudgetMS = retryBudgetMS
        self.logLevel = logLevel
        self.offline = offline
        self.sessionDir = sessionDir
        self.apiKeyEnv = apiKeyEnv
        self.mcpServers = mcpServers
    }

    public enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case model
        case smallModel
        case authHeader
        case authScheme
        case reasoningEffort
        case timeoutMS = "timeoutMs"
        case streamTimeoutMS = "streamTimeoutMs"
        case maxRetries
        case retryBaseMS = "retryBaseMs"
        case retryMaxMS = "retryMaxMs"
        case retryBudgetMS = "retryBudgetMs"
        case logLevel
        case offline
        case sessionDir
        case apiKeyEnv
        case mcpServers
    }

    /// Loads a settings file, returning `nil` when it is absent and throwing
    /// ``DoMoError/Kind/configuration`` only when it exists but cannot be parsed.
    ///
    /// A missing file is the common case (most users never write one) and must
    /// not be an error; a malformed file is a mistake the user should be told
    /// about rather than have silently ignored.
    public static func load(from path: FilePath) throws(DoMoError) -> Settings? {
        let url = URL(fileURLWithPath: path.string)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Absent (or unreadable) → treat as "no settings here".
            return nil
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw DoMoError(.configuration, "Could not parse settings file \(path)", cause: error)
        }
    }

    /// String-path convenience, so a caller without `SystemPackage` in scope
    /// (a test, most often) need not construct a `FilePath`.
    public static func load(fromPath path: String) throws(DoMoError) -> Settings? {
        try load(from: FilePath(path))
    }
}

// MARK: - CLI overrides

/// The subset of settings a command-line flag can override. Highest precedence.
public struct CLIOverrides: Sendable, Hashable {
    public var baseURL: String?
    public var model: String?

    public init(baseURL: String? = nil, model: String? = nil) {
        self.baseURL = baseURL
        self.model = model
    }
}

// MARK: - Resolved configuration

/// The fully-resolved settings one run operates under.
///
/// Every value here is already the winner of the precedence contest — CLI flag,
/// then environment variable, then project `settings.json`, then user
/// `settings.json`, then built-in default. Nothing downstream re-reads the
/// environment or a file; this struct is the single source of truth so the
/// precedence rule lives in exactly one place (``resolve(cli:environment:project:user:)``).
public struct ResolvedConfiguration: Sendable {
    public var baseURL: String
    /// `nil` when no key was found in the environment. A local unsecured proxy
    /// accepts an unauthenticated request, so a missing key is not fatal here.
    public var apiKey: String?
    public var authHeaderName: String
    public var authScheme: String
    public var model: String?
    public var smallModel: String?
    public var reasoningEffort: ReasoningEffort?
    public var timeout: Duration
    public var streamTimeout: Duration
    public var maxRetries: Int
    /// First retry backoff; each further attempt doubles it before jitter.
    public var retryBaseDelay: Duration
    /// Backoff ceiling, which also caps a server-supplied `Retry-After`.
    public var retryMaxDelay: Duration
    /// Total time one request may spend asleep between retries. `nil` disables
    /// the budget; `DOMOCODE_RETRY_BUDGET_MS=0` is how an operator spells that.
    public var retryDelayBudget: Duration?
    public var configDirectory: FilePath
    public var sessionDirectory: FilePath
    public var logLevel: Logger.Level
    public var offline: Bool
    /// The enabled stdio MCP servers, project merged over user (Phase 8c).
    public var mcpServers: [String: MCPServerConfig]

    public init(
        baseURL: String,
        apiKey: String?,
        authHeaderName: String,
        authScheme: String,
        model: String?,
        smallModel: String?,
        reasoningEffort: ReasoningEffort?,
        timeout: Duration,
        streamTimeout: Duration,
        maxRetries: Int,
        retryBaseDelay: Duration = ResolvedConfiguration.defaultRetryBaseDelay,
        retryMaxDelay: Duration = ResolvedConfiguration.defaultRetryMaxDelay,
        retryDelayBudget: Duration? = ResolvedConfiguration.defaultRetryDelayBudget,
        configDirectory: FilePath,
        sessionDirectory: FilePath,
        logLevel: Logger.Level,
        offline: Bool,
        mcpServers: [String: MCPServerConfig] = [:]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authHeaderName = authHeaderName
        self.authScheme = authScheme
        self.model = model
        self.smallModel = smallModel
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
        self.streamTimeout = streamTimeout
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.retryMaxDelay = retryMaxDelay
        self.retryDelayBudget = retryDelayBudget
        self.configDirectory = configDirectory
        self.sessionDirectory = sessionDirectory
        self.logLevel = logLevel
        self.offline = offline
        self.mcpServers = mcpServers
    }

    // MARK: Defaults

    public static let defaultBaseURL = "http://localhost:4000/v1"
    public static let defaultAuthHeaderName = "Authorization"
    public static let defaultAuthScheme = "Bearer"
    public static let defaultTimeout = Duration.milliseconds(600_000)
    public static let defaultStreamTimeout = Duration.milliseconds(30_000)
    /// Ten, not three. A busy or overloaded provider is the one failure that
    /// reliably clears on its own, and giving up after three attempts turns a
    /// provider's bad ninety seconds into a failed turn the user has to retype.
    /// The schedule is exponential from ``defaultRetryBaseDelay``, capped at
    /// ``defaultRetryMaxDelay`` and half-jittered, with
    /// ``defaultRetryDelayBudget`` as the total-sleep ceiling; a failure before
    /// the gateway ever answered keeps its own far smaller budget
    /// (``DoMoLLM/LiteLLMClient/Configuration/maxPreConnectRetries``).
    public static let defaultMaxRetries = 10
    public static let defaultRetryBaseDelay = Duration.seconds(1)
    public static let defaultRetryMaxDelay = Duration.seconds(60)
    public static let defaultRetryDelayBudget: Duration? = .seconds(300)
    public static let defaultLogLevel = Logger.Level.warning

    /// The `LiteLLMClient` configuration this resolves to. The one place the CLI
    /// hands its resolved settings to the wire client.
    public var clientConfiguration: LiteLLMClient.Configuration {
        LiteLLMClient.Configuration(
            baseURL: baseURL,
            apiKey: apiKey,
            authHeaderName: authHeaderName,
            authScheme: authScheme,
            maxRetries: maxRetries,
            baseRetryDelay: retryBaseDelay,
            maxRetryDelay: retryMaxDelay,
            retryDelayBudget: retryDelayBudget,
            timeout: timeout
        )
    }
}

// MARK: - Resolution

extension ResolvedConfiguration {

    /// Resolves configuration from the four layers, honoring the README's
    /// precedence: CLI flag → environment → project settings → user settings →
    /// default.
    ///
    /// `project` and `user` are already-loaded settings so this function stays
    /// pure and unit-testable; ``load(cli:environment:workingDirectory:)`` is the
    /// impure wrapper that reads them off disk.
    public static func resolve(
        cli: CLIOverrides,
        environment: [String: String],
        project: Settings?,
        user: Settings?
    ) throws(DoMoError) -> ResolvedConfiguration {
        // Highest-precedence-first lookup for a string-valued setting.
        func string(cli cliValue: String?, env envName: String, _ keyPath: KeyPath<Settings, String?>) -> String? {
            if let cliValue { return cliValue }
            if let value = environment[envName], !value.isEmpty { return value }
            if let value = project?[keyPath: keyPath] { return value }
            if let value = user?[keyPath: keyPath] { return value }
            return nil
        }

        let baseURL =
            string(cli: cli.baseURL, env: EnvName.baseURL, \.baseURL) ?? defaultBaseURL
        let authHeaderName =
            string(cli: nil, env: EnvName.authHeader, \.authHeader) ?? defaultAuthHeaderName
        let authScheme =
            string(cli: nil, env: EnvName.authScheme, \.authScheme) ?? defaultAuthScheme
        let model = string(cli: cli.model, env: EnvName.model, \.model)
        let smallModel =
            string(cli: nil, env: EnvName.smallModel, \.smallModel) ?? model
        let reasoningEffort =
            string(cli: nil, env: EnvName.reasoningEffort, \.reasoningEffort)
            .map(ReasoningEffort.init(rawValue:))

        let timeout = try durationMS(
            environment[EnvName.timeoutMS], project?.timeoutMS ?? user?.timeoutMS,
            name: EnvName.timeoutMS, default: defaultTimeout
        )
        let streamTimeout = try durationMS(
            environment[EnvName.streamTimeoutMS], project?.streamTimeoutMS ?? user?.streamTimeoutMS,
            name: EnvName.streamTimeoutMS, default: defaultStreamTimeout
        )
        let maxRetries = try retries(
            environment[EnvName.maxRetries], project?.maxRetries ?? user?.maxRetries
        )
        let retryBaseDelay = try durationMS(
            environment[EnvName.retryBaseMS], project?.retryBaseMS ?? user?.retryBaseMS,
            name: EnvName.retryBaseMS, default: defaultRetryBaseDelay
        )
        let retryMaxDelay = try durationMS(
            environment[EnvName.retryMaxMS], project?.retryMaxMS ?? user?.retryMaxMS,
            name: EnvName.retryMaxMS, default: defaultRetryMaxDelay
        )
        // A budget of zero is "no budget", not "never sleep": a zero ceiling
        // would make every computed delay overshoot it and silently disable
        // retrying altogether, which is not what an operator typing 0 means.
        let retryBudget = try durationMS(
            environment[EnvName.retryBudgetMS], project?.retryBudgetMS ?? user?.retryBudgetMS,
            name: EnvName.retryBudgetMS, default: defaultRetryDelayBudget ?? .zero
        )
        let retryDelayBudget: Duration? = retryBudget == .zero ? nil : retryBudget

        let logLevel =
            (environment[EnvName.logLevel].flatMap(Logger.Level.init(caseInsensitive:)))
            ?? (project?.logLevel).flatMap(Logger.Level.init(caseInsensitive:))
            ?? (user?.logLevel).flatMap(Logger.Level.init(caseInsensitive:))
            ?? defaultLogLevel

        let offline =
            environment[EnvName.offline].map(boolFromFlag)
            ?? project?.offline ?? user?.offline ?? false

        let configDirectory = resolveConfigDirectory(environment: environment)
        let sessionDirectory =
            (environment[EnvName.sessionDir]).map(FilePath.init(_:))
            ?? (project?.sessionDir).map(FilePath.init(_:))
            ?? (user?.sessionDir).map(FilePath.init(_:))
            ?? configDirectory.appending("sessions")

        let apiKey = resolveAPIKey(
            environment: environment,
            apiKeyEnvName: project?.apiKeyEnv ?? user?.apiKeyEnv
        )

        // MCP servers: project merged over user (project wins on a key collision,
        // matching every other setting), then disabled entries dropped so the build
        // sites never spawn them.
        let mergedMCP = (user?.mcpServers ?? [:]).merging(project?.mcpServers ?? [:]) { _, projectValue in projectValue }
        let mcpServers = mergedMCP.filter { $0.value.enabled != false }

        return ResolvedConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            authHeaderName: authHeaderName,
            authScheme: authScheme,
            model: model,
            smallModel: smallModel,
            reasoningEffort: reasoningEffort,
            timeout: timeout,
            streamTimeout: streamTimeout,
            maxRetries: maxRetries,
            retryBaseDelay: retryBaseDelay,
            retryMaxDelay: retryMaxDelay,
            retryDelayBudget: retryDelayBudget,
            configDirectory: configDirectory,
            sessionDirectory: sessionDirectory,
            logLevel: logLevel,
            offline: offline,
            mcpServers: mcpServers
        )
    }

    /// Loads the two settings files off disk and resolves. The project file is
    /// `<cwd>/.domocode/settings.json`; the user file is
    /// `<configDir>/settings.json`.
    public static func load(
        cli: CLIOverrides,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: FilePath = FilePath(FileManager.default.currentDirectoryPath)
    ) throws(DoMoError) -> ResolvedConfiguration {
        let configDirectory = resolveConfigDirectory(environment: environment)
        let projectPath = workingDirectory.appending(".domocode").appending("settings.json")
        let userPath = configDirectory.appending("settings.json")

        let project = try Settings.load(from: projectPath)
        let user = try Settings.load(from: userPath)
        return try resolve(cli: cli, environment: environment, project: project, user: user)
    }

    // MARK: Field parsers

    /// The config directory, from `DOMOCODE_CONFIG_DIR` or `~/.domocode`. Not
    /// itself sourced from a settings file: it is *where* the user settings file
    /// lives, so reading it from there would be circular.
    static func resolveConfigDirectory(environment: [String: String]) -> FilePath {
        if let dir = environment[EnvName.configDir], !dir.isEmpty {
            return FilePath(dir)
        }
        let home = environment["HOME"].map(FilePath.init(_:)) ?? FilePath(NSHomeDirectory())
        return home.appending(".domocode")
    }

    /// Resolves the API key from the environment only. When a settings file named
    /// an environment variable, that name wins; otherwise the standard fallback
    /// chain is tried. The value is never read from a settings file.
    static func resolveAPIKey(environment: [String: String], apiKeyEnvName: String?) -> String? {
        if let name = apiKeyEnvName, !name.isEmpty {
            if let value = environment[name], !value.isEmpty { return value }
            // A named-but-unset variable falls through to the defaults rather than
            // forcing an unauthenticated request the user did not intend.
        }
        for name in EnvName.apiKeyFallbacks {
            if let value = environment[name], !value.isEmpty { return value }
        }
        return nil
    }

    private static func durationMS(
        _ envValue: String?,
        _ settingsValue: Int?,
        name: String,
        default fallback: Duration
    ) throws(DoMoError) -> Duration {
        if let raw = envValue, !raw.isEmpty {
            guard let ms = Int(raw), ms >= 0 else {
                throw DoMoError(.configuration, "\(name) must be a non-negative integer (got \"\(raw)\")")
            }
            return .milliseconds(ms)
        }
        if let ms = settingsValue {
            guard ms >= 0 else {
                throw DoMoError(.configuration, "\(name) must be non-negative (got \(ms))")
            }
            return .milliseconds(ms)
        }
        return fallback
    }

    private static func retries(_ envValue: String?, _ settingsValue: Int?) throws(DoMoError) -> Int {
        if let raw = envValue, !raw.isEmpty {
            guard let count = Int(raw), count >= 0 else {
                throw DoMoError(.configuration, "\(EnvName.maxRetries) must be a non-negative integer (got \"\(raw)\")")
            }
            return count
        }
        if let count = settingsValue {
            guard count >= 0 else {
                throw DoMoError(.configuration, "\(EnvName.maxRetries) must be non-negative (got \(count))")
            }
            return count
        }
        return defaultMaxRetries
    }

    /// `1`/`true`/`yes`/`on` (case-insensitive) is true; everything else false.
    /// Matches the loose truthiness a shell-set `DOMOCODE_OFFLINE=1` implies.
    private static func boolFromFlag(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}

// MARK: - Log level parsing

extension Logger.Level {
    /// Parses a log level by name, case-insensitively, so `DOMOCODE_LOG_LEVEL=WARNING`
    /// works as well as `warning`. Returns `nil` for an unrecognized value rather
    /// than defaulting silently, so the caller decides the fallback.
    public init?(caseInsensitive raw: String) {
        self.init(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
