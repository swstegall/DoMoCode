// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Text selection over a painted alternate-screen page. There is no upstream in
// pi: pi runs inline, so the terminal's own selection is always available and pi
// never had to build one. A full-screen app that takes the mouse to scroll takes
// the selection away with it, and this is what gives it back.
//
// It lives in DoMoTUI, not in the client, for three concrete reasons: it needs
// `sliceByColumn`/`visibleWidth`/`padToWidth` (TextSlicing.swift, TextWidth.swift),
// it needs the module-internal `isWordCharacter`/`isWhitespaceCluster`/`isCJKCluster`
// (WordNavigation.swift) — reaching them from another target would mean widening
// them to `public` — and a selection is a property of any alt-screen frame, not of
// one app.
//
// Everything here is a pure function of a painted `[String]` frame. `DoMoTUI` is
// `.defaultIsolation(MainActor.self)`, so every declaration is spelled
// `nonisolated` (the same rule TextWidth.swift states at its head), and every one
// is `public` so its tests need no `@testable` and therefore build in release.

import DoMoTermGraphics

// MARK: - Cells

/// A cell on the painted page, 0-based, origin top-left.
public nonisolated struct ScreenCell: Sendable, Hashable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Reading order: row first, then column. This ordering is what makes a
    /// ``ScreenSelection`` a STREAM rather than a rectangle.
    public static func < (lhs: ScreenCell, rhs: ScreenCell) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

// MARK: - Selection

/// An anchor + focus pair over a painted frame, selected in STREAM order.
///
/// A terminal does not select a rectangle. Dragging from the middle of row 3 to
/// the middle of row 7 takes the REST of row 3, all of rows 4–6, and the START of
/// row 7 — which is what ``columnSpan(on:columns:)`` computes, and what makes a
/// copied paragraph read as prose instead of as a column of fragments.
///
/// `columns` is the horizontal window the selection is confined to (a pane), so a
/// drag that began in the transcript never cuts the sidebar into every line.
///
/// Anchor and focus are stored unnormalized so a drag can run in either
/// direction; ``start``/``end`` normalize on read, which is why dragging upward
/// and dragging downward over the same two cells select exactly the same text.
public nonisolated struct ScreenSelection: Sendable, Hashable {
    /// Where the drag began. Fixed for the life of the drag; shift-click moves
    /// the focus and leaves this alone.
    public var anchor: ScreenCell
    /// Where the pointer is now.
    public var focus: ScreenCell

    public init(anchor: ScreenCell, focus: ScreenCell) {
        self.anchor = anchor
        self.focus = focus
    }

    /// The earlier of anchor and focus in reading order.
    public var start: ScreenCell { Swift.min(anchor, focus) }
    /// The later of anchor and focus in reading order.
    public var end: ScreenCell { Swift.max(anchor, focus) }
    /// Whether the selection covers no cells at all — a press and release in one
    /// place, which must not leave a phantom one-cell highlight behind.
    public var isEmpty: Bool { start == end }
    /// The inclusive row band the selection touches.
    public var rows: ClosedRange<Int> { start.row...end.row }

    /// The half-open column span selected on `row`, clamped into `columns`, or
    /// `nil` when this row carries no selection.
    ///
    /// The stream rule, stated once:
    ///
    ///   * `row` outside `start.row...end.row` → `nil`
    ///   * `start.row == end.row` → `start.column..<end.column`
    ///   * `row == start.row` → `start.column..<columns.upperBound`
    ///   * `row == end.row` → `columns.lowerBound..<end.column`
    ///   * otherwise → the whole of `columns`
    ///
    /// then intersected with `columns`. An empty intersection is `nil`, never an
    /// empty range: "nothing selected here" and "a zero-width selection here" are
    /// the same thing to every caller, and collapsing them removes a case.
    public func columnSpan(on row: Int, columns: Range<Int>) -> Range<Int>? {
        guard columns.lowerBound < columns.upperBound else { return nil }
        let first = start
        let last = end
        guard row >= first.row, row <= last.row else { return nil }

        let lower: Int
        let upper: Int
        if first.row == last.row {
            lower = first.column
            upper = last.column
        } else if row == first.row {
            lower = first.column
            upper = columns.upperBound
        } else if row == last.row {
            lower = columns.lowerBound
            upper = last.column
        } else {
            lower = columns.lowerBound
            upper = columns.upperBound
        }

        let clampedLower = Swift.max(lower, columns.lowerBound)
        let clampedUpper = Swift.min(upper, columns.upperBound)
        guard clampedLower < clampedUpper else { return nil }
        return clampedLower..<clampedUpper
    }
}

