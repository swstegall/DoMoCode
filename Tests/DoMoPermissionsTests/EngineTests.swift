// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The stateful layer above the pure policy core: the order-preserving config parse,
// the tool-aware request factory, and the `PermissionEngine` actor's ask/reply/persist
// semantics.

import DoMoCore
import Foundation
import Synchronization
import Testing

@testable import DoMoPermissions

private let HOME = "/home/tester"

// MARK: - Ordered JSON + config extraction

@Suite("Ordered permission config parse")
struct OrderedConfigTests {
    @Test("key order is preserved (last-match-wins depends on it)")
    func orderPreserved() {
        let text = #"{ "model": "x", "permission": { "bash": { "*": "deny", "git *": "allow" } } }"#
        let config = permissionConfig(fromSettingsText: text)
        let rules = fromConfig(config, homeDirectory: HOME)
        #expect(rules == [
            PermissionRule(permission: "bash", pattern: "*", action: .deny),
            PermissionRule(permission: "bash", pattern: "git *", action: .allow),
        ])
        // Reversed authoring flips the precedence, proving order is load-bearing.
        let reversed = permissionConfig(fromSettingsText:
            #"{ "permission": { "bash": { "git *": "allow", "*": "deny" } } }"#)
        #expect(evaluate("bash", "git status", fromConfig(reversed, homeDirectory: HOME)).action == .deny)
        #expect(evaluate("bash", "git status", rules).action == .allow)
    }

    @Test("top-level bare string normalizes to { \"*\": action }")
    func bareString() {
        let config = permissionConfig(fromSettingsText: #"{ "permission": "allow" }"#)
        #expect(fromConfig(config, homeDirectory: HOME) == [PermissionRule(permission: "*", pattern: "*", action: .allow)])
    }

    @Test("null delete sentinels survive the parse")
    func nullSentinel() {
        let config = permissionConfig(fromSettingsText: #"{ "permission": { "bash": { "*": "ask", "npm *": null }, "edit": null } }"#)
        #expect(fromConfig(config, homeDirectory: HOME) == [PermissionRule(permission: "bash", pattern: "*", action: .ask)])
    }

    @Test("missing permission key yields empty config; malformed rules are skipped")
    func robustness() {
        #expect(permissionConfig(fromSettingsText: #"{ "model": "x" }"#).isEmpty)
        #expect(permissionConfig(fromSettingsText: "not json at all") .isEmpty)
        // A non-action string value is skipped, not fatal.
        let config = permissionConfig(fromSettingsText: #"{ "permission": { "bash": "banana", "edit": "deny" } }"#)
        #expect(fromConfig(config, homeDirectory: HOME) == [PermissionRule(permission: "edit", pattern: "*", action: .deny)])
    }

    @Test("string escapes parse")
    func escapes() {
        let root = parseOrderedJSON(#"{ "a": "line\none\ttab\"q", "b": [1, 2.5, true, null] }"#)
        #expect(root?["a"] == .string("line\none\ttab\"q"))
        #expect(root?["b"] == .array([.number("1"), .number("2.5"), .bool(true), .null]))
    }
}

// MARK: - Request factory

@Suite("Permission request factory")
struct FactoryTests {
    private let factory = PermissionRequestFactory(workingDirectory: "/work")

    @Test("bash splits compound commands and computes arity always-globs")
    func bash() {
        let spec = factory.make(toolName: "bash", arguments: .object(["command": .string("echo hi && git commit -m 'x'")]))
        #expect(spec.permission == "bash")
        #expect(spec.patterns == ["echo hi", "git commit -m 'x'"])   // per sub-command (a deny on one is caught)
        #expect(spec.always == ["echo *", "git commit *"])           // arity prefixes
        #expect(spec.metadata["command"]?.stringValue == "echo hi && git commit -m 'x'")
    }

    @Test("read keys on the real path (so the .env guard sees it)")
    func read() {
        let spec = factory.make(toolName: "read", arguments: .object(["path": .string("config/.env")]))
        #expect(spec.permission == "read")
        #expect(spec.patterns == ["config/.env"])
    }

    @Test("unknown/MCP tool name defaults to a * resource")
    func unknown() {
        let spec = factory.make(toolName: "myserver_dangerous", arguments: .object([:]))
        #expect(spec.permission == "myserver_dangerous")
        #expect(spec.patterns == ["*"])
        #expect(spec.always == ["*"])
    }

    @Test("write to a protected config file is flagged configProtected (incl. case variants)")
    func selfEditGuard() {
        let guarded = PermissionRequestFactory(workingDirectory: "/work", protectedPaths: ["/work/.domocode/settings.json"])
        #expect(guarded.make(toolName: "write", arguments: .object(["path": .string(".domocode/settings.json")])).configProtected)
        // macOS is case-insensitive: `Settings.json` overwrites the real file.
        #expect(guarded.make(toolName: "edit", arguments: .object(["path": .string(".domocode/Settings.json")])).configProtected)
        #expect(!guarded.make(toolName: "write", arguments: .object(["path": .string("src/main.swift")])).configProtected)
    }

    @Test("bash that names a config file is config-protected (redirect self-edit guard)")
    func bashRedirectGuard() {
        let guarded = PermissionRequestFactory(workingDirectory: "/work", protectedPaths: ["/work/.domocode/settings.json"])
        let danger = guarded.make(toolName: "bash", arguments: .object(["command": .string("echo bad > .domocode/settings.json")]))
        #expect(danger.configProtected)
        #expect(danger.always.isEmpty)  // a protected command offers no "always"
        #expect(!guarded.make(toolName: "bash", arguments: .object(["command": .string("echo hi")])).configProtected)
    }

    @Test("bash env-assignment prefixes are stripped from the arity glob")
    func bashEnvStrip() {
        let factory = PermissionRequestFactory(workingDirectory: "/work")
        let spec = factory.make(toolName: "bash", arguments: .object(["command": .string("FOO=bar rm x")]))
        #expect(spec.always == ["rm *"])
    }
}

@Suite("Shell command decomposition")
struct ShellSplitTests {
    @Test("chained, substituted, and subshell commands each become a checked fragment")
    func decomposes() {
        #expect(ShellCommand.split("echo hi && rm -rf /") == ["echo hi", "rm -rf /"])
        #expect(ShellCommand.split("echo $(rm -rf /)").contains("rm -rf /"))
        #expect(ShellCommand.split("echo `rm -rf /`").contains("rm -rf /"))
        #expect(ShellCommand.split("( rm -rf / )").contains("rm -rf /"))
        // Command substitution is active INSIDE double quotes too.
        #expect(ShellCommand.split(#"echo "$(rm -rf /)""#).contains { $0.hasPrefix("rm -rf /") })
    }

    @Test("a backslash-escaped separator does not desync the scanner")
    func backslashEscape() {
        #expect(ShellCommand.split(#"echo a\;b"#) == [#"echo a\;b"#])   // \; is escaped, not a separator
        #expect(ShellCommand.split("'a; b'") == ["'a; b'"])            // single quotes suppress the ;
    }

    @Test("env-assignment stripping")
    func envStrip() {
        #expect(ShellCommand.stripEnvAssignments(["FOO=bar", "BAZ=qux", "rm", "x"]) == ["rm", "x"])
        #expect(ShellCommand.stripEnvAssignments(["rm", "FOO=bar"]) == ["rm", "FOO=bar"])  // only LEADING
    }
}

// MARK: - Engine

@Suite("Permission engine")
struct EngineTests {
    private func baseline() -> Ruleset {
        fromConfig(defaultBaselinePermissionConfig(), homeDirectory: HOME)
    }

    @Test("read-only tools run with no prompt under the baseline")
    func autoAllow() async {
        let prompted = Mutex(false)
        let engine = PermissionEngine(ruleset: baseline(), prompt: { _ in prompted.withLock { $0 = true }; return .reject(message: nil) })
        let decision = await engine.ask(PermissionRequestSpec(permission: "read", patterns: ["src/main.swift"], always: ["*"]), sessionID: "s")
        #expect(decision == .allow)
        #expect(!prompted.withLock { $0 })
    }

    @Test("a .env read prompts even though read is broadly allowed")
    func envAsks() async {
        let prompted = Mutex(false)
        let engine = PermissionEngine(ruleset: baseline(), prompt: { _ in prompted.withLock { $0 = true }; return .once })
        let decision = await engine.ask(PermissionRequestSpec(permission: "read", patterns: ["config/.env"], always: ["*"]), sessionID: "s")
        #expect(decision == .allow)
        #expect(prompted.withLock { $0 })   // the .env guard forced the prompt
    }

    @Test("bash asks under the baseline; a deny short-circuits with a reason")
    func bashAskAndDeny() async {
        let ruleset = merge(baseline(), fromConfig(permissionConfig(fromSettingsText: #"{ "permission": { "bash": { "rm *": "deny" } } }"#), homeDirectory: HOME))
        let engine = PermissionEngine(ruleset: ruleset, prompt: { _ in .once })
        let ask = await engine.ask(PermissionRequestSpec(permission: "bash", patterns: ["ls -la"], always: ["ls *"]), sessionID: "s")
        #expect(ask == .allow)
        let deny = await engine.ask(PermissionRequestSpec(permission: "bash", patterns: ["rm -rf /"], always: ["rm *"]), sessionID: "s")
        if case .deny = deny {} else { Issue.record("expected deny, got \(deny)") }
    }

    @Test("allow-always grants the broader glob for the rest of the session and persists it")
    func alwaysGrantsAndPersists() async {
        let persisted = PersistBox()
        let engine = PermissionEngine(
            ruleset: baseline(),
            prompt: { _ in .always },
            persist: { rules in await persisted.append(rules) }
        )
        // First git call: prompts, user picks always -> grants "git *".
        let first = await engine.ask(PermissionRequestSpec(permission: "bash", patterns: ["git status"], always: ["git *"]), sessionID: "s")
        #expect(first == .allow)
        #expect(await persisted.all == [PermissionRule(permission: "bash", pattern: "git *", action: .allow)])
        // Second git call: now silently allowed (grant covers it), no second prompt.
        let promptCount = Mutex(0)
        let engine2 = PermissionEngine(
            ruleset: baseline(),
            approved: [PermissionRule(permission: "bash", pattern: "git *", action: .allow)],
            prompt: { _ in promptCount.withLock { $0 += 1 }; return .once }
        )
        let second = await engine2.ask(PermissionRequestSpec(permission: "bash", patterns: ["git log"], always: ["git *"]), sessionID: "s")
        #expect(second == .allow)
        #expect(promptCount.withLock { $0 } == 0)
    }

    @Test("config-protected request is forced to prompt and never persists an always grant")
    func configProtected() async {
        let lastRequest = Mutex<PermissionRequest?>(nil)
        let persisted = PersistBox()
        // Even with an explicit allow rule, a protected write must prompt.
        let ruleset = merge(baseline(), [PermissionRule(permission: "write", pattern: "*", action: .allow)])
        let engine = PermissionEngine(
            ruleset: ruleset,
            prompt: { request in lastRequest.withLock { $0 = request }; return .always },
            persist: { rules in await persisted.append(rules) }
        )
        let spec = PermissionRequestSpec(permission: "write", patterns: [".domocode/settings.json"], always: ["*"], configProtected: true)
        let decision = await engine.ask(spec, sessionID: "s")
        #expect(decision == .allow)            // the user allowed it once
        #expect(lastRequest.withLock { $0 }?.disableAlways == true)
        #expect(await persisted.all.isEmpty)   // but "always" did not persist a self-widening grant
    }

    @Test("a config deny beats a broad in-session allow-always grant (resolve, not flat merge)")
    func configDenyBeatsSavedGrant() async {
        // User config denies writing lockfiles.
        let ruleset = merge(baseline(), fromConfig(permissionConfig(fromSettingsText:
            #"{ "permission": { "write": { "*.lock": "deny" } } }"#), homeDirectory: HOME))
        // The model earlier obtained a broad `write *` allow-always grant.
        let engine = PermissionEngine(
            ruleset: ruleset,
            approved: [PermissionRule(permission: "write", pattern: "*", action: .allow)],
            prompt: { _ in .reject(message: nil) }
        )
        // The lockfile write must still be DENIED — the grant cannot override the deny.
        let denied = await engine.ask(PermissionRequestSpec(permission: "write", patterns: ["yarn.lock"], always: ["*"]), sessionID: "s")
        if case .deny = denied {} else { Issue.record("config deny must beat the saved grant, got \(denied)") }
        // A non-denied write is still covered silently by the grant.
        let allowed = await engine.ask(PermissionRequestSpec(permission: "write", patterns: ["README.md"], always: ["*"]), sessionID: "s")
        #expect(allowed == .allow)
    }

    @Test("reject with a message denies with that message as the reason")
    func rejectMessage() async {
        let engine = PermissionEngine(ruleset: baseline(), prompt: { _ in .reject(message: "not now") })
        let decision = await engine.ask(PermissionRequestSpec(permission: "bash", patterns: ["ls"], always: ["ls *"]), sessionID: "s")
        #expect(decision == .deny(reason: "not now"))
    }
}

/// A tiny actor to observe persisted grants from the engine's `persist` closure.
private actor PersistBox {
    private(set) var all: Ruleset = []
    func append(_ rules: Ruleset) { all.append(contentsOf: rules) }
}
