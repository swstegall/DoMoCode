// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

// These fixtures prove the oracle itself before it is trusted to judge a
// renderer: feed known ANSI, assert the cell grid matches what a real terminal
// would show. If the oracle is wrong, every renderer test built on it is wrong.
@Suite("ScreenOracle correctness")
struct ScreenOracleTests {
    @Test("Plain text lands in the top-left cells")
    func plainText() {
        let screen = ScreenOracle(rows: 4, cols: 20)
        screen.feed("hello")
        #expect(screen.row(0) == "hello")
        #expect(screen.cell(col: 0, row: 0)?.character == "h")
        #expect(screen.cell(col: 4, row: 0)?.character == "o")
        // The cursor sits just past the written text.
        #expect(screen.cursor == (5, 0))
    }

    @Test("CR/LF and relative motion place text on the right rows")
    func crlfAndRows() {
        let screen = ScreenOracle(rows: 4, cols: 20)
        screen.feed("line1\r\nline2")
        #expect(screen.row(0) == "line1")
        #expect(screen.row(1) == "line2")
        #expect(screen.cursor == (5, 1))
    }

    @Test("Cursor addressing then overwrite replaces the earlier cell")
    func cursorMoveAndOverwrite() {
        let screen = ScreenOracle(rows: 4, cols: 20)
        screen.feed("XXXXX")
        // CSI H is 1-based: row 1, col 3 -> overwrite the third X.
        screen.feed("\u{1b}[1;3HY")
        #expect(screen.row(0) == "XXYXX")
    }

    @Test("A relative cursor-up move lands on the prior line")
    func relativeCursorUp() {
        let screen = ScreenOracle(rows: 4, cols: 20)
        screen.feed("aaa\r\nbbb")
        // Up one, carriage return, overwrite: change row 0 without touching row 1.
        screen.feed("\u{1b}[A\rZ")
        #expect(screen.row(0) == "Zaa")
        #expect(screen.row(1) == "bbb")
    }

    @Test("SGR colour sets the cell attribute, and reset clears it")
    func sgrColorAndReset() {
        let screen = ScreenOracle(rows: 2, cols: 20)
        screen.feed("\u{1b}[31;1mR\u{1b}[0mN")
        let red = try! #require(screen.cell(col: 0, row: 0))
        #expect(red.character == "R")
        #expect(red.style.foreground == .ansi(1))
        #expect(red.style.bold)

        let normal = try! #require(screen.cell(col: 1, row: 0))
        #expect(normal.character == "N")
        #expect(normal.style.foreground == .default)
        #expect(!normal.style.bold)
    }

    @Test("A wide CJK glyph occupies two cells")
    func wideCharTwoCells() {
        let screen = ScreenOracle(rows: 2, cols: 20)
        screen.feed("A你B")
        #expect(screen.cell(col: 0, row: 0)?.character == "A")
        let wide = try! #require(screen.cell(col: 1, row: 0))
        #expect(wide.character == "你")
        #expect(wide.width == 2)
        // The next real glyph is two columns over, not one.
        #expect(screen.cell(col: 3, row: 0)?.character == "B")
    }

    @Test("A line longer than the width wraps onto the next row")
    func lineWrap() {
        let screen = ScreenOracle(rows: 4, cols: 5)
        screen.feed("abcdefg")  // 7 chars into a 5-wide screen
        #expect(screen.row(0) == "abcde")
        #expect(screen.row(1) == "fg")
        #expect(screen.cursor == (2, 1))
    }

    @Test("Content past the viewport scrolls into scrollback, not clobbered")
    func scrolledTranscript() {
        // Four-row viewport; feed six numbered lines. Two must scroll off the top.
        let screen = ScreenOracle(rows: 4, cols: 20)
        screen.feed("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6")

        // The viewport shows the last four lines — the emulator scrolled.
        #expect(screen.screen == ["L3", "L4", "L5", "L6"])
        #expect(screen.cursor == (2, 3))

        // The scrolled-off lines are preserved in the transcript, in order. This
        // is the assertion a byte-recording harness cannot make: it is the
        // terminal's *reaction* — scroll vs. clamp-and-overwrite — under test.
        #expect(screen.transcriptTrimmed == ["L1", "L2", "L3", "L4", "L5", "L6"])
    }

    @Test("An explicit line feed at the bottom margin scrolls rather than clamps")
    func lineFeedAtBottomScrolls() {
        let screen = ScreenOracle(rows: 3, cols: 20)
        screen.feed("top\r\nmid\r\nbot")
        #expect(screen.screen == ["top", "mid", "bot"])
        // Cursor is on the last row; a newline here must scroll the whole screen
        // up and reveal a fresh bottom line — the exact motion a buggy renderer
        // clamps instead, overwriting "bot".
        screen.feed("\r\nnew")
        #expect(screen.screen == ["mid", "bot", "new"])
        #expect(screen.transcriptTrimmed == ["top", "mid", "bot", "new"])
    }
}
