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

    private let factory = PermissionRequestFactory(workingDirectory: "/work")

    private func spec(_ tool: String, path: String) -> PermissionRequestSpec {
        factory.make(toolName: tool, arguments: .object(["path": .string(path)]))
    }

    @Test("An edit grant covers that file, not every file")
    func editGrantIsScopedToTheFile() {
        // It used to be ["*"]: approving "Allow always" on a prompt reading
        // `edit  a.txt` wrote `edit: {"*": "allow"}` to the GLOBAL settings.json —
        // every edit, every file, every project, permanently.
        #expect(spec("edit", path: "a.txt").always == ["a.txt"])
        #expect(spec("write", path: "src/Foo.swift").always == ["src/Foo.swift"])
        #expect(!spec("edit", path: "a.txt").always.contains("*"))
    }

    @Test("A read grant cannot disable the .env guard everywhere")
    func readGrantIsScopedToTheFile() {
        // Worse than edit: a blanket `read: {"*": "allow"}` overrides the baseline's
        // `*.env: ask` rule, so one "always" on any file silently turned off the
        // secret guard for every project.
        #expect(spec("read", path: "notes.md").always == ["notes.md"])
        #expect(!spec("read", path: "notes.md").always.contains("*"))
    }

    @Test("A path-scoped grant really does suppress the prompt for that path")
    func scopedGrantIsHonouredByTheResolver() async {
        // A narrow saved rule has to be ACCEPTED against the baseline's broad `*`
        // rule, or the fix would trade over-granting for a grant that does nothing.
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home")
        let engine = PermissionEngine(
            ruleset: ruleset,
            approved: [PermissionRule(permission: "edit", pattern: "a.txt", action: .allow)],
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
            approved: [PermissionRule(permission: "edit", pattern: "a.txt", action: .allow)],
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

    @Test("A broad grant that would bury a narrower deny is refused too")
    func broadGrantCannotBuryANarrowDeny() {
        let existing = """
            {"permission": {"edit": {"secrets.txt": "deny"}}}
            """
        let text = settingsText(existing, mergingGrants: [
            PermissionRule(permission: "edit", pattern: "*", action: .allow)
        ])
        #expect(text?.contains("deny") == true)
        #expect(text?.contains("allow") == false, "a `*` allow must not leapfrog an existing deny: \(text ?? "nil")")
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
