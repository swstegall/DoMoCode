// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// The one place a credential is turned back into text nobody can use.
///
/// LiteLLM's 401 body echoes the API key it was handed. That body becomes an
/// `AssistantMessage.errorMessage`, and every assistant message is appended to
/// the session JSONL — so without this type a single mistyped key is written to
/// disk in plaintext and stays there for the life of the session file.
/// Diagnostics, notices and header dumps are the other edges where a secret
/// escapes into text a human, or a pasted bug report, can read.
///
/// Two mechanisms, applied in that order:
///
/// 1. A **literal registry**. Whoever resolved a secret — the env layer, config
///    interpolation — hands the resolved value here, and every later occurrence
///    of that exact string is replaced. This is the only mechanism that can be
///    exact, so it runs first.
/// 2. **Pattern rules** for the secrets nobody registered: a key the *user*
///    pasted into a prompt, a `Set-Cookie` from a proxy, a token quoted back by
///    an upstream error.
///
/// There is deliberately **no entropy heuristic**. Base64 image data, git SHAs,
/// UUIDv7 ids and minified JavaScript all read as "high entropy", and a
/// redactor that eats them makes every diagnostic useless while proving
/// nothing.
///
/// Scope is equally deliberate. This touches error messages, notices, headers
/// and display edges only. It must never touch prompt text, assistant text or
/// reasoning, tool arguments or tool output: persisted message content is
/// replayed verbatim into the next request, so redacting it would corrupt the
/// conversation on resume.
public final class RedactionVault: Sendable {

    /// Registered secrets, longest first — see ``register(_:)`` for why order
    /// is part of the contract rather than an accident of insertion.
    private let literals = Mutex<[String]>([])

    public init() {}

    /// The vault every module reaches through ``Redaction``.
    ///
    /// A process-wide registry is the point: the code that *resolves* a key
    /// (config load) and the code that *prints* a failure (the stream error
    /// path) are in different modules and never meet.
    public static let shared = RedactionVault()

    /// The shortest string this will accept as a secret.
    ///
    /// Below this a "secret" is far more likely to be a word that also occurs
    /// in the diagnostic — `dev`, `test`, `key` — and replacing every instance
    /// of it would shred the message a human needs to read.
    private static let minimumSecretLength = 8

    /// Remembers a secret so every later occurrence of it is replaced.
    ///
    /// Ignores `nil`, anything shorter than ``minimumSecretLength`` and
    /// anything that is only whitespace. The whitespace guard matters: an env
    /// var set to blanks resolves to a string of spaces, and registering that
    /// would replace every run of spaces in every diagnostic for the rest of
    /// the process.
    public func register(_ secret: String?) {
        guard let secret, Self.isRegisterable(secret) else { return }
        literals.withLock { store in
            guard !store.contains(secret) else { return }
            store.append(secret)
            // Longest first. When one registered secret is a prefix of another
            // — a key and the same key with a suffix — replacing the shorter
            // one first leaves the remainder of the longer one sitting in the
            // text next to a `[redacted]` marker.
            store.sort { $0.count > $1.count }
        }
    }

    /// Registers each element, applying ``register(_:)``'s rules to every one.
    public func registerAll(_ secrets: some Sequence<String>) {
        for secret in secrets { register(secret) }
    }

    private static func isRegisterable(_ secret: String) -> Bool {
        secret.count >= minimumSecretLength && secret.contains(where: { !$0.isWhitespace })
    }

