// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import DoMoCore
import DoMoPermissions
import Foundation
import Testing

@testable import DoMoCLI

private final class PermissionWorkspace: Sendable {
    let root: URL
    let config: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("domo-permission-" + UUID().uuidString, isDirectory: true)
        config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeUser(_ text: String) throws {
        try text.write(
            to: config.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeProject(_ text: String) throws {
        let directory = root.appendingPathComponent(".domocode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(
            to: directory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@Suite("Project permission tightening")
struct PermissionSetupTests {
    private func resolve(_ workspace: PermissionWorkspace) -> Ruleset {
        PermissionSetup.resolvedRuleset(
            workingDirectory: workspace.root.path,
            configDirectory: workspace.config.path,
            homeDirectory: "/home/test"
        )
    }

    @Test("project allow cannot widen the default ask")
    func projectAllowIsClampedToAsk() throws {
        let workspace = try PermissionWorkspace()
        try workspace.writeProject(#"{"permission":{"mcp_fixture_danger":{"*":"allow"}}}"#)

        let rules = resolve(workspace)
        #expect(evaluate("mcp_fixture_danger", "arguments:e30", rules).action == .ask)
    }

    @Test("project ask can tighten a user allow")
    func projectAskTightensUserAllow() throws {
        let workspace = try PermissionWorkspace()
        try workspace.writeUser(#"{"permission":{"bash":"allow"}}"#)
        try workspace.writeProject(#"{"permission":{"bash":"ask"}}"#)

        let rules = resolve(workspace)
        #expect(evaluate("bash", "git status", rules).action == .ask)
    }

    @Test("a broad project rule cannot override a narrower user deny")
    func projectCannotOverrideOverlappingDeny() throws {
        let workspace = try PermissionWorkspace()
        try workspace.writeUser(#"{"permission":{"bash":{"rm *":"deny"}}}"#)
        try workspace.writeProject(#"{"permission":{"bash":{"*":"allow"}}}"#)

        let rules = resolve(workspace)
        #expect(evaluate("bash", "rm -rf", rules).action == .deny)
        #expect(evaluate("bash", "git status", rules).action == .ask)
    }

    @Test("project deny remains final after profile rules")
    func projectDenySurvivesDownstreamRules() throws {
        let workspace = try PermissionWorkspace()
        try workspace.writeProject(#"{"permission":{"write":{"README.md":"deny"}}}"#)

        let rules = PermissionSetup.resolvedRuleset(
            workingDirectory: workspace.root.path,
            configDirectory: workspace.config.path,
            homeDirectory: "/home/test",
            profileRules: [PermissionRule(permission: "write", pattern: "README.md", action: .allow)]
        )
        #expect(evaluate("write", "README.md", rules).action == .deny)
    }
}
