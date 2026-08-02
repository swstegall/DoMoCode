// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `{env:NAME}` and `{file:PATH}` in settings.json, resolved.
//
// The feature is opencode's (`packages/opencode/src/config/variable.ts`) and the
// trust model is kilocode's hardening of it (the same path in the kilocode fork,
// plus `src/kilocode/config/variable.ts`): project configuration is untrusted, so
// `{env:}` is refused outright and `{file:}` is confined to the project root,
// while a user's own config is trusted. DoMoCode follows kilocode, and diverges
// from both upstreams in four places that are documented on the declarations
// below — the hard error for an unset variable, the credential denylist, the
// single-pass design, and the escape.

import SystemPackage

// MARK: - Policy

/// Who is allowed to interpolate what.
///
/// The split exists because the two settings.json files this harness reads are
/// not equally trustworthy. `~/.domocode/settings.json` is the user's own; a
/// repository's `.domocode/settings.json` arrives with whatever was cloned. If
/// project config could say `{env:DOMOCODE_API_KEY}` it could exfiltrate the
/// gateway credential through any field that later reaches the network, and if
/// its `{file:}` were unconfined it could read `~/.ssh/id_ed25519` into a value
/// that is then sent upstream. So the untrusted policy refuses `{env:}` — there
/// is no scoped form of "read one environment variable" that stays safe — and
/// bounds `{file:}` to the project directory.
public struct InterpolationPolicy: Sendable, Hashable {

    /// Whether `{env:NAME}` may be resolved at all. False refuses every `{env:}`
    /// token by name, rather than resolving it to something harmless: a config
    /// that expected a value and silently got none fails later, somewhere else,
    /// as an unexplained authentication error.
    public var allowEnvironment: Bool

    /// The directory `{file:}` may not escape. `nil` is unconfined.
    ///
    /// Confinement is **lexical**: the path is normalized by collapsing `.` and
    /// `..` without consulting the filesystem, and must still start with this
    /// root. That catches `../../../etc/passwd` and an absolute path, but it
    /// does not catch a symlink *inside* the root that points outside it —
    /// nothing here calls `realpath`, because this function is pure by design
    /// and does its reading through an injected closure. A caller that needs
    /// that guarantee must enforce it in the closure, where the file descriptor
    /// actually exists.
    public var fileRoot: String?

    /// Environment variable names that may never be interpolated, even under a
    /// trusted policy, compared case-insensitively.
    ///
    /// This is the single most important constraint in this file, and it is not
    /// about the user's own config being dangerous — it is about where an
    /// interpolated value can end up. `mcpServers.x.environment` is overlaid
    /// onto a child process's environment *after* the MCP launcher scrubs the
    /// gateway credential out of it, so `{"K": "{env:OPENAI_API_KEY}"}` re-injects
    /// by hand exactly the secret the scrub exists to remove, under a name the
    /// scrub does not know. Refusing the read is the only place that composes.
    public var deniedEnvironmentNames: Set<String>

    public init(allowEnvironment: Bool, fileRoot: String?, deniedEnvironmentNames: Set<String>) {
        self.allowEnvironment = allowEnvironment
        self.fileRoot = fileRoot
        self.deniedEnvironmentNames = deniedEnvironmentNames
    }

    /// The user's own configuration: environment reads allowed, file reads
    /// unconfined, credential names still denied.
    public static let trusted = InterpolationPolicy(
        allowEnvironment: true,
        fileRoot: nil,
        deniedEnvironmentNames: Redaction.secretEnvironmentNames
    )

    /// A repository's configuration: no environment reads, file reads confined
    /// to `root`.
    ///
    /// The denylist is carried anyway even though `allowEnvironment` already
    /// refuses every name. Keeping the field populated means loosening
    /// `allowEnvironment` later cannot silently unblock the credentials.
    public static func untrusted(root: String) -> InterpolationPolicy {
        InterpolationPolicy(
            allowEnvironment: false,
            fileRoot: root,
            deniedEnvironmentNames: Redaction.secretEnvironmentNames
        )
    }
}

// MARK: - Result

/// A resolved value, plus what went into it.
public struct InterpolationResult: Sendable, Hashable {

    /// The value with every token replaced. Equal to the input when there was
    /// nothing to substitute.
    public var value: String

