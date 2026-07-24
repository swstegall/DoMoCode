// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/keys.ts
// Copyright (c) 2025 opentui. MIT license.  https://github.com/anomalyco/opentui
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The public, pure key decoder. Framed terminal-input bytes go in; a `KeyId`,
// a match verdict, or decoded text comes out. Nothing here touches the terminal
// or any global: the Kitty-protocol state pi keeps in a module variable is a
// parameter here, so the same bytes always decode the same way. That is the
// non-negotiable the README names — every keybinding layer is built on this
// function, so it stays independently testable rather than a method on a
// terminal type.

// MARK: - Modifier and codepoint constants

/// Modifier bits as they travel in Kitty / `modifyOtherKeys` sequences.
enum KeyModifier {
    static let shift = 1
    static let alt = 2
    static let ctrl = 4
    static let `super` = 8
}

/// Caps Lock (64) + Num Lock (128). Masked out before comparing modifiers: a
/// binding must fire whether or not a lock light is on.
private let lockMask = 64 + 128

private enum Codepoint {
    static let escape = 27
    static let tab = 9
    static let enter = 13
    static let space = 32
    static let backspace = 127
    static let kpEnter = 57414  // Numpad Enter (Kitty protocol)
}

// Negative sentinels for keys that have no Unicode codepoint. Kept identical to
// pi so the shared normalization logic lines up.
private enum ArrowCodepoint {
    static let up = -1
    static let down = -2
    static let right = -3
    static let left = -4
}

private enum FunctionalCodepoint {
    static let delete = -10
    static let insert = -11
    static let pageUp = -12
    static let pageDown = -13
    static let home = -14
    static let end = -15
}

private let symbolKeys: Set<Character> = [
    "`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
    "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+",
    "|", "~", "{", "}", ":", "<", ">", "?",
]

/// Kitty reports numpad keys with private-use codepoints; a binding cares about
/// the key they stand for. Normalizing here is what makes `KP_1` match `1`.
private let kittyFunctionalEquivalents: [Int: Int] = [
    57399: 48, 57400: 49, 57401: 50, 57402: 51, 57403: 52,
    57404: 53, 57405: 54, 57406: 55, 57407: 56, 57408: 57,
    57409: 46, 57410: 47, 57411: 42, 57412: 45, 57413: 43,
    57415: 61, 57416: 44,
    57417: ArrowCodepoint.left,
    57418: ArrowCodepoint.right,
    57419: ArrowCodepoint.up,
    57420: ArrowCodepoint.down,
    57421: FunctionalCodepoint.pageUp,
    57422: FunctionalCodepoint.pageDown,
    57423: FunctionalCodepoint.home,
    57424: FunctionalCodepoint.end,
    57425: FunctionalCodepoint.insert,
    57426: FunctionalCodepoint.delete,
]

private func normalizeKittyFunctionalCodepoint(_ codepoint: Int) -> Int {
    kittyFunctionalEquivalents[codepoint] ?? codepoint
}

/// Shift + an uppercase-letter codepoint denotes the same key as the lowercase
/// letter; collapse them so `shift+A` and `shift+a` are one binding.
private func normalizeShiftedLetterIdentityCodepoint(_ codepoint: Int, _ modifier: Int) -> Int {
    let effective = modifier & ~lockMask
    if (effective & KeyModifier.shift) != 0, codepoint >= 65, codepoint <= 90 {
        return codepoint + 32
    }
    return codepoint
}

// MARK: - Byte helpers

private let esc: UInt8 = 0x1b

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Does `haystack` contain `needle` as a contiguous subsequence? Used only by
/// the event-type substring heuristics, which pi expresses as `String.includes`.
private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if haystack.count < needle.count { return false }
    let last = haystack.count - needle.count
    var i = 0
    while i <= last {
        var j = 0
        while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
        if j == needle.count { return true }
        i += 1
    }
    return false
}

// MARK: - CSI parsing

/// A parsed `CSI` sequence: `ESC [` then numeric parameters separated by `;`,
/// each with `:`-separated sub-parameters, then one final byte.
///
/// All three wire encodings this decoder handles (Kitty CSI-u, modified legacy
/// forms, and xterm `modifyOtherKeys`) are `CSI` sequences, so one tolerant
/// parser replaces pi's four hand-tuned regexes. An empty parameter is `nil`,
/// which is how CSI-u carries "no shifted key" as `<cp>::<base>`.
private struct ParsedCSI {
    var params: [[Int?]]
    var finalByte: UInt8
}

private func parseCSI(_ data: [UInt8]) -> ParsedCSI? {
    guard data.count >= 3, data[0] == esc, data[1] == 0x5b else { return nil }  // ESC [
    let finalByte = data[data.count - 1]
    // The final byte is the alphabetic/`~` terminator; a digit, ':' or ';'
    // means the sequence is truncated and belongs to nobody.
    if finalByte >= 0x30, finalByte <= 0x3b { return nil }

    var params: [[Int?]] = []
    var currentParam: [Int?] = []
    var currentNumber = 0
    var hasDigits = false

    func flushSub() {
        currentParam.append(hasDigits ? currentNumber : nil)
        currentNumber = 0
        hasDigits = false
    }

    var i = 2
    let end = data.count - 1
    while i < end {
        let byte = data[i]
        switch byte {
        case 0x30...0x39:
            // Cap accumulation so a long digit run from a garbage/hostile
            // terminal cannot overflow `Int` and trap the renderer. No
            // meaningful parameter (max codepoint U+10FFFF, small modifiers)
            // exceeds this ceiling; anything past it stops growing and lands on
            // a value that maps to no key, so the sequence decodes to `nil`.
            if currentNumber <= 0x10FFFF {
                currentNumber = currentNumber * 10 + Int(byte - 0x30)
            }
            hasDigits = true
        case 0x3a:  // ':'
            flushSub()
        case 0x3b:  // ';'
            flushSub()
            params.append(currentParam)
            currentParam = []
        default:
            return nil  // an intermediate byte we do not model
        }
        i += 1
    }
    flushSub()
    params.append(currentParam)
    return ParsedCSI(params: params, finalByte: finalByte)
}

