// Copyright (c) 2025 opencode contributors. MIT license.
// https://github.com/sst/opencode — packages/opencode/src/permission/index.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The pure policy core. `evaluate` is opencode's `findLast` matcher (LAST rule whose
// permission-dim AND pattern-dim both glob-match wins; default `ask`); `merge` is an
// order-preserving concat; `readHarden` ports kilocode's `.env`-secret guard (a broad
// `read` allow is downgraded to `ask` for `*.env`/`*.env.*`, except `*.env.example`);
// `disabled` ports opencode's tool-visibility filter; `resolvePermission` ports
// kilocode's base-vs-saved `resolve` layering (dropping only the agent-mode /
// external_directory / hardRuleset pieces DoMoCode has no equivalent for). The
// layering is load-bearing: a config `deny` must beat any broad in-session "allow
// always" grant, which a flat `evaluate(merge(config, saved))` does NOT guarantee
// (last-match-wins would let the appended grant win).

/// A permission decision. Runtime literal order is `allow, deny, ask` (opencode).
public enum PermissionAction: String, Sendable, Hashable, Codable {
    case allow
    case deny
    case ask
}

/// One rule: `permission` (tool key / glob) and `pattern` (resource/command glob) are
/// both globs matched by ``wildcardMatch(_:_:)``; `action` is the verdict.
public struct PermissionRule: Sendable, Hashable {
    public var permission: String
    public var pattern: String
    public var action: PermissionAction

    public init(permission: String, pattern: String, action: PermissionAction) {
        self.permission = permission
        self.pattern = pattern
        self.action = action
    }
}

/// An ordered ruleset. Order is load-bearing — `evaluate` is last-match-wins.
public typealias Ruleset = [PermissionRule]

/// The verdict for `(permission, pattern)` against the flattened `rulesets`.
///
/// Flattens the rulesets in argument order, then returns the LAST rule whose
/// permission-dim (`wildcardMatch(permission, rule.permission)`) AND pattern-dim
/// (`wildcardMatch(pattern, rule.pattern)`) both match. Nothing matches -> the default
/// `{ action: .ask, permission: <queried>, pattern: "*" }`. Ported verbatim from
/// opencode's `evaluate` (identical in kilocode).
public func evaluate(_ permission: String, _ pattern: String, _ rulesets: Ruleset...) -> PermissionRule {
    evaluate(permission, pattern, rulesets: rulesets)
}

/// Array-taking form of ``evaluate(_:_:_:)`` (the variadic splat is inconvenient to
/// forward otherwise).
public func evaluate(_ permission: String, _ pattern: String, rulesets: [Ruleset]) -> PermissionRule {
    let flattened = rulesets.flatMap { $0 }
    if let rule = flattened.last(where: {
        wildcardMatch(permission, $0.permission) && wildcardMatch(pattern, $0.pattern)
    }) {
        return rule
    }
    return PermissionRule(permission: permission, pattern: "*", action: .ask)
}

/// Order-preserving concatenation. Ports opencode's `merge` (`rulesets.flat()`).
public func merge(_ rulesets: Ruleset...) -> Ruleset {
    rulesets.flatMap { $0 }
}

/// Whether a rule is "broad" — its permission OR pattern is the bare `*`. Ports
/// kilocode's `PermissionRule.broad`.
public func isBroad(_ rule: PermissionRule) -> Bool {
    rule.permission == "*" || rule.pattern == "*"
}

/// Resolve `(permission, pattern)` against the CONFIG ruleset (`base`) and the
/// in-session grants (`saved`), giving config precedence. Ports kilocode's `resolve`:
/// `base` is `evaluate` over config with the `.env` guard applied; `saved` is
/// `evaluate` over the session grants. Precedence:
///   1. a config `deny` is final (checked before `saved` is even consulted),
///   2. then a saved `deny` is final,
///   3. a config `ask` is promoted to a saved `allow` ONLY if the saved rule's
///      pattern falls within the config rule's pattern (`wildcardMatch(saved, base)`)
///      — so a blanket `*` grant cannot lift a targeted `.env`/`deny`-adjacent ask,
///   4. otherwise a saved `allow` wins over a config `allow`.
/// This is why an "allow always" grant cannot silently override a `deny` the user (or
/// the baseline) configured — the flaw a flat merge has.
public func resolvePermission(_ permission: String, _ pattern: String, config: Ruleset, saved: Ruleset) -> PermissionRule {
    let base = readHarden(permission, pattern, evaluate(permission, pattern, config))
    let savedRule = evaluate(permission, pattern, saved)
    if base.action == .deny { return base }
    if savedRule.action == .deny { return savedRule }
    if base.action == .ask {
        if savedRule.action == .allow, wildcardMatch(savedRule.pattern, base.pattern) { return savedRule }
        return base
    }
    if savedRule.action == .allow { return savedRule }
    return base
}

/// The `.env`-secret read guard. Ports kilocode's `ReadPermission.harden`: a BROAD
/// `read` allow is downgraded to `ask` for a `*.env` / `*.env.*` resource (narrowing
/// the rule's pattern to the matched glob), with a `*.env.example` exception. A
/// specific (non-broad) allow, or any non-`read`/non-`allow` rule, passes through.
///
/// Applied to the evaluated result so a broad `read` allow — from config OR a
/// persisted "always" grant — can never silently expose a secrets file.
public func readHarden(_ permission: String, _ pattern: String, _ rule: PermissionRule) -> PermissionRule {
    guard permission == "read", rule.action == .allow else { return rule }
    guard let narrowed = envGuard(pattern) else { return rule }
    guard isBroad(rule) else { return rule }
    return PermissionRule(permission: permission, pattern: narrowed, action: .ask)
}

/// Classifies a read path as a protected secrets file. Ports kilocode's `guard`:
/// `*.env.example` -> nil (the exception); else `*.env` -> `"*.env"`; else `*.env.*`
/// -> `"*.env.*"`; else nil.
private func envGuard(_ pattern: String) -> String? {
    if wildcardMatch(pattern, "*.env.example") { return nil }
    if wildcardMatch(pattern, "*.env") { return "*.env" }
    if wildcardMatch(pattern, "*.env.*") { return "*.env.*" }
    return nil
}

/// The tools hidden from the model by a `ruleset`. Ports opencode's `disabled`: a tool
/// is hidden iff the LAST rule matching its permission-dim (pattern-dim ignored here)
/// has `pattern == "*"` AND `action == .deny`. `edit`/`write`/`apply_patch` alias to
/// the `edit` permission. Used by 8d to drop `deny`'d (MCP) tools from the schema.
public func disabledTools(_ tools: [String], _ ruleset: Ruleset) -> Set<String> {
    let edits: Set<String> = ["edit", "write", "apply_patch"]
    var hidden: Set<String> = []
    for tool in tools {
        let permission = edits.contains(tool) ? "edit" : tool
        let rule = ruleset.last { wildcardMatch(permission, $0.permission) }
        if rule?.pattern == "*", rule?.action == .deny { hidden.insert(tool) }
    }
    return hidden
}
