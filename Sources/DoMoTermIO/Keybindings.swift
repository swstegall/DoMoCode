// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/keybindings.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

/// A semantic action the editor and selection layers resolve against input.
///
/// pi keys these on free-form strings and lets downstream packages extend the
/// registry through TypeScript declaration merging. DoMoCode ships a fixed tool
/// surface (README non-goals), so the set is closed and modeled as an enum:
/// a user override for an unknown id is simply unrepresentable rather than
/// silently dropped, and every call site names the action by a checked case.
public enum Keybinding: String, CaseIterable, Sendable, Hashable {
    case editorCursorUp = "tui.editor.cursorUp"
    case editorCursorDown = "tui.editor.cursorDown"
    case editorCursorLeft = "tui.editor.cursorLeft"
    case editorCursorRight = "tui.editor.cursorRight"
    case editorCursorWordLeft = "tui.editor.cursorWordLeft"
    case editorCursorWordRight = "tui.editor.cursorWordRight"
    case editorCursorLineStart = "tui.editor.cursorLineStart"
    case editorCursorLineEnd = "tui.editor.cursorLineEnd"
    case editorJumpForward = "tui.editor.jumpForward"
    case editorJumpBackward = "tui.editor.jumpBackward"
    case editorPageUp = "tui.editor.pageUp"
    case editorPageDown = "tui.editor.pageDown"
    case editorDeleteCharBackward = "tui.editor.deleteCharBackward"
    case editorDeleteCharForward = "tui.editor.deleteCharForward"
    case editorDeleteWordBackward = "tui.editor.deleteWordBackward"
    case editorDeleteWordForward = "tui.editor.deleteWordForward"
    case editorDeleteToLineStart = "tui.editor.deleteToLineStart"
    case editorDeleteToLineEnd = "tui.editor.deleteToLineEnd"
    case editorYank = "tui.editor.yank"
    case editorYankPop = "tui.editor.yankPop"
    case editorUndo = "tui.editor.undo"
    case inputNewLine = "tui.input.newLine"
    case inputSubmit = "tui.input.submit"
    case inputTab = "tui.input.tab"
    case inputCopy = "tui.input.copy"
    case selectUp = "tui.select.up"
    case selectDown = "tui.select.down"
    case selectPageUp = "tui.select.pageUp"
    case selectPageDown = "tui.select.pageDown"
    case selectConfirm = "tui.select.confirm"
    case selectCancel = "tui.select.cancel"
}

/// A key claimed by more than one action under the user's overrides.
///
/// pi surfaces conflicts only among *user* bindings, never among defaults, and
/// this preserves that: a default table can legitimately reuse a key (Enter is
/// both submit and confirm), but a user pointing one key at two actions is a
/// mistake worth reporting.
public struct KeybindingConflict: Sendable, Hashable {
    public let key: KeyId
    public let keybindings: [Keybinding]
}

/// The resolved keybinding table: defaults, overlaid by user bindings, with the
/// matcher built on ``matchesKey(_:_:kittyProtocolActive:)``.
///
/// This is pi's `KeybindingsManager` made a value type. pi keeps a single
/// process-global instance and mutates it in place; the README forbids that.
/// Resolution happens once at construction, the result is immutable, and it is
/// injected wherever the ~40 downstream call sites need it — so two components
/// can hold two different tables and there is no shared mutable state to reason
/// about across isolation boundaries.
public struct Keybindings: Sendable {
    private let keysById: [Keybinding: [KeyId]]
    public let conflicts: [KeybindingConflict]

