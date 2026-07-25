// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Persisting "allow always" grants back into settings.json without disturbing other
// settings, the permission block's authored order, a `~` in an existing pattern, or a
// number token — and without ever clobbering an unparseable file.

import Testing

@testable import DoMoPermissions

private let HOME = "/home/tester"

@Suite("Settings permission writer")
struct WriterTests {
    private func r(_ p: String, _ pat: String, _ a: PermissionAction) -> PermissionRule {
        PermissionRule(permission: p, pattern: pat, action: a)
    }
    private func write(_ existing: String, _ grants: Ruleset) throws -> String {
        try #require(settingsText(existing, mergingGrants: grants))
    }

    @Test("writes a grant into an empty settings file")
    func emptyFile() throws {
        let text = try write("{}", [r("bash", "git *", .allow)])
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME) == [r("bash", "git *", .allow)])
    }

    @Test("preserves other settings keys and number tokens verbatim")
    func preservesOtherKeys() throws {
        let text = try write(#"{ "model": "gpt", "timeoutMs": 30000, "ratio": 1.50 }"#, [r("bash", "npm *", .allow)])
        let root = parseOrderedJSON(text)
        #expect(root?["model"] == .string("gpt"))
        #expect(root?["timeoutMs"] == .number("30000"))  // not reformatted
        #expect(root?["ratio"] == .number("1.50"))       // trailing zero preserved
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME) == [r("bash", "npm *", .allow)])
    }

    @Test("merges into an existing permission block, appending the grant last")
    func mergesExisting() throws {
        let text = try write(#"{ "permission": { "bash": { "*": "ask" } } }"#, [r("bash", "git *", .allow)])
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME)
            == [r("bash", "*", .ask), r("bash", "git *", .allow)])
    }

    @Test("overrides the action of an existing pattern rather than duplicating it")
    func overridesExistingPattern() throws {
        let text = try write(#"{ "permission": { "bash": { "git *": "ask" } } }"#, [r("bash", "git *", .allow)])
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME) == [r("bash", "git *", .allow)])
    }

    @Test("a ~ in an existing pattern is NOT expanded on write")
    func preservesTilde() throws {
        let text = try write(#"{ "permission": { "read": { "~/secrets/*": "deny" } } }"#, [r("bash", "ls *", .allow)])
        #expect(text.contains("~/secrets/*"), "the ~ must survive: \(text)")
    }

    @Test("aborts (returns nil) on a present-but-unparseable file rather than clobbering it")
    func abortsOnUnparseable() {
        #expect(settingsText("this is { not json", mergingGrants: [r("bash", "git *", .allow)]) == nil)
        #expect(settingsText("[1, 2, 3]", mergingGrants: [r("bash", "git *", .allow)]) == nil)  // not an object
        // But a whitespace-only file is treated as empty and written.
        #expect(settingsText("   \n ", mergingGrants: [r("bash", "git *", .allow)]) != nil)
    }
}