    /// The values that were substituted in, in the order they were resolved.
    ///
    /// They are handed back rather than merely spliced because they are exactly
    /// the strings a user chose to keep out of their config file, which makes
    /// them exactly the strings that must never appear in a diagnostic or a log
    /// line. The caller passes them to ``Redaction/registerAll(_:)``. File
    /// contents are included for the same reason: `{file:~/.gateway-key}` is a
    /// credential too.
    public var substituted: [String]

    public init(value: String, substituted: [String]) {
        self.value = value
        self.substituted = substituted
    }
}

// MARK: - Resolution

/// Resolve `{env:NAME}` and `{file:PATH}` in one config value.
///
/// ## Where this runs
///
/// On the decoded *value*, never on the file text. Substituting into the source
/// bytes moves every byte offset after the first token, which would put
/// ``ConfigDiagnostic``'s caret under the wrong column for every later error in
/// the file.
///
/// ## Syntax
///
/// A token is `{env:NAME}` or `{file:PATH}` — lowercase keyword, no spaces, body
/// non-empty and free of `{`, `}`, CR and LF. Anything else that merely contains
/// a brace (`{}`, `{notatoken}`, `{ env:X }`, a JSON snippet in a prompt string)
/// is not a token and is copied through untouched.
///
/// The escape is `{{env:NAME}}` → the literal text `{env:NAME}`. `{{` is special
/// **only** when a well-formed token follows it, so doubled braces anywhere else
/// stay as written; and once `{{` has been recognised the token is never
/// resolved, so a mis-typed closing brace fails towards the literal rather than
/// towards a substitution. Neither upstream has an escape at all.
///
/// ## Divergences from opencode, each deliberate
///
/// - **An unset variable is a hard error naming it.** opencode substitutes the
///   empty string (`process.env[varName] || ""`), which turns one typo in a
///   config file into a 401 from the gateway with nothing anywhere connecting
///   the two. The name is safe to print; the value never is.
/// - **Values are never inserted into JSON text.** opencode splices raw
///   environment values into the document before parsing it — a value containing
///   a quote or a backslash corrupts the file — and JSON-escapes only the
///   `{file:}` case. Resolving into a Swift `String` after decoding cannot have
///   that bug at all.
/// - **Single pass, and substituted text is never re-scanned.** opencode
///   replaces every `{env:}` across the whole document and *then* searches the
///   result for `{file:}`, so an environment variable whose value is
///   `{file:/etc/shadow}` gets that file read and inlined. Here the scanner
///   advances past each substitution and only ever looks at the original input,
///   so a resolved value containing a token stays literal by construction.
/// - **A credential denylist**, checked before the lookup. See
///   ``InterpolationPolicy/deniedEnvironmentNames``.
///
/// ## Diagnostics
///
/// Every failure is a ``ConfigDiagnostic`` whose `problem` names the token, the
/// variable or the path — and **never** a resolved value, a file's contents, or
/// the partially-built output. That is also why `readFile`'s own error text is
/// not reproduced: this module cannot see what a caller's closure puts in its
/// error description, these diagnostics get printed and logged, and the rule is
/// absolute. The path, which is the part that identifies the mistake, is in the
/// message either way.
///
/// - Parameters:
///   - raw: The decoded config value.
///   - policy: Trust for this source file. See ``InterpolationPolicy``.
///   - environment: The environment to read, injected so callers and tests are
///     not at the mercy of the process's own.
///   - baseDirectory: What a relative `{file:}` path is relative to — normally
///     the directory holding the settings file. When it is `nil` a relative path
///     is resolved against `policy.fileRoot` if there is one, and otherwise is
///     handed to `readFile` as written, for it to resolve against the working
///     directory. No tilde expansion is performed here; `~` has no home to
///     expand against in a pure function.
///   - keyPath: Where in the config this value came from, for the diagnostic.
///   - file: The config file's path, for the diagnostic.
///   - readFile: Reads a file's whole contents as text. Injected so this stays
///     pure and headless, and so a caller that needs `O_NOFOLLOW` or an
///     fd-validated scope check has somewhere to put it.
/// - Returns: The resolved value and the values substituted into it.
/// - Throws: ``ConfigDiagnostic`` on a refused, unset or unreadable token.
public func resolveConfigValue(
    _ raw: String,
    policy: InterpolationPolicy,
    environment: [String: String],
    baseDirectory: String?,
    keyPath: [String],
    file: String?,
    readFile: @Sendable (String) throws -> String
) throws(ConfigDiagnostic) -> InterpolationResult {
    // Nothing can be a token without an opening brace, and the overwhelming
    // majority of config values have none.
    guard raw.unicodeScalars.contains("{") else {
        return InterpolationResult(value: raw, substituted: [])
    }

    let scalars = Array(raw.unicodeScalars)
    var output = String.UnicodeScalarView()
    var substituted: [String] = []
    var index = 0

    while index < scalars.count {
        guard scalars[index] == "{" else {
            output.append(scalars[index])
            index += 1
            continue
        }

        // `{{token}}` — emit the token's own text and resolve nothing. The
        // trailing `}` is consumed when present; when it is absent the input was
        // malformed and this still refuses to substitute, which is the safe
        // direction to fail in.
        if index + 1 < scalars.count, scalars[index + 1] == "{",
            let escaped = parseInterpolationToken(scalars, at: index + 1)
        {
            output.append(contentsOf: scalars[(index + 1)..<escaped.end])
            index = escaped.end
            if index < scalars.count, scalars[index] == "}" { index += 1 }
            continue
        }

        guard let token = parseInterpolationToken(scalars, at: index) else {
            output.append(scalars[index])
            index += 1
            continue
        }

        let value = try resolveInterpolationToken(
            token,
            policy: policy,
            environment: environment,
            baseDirectory: baseDirectory,
            keyPath: keyPath,
            file: file,
            readFile: readFile
        )
        // The substituted scalars go straight to the output and `index` jumps
        // past the token: nothing that came out of a resolution is ever looked
        // at again by this loop. That is the whole of the anti-recursion story.
        output.append(contentsOf: value.unicodeScalars)
        substituted.append(value)
        index = token.end
    }

    return InterpolationResult(value: String(output), substituted: substituted)
}

