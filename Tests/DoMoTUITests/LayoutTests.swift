// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import Testing

// Full-screen LAYOUT tests THROUGH the screen-state oracle. A `LayoutNode` tree
// is solved and flattened by `layoutBuffer`/`layoutLines`, painted by
// `AltScreenCore` into a `CaptureTarget`, and the bytes fed to a `ScreenOracle` —
// the exact 7a discipline, now proving the 2-D flex solver tiles a frame with no
// gap and no overrun. Public API only (no `@testable`): the layout types, the
// adapter, and the compose seam are all exercised as a caller would. Correctness
// is the emulator's CELL GRID (row, col -> grapheme), the strongest check; where
// a whole row is compared, trailing spaces are trimmed because the full frame
// blank-fills with REAL space cells.

// MARK: - Local helpers

/// A component that fills every column of its width with one character (one
/// line). The test stand-in for a solid region whose column boundaries the oracle
/// can read straight off the grid.
@MainActor
private final class Fill: Component {
    let ch: Character
    init(_ ch: Character) { self.ch = ch }
    func render(width: Int) -> [String] { [String(repeating: ch, count: max(0, width))] }
}

/// Enter/leave the alternate screen the way `TerminalLifecycle` does — feeding
/// the literal DEC sequences proves the oracle models the same switch.
private let altEnter = "\u{1b}[?1049h"

/// Drop trailing spaces from a row: the full-screen frame paints every cell, so a
/// short row lands as real space cells the emulator will not trim on its own.
private func trimmed(_ row: String) -> String {
    var s = row
    while s.last == " " { s.removeLast() }
    return s
}