private func param(_ params: [[Int?]], _ p: Int, _ s: Int) -> Int? {
    guard params.indices.contains(p), params[p].indices.contains(s) else { return nil }
    return params[p][s]
}

// MARK: - Kitty protocol parsing

/// Event types from Kitty keyboard protocol flag 2.
public enum KeyEventType: Sendable, Hashable {
    case press
    case `repeat`
    case release
}

private struct ParsedKittySequence {
    var codepoint: Int
    var shiftedKey: Int?
    var baseLayoutKey: Int?
    var modifier: Int
    var eventType: KeyEventType
}

private struct ParsedModifyOtherKeys {
    var codepoint: Int
    var modifier: Int
}

private func parseEventType(_ value: Int?) -> KeyEventType {
    switch value {
    case 2: return .repeat
    case 3: return .release
    default: return .press
    }
}

private func parseKittySequence(_ data: [UInt8]) -> ParsedKittySequence? {
    guard let csi = parseCSI(data) else { return nil }
    let p = csi.params

    switch csi.finalByte {
    case UInt8(ascii: "u"):
        // <codepoint>[:<shifted>[:<base>]];<mod>[:<event>]u
        guard let codepoint = param(p, 0, 0) else { return nil }
        let shiftedKey = param(p, 0, 1)
        let baseLayoutKey = param(p, 0, 2)
        let modValue = param(p, 1, 0) ?? 1
        let eventType = parseEventType(param(p, 1, 1))
        return ParsedKittySequence(
            codepoint: codepoint,
            shiftedKey: shiftedKey,
            baseLayoutKey: baseLayoutKey,
            modifier: modValue - 1,
            eventType: eventType
        )

    case UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"):
        // Modified arrows only: \x1b[1;<mod>[:<event>]A. Plain arrows carry no
        // parameters and are handled by the legacy tables.
        guard param(p, 0, 0) == 1, p.count >= 2 else { return nil }
        let modValue = param(p, 1, 0) ?? 1
        let eventType = parseEventType(param(p, 1, 1))
        let arrow: Int
        switch csi.finalByte {
        case UInt8(ascii: "A"): arrow = ArrowCodepoint.up
        case UInt8(ascii: "B"): arrow = ArrowCodepoint.down
        case UInt8(ascii: "C"): arrow = ArrowCodepoint.right
        default: arrow = ArrowCodepoint.left
        }
        return ParsedKittySequence(
            codepoint: arrow, shiftedKey: nil, baseLayoutKey: nil,
            modifier: modValue - 1, eventType: eventType
        )

    case UInt8(ascii: "H"), UInt8(ascii: "F"):
        guard param(p, 0, 0) == 1, p.count >= 2 else { return nil }
        let modValue = param(p, 1, 0) ?? 1
        let eventType = parseEventType(param(p, 1, 1))
        let codepoint = csi.finalByte == UInt8(ascii: "H") ? FunctionalCodepoint.home : FunctionalCodepoint.end
        return ParsedKittySequence(
            codepoint: codepoint, shiftedKey: nil, baseLayoutKey: nil,
            modifier: modValue - 1, eventType: eventType
        )

    case UInt8(ascii: "~"):
        // \x1b[<num>[;<mod>][:<event>]~. The event sub-parameter rides on the
        // modifier parameter when present, otherwise on the number parameter.
        guard let keyNum = param(p, 0, 0) else { return nil }
        let funcCodes: [Int: Int] = [
            2: FunctionalCodepoint.insert,
            3: FunctionalCodepoint.delete,
            5: FunctionalCodepoint.pageUp,
            6: FunctionalCodepoint.pageDown,
            7: FunctionalCodepoint.home,
            8: FunctionalCodepoint.end,
        ]
        guard let codepoint = funcCodes[keyNum] else { return nil }
        let modValue = p.count >= 2 ? (param(p, 1, 0) ?? 1) : 1
        let eventValue = p.count >= 2 ? param(p, 1, 1) : param(p, 0, 1)
        return ParsedKittySequence(
            codepoint: codepoint, shiftedKey: nil, baseLayoutKey: nil,
            modifier: modValue - 1, eventType: parseEventType(eventValue)
        )

    default:
        return nil
    }
}

private func matchesKittySequence(_ data: [UInt8], _ expectedCodepoint: Int, _ expectedModifier: Int) -> Bool {
    guard let parsed = parseKittySequence(data) else { return false }
    let actualMod = parsed.modifier & ~lockMask
    let expectedMod = expectedModifier & ~lockMask
    if actualMod != expectedMod { return false }

    let normalizedCodepoint = normalizeShiftedLetterIdentityCodepoint(
        normalizeKittyFunctionalCodepoint(parsed.codepoint), parsed.modifier)
    let normalizedExpected = normalizeShiftedLetterIdentityCodepoint(
        normalizeKittyFunctionalCodepoint(expectedCodepoint), expectedModifier)

    if normalizedCodepoint == normalizedExpected { return true }

    // Base-layout fallback for non-Latin layouts: Ctrl+С (Cyrillic) should match
    // Ctrl+c when the terminal reports the PC-101 base key. Suppressed whenever
    // the reported codepoint is itself a Latin letter or a known symbol —
    // otherwise a remapped Latin layout (Dvorak, Colemak) would false-match,
    // e.g. Ctrl+K matching Ctrl+V or Ctrl+/ matching Ctrl+[.
    if let base = parsed.baseLayoutKey, base == expectedCodepoint {
        let cp = normalizedCodepoint
        let isLatinLetter = cp >= 97 && cp <= 122
        let isKnownSymbol = codepointIsKnownSymbol(cp)
        if !isLatinLetter && !isKnownSymbol { return true }
    }
    return false
}

