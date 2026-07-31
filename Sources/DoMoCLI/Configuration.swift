// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
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
    public var sessionDir: String?

    /// The *name* of the environment variable holding the API key. Never the key.
    public var apiKeyEnv: String?

    /// Stdio-local MCP servers, keyed by a namespacing prefix (Phase 8c). Rides
    /// settings.json, so a project's servers are trust-gated by the existing gate.
    public var mcpServers: [String: MCPServerConfig]?

    /// What the operator knows about individual model aliases that the gateway
    /// will not say: context window, prices, and a model-specific reasoning
    /// effort. Keyed by the alias exactly as it is sent on the wire.
    ///
    /// LiteLLM's `/models` answers with names and nothing else, so every number
    /// here is operator-supplied truth. See ``DoMoLLM/ModelOverride`` for the two
    /// authoring shapes it accepts.
    public var modelOverrides: [String: ModelOverride]?

    /// Compaction knobs, each one optional so an absent key can be told from a
    /// stated one when the project and user files are merged.
    public var compaction: CompactionOverrides?

    /// The context window to assume for an alias with no ``modelOverrides``
    /// entry.
    ///
    /// `nil` means *genuinely unknown*, which is a different claim from any
    /// number: a meter renders `?` rather than a percentage of a guess. It is
    /// not defaulted to 200 000 here — that number is compaction's floor, not a
    /// fact about the model.
    public var contextWindow: Int?

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
        sessionDir: String? = nil,
        apiKeyEnv: String? = nil,
        mcpServers: [String: MCPServerConfig]? = nil,
        modelOverrides: [String: ModelOverride]? = nil,
        compaction: CompactionOverrides? = nil,
        contextWindow: Int? = nil
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
        self.sessionDir = sessionDir
        self.apiKeyEnv = apiKeyEnv
        self.mcpServers = mcpServers
        self.modelOverrides = modelOverrides
        self.compaction = compaction
        self.contextWindow = contextWindow
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
        case sessionDir
        case apiKeyEnv
        case mcpServers
        case modelOverrides
        case compaction
        case contextWindow
    }

    /// Loads a settings file: `nil` when it is genuinely absent, a thrown error
    /// for every other way reading or understanding it can fail.
    ///
    /// A missing file is the common case (most users never write one) and must
    /// not be an error. Everything else must be: an **unreadable** file used to
    /// take the same silent `nil` path as an absent one, which meant a
    /// settings.json left at mode 000 — or under a directory the user had lost
    /// access to — simply vanished, taking the model, the gateway URL and the
    /// permission grants with it and reporting nothing. "The file is not there"
    /// — see ``isMissingFile(_:path:)`` for how narrowly that is decided — is now
    /// the only answer that means "no settings here".
    ///
    /// A parse failure throws ``DoMoError/Kind/configuration`` carrying a
    /// ``DoMoCore/ConfigDiagnostic`` as its ``DoMoError/cause``, so
    /// ``DoMoError/description`` ends with the offending source line and a caret
    /// under the offending character.
    ///
    /// - Parameters:
    ///   - path: the file to read.
    ///   - interpolation: the trust policy for `{env:}` / `{file:}` in this
    ///     file's *values* — `.trusted` for the user's own settings,
    ///     `.untrusted(root:)` for a repository's. `nil`, the default, leaves
    ///     every token literal; it exists so a caller that only wants to inspect
    ///     a file (a test, a doctor command) does not have to invent an
    ///     environment.
    ///   - environment: the environment `{env:}` reads, injected so this is not
    ///     at the mercy of the process's own.
    public static func load(
        from path: FilePath,
        interpolation: InterpolationPolicy? = nil,
        environment: [String: String] = [:]
    ) throws(DoMoError) -> Settings? {
        let url = URL(fileURLWithPath: path.string)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isMissingFile(error, path: path.string) { return nil }
            throw DoMoError(
                .file(path: path, errno: posixErrno(error)),
                "Could not read settings file \(path)",
                cause: error
            )
        }

        // The bytes are read once and kept. Re-reading the file to build the
        // excerpt would be a TOCTOU: the caret would be drawn under whatever the
        // file says now, which need not be the bytes that failed to decode.
        let source = Array(data)
        let decoded: Settings
        do {
            decoded = try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw DoMoError(
                .configuration,
                "Could not parse settings file \(path)",
                cause: ConfigDiagnostic(decoding: error, source: source, file: path.string)
            )
        }

        guard let interpolation else { return decoded }
        do {
            // This is the only layer that still knows the file's own path, which
            // is what a relative `{file:}` has to be resolved against.
            let resolved = try decoded.resolvingInterpolations(
                policy: interpolation,
                environment: environment,
                baseDirectory: path.removingLastComponent().string,
                file: path.string
            )
            // Whatever a user kept out of their config file is exactly what must
            // never reach a log line or a diagnostic.
            Redaction.registerAll(resolved.substituted)
            return resolved.settings
        } catch {
            throw DoMoError(
                .configuration, "Could not resolve values in settings file \(path)", cause: error)
        }
    }

    /// String-path convenience, so a caller without `SystemPackage` in scope
    /// (a test, most often) need not construct a `FilePath`.
    public static func load(
        fromPath path: String,
        interpolation: InterpolationPolicy? = nil,
        environment: [String: String] = [:]
    ) throws(DoMoError) -> Settings? {
        try load(from: FilePath(path), interpolation: interpolation, environment: environment)
    }

    /// Whether a read failure means the file is not there, as opposed to there
    /// and unreadable.
    ///
    /// Three sources are consulted because no single one is trustworthy across
    /// both platforms: Foundation's Cocoa code, the POSIX errno it sometimes
    /// carries instead, and — last — the filesystem itself. The filesystem
    /// question is what keeps this correct on Linux, where corelibs-foundation
    /// does not always produce the same domain for the same failure; it is
    /// asked last so that a genuine permission error is never re-answered as
    /// absence by a `fileExists` that also happens to fail.
    private static func isMissingFile(_ error: any Error, path: String) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if let errno = posixErrno(error) {
            return errno == .noSuchFileOrDirectory
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// The POSIX errno behind a Foundation read failure, when there is one, so
    /// ``DoMoError/Kind/file(path:errno:)`` can carry it and the presenter can
    /// say "check file permissions" rather than shrug.
    private static func posixErrno(_ error: any Error) -> Errno? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Errno(rawValue: CInt(truncatingIfNeeded: nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .permissionDenied
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return Errno(rawValue: CInt(truncatingIfNeeded: underlying.code))
        }
        return nil
    }
}

