// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

/// The policy facts that make plan mode a capability boundary.
///
/// Plan mode is not a second sandbox and it does not need an external-directory
/// concept. The existing tool filesystem is already rooted at the workspace;
/// this policy simply denies every mutating capability except the one generated
/// plan path. Project mode rules are accepted only as denials, so a repository
/// can tighten this boundary but cannot widen it.
public enum AgentModePolicy {
    /// A stable per-session file inside the existing workspace sandbox.
    public static func planPath(workingDirectory: String, sessionID: String) -> String {
        let safeID = sessionID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        let name = safeID.isEmpty ? "current" : String(safeID)
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent(".domocode", isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("\(name).md")
            .standardizedFileURL.path
    }

    /// The mode rules layered after ordinary global and profile rules.
    public static func rules(
        for mode: AgentMode,
        planPath: String,
        additional: Ruleset = []
    ) -> Ruleset {
        guard mode == .plan else { return denyOnly(additional) }

        // Start with a deny-all rule so an unknown MCP or future tool cannot
        // become an accidental write capability in plan mode.
        var rules: Ruleset = [PermissionRule(permission: "*", pattern: "*", action: .deny)]

        // Read-only tools remain useful. The secret-file exceptions are repeated
        // after the broad read allow so the normal .env hardening still applies.
        rules.append(contentsOf: [
            PermissionRule(permission: "read", pattern: "*", action: .allow),
            PermissionRule(permission: "read", pattern: "*.env", action: .ask),
            PermissionRule(permission: "read", pattern: "*.env.*", action: .ask),
            PermissionRule(permission: "read", pattern: "*.env.example", action: .allow),
            PermissionRule(permission: "ls", pattern: "*", action: .allow),
            PermissionRule(permission: "find", pattern: "*", action: .allow),
            PermissionRule(permission: "grep", pattern: "*", action: .allow),
            PermissionRule(permission: "glob", pattern: "*", action: .allow),
            PermissionRule(permission: "todowrite", pattern: "*", action: .allow),
            PermissionRule(permission: "question", pattern: "*", action: .ask),
            PermissionRule(permission: "webfetch", pattern: "*", action: .ask),
            PermissionRule(permission: "plan_exit", pattern: "*", action: .allow),
        ])

        // An exact plan path is the only write/edit exception. PermissionRequest
        // checks both the model spelling and the workspace-absolute alias, so the
        // absolute rule covers relative and full-path spellings.
        rules.append(contentsOf: [
            PermissionRule(permission: "write", pattern: planPath, action: .allow),
            PermissionRule(permission: "edit", pattern: planPath, action: .allow),
            PermissionRule(permission: "apply_patch", pattern: planPath, action: .allow),
        ])

        // Only denials from a user/project mode block are meaningful here. A
        // project can deny the plan file too, but it cannot add another allow.
        rules.append(contentsOf: denyOnly(additional))
        return rules
    }

    /// Mode configuration is a tightening surface, never an allow surface.
    public static func denyOnly(_ rules: Ruleset) -> Ruleset {
        rules.filter { $0.action == .deny }
    }

    public static func systemPrompt(planPath: String) -> String {
        """
        You are in plan mode. Inspect the workspace with read-only tools and write the plan only to \(planPath). Do not edit, write, patch, shell out, launch background processes, or call external tools. When the plan is complete, call plan_exit; do not claim completion without using it.
        """
    }
}