private func codepointIsKnownSymbol(_ cp: Int) -> Bool {
    guard cp >= 0, let scalar = Unicode.Scalar(cp) else { return false }
    return symbolKeys.contains(Character(scalar))
}

private func parseModifyOtherKeysSequence(_ data: [UInt8]) -> ParsedModifyOtherKeys? {
    // \x1b[27;<mod>;<codepoint>~
    guard let csi = parseCSI(data), csi.finalByte == UInt8(ascii: "~") else { return nil }
    guard csi.params.count == 3, param(csi.params, 0, 0) == 27 else { return nil }
    guard let modValue = param(csi.params, 1, 0), let codepoint = param(csi.params, 2, 0) else { return nil }
    return ParsedModifyOtherKeys(codepoint: codepoint, modifier: modValue - 1)
}

private func matchesModifyOtherKeys(_ data: [UInt8], _ expectedKeycode: Int, _ expectedModifier: Int) -> Bool {
    guard let parsed = parseModifyOtherKeysSequence(data) else { return false }
    return parsed.codepoint == expectedKeycode && parsed.modifier == expectedModifier
}

private func matchesPrintableModifyOtherKeys(_ data: [UInt8], _ expectedKeycode: Int, _ expectedModifier: Int) -> Bool {
    if expectedModifier == 0 { return false }
    guard let parsed = parseModifyOtherKeysSequence(data), parsed.modifier == expectedModifier else { return false }
    return normalizeShiftedLetterIdentityCodepoint(parsed.codepoint, parsed.modifier)
        == normalizeShiftedLetterIdentityCodepoint(expectedKeycode, expectedModifier)
}

/// Raw `0x7f`/`0x08` backspace disambiguation.
///
/// pi additionally checks a Windows Terminal environment variable to read
/// `0x08` as Ctrl+Backspace. DoMoCode is macOS/Linux only (README non-goals),
/// so that heuristic is dropped and — critically — no environment is read,
/// keeping the decoder pure. Both raw bytes therefore mean unmodified Backspace.
private func matchesRawBackspace(_ data: [UInt8], _ expectedModifier: Int) -> Bool {
    if data == [0x7f] { return expectedModifier == 0 }
    if data != [0x08] { return false }
    return expectedModifier == 0
}

// MARK: - Legacy sequence tables

private let legacyKeySequences: [BaseKey: [[UInt8]]] = [
    .up: [bytes("\u{1b}[A"), bytes("\u{1b}OA")],
    .down: [bytes("\u{1b}[B"), bytes("\u{1b}OB")],
    .right: [bytes("\u{1b}[C"), bytes("\u{1b}OC")],
    .left: [bytes("\u{1b}[D"), bytes("\u{1b}OD")],
    .home: [bytes("\u{1b}[H"), bytes("\u{1b}OH"), bytes("\u{1b}[1~"), bytes("\u{1b}[7~")],
    .end: [bytes("\u{1b}[F"), bytes("\u{1b}OF"), bytes("\u{1b}[4~"), bytes("\u{1b}[8~")],
    .insert: [bytes("\u{1b}[2~")],
    .delete: [bytes("\u{1b}[3~")],
    .pageUp: [bytes("\u{1b}[5~"), bytes("\u{1b}[[5~")],
    .pageDown: [bytes("\u{1b}[6~"), bytes("\u{1b}[[6~")],
    .clear: [bytes("\u{1b}[E"), bytes("\u{1b}OE")],
    .f1: [bytes("\u{1b}OP"), bytes("\u{1b}[11~"), bytes("\u{1b}[[A")],
    .f2: [bytes("\u{1b}OQ"), bytes("\u{1b}[12~"), bytes("\u{1b}[[B")],
    .f3: [bytes("\u{1b}OR"), bytes("\u{1b}[13~"), bytes("\u{1b}[[C")],
    .f4: [bytes("\u{1b}OS"), bytes("\u{1b}[14~"), bytes("\u{1b}[[D")],
    .f5: [bytes("\u{1b}[15~"), bytes("\u{1b}[[E")],
    .f6: [bytes("\u{1b}[17~")],
    .f7: [bytes("\u{1b}[18~")],
    .f8: [bytes("\u{1b}[19~")],
    .f9: [bytes("\u{1b}[20~")],
    .f10: [bytes("\u{1b}[21~")],
    .f11: [bytes("\u{1b}[23~")],
    .f12: [bytes("\u{1b}[24~")],
]

private let legacyShiftSequences: [BaseKey: [[UInt8]]] = [
    .up: [bytes("\u{1b}[a")],
    .down: [bytes("\u{1b}[b")],
    .right: [bytes("\u{1b}[c")],
    .left: [bytes("\u{1b}[d")],
    .clear: [bytes("\u{1b}[e")],
    .insert: [bytes("\u{1b}[2$")],
    .delete: [bytes("\u{1b}[3$")],
    .pageUp: [bytes("\u{1b}[5$")],
    .pageDown: [bytes("\u{1b}[6$")],
    .home: [bytes("\u{1b}[7$")],
    .end: [bytes("\u{1b}[8$")],
]