// MARK: - Value interpolation

extension Settings {

    /// This settings value with `{env:NAME}` and `{file:PATH}` resolved in the
    /// string fields that are allowed to carry them.
    ///
    /// ## Why here, and not on the file text
    ///
    /// Substituting into the source bytes before parsing — which is what
    /// opencode does — moves every byte offset after the first token, and every
    /// later ``DoMoCore/ConfigDiagnostic`` in that file would then draw its caret
    /// under the wrong column. Resolving decoded *values* cannot have that bug,
    /// and it also cannot produce the other one: a value containing a quote or a
    /// backslash spliced into JSON text corrupts the document.
    ///
    /// ## What it reaches, and what it deliberately does not
    ///
    /// The list is explicit rather than "every string in the type", because the
    /// interesting cases are the omissions:
    ///
    /// - **The `permission` block is not here at all.** It is not a field of
    ///   ``Settings`` — `PermissionSetup` reads it with its own order-preserving
    ///   parser straight off the file text — and leaving it literal is what stops
    ///   `{env:}` from becoming a permission-widening vector: a rule spelled
    ///   `{env:PATTERN}` stays the uninterpreted string `{env:PATTERN}`, matches
    ///   nothing, and grants nothing.
    /// - **The integer knobs cannot be reached, and this is honest about it.**
    ///   `timeoutMs`, `maxRetries`, `retryBaseMs`, `retryMaxMs`,
    ///   `retryBudgetMs`, `contextWindow` and the numbers inside
    ///   `modelOverrides` decode as `Int`/`Decimal` before anything here could
    ///   run, so `"timeoutMs": "{env:T}"` is a type error at decode time, not an
    ///   interpolation. Supporting it would mean decoding every number as a
    ///   string first, which costs every other diagnostic its type check. It is
    ///   not supported; it is documented.
    /// - **`modelOverrides` and `compaction` are not walked.** They carry
    ///   numbers, an effort level and a model alias — nothing a user has any
    ///   reason to keep in a separate file — and every field added to the
    ///   allowlist is a field an untrusted project config gets to point at a
    ///   file read.
    ///
    /// `mcpServers.*.environment` is the case the feature exists for: it is
    /// overlaid onto a child process's environment, so a server that needs a
    /// token can be configured without the token being written down. Its **keys
    /// stay literal** — a variable name is not a secret, and resolving keys would
    /// let one token silently rename another.
    ///
    /// - Returns: the resolved settings, and every value that was substituted
    ///   into them, for ``DoMoCore/Redaction/registerAll(_:)``.
    /// - Throws: ``DoMoCore/ConfigDiagnostic`` naming the token that failed —
    ///   never the value it would have produced.
    /// Whether a value substituted into this key should be registered as a
    /// secret, so it is masked wherever it is later printed.
    ///
    /// Not every interpolated value is a credential, and treating them as if
    /// they were does real damage. The first cut of this registered *every*
    /// substituted value, and `"baseUrl": "http://{env:MY_GATEWAY_HOST}:4000/v1"`
    /// then registered the hostname — so a later connection failure read
    /// `connect to https://[redacted]@[redacted] failed`, blanking the one fact
    /// the URL-userinfo rule goes out of its way to preserve: which endpoint
    /// refused you. A host a user happened to keep in an environment variable is
    /// not thereby a secret.
    ///
    /// Three things qualify. `authHeader` and `authScheme` are named explicitly
    /// because they hold a credential while matching none of
    /// ``DoMoCore/Redaction/isSecretKeyName(_:)``'s markers. Every
    /// `mcpServers.*.environment` value qualifies regardless of its name, because
    /// that block exists to hand secrets to a child and a name filter would miss
    /// the one a user spelled `GH_PAT` — the same trade
    /// ``DoMoCodeCommand`` makes when it registers those values at startup.
    /// Anything else qualifies only on a secret-shaped name.
    ///
    /// `apiKeyEnv` is deliberately absent: it holds the *name* of a variable,
    /// which is not a secret, and registering it would scrub that name out of
    /// the "which credential did I use?" hint an auth failure most needs.
    static func keyCarriesCredential(_ keyPath: [String]) -> Bool {
        guard let key = keyPath.last else { return false }
        if keyPath.count == 1 { return ["authHeader", "authScheme"].contains(key) }
        if keyPath.count == 4, keyPath[0] == "mcpServers", keyPath[2] == "environment" { return true }
        return Redaction.isSecretKeyName(key)
    }

