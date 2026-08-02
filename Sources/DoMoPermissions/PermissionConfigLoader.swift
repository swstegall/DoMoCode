// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Reads the `permission` block from settings.json into an order-preserving
// ``PermissionConfig``. A top-level bare action string normalizes to `{ "*": action }`
// (opencode's `normalizeInput`); a per-key bare string becomes a `*` rule via
// ``fromConfig(_:homeDirectory:)`; `null` is the delete sentinel.
//
// Two failure classes, deliberately treated differently:
//
//  - A malformed *entry* (`"bash": 42`, `"edit": "banana"`) is skipped and the rest
//    of the block still loads. A bad permission rule must not brick the CLI.
//  - A malformed *file* is reported. It used to yield `[]`, which meant the whole
//    permission block vanished with no message and — because
//    `PermissionSetup.persister` refuses to write a file it cannot parse — every
//    subsequent "Allow always" was dropped in silence too. Since Foundation would
//    still have read `model` and `baseUrl` out of the same bytes, nothing about the
//    run looked wrong.

import DoMoCore

/// Extract the `permission` config from a settings.json document's text, or throw a
/// ``ConfigDiagnostic`` locating the syntax error.
///
/// An absent `permission` key is **not** an error — it is the common case, and it
/// yields an empty config. Only a file that will not parse, or one whose top level is
/// not a JSON object, throws.
///
/// - Parameters:
///   - text: The settings.json document.
///   - file: The path to name in the diagnostic, when the text came from one.
public func permissionConfig(
    parsingSettingsText text: String,
    file: String? = nil
) throws(ConfigDiagnostic) -> PermissionConfig {
    let root = try parseOrderedJSON(text: text, file: file)
    guard case .object = root else {
        throw ConfigDiagnostic(
            file: file,
            source: Array(text.utf8),
            byteOffset: documentStartByteOffset(text),
            keyPath: [],
            problem: "settings must be a JSON object"
        )
    }
    guard let permission = root["permission"] else { return [] }
    return permissionConfig(from: permission)
}

/// Extract the `permission` config from a settings.json document's text. Returns an
/// empty config if the file has no `permission` key or does not parse.
///
/// The thin, reportless spelling. Prefer ``permissionConfig(parsingSettingsText:file:)``
/// anywhere there is a user to tell — a silently empty permission block is
/// indistinguishable from a file that deliberately configures none.
public func permissionConfig(fromSettingsText text: String) -> PermissionConfig {
    (try? permissionConfig(parsingSettingsText: text)) ?? []
}

/// The byte offset of the document's first real character: past a UTF-8 byte-order
/// mark and any leading whitespace.
///
/// So that "settings must be a JSON object" puts its caret under the `[` or the `4`
/// it is accusing, rather than under column one of a blank first line.
func documentStartByteOffset(_ text: String) -> Int {
    let bytes = Array(text.utf8)
    var offset = 0
    if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { offset = 3 }
    while offset < bytes.count {
        let byte = bytes[offset]
        guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { break }
        offset += 1
    }
    return offset
}

/// Convert a parsed `permission` value into an ordered ``PermissionConfig``.
///
/// Entry-level tolerance lives here: an unrecognized action or a value of the wrong
/// shape is dropped and the surrounding block survives.
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
