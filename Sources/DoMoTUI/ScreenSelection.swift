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

/// A `nonisolated` copy of ``cursorMarker``.
///
/// `cursorMarker` is a `public let` declared in a module built with
/// `.defaultIsolation(MainActor.self)` and carries no `nonisolated`, so it infers
/// `@MainActor` and cannot be read from this file, every declaration of which is
/// `nonisolated` on purpose (see the header). Duplicating the four-byte literal is
/// the smaller evil; `cursorMarkerIsNeitherDuplicatedNorMovedNorLost` drives
/// ``highlightColumns(_:from:to:width:)`` with the REAL ``cursorMarker``, so the
/// two drifting apart is a test failure rather than a silent regression.
private nonisolated let caretMarkerSequence = "\u{1b}_pi:c\u{07}"

/// Reverse video, RE-stated, used inside the span purely as a zero-width grapheme
/// break.
///
/// The span is re-emitted plain, so the escapes that stood between two clusters in
/// the row are gone — and Swift RE-SEGMENTS what is left when they are
/// concatenated. `"✅" + ZWJ` beside `"✅"` is two clusters worth four columns
/// while an escape separates them and ONE cluster worth two the instant it is
/// removed, so the row would quietly lose two columns and the frame would paint
/// stale glyphs at its right edge. Putting the attribute the span is ALREADY
/// painting back into the gap restores the break for zero visible columns, and it
/// cannot stripe the selection the way replaying the row's own `ESC[0m` would,
/// because it turns reverse video on where reverse video is already on.
///
/// It is a CANDIDATE, never a guarantee: its own trailing `m` is itself fusable —
/// an emoji modifier such as U+1F3FB is `Extend` and swallows it — so
/// ``assembleRow(_:width:)`` only keeps the break when re-measuring says it worked.
private nonisolated let selectionGraphemeBreak = "\u{1b}[7m"

/// One unit of the row ``highlightColumns(_:from:to:width:)`` is assembling: some
/// literal text, and the number of visible columns that text is ACCOUNTABLE for.
///
/// Splitting the row into pieces with a declared column cost is what lets the
/// assembler check the width invariant by MEASUREMENT instead of by argument. Every
/// earlier attempt at this function reasoned about which scalars can fuse with an
/// inserted escape's final byte, and every such argument has been wrong in a way
/// that ended somebody's session.
private nonisolated struct RowPiece {
    /// The bytes to emit.
    var text: String
    /// How many terminal columns `text` must add to the row.
    var columns: Int
    /// Whether ``selectionGraphemeBreak`` may be inserted in front of `text` to
    /// undo a fusion. Only true inside the span, where reverse video is already on
    /// and re-stating it paints nothing; outside the span the same escape would
    /// smear the highlight across the rest of the row.
    var breakable: Bool
    /// Whether this piece IS the feature, so a row without it is not a row worth
    /// returning.
    ///
    /// The ladder's last resort is "emit nothing", which is sound for any piece
    /// that owes no columns — a style escape or a zero-width mark costs the row
    /// nothing, so dropping it keeps the width. That argument is about WIDTH only,
    /// and the two selection brackets are the counter-example: they owe no columns
    /// and they are the entire point of the call. Dropping one leaves reverse video
    /// opened and never closed; dropping both returns the row unhighlighted while
    /// claiming success. Marking them here makes "never drop the brackets" a
    /// property of the piece rather than a case analysis in the loop.
    var required: Bool

    init(_ text: String, columns: Int = 0, breakable: Bool = false, required: Bool = false) {
        self.text = text
        self.columns = columns
        self.breakable = breakable
        self.required = required
    }
}

/// Where a piece ends in an assembled row: the offset in UNICODE SCALARS, and the
/// number of columns everything up to there is declared to occupy.
///
/// Scalars, not `Character`s, because a `Character` boundary is exactly the thing
/// concatenation can destroy — and a piece boundary that is no longer a character
/// boundary is the fusion this file exists to survive. A scalar offset is stable
/// under concatenation, so it can name the place where a boundary was SUPPOSED to be.
private nonisolated struct PieceBoundary {
    var offset: Int
    var width: Int
}