private let legacyCtrlSequences: [BaseKey: [[UInt8]]] = [
    .up: [bytes("\u{1b}Oa")],
    .down: [bytes("\u{1b}Ob")],
    .right: [bytes("\u{1b}Oc")],
    .left: [bytes("\u{1b}Od")],
    .clear: [bytes("\u{1b}Oe")],
    .insert: [bytes("\u{1b}[2^")],
    .delete: [bytes("\u{1b}[3^")],
    .pageUp: [bytes("\u{1b}[5^")],
    .pageDown: [bytes("\u{1b}[6^")],
    .home: [bytes("\u{1b}[7^")],
    .end: [bytes("\u{1b}[8^")],
]

private let legacySequenceKeyIds: [[UInt8]: KeyId] = {
    var table: [[UInt8]: KeyId] = [:]
    func put(_ s: String, _ key: KeyId) { table[bytes(s)] = key }
    put("\u{1b}OA", Key.up)
    put("\u{1b}OB", Key.down)
    put("\u{1b}OC", Key.right)
    put("\u{1b}OD", Key.left)
    put("\u{1b}OH", Key.home)
    put("\u{1b}OF", Key.end)
    put("\u{1b}[E", Key.clear)
    put("\u{1b}OE", Key.clear)
    put("\u{1b}Oe", KeyId(base: .clear, ctrl: true))
    put("\u{1b}[e", KeyId(base: .clear, shift: true))
    put("\u{1b}[2~", Key.insert)
    put("\u{1b}[2$", KeyId(base: .insert, shift: true))
    put("\u{1b}[2^", KeyId(base: .insert, ctrl: true))
    put("\u{1b}[3$", KeyId(base: .delete, shift: true))
    put("\u{1b}[3^", KeyId(base: .delete, ctrl: true))
    put("\u{1b}[[5~", Key.pageUp)
    put("\u{1b}[[6~", Key.pageDown)
    put("\u{1b}[a", KeyId(base: .up, shift: true))
    put("\u{1b}[b", KeyId(base: .down, shift: true))
    put("\u{1b}[c", KeyId(base: .right, shift: true))
    put("\u{1b}[d", KeyId(base: .left, shift: true))
    put("\u{1b}Oa", KeyId(base: .up, ctrl: true))
    put("\u{1b}Ob", KeyId(base: .down, ctrl: true))
    put("\u{1b}Oc", KeyId(base: .right, ctrl: true))
    put("\u{1b}Od", KeyId(base: .left, ctrl: true))
    put("\u{1b}[5$", KeyId(base: .pageUp, shift: true))
    put("\u{1b}[6$", KeyId(base: .pageDown, shift: true))
    put("\u{1b}[7$", KeyId(base: .home, shift: true))
    put("\u{1b}[8$", KeyId(base: .end, shift: true))
    put("\u{1b}[5^", KeyId(base: .pageUp, ctrl: true))
    put("\u{1b}[6^", KeyId(base: .pageDown, ctrl: true))
    put("\u{1b}[7^", KeyId(base: .home, ctrl: true))
    put("\u{1b}[8^", KeyId(base: .end, ctrl: true))
    put("\u{1b}OP", Key.f1)
    put("\u{1b}OQ", Key.f2)
    put("\u{1b}OR", Key.f3)
    put("\u{1b}OS", Key.f4)
    put("\u{1b}[11~", Key.f1)
    put("\u{1b}[12~", Key.f2)
    put("\u{1b}[13~", Key.f3)
    put("\u{1b}[14~", Key.f4)
    put("\u{1b}[[A", Key.f1)
    put("\u{1b}[[B", Key.f2)
    put("\u{1b}[[C", Key.f3)
    put("\u{1b}[[D", Key.f4)
    put("\u{1b}[[E", Key.f5)
    put("\u{1b}[15~", Key.f5)
    put("\u{1b}[17~", Key.f6)
    put("\u{1b}[18~", Key.f7)
    put("\u{1b}[19~", Key.f8)
    put("\u{1b}[20~", Key.f9)
    put("\u{1b}[21~", Key.f10)
    put("\u{1b}[23~", Key.f11)
    put("\u{1b}[24~", Key.f12)
    put("\u{1b}b", KeyId(base: .left, alt: true))
    put("\u{1b}f", KeyId(base: .right, alt: true))
    put("\u{1b}p", KeyId(base: .up, alt: true))
    put("\u{1b}n", KeyId(base: .down, alt: true))
    return table
}()

private func matchesLegacySequence(_ data: [UInt8], _ sequences: [[UInt8]]?) -> Bool {
    guard let sequences else { return false }
    return sequences.contains(data)
}

private func matchesLegacyModifierSequence(_ data: [UInt8], _ key: BaseKey, _ modifier: Int) -> Bool {
    if modifier == KeyModifier.shift { return matchesLegacySequence(data, legacyShiftSequences[key]) }
    if modifier == KeyModifier.ctrl { return matchesLegacySequence(data, legacyCtrlSequences[key]) }
    return false
}

// MARK: - Printable-key helpers

/// The control character for a printable key: `code & 0x1f`, matching Kitty's
/// legacy Ctrl mapping. `-` folds onto `_` because they share a physical key.
private func rawCtrlByte(_ ch: Character) -> UInt8? {
    let lower = String(ch).lowercased()
    guard let scalar = lower.unicodeScalars.first, lower.unicodeScalars.count == 1 else { return nil }
    let code = scalar.value
    if (code >= 97 && code <= 122) || ch == "[" || ch == "\\" || ch == "]" || ch == "_" {
        return UInt8(code & 0x1f)
    }
    if ch == "-" { return 31 }
    return nil
}