// MARK: - Plain text

/// `line` with every ANSI/OSC/APC escape removed — the clipboard's view of a
/// painted row.
///
/// Walks with ``ansiEscapeLength(in:at:)``, the same scanner every slicer in this
/// module shares, so it drops SGR, OSC-8 hyperlink pairs and the APC cursor
/// marker alike, and never splits a grapheme cluster.
///
/// Deliberately NOT `sanitizeUntrustedText`, which SUBSTITUTES `·` for control
/// characters. That is a display guard: it exists so untrusted text cannot repaint
/// the screen. Pasting a `·` where an `ESC` was would be a lie about what the user
/// selected, and pasting a `·` for every byte of a colour code would be unusable.
public nonisolated func strippingANSI(_ line: String) -> String {
    guard line.unicodeScalars.contains(where: { $0.value == 0x1B }) else { return line }
    let chars = Array(line)
    var result = ""
    var index = 0
    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            index += length
            continue
        }
        result.append(chars[index])
        index += 1
    }
    return result
}

/// The plain text occupying visible columns `from..<to` of `line`.
///
/// The plain-text sibling of ``sliceByColumn(_:from:to:strict:)``: it shares the
/// escape scanner and the grapheme walk, so a column here means the same cell it
/// means there. A wide (CJK, emoji) cluster straddling either boundary is DROPPED
/// rather than split or blanked — a half-copied glyph is worse than a missing one,
/// and a space in its place would silently alter the text the user asked for.
///
/// The result therefore measures AT MOST `to - from` columns, and can measure
/// less. Callers that need an exact width want ``highlightColumns(_:from:to:width:)``,
/// which blanks the straddle instead.
public nonisolated func plainSliceByColumn(_ line: String, from: Int, to: Int) -> String {
    guard to > from else { return "" }
    let chars = Array(line)
    var result = ""
    var column = 0
    var index = 0
    /// Whether the most recent printable cluster made it into the window, so a
    /// combining mark or default-ignorable follows the cell it decorates instead
    /// of being stranded on its own.
    var keptLast = false
    while index < chars.count, column < to {
        if let length = ansiEscapeLength(in: chars, at: index) {
            index += length
            continue
        }
        let character = chars[index]
        let width = graphemeWidth(character)
        if width == 0 {
            if keptLast { result.append(character) }
        } else {
            keptLast = column >= from && column + width <= to
            if keptLast { result.append(character) }
        }
        column += width
        index += 1
    }
    return result
}

/// `line` with its trailing blank padding removed.
///
/// Every frame row is blank-padded to the pane width by `CellBuffer.flatten()`, so
/// without this a copy comes back padded to the terminal width on every line.
private nonisolated func trimmingTrailingBlanks(_ line: String) -> String {
    var result = line
    while let last = result.last, last == " " || last == "\t" {
        result.removeLast()
    }
    return result
}

// MARK: - Highlighting

/// The reverse-video attribute, opened after a full reset so a style already
/// active on the row cannot suppress it.
private nonisolated let selectionOpen = "\u{1b}[0m\u{1b}[7m"
/// Reverse video off, then a full reset, so nothing leaks into the tail.
private nonisolated let selectionClose = "\u{1b}[27m\u{1b}[0m"

