// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `bash` is a tool the MODEL drives. While `ToolContext.environment` defaulted
// to a plain inherited environment, a model that ran `env` — or `printenv
// DOMOCODE_API_KEY`, or a `curl` it composed itself — read the gateway
// credential straight out of the child and got it back as tool OUTPUT. Tool
// output is deliberately never redacted (it is conversation state, replayed
// verbatim into the next request; rewriting it corrupts a resume), so the only
// place to stop that is before the subprocess can see the variable at all.
//
// The claim these tests hold up is made of two halves, and neither is
// sufficient alone:
//
//  1. The DEFAULT context marks exactly the credential variables for removal —
//     "exactly" in both directions, since a scrub that also dropped `PATH` or
//     `HOME` would break every build command a user asks about.
//  2. A variable actually present in this process and named in that map really
//     does disappear from the child, while its neighbour survives.
//
// The second half is exercised through `alsoUnsetting:` with a name unique to
// this file rather than through `DOMOCODE_API_KEY` itself. Setting a real
// credential name in this process's environment would leak into the CLI tests,
// which spawn `domo` with a copy of it — and `alsoUnsetting:` is the same code
// path (one loop over the union), as well as being the CLI's route for a
// deployment whose key lives under a custom `apiKeyEnv` name.

import DoMoCore
import DoMoExec
import DoMoTools
import Foundation
import SystemPackage
import Testing

// MARK: - Fixtures

/// Names unique to this file, so setting them process-wide cannot perturb
/// another target's tests the way a real credential name would.
private let fakeCredentialName = "DOMO_TOOLENV_FAKE_CREDENTIAL"
private let ordinaryName = "DOMO_TOOLENV_ORDINARY"

/// A tool context rooted at a fresh temp directory, with an environment of the
/// caller's choosing. `ToolFixture` always takes the default, which is exactly
/// what the first half of these tests is about.
private func makeContext(environment: ShellEnvironment) async throws -> (ToolContext, URL) {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("domotools-env-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let context = try await ToolContext.rooted(
        at: FilePath(base.path),
        shell: try SubprocessShell(),
        environment: environment
    )
    return (context, base)
}

// MARK: - What the default asks for

@Suite("Tool environment — the default scrub")
struct ToolEnvironmentDefaultTests {

    @Test("A default ToolContext marks every gateway credential variable for removal")
    func defaultUnsetsCredentialNames() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let overrides = fixture.context.environment.overrides

        for name in Redaction.secretEnvironmentNames {
            // Present-with-a-nil-value is what `ShellEnvironment` reads as
            // "unset this". An ABSENT key would scrub nothing, so the fallback
            // here has to be a non-nil string for the assertion to be able to
            // tell the two apart.
            #expect((overrides[name] ?? "still inherited") == nil, "\(name) was not unset")
        }
        #expect(!Redaction.secretEnvironmentNames.isEmpty)
    }

    @Test("Nothing but the credential variables is disturbed")
    func defaultDisturbsNothingElse() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        // Still an INHERITED base — a tool with no PATH, no HOME and no LANG
        // cannot run the build the user asked about, and that is not a security
        // win.
        #expect(fixture.context.environment.base == .inherited)
        #expect(Set(fixture.context.environment.overrides.keys) == Redaction.secretEnvironmentNames)
    }

    @Test("A caller can name more variables to unset, and the defaults stay")
    func callerCanAddNames() {
        let environment = ToolContext.scrubbedEnvironment(
            alsoUnsetting: ["ACME_GATEWAY_TOKEN", "ACME_SECONDARY_TOKEN"]
        )

        #expect(environment.base == .inherited)
        #expect(
            Set(environment.overrides.keys)
                == Redaction.secretEnvironmentNames.union(["ACME_GATEWAY_TOKEN", "ACME_SECONDARY_TOKEN"])
        )
        for name in Set(environment.overrides.keys) {
            #expect((environment.overrides[name] ?? "still inherited") == nil, "\(name) was not unset")
        }
    }

    @Test("An inherited environment really would have leaked it")
    func plainInheritKeepsEverything() {
        // The control for the two tests above: `.inherit` is what the default
        // used to be, and it removes nothing. Without this, "the overrides name
        // the credential variables" could be satisfied by a map that does not
        // actually change what the child sees.
        #expect(ShellEnvironment.inherit.overrides.isEmpty)
    }
}

// MARK: - What the child actually sees

@Suite("Tool environment — the child process", .timeLimit(.minutes(2)))
struct ToolEnvironmentChildTests {

    @Test("A named variable is gone from bash while its neighbour survives")
    func namedVariableIsRemovedFromTheChild() async throws {
        _ = unsafe setenv(fakeCredentialName, "leaked-value-9f21", 1)
        _ = unsafe setenv(ordinaryName, "kept", 1)
        defer {
            _ = unsafe unsetenv(fakeCredentialName)
            _ = unsafe unsetenv(ordinaryName)
        }

        // Baseline: with a plain inherited environment the child sees both. This
        // is what makes the scrubbed run below mean something — without it, a
        // child that never inherited the variable in the first place would pass.
        let (leaky, leakyRoot) = try await makeContext(environment: .inherit)
        defer { try? FileManager.default.removeItem(at: leakyRoot) }
        let before = try await BashTool().execute(
            ["command": .string("echo \"[${\(fakeCredentialName)-unset}][${\(ordinaryName)-unset}]\"")],
            in: leaky
        )
        #expect(before.text == "[leaked-value-9f21][kept]\n")

        let (scrubbed, scrubbedRoot) = try await makeContext(
            environment: ToolContext.scrubbedEnvironment(alsoUnsetting: [fakeCredentialName])
        )
        defer { try? FileManager.default.removeItem(at: scrubbedRoot) }
        let after = try await BashTool().execute(
            ["command": .string("echo \"[${\(fakeCredentialName)-unset}][${\(ordinaryName)-unset}]\"")],
            in: scrubbed
        )
        #expect(after.text == "[unset][kept]\n")
    }

    @Test("The default context still gives bash a usable environment")
    func defaultContextKeepsPath() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        // `PATH` is the one inherited variable a coding agent cannot work
        // without, and it is the canary for a scrub that got too broad: an
        // `.empty` base, or a denylist keyed off a name pattern, loses it.
        let result = try await BashTool().execute(
            ["command": "echo \"[${PATH:+path}]\""],
            in: fixture.context
        )

        #expect(!result.isError)
        #expect(result.text == "[path]\n")
    }
}