private func isPrintableBase(_ c: Character) -> Bool {
    guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    let v = scalar.value
    return (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || symbolKeys.contains(c)
}

// MARK: - matchesKey

/// Does `data` — a complete, framed terminal-input sequence — represent `keyId`?
///
/// Pure and total across the three encodings: the legacy sequence tables, the
/// Kitty CSI-u protocol, and xterm `modifyOtherKeys`. `kittyProtocolActive`
/// replaces pi's module-global flag; it changes how a handful of ambiguous
/// legacy bytes are read (e.g. `\x1b\r` is shift+enter under Kitty, alt+enter
/// without it), and defaults to the legacy interpretation.
public func matchesKey(_ data: [UInt8], _ keyId: KeyId, kittyProtocolActive: Bool = false) -> Bool {
    let modifier = keyId.modifierMask
    let shift = keyId.shift, alt = keyId.alt, ctrl = keyId.ctrl

    switch keyId.base {
    case .escape:
        if modifier != 0 { return false }
        return data == [esc]
            || matchesKittySequence(data, Codepoint.escape, 0)
            || matchesModifyOtherKeys(data, Codepoint.escape, 0)

    case .space:
        if !kittyProtocolActive {
            if modifier == KeyModifier.ctrl, data == [0x00] { return true }
            if modifier == KeyModifier.alt, data == bytes("\u{1b} ") { return true }
        }
        if modifier == 0 {
            return data == bytes(" ")
                || matchesKittySequence(data, Codepoint.space, 0)
                || matchesModifyOtherKeys(data, Codepoint.space, 0)
        }
        return matchesKittySequence(data, Codepoint.space, modifier)
            || matchesModifyOtherKeys(data, Codepoint.space, modifier)

    case .tab:
        if modifier == KeyModifier.shift {
            return data == bytes("\u{1b}[Z")
                || matchesKittySequence(data, Codepoint.tab, KeyModifier.shift)
                || matchesModifyOtherKeys(data, Codepoint.tab, KeyModifier.shift)
        }
        if modifier == 0 {
            return data == [0x09] || matchesKittySequence(data, Codepoint.tab, 0)
        }
        return matchesKittySequence(data, Codepoint.tab, modifier)
            || matchesModifyOtherKeys(data, Codepoint.tab, modifier)

    case .enter:
        if modifier == KeyModifier.shift {
            if matchesKittySequence(data, Codepoint.enter, KeyModifier.shift)
                || matchesKittySequence(data, Codepoint.kpEnter, KeyModifier.shift) { return true }
            if matchesModifyOtherKeys(data, Codepoint.enter, KeyModifier.shift) { return true }
            if kittyProtocolActive { return data == bytes("\u{1b}\r") || data == [0x0a] }
            return false
        }
        if modifier == KeyModifier.alt {
            if matchesKittySequence(data, Codepoint.enter, KeyModifier.alt)
                || matchesKittySequence(data, Codepoint.kpEnter, KeyModifier.alt) { return true }
            if matchesModifyOtherKeys(data, Codepoint.enter, KeyModifier.alt) { return true }
            if !kittyProtocolActive { return data == bytes("\u{1b}\r") }
            return false
        }
        if modifier == 0 {
            return data == [0x0d]
                || (!kittyProtocolActive && data == [0x0a])
                || data == bytes("\u{1b}OM")
                || matchesKittySequence(data, Codepoint.enter, 0)
                || matchesKittySequence(data, Codepoint.kpEnter, 0)
        }
        return matchesKittySequence(data, Codepoint.enter, modifier)
            || matchesKittySequence(data, Codepoint.kpEnter, modifier)
            || matchesModifyOtherKeys(data, Codepoint.enter, modifier)

    case .backspace:
        if modifier == KeyModifier.alt {
            if data == bytes("\u{1b}\u{7f}") || data == bytes("\u{1b}\u{08}") { return true }
            return matchesKittySequence(data, Codepoint.backspace, KeyModifier.alt)
                || matchesModifyOtherKeys(data, Codepoint.backspace, KeyModifier.alt)
        }
        if modifier == KeyModifier.ctrl {
            if matchesRawBackspace(data, KeyModifier.ctrl) { return true }
            return matchesKittySequence(data, Codepoint.backspace, KeyModifier.ctrl)
                || matchesModifyOtherKeys(data, Codepoint.backspace, KeyModifier.ctrl)
        }
        if modifier == 0 {
            return matchesRawBackspace(data, 0)
                || matchesKittySequence(data, Codepoint.backspace, 0)
                || matchesModifyOtherKeys(data, Codepoint.backspace, 0)
        }
        return matchesKittySequence(data, Codepoint.backspace, modifier)
            || matchesModifyOtherKeys(data, Codepoint.backspace, modifier)

    case .insert:
        return matchesFunctional(data, .insert, FunctionalCodepoint.insert, modifier)
    case .delete:
        return matchesFunctional(data, .delete, FunctionalCodepoint.delete, modifier)
    case .home:
        return matchesFunctional(data, .home, FunctionalCodepoint.home, modifier)
    case .end:
        return matchesFunctional(data, .end, FunctionalCodepoint.end, modifier)
    case .pageUp:
        return matchesFunctional(data, .pageUp, FunctionalCodepoint.pageUp, modifier)
    case .pageDown:
        return matchesFunctional(data, .pageDown, FunctionalCodepoint.pageDown, modifier)

    case .clear:
        if modifier == 0 { return matchesLegacySequence(data, legacyKeySequences[.clear]) }
        return matchesLegacyModifierSequence(data, .clear, modifier)

    case .up:
        if modifier == KeyModifier.alt {
            return data == bytes("\u{1b}p") || matchesKittySequence(data, ArrowCodepoint.up, KeyModifier.alt)
        }
        return matchesArrow(data, .up, ArrowCodepoint.up, modifier)
    case .down:
        if modifier == KeyModifier.alt {
            return data == bytes("\u{1b}n") || matchesKittySequence(data, ArrowCodepoint.down, KeyModifier.alt)
        }
        return matchesArrow(data, .down, ArrowCodepoint.down, modifier)
    case .left:
        if modifier == KeyModifier.alt {
            return data == bytes("\u{1b}[1;3D")
                || (!kittyProtocolActive && data == bytes("\u{1b}B"))
                || data == bytes("\u{1b}b")
                || matchesKittySequence(data, ArrowCodepoint.left, KeyModifier.alt)
        }
        if modifier == KeyModifier.ctrl {
            return data == bytes("\u{1b}[1;5D")
                || matchesLegacyModifierSequence(data, .left, KeyModifier.ctrl)
                || matchesKittySequence(data, ArrowCodepoint.left, KeyModifier.ctrl)
        }
        return matchesArrow(data, .left, ArrowCodepoint.left, modifier)
    case .right:
        if modifier == KeyModifier.alt {
            return data == bytes("\u{1b}[1;3C")
                || (!kittyProtocolActive && data == bytes("\u{1b}F"))
                || data == bytes("\u{1b}f")
                || matchesKittySequence(data, ArrowCodepoint.right, KeyModifier.alt)
        }
        if modifier == KeyModifier.ctrl {
            return data == bytes("\u{1b}[1;5C")
                || matchesLegacyModifierSequence(data, .right, KeyModifier.ctrl)
                || matchesKittySequence(data, ArrowCodepoint.right, KeyModifier.ctrl)
        }
        return matchesArrow(data, .right, ArrowCodepoint.right, modifier)

    case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
        if modifier != 0 { return false }
        return matchesLegacySequence(data, legacyKeySequences[keyId.base])

    case .char(let rawChar):
        return matchesPrintableKey(
            data, rawChar, shift: shift, alt: alt, ctrl: ctrl, modifier: modifier,
            kittyProtocolActive: kittyProtocolActive)
    }
}

private func matchesFunctional(_ data: [UInt8], _ key: BaseKey, _ codepoint: Int, _ modifier: Int) -> Bool {
    if modifier == 0 {
        return matchesLegacySequence(data, legacyKeySequences[key])
            || matchesKittySequence(data, codepoint, 0)
    }
    if matchesLegacyModifierSequence(data, key, modifier) { return true }
    return matchesKittySequence(data, codepoint, modifier)
}

private func matchesArrow(_ data: [UInt8], _ key: BaseKey, _ codepoint: Int, _ modifier: Int) -> Bool {
    if modifier == 0 {
        return matchesLegacySequence(data, legacyKeySequences[key])
            || matchesKittySequence(data, codepoint, 0)
    }
    if matchesLegacyModifierSequence(data, key, modifier) { return true }
    return matchesKittySequence(data, codepoint, modifier)
}

private func matchesPrintableKey(
    _ data: [UInt8], _ rawChar: Character,
    shift: Bool, alt: Bool, ctrl: Bool, modifier: Int, kittyProtocolActive: Bool
) -> Bool {
    let key = KeyId.normalizeBaseChar(rawChar)
    guard isPrintableBase(key), let scalar = key.unicodeScalars.first else { return false }
    let codepoint = Int(scalar.value)
    let ctrlByte = rawCtrlByte(key)
    let isLetter = scalar.value >= 97 && scalar.value <= 122
    let isDigit = scalar.value >= 48 && scalar.value <= 57

    if modifier == KeyModifier.ctrl + KeyModifier.alt, !kittyProtocolActive, let cb = ctrlByte {
        if data == [esc, cb] { return true }
    }

    if modifier == KeyModifier.alt, !kittyProtocolActive, isLetter || isDigit || symbolKeys.contains(key) {
        if data == [esc] + Array(String(key).utf8) { return true }
    }

    if modifier == KeyModifier.ctrl {
        if let cb = ctrlByte, data == [cb] { return true }
        return matchesKittySequence(data, codepoint, KeyModifier.ctrl)
            || matchesPrintableModifyOtherKeys(data, codepoint, KeyModifier.ctrl)
    }

    if modifier == KeyModifier.shift + KeyModifier.ctrl {
        return matchesKittySequence(data, codepoint, KeyModifier.shift + KeyModifier.ctrl)
            || matchesPrintableModifyOtherKeys(data, codepoint, KeyModifier.shift + KeyModifier.ctrl)
    }

    if modifier == KeyModifier.shift {
        if isLetter, data == Array(String(key).uppercased().utf8) { return true }
        return matchesKittySequence(data, codepoint, KeyModifier.shift)
            || matchesPrintableModifyOtherKeys(data, codepoint, KeyModifier.shift)
    }

    if modifier != 0 {
        return matchesKittySequence(data, codepoint, modifier)
            || matchesPrintableModifyOtherKeys(data, codepoint, modifier)
    }

    return data == Array(String(key).utf8) || matchesKittySequence(data, codepoint, 0)
}

// MARK: - parseKey

/// Turn a codepoint + modifier (as decoded from any encoding) into a ``KeyId``.
///
/// The base-layout key is honoured only when the reported codepoint is not a
/// Latin letter, digit, or known symbol — the same suppression that keeps
/// remapped layouts from mislabeling keys in ``matchesKittySequence(_:_:_:)``.
private func formatParsedKey(_ codepoint: Int, _ modifier: Int, _ baseLayoutKey: Int? = nil) -> KeyId? {
    let normalized = normalizeKittyFunctionalCodepoint(codepoint)
    let identity = normalizeShiftedLetterIdentityCodepoint(normalized, modifier)

    let isLatinLetter = identity >= 97 && identity <= 122
    let isDigit = identity >= 48 && identity <= 57
    let isKnownSymbol = codepointIsKnownSymbol(identity)
    let effective = (isLatinLetter || isDigit || isKnownSymbol) ? identity : (baseLayoutKey ?? identity)

    guard let base = baseKey(forCodepoint: effective) else { return nil }
    guard let (shift, alt, ctrl, superKey) = decodeModifierBits(modifier) else { return nil }
    return KeyId(base: base, shift: shift, alt: alt, ctrl: ctrl, superKey: superKey)
}

private func baseKey(forCodepoint cp: Int) -> BaseKey? {
    switch cp {
    case Codepoint.escape: return .escape
    case Codepoint.tab: return .tab
    case Codepoint.enter, Codepoint.kpEnter: return .enter
    case Codepoint.space: return .space
    case Codepoint.backspace: return .backspace
    case FunctionalCodepoint.delete: return .delete
    case FunctionalCodepoint.insert: return .insert
    case FunctionalCodepoint.home: return .home
    case FunctionalCodepoint.end: return .end
    case FunctionalCodepoint.pageUp: return .pageUp
    case FunctionalCodepoint.pageDown: return .pageDown
    case ArrowCodepoint.up: return .up
    case ArrowCodepoint.down: return .down
    case ArrowCodepoint.left: return .left
    case ArrowCodepoint.right: return .right
    default:
        if cp >= 48, cp <= 57 { return .char(Character(Unicode.Scalar(cp)!)) }
        if cp >= 97, cp <= 122 { return .char(Character(Unicode.Scalar(cp)!)) }
        if codepointIsKnownSymbol(cp) { return .char(Character(Unicode.Scalar(cp)!)) }
        return nil
    }
}

/// Reject any modifier bit outside shift/alt/ctrl/super (after masking the
/// lock bits). pi's `formatKeyNameWithModifiers` returns `undefined` here, which
/// makes the whole parse fail.
private func decodeModifierBits(_ modifier: Int) -> (Bool, Bool, Bool, Bool)? {
    let effective = modifier & ~lockMask
    let supported = KeyModifier.shift | KeyModifier.ctrl | KeyModifier.alt | KeyModifier.super
    if (effective & ~supported) != 0 { return nil }
    return (
        (effective & KeyModifier.shift) != 0,
        (effective & KeyModifier.alt) != 0,
        (effective & KeyModifier.ctrl) != 0,
        (effective & KeyModifier.super) != 0
    )
}

/// Decode a framed terminal-input sequence into the key it names, or `nil`.
///
/// Order matches pi: Kitty CSI-u first, then `modifyOtherKeys`, then the
/// mode-aware legacy tables. `kittyProtocolActive` decides the reading of the
/// handful of sequences that legacy and Kitty terminals overload differently.
public func parseKey(_ data: [UInt8], kittyProtocolActive: Bool = false) -> KeyId? {
    if let kitty = parseKittySequence(data) {
        return formatParsedKey(kitty.codepoint, kitty.modifier, kitty.baseLayoutKey)
    }
    if let mok = parseModifyOtherKeysSequence(data) {
        return formatParsedKey(mok.codepoint, mok.modifier)
    }

    if kittyProtocolActive {
        if data == bytes("\u{1b}\r") || data == [0x0a] { return KeyId(base: .enter, shift: true) }
    }

    if let mapped = legacySequenceKeyIds[data] { return mapped }

    if data == [esc] { return Key.escape }
    if data == [0x1c] { return KeyId(base: .char("\\"), ctrl: true) }
    if data == [0x1d] { return KeyId(base: .char("]"), ctrl: true) }
    if data == [0x1f] { return KeyId(base: .char("-"), ctrl: true) }
    if data == [esc, 0x1b] { return KeyId(base: .char("["), alt: true, ctrl: true) }
    if data == [esc, 0x1c] { return KeyId(base: .char("\\"), alt: true, ctrl: true) }
    if data == [esc, 0x1d] { return KeyId(base: .char("]"), alt: true, ctrl: true) }
    if data == [esc, 0x1f] { return KeyId(base: .char("-"), alt: true, ctrl: true) }
    if data == [0x09] { return Key.tab }
    if data == [0x0d] || (!kittyProtocolActive && data == [0x0a]) || data == bytes("\u{1b}OM") { return Key.enter }
    if data == [0x00] { return KeyId(base: .space, ctrl: true) }
    if data == bytes(" ") { return Key.space }
    if data == [0x7f] { return Key.backspace }
    if data == [0x08] { return Key.backspace }
    if data == bytes("\u{1b}[Z") { return KeyId(base: .tab, shift: true) }
    if !kittyProtocolActive, data == bytes("\u{1b}\r") { return KeyId(base: .enter, alt: true) }
    if !kittyProtocolActive, data == bytes("\u{1b} ") { return KeyId(base: .space, alt: true) }
    if data == bytes("\u{1b}\u{7f}") || data == bytes("\u{1b}\u{08}") { return KeyId(base: .backspace, alt: true) }
    if !kittyProtocolActive, data == bytes("\u{1b}B") { return KeyId(base: .left, alt: true) }
    if !kittyProtocolActive, data == bytes("\u{1b}F") { return KeyId(base: .right, alt: true) }

    if !kittyProtocolActive, data.count == 2, data[0] == esc {
        let code = Int(data[1])
        if code >= 1, code <= 26 {
            return KeyId(base: .char(Character(Unicode.Scalar(UInt32(code + 96))!)), alt: true, ctrl: true)
        }
        if let scalar = Unicode.Scalar(UInt32(code)) {
            let key = Character(scalar)
            if (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || symbolKeys.contains(key) {
                return KeyId(base: .char(key), alt: true)
            }
        }
    }

    if data == bytes("\u{1b}[A") { return Key.up }
    if data == bytes("\u{1b}[B") { return Key.down }
    if data == bytes("\u{1b}[C") { return Key.right }
    if data == bytes("\u{1b}[D") { return Key.left }
    if data == bytes("\u{1b}[H") || data == bytes("\u{1b}OH") { return Key.home }
    if data == bytes("\u{1b}[F") || data == bytes("\u{1b}OF") { return Key.end }
    if data == bytes("\u{1b}[3~") { return Key.delete }
    if data == bytes("\u{1b}[5~") { return Key.pageUp }
    if data == bytes("\u{1b}[6~") { return Key.pageDown }

    if data.count == 1 {
        let code = Int(data[0])
        if code >= 1, code <= 26 {
            return KeyId(base: .char(Character(Unicode.Scalar(UInt32(code + 96))!)), ctrl: true)
        }
        if code >= 32, code <= 126 {
            return KeyId(base: .char(Character(Unicode.Scalar(UInt32(code))!)))
        }
    }
    return nil
}

// MARK: - Event-type detection

/// The Kitty flag-2 event type of `data`, or `.press` for anything that is not
/// a flag-2 sequence. Reads it straight off the parsed sequence rather than
/// through pi's module-global `_lastEventType`, so it stays pure.
public func keyEventType(_ data: [UInt8]) -> KeyEventType {
    parseKittySequence(data)?.eventType ?? .press
}

/// Substring heuristic for a release event, matching pi's `isKeyRelease`.
///
/// Bracketed-paste content is exempted: a pasted MAC address like `90:62:3F`
/// contains `:3F` and must not be read as a release. `Terminal` re-wraps paste
/// content in `\x1b[200~`, so its presence is the tell.
public func isKeyRelease(_ data: [UInt8]) -> Bool {
    if contains(data, bytes("\u{1b}[200~")) { return false }
    for suffix in [":3u", ":3~", ":3A", ":3B", ":3C", ":3D", ":3H", ":3F"] {
        if contains(data, bytes(suffix)) { return true }
    }
    return false
}

/// Substring heuristic for a repeat event, matching pi's `isKeyRepeat`.
public func isKeyRepeat(_ data: [UInt8]) -> Bool {
    if contains(data, bytes("\u{1b}[200~")) { return false }
    for suffix in [":2u", ":2~", ":2A", ":2B", ":2C", ":2D", ":2H", ":2F"] {
        if contains(data, bytes(suffix)) { return true }
    }
    return false
}

// MARK: - Printable decoding

private let kittyPrintableAllowedModifiers = KeyModifier.shift | lockMask

/// Recover the literal text a Kitty CSI-u sequence stands for, when it is a
/// plain or shift-only printable key. Ctrl/Alt/Super are rejected — those are
/// commands, not text, and are handled by keybinding matching. The shifted
/// keycode wins when Shift is held so `shift+a` yields `A`.
public func decodeKittyPrintable(_ data: [UInt8]) -> String? {
    guard let csi = parseCSI(data), csi.finalByte == UInt8(ascii: "u") else { return nil }
    guard let codepoint = param(csi.params, 0, 0) else { return nil }
    let shiftedKey = param(csi.params, 0, 1)
    let modValue = param(csi.params, 1, 0) ?? 1
    let modifier = modValue - 1

    if (modifier & ~kittyPrintableAllowedModifiers) != 0 { return nil }
    if (modifier & (KeyModifier.alt | KeyModifier.ctrl)) != 0 { return nil }

    var effective = codepoint
    if (modifier & KeyModifier.shift) != 0, let shiftedKey { effective = shiftedKey }
    effective = normalizeKittyFunctionalCodepoint(effective)
    if effective < 32 { return nil }
    guard let scalar = Unicode.Scalar(UInt32(exactly: effective) ?? 0) else { return nil }
    return String(scalar)
}

private func decodeModifyOtherKeysPrintable(_ data: [UInt8]) -> String? {
    guard let parsed = parseModifyOtherKeysSequence(data) else { return nil }
    let modifier = parsed.modifier & ~lockMask
    if (modifier & ~KeyModifier.shift) != 0 { return nil }
    if parsed.codepoint < 32 { return nil }
    guard let scalar = Unicode.Scalar(UInt32(exactly: parsed.codepoint) ?? 0) else { return nil }
    return String(scalar)
}

/// Recover the text a printable-key sequence stands for, across Kitty CSI-u and
/// `modifyOtherKeys`. `nil` for a non-printable or command sequence.
public func decodePrintableKey(_ data: [UInt8]) -> String? {
    decodeKittyPrintable(data) ?? decodeModifyOtherKeysPrintable(data)
}
