// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import Testing

// Full-screen (alternate-screen) golden-frame tests THROUGH the screen-state
// oracle — the exact discipline the inline `RendererTests` use, moved to the alt
// buffer. Public API only (no `@testable`): the alt-screen renderer, the cell
// buffer, and the oracle's alt-buffer accessor are all exercised as a caller
// would see them. Bytes that "look right" are not the deliverable; SwiftTerm's
// reaction to them — which buffer is active, where each grapheme lands, and
// whether anything scrolled — is.

// MARK: - Minimal headless wiring

/// Drives a STATIC full-screen frame: a ``CellBuffer`` of known content through
/// ``AltScreenCore/frame(lines:width:height:hasOverlays:)`` into a
/// ``CaptureTarget``, whose bytes are fed to a ``ScreenOracle`` exactly as a
/// terminal on the alternate screen would receive them. The alt-buffer analogue
/// of `ScreenOracle.drive(_:from:)`.
@MainActor
final class StaticAltScreen {
    private var core: AltScreenCore
    let target: CaptureTarget
    let width: Int
    let height: Int

    init(width: Int, height: Int, showHardwareCursor: Bool = false) {
        self.width = width
        self.height = height
        self.target = CaptureTarget(columns: width, rows: height)
        self.core = AltScreenCore(showHardwareCursor: showHardwareCursor)
    }

    /// How many full redraws the core has taken — the incremental-path metric.
    var fullRedraws: Int { core.fullRedraws }

    /// Flatten `buffer` to exactly `height × width`, diff it into bytes, and feed
    /// them to `oracle`.
    func paint(_ buffer: CellBuffer, into oracle: ScreenOracle) throws {
        let bytes = try core.frame(lines: buffer.flatten(), width: width, height: height)
        target.write(bytes)
        oracle.feed(target.drain())
    }
}

/// A full-frame rectangle for the common Phase-7a case: one `place` covering the
/// whole buffer.
@MainActor
private func fullFrame(_ width: Int, _ height: Int, _ lines: [String]) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    buffer.place(lines: lines, at: CellRect(row: 0, col: 0, width: width, height: height))
    return buffer
}

/// Enter the alternate screen the way the lifecycle's `enter()` does: the DEC
/// `?1049h` switch. Feeding the literal bytes proves the oracle models the same
/// sequence `TerminalLifecycle` emits.
private let enterAltScreen = "\u{1b}[?1049h"
/// Leave the alternate screen: `?1049l`, the last byte of the crash-safe exit.
private let exitAltScreen = "\u{1b}[?1049l"

/// Drop trailing spaces from a row. The full-screen frame paints every cell,
/// so a short row lands as real space cells the emulator will not trim on its
/// own (`trimRight` only strips unwritten cells). Trimming here compares the
/// *visible content* while the cell-grid assertions confirm the padding is real.
private func visible(_ row: String) -> String {
    var trimmed = row
    while trimmed.last == " " { trimmed.removeLast() }
    return trimmed
}

private func visible(_ rows: [String]) -> [String] { rows.map(visible) }

// MARK: - Tests

@MainActor
@Suite("Alt-screen renderer — full-screen golden frames")
struct AltScreenCoreTests {
    @Test("Entering the alternate screen switches the active buffer")
    func enterSwitchesBuffer() {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        #expect(!oracle.isCurrentBufferAlternate)
        // (a) The lifecycle enter sequence flips SwiftTerm to the alt buffer.
        oracle.feed(enterAltScreen)
        #expect(oracle.isCurrentBufferAlternate)
    }