@MainActor
@Suite("Full-screen flex layout — oracle-asserted rects")
struct LayoutTests {
    // (a) A Column of header Fixed(1) / transcript Flexible(1) / footer Fixed(1)
    //     into a 20x10 grid: header at row 0, footer at row 9, transcript rows 1..8.
    @Test("Column: header/transcript/footer tile a fixed height exactly")
    func columnHeaderTranscriptFooter() throws {
        let width = 20, height = 10
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let transcript = LinesComponent((1...8).map { "T\($0)" })
        let tree = Column([
            Fixed(.absolute(1), ComponentBox(Fill("H"))),
            Flexible(1, ComponentBox(transcript)),
            Fixed(.absolute(1), ComponentBox(Fill("F"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        // Header owns row 0 only; footer owns row 9 only.
        #expect(oracle.cell(col: 0, row: 0)?.character == "H")
        #expect(oracle.cell(col: 19, row: 0)?.character == "H")
        #expect(oracle.cell(col: 0, row: 9)?.character == "F")
        #expect(oracle.cell(col: 19, row: 9)?.character == "F")

        // Transcript fills rows 1..8, one distinct line each — the header did NOT
        // spill into row 1 and the footer did NOT spill into row 8.
        for i in 0..<8 {
            #expect(trimmed(oracle.row(i + 1)) == "T\(i + 1)")
        }
        #expect(oracle.cell(col: 0, row: 1)?.character == "T")
    }

    // (b) A Row of a Fixed(.absolute(20)) sidebar and a Flexible(1) main at width
    //     80: sidebar cols 0..19, main cols 20..79 — the two-pane primitive.
    @Test("Row: fixed sidebar beside a flexible main splits the width")
    func rowSidebarMain() throws {
        let width = 80, height = 5
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let tree = Row([
            Fixed(.absolute(20), ComponentBox(Fill("S"))),
            Flexible(1, ComponentBox(Fill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        #expect(oracle.cell(col: 0, row: 0)?.character == "S")
        #expect(oracle.cell(col: 19, row: 0)?.character == "S")   // sidebar last col
        #expect(oracle.cell(col: 20, row: 0)?.character == "M")   // main first col
        #expect(oracle.cell(col: 79, row: 0)?.character == "M")   // main last col
        // The boundary is exact: col 19 is the last 'S', col 20 the first 'M'.
        #expect(trimmed(oracle.row(0)) == String(repeating: "S", count: 20) + String(repeating: "M", count: 60))
    }

    // (b') The same two-pane split expressed as a PERCENT basis: Fixed(.percent(25))
    //      of 80 == 20, proving `SizeValue.percent` resolves against the main axis.
    @Test("Row: a percent sidebar resolves against the main-axis width")
    func rowPercentSidebar() throws {
        let width = 80, height = 3
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let tree = Row([
            Fixed(.percent(25), ComponentBox(Fill("S"))),
            Flexible(1, ComponentBox(Fill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        #expect(oracle.cell(col: 19, row: 0)?.character == "S")
        #expect(oracle.cell(col: 20, row: 0)?.character == "M")
        #expect(oracle.cell(col: 79, row: 0)?.character == "M")
    }

    // (c) Three Flexible(1) across width 80 split 27 / 27 / 26, summing to EXACTLY
    //     80 with no gap and no overrun; the boundaries land on the grid.
    @Test("Row: equal flexes distribute the rounding remainder deterministically")
    func rowFlexRemainder() throws {
        let width = 80, height = 2
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let tree = Row([
            Flexible(1, ComponentBox(Fill("A"))),
            Flexible(1, ComponentBox(Fill("B"))),
            Flexible(1, ComponentBox(Fill("C"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        // 27 / 27 / 26: A -> [0,26], B -> [27,53], C -> [54,79].
        #expect(oracle.cell(col: 0, row: 0)?.character == "A")
        #expect(oracle.cell(col: 26, row: 0)?.character == "A")
        #expect(oracle.cell(col: 27, row: 0)?.character == "B")
        #expect(oracle.cell(col: 53, row: 0)?.character == "B")
        #expect(oracle.cell(col: 54, row: 0)?.character == "C")
        #expect(oracle.cell(col: 79, row: 0)?.character == "C")
        // Exact sum: every one of the 80 columns is filled, no blank seam.
        #expect(trimmed(oracle.row(0)).count == 80)
    }

    // (d) A wide-grapheme (emoji, width 2) line placed in a width-3 region clips at
    //     the CLUSTER boundary — the second emoji is dropped whole, the vacated
    //     column padded — deterministically, with no half-character and no
    //     over-wide DoMoError from the frame's width invariant.
    @Test("ComponentBox: a wide cluster clips at its boundary, never split")
    func wideGraphemeClipsCleanly() throws {
        let width = 3, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        // Five width-2 emoji = 10 columns of content into a 3-column region.
        let emoji = LinesComponent(["🙂🙂🙂🙂🙂"])
        let tree = Column([Fixed(.absolute(1), ComponentBox(emoji))])
        // Must NOT throw: the clip keeps the row within the 3-column budget.
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        // The first emoji occupies cols 0..1 (wide cell + spacer); col 2 is the
        // single padding space — the second emoji, which would straddle col 2..3,
        // is dropped whole, not halved.
        #expect(oracle.cell(col: 0, row: 0)?.character == "🙂")
        #expect(oracle.cell(col: 0, row: 0)?.width == 2)
        #expect(oracle.cell(col: 2, row: 0)?.character == " ")
    }

    // (e) A widget producing FEWER lines than its rect blank-fills to the rect
    //     height; one producing MORE is clipped to the rect and never overflows
    //     into a sibling.
    @Test("ComponentBox: short widgets blank-fill, tall widgets clip to the rect")
    func blankFillAndClip() throws {
        let width = 10, height = 5
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        // Flexible region is 4 rows (5 - the 1-row footer). The transcript emits 6
        // lines: A..D fill rows 0..3, E and F are clipped and MUST NOT reach the
        // footer row.
        let tall = LinesComponent(["A", "B", "C", "D", "E", "F"])
        let tree = Column([
            Flexible(1, ComponentBox(tall)),
            Fixed(.absolute(1), ComponentBox(Fill("Z"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        #expect(trimmed(oracle.row(0)) == "A")
        #expect(trimmed(oracle.row(3)) == "D")
        #expect(oracle.cell(col: 0, row: 4)?.character == "Z")   // footer intact — no overflow

        // Short widget: one line into the same 4-row region blank-fills rows 1..3.
        let short = LinesComponent(["X"])
        let tree2 = Column([
            Flexible(1, ComponentBox(short)),
            Fixed(.absolute(1), ComponentBox(Fill("Z"))),
        ])
        try screen.paint(layoutBuffer(tree2, width: width, height: height), into: oracle)
        #expect(trimmed(oracle.row(0)) == "X")
        #expect(trimmed(oracle.row(1)) == "")   // blank-filled, not stale "B"
        #expect(trimmed(oracle.row(3)) == "")
        #expect(oracle.cell(col: 0, row: 4)?.character == "Z")
    }

    // (f) Re-solving the SAME tree at a new size repaints the new rects.
    @Test("Resize: re-solving at a new size yields new rects on the grid")
    func resizeReflows() throws {
        let tree = Column([
            Fixed(.absolute(1), ComponentBox(Fill("H"))),
            Flexible(1, ComponentBox(LinesComponent((1...8).map { "T\($0)" }))),
            Fixed(.absolute(1), ComponentBox(Fill("F"))),
        ])

        // First size: 20x10, footer at row 9.
        let oracle = ScreenOracle(rows: 10, cols: 20)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: 20, height: 10)
        try screen.paint(layoutBuffer(tree, width: 20, height: 10), into: oracle)
        #expect(oracle.cell(col: 0, row: 9)?.character == "F")
        #expect(trimmed(oracle.row(1)) == "T1")

        // Resize to 30x6: the alt core repaints; footer now at row 5, transcript
        // rows 1..4, and the header still at row 0. A fresh oracle models the new
        // terminal size.
        let oracle2 = ScreenOracle(rows: 6, cols: 30)
        oracle2.feed(altEnter)
        let screen2 = StaticAltScreen(width: 30, height: 6)
        try screen2.paint(layoutBuffer(tree, width: 30, height: 6), into: oracle2)
        #expect(oracle2.cell(col: 0, row: 0)?.character == "H")
        #expect(oracle2.cell(col: 29, row: 0)?.character == "H")   // header now 30 wide
        #expect(oracle2.cell(col: 0, row: 5)?.character == "F")    // footer moved up to row 5
        #expect(trimmed(oracle2.row(1)) == "T1")
        #expect(trimmed(oracle2.row(4)) == "T4")
    }

    // A direct compose-seam check: `layoutLines` yields exactly height rows of
    // exactly width columns, independent of the oracle.
    @Test("layoutLines flattens to exactly height x width")
    func layoutLinesShape() {
        let tree = Row([
            Fixed(.absolute(20), ComponentBox(Fill("S"))),
            Flexible(1, ComponentBox(Fill("M"))),
        ])
        let lines = layoutLines(tree, width: 80, height: 4)
        #expect(lines.count == 4)
        for line in lines {
            #expect(visibleWidth(line) == 80)
        }
    }
}
