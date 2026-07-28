// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The selection model, asserted through the public API only — no `@testable`, so
// this suite builds and runs in release exactly as it does in debug.
//
// Two of these tests are load-bearing rather than descriptive:
//
//  * WIDTH INVARIANCE. `AltScreenCore.frame` throws on a row wider than the
//    terminal and the driver escalates that to ending the session, so a highlight
//    that added one column would hang up on the user the first time they dragged
//    across a CJK glyph. The property is swept over every (from, to) pair on a
//    table of styled, wide and zero-width rows.
//  * STREAM SHAPE. A terminal selects a stream, not a rectangle. Getting this
//    wrong is not a cosmetic difference: it turns a copied paragraph into a column
//    of fragments.

import DoMoTUI
import Testing

@Suite("Screen selection")
struct ScreenSelectionTests {

    private let escape = "\u{1b}"

    // MARK: Stream shape

    @Test("A multi-row selection is a stream: rest of the first row, all of the middle, start of the last")
    func streamNotRectangle() {
        let selection = ScreenSelection(
            anchor: ScreenCell(row: 1, column: 5),
            focus: ScreenCell(row: 3, column: 2)
        )
        let columns = 0..<20
        #expect(selection.columnSpan(on: 1, columns: columns) == 5..<20)
        #expect(selection.columnSpan(on: 2, columns: columns) == 0..<20)
        #expect(selection.columnSpan(on: 3, columns: columns) == 0..<2)
        #expect(selection.rows == 1...3)
    }

    @Test("Dragging upward selects exactly what dragging downward selects")
    func normalizationIsDirectionFree() {
        let downward = ScreenSelection(anchor: ScreenCell(row: 1, column: 5), focus: ScreenCell(row: 3, column: 2))
        let upward = ScreenSelection(anchor: ScreenCell(row: 3, column: 2), focus: ScreenCell(row: 1, column: 5))
        let columns = 0..<20
        for row in 1...3 {
            #expect(downward.columnSpan(on: row, columns: columns) == upward.columnSpan(on: row, columns: columns))
        }
        #expect(upward.start == ScreenCell(row: 1, column: 5))
        #expect(upward.end == ScreenCell(row: 3, column: 2))
    }

    @Test("A single-row selection is one half-open span, and rows outside it are nil")
    func singleRowAndOutOfRange() {
        let selection = ScreenSelection(anchor: ScreenCell(row: 4, column: 3), focus: ScreenCell(row: 4, column: 9))
        #expect(selection.columnSpan(on: 4, columns: 0..<40) == 3..<9)
        #expect(selection.columnSpan(on: 3, columns: 0..<40) == nil)
        #expect(selection.columnSpan(on: 5, columns: 0..<40) == nil)
    }

    @Test("An empty intersection is nil, never an empty range")
    func emptyIntersectionIsNil() {
        // A click with no drag: start == end, so no row carries a span.
        let click = ScreenSelection(anchor: ScreenCell(row: 2, column: 7), focus: ScreenCell(row: 2, column: 7))
        #expect(click.isEmpty)
        #expect(click.columnSpan(on: 2, columns: 0..<40) == nil)
        // A selection whose row band lies entirely left of the pane window.
        let offPane = ScreenSelection(anchor: ScreenCell(row: 0, column: 1), focus: ScreenCell(row: 0, column: 4))
        #expect(offPane.columnSpan(on: 0, columns: 25..<80) == nil)
        // A degenerate pane window selects nothing at all.
        #expect(click.columnSpan(on: 2, columns: 5..<5) == nil)
    }

    @Test("Pane clamping: a selection never reaches below the pane's first column")
    func paneClamping() {
        let selection = ScreenSelection(anchor: ScreenCell(row: 1, column: 5), focus: ScreenCell(row: 4, column: 60))
        let columns = 25..<80
        for row in 1...4 {
            guard let span = selection.columnSpan(on: row, columns: columns) else { continue }
            #expect(span.lowerBound >= 25, "row \(row) reached into the sidebar")
            #expect(span.upperBound <= 80)
        }
        // The anchor at column 5 is left of the pane, so the first row starts at the
        // pane edge rather than at the anchor.
        #expect(selection.columnSpan(on: 1, columns: columns) == 25..<80)
        #expect(selection.columnSpan(on: 4, columns: columns) == 25..<60)
    }

    @Test("ScreenCell orders in reading order, which is what makes the shape a stream")
    func cellOrdering() {
        #expect(ScreenCell(row: 1, column: 90) < ScreenCell(row: 2, column: 0))
        #expect(ScreenCell(row: 2, column: 3) < ScreenCell(row: 2, column: 4))
        #expect(!(ScreenCell(row: 2, column: 4) < ScreenCell(row: 2, column: 4)))
    }