/// Whether one left-to-right scan of `text` — the same scan ``visibleWidth(_:)``
/// performs — reaches every boundary in `boundaries` exactly, and carries exactly
/// the declared width when it gets there.
///
/// This is the whole width invariant, checked in a single O(`text`) pass against the
/// FINISHED string rather than against a chain of prefixes. It fails, correctly, on
/// both of the ways a concatenation can lie:
///
///   * a boundary that the scan steps OVER means two pieces fused into one cluster,
///     or a piece was swallowed into an escape that only became recognisable once the
///     next piece supplied its final byte;
///   * a boundary the scan lands on with the wrong running width means the pieces so
///     far do not occupy the columns they claimed.
private nonisolated func scanReachesEveryBoundary(_ text: String, _ boundaries: [PieceBoundary]) -> Bool {
    let chars = Array(text)
    var offset = 0
    var width = 0
    var index = 0
    var next = 0

    func settleBoundaries() -> Bool {
        while next < boundaries.count, boundaries[next].offset <= offset {
            guard boundaries[next].offset == offset, boundaries[next].width == width else { return false }
            next += 1
        }
        return true
    }

    while index < chars.count {
        guard settleBoundaries() else { return false }
        if let length = ansiEscapeLength(in: chars, at: index) {
            for step in index..<(index + length) { offset += chars[step].unicodeScalars.count }
            index += length
            continue
        }
        offset += chars[index].unicodeScalars.count
        width += graphemeWidth(chars[index])
        index += 1
    }
    guard settleBoundaries() else { return false }
    return next == boundaries.count
}

/// Concatenate `pieces`, keeping the running measured width equal to the running
/// declared width at EVERY piece boundary.
///
/// Appending to a string is not a local operation in this domain. Swift re-segments
/// graphemes across the join, so a cluster can fuse with the one before it and cost
/// two columns less than it did; and ``ansiEscapeLength(in:at:)`` re-scans, so a
/// byte can complete — or, by being swallowed into a cluster, un-complete — an
/// escape and move the width by the whole length of that escape. Both directions
/// are reachable from a row a hostile program can paint.
///
/// The ordinary row needs no repair, so the plain concatenation is tried first and
/// VERIFIED by ``scanReachesEveryBoundary(_:_:)`` — one linear pass, and a stronger
/// statement than the fallback makes, since it pins every piece to its own columns
/// in the finished string.
///
/// When that fails, each piece is offered to the row in order of decreasing
/// fidelity, and the first candidate whose MEASURED effect is exactly
/// `piece.columns` wins:
///
///   1. the piece itself;
///   2. inside the span, ``selectionGraphemeBreak`` then the piece;
///   3. one blank per column the piece owed — the same repair the straddle loop
///      already uses, and the only one that keeps the column count by construction;
///   4. nothing at all, for a piece that owes no columns (a style escape or a
///      zero-width mark) and is not ``RowPiece/required``, which costs the row
///      nothing.
///
/// A `required` piece that reaches the end of the ladder abandons the whole
/// assembly instead, because the last candidate trades content for width and the
/// selection brackets are content the width check cannot audit.
///
/// The returned string therefore satisfies `visibleWidth(result) == accepted`, where
/// `accepted` is at most the sum of the declared columns — so the result can be
/// SHORT (only if every candidate for some piece failed) but never OVER-wide.
/// `nil` reports that shortfall — or an unplaceable required piece — so the caller
/// can fall back to the untouched row.
private nonisolated func assembleRow(_ pieces: [RowPiece], width: Int) -> String? {
    var naive = ""
    var boundaries: [PieceBoundary] = []
    var offset = 0
    var declared = 0
    boundaries.reserveCapacity(pieces.count)
    for piece in pieces {
        naive += piece.text
        offset += piece.text.unicodeScalars.count
        declared += piece.columns
        boundaries.append(PieceBoundary(offset: offset, width: declared))
    }
    if declared == width, scanReachesEveryBoundary(naive, boundaries) { return naive }

    var result = ""
    var measured = 0
    for piece in pieces {
        let target = measured + piece.columns
        if visibleWidth(result + piece.text) == target {
            result += piece.text
            measured = target
            continue
        }
        if piece.breakable, visibleWidth(result + selectionGraphemeBreak + piece.text) == target {
            result += selectionGraphemeBreak + piece.text
            measured = target
            continue
        }
        if piece.columns > 0 {
            let blanks = String(repeating: " ", count: piece.columns)
            if visibleWidth(result + blanks) == target {
                result += blanks
                measured = target
                continue
            }
        }
        // A piece the caller marked `required` is never dropped: a row missing one
        // of its selection brackets is a WRONG row, not a narrower one, and the
        // width check below cannot see the difference. Bail out here and let the
        // caller return the untouched line — no highlight is a cosmetic loss, a
        // half-opened one leaks reverse video into the rest of the row.
        if piece.required { return nil }
        // Nothing that keeps the count fits. Dropping the piece keeps
        // `visibleWidth(result) == measured` true, which is what makes an over-wide
        // row impossible; the columns it owed are simply missing, and the guard
        // below turns that into an unhighlighted row rather than a wrong one.
    }
    // The total safety net, and deliberately a re-MEASUREMENT of the finished
    // string rather than a check of `measured`: it is the one statement here that
    // does not depend on the loop above being right, and it turns "the highlighted
    // row is exactly `width` columns" into a fact about the returned value instead
    // of a claim about the code that built it.
    //
    // Candidate 3 cannot fail — a blank is neither an `Extend`, a `ZWJ`, a
    // `SpacingMark` nor a CSI/OSC terminator, so appending one can neither fuse with
    // the cluster before it nor complete an escape — and candidate 4 always succeeds
    // for a piece that owes nothing, so on the rows that get this far `measured`
    // does reach `width`. That argument is exactly the kind that has been wrong
    // several times in this function, which is why the check is here rather than in
    // a comment: it costs one linear pass and it removes the argument from the
    // safety property.
    return visibleWidth(result) == width ? result : nil
}