    public func resolvingInterpolations(
        policy: InterpolationPolicy,
        environment: [String: String],
        baseDirectory: String?,
        file: String?,
        readFile: @Sendable (String) throws -> String = {
            try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
        }
    ) throws(ConfigDiagnostic) -> (settings: Settings, substituted: [String]) {
        var resolved = self
        var substituted: [String] = []

        func apply(_ value: String?, _ keyPath: [String]) throws(ConfigDiagnostic) -> String? {
            guard let value else { return nil }
            let result = try resolveConfigValue(
                value,
                policy: policy,
                environment: environment,
                baseDirectory: baseDirectory,
                keyPath: keyPath,
                file: file,
                readFile: readFile
            )
            if Settings.keyCarriesCredential(keyPath) {
                substituted.append(contentsOf: result.substituted)
            }
            return result.value
        }

        resolved.baseURL = try apply(baseURL, ["baseUrl"])
        resolved.model = try apply(model, ["model"])
        resolved.smallModel = try apply(smallModel, ["smallModel"])
        resolved.authHeader = try apply(authHeader, ["authHeader"])
        resolved.authScheme = try apply(authScheme, ["authScheme"])
        resolved.reasoningEffort = try apply(reasoningEffort, ["reasoningEffort"])
        resolved.logLevel = try apply(logLevel, ["logLevel"])
        resolved.sessionDir = try apply(sessionDir, ["sessionDir"])
        resolved.apiKeyEnv = try apply(apiKeyEnv, ["apiKeyEnv"])

        if let servers = mcpServers {
            var updated: [String: MCPServerConfig] = [:]
            updated.reserveCapacity(servers.count)
            // Sorted, so both the substitution order and — far more importantly —
            // *which* token is reported when two are broken are the same on every
            // run. Dictionary order is not.
            for name in servers.keys.sorted() {
                guard var server = servers[name] else { continue }
                var command: [String] = []
                command.reserveCapacity(server.command.count)
                for (index, argument) in server.command.enumerated() {
                    let path = ["mcpServers", name, "command", String(index)]
                    let resolvedArgument = try apply(argument, path)
                    command.append(resolvedArgument ?? argument)
                }
                server.command = command
                if let variables = server.environment {
                    var resolvedVariables: [String: String] = [:]
                    resolvedVariables.reserveCapacity(variables.count)
                    for key in variables.keys.sorted() {
                        guard let raw = variables[key] else { continue }
                        let path = ["mcpServers", name, "environment", key]
                        let resolvedValue = try apply(raw, path)
                        resolvedVariables[key] = resolvedValue ?? raw
                    }
                    server.environment = resolvedVariables
                }
                server.cwd = try apply(server.cwd, ["mcpServers", name, "cwd"])
                updated[name] = server
            }
            resolved.mcpServers = updated
        }

        return (resolved, substituted)
    }
}