    // MARK: Width invariance

    /// Rows that between them cover every way a highlight can go wrong: plain
    /// ASCII, a style that opens and closes, a row whose own reset lands inside a
    /// likely span, wide CJK, emoji (including a ZWJ family), a combining mark, and
    /// an OSC-8 hyperlink pair.
    private func styledRows(width: Int) -> [String] {
        let raw = [
            "let total = count + 1",
            "\(escape)[2mdimmed status line\(escape)[0m",
            "head \(escape)[0m reset in the middle \(escape)[0m tail",
            "漢字テスト の 行",
            "emoji ✅ 👩‍👩‍👧‍👦 tail",
            "e\u{0301}cole cafe\u{0301}",
            "\(escape)]8;;https://example.com\u{07}link text\(escape)]8;;\u{07} after",
            "",
            "   ",
        ]
        return raw.map { padToWidth($0, width) }
    }

    @Test("Highlighting preserves every row's exact visible width, for every span")
    func widthInvariance() {
        let width = 40
        for row in styledRows(width: width) {
            #expect(visibleWidth(row) == width, "fixture row is not exactly \(width) columns")
            for from in 0...width {
                for to in from...width {
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    #expect(
                        visibleWidth(decorated) == width,
                        "from \(from) to \(to) measured \(visibleWidth(decorated)) on \(String(reflecting: row))"
                    )
                }
            }
        }
    }

    @Test("A span that straddles a wide glyph blanks it rather than splitting it")
    func wideGlyphStraddle() {
        // `漢` occupies columns 2 and 3; a span ending at 3 cuts it in half.
        let row = padToWidth("ab漢cd", 10)
        let decorated = highlightColumns(row, from: 0, to: 3, width: 10)
        #expect(visibleWidth(decorated) == 10)
        #expect(!strippingANSI(decorated).contains("漢"), "a half-covered wide glyph must not survive")
        // The same straddle at the LEFT edge of the span.
        let leftStraddle = highlightColumns(row, from: 3, to: 10, width: 10)
        #expect(visibleWidth(leftStraddle) == 10)
        #expect(!strippingANSI(leftStraddle).contains("漢"))
    }

    @Test("A degenerate or inverted span returns the row untouched")
    func degenerateSpansAreInert() {
        let row = padToWidth("hello", 20)
        #expect(highlightColumns(row, from: 5, to: 5, width: 20) == row)
        #expect(highlightColumns(row, from: 9, to: 2, width: 20) == row)
        #expect(highlightColumns(row, from: 25, to: 30, width: 20) == row)
        #expect(highlightColumns(row, from: 0, to: 5, width: 0) == row)
    }

    // MARK: Highlight correctness

    @Test("The highlight opens reverse video before the span and closes it after")
    func highlightBrackets() {
        let row = padToWidth("abcdefgh", 12)
        let decorated = highlightColumns(row, from: 2, to: 5, width: 12)
        let open = try! #require(decorated.range(of: "\(escape)[7m"))
        let close = try! #require(decorated.range(of: "\(escape)[27m"))
        #expect(open.upperBound < close.lowerBound)
        let middle = String(decorated[open.upperBound..<close.lowerBound])
        #expect(middle == "cde")
    }

    @Test("A row whose own reset falls inside the span still highlights the WHOLE span")
    func resetInsideTheSpanDoesNotStripe() {
        // This is why the middle is re-emitted plain: an `ESC[0m` left in place would
        // cancel reverse video partway through and stripe the selection.
        let row = padToWidth("aa\(escape)[0mbb\(escape)[0mcc", 12)
        let decorated = highlightColumns(row, from: 0, to: 6, width: 12)
        let open = try! #require(decorated.range(of: "\(escape)[7m"))
        let close = try! #require(decorated.range(of: "\(escape)[27m"))
        let middle = String(decorated[open.upperBound..<close.lowerBound])
        #expect(middle == "aabbcc")
        #expect(!middle.contains(escape))
    }

    @Test("Styling that entered before the span is restored after it")
    func stylingSurvivesTheSpan() {
        let row = padToWidth("\(escape)[2mdim all the way across", 30)
        let decorated = highlightColumns(row, from: 4, to: 8, width: 30)
        let close = try! #require(decorated.range(of: "\(escape)[27m"))
        let tail = String(decorated[close.upperBound...])
        #expect(tail.contains("\(escape)[2m"), "the dim must be re-stated for the text after the selection")
    }

    @Test("Rows outside the selection come back byte-identical, so the diff stays incremental")
    func unselectedRowsAreUntouched() {
        let lines = (0..<8).map { padToWidth("row \($0) content", 30) }
        let selection = ScreenSelection(anchor: ScreenCell(row: 3, column: 2), focus: ScreenCell(row: 4, column: 6))
        let decorated = applySelectionHighlight(lines, selection: selection, columns: 0..<30, width: 30)
        #expect(decorated.count == lines.count)
        for row in 0..<8 where row < 3 || row > 4 {
            #expect(decorated[row] == lines[row], "row \(row) was repainted for nothing")
        }
        #expect(decorated[3] != lines[3])
        #expect(decorated[4] != lines[4])
        for row in decorated { #expect(visibleWidth(row) == 30) }
    }

    @Test("An empty selection decorates nothing, and out-of-frame rows are skipped")
    func emptySelectionAndOutOfFrameRows() {
        let lines = (0..<3).map { padToWidth("row \($0)", 20) }
        let empty = ScreenSelection(anchor: ScreenCell(row: 1, column: 4), focus: ScreenCell(row: 1, column: 4))
        #expect(applySelectionHighlight(lines, selection: empty, columns: 0..<20, width: 20) == lines)
        // A selection left over from a taller frame must not index out of bounds.
        let stale = ScreenSelection(anchor: ScreenCell(row: 1, column: 0), focus: ScreenCell(row: 40, column: 5))
        let decorated = applySelectionHighlight(lines, selection: stale, columns: 0..<20, width: 20)
        #expect(decorated.count == 3)
        #expect(selectionText(lines, selection: stale, columns: 0..<20).split(separator: "\n").count == 2)
    }

    @Test("An image row is returned untouched, because slicing its escape corrupts it")
    func imageRowsAreOpaque() {
        // The iTerm2 inline-image form `isImageLine` recognises.
        let imageRow = "\(escape)]1337;File=inline=1:AAAA\u{07}"
        #expect(highlightColumns(imageRow, from: 0, to: 10, width: 40) == imageRow)
    }

    // MARK: Plain-text extraction

    @Test("strippingANSI removes SGR, an OSC-8 hyperlink pair and the APC cursor marker")
    func strippingRemovesEveryEscapeForm() {
        let styled = "\(escape)[1;31mred\(escape)[0m plain"
        #expect(strippingANSI(styled) == "red plain")

        let linked = "\(escape)]8;;https://example.com\u{07}text\(escape)]8;;\u{07}"
        #expect(strippingANSI(linked) == "text")

        // APC (`ESC _ … BEL`) is how a focused component marks the caret.
        let marked = "before\(escape)_cursor\u{07}after"
        #expect(strippingANSI(marked) == "beforeafter")

        // No escape at all: returned as-is, and never `·`-substituted the way the
        // DISPLAY guard would.
        #expect(strippingANSI("plain text") == "plain text")
    }

    @Test("plainSliceByColumn agrees with the styled slicer on columns and never returns half a wide cluster")
    func plainSliceMatchesColumns() {
        let row = "ab漢字cd"
        #expect(plainSliceByColumn(row, from: 0, to: 2) == "ab")
        #expect(plainSliceByColumn(row, from: 2, to: 6) == "漢字")
        // A boundary through the middle of `漢` drops it entirely.
        #expect(plainSliceByColumn(row, from: 0, to: 3) == "ab")
        #expect(plainSliceByColumn(row, from: 3, to: 8) == "字cd")
        for from in 0...8 {
            for to in from...8 {
                #expect(visibleWidth(plainSliceByColumn(row, from: from, to: to)) <= to - from)
            }
        }
        #expect(plainSliceByColumn(row, from: 4, to: 4) == "")
    }

    @Test("A combining mark rides with the cell it decorates")
    func combiningMarksAreNotStranded() {
        // `e` + U+0301: one grapheme cluster in Swift, so it is one cell either way —
        // but a decomposed sequence that Swift did NOT merge must not be orphaned.
        let row = "cafe\u{0301} bar"
        #expect(plainSliceByColumn(row, from: 0, to: 4) == "café")
        #expect(plainSliceByColumn(row, from: 5, to: 8) == "bar")
    }

    @Test("selectionText trims each row's trailing pad and joins with newlines")
    func selectionTextTrimsPadding() {
        let lines = [
            padToWidth("first line", 60),
            padToWidth("second", 60),
            padToWidth("third line here", 60),
        ]
        let selection = ScreenSelection(anchor: ScreenCell(row: 0, column: 0), focus: ScreenCell(row: 2, column: 15))
        let text = selectionText(lines, selection: selection, columns: 0..<60)
        #expect(text == "first line\nsecond\nthird line here")
        #expect(!text.contains("  "), "padding must not reach the clipboard")
    }

    @Test("selectionText over styled rows yields text with no ESC at all")
    func selectionTextIsClipboardClean() {
        let lines = [
            padToWidth("\(escape)[2m$ git status\(escape)[0m", 40),
            padToWidth("\(escape)[32mnothing to commit\(escape)[0m", 40),
        ]
        let selection = ScreenSelection(anchor: ScreenCell(row: 0, column: 0), focus: ScreenCell(row: 1, column: 17))
        let text = selectionText(lines, selection: selection, columns: 0..<40)
        #expect(text == "$ git status\nnothing to commit")
        #expect(!text.contains(escape))
    }

    @Test("A stream selection copies the rest of the first row and the start of the last")
    func selectionTextIsStreamShaped() {
        let lines = [
            padToWidth("alpha beta gamma", 30),
            padToWidth("delta epsilon", 30),
            padToWidth("zeta eta theta", 30),
        ]
        let selection = ScreenSelection(anchor: ScreenCell(row: 0, column: 6), focus: ScreenCell(row: 2, column: 4))
        #expect(
            selectionText(lines, selection: selection, columns: 0..<30)
                == "beta gamma\ndelta epsilon\nzeta"
        )
    }

    @Test("An empty selection copies nothing")
    func emptySelectionCopiesNothing() {
        let lines = [padToWidth("content", 20)]
        let empty = ScreenSelection(anchor: ScreenCell(row: 0, column: 3), focus: ScreenCell(row: 0, column: 3))
        #expect(selectionText(lines, selection: empty, columns: 0..<20) == "")
    }

    // MARK: Word and line spans

    @Test("Double-click selects the word under the pointer, underscore included")
    func wordSpanCoversTheWholeIdentifier() {
        let line = "let foo_bar = 42"
        let span = try! #require(wordColumnSpan(in: line, atColumn: 6))
        #expect(span == 4..<11)
        #expect(plainSliceByColumn(line, from: span.lowerBound, to: span.upperBound) == "foo_bar")
        // Every column of the word resolves to the same span.
        for column in 4..<11 {
            #expect(wordColumnSpan(in: line, atColumn: column) == span)
        }
    }

    @Test("A click on whitespace selects the whitespace run, and on punctuation the punctuation run")
    func nonWordRuns() {
        let line = "a   ==>  b"
        let blanks = try! #require(wordColumnSpan(in: line, atColumn: 2))
        #expect(blanks == 1..<4)
        let punctuation = try! #require(wordColumnSpan(in: line, atColumn: 5))
        #expect(punctuation == 4..<7)
        #expect(plainSliceByColumn(line, from: punctuation.lowerBound, to: punctuation.upperBound) == "==>")
    }

    @Test("A click past the row's content selects nothing")
    func clickPastContentSelectsNothing() {
        #expect(wordColumnSpan(in: "short", atColumn: 40) == nil)
        #expect(wordColumnSpan(in: "", atColumn: 0) == nil)
        #expect(wordColumnSpan(in: "abc", atColumn: -1) == nil)
    }

    @Test("A CJK run is one word, and a latin-CJK transition is a boundary")
    func cjkRunIsOneWord() {
        let line = "abc漢字def"
        let cjk = try! #require(wordColumnSpan(in: line, atColumn: 4))
        // `漢字` occupies columns 3..<7 — two cells each.
        #expect(cjk == 3..<7)
        let latin = try! #require(wordColumnSpan(in: line, atColumn: 1))
        #expect(latin == 0..<3)
    }

    @Test("Word spans are computed over the plain text, so styling does not shift them")
    func wordSpansIgnoreEscapes() {
        let styled = "\(escape)[2mlet \(escape)[0mfoo_bar\(escape)[0m = 42"
        #expect(wordColumnSpan(in: styled, atColumn: 6) == 4..<11)
    }

    @Test("Triple-click takes the row's content and stops at the last non-blank column")
    func contentSpanDropsTrailingPadding() {
        let padded = padToWidth("  indented code", 60)
        #expect(contentColumnSpan(in: padded) == 0..<15)
        // Leading indentation is kept: a triple-clicked line of code that lost its
        // indentation would not paste back as the same code.
        #expect(plainSliceByColumn(padded, from: 0, to: 15) == "  indented code")
        // A styled row measures the same.
        #expect(contentColumnSpan(in: "\(escape)[2mhi\(escape)[0m" + String(repeating: " ", count: 40)) == 0..<2)
        // An entirely blank row selects nothing.
        #expect(contentColumnSpan(in: String(repeating: " ", count: 30)) == 0..<0)
        #expect(contentColumnSpan(in: "") == 0..<0)
    }
}
