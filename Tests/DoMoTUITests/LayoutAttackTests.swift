// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// ADVERSARIAL attack suite for Phase 7b. Every test asserts the SwiftTerm cell grid (row,col -> grapheme/style)
// after the tree is solved, flattened, and painted through AltScreenCore, exactly
// like LayoutTests. The goal is to break the flex solver, the ComponentBox
// clip/pad, and the compose seam at the edges LayoutTests does not visit.

import DoMoCore
import DoMoTUI
import Testing

@MainActor
private final class AFill: Component {
    let ch: Character
    init(_ ch: Character) { self.ch = ch }
    func render(width: Int) -> [String] { [String(repeating: ch, count: max(0, width))] }
}

/// A component whose single line is `count` copies of `ch` prefixed with a
/// red-BACKGROUND SGR and NO trailing reset — the worst case for style bleed. The
/// background makes padding/bleed visible on the oracle's per-cell style.
@MainActor
private final class BgFill: Component {
    let ch: Character
    let count: Int
    init(_ ch: Character, count: Int) { self.ch = ch; self.count = count }
    func render(width: Int) -> [String] { ["\u{1b}[41m" + String(repeating: ch, count: count)] }
}

private let altEnter = "\u{1b}[?1049h"

private func trimmed(_ row: String) -> String {
    var s = row
    while s.last == " " { s.removeLast() }
    return s
}

@MainActor
@Suite("Phase 7b adversarial — flex/clip/nesting/style at the edges")
struct LayoutAttackTests {

    // (1) Flex rounding at awkward widths: the columns must sum EXACTLY to the
    //     container width with a deterministic split, for widths where the
    //     remainder does not divide evenly.
    @Test("Flex remainder sums exactly at awkward widths and weights")
    func flexRemainderExact() throws {
        // 7 equal flexes at 100: floor(100/7)=14, remainder 2 -> 15,15,14,14,14,14,14.
        try assertFlexTiling(weights: [1,1,1,1,1,1,1], width: 100,
                             expected: [15,15,14,14,14,14,14])
        // 3 equal flexes across several awkward widths.
        try assertFlexTiling(weights: [1,1,1], width: 80, expected: [27,27,26])
        try assertFlexTiling(weights: [1,1,1], width: 81, expected: [27,27,27])
        try assertFlexTiling(weights: [1,1,1], width: 82, expected: [28,27,27])
        try assertFlexTiling(weights: [1,1,1], width: 100, expected: [34,33,33])
        // Weighted: 2:1 at 80 -> floor 53/26, remainder 1 -> weight-2 gets it -> 54,26.
        try assertFlexTiling(weights: [2,1], width: 80, expected: [54,26])
        // Weighted 3:2:1 at 101 -> shares floor(101*{3,2,1}/6)= 50,33,16 =99; rem 2
        // to first two in order -> 51,34,16.
        try assertFlexTiling(weights: [3,2,1], width: 101, expected: [51,34,16])
    }