// MARK: - Model runtime

/// Everything one model alias is run with, gathered in one value.
///
/// It exists because the three surfaces that drive a harness — print mode, the
/// inline REPL and the embedded server — each used to assemble these four
/// arguments separately, and had already drifted: `rates` reached one of them
/// and the reasoning effort reached two. A session whose `rates` were dropped
/// reports every turn as free, silently, which is the exact failure this phase
/// exists to end.
///
/// ``contextWindow`` is `Int?` on purpose. `nil` means nobody has said what this
/// model's window is, and a meter must render `?` — never a percentage of the
/// 200 000-token fallback compaction uses, which would be a number the user has
/// no reason to doubt and no way to check.
public struct ModelRuntime: Sendable, Hashable {
    /// The alias sent on the wire.
    public var model: String
    /// The alias's own effort if it stated one, otherwise the global setting.
    public var reasoningEffort: ReasoningEffort?
    /// `nil` leaves cost at zero — the honest answer for a model whose price
    /// nobody stated, and not the same claim as "free".
    public var rates: ModelCostRates?
    /// `nil` = genuinely unknown. See the type's note.
    public var contextWindow: Int?

    public init(
        model: String,
        reasoningEffort: ReasoningEffort? = nil,
        rates: ModelCostRates? = nil,
        contextWindow: Int? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.rates = rates
        self.contextWindow = contextWindow
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
    /// `0` means "no idle bound" — see ``DoMoLLM/AsyncHTTPClientTransport``.
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
    /// The enabled stdio MCP servers, project merged over user (Phase 8c).
    public var mcpServers: [String: MCPServerConfig]

    /// Per-alias overrides, **merged per key with the whole entry replaced**,
    /// project over user. See ``override(for:)`` for why this merge differs from
    /// ``compaction``'s.
    public var modelOverrides: [String: ModelOverride]

    /// Compaction settings, **merged field by field**, project over user, then
    /// applied over ``DoMoHarness/CompactionSettings/default``. See
    /// ``override(for:)``.
    public var compaction: CompactionSettings

    /// The alias to summarize with, if `compaction.model` named one.
    ///
    /// It is separate from ``compaction`` because
    /// ``DoMoHarness/CompactionSettings`` has nowhere to put it: the harness does
    /// not select models, it runs an injected summarizer. Whoever builds that
    /// summarizer reads this.
    public var compactionModel: String?

    /// The global context window for aliases with no ``modelOverrides`` entry.
    /// `nil` = genuinely unknown; see ``ModelRuntime/contextWindow``.
    public var contextWindow: Int?

    /// The *name* of the environment variable the API key was read from, when a
    /// settings file named one. Never the key.
    ///
    /// Carried so the two places that scrub the gateway credential out of a
    /// child process's environment — the MCP launcher and the bash tool — can
    /// union it into their otherwise-hardcoded three-name list. Without it, a
    /// user who names their own variable hands that credential to every MCP
    /// server and to every command the model runs.
    public var apiKeyEnvName: String?

    /// Non-fatal complaints about the configuration, in the order they were
    /// found: a value that could not be understood and was therefore ignored.
    ///
    /// Values, not printed text, so the surface decides where they go. The
    /// alternative — the one this replaces — is falling through to the next
    /// precedence layer in silence, which leaves a user staring at a `logLevel`
    /// they set and a harness that plainly is not using it.
    public var warnings: [String]

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
        mcpServers: [String: MCPServerConfig] = [:],
        modelOverrides: [String: ModelOverride] = [:],
        compaction: CompactionSettings = .default,
        compactionModel: String? = nil,
        contextWindow: Int? = nil,
        apiKeyEnvName: String? = nil,
        warnings: [String] = []
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
        self.mcpServers = mcpServers
        self.modelOverrides = modelOverrides
        self.compaction = compaction
        self.compactionModel = compactionModel
        self.contextWindow = contextWindow
        self.apiKeyEnvName = apiKeyEnvName
        self.warnings = warnings
    }

