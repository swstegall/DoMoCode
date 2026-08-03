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
    /// (later wins). A provider lets a long-lived server session switch between
    /// build and plan modes without replacing its harness or losing its prompt.
    private let rulesetProvider: @Sendable () -> Ruleset
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
        self.rulesetProvider = { ruleset }
        self.sessionApproved = approved
        self.prompt = prompt
        self.persist = persist
    }

    /// Creates an engine whose policy can change between tool calls. The
    /// provider is synchronous so a server can read a lock-protected mode value
    /// without introducing an await between permission checks.
    public init(
        rulesetProvider: @escaping @Sendable () -> Ruleset,
        approved: Ruleset = [],
        prompt: @escaping PermissionPrompter,
        persist: (@Sendable (Ruleset) async -> Void)? = nil
    ) {
        self.rulesetProvider = rulesetProvider
        self.sessionApproved = approved
        self.prompt = prompt
        self.persist = persist
    }

    /// The verdict for a tool call. Evaluates each concrete pattern; a `deny`
    /// short-circuits to a denial with a model-visible reason, an all-`allow` call
    /// runs with no prompt, and any `ask` prompts the surface once for the whole call.
    public func ask(_ spec: PermissionRequestSpec, sessionID: String) async -> PermissionDecision {
        var needsAsk = false
        for (index, pattern) in spec.patterns.enumerated() {
            // Every spelling of the resource is checked, not just the one the model
            // used — see `PermissionRequestSpec.patternAliases`. Aliases describe the
            // FIRST pattern only; a multi-pattern spec (bash) has none.
            let spellings = index == 0 ? [pattern] + spec.patternAliases : [pattern]
            var action = resolvedAction(spec.permission, spellings)
            // Config-protection: a broad allow must not silently cover the agent's own
            // permission/settings files — force a prompt.
            if spec.configProtected, action == .allow { action = .ask }
            switch action {
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

    /// Fold the verdicts for every spelling of one resource.
    ///
    /// Deny-first, then allow: a deny on ANY spelling denies (so a rule cannot be
    /// side-stepped by renaming the same file), and an allow on any spelling allows
    /// (so a grant is spelling-independent). Only if no spelling says anything does
    /// it fall through to a prompt.
    ///
    /// Each spelling goes through the base-vs-saved resolve, NOT a flat merge: a
    /// config `deny` beats a broad in-session "allow always" grant, which
    /// last-match-wins would not.
    private func resolvedAction(_ permission: String, _ spellings: [String]) -> PermissionAction {
        let baseRuleset = rulesetProvider()
        var sawAllow = false
        for spelling in spellings {
            switch resolvePermission(permission, spelling, config: baseRuleset, saved: sessionApproved).action {
            case .deny: return .deny
            case .allow: sawAllow = true
            case .ask: continue
            }
        }
        return sawAllow ? .allow : .ask
    }

    /// A model-visible denial reason. The model reads this as the tool's error result
    /// and can adapt (choose a different command, ask the user).
    private static func deniedReason(permission: String, pattern: String) -> String {
        "Permission denied by policy: the \"\(permission)\" action \"\(pattern)\" is not allowed."
    }
}