// MARK: - Scanning

/// The two things a token can ask for.
private enum InterpolationTokenKind: String {
    case env
    case file
}

/// A well-formed token found in the input.
private struct InterpolationToken {
    var kind: InterpolationTokenKind
    /// The text between the colon and the closing brace: a variable name or a path.
    var body: String
    /// The index just past the closing brace.
    var end: Int
    /// The token as it was written, for a diagnostic.
    var text: String { "{\(kind.rawValue):\(body)}" }
}

private let environmentKeywordScalars = Array("env:".unicodeScalars)
private let fileKeywordScalars = Array("file:".unicodeScalars)

/// Parse a token starting at `start`, which must be an opening brace.
///
/// Returns `nil` for anything that is not exactly a token, so the caller can
/// copy the brace through as an ordinary character. A body containing `{` or a
/// line break is rejected rather than swallowed: `{file:a` followed by a newline
/// and then a `}` on a later line is a typo, and reading a "path" spanning two
/// lines is a worse answer than leaving the text alone.
private func parseInterpolationToken(
    _ scalars: [Unicode.Scalar],
    at start: Int
) -> InterpolationToken? {
    guard start < scalars.count, scalars[start] == "{" else { return nil }

    var cursor = start + 1
    let kind: InterpolationTokenKind
    if hasScalarPrefix(scalars, at: cursor, environmentKeywordScalars) {
        kind = .env
        cursor += environmentKeywordScalars.count
    } else if hasScalarPrefix(scalars, at: cursor, fileKeywordScalars) {
        kind = .file
        cursor += fileKeywordScalars.count
    } else {
        return nil
    }

    let bodyStart = cursor
    while cursor < scalars.count {
        switch scalars[cursor] {
        case "}":
            guard cursor > bodyStart else { return nil }
            var body = String.UnicodeScalarView()
            body.append(contentsOf: scalars[bodyStart..<cursor])
            return InterpolationToken(kind: kind, body: String(body), end: cursor + 1)
        case "{", "\n", "\r":
            return nil
        default:
            cursor += 1
        }
    }
    return nil
}

private func hasScalarPrefix(
    _ scalars: [Unicode.Scalar],
    at start: Int,
    _ prefix: [Unicode.Scalar]
) -> Bool {
    guard start + prefix.count <= scalars.count else { return false }
    for offset in 0..<prefix.count where scalars[start + offset] != prefix[offset] {
        return false
    }
    return true
}

// MARK: - Token resolution

