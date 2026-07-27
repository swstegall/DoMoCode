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
        // A deny the user wrote by hand always wins over a grant we persist.
        //
        // Evaluation is last-match-wins, so simply appending a grant lets it overrule
        // an earlier deny from the next launch onwards. There are three cases, and
        // they want three different answers:
        //
        //  1. The grant's pattern EQUALS a deny — overwriting it in place would
        //     delete the user's rule outright. Refuse.
        //  2. A deny is STRICTLY NARROWER than the grant (`secrets.txt` under a `*`
        //     grant) — both can hold if the grant goes BEFORE the deny, since the
        //     narrower rule then matches last. Insert, do not drop.
        //  3. A deny is BROADER than the grant (`*.lock` covering `yarn.lock`) — no
        //     ordering satisfies both, because the deny is the more specific
        //     statement of intent about this file. Refuse.
        if let collision = patterns.first(where: {
            $0.action == .deny && denyBlocks($0.pattern, grantPattern.pattern)
        }) {
            // Case 1 and 3.
            if collision.pattern == grantPattern.pattern { continue }
            if wildcardMatch(grantPattern.pattern, collision.pattern) { continue }
        }
        if let index = patterns.firstIndex(where: { $0.pattern == grantPattern.pattern }) {
            patterns[index] = grantPattern
        } else if let firstCoveredDeny = patterns.firstIndex(where: {
            $0.action == .deny && wildcardMatch($0.pattern, grantPattern.pattern)
        }) {
            // Case 2: keep the narrower deny effective by putting the grant ahead of it.
            patterns.insert(grantPattern, at: firstCoveredDeny)
        } else {
            patterns.append(grantPattern)
        }
    }
    return PermissionConfigEntry(permission: existing.permission, value: .map(patterns))
}

/// Whether an existing `deny` and a new grant pattern overlap at all — in either
/// direction, since a grant can be wider or narrower than the deny it meets.
private func denyBlocks(_ denyPattern: String, _ grantPattern: String) -> Bool {
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
