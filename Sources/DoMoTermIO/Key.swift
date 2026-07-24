// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/keys.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

/// The base key a ``KeyId`` names, stripped of modifiers.
///
/// pi encodes the whole key identifier — base plus modifiers — as one string
/// (`"ctrl+shift+p"`) and leans on TypeScript template-literal types to make it
/// autocomplete and typo-proof. Swift has no template-literal types, so the
/// grammar becomes a value: a `BaseKey` case plus four modifier flags on
/// ``KeyId``. Splitting the base out this way is what lets the matcher `switch`
/// exhaustively instead of dispatching on a lowercased substring, and it makes
/// the whole thing a first-class dictionary key so the keybinding table can be
/// an ordinary `[KeyId: …]`.
///
/// `char` carries printable keys (letters, digits, and the symbol set). Letters
/// are canonicalised to lowercase when a modifier is present — pi's matcher
/// lowercases the identifier before comparing, so `ctrl+C` and `ctrl+c` denote
/// the same binding and must hash the same — while an unmodified printable is
/// stored verbatim so ``parseKey`` can round-trip a literal `A` the way pi does.
public enum BaseKey: Hashable, Sendable {
    case char(Character)

    case escape
    case enter
    case tab
    case space
    case backspace
    case delete
    case insert
    case clear
    case home
    case end
    case pageUp
    case pageDown
    case up
    case down
    case left
    case right
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

extension BaseKey {
    /// The lowercase token pi would print for this key: `"up"`, `"pageUp"`,
    /// `"f5"`, or the literal character. Used only for ``KeyId/description`` and
    /// parsing; matching never routes through a string.
    var name: String {
        switch self {
        case .char(let c): return String(c)
        case .escape: return "escape"
        case .enter: return "enter"
        case .tab: return "tab"
        case .space: return "space"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .insert: return "insert"
        case .clear: return "clear"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .f1: return "f1"
        case .f2: return "f2"
        case .f3: return "f3"
        case .f4: return "f4"
        case .f5: return "f5"
        case .f6: return "f6"
        case .f7: return "f7"
        case .f8: return "f8"
        case .f9: return "f9"
        case .f10: return "f10"
        case .f11: return "f11"
        case .f12: return "f12"
        }
    }

    /// Case-insensitive lookup of a special-key name, matching pi's `parseKeyId`
    /// which lowercases the whole identifier before dispatch. Returns `nil` for
    /// anything that is not a reserved special-key word, so the caller falls
    /// through to treating the token as a single printable character.
    static func special(named token: String) -> BaseKey? {
        switch token.lowercased() {
        case "escape", "esc": return .escape
        case "enter", "return": return .enter
        case "tab": return .tab
        case "space": return .space
        case "backspace": return .backspace
        case "delete": return .delete
        case "insert": return .insert
        case "clear": return .clear
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "f1": return .f1
        case "f2": return .f2
        case "f3": return .f3
        case "f4": return .f4
        case "f5": return .f5
        case "f6": return .f6
        case "f7": return .f7
        case "f8": return .f8
        case "f9": return .f9
        case "f10": return .f10
        case "f11": return .f11
        case "f12": return .f12
        default: return nil
        }
    }
}

/// A key press identified by its base key and the modifiers held with it.
///
/// This is pi's `KeyId` string type reified as a value. Being `Hashable` and
/// `Sendable` is the whole point: the keybinding table keys on it, and it
/// crosses off the main actor into measurement and test paths, so it cannot be
/// a class or carry reference state.
public struct KeyId: Hashable, Sendable {
    public var base: BaseKey
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool
    public var superKey: Bool

    public init(
        base: BaseKey,
        shift: Bool = false,
        alt: Bool = false,
        ctrl: Bool = false,
        superKey: Bool = false
    ) {
        self.base = base
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
        self.superKey = superKey
    }
}

extension KeyId {
    /// The modifier bitmask pi uses internally: shift 1, alt 2, ctrl 4, super 8.
    /// Kept identical to the wire encoding so the matcher can compare masks
    /// directly against a parsed Kitty/`modifyOtherKeys` sequence.
    var modifierMask: Int {
        var m = 0
        if shift { m |= KeyModifier.shift }
        if alt { m |= KeyModifier.alt }
        if ctrl { m |= KeyModifier.ctrl }
        if superKey { m |= KeyModifier.super }
        return m
    }
}

extension KeyId: CustomStringConvertible {
    /// pi-style rendering (`"ctrl+shift+p"`). Modifier order matches upstream's
    /// `formatKeyNameWithModifiers` — shift, ctrl, alt, super — so a parsed key
    /// prints the way the keybinding tables are written.
    public var description: String {
        var parts: [String] = []
        if shift { parts.append("shift") }
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if superKey { parts.append("super") }
        parts.append(base.name)
        return parts.joined(separator: "+")
    }
}

// MARK: - Parsing

extension KeyId {
    /// Parse an identifier string such as `"ctrl+alt+]"`.
    ///
    /// Mirrors pi's `parseKeyId`: split on `+`, the last segment is the key and
    /// the rest are modifier names. Returns `nil` for an empty or malformed
    /// string. This exists so the default keybinding table can be written the
    /// way upstream writes it; hand-built keys go through ``init(base:…)`` or the
    /// ``Key`` helpers.
    public init?(parsing identifier: String) {
        let parts = identifier.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyToken = parts.last, !keyToken.isEmpty else { return nil }
        let modifiers = Set(parts.dropLast().map { $0.lowercased() })

        let base: BaseKey
        if let special = BaseKey.special(named: keyToken) {
            base = special
        } else if keyToken.count == 1 {
            base = .char(KeyId.normalizeBaseChar(keyToken.first!))
        } else {
            return nil
        }

        self.init(
            base: base,
            shift: modifiers.contains("shift"),
            alt: modifiers.contains("alt"),
            ctrl: modifiers.contains("ctrl"),
            superKey: modifiers.contains("super")
        )
    }

