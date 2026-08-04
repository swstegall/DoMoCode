// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// What "Allow always" is allowed to write into the user's global settings.json.
//
// This is the blast radius of a single keypress on a prompt whose bold line names
// one file, so the invariant is narrow and worth pinning: a grant may never be
// wider than what the prompt showed, and it may never bury a deny the user wrote
// by hand.

import DoMoCore
import DoMoPermissions
import Foundation
import Testing

@Suite("Allow-always grant scope")
struct GrantScopeTests {

    private let workspace = "/work"
    private var factory: PermissionRequestFactory { PermissionRequestFactory(workingDirectory: workspace) }

    private func spec(_ tool: String, path: String) -> PermissionRequestSpec {
        factory.make(toolName: tool, arguments: .object(["path": .string(path)]))
    }

    @Test("An edit grant covers that file, not every file — and not other projects")
    func editGrantIsScopedToTheFile() {
        // It used to be ["*"]: approving "Allow always" on a prompt reading
        // `edit  a.txt` wrote `edit: {"*": "allow"}` to the GLOBAL settings.json —
        // every edit, every file, every project, permanently. Scoping it to the path
        // alone was still not enough: grants live in the GLOBAL config, so a bare
        // relative pattern authorised the same relative path in every other repo.
        #expect(spec("edit", path: "a.txt").always == ["/work/a.txt"])
        #expect(spec("write", path: "src/Foo.swift").always == ["/work/src/Foo.swift"])
        #expect(!spec("edit", path: "a.txt").always.contains("*"))
    }

    @Test("A grant made in one project does not authorise the same relative path in another")
    func grantsDoNotTravelBetweenProjects() {
        let granted = spec("edit", path: "src/index.js").always
        #expect(granted == ["/work/src/index.js"])
        let elsewhere = PermissionRequestFactory(workingDirectory: "/other")
            .make(toolName: "edit", arguments: .object(["path": .string("src/index.js")]))
        // The other project's request resolves to a different absolute spelling, so
        // the saved rule cannot match it.
        #expect(!elsewhere.patternAliases.contains("/work/src/index.js"))
        #expect(elsewhere.patternAliases == ["/other/src/index.js"])
    }

    @Test("Every spelling of the same file is checked, so a grant is spelling-independent")
    func spellingsAreEquivalent() async {
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home")
        let engine = PermissionEngine(
            ruleset: ruleset,
            approved: [PermissionRule(permission: "edit", pattern: "/work/a.txt", action: .allow)],
            prompt: { _ in Issue.record("a granted file must not re-prompt under another spelling"); return .reject(message: nil) }
        )
        for spelling in ["a.txt", "./a.txt", "/work/a.txt", "sub/../a.txt"] {
            #expect(await engine.ask(spec("edit", path: spelling), sessionID: "s") == .allow, "spelling: \(spelling)")
        }
    }

    @Test("A deny cannot be side-stepped by re-spelling the path")
    func denyCannotBeDodgedByRespelling() async {
        let config: PermissionConfig = [
            PermissionConfigEntry(permission: "*", value: .action(.ask)),
            PermissionConfigEntry(permission: "edit", value: .map([PatternRule(pattern: "secrets.txt", action: .deny)])),
        ]
        let engine = PermissionEngine(
            ruleset: fromConfig(config, homeDirectory: "/home"),
            prompt: { _ in .once }
        )
        // The raw spelling is still in the checked set, so the hand-written relative
        // rule keeps working; the fold is deny-first, so no alias can lift it.
        if case .allow = await engine.ask(spec("edit", path: "secrets.txt"), sessionID: "s") {
            Issue.record("the hand-written deny must still apply")
        }
    }

    @Test("A read grant cannot disable the .env guard everywhere")
    func readGrantIsScopedToTheFile() {
        // Worse than edit: a blanket `read: {"*": "allow"}` overrides the baseline's
        // `*.env: ask` rule, so one "always" on any file silently turned off the
        // secret guard for every project.
        #expect(spec("read", path: "notes.md").always == ["/work/notes.md"])
        #expect(!spec("read", path: "notes.md").always.contains("*"))
    }