/// `line` with visible columns `from..<to` rendered in reverse video, in EXACTLY
/// the same number of visible columns as `line` occupied.
///
/// The width invariance is not a nicety. `AltScreenCore.frame` throws on any row
/// wider than the terminal, and the driver escalates that throw to ending the
/// session — so a highlight that added a column would kill the user's session the
/// first time they dragged across a CJK glyph.
///
/// It is held by MEASUREMENT, not by argument. The row is decomposed into
/// ``RowPiece``s that each declare the columns they owe, and ``assembleRow(_:width:)``
/// re-measures after every append and repairs — with a grapheme break, or with
/// blanks, or by dropping a piece that owes nothing — whenever the measurement
/// disagrees. If the finished row still does not measure exactly `width`, the
/// UNTOUCHED `line` is returned.
///
/// The two reverse-video brackets are exempt from that last repair. They owe no
/// columns, so the width check alone would happily drop them — and a row that
/// opened reverse video and never closed it, or lost the highlight entirely while
/// measuring perfectly, is what that leniency produced. They are marked
/// ``RowPiece/required``, so the row falls back to `line` instead: dropping the
/// highlight the user asked for is a defect whether or not the width survives it. Losing the highlight on a pathological row is a
/// cosmetic glitch; returning an over-wide one ends the session, so no residual case
/// is left to an argument about which scalars fuse with which. Earlier versions of
/// this function made exactly that argument — that only zero-width scalars can fuse
/// with an inserted `ESC[7m`'s trailing `m` — and it is false: every emoji skin-tone
/// modifier (U+1F3FB…U+1F3FF) is `Extend`, measures two columns, and swallows it.
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
/// A ZERO-WIDTH cluster rides in the segment that owns the column it sits at, like
/// every other cluster — and is DROPPED when, and only when, the assembler measures
/// that keeping it changed the row's width. That is the case a bare combining mark
/// at the head of the span hits: placed straight after the inserted `ESC[7m` it
/// merges with that final `m` into a single `Character`,
/// ``ansiEscapeLength(in:at:)`` stops recognising the escape, and the scanner
/// swallows the text after it — the row then measures short and the frame paints
/// stale glyphs at the right of the line. Dropping it costs no columns, which is
/// why it is the right repair for a cluster that owes none.
///
/// The APC ``cursorMarker`` is carried in the segment that owns its column rather
/// than replayed with the entering styles. It is a POSITION, not a style:
/// replaying it would emit it TWICE when the caret is left of the span (once in
/// place, once with the restored styles), move it to the end of the span when the
/// caret is inside, and lose it entirely when the span runs to the page edge and
/// the carried styles are dropped. `AltScreenCore.extractCursorPosition` strips
/// only the first marker in a row, so each of those is a real defect: raw APC
/// bytes on the wire, or the hardware cursor parked in the wrong column.
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
    var beforePieces: [RowPiece] = []
    var middlePieces: [RowPiece] = []
    var afterPieces: [RowPiece] = []
    var beforeWidth = 0
    var middleWidth = 0
    var afterWidth = 0
    /// Every escape seen before the tail begins, replayed at the head of the
    /// tail — the same "carry the entering style in" rule `sliceWithWidth` uses.
    var entering = ""
    var column = 0
    var index = 0

    /// File `text` in the segment that owns visible column `covered`, and charge it
    /// `columns` cells of that segment's budget.
    ///
    /// One routing rule for escapes, printable clusters, zero-width clusters and
    /// straddle blanks alike: the column decides, nothing else. Whether a piece can
    /// actually be written where it lands is not decided here — that is
    /// ``assembleRow(_:width:)``'s job, and it decides it by measuring.
    func emit(_ text: String, columns: Int, at covered: Int) {
        if covered < spanStart {
            beforePieces.append(RowPiece(text, columns: columns))
            beforeWidth += columns
        } else if covered < spanEnd {
            middlePieces.append(RowPiece(text, columns: columns, breakable: true))
            middleWidth += columns
        } else {
            afterPieces.append(RowPiece(text, columns: columns))
            afterWidth += columns
        }
    }

    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            let code = String(chars[index..<index + length])
            // The APC caret marker is a position, not a style, so it is never
            // replayed with `entering`: it rides in the segment that owns its
            // column and stays at exactly the column it marked.
            let isCaretMarker = code == caretMarkerSequence
            // Escapes INSIDE the span are suppressed — the span is re-emitted plain
            // so a colour of its own cannot stripe the highlight — but everything
            // before the tail still counts towards the style the tail inherits.
            let suppressed = column >= spanStart && column < spanEnd && !isCaretMarker
            if !suppressed { emit(code, columns: 0, at: column) }
            if column < spanEnd, !isCaretMarker { entering += code }
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

        // Whether the cluster lies wholly inside ONE of the three column ranges
        // `[0, spanStart)`, `[spanStart, spanEnd)`, `[spanEnd, width)`. A zero-width
        // cluster always does — it covers no columns at all.
        let fitsOneSegment =
            clusterWidth == 0
            || clusterEnd <= spanStart
            || (clusterStart >= spanStart && clusterEnd <= spanEnd)
            || (clusterStart >= spanEnd && clusterEnd <= width)

        if fitsOneSegment {
            emit(String(character), columns: clusterWidth, at: clusterStart)
        } else {
            // Straddles a boundary. Blank each column it covered, in whichever
            // segment owns that column, so no segment loses or gains a cell.
            for covered in clusterStart..<Swift.min(clusterEnd, width) {
                emit(" ", columns: 1, at: covered)
            }
        }

        column = clusterEnd
        index += 1
    }

    // A row shorter than the page: the missing cells are genuinely at the right
    // of each segment, so appending is correct here and only here.
    let beforePad = Swift.max(0, spanStart - beforeWidth)
    let middlePad = Swift.max(0, (spanEnd - spanStart) - middleWidth)
    let afterPad = Swift.max(0, (width - spanEnd) - afterWidth)

    var pieces = beforePieces
    pieces.append(RowPiece(String(repeating: " ", count: beforePad), columns: beforePad))
    pieces.append(RowPiece(selectionOpen, required: true))
    pieces += middlePieces
    pieces.append(RowPiece(String(repeating: " ", count: middlePad), columns: middlePad, breakable: true))
    pieces.append(RowPiece(selectionClose, required: true))
    // A span that runs to the edge of the page has no tail to restyle, so the
    // carried escapes are dropped rather than emitted after the last cell.
    if spanEnd < width { pieces.append(RowPiece(entering)) }
    pieces += afterPieces
    pieces.append(RowPiece(String(repeating: " ", count: afterPad), columns: afterPad))

    return assembleRow(pieces, width: width) ?? line
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
