// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Reads the `permission` block from settings.json into an order-preserving
// ``PermissionConfig``. A top-level bare action string normalizes to `{ "*": action }`
// (opencode's `normalizeInput`); a per-key bare string becomes a `*` rule via
// ``fromConfig(_:homeDirectory:)`; `null` is the delete sentinel. Malformed entries
// are skipped rather than failing the whole load — a bad permission rule must not
// brick the CLI.

/// Extract the `permission` config from a settings.json document's text. Returns an
/// empty config if the file has no `permission` key or does not parse.
public func permissionConfig(fromSettingsText text: String) -> PermissionConfig {
    guard let root = parseOrderedJSON(text), let permission = root["permission"] else { return [] }
    return permissionConfig(from: permission)
}

/// Convert a parsed `permission` value into an ordered ``PermissionConfig``.
public func permissionConfig(from value: OrderedJSONValue) -> PermissionConfig {
    // A bare top-level action string means "this action for everything".
    if case .string(let raw) = value {
        guard let action = PermissionAction(rawValue: raw) else { return [] }
        return [PermissionConfigEntry(permission: "*", value: .action(action))]
    }
    guard case .object(let entries) = value else { return [] }

    var config: PermissionConfig = []
    for (key, entryValue) in entries {
        switch entryValue {
        case .null:
            config.append(PermissionConfigEntry(permission: key, value: nil))  // delete sentinel
        case .string(let raw):
            guard let action = PermissionAction(rawValue: raw) else { continue }
            config.append(PermissionConfigEntry(permission: key, value: .action(action)))
        case .object(let patterns):
            var rules: [PatternRule] = []
            for (pattern, patternValue) in patterns {
                switch patternValue {
                case .null:
                    rules.append(PatternRule(pattern: pattern, action: nil))  // delete sentinel
                case .string(let raw):
                    guard let action = PermissionAction(rawValue: raw) else { continue }
                    rules.append(PatternRule(pattern: pattern, action: action))
                default:
                    continue  // malformed pattern value — skip
                }
            }
            config.append(PermissionConfigEntry(permission: key, value: .map(rules)))
        default:
            continue  // malformed permission value — skip
        }
    }
    return config
}
