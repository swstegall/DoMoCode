// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Persisting "allow always" grants back into settings.json without disturbing other
// settings, the permission block's authored order, or a `~` in an existing pattern.

import Testing

@testable import DoMoPermissions

private let HOME = "/home/tester"

@Suite("Settings permission writer")
struct WriterTests {
    private func r(_ p: String, _ pat: String, _ a: PermissionAction) -> PermissionRule {
        PermissionRule(permission: p, pattern: pat, action: a)
    }

    @Test("writes a grant into an empty settings file")
    func emptyFile() {
        let text = settingsText("{}", mergingGrants: [r("bash", "git *", .allow)])
        let config = permissionConfig(fromSettingsText: text)
        #expect(fromConfig(config, homeDirectory: HOME) == [r("bash", "git *", .allow)])
    }

    @Test("preserves other settings keys")
    func preservesOtherKeys() {
        let text = settingsText(#"{ "model": "gpt", "baseUrl": "http://x" }"#, mergingGrants: [r("bash", "npm *", .allow)])
        let root = parseOrderedJSON(text)
        #expect(root?["model"] == .string("gpt"))
        #expect(root?["baseUrl"] == .string("http://x"))
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME) == [r("bash", "npm *", .allow)])
    }

    @Test("merges into an existing permission block, appending the grant last")
    func mergesExisting() {
        let existing = #"{ "permission": { "bash": { "*": "ask" } } }"#
        let text = settingsText(existing, mergingGrants: [r("bash", "git *", .allow)])
        // Order matters: the new allow must come AFTER the existing ask (last wins).
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME)
            == [r("bash", "*", .ask), r("bash", "git *", .allow)])
    }

    @Test("overrides the action of an existing pattern rather than duplicating it")
    func overridesExistingPattern() {
        let existing = #"{ "permission": { "bash": { "git *": "ask" } } }"#
        let text = settingsText(existing, mergingGrants: [r("bash", "git *", .allow)])
        #expect(fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME)
            == [r("bash", "git *", .allow)])
    }

    @Test("a new permission key is appended")
    func newKey() {
        let existing = #"{ "permission": { "bash": { "*": "ask" } } }"#
        let text = settingsText(existing, mergingGrants: [r("write", "*", .allow)])
        let rules = fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: HOME)
        #expect(rules == [r("bash", "*", .ask), r("write", "*", .allow)])
    }

    @Test("a ~ in an existing pattern is NOT expanded on write")
    func preservesTilde() {
        let existing = #"{ "permission": { "read": { "~/secrets/*": "deny" } } }"#
        let text = settingsText(existing, mergingGrants: [r("bash", "ls *", .allow)])
        #expect(text.contains("~/secrets/*"), "the ~ must survive: \(text)")
    }
}
