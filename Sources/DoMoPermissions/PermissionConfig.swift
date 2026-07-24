// Copyright (c) 2025 opencode contributors. MIT license.
// Copyright (c) 2025 Kilo Code / opencode contributors. MIT license.
// https://github.com/sst/opencode — permission/index.ts (fromConfig / toConfig / expand)
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The on-disk <-> ruleset bridge. `PermissionConfig` is an ORDER-PRESERVING model of
// the settings.json `permission` block — order drives `evaluate`'s last-match-wins
// precedence, so a plain (unordered) dictionary cannot represent it. `fromConfig`
// expands it to a `Ruleset` (with `~`/`$HOME` expansion and kilocode's `null` delete
// sentinel); `toConfig` is the inverse used to persist "always" grants.

/// A permission value in config: a bare action, or an ordered pattern->action map.
/// `nil` entries are kilocode's delete sentinel (dropped on load).
public enum PermissionConfigValue: Sendable, Equatable {
    case action(PermissionAction)
    /// Ordered pattern rules; a `nil` action is the delete sentinel.
    case map([PatternRule])
}

/// One ordered `pattern -> action` entry inside a permission's map. `action == nil`
/// is the delete sentinel.
public struct PatternRule: Sendable, Equatable {
    public var pattern: String
    public var action: PermissionAction?
    public init(pattern: String, action: PermissionAction?) {
        self.pattern = pattern
        self.action = action
    }
}

/// One ordered top-level `permission -> value` entry. `value == nil` is the delete
/// sentinel (the whole key is removed).
public struct PermissionConfigEntry: Sendable, Equatable {
    public var permission: String
    public var value: PermissionConfigValue?
    public init(permission: String, value: PermissionConfigValue?) {
        self.permission = permission
        self.value = value
    }
}

/// The `permission` config block, order preserved.
public typealias PermissionConfig = [PermissionConfigEntry]

/// Expand a leading `~` / `$HOME`. Ports opencode's `expand` — only at string START;
/// a `~` mid-string is left literal. `homeDirectory` is injected (opencode reads
/// `os.homedir()`) so the port is deterministic and testable.
public func expandHome(_ pattern: String, homeDirectory: String) -> String {
    if pattern.hasPrefix("~/") { return homeDirectory + String(pattern.dropFirst(1)) }
    if pattern == "~" { return homeDirectory }
    if pattern.hasPrefix("$HOME/") { return homeDirectory + String(pattern.dropFirst(5)) }
    if pattern.hasPrefix("$HOME") { return homeDirectory + String(pattern.dropFirst(5)) }
    return pattern
}

/// Expand a `PermissionConfig` into a flat `Ruleset`, preserving order. Ports
/// opencode's `fromConfig` + kilocode's `null`-sentinel filtering. A bare-action value
/// becomes one `{key, "*", action}` rule (pattern NOT expanded — always literal `*`);
/// a map becomes one rule per non-`nil` entry with the pattern run through
/// ``expandHome(_:homeDirectory:)``.
public func fromConfig(_ config: PermissionConfig, homeDirectory: String) -> Ruleset {
    var ruleset: Ruleset = []
    for entry in config {
        guard let value = entry.value else { continue }  // top-level null: delete sentinel
        switch value {
        case .action(let action):
            ruleset.append(PermissionRule(permission: entry.permission, pattern: "*", action: action))
        case .map(let patterns):
            for pattern in patterns {
                guard let action = pattern.action else { continue }  // null: delete sentinel
                ruleset.append(
                    PermissionRule(
                        permission: entry.permission,
                        pattern: expandHome(pattern.pattern, homeDirectory: homeDirectory),
                        action: action
                    )
                )
            }
        }
    }
    return ruleset
}

/// Permissions that serialize as a bare action string (never a map). Ports kilocode's
/// `SCALAR_ONLY_PERMISSIONS`. DoMoCode has none of these tools today, but the set is
/// carried so the `toConfig` round-trip stays faithful to the corpus.
private let scalarOnlyPermissions: Set<String> = [
    "todowrite", "todoread", "question", "webfetch", "websearch", "doom_loop",
]

/// The inverse of ``fromConfig(_:homeDirectory:)`` — serialize a `Ruleset` back to the
/// on-disk shape for persisting "always" grants. Ports kilocode's `toConfig`:
/// rule-capable permissions ALWAYS emit object form (even a lone `*`, so a merge never
/// erases a sibling granular rule); a scalar-only permission emits a bare action and
/// drops any non-`*` pattern (it cannot be represented). Order of first appearance is
/// preserved for both permissions and patterns.
public func toConfig(_ rules: Ruleset) -> PermissionConfig {
    // Track insertion order + allow in-place update of a permission's value.
    var order: [String] = []
    var values: [String: PermissionConfigValue] = [:]

    func upsert(_ permission: String, _ transform: (PermissionConfigValue?) -> PermissionConfigValue?) {
        let existing = values[permission]
        if existing == nil, !order.contains(permission) { order.append(permission) }
        if let next = transform(existing) {
            values[permission] = next
        }
    }

    for rule in rules {
        if scalarOnlyPermissions.contains(rule.permission) {
            guard rule.pattern == "*" else { continue }  // non-* pattern is unrepresentable -> drop
            upsert(rule.permission) { _ in .action(rule.action) }
            continue
        }
        upsert(rule.permission) { existing in
            switch existing {
            case .none:
                return .map([PatternRule(pattern: rule.pattern, action: rule.action)])
            case .action(let scalar):
                // Promote a bare scalar to object form, keeping it under "*".
                return .map([
                    PatternRule(pattern: "*", action: scalar),
                    PatternRule(pattern: rule.pattern, action: rule.action),
                ])
            case .map(var patterns):
                if let index = patterns.firstIndex(where: { $0.pattern == rule.pattern }) {
                    patterns[index] = PatternRule(pattern: rule.pattern, action: rule.action)
                } else {
                    patterns.append(PatternRule(pattern: rule.pattern, action: rule.action))
                }
                return .map(patterns)
            }
        }
    }

    return order.compactMap { permission in
        values[permission].map { PermissionConfigEntry(permission: permission, value: $0) }
    }
}
