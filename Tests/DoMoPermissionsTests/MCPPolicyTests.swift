// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 8d: an MCP tool is gated by the SAME policy as any tool (its namespaced name is
// the permission key), so it can be allowed/denied per-tool or per-server, and a broad
// `deny` HIDES it from the model (disabledTools), not merely blocks the call.

import Testing

@testable import DoMoPermissions

private let HOME = "/home/tester"

@Suite("MCP tool policy — routing + visibility")
struct MCPPolicyTests {
    private var baseline: Ruleset { fromConfig(defaultBaselinePermissionConfig(), homeDirectory: HOME) }
    private func rule(_ p: String, _ pat: String, _ a: PermissionAction) -> PermissionRule {
        PermissionRule(permission: p, pattern: pat, action: a)
    }

    // MARK: routing (evaluate) — per-tool and per-server

    @Test("An MCP tool with no rule resolves to ask under the baseline")
    func mcpDefaultsToAsk() {
        #expect(evaluate("github_list_issues", "*", rulesets: [baseline]).action == .ask)
    }

    @Test("A specific-tool allow grants only that MCP tool")
    func specificToolAllow() {
        let user = [rule("github_list_issues", "*", .allow)]
        #expect(evaluate("github_list_issues", "*", rulesets: [baseline, user]).action == .allow)
        // A different tool of the same server is unaffected — still ask.
        #expect(evaluate("github_create_issue", "*", rulesets: [baseline, user]).action == .ask)
    }

    @Test("A whole-server glob allows every tool of that server")
    func wholeServerAllow() {
        let user = [rule("github_*", "*", .allow)]
        #expect(evaluate("github_list_issues", "*", rulesets: [baseline, user]).action == .allow)
        #expect(evaluate("github_create_issue", "*", rulesets: [baseline, user]).action == .allow)
        // A different server is not matched.
        #expect(evaluate("gitlab_get", "*", rulesets: [baseline, user]).action == .ask)
    }

    @Test("A whole-server deny denies every tool of that server")
    func wholeServerDeny() {
        let user = [rule("github_*", "*", .deny)]
        #expect(evaluate("github_list_issues", "*", rulesets: [baseline, user]).action == .deny)
    }

    // MARK: visibility (disabledTools) — a broad deny HIDES the tool

    @Test("A deny'd MCP tool is hidden; a non-denied one stays visible")
    func denyHides() {
        let ruleset = merge(baseline, [rule("github_*", "*", .deny)])
        #expect(disabledTools(["github_list_issues", "gitlab_get"], ruleset) == ["github_list_issues"])
    }

    @Test("A specific-tool deny hides just that tool")
    func specificDenyHides() {
        let ruleset = merge(baseline, [rule("github_list_issues", "*", .deny)])
        #expect(disabledTools(["github_list_issues", "github_create_issue"], ruleset) == ["github_list_issues"])
    }

    @Test("An allowed or unruled MCP tool is not hidden")
    func allowedNotHidden() {
        let ruleset = merge(baseline, [rule("github_list_issues", "*", .allow)])
        #expect(disabledTools(["github_list_issues", "github_create_issue"], ruleset).isEmpty)
    }

    @Test("A deny with a non-* pattern gates the call but does NOT hide the tool")
    func patternDenyDoesNotHide() {
        // pattern != "*" — only the matching call is denied at dispatch; the tool stays visible.
        let ruleset = merge(baseline, [rule("github_list_issues", "somearg", .deny)])
        #expect(disabledTools(["github_list_issues"], ruleset).isEmpty)
    }

    @Test("A blanket *: deny hides every MCP tool (intended — the user denied everything)")
    func blanketDenyHidesAll() {
        let ruleset = merge(baseline, [rule("*", "*", .deny)])
        #expect(disabledTools(["github_list_issues", "gitlab_get"], ruleset) == ["github_list_issues", "gitlab_get"])
    }
}