    // MARK: Per-model truth

    /// What the operator said about one alias, or `nil` if they said nothing.
    ///
    /// The lookup is **exact**: the key is the alias as it is sent on the wire.
    /// No prefix stripping, no case folding — a gateway is free to serve
    /// `openai/gpt-5` and `gpt-5` as two different models with two different
    /// prices, and guessing that they are the same one would bill a session at
    /// the wrong rate without ever saying so.
    ///
    /// ## The two merges, and why they differ
    ///
    /// ``modelOverrides`` merges **per key, whole entry replaced**: a project's
    /// `"gpt-5"` entry supersedes the user's `"gpt-5"` entry outright, and the
    /// user's other aliases survive untouched. This follows `mcpServers`, and it
    /// is right because an override is a *description of one model* — half the
    /// project's prices layered over half the user's produces a price table that
    /// neither of them wrote.
    ///
    /// ``compaction`` merges **field by field**: a project that only tunes
    /// `keepRecentTokens` keeps the user's `enabled` and `model`. This follows
    /// every other numeric knob in this file, and it is right for the same
    /// reason inverted — these are independent dials on one behaviour, not a
    /// description of one thing.
    public func override(for model: String) -> ModelOverride? {
        modelOverrides[model]
    }

    /// The four things a run needs to know about an alias, resolved.
    ///
    /// Precedence for the effort is the only interesting part: an alias-level
    /// `reasoningEffort` **beats** the global `DOMOCODE_REASONING_EFFORT` or
    /// `settings.reasoningEffort`, because it is the more specific statement.
    /// The global one is the fallback, not the override.
    ///
    /// ``ModelRuntime/contextWindow`` stays `nil` when neither the alias nor the
    /// global setting states one. ``defaultContextWindow`` is deliberately *not*
    /// substituted here: it is compaction's floor, and returning it would turn
    /// "unknown" into a number a meter would render as a confident percentage.
    public func modelRuntime(for alias: String) -> ModelRuntime {
        let specific = override(for: alias)
        return ModelRuntime(
            model: alias,
            reasoningEffort: specific?.reasoningEffort ?? reasoningEffort,
            rates: specific?.rates,
            contextWindow: specific?.contextWindow ?? contextWindow
        )
    }

    // MARK: Defaults

    public static let defaultBaseURL = "http://localhost:4000/v1"
    public static let defaultAuthHeaderName = "Authorization"
    public static let defaultAuthScheme = "Bearer"
    public static let defaultTimeout = Duration.milliseconds(600_000)

