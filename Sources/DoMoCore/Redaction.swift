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
/// Two mechanisms, interleaved rather than stacked:
///
/// 1. **Pattern rules** for the secrets nobody registered: a key the *user*
///    pasted into a prompt, a `Set-Cookie` from a proxy, a token quoted back by
///    an upstream error. They are structural, and a registered literal must not
///    be able to disable one.
/// 2. A **literal registry**. Whoever resolved a secret — the env layer, config
///    interpolation — hands the resolved value here, and every later occurrence
///    of that exact string is replaced. This is the only mechanism that can be
///    exact, and it is the backstop for everything the rules cannot recognize.
///
/// Neither can simply run first: a rule that rewrites *part* of a registered
/// secret leaves the rest unmatchable, and a registered literal that is a rule's
/// trigger word switches that rule off. ``RedactionVault/diagnostic(_:)`` states
/// which secret goes on which side of the pattern pass, and why.
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

    /// A registered secret and the one thing ``diagnostic(_:)`` needs to know
    /// about it, decided once here rather than on every scrub.
    private struct Registered: Sendable {
        var text: String

        /// Whether a *value* rule — URL userinfo, a bearer run, a vendor token —
        /// would rewrite part of this secret and leave the rest behind.
        ///
        /// Only the value rules count. Header-line sensitivity is the opposite
        /// problem: a literal the header rule keys on is one that must survive
        /// into the pattern pass, not one that must be removed before it. See
        /// ``diagnostic(_:)``.
        var isFragile: Bool
    }

    /// Registered secrets, longest first — see ``register(_:)`` for why order
    /// is part of the contract rather than an accident of insertion.
    private let literals = Mutex<[Registered]>([])

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
        // Decided here, on the cold path, because `diagnostic(_:)` consults it
        // for every registered secret on every error it formats.
        let entry = Registered(text: secret, isFragile: Redaction.isPatternFragile(secret))
        literals.withLock { store in
            guard !store.contains(where: { $0.text == secret }) else { return }
            store.append(entry)
            // Longest first. When one registered secret is a prefix of another
            // — a key and the same key with a suffix — replacing the shorter
            // one first leaves the remainder of the longer one sitting in the
            // text next to a `[redacted]` marker.
            store.sort { $0.text.count > $1.text.count }
        }
    }

    /// Registers each element, applying ``register(_:)``'s rules to every one.
    public func registerAll(_ secrets: some Sequence<String>) {
        for secret in secrets { register(secret) }
    }

    private static func isRegisterable(_ secret: String) -> Bool {
        secret.count >= minimumSecretLength && secret.contains(where: { !$0.isWhitespace })
    }

    /// Scrubs a string bound for a human: the registry, then the pattern rules,
    /// then the registry again.
    ///
    /// **The order is a security property, not a preference**, and it is not the
    /// same order for every registered secret — because each of the two possible
    /// orders leaks a different secret.
    ///
    /// *Patterns cannot go first for a secret a rule only partly recognizes.* A
    /// registered `postgres://admin:p@ssw0rd-hunter2-longsecret@db.internal:5432/app`
    /// trips the URL-userinfo rule, which by design rewrites `://admin:p@` and
    /// keeps the host — the `@` inside the password ends the match, so all but
    /// the first character of that password stays in the text, where the
    /// registry can no longer reach it because the literal it knows no longer
    /// occurs:
    ///
    /// ```
    /// connect failed: postgres://[redacted]@ssw0rd-hunter2-longsecret@db.internal:5432/app
    /// ```
    ///
    /// The same shape holds for a Slack token with a trailing half outside the
    /// rule's run class, and for a base64 key whose `==` padding the rule stops
    /// at. So a secret a *value* rule would break up is replaced whole, before
    /// any rule can break it up.
    ///
    /// *The registry cannot go first for every secret.* A registered literal is
    /// replaced everywhere it occurs, so a literal that happens to be the
    /// substring a rule matches on deletes that rule's trigger. This is not
    /// hypothetical: `authHeader` is a credential-carrying config key, its value
    /// is a *header name* — `Authorization` — and registering it made
    /// `Authorization: Basic …` become `[redacted]: Basic …`, with the
    /// credential intact, right past a rule written to catch exactly that line.
    /// Such a literal is left in place for the pattern pass and removed by the
    /// pass after it.
    ///
    /// Which side a secret falls on is ``Registered/isFragile``, decided once at
    /// registration by ``Redaction/isPatternFragile(_:)``.
    ///
    /// This is a hot path — it runs on every error and on every re-render of
    /// the client's diagnostics panel — so every stage short-circuits. Text
    /// carrying none of the pattern rules' trigger substrings never reaches a
    /// regex engine, an empty registry costs two loops over nothing, and a
    /// secret the text does not contain costs one `contains`.
    public func diagnostic(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let known = literals.withLock { $0 }
        var result = text
        // The secrets a value rule would only partly rewrite, before it can.
        for secret in known where secret.isFragile {
            guard result.contains(secret.text) else { continue }
            result = result.replacingOccurrences(of: secret.text, with: Redaction.placeholder)
        }
        result = Redaction.patterns(result)
        // Everything else the registry knows, including the literals held back
        // above so that they could not switch a rule off.
        for secret in known {
            guard result.contains(secret.text) else { continue }
            result = result.replacingOccurrences(of: secret.text, with: Redaction.placeholder)
        }
        return result
    }

    /// Scrubs a header dictionary, dropping the value of any header whose
    /// *name* announces a credential and pattern-scrubbing the rest.
    ///
    /// Values of ordinary headers still go through ``diagnostic(_:)`` because a
    /// redirect `Location` can carry URL userinfo, which is a password in a
    /// header that no name-based rule would catch.
    ///
    /// > Note: no production code calls this yet. The natural site is
    /// > `ResponseMetadata.headers` in DoMoLLM, which is the only place the
    /// > harness holds a response's headers as a dictionary; until that is wired
    /// > up this is exercised only by its tests.
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
    ///
    /// > Note: no production code calls this yet either. Error bodies reach
    /// > ``diagnostic(_:)`` as text, not as parsed JSON, so nothing in the
    /// > harness currently has a `JSONValue` on a path bound for a human.
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
        // Header lines first: where one really is a header it subsumes every
        // other rule for the text it covers, so running it first means one
        // replacement instead of a `[redacted]` nested inside another. Where the
        // marker turns out to be prose the span is left untouched and the rules
        // below still get their look at it.
        let result = replacingMatches(in: text, of: headerLineRule.regex, with: redactHeaderLine)
        return valuePatterns(result)
    }

    /// The rules that recognize a credential by the shape of the *value* alone:
    /// URL userinfo, a bearer run, a vendor-prefixed token.
    ///
    /// Split out from ``patterns(_:)`` because two callers need these without
    /// the header-line rule. ``RedactionVault/diagnostic(_:)`` asks whether a
    /// registered secret would be *broken up* by a rule, and a header marker
    /// inside a secret is the case where the literal must survive instead. And
    /// ``maskingSecrets(inSourceLine:)`` needs rules that stop at the end of
    /// what is secret, not at the end of the line.
    static func valuePatterns(_ text: String) -> String {
        guard containsPatternTrigger(text) else { return text }
        var result = replacingMatches(in: text, of: urlUserinfoRule.regex) { _, _ in "://\(placeholder)@" }
        result = replacingMatches(in: result, of: bearerRule.regex) { redactBearer($0[$1]) }
        result = replacingMatches(in: result, of: tokenRule.regex) { redactToken($0[$1]) }
        return result
    }

    /// Whether a value rule would rewrite part of `secret`, leaving the rest of
    /// it in the text as something the registry can no longer match.
    ///
    /// See ``RedactionVault/diagnostic(_:)`` for what is done about it. The
    /// header-line rule is deliberately excluded: a registered literal it keys
    /// on — the header *name* — is one that must reach the pattern pass intact.
    static func isPatternFragile(_ secret: String) -> Bool {
        valuePatterns(secret) != secret
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
    ///
    /// The rule finds the marker *anywhere*; whether the marker is actually a
    /// header is decided by ``isAtHeaderPosition(_:_:)`` in the replacement, not
    /// here. Writing the anchor into the pattern is the obvious alternative and
    /// it does not work: `Regex` fails to backtrack a greedy quantifier that
    /// follows a character class, so `/[\r\n][A-Za-z0-9_\-]*api-key/` finds
    /// nothing at all in `"\nanthropic-api-key:"`. For a redaction rule that
    /// engine bug is a silent leak, so the decision is made in code that can be
    /// read and tested directly.
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

    private static func redactHeaderLine(_ text: String, _ range: Range<String.Index>) -> String {
        let matched = text[range]
        // A marker in the middle of a sentence is prose, not a header. This is
        // the whole reason the check exists: `DoMoError.description` is a
        // documented one-line string that is persisted as an
        // `AssistantMessage.errorMessage`, and taking everything to end of line
        // from an unanchored marker wrote "the api-key: header was rejected,
        // rotate the key in the dashboard" to the session file with its entire
        // actionable half missing.
        //
        // Leaving the span alone rather than rewriting it is deliberate: the
        // later rules run over the whole string afterwards, so a token or a
        // bearer run inside this sentence is still redacted by the rule that
        // recognizes it.
        guard isAtHeaderPosition(text, range.lowerBound) else { return String(matched) }
        guard let colon = matched.firstIndex(of: ":") else { return placeholder }
        let value = matched[matched.index(after: colon)...]
        // An absent value is not a secret. Turning `Cookie:` into
        // `Cookie: [redacted]` would tell the reader a credential was there.
        guard value.contains(where: { !$0.isWhitespace }) else { return String(matched) }
        return "\(matched[...colon]) \(placeholder)"
    }

    /// Whether a marker starting at `start` is where a header name would be.
    ///
    /// Walking backwards, a header position is: the rest of the header's name,
    /// then optional indentation, then the start of a line. So
    /// `Anthropic-Api-Key:` and `  Set-Cookie:` are headers, `cookieJar:` is not
    /// (the marker has to *end* the name, which the pattern already requires),
    /// and `the api-key:` is not — a blank may indent a line but may never
    /// separate a word from the header name.
    ///
    /// The start of a line is the start of the text, a real `CR` or `LF`, or an
    /// *escaped* one: the two characters `\` and `r`/`n`, which is the form a
    /// header block takes once it has been through a JSON string. That is the
    /// only way a header block reaches a persisted one-line error message.
    private static func isAtHeaderPosition(_ text: String, _ start: String.Index) -> Bool {
        var index = start
        var sawBlank = false
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isNewline { return true }
            if character == "r" || character == "n", previous > text.startIndex,
                text[text.index(before: previous)] == "\\"
            {
                // An escaped line break: the two characters `\` and `r`/`n`.
                return true
            }
            if character == " " || character == "\t" {
                sawBlank = true
                index = previous
                continue
            }
            // Name characters may only sit between the marker and the start of
            // the line; once a blank has been crossed there is a word here, and
            // a word before a marker makes it prose.
            guard !sawBlank, isHeaderNameCharacter(character) else { return false }
            index = previous
        }
        return true
    }

    private static func isHeaderNameCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "_" || character == "-")
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
    ///
    /// `transform` is handed the whole text and the matched range, not just the
    /// match, because a rule may need to see what *precedes* it: the header rule
    /// is only a header rule when its marker starts a header name.
    private static func replacingMatches(
        in text: String,
        of rule: some RegexComponent,
        with transform: (String, Range<String.Index>) -> String
    ) -> String {
        let ranges = text.ranges(of: rule)
        guard !ranges.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor..<range.lowerBound]
            result += transform(text, range)
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Length-preserving source masking

    /// Masks the credentials on one line of JSON source **without changing how
    /// long it is**.
    ///
    /// ``ConfigDiagnostic`` quotes the offending line of a settings file back at
    /// the user with a caret under the offending column, and a settings file
    /// holds `mcpServers.*.environment` — so that line is routinely a live
    /// credential, and any unrelated key in the file failing to decode was
    /// enough to print it to stderr.
    ///
    /// ``patterns(_:)`` is the wrong tool for that line, twice over:
    ///
    /// * Every rule substitutes `[redacted]`, whose length is not the length of
    ///   what it replaced. The caret is counted in Unicode scalars of this exact
    ///   line, so any substitution of a different width slides it off the
    ///   character it is accusing — the one thing the excerpt exists to point at.
    /// * The header rule takes everything after its marker to end of line, so a
    ///   line holding `"note": "authorization: see the docs"` would lose its
    ///   value, its closing brace and every sibling after it.
    ///
    /// So this masks with a run of `*` of exactly the same number of Unicode
    /// scalars — quotes, keys, structure and every column stay where they were —
    /// and decides what to mask three ways, in this order:
    ///
    /// 1. **By position.** A literal that is the value of a member whose key
    ///    passes ``isSecretKeyName(_:)``; the value of *any* member of an
    ///    `environment` object; *any* element of a `command` array. The last two
    ///    are the block whose entire purpose is handing secrets to a child
    ///    process, and `DoMoCLI`'s `Settings.keyCarriesCredential` registers
    ///    every value in it as a process-wide secret for exactly one reason: a
    ///    name filter misses the one a user spelled `GH_PAT`, `NPM_AUTH` or
    ///    `MY_KEY`, and misses `["gh-mcp", "--token=…"]` altogether. A mask that
    ///    tested names would *be* the filter its own registration policy argues
    ///    against, and would print the values that policy calls credentials.
    /// 2. **A credential header line inside a literal** — `"note":
    ///    "authorization: rotate it"` — masked whole, because that rule's value
    ///    has no end short of the end of what quotes it.
    /// 3. **The span a value rule recognizes, and only that span**: the userinfo
    ///    of a URL, the run after `Bearer`, a vendor token. Starring the whole
    ///    literal instead turns `"baseUrl": "https://svc:pw@gw.corp.internal:4000/v1"`
    ///    into a row of stars and takes the endpoint with it — and the endpoint
    ///    is what a user debugging an unrelated typo most needs to read. It is
    ///    the same half the live URL rule already keeps.
    ///
    /// Then, whatever the walk concluded, the **raw line** is swept for those
    /// same value-rule spans and they are starred too. That is belt and braces
    /// for the case this function exists to serve: the commonest JSON typo is a
    /// missing quote — which is the very error being reported — and it inverts
    /// the parity of every literal after it, so the credential lands *outside*
    /// everything the walk calls a literal and would otherwise print verbatim.
    /// The sweep carries the value rules only, for the reason in the second
    /// bullet above: the header rule has no right edge but the end of the line,
    /// and on a line whose structure is already broken that is every sibling
    /// member the excerpt was quoting.
    ///
    /// Two details earn their keep. A tab inside a masked span survives as a tab,
    /// because the excerpt expands tabs to a fixed stop and turning one into `*`
    /// would move every column after it. And a literal left unterminated at end
    /// of line is masked to end of line: the rest of it is its value, and the
    /// line came from a file that failed to parse in the first place.
    public static func maskingSecrets(inSourceLine line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var masked = scalars
        var changed = false

        // Stars one span, scalar for scalar. A tab is left as it was: see above.
        func star(_ span: Range<Int>) {
            guard !span.isEmpty else { return }
            for offset in span where masked[offset] != "\t" { masked[offset] = "*" }
            changed = true
        }

        if scalars.contains("\"") {
            let literals = jsonStringLiterals(in: scalars)
            let byPosition = credentialsByPosition(literals, in: scalars)
            for position in literals.indices {
                let literal = literals[position]
                guard !literal.contents.isEmpty else { continue }
                if byPosition[position] || isCredentialHeaderLine(literal.text) {
                    star(literal.contents)
                    continue
                }
                let base = literal.contents.lowerBound
                for span in credentialSpans(in: literal.text) {
                    star((base + span.lowerBound)..<(base + span.upperBound))
                }
            }
        }

        // Belt and braces: a line that failed to parse cannot be trusted to have
        // put its credential inside a literal.
        for span in credentialSpans(in: line) { star(span) }

        guard changed else { return line }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: masked)
        return String(view)
    }

    /// One JSON string literal on a source line, in scalar offsets. `close` is
    /// `nil` for a literal the line ends inside of.
    private struct SourceLiteral {
        var open: Int
        var contents: Range<Int>
        var close: Int?
        var text: String
    }

    /// Every JSON string literal on the line, in order.
    private static func jsonStringLiterals(in scalars: [Unicode.Scalar]) -> [SourceLiteral] {
        var literals: [SourceLiteral] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\"" else {
                index += 1
                continue
            }
            var cursor = index + 1
            var close: Int?
            while cursor < scalars.count {
                if scalars[cursor] == "\\" {
                    // A backslash escapes whatever follows it, including a
                    // quote, so the pair is skipped whole.
                    cursor += 2
                    continue
                }
                if scalars[cursor] == "\"" {
                    close = cursor
                    break
                }
                cursor += 1
            }
            let contents = min(index + 1, scalars.count)..<min(close ?? scalars.count, scalars.count)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[contents])
            literals.append(
                SourceLiteral(open: index, contents: contents, close: close, text: String(view))
            )
            index = close.map { $0 + 1 } ?? scalars.count
        }
        return literals
    }

    /// Which literals are credentials because of **where they sit**: the value
    /// of a member whose key names a credential, the value of any member of an
    /// `environment` object, or any element of a `command` array.
    ///
    /// Position rather than spelling, because the names in that block are the
    /// user's own — see ``maskingSecrets(inSourceLine:)``.
    private static func credentialsByPosition(
        _ literals: [SourceLiteral], in scalars: [Unicode.Scalar]
    ) -> [Bool] {
        var result = [Bool](repeating: false, count: literals.count)
        guard !literals.isEmpty else { return result }

        // The key of the member `position` is the value of, if it is one: the
        // literal before it, separated by exactly one colon and blanks.
        //
        // The "and nothing else" is what keeps `"environment": {"K": "v"}` from
        // attributing `v` to `environment` — the `{` between them ends the
        // question — and it is why a nested key is read from the literal that
        // really precedes it.
        func keyOfMember(at position: Int) -> String? {
            guard position > 0, let close = literals[position - 1].close else { return nil }
            var sawColon = false
            for offset in (close + 1)..<literals[position].open {
                let scalar = scalars[offset]
                if scalar == ":" {
                    guard !sawColon else { return nil }
                    sawColon = true
                } else if !isJSONWhitespace(scalar) {
                    return nil
                }
            }
            return sawColon ? literals[position - 1].text : nil
        }

        // A container, labelled with the key it is the value of. That label is
        // the whole point: it is what makes an element of `command` and a member
        // of `environment` recognizable without asking what they are called.
        struct Container {
            var label: String
            var isArray: Bool
        }

        var stack: [Container] = []
        var pendingKey = ""  // the literal just passed, until something says what it was
        var pendingLabel = ""  // the key whose value the next `{` or `[` opens
        var position = 0
        var index = 0
        while index < scalars.count {
            if position < literals.count, index == literals[position].open {
                let literal = literals[position]
                let container = stack.last
                if let key = keyOfMember(at: position) {
                    if isSecretKeyName(key) { result[position] = true }
                    if let container, !container.isArray,
                        credentialObjectNames.contains(normalizedName(container.label))
                    {
                        result[position] = true
                    }
                } else if let container, container.isArray,
                    credentialArrayNames.contains(normalizedName(container.label))
                {
                    result[position] = true
                }
                pendingKey = literal.text
                pendingLabel = ""
                index = literal.close.map { $0 + 1 } ?? scalars.count
                position += 1
                continue
            }
            let scalar = scalars[index]
            if scalar == ":" {
                pendingLabel = pendingKey
                pendingKey = ""
            } else if scalar == "{" || scalar == "[" {
                stack.append(Container(label: pendingLabel, isArray: scalar == "["))
                pendingLabel = ""
                pendingKey = ""
            } else if scalar == "}" || scalar == "]" {
                if !stack.isEmpty { stack.removeLast() }
                pendingLabel = ""
                pendingKey = ""
            } else if !isJSONWhitespace(scalar) {
                // A comma, a number, a stray character: whatever it is, it ends
                // the question of what the last key was.
                pendingLabel = ""
                pendingKey = ""
            }
            index += 1
        }
        return result
    }

    /// The key of an object whose every member value is a credential, and the
    /// key of an array whose every element is one.
    ///
    /// The same two slots `DoMoCLI`'s `Settings.keyCarriesCredential` treats as
    /// unconditionally credential-bearing — `mcpServers.*.environment` and
    /// `mcpServers.*.command` — for the same reason.
    private static let credentialObjectNames: Set<String> = ["environment"]
    private static let credentialArrayNames: Set<String> = ["command"]

    /// Whether the header-line rule reads `text` as a credential header.
    ///
    /// The one rule whose value has no end short of the end of the line, which
    /// is why a literal it recognizes is masked whole rather than by span.
    private static func isCredentialHeaderLine(_ text: String) -> Bool {
        guard containsPatternTrigger(text) else { return false }
        return replacingMatches(in: text, of: headerLineRule.regex, with: redactHeaderLine) != text
    }

    /// Every span of `text` a **value** rule recognizes as a credential, as
    /// offsets into `text.unicodeScalars`.
    ///
    /// Each is narrowed to what is actually secret — the same narrowing
    /// ``valuePatterns(_:)`` makes when it substitutes: the userinfo between
    /// `://` and `@`, the run after `Bearer`, the token without the boundary
    /// character its rule consumed.
    private static func credentialSpans(in text: String) -> [Range<Int>] {
        guard containsPatternTrigger(text) else { return [] }
        let scalars = text.unicodeScalars
        func offset(of index: String.Index) -> Int {
            scalars.distance(from: scalars.startIndex, to: index)
        }

        var spans: [Range<Int>] = []
        // `scheme://user:password@` — the userinfo, between a three-scalar `://`
        // and the one-scalar `@` the match ends on.
        for range in text.ranges(of: urlUserinfoRule.regex) {
            let start = offset(of: range.lowerBound) + 3
            let end = offset(of: range.upperBound) - 1
            if start < end { spans.append(start..<end) }
        }
        // `Bearer <credential>` — whatever follows the last blank, because a run
        // may not contain one.
        for range in text.ranges(of: bearerRule.regex) {
            let matched = text[range]
            guard let separator = matched.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
                spans.append(offset(of: range.lowerBound)..<offset(of: range.upperBound))
                continue
            }
            spans.append(offset(of: matched.index(after: separator))..<offset(of: range.upperBound))
        }
        // A vendor-prefixed token, less the boundary character the rule ate to
        // prove the prefix started a word.
        for range in text.ranges(of: tokenRule.regex) {
            var start = offset(of: range.lowerBound)
            if let first = text[range].first, !isRunCharacter(first) { start += 1 }
            spans.append(start..<offset(of: range.upperBound))
        }
        return spans
    }

    private static func isJSONWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    // MARK: - Name tests

    /// Substrings that make a key name a credential name.
    private static let secretKeyMarkers = [
        "apikey", "secret", "password", "passwd", "token", "credential",
        "authorization", "bearer", "privatekey", "accesskey", "sessionkey",
    ]

    /// Markers that name a credential outright, and therefore beat the token
    /// counter allow-list.
    ///
    /// The counter rule keys on the plural — see ``isTokenCounterName(_:)`` —
    /// and a credential can be plural too. Without this list `access_tokens`,
    /// `refresh_tokens` and `api_tokens` all read as counters and are printed.
    /// The singular forms need no help; these exist for the names where both
    /// signals are present at once.
    private static let unambiguousSecretKeyMarkers = [
        "apikey", "secret", "password", "passwd", "credential",
        "authorization", "bearer", "privatekey", "accesskey", "sessionkey",
        "apitoken", "accesstoken", "refreshtoken", "authtoken", "idtoken",
        "sessiontoken",
    ]

    /// Whether a *normalized* name counts tokens rather than being one.
    ///
    /// The distinguishing signal is the plural. Every counter a provider emits
    /// is a count *of tokens* — `prompt_tokens`, `audio_tokens`, `text_tokens`,
    /// `image_tokens`, `accepted_prediction_tokens`, `cache_read_input_tokens`,
    /// `num_tokens`, bare `tokens` — and the nested wire shapes keep the plural
    /// inside them (`prompt_tokens_details`, `tokens_before`). A credential is a
    /// token, singular: `access_token`, `api_token`. `token_count` says "count"
    /// outright and is admitted by name.
    ///
    /// This rule replaced an enumeration of ten literal counter names, which was
    /// wrong in the way an allow-list is always wrong: it silently called
    /// `audio_tokens`, `text_tokens`, `image_tokens`,
    /// `accepted_prediction_tokens`, `rejected_prediction_tokens`,
    /// `cache_read_tokens`, `cache_write_tokens`, `num_tokens` and `tokens`
    /// credentials, and the test that "pinned" it listed exactly the names it
    /// already contained, so the gap could not fail a test.
    ///
    /// The allow-list is mostly **pre-emptive**. Its one live reader is
    /// DoMoCLI's config interpolation, which asks ``isSecretKeyName(_:)`` which
    /// substituted values to register as process-wide secrets — a `maxTokens`
    /// read from the environment must not become a string that is struck out of
    /// every later diagnostic. ``RedactionVault/redact(_:)``, the usage-object
    /// path this list is really shaped for, has no production caller yet.
    private static func isTokenCounterName(_ normalized: String) -> Bool {
        normalized.contains("tokens") || normalized.contains("tokencount")
    }

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
        // A name that says "credential" outright wins over the counter rule, so
        // that a plural credential is not mistaken for a plural counter.
        if unambiguousSecretKeyMarkers.contains(where: { normalized.contains($0) }) { return true }
        // Then the allow-list; see ``isTokenCounterName(_:)``.
        if isTokenCounterName(normalized) { return false }
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
