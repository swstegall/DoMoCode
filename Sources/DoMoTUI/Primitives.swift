// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/utils.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The text-flow helpers
// (AnsiCodeTracker, wrapTextWithAnsi and friends) port `utils.ts`; the
// `Text`/`Box`/`Spacer` components are the minimal component set pi grows from
// the same `Component` interface, kept just rich enough to build golden-frame
// tests against the renderer.

import DoMoCore

// MARK: - ANSI code extraction

/// The escape at `position` in `chars` as `(code, length)`, or `nil`.
///
/// A thin `String`-returning wrapper over ``ansiEscapeLength(in:at:)`` so the
/// text-flow helpers, which accumulate escape *text*, do not each re-slice the
/// array by hand.
nonisolated func extractAnsiCode(_ chars: [Character], _ position: Int) -> (code: String, length: Int)? {
    guard let length = ansiEscapeLength(in: chars, at: position) else { return nil }
    return (String(chars[position..<position + length]), length)
}

// MARK: - CJK break detection

/// Whether `character`'s base scalar is a CJK ideograph or kana/hangul/bopomofo
/// that terminals break between without an intervening space.
///
/// pi tests `\p{Script_Extensions=…}` for Han/Hiragana/Katakana/Hangul/Bopomofo.
/// Swift's stdlib exposes no script-extension query, so this approximates with
/// the codepoint blocks those scripts occupy. The consequence is a fidelity gap
/// of the same character as the emoji-width gap in ``graphemeWidth(_:)``: an
/// exotic scalar that carries one of those scripts *by extension* but lives
/// outside these blocks will not be treated as its own break token. The common
/// CJK text that drives line-breaking behaviour is fully covered.
nonisolated func isCJKBreak(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    let v = scalar.value
    return (0x4E00...0x9FFF).contains(v) // CJK Unified Ideographs
        || (0x3400...0x4DBF).contains(v) // CJK Extension A
        || (0x3040...0x309F).contains(v) // Hiragana
        || (0x30A0...0x30FF).contains(v) // Katakana
        || (0xAC00...0xD7AF).contains(v) // Hangul Syllables
        || (0x1100...0x11FF).contains(v) // Hangul Jamo
        || (0x3100...0x312F).contains(v) // Bopomofo
        || (0xF900...0xFAFF).contains(v) // CJK Compatibility Ideographs
        || (0x20000...0x2FA1F).contains(v) // CJK Extension B+ and supplement
}

// MARK: - ANSI SGR tracker

/// Tracks the active SGR (colour/style) state as escape codes stream past, so a
/// style opened on one line can be reopened at the start of the next.
///
/// Ported from `utils.ts`'s `AnsiCodeTracker`, minus its OSC 8 hyperlink state.
/// The renderer's per-line reset (`\x1b[0m\x1b]8;;\x07`) already closes any open
/// hyperlink at every line end, and no component in this phase emits hyperlinks;
/// carrying hyperlink continuation across wraps is deferred with the component
/// that needs it. Everything else — the individual attribute flags, 256/RGB
/// colour parsing, `getActiveCodes` reconstruction, and the underline-off line
/// reset — matches pi so wrapped styled text renders identically.
final class AnsiCodeTracker {
    private var bold = false
    private var dim = false
    private var italic = false
    private var underline = false
    private var blink = false
    private var inverse = false
    private var hidden = false
    private var strikethrough = false
    private var fgColor: String?
    private var bgColor: String?

    func clear() { resetSGR() }

    private func resetSGR() {
        bold = false; dim = false; italic = false; underline = false
        blink = false; inverse = false; hidden = false; strikethrough = false
        fgColor = nil; bgColor = nil
    }

    /// Fold one escape code into the tracked state. Non-SGR escapes are ignored.
    func process(_ ansiCode: String) {
        guard ansiCode.hasSuffix("m"), ansiCode.hasPrefix("\u{1b}[") else { return }
        // Parameters are between "\x1b[" and the trailing "m".
        let body = ansiCode.dropFirst(2).dropLast()
        if body.isEmpty || body == "0" {
            resetSGR()
            return
        }
        let parts = body.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        var i = 0
        while i < parts.count {
            guard let code = Int(parts[i]) else { i += 1; continue }
            if code == 38 || code == 48 {
                if i + 2 < parts.count, parts[i + 1] == "5" {
                    let colorCode = "\(parts[i]);\(parts[i + 1]);\(parts[i + 2])"
                    if code == 38 { fgColor = colorCode } else { bgColor = colorCode }
                    i += 3
                    continue
                } else if i + 4 < parts.count, parts[i + 1] == "2" {
                    let colorCode = "\(parts[i]);\(parts[i + 1]);\(parts[i + 2]);\(parts[i + 3]);\(parts[i + 4])"
                    if code == 38 { fgColor = colorCode } else { bgColor = colorCode }
                    i += 5
                    continue
                }
            }
            switch code {
            case 0: resetSGR()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 5: blink = true
            case 7: inverse = true
            case 8: hidden = true
            case 9: strikethrough = true
            case 21: bold = false
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 25: blink = false
            case 27: inverse = false
            case 28: hidden = false
            case 29: strikethrough = false
            case 39: fgColor = nil
            case 49: bgColor = nil
            default:
                if (30...37).contains(code) || (90...97).contains(code) {
                    fgColor = String(code)
                } else if (40...47).contains(code) || (100...107).contains(code) {
                    bgColor = String(code)
                }
            }
            i += 1
        }
    }