    /// How long a committed stream may deliver nothing before the turn is failed.
    ///
    /// This deliberately equals ``DoMoLLM/AsyncHTTPClientTransport/defaultIdleTimeout``.
    /// The value used to be 30s, which was harmless only because nothing read
    /// it; the moment it reached the transport, that default would have quartered
    /// every user's silence tolerance without anyone asking for it. A model can
    /// legitimately go quiet for a long reasoning block behind a proxy that does
    /// not forward keepalives, and a false positive there costs a whole turn —
    /// a 2xx has already committed the stream, so exceeding this fails the turn
    /// rather than retrying it.
    public static let defaultStreamTimeout = AsyncHTTPClientTransport.defaultIdleTimeout
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

    /// The window to assume when nothing knows the real one.
    ///
    /// It is **not** a fact about any model and is never reported as one — see
    /// ``modelRuntime(for:)``. It exists so that a session against an unknown
    /// model still compacts, rather than growing until the provider rejects the
    /// turn. Must equal `AgentHarness.Configuration.fallbackContextWindow`,
    /// which is the value the harness actually compacts against; two different
    /// numbers would mean the CLI and the harness disagree about when a session
    /// is full.
    public static let defaultContextWindow = 200_000

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
            timeout: timeout,
            streamIdleTimeout: streamTimeout
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
        //
        // Every layer requires a non-empty value, including the two file layers.
        // They used not to, and the asymmetry was a real bug: `"model": ""` in a
        // project settings.json beat a user's real model and produced a request
        // with no model at all, while the same empty string exported as
        // `DOMOCODE_MODEL` was correctly ignored. An empty string is how a
        // settings file spells "I wrote this key and then deleted the value";
        // it is never a setting.
        func string(cli cliValue: String?, env envName: String, _ keyPath: KeyPath<Settings, String?>) -> String? {
            if let cliValue, !cliValue.isEmpty { return cliValue }
            if let value = environment[envName], !value.isEmpty { return value }
            if let value = project?[keyPath: keyPath], !value.isEmpty { return value }
            if let value = user?[keyPath: keyPath], !value.isEmpty { return value }
            return nil
        }

        var warnings: [String] = []

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

        // Zero here is the default, not a literal zero deadline. This bound is
        // time-to-response-head, so a literal zero fails every attempt in about a
        // second against a perfectly healthy gateway — and it is also what the
        // stream knob's "disabled" case falls back to, so a zero would silently
        // re-tighten the very bound the operator switched off. Unlike that knob
        // there is no "no deadline" to express: AsyncHTTPClient requires one.
        let timeoutRaw = try durationMS(
            environment[EnvName.timeoutMS], project: project?.timeoutMS, user: user?.timeoutMS,
            envName: EnvName.timeoutMS, key: "timeoutMs", default: defaultTimeout
        )
        let timeout = timeoutRaw == .zero ? defaultTimeout : timeoutRaw
        // Zero is carried through verbatim and means "no idle bound", matching
        // `DOMOCODE_RETRY_BUDGET_MS` above. It is NOT mapped to nil here: nil
        // already means "the caller expressed no preference, use the transport
        // default", and collapsing the two would turn an explicit 0 back into
        // the 120s default — the opposite of what an operator typing 0 asked
        // for. The sentinel is interpreted once, at the transport.
        let streamTimeout = try durationMS(
            environment[EnvName.streamTimeoutMS],
            project: project?.streamTimeoutMS, user: user?.streamTimeoutMS,
            envName: EnvName.streamTimeoutMS, key: "streamTimeoutMs",
            default: defaultStreamTimeout
        )
        let maxRetries = try retries(
            environment[EnvName.maxRetries], project: project?.maxRetries, user: user?.maxRetries
        )
        let retryBaseDelay = try durationMS(
            environment[EnvName.retryBaseMS],
            project: project?.retryBaseMS, user: user?.retryBaseMS,
            envName: EnvName.retryBaseMS, key: "retryBaseMs", default: defaultRetryBaseDelay
        )
        let retryMaxDelay = try durationMS(
            environment[EnvName.retryMaxMS],
            project: project?.retryMaxMS, user: user?.retryMaxMS,
            envName: EnvName.retryMaxMS, key: "retryMaxMs", default: defaultRetryMaxDelay
        )
        // A budget of zero is "no budget", not "never sleep": a zero ceiling
        // would make every computed delay overshoot it and silently disable
        // retrying altogether, which is not what an operator typing 0 means.
        let retryBudget = try durationMS(
            environment[EnvName.retryBudgetMS],
            project: project?.retryBudgetMS, user: user?.retryBudgetMS,
            envName: EnvName.retryBudgetMS, key: "retryBudgetMs",
            default: defaultRetryDelayBudget ?? .zero
        )
        let retryDelayBudget: Duration? = retryBudget == .zero ? nil : retryBudget