/// `line` with visible columns `from..<to` rendered in reverse video, in EXACTLY
/// the same number of visible columns as `line` occupied.
///
/// The width invariance is not a nicety. `AltScreenCore.frame` throws on any row
/// wider than the terminal, and the driver escalates that throw to ending the
/// session — so a highlight that added a column would kill the user's session the
/// first time they dragged across a CJK glyph. Every branch below is written to
/// keep the sum `a + (b - a) + (width - b)` exact.
///
/// The highlighted middle is re-emitted as PLAIN text wrapped in `ESC[7m … ESC[27m`
/// rather than styled in place, because a row's own `ESC[0m` — and every dimmed
/// row emits one — sitting inside the span would cancel the reverse attribute
/// mid-highlight and leave the selection visibly striped. Uniform reverse video is
/// also what a terminal's own selection looks like. The styles that were active
/// entering the span are re-emitted after it, so text to the right of the
/// selection keeps its colour.
///
/// A cluster that straddles either edge of the span, or the right edge of the
/// page, is replaced by one blank per column it covered, in the segment that owns
/// that column. That is the only construction that both preserves the width and
/// keeps the highlight boundary where the user put it.
///
/// An image row (``isImageLine(_:)``) is returned untouched: its escape is an
/// opaque payload and slicing it corrupts the image — the same guard
/// `compositeLineAt` applies.
public nonisolated func highlightColumns(_ line: String, from: Int, to: Int, width: Int) -> String {
    if width <= 0 { return line }
    if isImageLine(line) { return line }
    let spanStart = Swift.max(0, Swift.min(from, width))
    let spanEnd = Swift.max(spanStart, Swift.min(to, width))
    guard spanEnd > spanStart else { return line }

    let chars = Array(line)
    var before = ""
    var middle = ""
    var after = ""
    var beforeWidth = 0
    var middleWidth = 0
    var afterWidth = 0
    /// Every escape seen before the tail begins, replayed at the head of the
    /// tail — the same "carry the entering style in" rule `sliceWithWidth` uses.
    var entering = ""
    var column = 0
    var index = 0

    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            let code = String(chars[index..<index + length])
            if column < spanEnd {
                // Escapes inside the span are suppressed (the span is plain) but
                // still count towards the style the tail inherits.
                if column < spanStart { before += code }
                entering += code
            } else {
                after += code
            }
            index += length
            continue
        }

        let character = chars[index]
        // A row wider than the page is clipped rather than carried: the renderer
        // has budgeted exactly `width` columns and an over-wide row ends the
        // session. Escapes past the edge still ride along, above.
        guard column < width else {
            column += graphemeWidth(character)
            index += 1
            continue
        }
        let clusterWidth = graphemeWidth(character)
        let clusterStart = column
        let clusterEnd = column + clusterWidth

        if clusterWidth == 0 {
            if clusterStart < spanStart {
                before.append(character)
            } else if clusterStart < spanEnd {
                middle.append(character)
            } else {
                after.append(character)
            }
        } else if clusterEnd <= spanStart {
            before.append(character)
            beforeWidth += clusterWidth
        } else if clusterStart >= spanStart, clusterEnd <= spanEnd {
            middle.append(character)
            middleWidth += clusterWidth
        } else if clusterStart >= spanEnd, clusterEnd <= width {
            after.append(character)
            afterWidth += clusterWidth
        } else {
            // Straddles a boundary. Blank each column it covered, in whichever
            // segment owns that column, so no segment loses or gains a cell.
            for covered in clusterStart..<Swift.min(clusterEnd, width) {
                if covered < spanStart {
                    before += " "
                    beforeWidth += 1
                } else if covered < spanEnd {
                    middle += " "
                    middleWidth += 1
                } else {
                    after += " "
                    afterWidth += 1
                }
            }
        }

        column = clusterEnd
        index += 1
    }

    // A row shorter than the page: the missing cells are genuinely at the right
    // of each segment, so appending is correct here and only here.
    before += String(repeating: " ", count: Swift.max(0, spanStart - beforeWidth))
    middle += String(repeating: " ", count: Swift.max(0, (spanEnd - spanStart) - middleWidth))
    after += String(repeating: " ", count: Swift.max(0, (width - spanEnd) - afterWidth))

    // A span that runs to the edge of the page has no tail to restyle, so the
    // carried escapes are dropped rather than emitted after the last cell.
    let tail = spanEnd < width ? entering + after : after
    return before + selectionOpen + middle + selectionClose + tail
}

/// Every row of `lines` with its selected span highlighted.
///
/// Rows outside the selection are returned byte-identical, which is what keeps the
/// differential renderer from repainting the whole page for a one-row highlight:
/// its per-row skip compares the strings.
public nonisolated func applySelectionHighlight(
    _ lines: [String],
    selection: ScreenSelection,
    columns: Range<Int>,
    width: Int
) -> [String] {
    guard !selection.isEmpty else { return lines }
    var result = lines
    for row in selection.rows {
        guard row >= 0, row < lines.count else { continue }
        guard let span = selection.columnSpan(on: row, columns: columns) else { continue }
        result[row] = highlightColumns(lines[row], from: span.lowerBound, to: span.upperBound, width: width)
    }
    return result
}