    /// Build a table from the defaults, overlaid by `userBindings`. An action
    /// present in `userBindings` is fully replaced (not merged) — matching pi,
    /// where a user entry supersedes the default rather than adding to it. Pass
    /// an empty override map for the stock bindings.
    public init(userBindings: [Keybinding: [KeyId]] = [:]) {
        var resolved: [Keybinding: [KeyId]] = [:]
        for action in Keybinding.allCases {
            let keys = userBindings[action] ?? Keybindings.defaults[action] ?? []
            resolved[action] = Keybindings.normalize(keys)
        }
        self.keysById = resolved

        // Conflicts are computed over user claims only, preserving insertion
        // order of the claimant list for stable reporting.
        var claims: [KeyId: [Keybinding]] = [:]
        var order: [KeyId] = []
        for action in Keybinding.allCases {
            guard let keys = userBindings[action] else { continue }
            for key in Keybindings.normalize(keys) {
                if claims[key] == nil { order.append(key) }
                if !(claims[key]?.contains(action) ?? false) {
                    claims[key, default: []].append(action)
                }
            }
        }
        self.conflicts = order.compactMap { key in
            let actions = claims[key] ?? []
            return actions.count > 1 ? KeybindingConflict(key: key, keybindings: actions) : nil
        }
    }

    /// Does `data` trigger `keybinding` under this table? Tries every key bound
    /// to the action in order. `kittyProtocolActive` threads through to the
    /// decoder, defaulting to the legacy interpretation.
    public func matches(_ data: [UInt8], _ keybinding: Keybinding, kittyProtocolActive: Bool = false) -> Bool {
        for key in keysById[keybinding] ?? [] {
            if matchesKey(data, key, kittyProtocolActive: kittyProtocolActive) { return true }
        }
        return false
    }

    /// The resolved keys bound to `keybinding`.
    public func keys(for keybinding: Keybinding) -> [KeyId] {
        keysById[keybinding] ?? []
    }

    private static func normalize(_ keys: [KeyId]) -> [KeyId] {
        var seen = Set<KeyId>()
        var result: [KeyId] = []
        for key in keys where seen.insert(key).inserted {
            result.append(key)
        }
        return result
    }

    /// The stock bindings, ported verbatim from pi's `TUI_KEYBINDINGS`.
    public static let defaults: [Keybinding: [KeyId]] = [
        .editorCursorUp: [Key.up],
        .editorCursorDown: [Key.down],
        .editorCursorLeft: [Key.left, Key.ctrl("b")],
        .editorCursorRight: [Key.right, Key.ctrl("f")],
        .editorCursorWordLeft: [KeyId(base: .left, alt: true), KeyId(base: .left, ctrl: true), Key.alt("b")],
        .editorCursorWordRight: [KeyId(base: .right, alt: true), KeyId(base: .right, ctrl: true), Key.alt("f")],
        .editorCursorLineStart: [Key.home, Key.ctrl("a")],
        .editorCursorLineEnd: [Key.end, Key.ctrl("e")],
        .editorJumpForward: [Key.ctrl("]")],
        .editorJumpBackward: [Key.ctrlAlt("]")],
        .editorPageUp: [Key.pageUp],
        .editorPageDown: [Key.pageDown],
        .editorDeleteCharBackward: [Key.backspace],
        .editorDeleteCharForward: [Key.delete, Key.ctrl("d")],
        .editorDeleteWordBackward: [Key.ctrl("w"), KeyId(base: .backspace, alt: true)],
        .editorDeleteWordForward: [Key.alt("d"), KeyId(base: .delete, alt: true)],
        .editorDeleteToLineStart: [Key.ctrl("u")],
        .editorDeleteToLineEnd: [Key.ctrl("k")],
        .editorYank: [Key.ctrl("y")],
        .editorYankPop: [Key.alt("y")],
        .editorUndo: [Key.ctrl("-")],
        .inputNewLine: [KeyId(base: .enter, shift: true), Key.ctrl("j")],
        .inputSubmit: [Key.enter],
        .inputTab: [Key.tab],
        .inputCopy: [Key.ctrl("c")],
        .selectUp: [Key.up],
        .selectDown: [Key.down],
        .selectPageUp: [Key.pageUp],
        .selectPageDown: [Key.pageDown],
        .selectConfirm: [Key.enter],
        .selectCancel: [Key.escape, Key.ctrl("c")],
    ]
}