        // An unparseable level is reported and then skipped, rather than being
        // fatal (nobody should lose a session over a typo in a log knob) and
        // rather than being silent (which is what it used to be: the value fell
        // through to the next layer with nothing said, so a user who wrote
        // `"logLevel": "verbose"` got warnings forever and no clue why).
        func level(_ raw: String?, _ source: String) -> Logger.Level? {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if let parsed = Logger.Level(caseInsensitive: raw) { return parsed }
            warnings.append("\(source) is not a log level (got \"\(raw)\"); ignoring it")
            return nil
        }
        let logLevel =
            level(environment[EnvName.logLevel], EnvName.logLevel)
            ?? level(project?.logLevel, "logLevel in the project settings.json")
            ?? level(user?.logLevel, "logLevel in the user settings.json")
            ?? defaultLogLevel

        let configDirectory = resolveConfigDirectory(environment: environment)
        // Each layer must be non-empty to count, the same guard
        // `resolveConfigDirectory` has always had. Without it,
        // `DOMOCODE_SESSION_DIR=""` — which is how a shell spells an unset
        // variable it still exports — produced `FilePath("")`, and every session
        // was then written relative to the process's working directory instead
        // of under the config directory.
        let sessionDirectory =
            nonEmptyPath(environment[EnvName.sessionDir])
            ?? nonEmptyPath(project?.sessionDir)
            ?? nonEmptyPath(user?.sessionDir)
            ?? configDirectory.appending("sessions")

        let apiKeyEnvName = nonEmpty(project?.apiKeyEnv) ?? nonEmpty(user?.apiKeyEnv)
        let apiKey = resolveAPIKey(environment: environment, apiKeyEnvName: apiKeyEnvName)

        // MCP servers: project merged over user (project wins on a key collision,
        // matching every other setting), then disabled entries dropped so the build
        // sites never spawn them.
        let mergedMCP = (user?.mcpServers ?? [:]).merging(project?.mcpServers ?? [:]) { _, projectValue in projectValue }
        let mcpServers = mergedMCP.filter { $0.value.enabled != false }

        // Whole entry replaced per key — see `override(for:)` for why this and
        // `compaction` below merge differently on purpose.
        let modelOverrides = (user?.modelOverrides ?? [:])
            .merging(project?.modelOverrides ?? [:]) { _, projectValue in projectValue }

        // Field by field, project over user.
        let compactionOverrides = (project?.compaction ?? CompactionOverrides())
            .merged(over: user?.compaction ?? CompactionOverrides())

