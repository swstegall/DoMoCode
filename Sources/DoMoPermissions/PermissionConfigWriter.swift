// Copyright (c) 2025 Kilo Code / opencode contributors. MIT license.
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Persists "allow always" grants back into settings.json (the user's Phase 8 choice).
// Ports the effect of kilocode's `config.updateGlobal({permission: toConfig(rules)})`:
// merge the new grant rules into the existing `permission` block and rewrite the file,
// leaving every other setting — and the block's authored key order (precedence) —
// intact. Merging happens at the CONFIG level (not through `fromConfig`) so a `~`/
// `$HOME` in an existing pattern is NOT expanded to an absolute path on disk.

/// Return the settings.json text with `grants` merged into its `permission` block.
/// Preserves all other keys and order; creates the block if absent. A grant for an
/// existing `(permission, pattern)` overrides its action; a new pattern is appended
/// (so it wins under last-match-wins); a new permission key is appended.
public func settingsText(_ existingText: String, mergingGrants grants: Ruleset) -> String {
    var root = parseOrderedJSON(existingText) ?? .object([])
    if case .object = root {} else { root = .object([]) }

    let existingConfig = root["permission"].map { permissionConfig(from: $0) } ?? []
    let merged = mergeGrants(into: existingConfig, grants: grants)
    let updated = setObjectKey(root, "permission", orderedJSON(from: merged))
    return serializeOrderedJSON(updated) + "\n"
}

/// Merge grant rules into a config. `grants` are always rule-capable (bash/write/…),
/// so they land in object form.
func mergeGrants(into config: PermissionConfig, grants: Ruleset) -> PermissionConfig {
    var result = config
    for grantEntry in toConfig(grants) {
        if let index = result.firstIndex(where: { $0.permission == grantEntry.permission }) {
            result[index] = mergeEntry(result[index], grantEntry)
        } else {
            result.append(grantEntry)
        }
    }
    return result
}

private func mergeEntry(_ existing: PermissionConfigEntry, _ grant: PermissionConfigEntry) -> PermissionConfigEntry {
    guard case .map(let grantPatterns) = grant.value else { return grant }
    var patterns: [PatternRule]
    switch existing.value {
    case .map(let existingPatterns): patterns = existingPatterns
    case .action(let action): patterns = [PatternRule(pattern: "*", action: action)]
    case .none: patterns = []
    }
    for grantPattern in grantPatterns {
        if let index = patterns.firstIndex(where: { $0.pattern == grantPattern.pattern }) {
            patterns[index] = grantPattern
        } else {
            patterns.append(grantPattern)
        }
    }
    return PermissionConfigEntry(permission: existing.permission, value: .map(patterns))
}

/// A `PermissionConfig` as an ordered JSON value (for writing back).
func orderedJSON(from config: PermissionConfig) -> OrderedJSONValue {
    var pairs: [(key: String, value: OrderedJSONValue)] = []
    for entry in config {
        guard let value = entry.value else { pairs.append((entry.permission, .null)); continue }
        switch value {
        case .action(let action):
            pairs.append((entry.permission, .string(action.rawValue)))
        case .map(let patterns):
            let inner = patterns.map { (key: $0.pattern, value: $0.action.map { OrderedJSONValue.string($0.rawValue) } ?? .null) }
            pairs.append((entry.permission, .object(inner)))
        }
    }
    return .object(pairs)
}

/// Set (or insert, preserving order) a key on an ordered object.
private func setObjectKey(_ root: OrderedJSONValue, _ key: String, _ value: OrderedJSONValue) -> OrderedJSONValue {
    guard case .object(var pairs) = root else { return .object([(key, value)]) }
    if let index = pairs.firstIndex(where: { $0.key == key }) {
        pairs[index] = (key, value)
    } else {
        pairs.append((key, value))
    }
    return .object(pairs)
}
