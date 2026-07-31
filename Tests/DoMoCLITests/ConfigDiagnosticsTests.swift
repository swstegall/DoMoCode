// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// What `Settings.load` says when a settings.json is wrong, and what it is
// allowed to read while loading one.
//
// Two separate promises are pinned here. The first is that a broken file
// produces a place to look — file, line, column, the offending source line and a
// caret under it — rather than Foundation's "The given data was not valid JSON".
// The second is the trust split: the user's own settings may interpolate the
// environment and any file; a repository's settings may interpolate neither the
// environment nor anything outside the working directory, and the `permission`
// block is never interpolated at all.

import DoMoCLI
import DoMoCore
import DoMoLLM
import Foundation
import SystemPackage
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite
struct ConfigDiagnosticsTests {

    /// Runs `body` with a fresh temporary directory, removed afterwards.
    private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.path)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Structured parse errors

    /// A decode failure has to point at a byte, not describe a shape.
    ///
    /// `JSONDecoder` knows only that a key had the wrong type; the location is
    /// recovered from the bytes by `JSONSourceIndex` and rendered as a caret.
    /// The caret must land on the offending **value**, not on the key.
    @Test
    func aMalformedSettingsFileReportsTheLineAndDrawsACaretUnderTheValue() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write("{\n  \"maxRetries\": \"seven\"\n}\n", to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path)
            }
            let text = try #require(failure?.description)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(lines.count == 3)

            // Header: file:line:column, then the setting, then the problem.
            #expect(lines[0].contains(path))
            #expect(lines[0].contains(":2:"))
            #expect(lines[0].contains("maxRetries"))

            // The excerpt is the offending source line, verbatim.
            #expect(lines[1] == "  \"maxRetries\": \"seven\"")

            // And the caret is spaces then a single `^`, positioned over the
            // value. Computed from the caret line rather than hardcoded, so the
            // two cannot silently drift apart.
            let caret = lines[2]
            #expect(caret.hasSuffix("^"))
            #expect(caret.dropLast().allSatisfy({ $0 == " " }))
            #expect(String(lines[1].dropFirst(caret.count - 1)).hasPrefix("\"seven\""))
        }
    }

    /// The diagnostic survives being carried as a `DoMoError` cause, which is the
    /// only way it ever reaches a terminal.
    @Test
    func theDiagnosticIsCarriedAsTheErrorsCauseWithAConfigurationKind() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write("{ \"model\": }", to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path)
            }
            let caught = try #require(failure)
            #expect(caught.kind == .configuration)
            #expect(caught.cause as? ConfigDiagnostic != nil)
            // The outer message names the file; the chain adds the position.
            #expect(caught.message.contains("settings.json"))
            #expect(caught.description.count > caught.message.count)
        }
    }

    // MARK: Absent versus unreadable

    @Test
    func anAbsentSettingsFileIsStillNil() throws {
        try withTemporaryDirectory { directory in
            let absent = try Settings.load(fromPath: directory + "/settings.json")
            #expect(absent == nil)
            // A missing intermediate directory is still just "no settings here".
            let nested = try Settings.load(fromPath: directory + "/nope/settings.json")
            #expect(nested == nil)
        }
    }

    /// An unreadable settings.json used to take the same silent `nil` path as an
    /// absent one, so a file at mode 000 simply vanished — taking the model, the
    /// gateway URL and the permission grants with it, and reporting nothing.
    @Test
    func anUnreadableSettingsFileIsNotSilentlyTreatedAsAbsent() throws {
        // root reads a mode-000 file regardless, so there is nothing to observe.
        guard getuid() != 0 else { return }
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(#"{"model":"m"}"#, to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path)
            }
            let caught = try #require(failure)
            // A file error, not a configuration one: nothing is wrong with the
            // settings, the bytes could not be read.
            guard case .file(_, let errno) = caught.kind else {
                Issue.record("expected a file error, got \(caught.kind)")
                return
            }
            #expect(errno == Errno.permissionDenied)
            #expect(caught.description.contains(path))
        }
    }

    // MARK: Interpolation — the trust split

    @Test
    func userSettingsMayInterpolateTheEnvironment() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(#"{"baseUrl": "http://{env:MY_GATEWAY_HOST}:4000/v1"}"#, to: path)

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_GATEWAY_HOST": "gateway.internal"]
                )
            )
            #expect(settings.baseURL == "http://gateway.internal:4000/v1")
        }
    }

    /// A repository's settings.json arrives with whatever was cloned, so it may
    /// not read the environment at all — there is no scoped form of "read one
    /// variable" that stays safe once the value can reach the network.
    @Test
    func projectSettingsMayNotReadTheEnvironmentAndTheDiagnosticNeverShowsTheValue() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(#"{"baseUrl": "http://{env:MY_GATEWAY_HOST}:4000/v1"}"#, to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(
                    fromPath: path,
                    interpolation: .untrusted(root: directory),
                    environment: ["MY_GATEWAY_HOST": "gateway.internal"]
                )
            }
            let text = try #require(failure?.description)
            #expect(text.contains("{env:MY_GATEWAY_HOST}"))
            #expect(text.contains("baseUrl"))
            // The token is named; the value it would have produced never is.
            #expect(!text.contains("gateway.internal"))
        }
    }

    /// `{file:}` under a project policy is confined to the working directory,
    /// and the refusal must not quote the file it declined to read.
    @Test
    func projectFileReadsAreConfinedToTheWorkingDirectory() throws {
        try withTemporaryDirectory { directory in
            let root = directory + "/project"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let path = root + "/settings.json"
            try write("Token-that-is-not-yours\n", to: directory + "/outside.txt")
            try write(#"{"authScheme": "{file:../outside.txt}"}"#, to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path, interpolation: .untrusted(root: root))
            }
            let text = try #require(failure?.description)
            #expect(text.contains("outside the project directory"))
            #expect(!text.contains("Token-that-is-not-yours"))

            // The user's own settings may read it — and exactly one trailing
            // newline is stripped, which is the difference between a working
            // header and a puzzling 401.
            let trusted = try #require(
                try Settings.load(fromPath: path, interpolation: .trusted)
            )
            #expect(trusted.authScheme == "Token-that-is-not-yours")
        }
    }

    /// An unset variable is a hard error naming it, not the empty string.
    ///
    /// Substituting `""` — which is what opencode does — turns one typo in a
    /// config file into a 401 from the gateway with nothing connecting the two.
    @Test
    func anUnsetVariableIsAHardErrorNamingIt() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(#"{"model": "{env:MY_MISSING_MODEL_VAR}"}"#, to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path, interpolation: .trusted, environment: [:])
            }
            let text = try #require(failure?.description)
            #expect(text.contains("{env:MY_MISSING_MODEL_VAR}"))
            #expect(text.contains("not set"))
        }
    }

    // MARK: Interpolation — what it reaches

    /// `mcpServers.*.environment` is the case the feature exists for: a server's
    /// token can be configured without the token being written down. The **keys**
    /// stay literal, because a variable name is not a secret and resolving keys
    /// would let one token silently rename another.
    @Test
    func mcpServerCommandEnvironmentValuesAndCwdAreResolvedButKeysAreNot() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(
                """
                {"mcpServers": {"gh": {
                  "command": ["mcp-{env:MY_SERVER_SUFFIX}", "--stdio"],
                  "environment": {"TOKEN": "{env:MY_MCP_TOKEN}", "{env:MY_MCP_TOKEN}": "literal"},
                  "cwd": "{env:MY_SERVER_CWD}"
                }}}
                """,
                to: path
            )
            let environment = [
                "MY_SERVER_SUFFIX": "github",
                "MY_MCP_TOKEN": "tok-abcdefghijklmnop",
                "MY_SERVER_CWD": "/srv/gh",
            ]

            let settings = try #require(
                try Settings.load(fromPath: path, interpolation: .trusted, environment: environment)
            )
            let server = try #require(settings.mcpServers?["gh"])
            #expect(server.command == ["mcp-github", "--stdio"])
            #expect(server.cwd == "/srv/gh")
            #expect(server.environment?["TOKEN"] == "tok-abcdefghijklmnop")

            // The key is exactly the text that was written.
            #expect(server.environment?["{env:MY_MCP_TOKEN}"] == "literal")
            #expect(server.environment?["tok-abcdefghijklmnop"] == nil)
        }
    }

    /// The `permission` block is never interpolated.
    ///
    /// It is not a field of `Settings` at all — a separate order-preserving
    /// parser reads it straight off the file text — and leaving it literal is
    /// what stops `{env:}` from becoming a permission-widening vector.
    ///
    /// The load *succeeding* is the load-bearing assertion: an unset variable is
    /// a hard error, so a pass that walked the whole document would throw here.
    @Test
    func thePermissionBlockIsNeverInterpolated() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let token = "{env:DEFINITELY_NOT_SET_PERMISSION_VAR}"
            try write(
                #"{"model": "m", "permission": {"bash": {"\#(token)": "allow"}}}"#,
                to: path
            )

            let settings = try #require(
                try Settings.load(fromPath: path, interpolation: .trusted, environment: [:])
            )
            #expect(settings.model == "m")

            // And the bytes the permission parser will later read are untouched.
            let onDisk = try String(contentsOfFile: path, encoding: .utf8)
            #expect(onDisk.contains(token))
        }
    }

    /// Whatever a user kept out of their config file is exactly what must never
    /// appear in a diagnostic or a log line, so every substituted value is
    /// registered with the redaction vault as it is resolved.
    @Test
    func anInterpolatedSecretIsRegisteredForRedaction() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let secret = "interpolated-9f3a2b7c-do-not-print"
            try write(#"{"authScheme": "{env:MY_TEST_SCHEME_SECRET}"}"#, to: path)

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_TEST_SCHEME_SECRET": secret]
                )
            )
            #expect(settings.authScheme == secret)
            #expect(
                Redaction.diagnostic("scheme was \(secret) here")
                    == "scheme was \(Redaction.placeholder) here"
            )
        }
    }

    /// The other half of the rule, and the one that actually bit: a value
    /// interpolated into a key that is *not* a credential must NOT be
    /// registered.
    ///
    /// Registering every substituted value looked like the cautious choice and
    /// was not. A `baseUrl` built from `{env:MY_GATEWAY_HOST}` registered the
    /// hostname, and every later connection failure then read
    /// `connect to https://[redacted]@[redacted] failed` — destroying the one
    /// fact the URL-userinfo rule deliberately preserves. Over-redaction is a
    /// diagnostic bug, not a safe default.
    @Test
    func anInterpolatedHostIsNotTreatedAsASecret() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let host = "gateway-4d1e8a02.example.invalid"
            try write(#"{"baseUrl": "https://{env:MY_TEST_GATEWAY_HOST}/v1"}"#, to: path)

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_TEST_GATEWAY_HOST": host]
                )
            )
            #expect(settings.baseURL == "https://\(host)/v1")
            // Unchanged, byte for byte: nothing about a hostname is redactable.
            let sentence = "connect to https://\(host)/v1 failed"
            #expect(Redaction.diagnostic(sentence) == sentence)
        }
    }

    /// Interpolation is off unless a policy is supplied, so a caller that only
    /// wants to inspect a file does not have to invent an environment.
    @Test
    func withoutAPolicyEveryTokenStaysLiteral() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            try write(#"{"model": "{env:MY_MISSING_MODEL_VAR}"}"#, to: path)
            let settings = try #require(try Settings.load(fromPath: path))
            #expect(settings.model == "{env:MY_MISSING_MODEL_VAR}")
        }
    }

    // MARK: End to end

    /// The two files are loaded under different policies, which is the whole
    /// trust model in one assertion pair: the same token resolves in the user's
    /// settings and is refused in the project's.
    @Test
    func theUserFileIsTrustedAndTheProjectFileIsNot() throws {
        try withTemporaryDirectory { directory in
            let configDirectory = directory + "/config"
            let workingDirectory = directory + "/work"
            try FileManager.default.createDirectory(
                atPath: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: workingDirectory + "/.domocode", withIntermediateDirectories: true)

            try write(#"{"model": "{env:MY_USER_MODEL}"}"#, to: configDirectory + "/settings.json")
            try write(
                #"{"smallModel": "small-fixed"}"#,
                to: workingDirectory + "/.domocode/settings.json"
            )

            let environment = [
                EnvName.configDir: configDirectory,
                "MY_USER_MODEL": "big-model",
            ]
            let config = try ResolvedConfiguration.load(
                cli: CLIOverrides(),
                environment: environment,
                workingDirectory: FilePath(workingDirectory)
            )
            #expect(config.model == "big-model")
            #expect(config.smallModel == "small-fixed")

            // The identical token in the project file is refused.
            try write(
                #"{"smallModel": "{env:MY_USER_MODEL}"}"#,
                to: workingDirectory + "/.domocode/settings.json"
            )
            let failure = #expect(throws: DoMoError.self) {
                try ResolvedConfiguration.load(
                    cli: CLIOverrides(),
                    environment: environment,
                    workingDirectory: FilePath(workingDirectory)
                )
            }
            let refusal = try #require(failure?.description)
            #expect(refusal.contains("may not read"))
        }
    }
}