    @Test("A path-scoped grant really does suppress the prompt for that path")
    func scopedGrantIsHonouredByTheResolver() async {
        // A narrow saved rule has to be ACCEPTED against the baseline's broad `*`
        // rule, or the fix would trade over-granting for a grant that does nothing.
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home")
        let engine = PermissionEngine(
            ruleset: ruleset,
            approved: [PermissionRule(permission: "edit", pattern: "/work/a.txt", action: .allow)],
            prompt: { _ in Issue.record("must not prompt for an already-granted path"); return .reject(message: nil) }
        )
        #expect(await engine.ask(spec("edit", path: "a.txt"), sessionID: "s") == .allow)
    }

    @Test("A grant for one file still prompts for another")
    func scopedGrantDoesNotLeak() async {
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home")
        let prompted = Prompted()
        let engine = PermissionEngine(
            ruleset: ruleset,
            approved: [PermissionRule(permission: "edit", pattern: "/work/a.txt", action: .allow)],
            prompt: { _ in prompted.record(); return .reject(message: nil) }
        )
        _ = await engine.ask(spec("edit", path: "b.txt"), sessionID: "s")
        #expect(prompted.happened, "a grant on a.txt must not cover b.txt")
    }

    /// A `Sendable` flag the engine's `@Sendable` prompter may set.
    private final class Prompted: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func record() { lock.lock(); value = true; lock.unlock() }
        var happened: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("An empty path grants nothing, so the UI can hide the row")
    func emptyPathGrantsNothing() {
        #expect(spec("edit", path: "").always.isEmpty)
    }

    @Test("A path containing a glob metacharacter grants NOTHING")
    func globbyPathGrantsNothing() {
        // The hole scoping-to-the-path left open: a grant is stored as a PATTERN, and
        // patterns are matched with wildcardMatch, where `*` and `?` are the two
        // characters left unescaped. The path comes from the model and `write`
        // creates whatever it is given — so `write *` produced a prompt reading
        // "Always allow *" that persisted `{"write": {"*": "allow"}}` globally: the
        // exact blanket rule scoping was meant to remove. `read *.env` is worse, since
        // it disables the secret guard the baseline exists to enforce.
        #expect(spec("write", path: "*").always.isEmpty)
        #expect(spec("write", path: "n*.txt").always.isEmpty)
        #expect(spec("read", path: "*.env").always.isEmpty)
        #expect(spec("edit", path: "a?.txt").always.isEmpty)
        #expect(spec("ls", path: "src/*").always.isEmpty)
        // An ordinary path is unaffected.
        #expect(spec("edit", path: "src/Foo.swift").always == ["/work/src/Foo.swift"])
        // Characters wildcardMatch already escapes are NOT glob-active, so they stay
        // grantable — refusing them would be needless.
        #expect(spec("edit", path: "a[1].txt").always == ["/work/a[1].txt"])
        #expect(spec("edit", path: "a+b(c).txt").always == ["/work/a+b(c).txt"])
    }

    @Test("bash grants stay globs — the restriction is for path-keyed tools only")
    func bashGrantsAreStillGlobs() {
        // `bashAlwaysGlob` produces `git *` by design; a blanket "no globby grants"
        // rule at the persistence layer would have broken it.
        let bash = factory.make(toolName: "bash", arguments: .object(["command": .string("git status")]))
        #expect(bash.always.contains { $0.contains("*") })
    }

