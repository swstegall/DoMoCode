// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/utils.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DisplayWidth

// MARK: - Isolation

// `DoMoTUI` is `.defaultIsolation(MainActor.self)`, so an unmarked global `let`
// or `func` here would infer `@MainActor` and become unusable off the main
// actor. The width engine is called from tests and, later, from measurement
// paths that run off-main while the render loop holds the main actor, so every
// declaration in this file is `nonisolated`. `DisplayWidth` is a `Sendable`
// value type, so one shared instance crosses isolation domains for free and
// avoids re-reading the Unicode tables on every call.
private nonisolated let displayWidth = DisplayWidth()

/// The number of columns pi assigns a horizontal tab.
///
/// pi expands tabs to a fixed three columns before measuring, rather than
/// resolving real tab stops, because layout is what decides where a line wraps
/// and a variable-width tab makes wrapping depend on prior content the measurer
/// cannot see. Matching the constant keeps this engine's width in lockstep with
/// pi's wrapper, which is the whole point of a differential renderer.
public nonisolated let tabColumnWidth = 3

// MARK: - ANSI scanning

/// The number of `Character`s an ANSI/OSC/APC escape occupies starting at
/// `position`, or `nil` if no recognized escape begins there.
///
/// Ported from pi's `extractAnsiCode`, deliberately including its quirks. The
/// CSI terminator set is `m G K H J` — pi's exact list — not the full
/// `0x40...0x7E` final-byte range a general VT parser uses, because these
/// helpers exist to measure and slice the specific output pi's renderer emits
/// (SGR styling, cursor motion, erase), and widening the set would silently
/// reclassify bytes that pi treats as literal text, drifting this engine away
/// from the wrapper it must agree with to the column.
///
/// Operating on `[Character]` is sound because every byte of an escape is
/// single-scalar ASCII, and `ESC` (a C0 control) never joins a following scalar
/// into one grapheme cluster (Unicode grapheme break GB4/GB5). So an escape is
/// always a run of standalone `Character`s and lookahead by `Character` index is
/// exact.
nonisolated func ansiEscapeLength(in chars: [Character], at position: Int) -> Int? {
    guard position < chars.count, chars[position] == "\u{1b}" else { return nil }
    let nextIndex = position + 1
    guard nextIndex < chars.count else { return nil }
    let next = chars[nextIndex]

    // CSI: ESC [ ... final-byte
    if next == "[" {
        var j = position + 2
        while j < chars.count, !isCSIFinalByte(chars[j]) { j += 1 }
        return j < chars.count ? j + 1 - position : nil
    }

    // OSC (ESC ]) and APC (ESC _) both run until BEL or ST (ESC \).
    if next == "]" || next == "_" {
        var j = position + 2
        while j < chars.count {
            if chars[j] == "\u{07}" { return j + 1 - position }
            if chars[j] == "\u{1b}", j + 1 < chars.count, chars[j + 1] == "\\" {
                return j + 2 - position
            }
            j += 1
        }
        return nil
    }

    return nil
}

private nonisolated func isCSIFinalByte(_ character: Character) -> Bool {
    character == "m" || character == "G" || character == "K" || character == "H" || character == "J"
}

// MARK: - Width

/// Whether `string` is entirely printable 7-bit ASCII (`0x20...0x7E`).
///
/// The fast path pi keeps for the overwhelmingly common line: no escape, no
/// wide character, no combining mark, so width is simply the count and no
/// grapheme walk or table lookup is needed. Tab (`0x09`) is deliberately outside
/// the range — it is not width 1 — so tabbed text falls through to the general
/// path.
nonisolated func isPrintableASCII(_ string: String) -> Bool {
    for scalar in string.unicodeScalars where scalar.value < 0x20 || scalar.value > 0x7E {
        return false
    }
    return true
}

/// The terminal-cell width of a single grapheme cluster.
///
/// A Swift `Character` *is* an extended grapheme cluster, which deletes pi's
/// manual `Intl.Segmenter` walk: pi segments a JS string into clusters by hand
/// because JS strings are UTF-16 code units, but iterating `Character`s already
/// yields exactly those clusters.
///
/// Zero-width detection ports pi's `zeroWidthRegex`
/// (`Default_Ignorable | Control | Mark | Surrogate`) directly onto Swift scalar
/// properties, and runs *before* `DisplayWidth`. This matters because
/// `DisplayWidth` zeroes only nonspacing/enclosing/combining marks and a fixed
/// list of zero-width scalars; a lone default-ignorable format character such as
/// U+2064 that is none of those would otherwise measure 1. A cluster is only
/// zeroed when *every* scalar is zero-width, so an emoji-plus-ZWJ sequence (the
/// emoji scalars are not zero-width) still reaches `DisplayWidth` and measures
/// its real width.
///
/// **Known fidelity gap (README, "Emoji width").** pi decides emoji width with
/// V8's `\p{RGI_Emoji}` regex, which is the authoritative test for a
/// *recommended-for-general-interchange* emoji sequence. Swift's regex engine
/// has no `RGI_Emoji` property and `DisplayWidth` approximates it with fixed
/// pictographic codepoint ranges plus ZWJ/skin-tone/VS16 aggregation. For the
/// common cases — single emoji, skin-toned emoji, ZWJ families, flag pairs —
/// the two agree at width 2. They can diverge on an exotic or not-yet-recommended
/// sequence that RGI would reject but the range heuristic accepts (or the
/// reverse); such a cluster may measure differently here than in pi. This is
/// accepted rather than closed: re-deriving RGI in Swift is out of scope, and
/// the README flags macOS 26's `UTF8Span` grapheme iteration as the right time
/// to revisit.
public nonisolated func graphemeWidth(_ character: Character) -> Int {
    if character == "\t" { return tabColumnWidth }
    if isZeroWidthCluster(character) { return 0 }
    return displayWidth(character)
}

private nonisolated func isZeroWidthCluster(_ character: Character) -> Bool {
    for scalar in character.unicodeScalars {
        let properties = scalar.properties
        if properties.isDefaultIgnorableCodePoint { continue }
        switch properties.generalCategory {
        case .control, .spacingMark, .nonspacingMark, .enclosingMark, .surrogate:
            continue
        default:
            return false
        }
    }
    return true
}

/// The visible width of `string` in terminal columns, ignoring ANSI/OSC/APC
/// escapes.
///
/// This and the slicing helpers share one notion of "escape" (``ansiEscapeLength``)
/// and one notion of "cluster" (`Character`), so a string this function reports
/// as N columns wide is a string ``sliceByColumn(_:from:to:strict:)`` will place
/// in exactly N columns. That agreement is the invariant the renderer is built
/// on; a one-column disagreement corrupts every subsequent column on the line.
///
/// Unlike pi, this keeps no width cache. Memoization is a latency optimization,
/// not a correctness requirement, and a shared cache under default `MainActor`
/// isolation would need its own `Mutex` to stay `nonisolated` — cost the port
/// can add later behind the same signature if measurement ever shows up hot.
public nonisolated func visibleWidth(_ string: String) -> Int {
    if string.isEmpty { return 0 }
    if isPrintableASCII(string) { return string.unicodeScalars.count }

    // No escape: measure clusters directly, no array allocation.
    if !string.unicodeScalars.contains(where: { $0.value == 0x1B }) {
        var width = 0
        for character in string { width += graphemeWidth(character) }
        return width
    }

    let chars = Array(string)
    var width = 0
    var index = 0
    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            index += length
            continue
        }
        width += graphemeWidth(chars[index])
        index += 1
    }
    return width
}
