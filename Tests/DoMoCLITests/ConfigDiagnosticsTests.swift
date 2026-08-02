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
import Synchronization
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
            // The file is named ONCE, by the diagnostic, and the outer message
            // does not repeat it. It used to, and the rendered error then opened
            // with the same long path twice before saying anything.
            #expect(!caught.message.contains("settings.json"))
            #expect(caught.description.contains("settings.json"))
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

    /// The lexical check is not the confinement, and a cloned repository can
    /// prove it: `.domocode/looks-local.key -> ~/.ssh/id_rsa` names nothing
    /// outside the project, collapses to nothing outside the project, and the
    /// kernel walks straight out of it.
    ///
    /// So the refusal has to happen where the file is opened, and it has to
    /// happen *before* the open — a reader that raises after slurping the bytes
    /// has already put them in this process's memory and one careless
    /// `\(error)` away from a log line.
    @Test
    func aSymlinkPlantedInsideTheProjectMayNotReachOutsideIt() throws {
        try withTemporaryDirectory { directory in
            let root = directory + "/project"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let secret = "id-rsa-body-4b8c1e7a-do-not-print"
            try write(secret + "\n", to: directory + "/outside.key")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/looks-local.key",
                withDestinationPath: directory + "/outside.key"
            )

            let path = root + "/settings.json"
            try write(#"{"model": "{file:looks-local.key}"}"#, to: path)

            let failure = #expect(throws: DoMoError.self) {
                try Settings.load(fromPath: path, interpolation: .untrusted(root: root))
            }
            let text = try #require(failure?.description)
            #expect(text.contains("{file:looks-local.key}"))
            // The token is named. What it pointed at never is.
            #expect(!text.contains(secret))

            // And nothing was read: the injected reader — which is confined too,
            // because a caller must not be able to opt out of the confinement it
            // asked for — is never called at all.
            let attempted = Mutex<[String]>([])
            #expect(throws: ConfigDiagnostic.self) {
                _ = try Settings(model: "{file:looks-local.key}").resolvingInterpolations(
                    policy: .untrusted(root: root),
                    environment: [:],
                    baseDirectory: root,
                    file: path,
                    readFile: { requested in
                        attempted.withLock { $0.append(requested) }
                        return secret
                    }
                )
            }
            #expect(attempted.withLock { $0 }.isEmpty)
        }
    }

    /// The other half of that rule, and the half a careless fix welds shut.
    ///
    /// Confinement is on the *resolved* location, not on "is a symlink": a link
    /// inside the project pointing at another file inside the project never
    /// leaves, and refusing it would break a repository that keeps its config
    /// fragments behind links. And a trusted policy has no root at all, so the
    /// user's own `{file:~/.gateway-key}` still follows wherever it points.
    @Test
    func aSymlinkThatStaysInsideTheProjectIsStillReadAndATrustedPolicyIsStillUnconfined() throws {
        try withTemporaryDirectory { directory in
            let root = directory + "/project"
            try FileManager.default.createDirectory(
                atPath: root + "/secrets", withIntermediateDirectories: true)
            try write("in-project-token\n", to: root + "/secrets/real.key")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/link.key", withDestinationPath: root + "/secrets/real.key")

            let path = root + "/settings.json"
            try write(#"{"model": "{file:link.key}"}"#, to: path)
            let confined = try #require(
                try Settings.load(fromPath: path, interpolation: .untrusted(root: root))
            )
            #expect(confined.model == "in-project-token")

            // A link out of the project, read under the user's own policy.
            try write("outside-token\n", to: directory + "/outside.key")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/escape.key", withDestinationPath: directory + "/outside.key")
            try write(#"{"model": "{file:escape.key}"}"#, to: path)
            let trusted = try #require(
                try Settings.load(fromPath: path, interpolation: .trusted)
            )
            #expect(trusted.model == "outside-token")
        }
    }

    /// The half the first confinement fix left wide open.
    ///
    /// That fix resolved with `URL.resolvingSymlinksInPath()`, which follows a
    /// link only when its target **exists**. A link inside the project pointing
    /// at a file that is not there yet came back as the link's *own* in-project
    /// path, confinement agreed it was inside, and the read then followed the
    /// link out of the root the instant the target appeared. Same for any leaf
    /// under a directory link, whether or not the directory itself exists.
    ///
    /// Both cases are driven through an *injected* reader on purpose. With the
    /// real reader a dangling link fails either way — refused, or opened and
    /// `ENOENT` — and it was exactly that shared failure that hid the hole: the
    /// question is not "did the load fail" but "was a path outside the root ever
    /// handed to the thing that opens files".
    @Test
    func aDanglingLinkAndAMissingLeafUnderADirectoryLinkAreBothRefused() throws {
        try withTemporaryDirectory { directory in
            let root = directory + "/project"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: directory + "/outside", withIntermediateDirectories: true)

            // A link inside the project at a file outside it that does not exist
            // yet — the attacker's half of the trick is creating it afterwards.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/dangling.key",
                withDestinationPath: directory + "/outside/appears-later.key"
            )
            // A link inside the project at a directory outside it, read through
            // for a leaf that does not exist yet.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/dirlink", withDestinationPath: directory + "/outside"
            )
            // The same, with the directory itself missing: resolution must not
            // depend on any part of the target existing.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/gonelink", withDestinationPath: directory + "/not-there-yet"
            )

            let settingsPath = root + "/settings.json"
            let planted = "PWNED-SECRET-9f3a2c17"
            let tokens = [
                "{file:dangling.key}",
                "{file:dirlink/later.key}",
                "{file:gonelink/later.key}",
            ]

            for token in tokens {
                let handed = Mutex<[String]>([])
                #expect(throws: ConfigDiagnostic.self, "\(token) must be refused") {
                    _ = try Settings(model: token).resolvingInterpolations(
                        policy: .untrusted(root: root),
                        environment: [:],
                        baseDirectory: root,
                        file: settingsPath,
                        readFile: { requested in
                            handed.withLock { $0.append(requested) }
                            return planted
                        }
                    )
                }
                // Before the fix this held `<root>/dangling.key` — a path that
                // reads as inside the project and names a file outside it.
                #expect(handed.withLock { $0 }.isEmpty, "\(token) reached the reader")
            }
        }
    }

    /// The rest of the matrix, in one place, so a fix that welds the check shut
    /// fails here rather than in somebody's repository.
    ///
    /// A chain out, a chain out whose end does not exist, and a relative link
    /// out are all refused; a link that stays inside the project is still read.
    @Test
    func chainedAndRelativeLinksOutAreRefusedWhileAnInProjectLinkIsStillRead() throws {
        try withTemporaryDirectory { directory in
            let root = directory + "/project"
            try FileManager.default.createDirectory(
                atPath: root + "/secrets", withIntermediateDirectories: true)
            try write("outside-body\n", to: directory + "/outside.key")

            // hop1 -> hop2 -> <outside>/outside.key, which exists.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/hop2.key", withDestinationPath: directory + "/outside.key")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/hop1.key", withDestinationPath: root + "/hop2.key")
            // The same chain ending on a file that does not exist.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/hopgone.key",
                withDestinationPath: directory + "/outside/never.key"
            )
            try FileManager.default.createSymbolicLink(
                atPath: root + "/chain-gone.key", withDestinationPath: root + "/hopgone.key")
            // A relative target, which names nothing outside the project as text.
            try FileManager.default.createSymbolicLink(
                atPath: root + "/relative.key", withDestinationPath: "../outside.key")

            let settingsPath = root + "/settings.json"
            let tokens = [
                "{file:hop1.key}", "{file:chain-gone.key}", "{file:relative.key}",
            ]
            for token in tokens {
                let handed = Mutex<[String]>([])
                #expect(throws: ConfigDiagnostic.self, "\(token) must be refused") {
                    _ = try Settings(model: token).resolvingInterpolations(
                        policy: .untrusted(root: root),
                        environment: [:],
                        baseDirectory: root,
                        file: settingsPath,
                        readFile: { requested in
                            handed.withLock { $0.append(requested) }
                            return "should-never-be-read"
                        }
                    )
                }
                #expect(handed.withLock { $0 }.isEmpty, "\(token) reached the reader")
            }

            // And the other direction, which is the half a blunt fix breaks: a
            // link that stays inside the project is still followed and read.
            try write("in-project-token\n", to: root + "/secrets/real.key")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/inside.key", withDestinationPath: root + "/secrets/real.key")
            try write(#"{"model": "{file:inside.key}"}"#, to: settingsPath)
            let confined = try #require(
                try Settings.load(fromPath: settingsPath, interpolation: .untrusted(root: root))
            )
            #expect(confined.model == "in-project-token")
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
    /// appear in a diagnostic or a log line, so a value substituted into a slot
    /// that genuinely holds a credential is registered with the redaction vault
    /// as it is resolved.
    ///
    /// `mcpServers.*.environment` is that slot: the block exists to hand secrets
    /// to a child process, so every value in it qualifies regardless of the name
    /// it was given — a name filter would miss the one a user spelled `GH_PAT`.
    @Test
    func anInterpolatedSecretIsRegisteredForRedaction() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let secret = "interpolated-9f3a2b7c-do-not-print"
            try write(
                #"{"mcpServers": {"gh": {"command": ["gh-mcp"], "environment": {"GH_PAT": "{env:MY_TEST_MCP_SECRET}"}}}}"#,
                to: path
            )

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_TEST_MCP_SECRET": secret]
                )
            )
            #expect(settings.mcpServers?["gh"]?.environment?["GH_PAT"] == secret)
            #expect(
                Redaction.diagnostic("spawn failed with \(secret) set")
                    == "spawn failed with \(Redaction.placeholder) set"
            )
        }
    }

    /// The same secret, spelled as a command argument instead of an environment
    /// variable, has to be registered too.
    ///
    /// It used not to be, and the asymmetry was the whole bug: `--token=…` is
    /// the case ``Settings``' own doc comment argues for, and an unregistered
    /// one goes verbatim into the spawn-failure line that quotes the argv while
    /// the identical value under `environment` is masked.
    @Test
    func aSecretInterpolatedIntoAnMCPCommandArgumentIsRegisteredToo() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let secret = "argv-secret-51c7d0e9-do-not-print"
            try write(
                #"{"mcpServers": {"gh": {"command": ["gh-mcp", "--token={env:MY_TEST_ARG_SECRET}"]}}}"#,
                to: path
            )

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_TEST_ARG_SECRET": secret]
                )
            )
            #expect(settings.mcpServers?["gh"]?.command == ["gh-mcp", "--token=\(secret)"])
            #expect(
                Redaction.diagnostic("could not spawn gh-mcp --token=\(secret)")
                    == "could not spawn gh-mcp --token=\(Redaction.placeholder)"
            )
        }
    }

    /// `authHeader` holds a header **name**, and registering a name as a secret
    /// literal does not hide a credential — it uncovers one.
    ///
    /// The literal registry runs before the pattern rules, so a registered
    /// `X-Gateway-Authorization` is rewritten to `[redacted]` first, and the
    /// header-line rule — which recognises the line by exactly that name and
    /// eats the value after the colon — then matches nothing. The name was
    /// hidden and the credential beside it was printed. `authScheme` (`Bearer`)
    /// is the same mistake one field over.
    @Test
    func aHeaderNameAndSchemeAreNeverRegisteredAsSecrets() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let headerName = "X-Gateway-Authorization"
            try write(
                #"{"authHeader": "{env:MY_TEST_HEADER_NAME}", "authScheme": "{env:MY_TEST_SCHEME}"}"#,
                to: path
            )

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: [
                        "MY_TEST_HEADER_NAME": headerName,
                        "MY_TEST_SCHEME": "Gateway-Signature-V4",
                    ]
                )
            )
            #expect(settings.authHeader == headerName)
            #expect(settings.authScheme == "Gateway-Signature-V4")

            // The value is one no pattern rule recognises on its own, so the
            // header-line rule is the only thing standing between it and the
            // log — and it only fires while the header name is still readable.
            let credential = "QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
            let line = "\(headerName): \(credential)"
            let scrubbed = Redaction.diagnostic(line)
            #expect(!scrubbed.contains(credential))
            #expect(scrubbed == "\(headerName): \(Redaction.placeholder)")

            // And the scheme word survives too: "which scheme did I send?" is a
            // fact an auth failure needs, not a secret.
            #expect(
                Redaction.diagnostic("sent Gateway-Signature-V4 to the gateway")
                    == "sent Gateway-Signature-V4 to the gateway"
            )
        }
    }

    /// `apiKeyEnv` is the third name-not-value field, and the one whose spelling
    /// makes `isSecretKeyName` say yes: `apikeyenv` contains `apikey`.
    ///
    /// It holds the name of an environment variable, never its contents, and
    /// registering it scrubs that name out of the "which credential did I use?"
    /// hint an auth failure most needs.
    @Test
    func theNameOfTheAPIKeyVariableIsNotItselfASecret() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            let variable = "ACME_GATEWAY_CREDENTIAL"
            try write(#"{"apiKeyEnv": "{env:MY_TEST_KEY_VARIABLE_NAME}"}"#, to: path)

            let settings = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["MY_TEST_KEY_VARIABLE_NAME": variable]
                )
            )
            #expect(settings.apiKeyEnv == variable)
            let hint = "no key found; set \(variable)"
            #expect(Redaction.diagnostic(hint) == hint)
        }
    }

    /// Every field the resolver claims to interpolate, proved one at a time.
    ///
    /// Five of these lines used to survive deletion with the whole suite green,
    /// which is how `authHeader` came to be interpolated by a line nothing
    /// tested. A table is the only shape that cannot rot that way: adding a
    /// field to the resolver without adding it here leaves the new field
    /// untested, but it can no longer *silently* break an old one.
    @Test
    func everyInterpolatableSettingsFieldIsActuallyInterpolated() throws {
        let reads: [(key: String, value: (Settings) -> String?)] = [
            ("baseUrl", { $0.baseURL }),
            ("model", { $0.model }),
            ("smallModel", { $0.smallModel }),
            ("authHeader", { $0.authHeader }),
            ("authScheme", { $0.authScheme }),
            ("reasoningEffort", { $0.reasoningEffort }),
            ("logLevel", { $0.logLevel }),
            ("sessionDir", { $0.sessionDir }),
            ("apiKeyEnv", { $0.apiKeyEnv }),
        ]

        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            for field in reads {
                try write(#"{"\#(field.key)": "{env:PROBE}-\#(field.key)"}"#, to: path)
                let settings = try #require(
                    try Settings.load(
                        fromPath: path,
                        interpolation: .trusted,
                        environment: ["PROBE": "probe-8e21"]
                    )
                )
                // The expected string names the field, so a failure says which.
                #expect(field.value(settings) == "probe-8e21-\(field.key)")
            }

            // The three nested ones, in one file: command argument, environment
            // value, and cwd.
            try write(
                """
                {"mcpServers": {"gh": {
                  "command": ["gh-mcp", "--flag={env:PROBE}-command"],
                  "environment": {"K": "{env:PROBE}-environment"},
                  "cwd": "{env:PROBE}-cwd"
                }}}
                """,
                to: path
            )
            let nested = try #require(
                try Settings.load(
                    fromPath: path,
                    interpolation: .trusted,
                    environment: ["PROBE": "probe-8e21"]
                )
            )
            let server = try #require(nested.mcpServers?["gh"])
            #expect(server.command == ["gh-mcp", "--flag=probe-8e21-command"])
            #expect(server.environment?["K"] == "probe-8e21-environment")
            #expect(server.cwd == "probe-8e21-cwd")
        }
    }

    /// Two broken servers, and the same one is always the one reported.
    ///
    /// `servers.keys.sorted()` carries a comment promising exactly this and
    /// nothing tested it. Dictionary iteration order is seeded per process, so
    /// a single pair would let an unsorted resolver pass half the time; twenty
    /// independent pairs make that a one-in-a-million accident instead.
    @Test
    func theBrokenMCPTokenReportedIsAlwaysTheAlphabeticallyFirstServer() throws {
        try withTemporaryDirectory { directory in
            let path = directory + "/settings.json"
            for round in 0..<20 {
                // "alpha-n" sorts before "zeta-n"; which one a Dictionary hands
                // back first is anybody's guess.
                try write(
                    """
                    {"mcpServers": {
                      "zeta-\(round)": {"command": ["z", "{env:MY_MISSING_Z_\(round)}"]},
                      "alpha-\(round)": {"command": ["a", "{env:MY_MISSING_A_\(round)}"]}
                    }}
                    """,
                    to: path
                )
                let failure = #expect(throws: DoMoError.self) {
                    try Settings.load(fromPath: path, interpolation: .trusted, environment: [:])
                }
                let text = try #require(failure?.description)
                #expect(text.contains("MY_MISSING_A_\(round)"))
                #expect(!text.contains("MY_MISSING_Z_\(round)"))
            }
        }
    }

    /// A rejected `logLevel` is quoted back so the user can see their typo — but
    /// `logLevel` is one of the interpolated fields, so "the value" can be
    /// whatever `{env:}` produced. The rule that a config diagnostic never
    /// prints a resolved value is only absolute if this layer keeps it too.
    @Test
    func anUnparseableLogLevelIsNotEchoedBackInFull() throws {
        try withTemporaryDirectory { directory in
            let configDirectory = directory + "/config"
            let workingDirectory = directory + "/work"
            try FileManager.default.createDirectory(
                atPath: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: workingDirectory, withIntermediateDirectories: true)

            let secret = "verbose-6d0b4a1f2c8e-do-not-print"
            try write(
                #"{"logLevel": "{env:MY_TEST_LOG_LEVEL}"}"#, to: configDirectory + "/settings.json")

            let config = try ResolvedConfiguration.load(
                cli: CLIOverrides(),
                environment: [
                    EnvName.configDir: configDirectory,
                    "MY_TEST_LOG_LEVEL": secret,
                ],
                workingDirectory: FilePath(workingDirectory)
            )
            let warning = try #require(config.warnings.first)
            #expect(!warning.contains(secret))
            // Not even a PREFIX of it. The value is measured, not quoted: the
            // scrub only replaces what the vault was told about, and `logLevel`
            // is not a credential-shaped key, so nothing registered this value
            // and a surviving prefix would be a surviving prefix of a secret.
            #expect(!warning.contains(secret.prefix(8)))
            #expect(warning.contains("\(secret.count)-character value"))
            #expect(warning.contains("user settings.json"))

            // A real typo is short and survives whole: the warning has to stay
            // useful, or hiding the value is just a different way of saying
            // nothing.
            let plain = try ResolvedConfiguration.resolve(
                cli: CLIOverrides(),
                environment: [:],
                project: nil,
                user: Settings(logLevel: "verbose")
            )
            let typo = try #require(plain.warnings.first)
            #expect(typo.contains("\"verbose\""))
        }
    }

    /// The boundary itself, which is where the previous fix went wrong.
    ///
    /// The cut was twelve characters while the longest level name — `critical` —
    /// is eight, so a nine-to-twelve-character value was quoted back to stderr
    /// whole. The tests meant to pin this used a 21- and a 33-character value:
    /// both far past twelve, so both passed against a limit that was wrong by
    /// four characters. A boundary is only tested from both sides of it.
    ///
    /// `logLevel` is an interpolated field, so "the value" can be whatever
    /// `{env:}` produced, and the scrub only replaces what the vault was told
    /// about — which for a key that is not credential-shaped is nothing.
    @Test
    func aRejectedLogLevelIsQuotedOnlyUpToTheLongestLevelName() throws {
        // Eight characters: exactly the limit, and exactly the kind of typo the
        // warning exists to show a user. Hiding this one would make the warning
        // a more elaborate way of saying nothing.
        let atLimit = try ResolvedConfiguration.resolve(
            cli: CLIOverrides(),
            environment: [:],
            project: nil,
            user: Settings(logLevel: "criticel")
        )
        let quoted = try #require(atLimit.warnings.first)
        #expect(quoted.contains("\"criticel\""))

        // Nine: one character past anything that could ever name a level, so it
        // is measured and never shown — not even the eight-character prefix the
        // old limit would have let through.
        let overLimit = try ResolvedConfiguration.resolve(
            cli: CLIOverrides(),
            environment: [:],
            project: nil,
            user: Settings(logLevel: "criticall")
        )
        let measured = try #require(overLimit.warnings.first)
        #expect(measured.contains("a 9-character value"))
        #expect(!measured.contains("criticall"))
        #expect(!measured.contains("critical"))
        #expect(measured.contains("logLevel in the user settings.json"))
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
