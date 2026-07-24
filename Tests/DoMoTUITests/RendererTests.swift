// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing
@testable import DoMoTUI

// Golden-frame tests THROUGH the screen-state oracle. Each drives real frames
// into a headless VT100 and asserts the resulting cell grid — and, for the
// scroll case, the scrolled-off transcript. Bytes that "look right" are not the
// deliverable; the terminal's reaction to them is.
@MainActor
@Suite("Differential renderer — golden frames")
struct RendererTests {
    @Test("First render lays N lines into the grid, no clear")
    func firstRender() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(LinesComponent(["alpha", "beta", "gamma"]))

        try tui.renderSync()
        let bytes = target.drain()
        // First render must not clear the screen/scrollback.
        #expect(!bytes.contains("\u{1b}[2J"))
        #expect(tui.fullRedraws == 1)

        oracle.feed(bytes)
        #expect(oracle.row(0) == "alpha")
        #expect(oracle.row(1) == "beta")
        #expect(oracle.row(2) == "gamma")
        #expect(oracle.row(3) == "")
    }

    @Test("A single-line change rewrites only that line")
    func singleLineChange() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let content = LinesComponent(["one", "two", "three"])
        tui.addChild(content)
        try oracle.drive(tui, from: target)

        let redrawsBefore = tui.fullRedraws
        content.lines = ["one", "CHANGED", "three"]
        try tui.renderSync()
        let bytes = target.drain()

        // Incremental path: no full clear, no extra full redraw.
        #expect(!bytes.contains("\u{1b}[2J"))
        #expect(tui.fullRedraws == redrawsBefore)
        // Only line 1 appears in the emitted frame; the unchanged lines do not.
        #expect(bytes.contains("CHANGED"))
        #expect(!bytes.contains("three"))

        oracle.feed(bytes)
        #expect(oracle.row(0) == "one")
        #expect(oracle.row(1) == "CHANGED")
        #expect(oracle.row(2) == "three")
    }

    @Test("A line appended at the bottom lands on the next row")
    func appendLine() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let content = LinesComponent(["r0", "r1"])
        tui.addChild(content)
        try oracle.drive(tui, from: target)

        content.lines = ["r0", "r1", "r2"]
        try oracle.drive(tui, from: target)

        #expect(tui.fullRedraws == 1) // still just the first render
        #expect(oracle.row(0) == "r0")
        #expect(oracle.row(1) == "r1")
        #expect(oracle.row(2) == "r2")
    }

    @Test("Content taller than the viewport SCROLLS the transcript, not clamps")
    func scrollsPastViewport() throws {
        // The TauTUI bug: a renderer that moves the cursor down at the bottom
        // margin clamps and overwrites the transcript. This proves a real scroll —
        // the top line must survive in scrollback.
        let oracle = ScreenOracle(rows: 4, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 4)
        let tui = TUI(target: target)
        let content = LinesComponent(["L0", "L1", "L2", "L3"])
        tui.addChild(content)
        try oracle.drive(tui, from: target)
        #expect(oracle.screen == ["L0", "L1", "L2", "L3"])

        // Append a fifth line: the viewport is full, so this must scroll.
        content.lines = ["L0", "L1", "L2", "L3", "L4"]
        try oracle.drive(tui, from: target)

        // Viewport now shows the bottom four lines...
        #expect(oracle.screen == ["L1", "L2", "L3", "L4"])
        // ...and the first line was scrolled into the transcript, not eaten.
        #expect(oracle.transcriptTrimmed == ["L0", "L1", "L2", "L3", "L4"])
        #expect(tui.fullRedraws == 1) // achieved incrementally, no full redraw

        // Keep growing — several lines beyond the viewport in one frame.
        content.lines = ["L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7"]
        try oracle.drive(tui, from: target)
        #expect(oracle.screen == ["L4", "L5", "L6", "L7"])
        #expect(oracle.transcriptTrimmed == ["L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7"])
    }

    @Test("A width change forces a full redraw and reflows")
    func widthChangeFullRedraw() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(Text("hello world foo"))
        try oracle.drive(tui, from: target)
        #expect(oracle.row(0) == "hello world foo")
        let redrawsBefore = tui.fullRedraws

        // Shrink the terminal to 10 columns and re-render.
        target.columns = 10
        let oracle10 = ScreenOracle(rows: 6, cols: 10)
        try tui.renderSync()
        let bytes = target.drain()
        #expect(bytes.contains("\u{1b}[2J")) // full clear
        #expect(tui.fullRedraws == redrawsBefore + 1)

        oracle10.feed(bytes)
        #expect(oracle10.row(0) == "hello")
        #expect(oracle10.row(1) == "world foo")
    }

    @Test("A shrink clears the vacated rows incrementally")
    func shrinkClearsVacatedRows() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let content = LinesComponent(["a", "b", "c", "d"])
        tui.addChild(content)
        try oracle.drive(tui, from: target)
        #expect(oracle.screen[0...3] == ["a", "b", "c", "d"])

        // Drop to two lines. Default clearOnShrink is off: incremental clear.
        content.lines = ["a", "b"]
        try tui.renderSync()
        let bytes = target.drain()
        #expect(!bytes.contains("\u{1b}[2J"))
        #expect(tui.fullRedraws == 1)

        oracle.feed(bytes)
        #expect(oracle.row(0) == "a")
        #expect(oracle.row(1) == "b")
        #expect(oracle.row(2) == "") // "c" cleared
        #expect(oracle.row(3) == "") // "d" cleared
    }

    @Test("clearOnShrink triggers a full redraw when content shrinks")
    func clearOnShrinkFullRedraw() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target, clearOnShrink: true)
        let content = LinesComponent(["a", "b", "c", "d"])
        tui.addChild(content)
        try oracle.drive(tui, from: target)
        let redrawsBefore = tui.fullRedraws

        content.lines = ["a", "b"]
        try tui.renderSync()
        let bytes = target.drain()
        #expect(bytes.contains("\u{1b}[2J"))
        #expect(tui.fullRedraws == redrawsBefore + 1)

        oracle.feed(bytes)
        #expect(oracle.row(0) == "a")
        #expect(oracle.row(1) == "b")
        #expect(oracle.row(2) == "")
    }

    @Test("An over-wide line throws DoMoError rather than trapping")
    func overWideLineThrows() throws {
        let target = CaptureTarget(columns: 10, rows: 6)
        let tui = TUI(target: target)
        let content = LinesComponent(["ok"])
        tui.addChild(content)
        try tui.renderSync() // first render (fine)
        _ = target.drain()

        // Now emit a line wider than the terminal on the incremental path.
        content.lines = ["0123456789ABCDEF"] // width 16 > 10
        #expect(throws: DoMoError.self) {
            try tui.renderSync()
        }
    }

    /// The fatal-width check must also guard the full-redraw paths — a component
    /// that emits an over-wide line on the very first frame (or after a width
    /// change) would otherwise wrap and corrupt every following column silently,
    /// which is exactly the class of component bug the invariant exists to catch.
    @Test("An over-wide line on the first-render path also throws")
    func overWideLineThrowsOnFullRedraw() throws {
        let firstRender = TUI(target: CaptureTarget(columns: 10, rows: 6))
        firstRender.addChild(LinesComponent(["0123456789ABCDEF"])) // 16 > 10
        #expect(throws: DoMoError.self) { try firstRender.renderSync() }

        // And on the width-change full-redraw path.
        let onResize = TUI(target: CaptureTarget(columns: 20, rows: 6))
        let content = LinesComponent(["0123456789ABCDEF"]) // 16, fits at 20
        onResize.addChild(content)
        try onResize.renderSync()
        _ = (onResize.target as? CaptureTarget)?.drain()
        (onResize.target as? CaptureTarget)?.columns = 10 // now 16 > 10
        #expect(throws: DoMoError.self) { try onResize.renderSync() }
    }

    @Test("Synchronized-output wrapping brackets every frame")
    func synchronizedOutputWrapping() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(LinesComponent(["x"]))
        try tui.renderSync()
        let bytes = target.drain()
        #expect(bytes.contains("\u{1b}[?2026h"))
        #expect(bytes.contains("\u{1b}[?2026l"))
    }

    @Test("A focused component's cursor marker positions the hardware cursor")
    func cursorMarkerPositioning() throws {
        let oracle = ScreenOracle(rows: 4, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 4)
        let tui = TUI(target: target, showHardwareCursor: true)
        let probe = FocusableProbe("hello", markerColumn: 3)
        tui.addChild(probe)
        tui.setFocus(probe)
        try oracle.drive(tui, from: target)

        // The marker sat after "hel" (column 3) on row 0; the visible text is intact.
        #expect(oracle.row(0) == "hello")
        #expect(oracle.cursor == (3, 0))
    }
}
