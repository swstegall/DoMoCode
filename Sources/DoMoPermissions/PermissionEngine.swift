// Copyright (c) 2025 opencode contributors. MIT license.
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The gate. An actor holding the resolved ruleset and the session's in-memory "always"
// grants, with a per-surface prompter injected. `ask` ports opencode's per-pattern
// disposition (any deny short-circuits; all-allow runs silently; any ask prompts once
// for the whole call), plus DoMoCode's `.env` guard and the config-protection
// self-edit downgrade. On "allow always" it appends the grants to the session and, if a
// persister was supplied, writes them to config (Phase 8a persistence).

/// Evaluates tool calls against policy and prompts a surface when a call is unresolved.
public actor PermissionEngine {
    /// The built-in defaults merged with the user's config, in precedence order
    /// (later wins). Static for the engine's lifetime.
    private let baseRuleset: Ruleset
    /// Runtime "allow always" grants, appended after `baseRuleset` so they win.
    private var sessionApproved: Ruleset
    private let prompt: PermissionPrompter
    /// Persists newly-granted rules to config (Phase 8a). `nil` = session-only.
    private let persist: (@Sendable (Ruleset) async -> Void)?
    private var counter = 0

    public init(
        ruleset: Ruleset,
        approved: Ruleset = [],
        prompt: @escaping PermissionPrompter,
        persist: (@Sendable (Ruleset) async -> Void)? = nil
    ) {
        self.baseRuleset = ruleset
        self.sessionApproved = approved
        self.prompt = prompt
        self.persist = persist
    }

    /// The verdict for a tool call. Evaluates each concrete pattern; a `deny`
    /// short-circuits to a denial with a model-visible reason, an all-`allow` call
    /// runs with no prompt, and any `ask` prompts the surface once for the whole call.
    public func ask(_ spec: PermissionRequestSpec, sessionID: String) async -> PermissionDecision {
        var needsAsk = false
        for pattern in spec.patterns {
            // Base-vs-saved resolve, NOT a flat merge: a config `deny` beats a broad
            // in-session "allow always" grant (which last-match-wins would not).
            var rule = resolvePermission(spec.permission, pattern, config: baseRuleset, saved: sessionApproved)
            // Config-protection: a broad allow must not silently cover the agent's own
            // permission/settings files — force a prompt.
            if spec.configProtected, rule.action == .allow { rule.action = .ask }
            switch rule.action {
            case .deny:
                return .deny(reason: Self.deniedReason(permission: spec.permission, pattern: pattern))
            case .ask:
                needsAsk = true
            case .allow:
                continue
            }
        }
        guard needsAsk else { return .allow }

        counter += 1
        let request = PermissionRequest(
            id: "per_\(counter)",
            sessionID: sessionID,
            permission: spec.permission,
            patterns: spec.patterns,
            // Config-protected requests cannot be persisted, so offer nothing to persist.
            always: spec.configProtected ? [] : spec.always,
            metadata: spec.metadata,
            disableAlways: spec.configProtected
        )

        switch await prompt(request) {
        case .once:
            return .allow
        case .always:
            // A config-protected "always" degrades to "once" — never persist a grant
            // that would let the model widen its own permissions.
            if !spec.configProtected, !spec.always.isEmpty {
                let grants = spec.always.map {
                    PermissionRule(permission: spec.permission, pattern: $0, action: .allow)
                }
                sessionApproved.append(contentsOf: grants)
                if let persist { await persist(grants) }
            }
            return .allow
        case .reject(let message):
            return .deny(reason: message ?? "The user rejected this tool call.")
        }
    }

    /// A model-visible denial reason. The model reads this as the tool's error result
    /// and can adapt (choose a different command, ask the user).
    private static func deniedReason(permission: String, pattern: String) -> String {
        "Permission denied by policy: the \"\(permission)\" action \"\(pattern)\" is not allowed."
    }
}
