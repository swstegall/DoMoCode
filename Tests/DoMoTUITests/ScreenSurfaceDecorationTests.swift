// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two hooks a pointer-driven decoration needs from the full-screen surface:
// read back the page that was actually painted, and transform it one last time
// before the diff. Both are asserted through the SwiftTerm cell-grid oracle, so
// "the row is highlighted" means the emulator says the cells are in reverse
// video — not that the byte stream contains an `ESC[7m` somewhere.
//
// The invariant that matters most is the negative one: a decorator that touches
// one row must not cost a full repaint. `AltScreenCore` skips rows whose string is
// unchanged, so a decorator that rebuilds every row byte-for-differently would
// quietly turn every selection into a whole-page repaint at 10 Hz.

import DoMoCore
import DoMoTermIO
import DoMoTUI
import Testing

@MainActor
@Suite("Full-screen surface — frame capture and decoration")
struct ScreenSurfaceDecorationTests {

    private func makeSurface(width: Int, height: Int, lines: [String]) -> (ScreenSurface, CaptureTarget, LinesComponent) {
        let target = CaptureTarget(columns: width, rows: height)
        let content = LinesComponent(lines)
        let surface = ScreenSurface(target: target, showHardwareCursor: false) {
            Column([content.layout, FlexSpacer()])
        }
        return (surface, target, content)
    }

    @Test("lastFrameLines is the page as painted: exactly rows × columns")
    func lastFrameLinesIsTheWholePage() throws {
        let width = 24, height = 5
        let (surface, _, _) = makeSurface(width: width, height: height, lines: ["alpha", "bravo"])
        #expect(surface.lastFrameLines.isEmpty, "nothing has been painted yet")

        try surface.renderSync()
        #expect(surface.lastFrameLines.count == height)
        for row in surface.lastFrameLines {
            #expect(visibleWidth(row) == width, "every row is padded to the full page width")
        }
        #expect(strippingANSI(surface.lastFrameLines[0]).hasPrefix("alpha"))
        #expect(strippingANSI(surface.lastFrameLines[1]).hasPrefix("bravo"))
    }

    @Test("lastFrameLines is captured PRE-decoration, so a decorator reads the frame and not its own output")
    func lastFrameLinesIsPreDecoration() throws {
        let (surface, _, _) = makeSurface(width: 20, height: 3, lines: ["one", "two"])
        var seen: [[String]] = []
        surface.decorateFrame = { lines in
            seen.append(lines)
            return lines.map { highlightColumns($0, from: 0, to: 3, width: 20) }
        }
        try surface.renderSync()
        // The decorator saw the undecorated page…
        #expect(seen.count == 1)
        #expect(!seen[0][0].contains("\u{1b}[7m"))
        // …and what was retained is that same undecorated page, not the highlighted
        // one. A selection controller reads this back to decide what is selected; if
        // it saw its own highlight it would compound it on every frame.
        #expect(surface.lastFrameLines == seen[0])
        #expect(!surface.lastFrameLines[0].contains("\u{1b}[7m"))

        // A second frame re-captures rather than accumulating.
        try surface.renderSync()
        #expect(seen.count == 2)
        #expect(seen[1] == seen[0])
    }

    @Test("An identity decorator produces byte-identical output to no decorator at all")
    func identityDecoratorIsFree() throws {
        let (plainSurface, plainTarget, _) = makeSurface(width: 20, height: 4, lines: ["alpha", "bravo"])
        try plainSurface.renderSync()
        let plainBytes = plainTarget.drain()

        let (decoratedSurface, decoratedTarget, _) = makeSurface(width: 20, height: 4, lines: ["alpha", "bravo"])
        decoratedSurface.decorateFrame = { $0 }
        try decoratedSurface.renderSync()
        #expect(decoratedTarget.drain() == plainBytes)
    }

    @Test("Highlighting one row puts that row — and only that row — in reverse video")
    func decorationReachesTheEmulator() throws {
        let width = 20, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed("\u{1b}[?1049h")
        let (surface, target, _) = makeSurface(width: width, height: height, lines: ["alpha", "bravo", "charlie"])
        surface.decorateFrame = { lines in
            var lines = lines
            lines[1] = highlightColumns(lines[1], from: 0, to: 5, width: width)
            return lines
        }
        try surface.renderSync()
        oracle.feed(target.drain())

        for column in 0..<5 {
            #expect(oracle.cell(col: column, row: 1)?.style.inverse == true, "column \(column) of row 1")
        }
        #expect(oracle.cell(col: 6, row: 1)?.style.inverse == false)
        #expect(oracle.cell(col: 0, row: 0)?.style.inverse == false)
        #expect(oracle.cell(col: 0, row: 2)?.style.inverse == false)
        // The text is unchanged under the highlight.
        #expect(oracle.row(1).hasPrefix("bravo"))
    }

    @Test("A one-row highlight repaints one row, not the page")
    func decorationStaysIncremental() throws {
        let width = 20, height = 6
        let (surface, target, _) = makeSurface(
            width: width, height: height,
            lines: ["alpha", "bravo", "charlie", "delta", "echo"]
        )
        try surface.renderSync()
        _ = target.drain()
        let redrawsBefore = surface.fullRedraws

        surface.decorateFrame = { lines in
            var lines = lines
            lines[2] = highlightColumns(lines[2], from: 0, to: 7, width: width)
            return lines
        }
        try surface.renderSync()
        let bytes = target.drain()

        #expect(surface.fullRedraws == redrawsBefore, "a highlight must not force a full redraw")
        // Exactly one row was repainted: `AltScreenCore` skips rows whose string is
        // unchanged, and each repainted row costs one absolute cursor placement.
        let placements = bytes.components(separatedBy: "\u{1b}[").filter { $0.contains(";1H") }.count
        #expect(placements == 1, "expected one repainted row, got \(placements)")
        #expect(bytes.contains("bravo") == false)
        #expect(bytes.contains("charlie"))
    }

    @Test("Clearing the decorator restores the undecorated page")
    func removingTheDecoratorRepaintsPlain() throws {
        let width = 20, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed("\u{1b}[?1049h")
        let (surface, target, _) = makeSurface(width: width, height: height, lines: ["alpha", "bravo"])
        surface.decorateFrame = { lines in
            var lines = lines
            lines[0] = highlightColumns(lines[0], from: 0, to: 5, width: width)
            return lines
        }
        try surface.renderSync()
        oracle.feed(target.drain())
        #expect(oracle.cell(col: 0, row: 0)?.style.inverse == true)

        surface.decorateFrame = nil
        try surface.renderSync()
        oracle.feed(target.drain())
        #expect(oracle.cell(col: 0, row: 0)?.style.inverse == false)
        #expect(oracle.row(0).hasPrefix("alpha"))
    }

    @Test("A decorator that widens a row is caught, not painted")
    func overWideDecorationThrows() throws {
        // The invariant `decorateFrame` documents, proven at the seam that enforces
        // it: an over-wide row shifts every column after it, so the renderer throws a
        // catchable DoMoError rather than corrupting the page. This is why
        // `highlightColumns` is width-exact by construction.
        let (surface, _, _) = makeSurface(width: 20, height: 3, lines: ["alpha"])
        surface.decorateFrame = { lines in lines.map { $0 + "!" } }
        #expect(throws: DoMoError.self) {
            try surface.renderSync()
        }
    }
}