/// The selection as plain text, rows joined with `"\n"`.
///
/// Each row is stripped of escapes and of its trailing blank padding: a frame row
/// is padded to the pane width by the cell buffer, and pasting sixty trailing
/// spaces per line is not what the user selected. Rows that fall outside the frame
/// are skipped rather than contributing empty lines.
public nonisolated func selectionText(
    _ lines: [String],
    selection: ScreenSelection,
    columns: Range<Int>
) -> String {
    guard !selection.isEmpty else { return "" }
    var rows: [String] = []
    for row in selection.rows {
        guard row >= 0, row < lines.count else { continue }
        guard let span = selection.columnSpan(on: row, columns: columns) else { continue }
        let text = plainSliceByColumn(lines[row], from: span.lowerBound, to: span.upperBound)
        rows.append(trimmingTrailingBlanks(text))
    }
    return rows.joined(separator: "\n")
}

// MARK: - Word and line spans

/// One printable cell of a row: the cluster, the column it starts at, and how
/// many columns it covers. Escapes are gone and zero-width clusters are folded
/// into the cell they decorate, so an index into this array IS a cell.
private nonisolated struct PlainCell {
    var text: String
    var column: Int
    var width: Int
}

/// Decompose `line` into its printable cells.
private nonisolated func plainCells(_ line: String) -> [PlainCell] {
    let chars = Array(line)
    var cells: [PlainCell] = []
    var column = 0
    var index = 0
    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            index += length
            continue
        }
        let character = chars[index]
        let width = graphemeWidth(character)
        if width == 0 {
            if !cells.isEmpty { cells[cells.count - 1].text.append(character) }
        } else {
            cells.append(PlainCell(text: String(character), column: column, width: width))
            column += width
        }
        index += 1
    }
    return cells
}

/// How a cell participates in word selection.
private nonisolated enum CellClass {
    case whitespace
    case latinWord
    case cjkWord
    case punctuation
}

private nonisolated func classify(_ cell: PlainCell) -> CellClass {
    guard let first = cell.text.first else { return .punctuation }
    if isWhitespaceCluster(first) { return .whitespace }
    if isCJKCluster(first) { return .cjkWord }
    if isWordCharacter(first) { return .latinWord }
    return .punctuation
}

/// The column span of the word under `column` on `line`, or `nil` when the click
/// landed past the row's content — double-click.
///
/// Classification reuses ``isWordCharacter(_:)``/``isWhitespaceCluster(_:)``/
/// ``isCJKCluster(_:)``, the same predicates Ctrl-Left/Ctrl-Right navigate by, so a
/// double-click selects exactly the run a word-wise cursor move would cross. A
/// click on whitespace selects the whitespace run (the terminal behaviour), a
/// click on punctuation selects the punctuation run, and a latin↔CJK transition is
/// a boundary.
///
/// Returned in the row's own visible columns; a caller working in a pane window
/// offsets it.
public nonisolated func wordColumnSpan(in line: String, atColumn column: Int) -> Range<Int>? {
    let cells = plainCells(line)
    guard let hit = cells.firstIndex(where: { column >= $0.column && column < $0.column + $0.width }) else {
        return nil
    }
    let target = classify(cells[hit])
    var lower = hit
    while lower > 0, classify(cells[lower - 1]) == target { lower -= 1 }
    var upper = hit
    while upper + 1 < cells.count, classify(cells[upper + 1]) == target { upper += 1 }
    return cells[lower].column..<(cells[upper].column + cells[upper].width)
}

/// The span of `line`'s content with trailing blanks dropped — triple-click.
///
/// Starts at column 0 rather than at the first non-blank: leading indentation is
/// part of a line of code, and a triple-click that silently dropped it would paste
/// something that does not compile. Trailing blanks are pure padding and carry no
/// such meaning. An entirely blank row yields an empty span.
public nonisolated func contentColumnSpan(in line: String) -> Range<Int> {
    let cells = plainCells(line)
    guard let last = cells.lastIndex(where: { classify($0) != .whitespace }) else { return 0..<0 }
    return 0..<(cells[last].column + cells[last].width)
}