private func resolveInterpolationToken(
    _ token: InterpolationToken,
    policy: InterpolationPolicy,
    environment: [String: String],
    baseDirectory: String?,
    keyPath: [String],
    file: String?,
    readFile: @Sendable (String) throws -> String
) throws(ConfigDiagnostic) -> String {
    switch token.kind {
    case .env:
        return try resolveEnvironmentToken(
            token,
            policy: policy,
            environment: environment,
            keyPath: keyPath,
            file: file
        )
    case .file:
        return try resolveFileToken(
            token,
            policy: policy,
            baseDirectory: baseDirectory,
            keyPath: keyPath,
            file: file,
            readFile: readFile
        )
    }
}

private func resolveEnvironmentToken(
    _ token: InterpolationToken,
    policy: InterpolationPolicy,
    environment: [String: String],
    keyPath: [String],
    file: String?
) throws(ConfigDiagnostic) -> String {
    let name = token.body

    guard policy.allowEnvironment else {
        throw interpolationDiagnostic(
            "\(token.text) is not allowed here: project configuration may not read "
                + "environment variables",
            keyPath: keyPath,
            file: file
        )
    }

    // Case-insensitive, matching kilocode's `secret.has(name.toUpperCase())`.
    // POSIX environments are case-sensitive, so this refuses a little more than
    // it strictly must; that is the right direction for a credential check.
    let uppercased = name.uppercased()
    if policy.deniedEnvironmentNames.contains(where: { $0.uppercased() == uppercased }) {
        throw interpolationDiagnostic(
            "\(token.text) names a model-gateway credential, which may not be interpolated "
                + "into configuration",
            keyPath: keyPath,
            file: file
        )
    }

    guard let value = environment[name] else {
        throw interpolationDiagnostic(
            "\(token.text) refers to an environment variable that is not set",
            keyPath: keyPath,
            file: file
        )
    }
    return value
}

private func resolveFileToken(
    _ token: InterpolationToken,
    policy: InterpolationPolicy,
    baseDirectory: String?,
    keyPath: [String],
    file: String?,
    readFile: @Sendable (String) throws -> String
) throws(ConfigDiagnostic) -> String {
    let requested = FilePath(token.body)
    var resolved = requested
    if requested.isRelative, let base = baseDirectory ?? policy.fileRoot, !base.isEmpty {
        resolved = FilePath(base).pushing(requested)
    }
    resolved = resolved.lexicallyNormalized()

    if let root = policy.fileRoot {
        let rootPath = FilePath(root).lexicallyNormalized()
        // An empty root would make `starts(with:)` vacuously true and confine
        // nothing at all. A caller that asked for confinement and then supplied
        // no directory has a bug, and answering it with an unrestricted read is
        // the one answer that must not happen.
        guard !rootPath.isEmpty else {
            throw interpolationDiagnostic(
                "\(token.text) cannot be resolved: reads are confined to the project directory, "
                    + "but no project directory was configured",
                keyPath: keyPath,
                file: file
            )
        }
        guard resolved.starts(with: rootPath) else {
            throw interpolationDiagnostic(
                "\(token.text) resolves to \(resolved.string), which is outside the project "
                    + "directory \(rootPath.string)",
                keyPath: keyPath,
                file: file
            )
        }
    }

    let path = resolved.string
    let contents: String
    do {
        contents = try readFile(path)
    } catch {
        throw interpolationDiagnostic(
            "\(token.text) could not be read from \(path)",
            keyPath: keyPath,
            file: file
        )
    }
    return strippingOneTrailingNewline(contents)
}

/// Drop one trailing line break, so `{file:key.txt}` on a file written by an
/// editor that always terminates the last line yields the key and not the key
/// plus a newline — which is the difference between a working `Authorization`
/// header and a puzzling 401.
///
/// Exactly one, and never more: a file whose content genuinely ends in a blank
/// line keeps it. This works on unicode scalars rather than characters because
/// `"\r\n"` is a single `Character`, so `dropLast(2)` on a CRLF-terminated
/// string would eat the last real character too.
private func strippingOneTrailingNewline(_ text: String) -> String {
    var scalars = text.unicodeScalars
    guard scalars.last == "\n" else { return text }
    scalars.removeLast()
    if scalars.last == "\r" { scalars.removeLast() }
    return String(scalars)
}

/// A diagnostic with no source location: interpolation runs on decoded values,
/// long after the byte offsets that would place a caret are gone.
private func interpolationDiagnostic(
    _ problem: String,
    keyPath: [String],
    file: String?
) -> ConfigDiagnostic {
    ConfigDiagnostic(
        file: file,
        location: nil,
        keyPath: keyPath,
        problem: problem,
        excerpt: nil,
        caretColumn: nil
    )
}
