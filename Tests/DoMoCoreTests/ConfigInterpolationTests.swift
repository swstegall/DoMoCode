// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Synchronization
import Testing

import DoMoCore

// MARK: - Fixtures

/// What the injected reader throws. `description` is deliberately attacker-ish in
/// one test: the point is that whatever a caller's closure puts in its error text
/// never reaches a diagnostic.
private struct StubReadFailure: Error, CustomStringConvertible {
    var description: String
}

/// Records every path the resolver actually asked to read.
///
/// It is the only way to assert the *negative* that matters: a refusal must
/// happen before the read, not after it. A confinement check performed on the
/// contents would already have opened the file.
private final class ReadLog: Sendable {
    private let storage = Mutex<[String]>([])

    func record(_ path: String) {
        storage.withLock { $0.append(path) }
    }

    var paths: [String] { storage.withLock { $0 } }
}

/// Calls ``resolveConfigValue`` with a headless reader backed by a dictionary.
private func resolve(
    _ raw: String,
    policy: InterpolationPolicy = .trusted,
    environment: [String: String] = [:],
    baseDirectory: String? = nil,
    files: [String: String] = [:],
    log: ReadLog? = nil,
    readFailure: String? = nil
) throws(ConfigDiagnostic) -> InterpolationResult {
    try resolveConfigValue(
        raw,
        policy: policy,
        environment: environment,
        baseDirectory: baseDirectory,
        keyPath: ["mcpServers", "docs", "environment", "KEY"],
        file: "/proj/.domocode/settings.json",
        readFile: { path in
            log?.record(path)
            if let readFailure {
                throw StubReadFailure(description: readFailure)
            }
            guard let contents = files[path] else {
                throw StubReadFailure(description: "no such file: \(path)")
            }
            return contents
        }
    )
}

// MARK: - Syntax

@Suite("Config interpolation — syntax")
struct ConfigInterpolationSyntaxTests {

    @Test("A value with no brace at all is returned verbatim")
    func noTokens() throws {
        let result = try resolve("claude-opus-4-6", environment: ["A": "x"])
        #expect(result.value == "claude-opus-4-6")
        #expect(result.substituted.isEmpty)
    }

    @Test("{env:NAME} resolves to the injected environment's value")
    func environmentToken() throws {
        let result = try resolve("{env:GATEWAY_URL}", environment: ["GATEWAY_URL": "https://gw"])
        #expect(result.value == "https://gw")
        #expect(result.substituted == ["https://gw"])
    }

    @Test("{file:PATH} resolves to the file's contents")
    func fileToken() throws {
        let result = try resolve(
            "{file:/proj/key.txt}",
            files: ["/proj/key.txt": "sk-file-derived"]
        )
        #expect(result.value == "sk-file-derived")
        #expect(result.substituted == ["sk-file-derived"])
    }

    @Test("Literal text around a token is preserved on both sides")
    func mixedLiteralAndToken() throws {
        let result = try resolve("Bearer {env:TOKEN} v1", environment: ["TOKEN": "abc123"])
        #expect(result.value == "Bearer abc123 v1")
    }

    @Test("Two tokens in one value both resolve, in order")
    func twoTokens() throws {
        let result = try resolve(
            "{env:USER}:{file:/proj/pass.txt}",
            environment: ["USER": "alice"],
            files: ["/proj/pass.txt": "hunter2"]
        )
        #expect(result.value == "alice:hunter2")
        #expect(result.substituted == ["alice", "hunter2"])
    }

    @Test("{{env:NAME}} is an escape and emits the literal token text")
    func escape() throws {
        let result = try resolve("x{{env:FOO}}y", environment: ["FOO": "resolved"])
        #expect(result.value == "x{env:FOO}y")
        #expect(result.substituted.isEmpty)
    }

    @Test("{{file:PATH}} is an escape and reads nothing")
    func escapedFileToken() throws {
        let log = ReadLog()
        let result = try resolve(
            "{{file:/proj/key.txt}}",
            files: ["/proj/key.txt": "sk-file-derived"],
            log: log
        )
        #expect(result.value == "{file:/proj/key.txt}")
        #expect(log.paths.isEmpty)
    }

    @Test("A doubled brace never substitutes, even with the closing brace mistyped")
    func escapeFailsTowardsTheLiteral() throws {
        let result = try resolve("{{env:FOO}", environment: ["FOO": "resolved"])
        #expect(result.value == "{env:FOO}")
        #expect(result.substituted.isEmpty)
    }

    @Test(
        "Braces that do not begin a well-formed token are copied through untouched",
        arguments: [
            "{",
            "}",
            "{}",
            "{env}",
            "{env:}",
            "{ env:A }",
            "{ENV:A}",
            "{FILE:/proj/key.txt}",
            "{notatoken}",
            "a {b} c",
            "{{notatoken}}",
            "{env:A",
            "{env:{A}}",
            #"{"env": "A"}"#,
        ]
    )
    func nonTokens(text: String) throws {
        let result = try resolve(
            text,
            environment: ["A": "SUBSTITUTED", "env": "SUBSTITUTED"],
            files: ["/proj/key.txt": "SUBSTITUTED"]
        )
        #expect(result.value == text)
        #expect(result.substituted.isEmpty)
    }

