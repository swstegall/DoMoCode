// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@testable import DoMoPermissions

@Suite("agent mode policy")
struct AgentModePolicyTests {
    @Test("plan mode permits only the generated plan file")
    func planBoundary() {
        let plan = "/work/.domocode/plans/session.md"
        let rules = AgentModePolicy.rules(for: .plan, planPath: plan)

        #expect(evaluate("write", plan, rules).action == .allow)
        #expect(evaluate("edit", plan, rules).action == .allow)
        #expect(evaluate("write", "/work/README.md", rules).action == .deny)
        #expect(evaluate("edit", "/work/Sources/App.swift", rules).action == .deny)
        #expect(evaluate("bash", "printf nope", rules).action == .deny)
        #expect(evaluate("background_process", "start", rules).action == .deny)
        #expect(evaluate("unknown_mcp_tool", "*", rules).action == .deny)
        #expect(evaluate("read", "/work/README.md", rules).action == .allow)
        #expect(evaluate("plan_exit", "*", rules).action == .allow)
        #expect(evaluate("task", "*", rules).action == .allow)
    }

    @Test("project allow rules cannot widen a hardened mode")
    func projectCannotWiden() {
        let plan = "/work/.domocode/plans/session.md"
        let rules = AgentModePolicy.rules(
            for: .plan,
            planPath: plan,
            additional: [
                PermissionRule(permission: "write", pattern: "*", action: .allow),
                PermissionRule(permission: "bash", pattern: "*", action: .allow),
                PermissionRule(permission: "read", pattern: "*.md", action: .deny),
            ]
        )

        #expect(evaluate("write", "/work/other.md", rules).action == .deny)
        #expect(evaluate("bash", "touch /work/other.md", rules).action == .deny)
        #expect(evaluate("write", plan, rules).action == .allow)
        #expect(evaluate("read", "/work/README.md", rules).action == .deny)
        #expect(AgentModePolicy.denyOnly([
            PermissionRule(permission: "write", pattern: "*", action: .allow)
        ]).isEmpty)
    }
}