    @Test("apply_patch scopes each touched file independently")
    func applyPatchGrantScope() {
        let patch = """
            *** Begin Patch
            *** Update File: src/a.swift
            @@
            -old
            +new
            *** Add File: notes.md
            +note
            *** End Patch
            """
        let specs = factory.makeAll(toolName: "apply_patch", arguments: ["patch": patch])

        #expect(specs.map(\.patterns) == [["src/a.swift"], ["notes.md"]])
        #expect(specs.map(\.always) == [["/work/src/a.swift"], ["/work/notes.md"]])
        #expect(specs.allSatisfy { $0.permission == "apply_patch" })
    }

    @Test("apply_patch protects a settings file even inside a multi-file patch")
    func applyPatchProtectsConfig() {
        let patch = """
            *** Begin Patch
            *** Update File: .domocode/settings.json
            @@
            -{}
            +{"permission": {}}
            *** End Patch
            """
        let spec = factory.make(toolName: "apply_patch", arguments: ["patch": patch])

        #expect(spec.configProtected)
        #expect(spec.always.isEmpty)
    }

    @Test("websearch is query-scoped and never persists a blanket grant")
    func webSearchPermission() {
        let spec = factory.make(
            toolName: "websearch",
            arguments: ["query": "swift concurrency"]
        )
        #expect(spec.permission == "websearch")
        #expect(spec.patterns == ["swift concurrency"])
        #expect(spec.always.isEmpty)
    }

    // MARK: Persistence

    @Test("A persisted grant never buries a deny the user wrote by hand")
    func grantCannotOverrideAnExistingDeny() {
        // Evaluation is last-match-wins and a new pattern is APPENDED, so without a
        // guard a grant written after an existing deny wins over it from the next
        // launch onwards — turning the user's own rule off.
        let existing = """
            {"permission": {"edit": {"yarn.lock": "deny"}}}
            """
        let text = settingsText(existing, mergingGrants: [
            PermissionRule(permission: "edit", pattern: "yarn.lock", action: .allow)
        ])
        #expect(text?.contains("\"yarn.lock\" : \"deny\"") == true || text?.contains("\"yarn.lock\": \"deny\"") == true)
        #expect(text?.contains("allow") == false, "the deny must survive: \(text ?? "nil")")
    }

    @Test("A broad grant is ordered BEFORE a narrower deny, so both keep their meaning")
    func broadGrantIsOrderedBeforeANarrowDeny() {
        // Evaluation is last-match-wins, so a grant wider than an existing deny can
        // satisfy both by going first — refusing it outright would needlessly break a
        // grant the user asked for, and appending it would bury their deny.
        let existing = """
            {"permission": {"edit": {"secrets.txt": "deny"}}}
            """
        guard let text = settingsText(existing, mergingGrants: [
            PermissionRule(permission: "edit", pattern: "*", action: .allow)
        ]) else { Issue.record("expected a merged config"); return }
        guard let allowAt = text.range(of: "\"*\""), let denyAt = text.range(of: "secrets.txt") else {
            Issue.record("both rules must be present: \(text)"); return
        }
        #expect(allowAt.lowerBound < denyAt.lowerBound, "the narrower deny must match LAST: \(text)")
        #expect(text.contains("deny"))
    }

    @Test("A deny BROADER than the grant still refuses it — no ordering satisfies both")
    func broaderDenyRefusesTheGrant() {
        let existing = """
            {"permission": {"edit": {"*.lock": "deny"}}}
            """
        let text = settingsText(existing, mergingGrants: [
            PermissionRule(permission: "edit", pattern: "yarn.lock", action: .allow)
        ])
        #expect(text?.contains("allow") == false, "the more specific statement of intent wins: \(text ?? "nil")")
    }

    @Test("An unrelated grant still persists normally")
    func unrelatedGrantStillPersists() {
        let existing = """
            {"permission": {"edit": {"yarn.lock": "deny"}}}
            """
        let text = settingsText(existing, mergingGrants: [
            PermissionRule(permission: "edit", pattern: "src/Foo.swift", action: .allow)
        ])
        #expect(text?.contains("src/Foo.swift") == true)
        #expect(text?.contains("deny") == true, "the existing deny is untouched")
    }
}
