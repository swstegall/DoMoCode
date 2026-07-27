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

/// Return the settings.json text with `grants` merged into its `permission` block, or
/// `nil` to ABORT — the caller must then leave the file untouched. Aborting protects
/// the user's other settings: an existing file that is non-empty but does not parse as
/// a JSON object is never overwritten (a clobber would silently destroy hand-authored
/// settings). Otherwise all other keys and the block's authored order are preserved; a
/// grant for an existing `(permission, pattern)` overrides its action, a new pattern is
/// appended (so it wins under last-match-wins), and a new permission key is appended.
public func settingsText(_ existingText: String, mergingGrants grants: Ruleset) -> String? {
    let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
    let root: OrderedJSONValue
    if trimmed.isEmpty {
        root = .object([])
    } else if let parsed = parseOrderedJSON(existingText), case .object = parsed {
        root = parsed
    } else {
        return nil  // present but unparseable / not an object — do NOT clobber it
    }

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
        // Never let a persisted grant overrule a deny the user wrote by hand.
        //
        // Evaluation is last-match-wins and a new pattern is APPENDED, so a grant
        // written after an existing deny silently wins over it from the next launch
        // onwards — `{"yarn.lock": "deny"}` plus an appended allow that also matches
        // `yarn.lock` turns the user's own rule off. The engine will not normally
        // prompt for something already denied, so reaching this is a sign the config
        // changed underneath us; either way the safe direction is to keep the deny.
        if patterns.contains(where: { $0.action == .deny && denyCovers($0.pattern, grantPattern.pattern) }) {
            continue
        }
        if let index = patterns.firstIndex(where: { $0.pattern == grantPattern.pattern }) {
            patterns[index] = grantPattern
        } else {
            patterns.append(grantPattern)
        }
    }
    return PermissionConfigEntry(permission: existing.permission, value: .map(patterns))
}

/// Whether an existing `deny` pattern covers everything a new grant pattern would
/// allow. Both directions are checked: a deny of `*.lock` covers a grant of
/// `yarn.lock`, and a deny of `yarn.lock` is covered by a grant of `*` — in which
/// case the broad grant would bury it and must also be refused.
private func denyCovers(_ denyPattern: String, _ grantPattern: String) -> Bool {
    wildcardMatch(grantPattern, denyPattern) || wildcardMatch(denyPattern, grantPattern)
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