    @Test("A static frame lands as the expected alt-screen cell grid")
    func staticLayoutGrid() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)

        let screen = StaticAltScreen(width: width, height: height)
        try screen.paint(fullFrame(width, height, ["Alpha", "Beta", "Gamma"]), into: oracle)

        // (b) The alt viewport equals the expected static layout, cell for cell.
        #expect(oracle.isCurrentBufferAlternate)
        #expect(visible(oracle.row(0)) == "Alpha")
        #expect(visible(oracle.row(1)) == "Beta")
        #expect(visible(oracle.row(2)) == "Gamma")
        #expect(visible(oracle.row(3)) == "")
        #expect(visible(oracle.row(5)) == "")
        #expect(oracle.cell(col: 0, row: 0)?.character == "A")
        #expect(oracle.cell(col: 4, row: 0)?.character == "a")
        #expect(oracle.cell(col: 0, row: 2)?.character == "G")
        // Every flattened row is exactly `width` columns — the frame is full-page.
        #expect(oracle.grid[0].count == width)
    }

    @Test("A bottom-row change is placed by CUP and never scrolls the page")
    func bottomRowClampsNoScroll() throws {
        let width = 20, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let screen = StaticAltScreen(width: width, height: height)

        // Fill every row, including the bottom margin.
        try screen.paint(fullFrame(width, height, ["r0", "r1", "r2", "r3"]), into: oracle)
        #expect(visible(oracle.screen) == ["r0", "r1", "r2", "r3"])

        // (c) Change ONLY the bottom row. A renderer that scrolled the page (an
        // inline-style bottom-row newline) would push "r0" off the top; the
        // absolute-CUP rewrite must clamp to the bottom row and leave the rest put.
        let redrawsBefore = screen.fullRedraws
        try screen.paint(fullFrame(width, height, ["r0", "r1", "r2", "BOT"]), into: oracle)
        #expect(visible(oracle.screen) == ["r0", "r1", "r2", "BOT"]) // top rows intact — no scroll
        #expect(screen.fullRedraws == redrawsBefore)                 // not a sledgehammer redraw

        // The alt buffer has no scrollback: the transcript is exactly the visible
        // page, nothing accumulated in history — the mirror of the inline scroll.
        #expect(visible(oracle.transcriptTrimmed) == ["r0", "r1", "r2", "BOT"])
    }

    @Test("Leaving the alternate screen restores the normal buffer transcript")
    func exitRestoresTranscript() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)

        // Normal-buffer content before entering the alt screen.
        oracle.feed("keep1\r\nkeep2")
        let transcriptBeforeEnter = oracle.transcriptTrimmed
        #expect(transcriptBeforeEnter == ["keep1", "keep2"])

        oracle.feed(enterAltScreen)
        let screen = StaticAltScreen(width: width, height: height)
        try screen.paint(fullFrame(width, height, ["ALT-A", "ALT-B", "ALT-C"]), into: oracle)
        #expect(oracle.isCurrentBufferAlternate)
        #expect(visible(oracle.row(0)) == "ALT-A")

        // (d) `?1049l` returns to the normal buffer, and its transcript is
        // byte-identical to before enter — the alt-screen paint polluted no
        // scrollback.
        oracle.feed(exitAltScreen)
        #expect(!oracle.isCurrentBufferAlternate)
        #expect(oracle.transcriptTrimmed == transcriptBeforeEnter)
    }

    @Test("A single-cell change takes the incremental CUP path, not a full redraw")
    func singleCellIsIncremental() throws {
        let width = 20, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let screen = StaticAltScreen(width: width, height: height)

        try screen.paint(fullFrame(width, height, ["abc", "def", "ghi", "jkl"]), into: oracle)
        let redrawsBefore = screen.fullRedraws

        // Change a single cell on row 1.
        try screen.paint(fullFrame(width, height, ["abc", "dXf", "ghi", "jkl"]), into: oracle)

        // (e) The incremental span-rewrite path ran — no full redraw was taken.
        #expect(screen.fullRedraws == redrawsBefore)
        #expect(visible(oracle.row(0)) == "abc")
        #expect(visible(oracle.row(1)) == "dXf")
        #expect(visible(oracle.row(2)) == "ghi")
        #expect(visible(oracle.row(3)) == "jkl")
    }
}
