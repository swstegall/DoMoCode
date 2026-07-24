// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/word-navigation.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// Deliberate divergence from pi: pi drives word boundaries with V8's
// `Intl.Segmenter` (granularity "word"), which is dictionary-backed. Swift's
// standard library exposes no word segmenter, and Foundation's ICU segmentation
// does not agree with V8 (it keeps `foo.bar` as one word and splits Chinese
// differently), so replaying pi's segments through Foundation would fail pi's own
// tests. Instead this reimplements the *observable boundaries* pi's tests pin
// with a category scan over `Character`s:
//   * a latin word run is a maximal run of letters/digits/`_` that are not CJK;
//   * a CJK run is a maximal run of CJK-script characters, treated as one word
//     unit (pi's dictionary would split undelimited multi-word CJK such as
//     `你好世界` into `你好`/`世界`; this port groups the whole run — the only case
//     not reproduced, and untested in the editor's own suite, which always
//     delimits CJK words with punctuation);
//   * everything else is whitespace or a punctuation run.
// A latin↔CJK transition is always a boundary, matching pi. Paste markers are
// passed in as atomic ranges and skipped as single units.

// MARK: - Character classification

/// Whether `scalar` belongs to one of pi's CJK break scripts (Han, Hiragana,
/// Katakana, Hangul, Bopomofo — matching `cjkBreakRegex`), by codepoint range.
nonisolated func isCJKScalar(_ v: UInt32) -> Bool {
    (0x3400...0x4DBF).contains(v) // CJK Unified Ideographs Extension A
        || (0x4E00...0x9FFF).contains(v) // CJK Unified Ideographs
        || (0xF900...0xFAFF).contains(v) // CJK Compatibility Ideographs
        || (0x3040...0x309F).contains(v) // Hiragana
        || (0x30A0...0x30FF).contains(v) // Katakana
        || (0x31F0...0x31FF).contains(v) // Katakana Phonetic Extensions
        || (0x3100...0x312F).contains(v) // Bopomofo
        || (0x31A0...0x31BF).contains(v) // Bopomofo Extended
        || (0x1100...0x11FF).contains(v) // Hangul Jamo
        || (0x3130...0x318F).contains(v) // Hangul Compatibility Jamo
        || (0xAC00...0xD7AF).contains(v) // Hangul Syllables
        || (0x20000...0x2FA1F).contains(v) // CJK Ideograph Extensions B–F + Supplement
}

/// Whether the cluster is a CJK-script character.
nonisolated func isCJKCluster(_ c: Character) -> Bool {
    c.unicodeScalars.contains { isCJKScalar($0.value) }
}

/// Whether the cluster is whitespace, matching pi's `isWhitespaceChar` (`/\s/`).
nonisolated func isWhitespaceCluster(_ c: Character) -> Bool {
    if c == " " || c == "\t" || c == "\n" || c == "\r" { return true }
    return c.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
}

/// Whether the cluster is a word character (letter, digit, or `_`). CJK counts.
nonisolated func isWordCharacter(_ c: Character) -> Bool {
    c == "_" || c.isLetter || c.isNumber
}

/// A latin (non-CJK) word character.
private nonisolated func isLatinWordCluster(_ c: Character) -> Bool {
    isWordCharacter(c) && !isCJKCluster(c)
}

// MARK: - Boundary search

/// The atomic range covering index `k`, or `nil`.
private nonisolated func atomicRange(covering k: Int, _ markers: [Range<Int>]) -> Range<Int>? {
    markers.first { $0.contains(k) }
}

/// The cursor position after moving one word backward from `cursor` over `chars`.
///
/// Skips trailing whitespace, then consumes exactly one unit: an atomic marker,
/// a CJK run, a latin word run, or a punctuation run. Pure; mutates nothing.
nonisolated func findWordBackward(_ chars: [Character], _ cursor: Int, markers: [Range<Int>] = []) -> Int {
    if cursor <= 0 { return 0 }
    var i = min(cursor, chars.count)

    // Skip trailing whitespace (a marker char is never whitespace).
    while i > 0 {
        let j = i - 1
        if atomicRange(covering: j, markers) != nil { break }
        if isWhitespaceCluster(chars[j]) { i -= 1 } else { break }
    }
    if i == 0 { return 0 }

    let j = i - 1
    if let range = atomicRange(covering: j, markers) {
        return range.lowerBound
    }

    let c = chars[j]
    if isCJKCluster(c) {
        while i > 0, atomicRange(covering: i - 1, markers) == nil, isCJKCluster(chars[i - 1]) { i -= 1 }
    } else if isLatinWordCluster(c) {
        while i > 0, atomicRange(covering: i - 1, markers) == nil, isLatinWordCluster(chars[i - 1]) { i -= 1 }
    } else {
        while i > 0,
            atomicRange(covering: i - 1, markers) == nil,
            !isWordCharacter(chars[i - 1]),
            !isWhitespaceCluster(chars[i - 1]) { i -= 1 }
    }
    return i
}

/// The cursor position after moving one word forward from `cursor` over `chars`.
///
/// Skips leading whitespace, then consumes exactly one unit. Pure.
nonisolated func findWordForward(_ chars: [Character], _ cursor: Int, markers: [Range<Int>] = []) -> Int {
    let n = chars.count
    if cursor >= n { return n }
    var i = max(0, cursor)

    // Skip leading whitespace.
    while i < n {
        if atomicRange(covering: i, markers) != nil { break }
        if isWhitespaceCluster(chars[i]) { i += 1 } else { break }
    }
    if i >= n { return i }

    if let range = atomicRange(covering: i, markers) {
        return range.upperBound
    }

    let c = chars[i]
    if isCJKCluster(c) {
        while i < n, atomicRange(covering: i, markers) == nil, isCJKCluster(chars[i]) { i += 1 }
    } else if isLatinWordCluster(c) {
        while i < n, atomicRange(covering: i, markers) == nil, isLatinWordCluster(chars[i]) { i += 1 }
    } else {
        while i < n,
            atomicRange(covering: i, markers) == nil,
            !isWordCharacter(chars[i]),
            !isWhitespaceCluster(chars[i]) { i += 1 }
    }
    return i
}