    /// Lowercase ASCII letters so `Key.ctrl("C")` and a bound `ctrl+c` compare
    /// and hash the same. Symbols and non-letters pass through untouched — pi's
    /// matcher lowercases the identifier, and lowercasing a symbol is a no-op.
    static func normalizeBaseChar(_ c: Character) -> Character {
        if let s = c.unicodeScalars.first, c.unicodeScalars.count == 1, s.value >= 65, s.value <= 90 {
            return Character(Unicode.Scalar(s.value + 32)!)
        }
        return c
    }
}

// MARK: - Key helper

/// Ergonomic, typo-resistant constructors for ``KeyId``.
///
/// This is pi's `Key` object. `Key.ctrl("c")`, `Key.ctrlShift("p")`, `Key.up`,
/// `Key.f5` — the same surface, so downstream code reads the same. Letter
/// arguments are lowercased on the way in for the reasons in
/// ``KeyId/normalizeBaseChar(_:)``.
public enum Key {
    public static let escape = KeyId(base: .escape)
    public static let esc = KeyId(base: .escape)
    public static let enter = KeyId(base: .enter)
    public static let `return` = KeyId(base: .enter)
    public static let tab = KeyId(base: .tab)
    public static let space = KeyId(base: .space)
    public static let backspace = KeyId(base: .backspace)
    public static let delete = KeyId(base: .delete)
    public static let insert = KeyId(base: .insert)
    public static let clear = KeyId(base: .clear)
    public static let home = KeyId(base: .home)
    public static let end = KeyId(base: .end)
    public static let pageUp = KeyId(base: .pageUp)
    public static let pageDown = KeyId(base: .pageDown)
    public static let up = KeyId(base: .up)
    public static let down = KeyId(base: .down)
    public static let left = KeyId(base: .left)
    public static let right = KeyId(base: .right)
    public static let f1 = KeyId(base: .f1)
    public static let f2 = KeyId(base: .f2)
    public static let f3 = KeyId(base: .f3)
    public static let f4 = KeyId(base: .f4)
    public static let f5 = KeyId(base: .f5)
    public static let f6 = KeyId(base: .f6)
    public static let f7 = KeyId(base: .f7)
    public static let f8 = KeyId(base: .f8)
    public static let f9 = KeyId(base: .f9)
    public static let f10 = KeyId(base: .f10)
    public static let f11 = KeyId(base: .f11)
    public static let f12 = KeyId(base: .f12)

    static func base(_ c: Character) -> BaseKey {
        if let special = BaseKey.special(named: String(c)) { return special }
        return .char(KeyId.normalizeBaseChar(c))
    }

    public static func ctrl(_ c: Character) -> KeyId { KeyId(base: base(c), ctrl: true) }
    public static func shift(_ c: Character) -> KeyId { KeyId(base: base(c), shift: true) }
    public static func alt(_ c: Character) -> KeyId { KeyId(base: base(c), alt: true) }
    public static func `super`(_ c: Character) -> KeyId { KeyId(base: base(c), superKey: true) }

    public static func ctrlShift(_ c: Character) -> KeyId { KeyId(base: base(c), shift: true, ctrl: true) }
    public static func ctrlAlt(_ c: Character) -> KeyId { KeyId(base: base(c), alt: true, ctrl: true) }
    public static func ctrlSuper(_ c: Character) -> KeyId { KeyId(base: base(c), ctrl: true, superKey: true) }
    public static func shiftAlt(_ c: Character) -> KeyId { KeyId(base: base(c), shift: true, alt: true) }
    public static func altSuper(_ c: Character) -> KeyId { KeyId(base: base(c), alt: true, superKey: true) }
    public static func shiftSuper(_ c: Character) -> KeyId { KeyId(base: base(c), shift: true, superKey: true) }

    public static func ctrlShiftAlt(_ c: Character) -> KeyId {
        KeyId(base: base(c), shift: true, alt: true, ctrl: true)
    }
    public static func ctrlShiftSuper(_ c: Character) -> KeyId {
        KeyId(base: base(c), shift: true, ctrl: true, superKey: true)
    }
}