    /// Scrubs a string bound for a human: the literal registry first, then the
    /// pattern rules.
    ///
    /// This is a hot path — it runs on every error and on every re-render of
    /// the client's diagnostics panel — so both halves short-circuit. An empty
    /// registry costs one `isEmpty`, and text carrying none of the pattern
    /// rules' trigger substrings never reaches a regex engine.
    public func diagnostic(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let known = literals.withLock { $0 }
        var result = text
        for secret in known where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: Redaction.placeholder)
        }
        return Redaction.patterns(result)
    }

    /// Scrubs a header dictionary, dropping the value of any header whose
    /// *name* announces a credential and pattern-scrubbing the rest.
    ///
    /// Values of ordinary headers still go through ``diagnostic(_:)`` because a
    /// redirect `Location` can carry URL userinfo, which is a password in a
    /// header that no name-based rule would catch.
    public func redact(headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(headers.count)
        for (name, value) in headers {
            result[name] = Redaction.isSecretHeaderName(name) ? Redaction.placeholder : diagnostic(value)
        }
        return result
    }

    /// Scrubs a JSON value: string leaves go through ``diagnostic(_:)``, and
    /// any member whose key names a credential is replaced wholesale.
    ///
    /// Replacing by key is what catches a request body echoed back by a gateway
    /// — `{"api_key": "…"}` — where the value itself carries no recognizable
    /// prefix. A `null` under such a key is left alone: rewriting it would
    /// claim a credential was present when none was.
    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .null, .bool, .int, .double:
            return value
        case .string(let string):
            return .string(diagnostic(string))
        case .array(let elements):
            return .array(elements.map { redact($0) })
        case .object(let members):
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(members.count)
            for (key, member) in members {
                if Redaction.isSecretKeyName(key), member != .null {
                    result[key] = .string(Redaction.placeholder)
                } else {
                    result[key] = redact(member)
                }
            }
            return .object(result)
        }
    }
}

/// The process-wide façade over ``RedactionVault/shared``, plus the pattern
/// rules and name tests that need no registry at all.
public enum Redaction {

    /// What replaces a secret. ASCII, no hint, no attribution: a placeholder
    /// that named which rule fired would tell a reader of the log which kind of
    /// credential was present, and a length hint narrows a brute force.
    public static let placeholder = "[redacted]"

    /// The environment variables that hold the gateway credential.
    ///
    /// Duplicated from `DoMoCLI.EnvironmentKeys.apiKeyFallbacks` on purpose:
    /// DoMoCore sits below DoMoCLI, and the scrub sites that need this list —
    /// MCP child environments, tool-subprocess environments — are lower still.
    public static let secretEnvironmentNames: Set<String> = [
        "DOMOCODE_API_KEY", "LITELLM_API_KEY", "OPENAI_API_KEY",
    ]

    public static func register(_ secret: String?) {
        RedactionVault.shared.register(secret)
    }

    public static func registerAll(_ secrets: some Sequence<String>) {
        RedactionVault.shared.registerAll(secrets)
    }

    public static func diagnostic(_ text: String) -> String {
        RedactionVault.shared.diagnostic(text)
    }

    public static func redact(headers: [String: String]) -> [String: String] {
        RedactionVault.shared.redact(headers: headers)
    }

    public static func redact(_ value: JSONValue) -> JSONValue {
        RedactionVault.shared.redact(value)
    }

    // MARK: - Pattern rules

    /// Applies the pattern rules and nothing else — no registry consulted.
    ///
    /// Exists so the rules can be tested for over-redaction without a shared
    /// mutable registry deciding the answer, and so a caller that has no vault
    /// (a pure formatting helper) can still scrub.
    public static func patterns(_ text: String) -> String {
        guard containsPatternTrigger(text) else { return text }
        // Header lines first: they subsume every other rule for the text they
        // cover, so running them first means one replacement instead of a
        // `[redacted]` nested inside another.
        var result = replacingMatches(in: text, of: headerLineRule.regex, with: redactHeaderLine)
        result = replacingMatches(in: result, of: urlUserinfoRule.regex) { _ in "://\(placeholder)@" }
        result = replacingMatches(in: result, of: bearerRule.regex, with: redactBearer)
        result = replacingMatches(in: result, of: tokenRule.regex, with: redactToken)
        return result
    }