    @Test("A line break inside a token body ends the candidate rather than being swallowed")
    func newlineInBody() throws {
        let text = "{env:A\nB}"
        let result = try resolve(text, environment: ["A\nB": "SUBSTITUTED"])
        #expect(result.value == text)
    }
}

// MARK: - Environment policy

@Suite("Config interpolation — environment policy")
struct ConfigInterpolationEnvironmentTests {

    @Test("An unset variable is a hard error naming it, not a silent empty string")
    func unsetVariableThrows() throws {
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve("prefix-{env:MISSING_KEY}", environment: ["OTHER": "x"])
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("{env:MISSING_KEY}"))
        #expect(diagnostic.problem.contains("not set"))
    }

    @Test("A denied name is refused even when the policy trusts environment reads")
    func deniedNameUnderTrustingPolicy() throws {
        let policy = InterpolationPolicy(
            allowEnvironment: true,
            fileRoot: nil,
            deniedEnvironmentNames: ["SECRET_NAME"]
        )
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{env:SECRET_NAME}",
                policy: policy,
                environment: ["SECRET_NAME": "super-secret-value-9"]
            )
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("SECRET_NAME"))
        #expect(!diagnostic.problem.contains("super-secret-value-9"))
        #expect(!String(describing: diagnostic).contains("super-secret-value-9"))
    }

    @Test("The denylist is matched case-insensitively")
    func denylistIsCaseInsensitive() throws {
        let policy = InterpolationPolicy(
            allowEnvironment: true,
            fileRoot: nil,
            deniedEnvironmentNames: ["SECRET_NAME"]
        )
        #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{env:secret_name}",
                policy: policy,
                environment: ["secret_name": "super-secret-value-9"]
            )
        }
    }

    @Test("A name that is not on the denylist still resolves under the same policy")
    func denylistDoesNotBlockEverything() throws {
        let policy = InterpolationPolicy(
            allowEnvironment: true,
            fileRoot: nil,
            deniedEnvironmentNames: ["SECRET_NAME"]
        )
        let result = try resolve(
            "{env:SECRET_NAMESPACE}",
            policy: policy,
            environment: ["SECRET_NAMESPACE": "ns"]
        )
        #expect(result.value == "ns")
    }

    @Test("The trusted policy refuses the gateway credential names by default")
    func trustedPolicyDeniesGatewayCredentials() throws {
        #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{env:OPENAI_API_KEY}",
                environment: ["OPENAI_API_KEY": "sk-should-never-be-interpolated"]
            )
        }
    }

    @Test("Untrusted configuration may not read the environment at all")
    func untrustedRefusesEnvironment() throws {
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{env:HOME_GROWN}",
                policy: .untrusted(root: "/proj"),
                environment: ["HOME_GROWN": "innocuous-value"]
            )
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("{env:HOME_GROWN}"))
        #expect(!diagnostic.problem.contains("innocuous-value"))
    }

    @Test("Policy constructors wire the fields the callers depend on")
    func policyDefaults() {
        #expect(InterpolationPolicy.trusted.allowEnvironment)
        #expect(InterpolationPolicy.trusted.fileRoot == nil)
        #expect(InterpolationPolicy.trusted.deniedEnvironmentNames == Redaction.secretEnvironmentNames)
        #expect(Redaction.secretEnvironmentNames.contains("OPENAI_API_KEY"))
        #expect(Redaction.secretEnvironmentNames.contains("DOMOCODE_API_KEY"))
        #expect(Redaction.secretEnvironmentNames.contains("LITELLM_API_KEY"))

        let untrusted = InterpolationPolicy.untrusted(root: "/proj")
        #expect(!untrusted.allowEnvironment)
        #expect(untrusted.fileRoot == "/proj")
    }
}

// MARK: - File policy

@Suite("Config interpolation — file policy")
struct ConfigInterpolationFileTests {

    @Test("A relative path resolves against the base directory")
    func relativeAgainstBaseDirectory() throws {
        let log = ReadLog()
        let result = try resolve(
            "{file:../key.txt}",
            baseDirectory: "/proj/nested",
            files: ["/proj/key.txt": "value"],
            log: log
        )
        #expect(log.paths == ["/proj/key.txt"])
        #expect(result.value == "value")
    }

    @Test("An absolute path ignores the base directory")
    func absoluteIgnoresBaseDirectory() throws {
        let log = ReadLog()
        _ = try resolve(
            "{file:/elsewhere/key.txt}",
            baseDirectory: "/proj",
            files: ["/elsewhere/key.txt": "value"],
            log: log
        )
        #expect(log.paths == ["/elsewhere/key.txt"])
    }

