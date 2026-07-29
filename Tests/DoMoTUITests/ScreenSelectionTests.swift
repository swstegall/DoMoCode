// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The selection model, asserted through the public API only — no `@testable`, so
// this suite builds and runs in release exactly as it does in debug.
//
// Three of these tests are load-bearing rather than descriptive:
//
//  * WIDTH INVARIANCE. `AltScreenCore.frame` throws on a row wider than the
//    terminal and the driver escalates that to ending the session, so a highlight
//    that added one column would hang up on the user the first time they dragged
//    across a CJK glyph. The property is swept over every (from, to) pair on a
//    table of styled, wide and zero-width rows, and again over a seeded corpus of
//    generated ones. Over-wide and under-wide are asserted SEPARATELY: only one of
//    them ends the session, and a shared failure message hides which happened.
//  * COLUMN POSITION. Width alone is too weak. The per-segment trailing padding
//    silently repairs a miscount into a row that is still exactly `width` columns
//    with every later column shifted one to the left, and a mutant that did
//    exactly that once passed every test in this file. So the reverse-video run is
//    measured against the span it claims to cover, and a table of rows asserts the
//    EXACT plain text a highlight produces, column for column.
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
    ///
    /// The last four rows carry a STANDALONE zero-width cluster — one Swift
    /// `Character` that measures zero columns and is not merged into a base. Swift
    /// only produces one at the start of a string or after a C0 control (grapheme
    /// break GB4), which is why every earlier fixture missed the class: writing
    /// `"e\u{0301}cole"` in source produces `é`, a single width-1 cluster, and never
    /// exercises a bare mark at a segment boundary at all.
    ///
    /// The tail of the table carries TAB and the emoji skin-tone modifier. Those two
    /// were absent for exactly one review cycle, and in that cycle a fix shipped that
    /// made rows over-wide — the failure this whole file exists to prevent — with
    /// every test still green. `cursorMarker` is `@MainActor`, which is why this and
    /// its callers are.
    @MainActor
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
            // A bare combining acute at the head of the row.
            "\u{0301}leading mark abc",
            // A bare ZWJ at the head of the row, and a wide glyph after it.
            "\u{200d}zwj 漢 tail",
            // A bare mark immediately after an OSC-8 close, i.e. after the BEL that
            // terminates it — the realistic way one appears mid-row.
            "\(escape)]8;;https://e.co\u{07}link\(escape)]8;;\u{07}\u{0301}after 漢",
            // U+2064 is a default-ignorable that is GCB=Control, so it stands alone
            // AFTER a printable base and breaks the cluster that follows it too.
            "a\u{2064}\u{0301}b wide 漢 ✅ end",
            // An emoji with a TRAILING ZWJ, separated from the next emoji only by an
            // escape. Suppressing that escape inside the span concatenates the two
            // and Swift re-segments them into ONE cluster worth two columns instead
            // of two clusters worth four.
            "✅\u{200d}\(escape)[31m✅ fuse",
            "👩‍👩‍👧‍👦\u{200d}\(escape)[2m👩‍👩‍👧‍👦 zwj",
            // TAB. `graphemeWidth` gives it three columns (pi's fixed `tabColumnWidth`),
            // so it is the cheapest way to make a cluster straddle BOTH span edges at
            // once, and it is a C0 control, so it leaves the cluster after it standing
            // alone where a printable base would have absorbed it.
            "col\tafter\ttab 漢",
            // A LONE emoji skin-tone modifier. U+1F3FB is grapheme-break class Extend
            // and measures TWO columns, so it fuses with the trailing `m` of any
            // escape this function inserts in front of it — including the `ESC[7m`
            // that exists to prevent exactly that. Nothing here may reason its way
            // around it; it has to be measured.
            "\u{1F3FB}orphan modifier abc",
            "a\t\u{1F3FB} tab then modifier",
            "\(escape)]8;;https://e.co\u{07}x\(escape)]8;;\u{07}\u{1F3FB}y modifier",
            // The APC caret marker mid-row, so the corpus exercises the one escape
            // that is CARRIED rather than replayed.
            "ab" + cursorMarker + "cd 漢 \u{1F3FB} tail",
        ]
        return raw.map { padToWidth($0, width) }
    }

    @Test("Highlighting preserves every row's exact visible width, for every span")
    @MainActor
    func widthInvariance() {
        let width = 40
        for row in styledRows(width: width) {
            #expect(visibleWidth(row) == width, "fixture row is not exactly \(width) columns")
            for from in 0...width {
                for to in from...width {
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    // Stated in BOTH directions on purpose. An over-wide row is a
                    // thrown `AltScreenCore.overWide` and an ended session; an
                    // under-wide one is stale glyphs at the right of the line. They
                    // are not the same bug and must not share one failure message.
                    #expect(
                        visibleWidth(decorated) <= width,
                        """
                        from \(from) to \(to) is OVER-WIDE at \(visibleWidth(decorated)) \
                        — this ends the session — on \(String(reflecting: row))
                        """
                    )
                    #expect(
                        visibleWidth(decorated) == width,
                        "from \(from) to \(to) measured \(visibleWidth(decorated)) on \(String(reflecting: row))"
                    )
                    guard to > from else { continue }
                    // The reverse-video run must measure the span EXACTLY. Total
                    // width alone does not say that: the per-segment trailing
                    // padding repairs a miscount into a row that is still `width`
                    // columns wide with the highlight boundary in the wrong place.
                    // Searching for `ESC[7m` also catches the merge case head-on —
                    // `String.range(of:)` is cluster-aware, so an opener whose `m`
                    // has been absorbed by a following combining mark is simply not
                    // found.
                    let run = reverseVideoRun(of: decorated)
                    #expect(run != nil, "from \(from) to \(to) lost its reverse-video brackets")
                    #expect(
                        visibleWidth(run ?? "") == to - from,
                        "from \(from) to \(to) highlighted \(visibleWidth(run ?? "")) columns on \(String(reflecting: row))"
                    )
                }
            }
        }
    }

    /// A deterministic xorshift, so a corpus failure is a reproducible bug report
    /// rather than a flake somebody reruns until it goes away.
    private struct SeededRandom {
        private var state: UInt64 = 0x2545_F491_4F6C_DD1D

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
    }

    /// Rows whose OWN escapes are already broken are not this function's problem.
    ///
    /// An ASCII scalar that has absorbed a following combining scalar is precisely
    /// what TextWidth.swift documents as impossible ("ESC never joins a following
    /// scalar"), and such a row is mismeasured before `highlightColumns` ever sees
    /// it — the renderer paints it wrong with or without a selection.
    private func rowIsWellFormed(_ row: String) -> Bool {
        !row.contains { character in
            character.unicodeScalars.count > 1 && (character.unicodeScalars.first?.isASCII ?? false)
        }
    }

    /// `count` generated rows of exactly `width` columns, each a concatenation of
    /// `atoms`, padded and filtered.
    private func generatedRows(atoms: [String], width: Int, attempts: Int) -> [String] {
        var random = SeededRandom()
        var rows: [String] = []
        for _ in 0..<attempts {
            var raw = ""
            for _ in 0..<(Int(random.next() % 8) + 1) { raw += random.pick(atoms) }
            let row = padToWidth(raw, width)
            guard visibleWidth(row) == width, rowIsWellFormed(row) else { continue }
            rows.append(row)
        }
        return rows
    }

    @Test("Width invariance holds over a generated corpus of adversarial rows")
    @MainActor
    func widthInvarianceOverGeneratedRows() {
        // The hand-written fixtures above are a table of cases someone thought of.
        // This is the same property over rows assembled from the pieces that break
        // it — bare marks, ZWJ, default-ignorables, wide glyphs, TAB, emoji skin-tone
        // modifiers, every escape form, and raw controls — in every order, from a
        // FIXED seed so a failure is reproducible rather than a flake.
        //
        // `\t` and `\u{1F3FB}` are load-bearing entries, not decoration. Without them
        // this corpus passed on an implementation that made 59 of 408,000 sampled
        // rows OVER-wide; with them it fails on that implementation in the first few
        // hundred rows.
        let atoms = [
            "a", "b", " ", "漢", "✅", "👩‍👩‍👧‍👦", "\u{0301}", "\u{200d}", "\u{2064}",
            "\(escape)[0m", "\(escape)[2m", "\(escape)[31m", "\(escape)]8;;u\u{07}",
            "\(escape)]8;;\u{07}", "\u{07}", "\(escape)[K", escape,
            "\t", "\u{1F3FB}", "\u{1F3FF}", "😀", cursorMarker,
        ]
        let width = 12
        let rows = generatedRows(atoms: atoms, width: width, attempts: 700)
        for row in rows {
            for from in 0...width {
                for to in from...width {
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    let measured = visibleWidth(decorated)
                    // Split in two so the log names the failure. Over-wide is the
                    // one that ends the session.
                    #expect(
                        measured <= width,
                        """
                        from \(from) to \(to) is OVER-WIDE at \(measured) — this ends the session — \
                        on \(String(reflecting: row))
                        """
                    )
                    #expect(
                        measured >= width,
                        "from \(from) to \(to) is UNDER-wide at \(measured) on \(String(reflecting: row))"
                    )
                }
            }
        }
        #expect(rows.count > 150, "the corpus filtered itself away: only \(rows.count) rows survived")
    }

    @Test("Differential fuzz: every generated row keeps its width and its span boundaries")
    @MainActor
    func differentialFuzzAgainstTheWidthInvariant() {
        // The corpus above sweeps the WIDTH of the whole row. Total width alone is
        // too weak on its own: the per-segment trailing padding repairs a miscount
        // into a row that is still exactly `width` columns with every later column
        // shifted one to the left, and a mutant that did precisely that passed every
        // test in this file. So this sweep also pins the two span boundaries by
        // measuring the reverse-video run, which is the text between the columns
        // `from` and `to` and nothing else.
        //
        // The atoms deliberately INCLUDE the ill-formed ones — a bare `ESC`, and the
        // `[`, `]`, `_`, `3` and `m` that turn one into a LATENT escape the scanner
        // cannot resolve until some later byte completes it. An earlier version of
        // this corpus excluded them and asserted, unconditionally, that the fallback
        // never fires and the brackets are always present. Both claims were true only
        // because the assembler was free to drop the brackets themselves — that is,
        // the corpus was chosen to avoid the inputs on which the assertions were
        // false, and a highlight that opened reverse video and never closed it
        // shipped underneath them.
        //
        // So the assertion is the honest one: EITHER the row comes back untouched —
        // the assembler could not place a piece and said so — OR both brackets are
        // present, in order, with exactly `to - from` columns between them. Never an
        // opener without a closer, and never a row that silently lost its highlight
        // while measuring perfectly.
        let atoms = [
            "a", "b", "z", " ", "漢", "字", "✅", "😀", "👩‍👩‍👧‍👦", "\t",
            "\u{0301}", "\u{200d}", "\u{2064}",
            "\(escape)[0m", "\(escape)[2m", "\(escape)[31m", "\(escape)[K",
            "\(escape)]8;;u\u{07}", "\(escape)]8;;\u{07}", cursorMarker,
            escape, "[", "3", "]", "_", "m",
        ]
        let width = 14
        let rows = generatedRows(atoms: atoms, width: width, attempts: 500)
        var samples = 0
        var highlighted = 0
        for row in rows {
            for from in 0..<width {
                for to in (from + 1)...width {
                    samples += 1
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    #expect(
                        visibleWidth(decorated) == width,
                        "from \(from) to \(to) measured \(visibleWidth(decorated)) on \(String(reflecting: row))"
                    )
                    // The untouched row is the one permitted way out, and it is
                    // self-announcing: byte-identical means no bracket was written at
                    // all, so there is nothing to leak.
                    if decorated == row { continue }
                    highlighted += 1
                    let run = reverseVideoRun(of: decorated)
                    #expect(
                        run != nil,
                        """
                        from \(from) to \(to) produced a row with an unmatched reverse-video \
                        bracket on \(String(reflecting: row)): \(String(reflecting: decorated))
                        """
                    )
                    #expect(
                        visibleWidth(run ?? "") == to - from,
                        """
                        from \(from) to \(to) highlighted \(visibleWidth(run ?? "")) columns \
                        on \(String(reflecting: row))
                        """
                    )
                }
            }
        }
        #expect(samples > 20_000, "the differential sweep shrank to \(samples) samples")
        // The escape hatch must stay an escape hatch. Without this, an implementation
        // that returned `line` for every row would satisfy every expectation above.
        #expect(
            highlighted > samples / 2,
            "only \(highlighted) of \(samples) samples were highlighted at all — the fallback is not an exception"
        )
    }

    @Test("A WELL-FORMED row is always highlighted, never handed back untouched")
    @MainActor
    func wellFormedRowsAreAlwaysHighlighted() {
        // The companion sweep above admits ill-formed atoms, so its assertion has to
        // permit the untouched-row fallback. That permission is load-bearing there and
        // a hole here: an implementation that silently declined to highlight some
        // recognisable class of row satisfies it completely. A mutant returning `line`
        // for every row carrying an OSC-8 hyperlink passed that sweep — and hyperlink
        // rows are ordinary output, emitted by `Markdown` and by `segmentReset` itself.
        //
        // So this corpus is deliberately WELL-FORMED — every escape is complete and
        // resolvable — and the assertion is unconditional: a row like this is ALWAYS
        // highlighted, with both brackets, spanning exactly the requested columns. The
        // fallback is permitted only where the input gave it no choice.
        let atoms = [
            "a", "b", "z", " ", "漢", "字", "✅", "😀", "👩‍👩‍👧‍👦", "\t",
            "\u{0301}", "\u{200d}", "\u{2064}",
            "\(escape)[0m", "\(escape)[2m", "\(escape)[31m", "\(escape)[K",
            "\(escape)]8;;u\u{07}", "\(escape)]8;;\u{07}", cursorMarker,
        ]
        let width = 14
        let rows = generatedRows(atoms: atoms, width: width, attempts: 500)
        var samples = 0
        for row in rows {
            for from in 0..<width {
                for to in (from + 1)...width {
                    samples += 1
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    #expect(
                        visibleWidth(decorated) == width,
                        "from \(from) to \(to) measured \(visibleWidth(decorated)) on \(String(reflecting: row))"
                    )
                    #expect(
                        decorated != row,
                        """
                        from \(from) to \(to) fell back to the untouched row on a WELL-FORMED \
                        input: \(String(reflecting: row))
                        """
                    )
                    let run = reverseVideoRun(of: decorated)
                    #expect(
                        run != nil,
                        """
                        from \(from) to \(to) produced an unmatched reverse-video bracket on \
                        \(String(reflecting: row)): \(String(reflecting: decorated))
                        """
                    )
                    #expect(
                        visibleWidth(run ?? "") == to - from,
                        """
                        from \(from) to \(to) highlighted \(visibleWidth(run ?? "")) columns \
                        on \(String(reflecting: row))
                        """
                    )
                }
            }
        }
        #expect(samples > 20_000, "the well-formed sweep shrank to \(samples) samples")
    }

    @Test("A latent escape never leaves reverse video opened and never closed")
    func latentEscapeNeverHalfOpensTheHighlight() {
        // `ansiEscapeLength`'s CSI final-byte set is `m G K H J`, so `ESC[3` is not an
        // escape yet: it stays LATENT in the row and measures zero columns, one
        // control plus four printable characters. Appending `selectionClose` supplies
        // the `m` that completes it — the scanner then swallows `ESC[3xy…ESC[27m` as
        // ONE escape, so the closing bracket measures as REMOVING four columns from
        // the row rather than adding none.
        //
        // The closer owes no columns and cannot take a grapheme break, so a repair
        // ladder that ends in "drop any piece that owes nothing" dropped it: a row of
        // exactly the right width, with reverse video opened and never closed, and a
        // highlight that runs to the right edge instead of stopping where the user
        // released the drag. Dropping BOTH brackets is the same bug one step further
        // on — a row that reports success and carries no highlight.
        //
        // These rows are pathological and losing the highlight on them is acceptable;
        // emitting half of it is not.
        let width = 12
        let rows = [
            padToWidth("\(escape)[3xy", width),
            padToWidth("\(escape)[ab", width),
            padToWidth("ab\(escape)[3cd", width),
            padToWidth("\(escape)[3\(escape)[K", width),
            padToWidth("a\(escape)]8;;x", width),
            padToWidth("a\(escape)_b", width),
            padToWidth("ab\(escape)[", width),
            padToWidth("\(escape)\(escape)[2", width),
        ]
        for row in rows {
            #expect(visibleWidth(row) == width, "fixture \(String(reflecting: row)) is not \(width) columns")
            for from in 0..<width {
                for to in (from + 1)...width {
                    let decorated = highlightColumns(row, from: from, to: to, width: width)
                    #expect(
                        visibleWidth(decorated) == width,
                        "from \(from) to \(to) measured \(visibleWidth(decorated)) on \(String(reflecting: row))"
                    )
                    if decorated == row { continue }
                    let run = reverseVideoRun(of: decorated)
                    #expect(
                        run != nil,
                        """
                        from \(from) to \(to) on \(String(reflecting: row)) emitted an unmatched \
                        bracket: \(String(reflecting: decorated))
                        """
                    )
                    #expect(
                        visibleWidth(run ?? "") == to - from,
                        """
                        from \(from) to \(to) on \(String(reflecting: row)) highlighted \
                        \(visibleWidth(run ?? "")) columns
                        """
                    )
                }
            }
        }
        // The exact repro, spelled out, so a regression names itself.
        let repro = padToWidth("\(escape)[3xy", width)
        let decorated = highlightColumns(repro, from: 0, to: 4, width: width)
        #expect(
            decorated == repro || decorated.contains("\(escape)[27m"),
            "the highlight opened without closing: \(String(reflecting: decorated))"
        )
    }

    @Test("The plain text of a highlighted row keeps every column exactly where it was")
    @MainActor
    func plainTextKeepsEveryColumnWhereItWas() {
        // Width invariance is necessary and not sufficient: a highlight can hold the
        // total and still slide every column after the span one place to the left.
        // These are hand-computed, column by column, over exactly the atoms that make
        // the width invariance hard — TAB, an emoji skin-tone modifier, ZWJ
        // sequences, U+2064, an OSC-8 hyperlink pair, the APC caret marker, an SGR
        // run and wide CJK.
        //
        // `plain` is the whole row with escapes removed; `run` is the text the
        // terminal paints in reverse video, which is where the span boundaries show.
        let tabRow = padToWidth("ab\tcd", 16)
        let modifierRow = padToWidth("\u{1F3FB}abc", 16)
        let ignorableRow = padToWidth("a\u{2064}\u{0301}b漢✅", 16)
        let linkRow = padToWidth("\(escape)]8;;https://e.co\u{07}link\(escape)]8;;\u{07} zz", 16)
        let caretRow = padToWidth("ab" + cursorMarker + "cd", 16)
        let sgrRow = padToWidth("\(escape)[31mred\(escape)[0m plain", 16)
        let cjkRow = padToWidth("漢字テスト", 16)
        let zwjRow = padToWidth("👩‍👩‍👧‍👦\u{200d}\(escape)[2m👩‍👩‍👧‍👦 z", 16)

        let cases: [(row: String, from: Int, to: Int, plain: String, run: String)] = [
            // TAB is three columns, so a span ending at 4 cuts it: columns 2 and 3
            // are blanked inside the highlight and column 4 outside it, and `cd`
            // stays at columns 5 and 6 where it started.
            (tabRow, 0, 4, "ab   cd         ", "ab  "),
            // A span clear of the tab leaves the tab itself in the row — the
            // character, not three spaces, so the clipboard still sees a tab.
            (tabRow, 5, 7, "ab\tcd         ", "cd"),
            // A span that lands exactly on the tab's own columns keeps it whole.
            (tabRow, 2, 5, "ab\tcd         ", "\t"),
            // An orphan skin-tone modifier fuses with the `m` of the inserted
            // `ESC[7m` — and with the `m` of a second `ESC[7m` inserted to break it —
            // so it is blanked. Two columns in, two columns out, `abc` unmoved.
            (modifierRow, 0, 2, "  abc           ", "  "),
            (modifierRow, 0, 5, "  abc           ", "  abc"),
            // U+2064 and the bare combining acute both SURVIVE: they cost no columns
            // and they do not fuse with the escape in front of them, so nothing is
            // gained by dropping them. `漢` straddles column 3 and is blanked.
            (ignorableRow, 0, 3, "a\u{2064}\u{0301}b  ✅          ", "a\u{2064}\u{0301}b "),
            (ignorableRow, 1, 4, "a\u{2064}\u{0301}b漢✅          ", "\u{2064}\u{0301}b漢"),
            (linkRow, 1, 5, "link zz         ", "ink "),
            // The caret marker rides inside the span, still between `b` and `c`.
            (caretRow, 1, 4, "abcd            ", "b" + cursorMarker + "cd"),
            (sgrRow, 2, 8, "red plain       ", "d plai"),
            // `漢` straddles the left edge: column 0 is blanked outside the highlight
            // and column 1 inside it, and `字テスト` never moves.
            (cjkRow, 1, 6, "  字テスト      ", " 字テ"),
            // The trailing ZWJ on the first family would fuse it with the second the
            // moment the SGR between them is suppressed; the inserted break keeps
            // them two clusters and eight columns.
            (zwjRow, 0, 8, "👩‍👩‍👧‍👦\u{200d}👩‍👩‍👧‍👦 z          ", "👩‍👩‍👧‍👦\u{200d}\(escape)[7m👩‍👩‍👧‍👦 z  "),
        ]

        for (row, from, to, plain, run) in cases {
            #expect(visibleWidth(row) == 16, "fixture \(String(reflecting: row)) is not 16 columns")
            let decorated = highlightColumns(row, from: from, to: to, width: 16)
            #expect(visibleWidth(decorated) == 16, "from \(from) to \(to) on \(String(reflecting: row))")
            #expect(
                strippingANSI(decorated) == plain,
                """
                from \(from) to \(to) on \(String(reflecting: row)) gave \
                \(String(reflecting: strippingANSI(decorated)))
                """
            )
            #expect(
                reverseVideoRun(of: decorated) == run,
                """
                from \(from) to \(to) on \(String(reflecting: row)) highlighted \
                \(String(reflecting: reverseVideoRun(of: decorated) ?? "nil"))
                """
            )
            #expect(visibleWidth(run) == to - from, "the fixture's own run is not \(to - from) columns")
        }
    }

    @Test("Suppressing the span's own escapes must not fuse two emoji into one cluster")
    func spanDoesNotFuseAdjacentClusters() {
        // `✅` + ZWJ and `✅` are two clusters worth four columns while the SGR
        // stands between them, and ONE cluster worth two the moment the span drops
        // that SGR — so the row loses two columns and paints stale glyphs at its
        // right edge.
        let row = padToWidth("✅\u{200d}\(escape)[31m✅ tail", 16)
        #expect(visibleWidth(row) == 16)
        for from in 0...16 {
            for to in from...16 {
                let decorated = highlightColumns(row, from: from, to: to, width: 16)
                #expect(visibleWidth(decorated) == 16, "from \(from) to \(to) measured \(visibleWidth(decorated))")
            }
        }
        // Both emoji are still inside the highlight, still four columns of it.
        let whole = highlightColumns(row, from: 0, to: 16, width: 16)
        #expect(visibleWidth(reverseVideoRun(of: whole) ?? "") == 16)
        #expect(whole.contains("✅"), "the emoji themselves must survive")
    }

    @Test("A span that straddles a wide glyph blanks it rather than splitting it")
    func wideGlyphStraddle() {
        // `漢` occupies columns 2 and 3; a span ending at 3 cuts it in half.
        let row = padToWidth("ab漢cd", 10)
        let decorated = highlightColumns(row, from: 0, to: 3, width: 10)
        #expect(visibleWidth(decorated) == 10)
        #expect(!strippingANSI(decorated).contains("漢"), "a half-covered wide glyph must not survive")
        // Width alone does not pin the blank's POSITION: the per-segment trailing
        // padding repairs any miscount inside the straddle loop into a row that is
        // still exactly `width` columns but has every later column shifted. Assert
        // the exact plain text so a miscount is a failure rather than a silent
        // one-column slide of `cd`.
        #expect(strippingANSI(decorated) == "ab  cd    ")
        // The same straddle at the LEFT edge of the span.
        let leftStraddle = highlightColumns(row, from: 3, to: 10, width: 10)
        #expect(visibleWidth(leftStraddle) == 10)
        #expect(!strippingANSI(leftStraddle).contains("漢"))
        #expect(strippingANSI(leftStraddle) == "ab  cd    ")
        // Each blank lands in the segment that owns its column: the span 0..<3 keeps
        // the first blank inside the reverse-video run and pushes the second into the
        // tail, and the span 3..<10 does the exact opposite.
        #expect(reverseVideoRun(of: decorated) == "ab ")
        #expect(reverseVideoRun(of: leftStraddle) == " cd    ")
    }

    /// The text between `ESC[7m` and `ESC[27m` — the run the terminal actually
    /// paints in reverse video.
    ///
    /// `nil` means the row carries no complete, correctly ordered bracket pair, which
    /// is exactly the failure the callers assert against: an opener with no closer
    /// leaks reverse video down the rest of the line. The ordering guard is not
    /// decorative — a row that lost its opener but kept its closer would otherwise
    /// build a reversed `Range` and trap.
    private func reverseVideoRun(of decorated: String) -> String? {
        guard let open = decorated.range(of: "\(escape)[7m"),
            let close = decorated.range(of: "\(escape)[27m"),
            open.upperBound <= close.lowerBound
        else { return nil }
        return String(decorated[open.upperBound..<close.lowerBound])
    }

    @Test("A standalone zero-width cluster at a span boundary does not eat the row's width")
    func zeroWidthClusterAtASpanBoundary() {
        // A combining acute with no base in front of it is its own grapheme cluster.
        // Spliced straight after `ESC[7m` it MERGES with that `m`, the escape scanner
        // stops recognising the sequence, and the row silently measures short —
        // stale glyphs left at the right of the line, and, when the tail carries no
        // further CSI final byte, an OVER-wide row, which `AltScreenCore.frame`
        // throws on and the driver escalates to ending the session.
        let row = padToWidth("\u{0301}abc", 12)
        #expect(visibleWidth(row) == 12)
        let decorated = highlightColumns(row, from: 0, to: 4, width: 12)
        #expect(visibleWidth(decorated) == 12, "measured \(visibleWidth(decorated))")
        // The mark decorated nothing, so it is dropped rather than relocated: the
        // visible text is unchanged and every column keeps its place.
        #expect(strippingANSI(decorated) == "abc" + String(repeating: " ", count: 9))
        #expect(reverseVideoRun(of: decorated) == "abc ")

        // The same cluster at the head of the TAIL, after `ESC[27mESC[0m`. Here the
        // merge can leave the trailing `ESC[0` with no final byte at all, so the
        // scanner gives up and counts `[0` + the merged cluster as TEXT — a row wider
        // than the page.
        let tailRow = padToWidth("ab\(escape)]8;;u\u{07}\u{0301}cd", 12)
        #expect(visibleWidth(tailRow) == 12)
        for from in 0...12 {
            for to in from...12 {
                let out = highlightColumns(tailRow, from: from, to: to, width: 12)
                #expect(visibleWidth(out) == 12, "from \(from) to \(to) measured \(visibleWidth(out))")
            }
        }
    }

    // `cursorMarker` infers `@MainActor` from DoMoTUI's default isolation, so the
    // one test that drives the REAL constant — and thereby pins the `nonisolated`
    // copy `highlightColumns` has to keep — hops onto the main actor to read it.
    @Test("The hardware-cursor marker survives exactly once, at the column it marked")
    @MainActor
    func cursorMarkerIsNeitherDuplicatedNorMovedNorLost() {
        // `cursorMarker` is an APC POSITION marker, not a style: `AltScreenCore`
        // strips the FIRST one it finds and parks the real cursor at its column. A
        // second copy therefore reaches the terminal as raw bytes, a moved copy parks
        // the caret at the wrong column, and a dropped copy leaves it wherever the
        // previous frame put it.
        let row = padToWidth("ab" + cursorMarker + "cd", 20)
        #expect(visibleWidth(row) == 20)
        // Marker before the span, inside it, at the head of it, and with the span
        // running to the page edge (which is where the carried styles are dropped).
        for (from, to) in [(5, 10), (0, 10), (0, 20), (2, 20), (0, 2), (1, 3)] {
            let decorated = highlightColumns(row, from: from, to: to, width: 20)
            #expect(
                occurrences(of: cursorMarker, in: decorated) == 1,
                "span \(from)..<\(to) left \(occurrences(of: cursorMarker, in: decorated)) markers"
            )
            if let marker = decorated.range(of: cursorMarker) {
                #expect(
                    visibleWidth(String(decorated[decorated.startIndex..<marker.lowerBound])) == 2,
                    "span \(from)..<\(to) moved the caret off column 2"
                )
            }
            #expect(visibleWidth(decorated) == 20)
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchFrom = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            count += 1
            searchFrom = found.upperBound
        }
        return count
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