    /// Build a Row of Flexible(weight) AFill cells at `width`, paint, and assert
    /// each cell owns exactly its expected column span with no gap/overrun.
    private func assertFlexTiling(weights: [Int], width: Int, expected: [Int]) throws {
        #expect(expected.reduce(0, +) == width, "test oracle wrong: expected sizes must sum to width")
        let letters = "ABCDEFGHIJ"
        let oracle = ScreenOracle(rows: 1, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: 1)
        let children: [any LayoutNode] = weights.enumerated().map { i, w in
            Flexible(w, ComponentBox(AFill(letters[letters.index(letters.startIndex, offsetBy: i)])))
        }
        try screen.paint(layoutBuffer(Row(children), width: width, height: 1), into: oracle)

        var col = 0
        for (i, size) in expected.enumerated() {
            let ch = letters[letters.index(letters.startIndex, offsetBy: i)]
            #expect(size > 0)
            #expect(oracle.cell(col: col, row: 0)?.character == ch,
                    "width \(width) weights \(weights): cell \(col) should be \(ch)")
            #expect(oracle.cell(col: col + size - 1, row: 0)?.character == ch,
                    "width \(width) weights \(weights): cell \(col + size - 1) should be \(ch)")
            col += size
        }
        #expect(col == width)
        // Full coverage, no blank seam.
        #expect(trimmed(oracle.row(0)).count == width)
    }

    // (2) Degenerate: fixed bases overflow the container. Must clip deterministically,
    //     no crash, no negative rect, no width-invariant throw.
    @Test("Fixed bases overflowing the width clip deterministically")
    func fixedOverflowClips() throws {
        let width = 80, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        // Two 50-wide fixed cells into 80: first owns 0..49, second starts at 50 and
        // is clipped at 79 (its last 20 columns fall off the frame).
        let tree = Row([
            Fixed(.absolute(50), ComponentBox(AFill("S"))),
            Fixed(.absolute(50), ComponentBox(AFill("X"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(oracle.cell(col: 0, row: 0)?.character == "S")
        #expect(oracle.cell(col: 49, row: 0)?.character == "S")
        #expect(oracle.cell(col: 50, row: 0)?.character == "X")
        #expect(oracle.cell(col: 79, row: 0)?.character == "X")
        #expect(trimmed(oracle.row(0)).count == 80)
    }

    // (2b) Zero-size slots: a Fixed(.absolute(0)) and a zero-height column must not
    //      crash and must paint nothing where they have no room.
    @Test("Zero-width and zero-height slots are handled")
    func zeroSizeSlots() throws {
        // Zero-width sidebar beside a flexible main: main owns the whole width.
        let width = 20, height = 3
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        let tree = Row([
            Fixed(.absolute(0), ComponentBox(AFill("S"))),
            Flexible(1, ComponentBox(AFill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(oracle.cell(col: 0, row: 0)?.character == "M")
        #expect(oracle.cell(col: 19, row: 0)?.character == "M")

        // Zero-height frame: layoutLines must still return the requested shape and
        // not crash.
        let empty = layoutLines(tree, width: 20, height: 0)
        #expect(empty.count == 0)
        let zeroW = layoutLines(tree, width: 0, height: 3)
        #expect(zeroW.count == 3)
        for l in zeroW { #expect(visibleWidth(l) == 0) }
    }

    // (3) Nesting: a Row of [sidebar | Column of [header|transcript|footer]] resolves
    //     every leaf to correct absolute (x,y,w,h) on the grid.
    @Test("Nested Row-of-Column resolves every leaf to absolute grid coords")
    func nestedRowOfColumn() throws {
        let width = 80, height = 10
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let transcript = LinesComponent((1...8).map { "T\($0)" })
        // A genuinely full-height sidebar: one 20-wide 'S' line per row.
        let sidebar = LinesComponent(Array(repeating: String(repeating: "S", count: 20), count: height))
        let tree = Row([
            Fixed(.absolute(20), ComponentBox(sidebar)),
            Flexible(1, Column([
                Fixed(.absolute(1), ComponentBox(AFill("H"))),
                Flexible(1, ComponentBox(transcript)),
                Fixed(.absolute(1), ComponentBox(AFill("F"))),
            ])),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        // Sidebar: cols 0..19 on EVERY row (full height).
        for r in 0..<height {
            #expect(oracle.cell(col: 0, row: r)?.character == "S")
            #expect(oracle.cell(col: 19, row: r)?.character == "S")
        }
        // Header row 0, cols 20..79.
        #expect(oracle.cell(col: 20, row: 0)?.character == "H")
        #expect(oracle.cell(col: 79, row: 0)?.character == "H")
        // Footer row 9, cols 20..79.
        #expect(oracle.cell(col: 20, row: 9)?.character == "F")
        #expect(oracle.cell(col: 79, row: 9)?.character == "F")
        // Transcript occupies rows 1..8 starting at col 20 (T1 at row 1).
        #expect(oracle.cell(col: 20, row: 1)?.character == "T")
        #expect(oracle.cell(col: 21, row: 1)?.character == "1")
        #expect(oracle.cell(col: 20, row: 8)?.character == "T")
        #expect(oracle.cell(col: 21, row: 8)?.character == "8")
        // The sidebar did not bleed into the header's column region and vice versa.
        #expect(oracle.cell(col: 19, row: 0)?.character == "S")
        #expect(oracle.cell(col: 20, row: 0)?.character == "H")
    }

    // (4) Wide-grapheme boundary under -c release AND at an odd clip column: a CJK
    //     cluster (width 2) straddling the right edge is dropped whole, never split,
    //     and the width invariant never throws.
    @Test("Wide cluster straddling an odd clip column is dropped whole")
    func wideClusterOddBoundary() throws {
        // CJK width-2 glyphs into a width-5 cell: 你好世 = 6 cols of content, cell 5
        // wide. 你(0..1) 好(2..3) then 世 would straddle 4..5 -> dropped, col 4 padded.
        let width = 5, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        let cjk = LinesComponent(["你好世界"])
        let tree = Column([Fixed(.absolute(1), ComponentBox(cjk))])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(oracle.cell(col: 0, row: 0)?.character == "你")
        #expect(oracle.cell(col: 0, row: 0)?.width == 2)
        #expect(oracle.cell(col: 2, row: 0)?.character == "好")
        #expect(oracle.cell(col: 4, row: 0)?.character == " ") // straddler dropped, padded
    }

    // (5) ComponentBox preserves/contains in-band SGR: a styled line clipped mid-run
    //     must NOT bleed its background into the sibling to the right.
    @Test("A styled clipped cell does not bleed SGR into its right sibling")
    func styledCellNoBleed() throws {
        let width = 40, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        // Left cell: 30 red-background '#' with NO reset, clipped into a 20-wide slot.
        // Right cell: plain 'M'. The red background must stop at col 19.
        let tree = Row([
            Fixed(.absolute(20), ComponentBox(BgFill("#", count: 30))),
            Flexible(1, ComponentBox(AFill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)

        // Visible content of the styled cell is the '#'.
        #expect(oracle.cell(col: 0, row: 0)?.character == "#")
        #expect(oracle.cell(col: 19, row: 0)?.character == "#")
        // Left cell is styled (non-default background); right sibling is NOT.
        #expect(oracle.cell(col: 0, row: 0)?.style.background != .default)
        #expect(oracle.cell(col: 20, row: 0)?.character == "M")
        #expect(oracle.cell(col: 20, row: 0)?.style.background == .default,
                "SGR bled from the clipped left cell into the right sibling")
        #expect(oracle.cell(col: 39, row: 0)?.style.background == .default)
    }

    // (5b) A styled line SHORTER than its cell: the pad within the cell must not be
    //      left styled such that it bleeds past the cell into a sibling.
    @Test("A short styled cell's padding does not bleed into the sibling")
    func shortStyledCellNoBleed() throws {
        let width = 20, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        // Left cell: 3 red-bg chars in a 10-wide slot (7 cols of pad inside the cell).
        let tree = Row([
            Fixed(.absolute(10), ComponentBox(BgFill("#", count: 3))),
            Flexible(1, ComponentBox(AFill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(oracle.cell(col: 0, row: 0)?.character == "#")
        // Right sibling starts at col 10, must be default background.
        #expect(oracle.cell(col: 10, row: 0)?.character == "M")
        #expect(oracle.cell(col: 10, row: 0)?.style.background == .default,
                "short styled cell bled into sibling")
        #expect(oracle.cell(col: 19, row: 0)?.style.background == .default)
    }

    // (6) Over-WIDE widget in a Row cell must clip to the cell and not paint into the
    //     right sibling (the horizontal analogue of LayoutTests (e)'s vertical clip).
    @Test("An over-wide widget clips to its cell, no horizontal sibling bleed")
    func overWideNoRightBleed() throws {
        let width = 30, height = 1
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        // LinesComponent ignores width -> emits a 40-col 'L' line into a 10-wide cell.
        let over = LinesComponent([String(repeating: "L", count: 40)])
        let tree = Row([
            Fixed(.absolute(10), ComponentBox(over)),
            Flexible(1, ComponentBox(AFill("R"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(oracle.cell(col: 0, row: 0)?.character == "L")
        #expect(oracle.cell(col: 9, row: 0)?.character == "L")   // last cell of the slot
        #expect(oracle.cell(col: 10, row: 0)?.character == "R")  // sibling not overwritten
        #expect(oracle.cell(col: 29, row: 0)?.character == "R")
    }

    // (7) Incremental path: painting the SAME size twice, changing only one leaf's
    //     content, must NOT trigger an extra full redraw (the diff path handles it).
    @Test("A one-leaf content change at the same size takes no extra full redraw")
    func incrementalNoExtraFullRedraw() throws {
        let width = 20, height = 5
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)

        let body = LinesComponent(["one", "two", "three"])
        func tree() -> any LayoutNode {
            Column([
                Fixed(.absolute(1), ComponentBox(AFill("H"))),
                Flexible(1, ComponentBox(body)),
                Fixed(.absolute(1), ComponentBox(AFill("F"))),
            ])
        }
        try screen.paint(layoutBuffer(tree(), width: width, height: height), into: oracle)
        let afterFirst = screen.fullRedraws
        #expect(afterFirst == 1)   // first frame is the sole full redraw

        // Change one leaf's content; same size -> incremental diff, no new full redraw.
        body.lines = ["one", "CHANGED", "three"]
        try screen.paint(layoutBuffer(tree(), width: width, height: height), into: oracle)
        #expect(screen.fullRedraws == afterFirst,
                "a same-size content change forced a full redraw")
        #expect(trimmed(oracle.row(2)) == "CHANGED")
        #expect(oracle.cell(col: 0, row: 0)?.character == "H")
        #expect(oracle.cell(col: 0, row: 4)?.character == "F")
    }

    // (7b) Painting an IDENTICAL frame twice emits nothing new for the second frame
    //      (byte-stable solve) and still takes no extra full redraw.
    @Test("Re-solving an unchanged tree is byte-stable and diff-empty")
    func unchangedResolveIsStable() throws {
        let width = 20, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(altEnter)
        let screen = StaticAltScreen(width: width, height: height)
        let tree = Row([
            Fixed(.absolute(8), ComponentBox(AFill("S"))),
            Flexible(1, ComponentBox(AFill("M"))),
        ])
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        let redraws = screen.fullRedraws
        // Second identical solve.
        try screen.paint(layoutBuffer(tree, width: width, height: height), into: oracle)
        #expect(screen.fullRedraws == redraws)
        #expect(oracle.cell(col: 7, row: 0)?.character == "S")
        #expect(oracle.cell(col: 8, row: 0)?.character == "M")
    }
}