    /// One shared, precompiled pattern rule.
    ///
    /// `Regex` carries no `Sendable` conformance, so a `static let` holding one
    /// is rejected in Swift 6 mode, and `nonisolated(unsafe)` is then rejected
    /// again by `.strictMemorySafety()`. A `Mutex` compiles but puts every
    /// redaction in the process behind a single lock, on precisely the paths —
    /// an error being formatted, a diagnostics panel re-rendering — where that
    /// contention is least welcome.
    ///
    /// So the conformance is asserted by hand, and `init` narrows what has to
    /// be true for the assertion to hold: it runs the rule once against the
    /// empty string, so whatever first-use work a pattern does — lowering it to
    /// a matching program — happens here, on one thread, before the box can be
    /// shared. Every later use is a read of a `let`; a match builds its own
    /// state.
    private final class PatternRule: @unchecked Sendable {
        let regex: Regex<Substring>

        init(_ regex: Regex<Substring>) {
            self.regex = regex
            _ = "".firstMatch(of: regex)
        }
    }

    /// Literal substrings without which no pattern rule can possibly fire.
    ///
    /// Every header rule and the URL-userinfo rule need a colon; every token
    /// rule needs its prefix. Ordinary prose carries none of these, so the
    /// common diagnostic never pays for a regex engine. `Bearer` is checked
    /// separately because its rule is case-insensitive.
    private static let patternTriggers = [
        ":", "sk-", "sk_", "pk_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA",
    ]

    private static func containsPatternTrigger(_ text: String) -> Bool {
        if patternTriggers.contains(where: { text.contains($0) }) { return true }
        return text.range(of: "earer", options: [.caseInsensitive, .literal]) != nil
    }

    /// `scheme://user:password@host` — the userinfo span only.
    ///
    /// The host is the useful half of the diagnostic ("which endpoint refused
    /// me?") and is not a secret, so it stays readable. A colon is required:
    /// `https://user@host` is a username, not a credential.
    private static let urlUserinfoRule = PatternRule(/:\/\/[^\/@:\s]+:[^\/@\s]*@/)

    /// Header lines whose value is a credential in its entirety.
    ///
    /// The value runs to end of line and is taken wholesale. That is greedy on
    /// purpose: a cookie or an auth value may contain `,`, `;` or `"`, so any
    /// earlier stop risks leaving the tail of the secret behind. A truncated
    /// diagnostic beats a leaked key. The rule is line-bounded, so the lines
    /// around it survive.
    private static let headerLineRule = PatternRule(
        /(?:proxy-authorization|authorization|x-api-key|api-key|set-cookie|cookie)[ \t]*:[^\r\n]*/
            .ignoresCase()
    )

    /// Vendor token prefixes, each requiring at least sixteen following
    /// characters of the run class so a bare `sk-` in prose survives.
    ///
    /// The leading `(?:^|[^…])` swallows one boundary character, which is what
    /// stops `task-1234567890123456` from being read as an `sk-` key; the
    /// boundary is put back by ``redactToken(_:)``. The run may not *end* in a
    /// dot, so the full stop that ends the sentence after a token is not eaten.
    private static let tokenRule = PatternRule(
        /(?:^|[^A-Za-z0-9_.\-])(?:github_pat_|sk-ant-|sk-proj-|sk_live_|pk_live_|xoxb-|xoxp-|ghp_|gho_|sk-)[A-Za-z0-9_.\-]{15,}[A-Za-z0-9_\-]|(?:^|[^A-Za-z0-9_.\-])AKIA[0-9A-Z]{16}/
    )

    /// `Bearer <credential>` outside a header line — the form an upstream error
    /// quotes back at you.
    private static let bearerRule = PatternRule(
        /(?:^|[^A-Za-z0-9_.\-])bearer[ \t]+[A-Za-z0-9_.\-]{15,}[A-Za-z0-9_\-]/
            .ignoresCase()
    )

