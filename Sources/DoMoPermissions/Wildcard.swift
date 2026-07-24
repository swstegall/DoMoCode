// Copyright (c) 2025 opencode contributors. MIT license.
// https://github.com/sst/opencode — packages/core/src/util/wildcard.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The glob primitive the whole permission engine matches with. A faithful port of
// opencode's `Wildcard.match` (byte-identical in kilocode): glob -> anchored regex,
// with `*` -> `.*`, `?` -> single char, backslash normalized to forward slash, and
// the load-bearing trailing-" *" -> optional-arguments rewrite so `"git *"` matches
// both `"git status"` and a bare `"git"`. Win32 case-insensitivity is dropped
// (DoMoCode is macOS/Linux) — dotAll is always on, matching is case-sensitive.

import Foundation

/// The regex metacharacters opencode escapes before glob expansion: `[.+^${}()|[]\]`.
/// `*` and `?` are deliberately absent (they are glob tokens handled afterward).
private let regexMetacharacters: Set<Character> = [".", "+", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]

/// Whether `input` matches glob `pattern`.
///
/// `Wildcard.match(input, pattern)`: the queried resource is `input`, the stored rule
/// glob is `pattern`. Ported step-for-step from the TypeScript:
///   1. normalize `\` -> `/` in both input and pattern
///   2. regex-escape the metacharacters above (so a literal `.` becomes `\.`)
///   3. `*` -> `.*`, `?` -> `.`
///   4. if the escaped string ends with `" .*"` (the pattern ended with " *"), make
///      that trailing group optional: `"( .*)?"`
///   5. anchor `^…$`, compile dotAll, and require a FULL-string match
public func wildcardMatch(_ input: String, _ pattern: String) -> Bool {
    let normalizedInput = input.replacingOccurrences(of: "\\", with: "/")

    var escaped = ""
    escaped.reserveCapacity(pattern.count * 2)
    for character in pattern.replacingOccurrences(of: "\\", with: "/") {
        switch character {
        case "*": escaped += ".*"
        case "?": escaped += "."
        default:
            if regexMetacharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
    }

    // Trailing " *" (now " .*") becomes an optional argument group.
    if escaped.hasSuffix(" .*") {
        escaped = String(escaped.dropLast(3)) + "( .*)?"
    }

    let source = "^" + escaped + "$"
    guard let regex = try? NSRegularExpression(pattern: source, options: [.dotMatchesLineSeparators]) else {
        return false
    }
    let full = NSRange(normalizedInput.startIndex..., in: normalizedInput)
    guard let match = regex.firstMatch(in: normalizedInput, options: [], range: full) else { return false }
    // Require the match to span the ENTIRE input — NSRegularExpression's `$` otherwise
    // also matches before a trailing newline, which JS's `$` (no `m` flag) does not.
    return match.range == full
}
