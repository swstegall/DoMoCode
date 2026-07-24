// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import SwiftTerm

// MARK: - Plain cell model

/// A cell's colour, reduced to plain Swift values a test can write literally.
///
/// SwiftTerm's `Attribute.Color` is not `Sendable` and carries emulator-internal
/// distinctions; this is the subset an assertion cares about.
enum OracleColor: Equatable, Sendable {
    case `default`
    case defaultInverted
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    init(_ color: Attribute.Color) {
        switch color {
        case .defaultColor: self = .default
        case .defaultInvertedColor: self = .defaultInverted
        case .ansi256(let code): self = .ansi(code)
        case .trueColor(let r, let g, let b): self = .rgb(r, g, b)
        }
    }
}

/// The style flags and colours of one cell, as plain values.
struct OracleStyle: Equatable, Sendable {
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var blink = false
    var inverse = false
    var invisible = false
    var crossedOut = false
    var foreground: OracleColor = .default
    var background: OracleColor = .default

    init(_ attribute: Attribute) {
        let style = attribute.style
        bold = style.contains(.bold)
        dim = style.contains(.dim)
        italic = style.contains(.italic)
        underline = style.contains(.underline)
        blink = style.contains(.blink)
        inverse = style.contains(.inverse)
        invisible = style.contains(.invisible)
        crossedOut = style.contains(.crossedOut)
        foreground = OracleColor(attribute.fg)
        background = OracleColor(attribute.bg)
    }
}

/// One screen cell: the character shown, how many columns it claims, and its
/// style. `width` is 2 for a wide (CJK/emoji) glyph, and 0 for the placeholder
/// cell a wide glyph's second column holds.
struct OracleCell: Equatable, Sendable {
    var character: Character
    var width: Int
    var style: OracleStyle
}

// MARK: - Oracle

/// A headless VT100 screen used as a test oracle.
///
/// Renderer bytes go in via ``feed(_:)``; the resulting *cell grid* comes back
/// as plain Swift values. This is the tool that catches the renderer bug class
/// the whole phase exists to avoid: a diff that emits a cursor-down which clamps
/// at the bottom margin instead of scrolling would overwrite the transcript, and
/// only an emulator that actually models a screen — cursor, margins, scrollback
/// — reveals it. A harness that records the emitted bytes and diffs *those*
/// cannot: the bytes look fine, it is the terminal's reaction to them that is
/// wrong.
///
/// Not `Sendable` on purpose: `SwiftTerm.Terminal` is a Swift-5-mode reference
/// type with no `Sendable` conformance. An oracle is created and driven within a
/// single test function, never shared across isolation domains.
final class ScreenOracle {
    /// Absorbs the terminal's back-channel writes (cursor/DA replies) so they do
    /// not deadlock or escape. A test oracle has no host to answer.
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let sink = Sink()
    let terminal: Terminal

    init(rows: Int, cols: Int, scrollback: Int = 500) {
        var options = TerminalOptions.default
        options.rows = rows
        options.cols = cols
        options.scrollback = scrollback
        terminal = Terminal(delegate: sink, options: options)
    }

    var rows: Int { terminal.rows }
    var cols: Int { terminal.cols }

    /// Cursor position as `(col, row)`, both zero-based and viewport-relative.
    var cursor: (col: Int, row: Int) {
        let location = terminal.getCursorLocation()
        return (location.x, location.y)
    }

    func feed(_ text: String) { terminal.feed(text: text) }
    func feed(bytes: [UInt8]) { terminal.feed(byteArray: bytes) }

    // MARK: Reading the grid

    /// The cell at viewport coordinates, or `nil` when out of range.
    func cell(col: Int, row: Int) -> OracleCell? {
        guard let data = terminal.getCharData(col: col, row: row) else { return nil }
        // A null scalar is an unwritten cell (and the spacer column a wide glyph
        // leaves behind); show it as the space the screen actually displays.
        let raw = terminal.getCharacter(for: data)
        let character = raw.unicodeScalars.first?.value == 0 ? " " : raw
        return OracleCell(character: character, width: Int(data.width), style: OracleStyle(data.attribute))
    }

    /// One viewport row as a string, trailing blanks trimmed.
    func row(_ row: Int) -> String {
        guard let line = terminal.getLine(row: row) else { return "" }
        return line.translateToString(trimRight: true, characterProvider: terminal.getCharacter(for:))
    }

    /// The whole viewport, one string per row, trailing blanks trimmed.
    var screen: [String] { (0..<rows).map(row) }

    /// The full cell grid of the viewport.
    var grid: [[OracleCell]] {
        (0..<rows).map { r in (0..<cols).map { c in cell(col: c, row: r) ?? OracleCell(character: " ", width: 1, style: OracleStyle(.empty)) } }
    }

    // MARK: Reading the transcript (scrollback + viewport)

    /// Every retained line — scrolled-off history *and* the current viewport — in
    /// order, trailing blanks trimmed.
    ///
    /// This is what the scrolled-transcript fixture asserts against: content that
    /// left the top of the screen must still be here, proving the emulator
    /// scrolled it into scrollback rather than clobbering it.
    var transcript: [String] {
        let top = terminal.buffer.totalLinesTrimmed
        var lines: [String] = []
        var index = top
        while let line = terminal.getScrollInvariantLine(row: index) {
            lines.append(line.translateToString(trimRight: true, characterProvider: terminal.getCharacter(for:)))
            index += 1
        }
        return lines
    }

    /// The transcript with trailing all-blank lines removed — the content the
    /// user would see if they scrolled all the way up, minus the empty tail a
    /// fresh viewport leaves behind.
    var transcriptTrimmed: [String] {
        var lines = transcript
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }
}