        let contextWindow = try positiveTokens(
            project: project?.contextWindow, user: user?.contextWindow, key: "contextWindow"
        )

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
            mcpServers: mcpServers,
            modelOverrides: modelOverrides,
            compaction: compactionOverrides.applied(to: .default),
            compactionModel: nonEmpty(compactionOverrides.model),
            contextWindow: contextWindow,
            apiKeyEnvName: apiKeyEnvName,
            warnings: warnings
        )
    }

    /// `nil` for an absent *or* empty string, so the two spellings of "not set"
    /// are one value everywhere below.
    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func nonEmptyPath(_ value: String?) -> FilePath? {
        nonEmpty(value).map(FilePath.init(_:))
    }

    /// Loads the two settings files off disk and resolves. The project file is
    /// `<cwd>/.domocode/settings.json`; the user file is
    /// `<configDir>/settings.json`.
    ///
    /// The two are read under **different interpolation policies**, and that is
    /// the whole trust model: the user's own file may read the environment and
    /// any file it likes; a repository's file — which arrives with whatever was
    /// cloned — may read no environment variable at all and no file outside the
    /// working directory.
    public static func load(
        cli: CLIOverrides,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: FilePath = FilePath(FileManager.default.currentDirectoryPath)
    ) throws(DoMoError) -> ResolvedConfiguration {
        let configDirectory = resolveConfigDirectory(environment: environment)
        let projectPath = workingDirectory.appending(".domocode").appending("settings.json")
        let userPath = configDirectory.appending("settings.json")

        let project = try Settings.load(
            from: projectPath,
            interpolation: .untrusted(root: workingDirectory.string),
            environment: environment
        )
        let user = try Settings.load(
            from: userPath,
            interpolation: .trusted,
            environment: environment
        )
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

    /// How a numeric setting should be named back to the user when it is wrong.
    ///
    /// This exists because the message used to name the environment variable
    /// whatever the source was: `"timeoutMs": -1` in a settings.json reported
    /// `DOMOCODE_TIMEOUT_MS must be non-negative`, sending the user to inspect an
    /// environment variable they had never set while the actual offending line
    /// sat unmentioned in a file. An error has to name the thing that has to be
    /// edited.
    private enum NumericSource {
        case environment(String)
        case project(String)
        case user(String)

        var described: String {
            switch self {
            case .environment(let name): return name
            case .project(let key): return "\"\(key)\" in the project settings.json"
            case .user(let key): return "\"\(key)\" in the user settings.json"
            }
        }
    }

    /// The first layer that states a millisecond value, validated and named.
    ///
    /// `project` and `user` are taken separately rather than pre-collapsed with
    /// `??`, because collapsing them throws away the one fact the error message
    /// needs.
    private static func durationMS(
        _ envValue: String?,
        project projectValue: Int?,
        user userValue: Int?,
        envName: String,
        key: String,
        default fallback: Duration
    ) throws(DoMoError) -> Duration {
        if let raw = envValue, !raw.isEmpty {
            guard let ms = Int(raw), ms >= 0 else {
                throw DoMoError(
                    .configuration,
                    "\(NumericSource.environment(envName).described) must be a non-negative integer (got \"\(raw)\")"
                )
            }
            return .milliseconds(ms)
        }
        if let ms = projectValue {
            return .milliseconds(try nonNegative(ms, .project(key)))
        }
        if let ms = userValue {
            return .milliseconds(try nonNegative(ms, .user(key)))
        }
        return fallback
    }

    private static func retries(
        _ envValue: String?,
        project projectValue: Int?,
        user userValue: Int?
    ) throws(DoMoError) -> Int {
        if let raw = envValue, !raw.isEmpty {
            guard let count = Int(raw), count >= 0 else {
                throw DoMoError(
                    .configuration,
                    "\(NumericSource.environment(EnvName.maxRetries).described) must be a non-negative integer (got \"\(raw)\")"
                )
            }
            return count
        }
        if let count = projectValue { return try nonNegative(count, .project("maxRetries")) }
        if let count = userValue { return try nonNegative(count, .user("maxRetries")) }
        return defaultMaxRetries
    }

    private static func nonNegative(_ value: Int, _ source: NumericSource) throws(DoMoError) -> Int {
        guard value >= 0 else {
            throw DoMoError(.configuration, "\(source.described) must be non-negative (got \(value))")
        }
        return value
    }

    /// A token count that must be a real count if it is stated at all.
    ///
    /// Zero is rejected alongside a negative: a window of zero is not "small",
    /// it is a claim that no message fits, and compaction would loop against it.
    /// `nil` — nobody said — stays `nil`, which is a different and honest answer.
    private static func positiveTokens(
        project projectValue: Int?,
        user userValue: Int?,
        key: String
    ) throws(DoMoError) -> Int? {
        func check(_ value: Int, _ source: NumericSource) throws(DoMoError) -> Int {
            guard value > 0 else {
                throw DoMoError(
                    .configuration, "\(source.described) must be greater than zero (got \(value))")
            }
            return value
        }
        if let value = projectValue { return try check(value, .project(key)) }
        if let value = userValue { return try check(value, .user(key)) }
        return nil
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