    /// The escape that reconstructs the current style from a clean slate.
    func getActiveCodes() -> String {
        var codes: [String] = []
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        if blink { codes.append("5") }
        if inverse { codes.append("7") }
        if hidden { codes.append("8") }
        if strikethrough { codes.append("9") }
        if let fgColor { codes.append(fgColor) }
        if let bgColor { codes.append(bgColor) }
        return codes.isEmpty ? "" : "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    /// The reset emitted at a wrapped line's end: close underline so it cannot
    /// bleed into trailing padding. (Background is deliberately left open so a
    /// filled block survives the wrap.)
    func getLineEndReset() -> String {
        underline ? "\u{1b}[24m" : ""
    }
}

private func updateTracker(from text: String, _ tracker: AnsiCodeTracker) {
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        if let ansi = extractAnsiCode(chars, i) {
            tracker.process(ansi.code)
            i += ansi.length
        } else {
            i += 1
        }
    }
}

// MARK: - Word wrapping

/// Split `text` into whitespace/word tokens, keeping ANSI codes attached to the
/// visible content that follows them and breaking CJK graphemes into their own
/// tokens. Ported from `splitIntoTokensWithAnsi`.
private func splitIntoTokens(_ text: String) -> [String] {
    let chars = Array(text)
    var tokens: [String] = []
    var current = ""
    var pendingAnsi = ""
    var currentKind: Int = 0 // 0 = none, 1 = space, 2 = word
    var i = 0

    func flushCurrent() {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current = ""
        currentKind = 0
    }

    while i < chars.count {
        if let ansi = extractAnsiCode(chars, i) {
            pendingAnsi += ansi.code
            i += ansi.length
            continue
        }
        // Consume a run of visible graphemes up to the next escape.
        var end = i
        while end < chars.count, extractAnsiCode(chars, end) == nil { end += 1 }
        for character in chars[i..<end] {
            let isSpace = character == " "
            if !isSpace, isCJKBreak(character) {
                flushCurrent()
                tokens.append(pendingAnsi + String(character))
                pendingAnsi = ""
                continue
            }
            let kind = isSpace ? 1 : 2
            if !current.isEmpty, currentKind != kind {
                flushCurrent()
            }
            if !pendingAnsi.isEmpty {
                current += pendingAnsi
                pendingAnsi = ""
            }
            currentKind = kind
            current.append(character)
        }
        i = end
    }

    if !pendingAnsi.isEmpty {
        if !current.isEmpty {
            current += pendingAnsi
        } else if !tokens.isEmpty {
            tokens[tokens.count - 1] += pendingAnsi
        } else {
            current = pendingAnsi
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

/// Break a single token wider than `width` grapheme-by-grapheme, preserving
/// active style across the breaks. Ported from `breakLongWord`.
private func breakLongWord(_ word: String, _ width: Int, _ tracker: AnsiCodeTracker) -> [String] {
    var lines: [String] = []
    var currentLine = tracker.getActiveCodes()
    var currentWidth = 0

    let chars = Array(word)
    var i = 0
    while i < chars.count {
        if let ansi = extractAnsiCode(chars, i) {
            currentLine += ansi.code
            tracker.process(ansi.code)
            i += ansi.length
            continue
        }
        let character = chars[i]
        let w = graphemeWidth(character)
        if currentWidth + w > width {
            currentLine += tracker.getLineEndReset()
            lines.append(currentLine)
            currentLine = tracker.getActiveCodes()
            currentWidth = 0
        }
        currentLine.append(character)
        currentWidth += w
        i += 1
    }
    if !currentLine.isEmpty { lines.append(currentLine) }
    return lines.isEmpty ? [""] : lines
}

private func trimEnd(_ string: String) -> String {
    var chars = Array(string)
    while let last = chars.last, last == " " || last == "\t" { chars.removeLast() }
    return String(chars)
}

private func wrapSingleLine(_ line: String, _ width: Int) -> [String] {
    if line.isEmpty { return [""] }
    if visibleWidth(line) <= width { return [line] }

    var wrapped: [String] = []
    let tracker = AnsiCodeTracker()
    let tokens = splitIntoTokens(line)

    var currentLine = ""
    var currentVisibleLength = 0

    for token in tokens {
        let tokenVisibleLength = visibleWidth(token)
        let isWhitespace = trimEnd(token).isEmpty

        // Token itself is too long: break it grapheme by grapheme.
        if tokenVisibleLength > width, !isWhitespace {
            if !currentLine.isEmpty {
                currentLine += tracker.getLineEndReset()
                wrapped.append(currentLine)
                currentLine = ""
                currentVisibleLength = 0
            }
            let broken = breakLongWord(token, width, tracker)
            for k in 0..<(broken.count - 1) { wrapped.append(broken[k]) }
            currentLine = broken[broken.count - 1]
            currentVisibleLength = visibleWidth(currentLine)
            continue
        }

        let totalNeeded = currentVisibleLength + tokenVisibleLength
        if totalNeeded > width, currentVisibleLength > 0 {
            var lineToWrap = trimEnd(currentLine)
            lineToWrap += tracker.getLineEndReset()
            wrapped.append(lineToWrap)
            if isWhitespace {
                currentLine = tracker.getActiveCodes()
                currentVisibleLength = 0
            } else {
                currentLine = tracker.getActiveCodes() + token
                currentVisibleLength = tokenVisibleLength
            }
        } else {
            currentLine += token
            currentVisibleLength += tokenVisibleLength
        }
        updateTracker(from: token, tracker)
    }

    if !currentLine.isEmpty { wrapped.append(currentLine) }
    return wrapped.isEmpty ? [""] : wrapped.map(trimEnd)
}

/// Word-wrap `text` to `width` visible columns, preserving ANSI styling across
/// line breaks and honouring embedded newlines. Ported from `wrapTextWithAnsi`.
///
/// Does word wrapping only — no padding, no background fill. Each returned line's
/// visible width is at most `width`.
public func wrapTextWithAnsi(_ text: String, _ width: Int) -> [String] {
    if text.isEmpty { return [""] }
    // Split on CRLF / CR / LF, keeping empty segments.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let inputLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    var result: [String] = []
    let tracker = AnsiCodeTracker()
    for inputLine in inputLines {
        let prefix = result.isEmpty ? "" : tracker.getActiveCodes()
        result.append(contentsOf: wrapSingleLine(prefix + inputLine, width))
        updateTracker(from: inputLine, tracker)
    }
    return result.isEmpty ? [""] : result
}

// MARK: - Text

/// A styled string rendered as wrapped (or truncated) lines.
///
/// The simplest non-trivial component: it owns a string that may carry ANSI
/// styling and newlines, and turns it into lines that respect the viewport
/// width. `wrap` chooses between word-wrapping the content to fit (the default)
/// and clipping each logical line to a single width-bounded line with an
/// ellipsis — the two shapes a one-line status and a flowing paragraph need.
public final class Text: Component {
    public var content: String
    public var wrap: Bool

    public init(_ content: String, wrap: Bool = true) {
        self.content = content
        self.wrap = wrap
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        if wrap { return wrapTextWithAnsi(content, width) }
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.map { truncateToWidth($0, width) }
    }
}

// MARK: - Spacer

/// A run of blank lines — vertical whitespace between components.
public final class Spacer: Component {
    public var lines: Int

    public init(lines: Int = 1) {
        self.lines = lines
    }

    public func render(width: Int) -> [String] {
        Array(repeating: "", count: max(0, lines))
    }
}

// MARK: - Box

/// A component that frames a child in a single-line border with padding.
///
/// Enough of a container to prove overlays and the diff against non-trivial
/// content: it renders its child at the reduced inner width, pads every inner
/// line to a uniform block, and wraps the block in box-drawing characters — so a
/// `Box` line is always exactly `width` columns, which is exactly what the
/// renderer's fatal-width invariant wants to see.
public final class Box: Component {
    public var child: Component
    public var paddingX: Int
    public var paddingY: Int

    /// Corner and edge glyphs, all width 1.
    private static let topLeft = "\u{250C}"
    private static let topRight = "\u{2510}"
    private static let bottomLeft = "\u{2514}"
    private static let bottomRight = "\u{2518}"
    private static let horizontal = "\u{2500}"
    private static let vertical = "\u{2502}"

    public init(_ child: Component, paddingX: Int = 1, paddingY: Int = 0) {
        self.child = child
        self.paddingX = max(0, paddingX)
        self.paddingY = max(0, paddingY)
    }

    public func invalidate() { child.invalidate() }

    public func render(width: Int) -> [String] {
        // Two border columns plus horizontal padding on each side.
        let innerWidth = width - 2 - paddingX * 2
        guard innerWidth > 0 else {
            // Too narrow to frame anything: emit a solid border block.
            let bar = Box.horizontal.repeated(max(0, width))
            return width >= 2 ? [Box.topLeft + Box.horizontal.repeated(width - 2) + Box.topRight] : [bar]
        }

        let horizontalPad = String(repeating: " ", count: paddingX)
        let blankInner = padToWidth("", innerWidth)

        var contentLines = child.render(width: innerWidth)
        for _ in 0..<paddingY { contentLines.insert(blankInner, at: 0) }
        for _ in 0..<paddingY { contentLines.append(blankInner) }

        var lines: [String] = []
        lines.append(Box.topLeft + Box.horizontal.repeated(width - 2) + Box.topRight)
        for line in contentLines {
            let padded = padToWidth(truncateToWidth(line, innerWidth), innerWidth)
            lines.append(Box.vertical + horizontalPad + padded + horizontalPad + Box.vertical)
        }
        lines.append(Box.bottomLeft + Box.horizontal.repeated(width - 2) + Box.bottomRight)
        return lines
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        count > 0 ? String(repeating: self, count: count) : ""
    }
}