    @Test("With no base directory, a relative path resolves against the confinement root")
    func relativeAgainstRootWithoutBaseDirectory() throws {
        let log = ReadLog()
        let result = try resolve(
            "{file:key.txt}",
            policy: .untrusted(root: "/proj"),
            files: ["/proj/key.txt": "value"],
            log: log
        )
        #expect(log.paths == ["/proj/key.txt"])
        #expect(result.value == "value")
    }

    @Test("A file inside the root is readable under an untrusted policy")
    func insideRootIsAllowed() throws {
        let result = try resolve(
            "{file:secrets/key.txt}",
            policy: .untrusted(root: "/proj"),
            baseDirectory: "/proj",
            files: ["/proj/secrets/key.txt": "value"]
        )
        #expect(result.value == "value")
    }

    @Test("An untrusted policy refuses to escape the root with ..", arguments: [
        "{file:../../etc/passwd}",
        "{file:secrets/../../../etc/passwd}",
        "{file:/etc/passwd}",
        "{file:/proj-elsewhere/key.txt}",
    ])
    func untrustedRefusesEscape(text: String) throws {
        let log = ReadLog()
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                text,
                policy: .untrusted(root: "/proj"),
                baseDirectory: "/proj",
                files: ["/etc/passwd": "root:x:0:0", "/proj-elsewhere/key.txt": "value"],
                log: log
            )
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("outside the project directory"))
        // The refusal has to precede the read; checking the contents would mean
        // the file had already been opened.
        #expect(log.paths.isEmpty)
    }

    @Test("A confinement root that is empty refuses rather than confining nothing")
    func emptyRootRefuses() throws {
        let log = ReadLog()
        let policy = InterpolationPolicy(
            allowEnvironment: false,
            fileRoot: "",
            deniedEnvironmentNames: []
        )
        #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{file:/proj/key.txt}",
                policy: policy,
                files: ["/proj/key.txt": "value"],
                log: log
            )
        }
        #expect(log.paths.isEmpty)
    }

    @Test("An unreadable file is an error naming the path but not the reader's own text")
    func unreadableFile() throws {
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{file:/proj/key.txt}",
                readFailure: "EACCES while reading, buffer so far: partial-key-material"
            )
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("/proj/key.txt"))
        #expect(!diagnostic.problem.contains("partial-key-material"))
        #expect(!String(describing: diagnostic).contains("partial-key-material"))
    }

    @Test("Exactly one trailing line break is stripped from file contents", arguments: [
        ("value\n", "value"),
        ("value\r\n", "value"),
        ("value\n\n", "value\n"),
        ("value", "value"),
        ("value\r", "value\r"),
        ("\n", ""),
        ("  value  \n", "  value  "),
    ])
    func trailingNewline(contents: String, expected: String) throws {
        let result = try resolve("{file:/proj/key.txt}", files: ["/proj/key.txt": contents])
        #expect(result.value == expected)
    }
}

// MARK: - Injection

@Suite("Config interpolation — injection")
struct ConfigInterpolationInjectionTests {

    @Test("A file whose contents are a token stays literal and is not read twice")
    func fileContentsAreNeverRescanned() throws {
        let log = ReadLog()
        let result = try resolve(
            "{file:/proj/note.txt}",
            environment: ["LEAKY": "leaked-value"],
            files: ["/proj/note.txt": "{env:LEAKY}"],
            log: log
        )
        #expect(result.value == "{env:LEAKY}")
        #expect(!result.value.contains("leaked-value"))
        #expect(log.paths == ["/proj/note.txt"])
    }

    @Test("An environment value containing a file token does not cause a read")
    func environmentValuesAreNeverRescanned() throws {
        let log = ReadLog()
        let result = try resolve(
            "{env:HOOK}",
            environment: ["HOOK": "{file:/proj/private.txt}"],
            files: ["/proj/private.txt": "PRIVATE-KEY-MATERIAL"],
            log: log
        )
        #expect(result.value == "{file:/proj/private.txt}")
        #expect(log.paths.isEmpty)
    }

    @Test("A value that resolved before the failing token never reaches the diagnostic")
    func partialOutputIsNotLeaked() throws {
        let thrown = #expect(throws: ConfigDiagnostic.self) {
            try resolve(
                "{file:/proj/key.txt}-{env:ABSENT}",
                environment: [:],
                files: ["/proj/key.txt": "TOP-SECRET-CONTENTS"]
            )
        }
        let diagnostic = try #require(thrown)
        #expect(diagnostic.problem.contains("{env:ABSENT}"))
        #expect(!String(describing: diagnostic).contains("TOP-SECRET-CONTENTS"))
    }

    @Test("Quotes and backslashes in a resolved value survive verbatim")
    func awkwardValuesAreNotEscapedOrTruncated() throws {
        let value = #"a"b\c{d}"#
        let result = try resolve("<{env:AWKWARD}>", environment: ["AWKWARD": value])
        #expect(result.value == "<\(value)>")
        #expect(result.substituted == [value])
    }
}