    private static func redactHeaderLine(_ matched: Substring) -> String {
        guard let colon = matched.firstIndex(of: ":") else { return placeholder }
        let value = matched[matched.index(after: colon)...]
        // An absent value is not a secret. Turning `Cookie:` into
        // `Cookie: [redacted]` would tell the reader a credential was there.
        guard value.contains(where: { !$0.isWhitespace }) else { return String(matched) }
        return "\(matched[...colon]) \(placeholder)"
    }

    private static func redactToken(_ matched: Substring) -> String {
        // Give back the boundary character the rule consumed; it belongs to the
        // surrounding text. When the token starts the string the rule matched
        // `^` instead and there is no boundary to restore.
        guard let first = matched.first, !isRunCharacter(first) else { return placeholder }
        return "\(first)\(placeholder)"
    }

    private static func redactBearer(_ matched: Substring) -> String {
        // Keep everything through the separator: "Bearer [redacted]" still
        // reads as an authorization value, and the scheme word is not secret.
        // The credential is whatever follows the last space or tab, because a
        // run may not contain either.
        guard let separator = matched.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
            return placeholder
        }
        return "\(matched[...separator])\(placeholder)"
    }

    private static func isRunCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-")
    }

    /// Rebuilds `text` with every match of `rule` handed to `transform`.
    ///
    /// Written against `ranges(of:)` rather than a match's typed captures so
    /// every rule can share one path regardless of how many groups it has.
    /// Returns the original string untouched when nothing matched, so the
    /// no-secret case allocates nothing.
    private static func replacingMatches(
        in text: String,
        of rule: some RegexComponent,
        with transform: (Substring) -> String
    ) -> String {
        let ranges = text.ranges(of: rule)
        guard !ranges.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor..<range.lowerBound]
            result += transform(text[range])
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Name tests

    /// Substrings that make a key name a credential name.
    private static let secretKeyMarkers = [
        "apikey", "secret", "password", "passwd", "token", "credential",
        "authorization", "bearer", "privatekey", "accesskey", "sessionkey",
    ]

    /// Counter names that contain `token` and must never be redacted.
    ///
    /// This allow-list is not optional. Without it every `prompt_tokens`,
    /// `max_tokens` and `total_tokens` in a usage object is replaced by
    /// `[redacted]`, which destroys the exact numbers this phase exists to make
    /// honest — the cost total, the context meter and the session accounting
    /// all read them.
    ///
    /// Matched as a substring so the nested wire shapes qualify too
    /// (`prompt_tokens_details`, `cache_read_input_tokens`). The narrow cost is
    /// that a name combining a marker *and* a counter — `secret_token_count` —
    /// is allowed through; the counters are worth that.
    private static let tokenCounterNames = [
        "maxtokens", "inputtokens", "outputtokens", "totaltokens", "prompttokens",
        "completiontokens", "cachedtokens", "reasoningtokens", "tokensbefore", "tokencount",
    ]

    /// Header names whose value is a credential but whose *name* carries none
    /// of ``secretKeyMarkers``. `Cookie` is the whole reason this exists: a
    /// session cookie is a credential and the word says nothing about it.
    private static let secretHeaderNames: Set<String> = ["cookie", "setcookie"]

    /// Whether a key or header name announces that its value is a credential.
    ///
    /// Normalizes first — lowercase, then drop everything that is not an ASCII
    /// letter or digit — so `X-API-Key`, `api_key` and `apiKey` are one name.
    public static func isSecretKeyName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else { return false }
        // The allow-list is checked FIRST and unconditionally; see
        // ``tokenCounterNames``.
        if tokenCounterNames.contains(where: { normalized.contains($0) }) { return false }
        return secretKeyMarkers.contains(where: { normalized.contains($0) })
    }

    /// ``isSecretKeyName(_:)`` widened by the header names it cannot know
    /// about. Header-only, because `cookie` as a key in a tool result is far
    /// more likely to be a recipe than a session.
    static func isSecretHeaderName(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        return secretHeaderNames.contains(normalized) || isSecretKeyName(name)
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
