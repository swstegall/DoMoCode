// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The full-screen coordinator, exercised THROUGH the SwiftTerm cell-grid oracle —
// the same discipline as `AltScreenCoreTests`, now driving the whole surface:
// layout tree -> overlays -> AltScreenCore -> bytes -> emulator. Focus traversal
// is asserted two ways at once — where the hardware cursor lands (a focused
// region emits the cursor marker) and which region actually receives typed input.
// The coexistence test proves the SAME `TerminalDriver` runs a `ScreenSurface`
// exactly as it runs a `TUI`. Public API only (no `@testable`).

import DoMoCore
import DoMoTermIO
import DoMoTUI
import Testing

// MARK: - Helpers

/// Enter/leave the alternate screen the way the lifecycle does.
private let enterAltScreen = "\u{1b}[?1049h"

/// Trim trailing spaces — the full-page frame paints every cell, so a short row
/// lands as real space cells the emulator will not trim on its own.
private func visible(_ row: String) -> String {
    var trimmed = row
    while trimmed.last == " " { trimmed.removeLast() }
    return trimmed
}

/// A lifecycle stub for the headless driver test: no real terminal touched.
private struct NoopLifecycle: TerminalLifecycleControl {
    func enter() throws(DoMoError) {}
    func stop() {}
}

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

@MainActor
private func drive(_ surface: ScreenSurface, into oracle: ScreenOracle, from target: CaptureTarget) throws {
    try surface.renderSync()
    oracle.feed(target.drain())
}

// MARK: - Tests

@MainActor
@Suite("Full-screen surface — focus, overlays, coexistence")
struct ScreenSurfaceTests {
    /// Two focus regions stacked in a column paint at their rows, and the focused
    /// region's caret drives the hardware cursor.
    @Test("The initial frame paints the tree and the focused region holds the caret")
    func initialFrameAndFocusCursor() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: width, rows: height)

        let alpha = FocusableProbe("alpha", markerColumn: 0)
        let bravo = FocusableProbe("bravo", markerColumn: 0)
        let ring = FocusRing()
        ring.register(alpha)
        ring.register(bravo)   // alpha is focused (first registered)

        let surface = ScreenSurface(target: target, focus: ring) {
            Column([alpha.layout, bravo.layout, FlexSpacer()])
        }
        try drive(surface, into: oracle, from: target)

        #expect(oracle.isCurrentBufferAlternate)
        #expect(visible(oracle.row(0)) == "alpha")
        #expect(visible(oracle.row(1)) == "bravo")
        #expect(visible(oracle.row(5)) == "")     // FlexSpacer fills the rest
        #expect(oracle.cursor.row == 0)           // caret on the focused region (alpha, row 0)
    }

    @Test("A concrete page background paints blank cells and survives row resets")
    func pageBackgroundPaintsEveryCell() throws {
        let width = 12, height = 4
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: width, rows: height)
        let probe = LinesComponent(["\u{1b}[31mred\u{1b}[0m", ""])
        let ring = FocusRing()
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([probe.layout, FlexSpacer()])
        }
        surface.frameBackground = .ansiIndex(24)
        surface.frameBackgroundTrueColor = false
        try drive(surface, into: oracle, from: target)

        for row in 0..<height {
            for column in 0..<width {
                #expect(oracle.cell(col: column, row: row)?.style.background == .ansi(24), "(row),(column)")
            }
        }
    }

    /// Tab moves focus forward, Shift-Tab back — proven by the hardware cursor AND
    /// by which region the next keystroke reaches.
    @Test("Tab and Shift-Tab traverse focus and route input to the focused region")
    func tabTraversesAndRoutesInput() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: width, rows: height)

        let alpha = FocusableProbe("alpha", markerColumn: 0)
        let bravo = FocusableProbe("bravo", markerColumn: 0)
        let ring = FocusRing()
        ring.register(alpha)
        ring.register(bravo)

        let surface = ScreenSurface(target: target, focus: ring) {
            Column([alpha.layout, bravo.layout, FlexSpacer()])
        }
        try drive(surface, into: oracle, from: target)
        #expect(oracle.cursor.row == 0)

        // Tab -> bravo (row 1) holds focus.
        surface.handleInput([0x09])
        try drive(surface, into: oracle, from: target)
        #expect(oracle.cursor.row == 1)

        // Typed input reaches bravo, not alpha.
        surface.handleInput(bytes("z"))
        #expect(bravo.received == [bytes("z")])
        #expect(alpha.received.isEmpty)

        // Shift-Tab (ESC [ Z) -> back to alpha (row 0).
        surface.handleInput([0x1b, 0x5b, 0x5a])
        try drive(surface, into: oracle, from: target)
        #expect(oracle.cursor.row == 0)

        surface.handleInput(bytes("q"))
        #expect(alpha.received == [bytes("q")])
        #expect(bravo.received == [bytes("z")])   // unchanged
    }

    /// An overlay composites over the base page and disappears cleanly on hide.
    @Test("An overlay composites over the base and hides cleanly")
    func overlayCompositesAndHides() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: width, rows: height)

        let base = FocusableProbe("base")
        let ring = FocusRing()
        ring.register(base)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([base.layout, FlexSpacer()])
        }
        try drive(surface, into: oracle, from: target)
        #expect(!oracle.screen.contains { $0.contains("POPUP") })

        let dialog = LinesComponent(["POPUP"])
        let handle = surface.showOverlay(dialog, options: OverlayOptions(width: .absolute(5), anchor: .center))
        try drive(surface, into: oracle, from: target)
        #expect(oracle.screen.contains { $0.contains("POPUP") })
        #expect(surface.hasOverlay())

        handle.hide()
        try drive(surface, into: oracle, from: target)
        #expect(!oracle.screen.contains { $0.contains("POPUP") })
        #expect(!surface.hasOverlay())
    }

    /// A capturing overlay takes focus from the base region and hands it back on
    /// hide — asserted by where typed input lands.
    @Test("A capturing overlay owns input while up, then restores focus")
    func capturingOverlayOwnsInput() throws {
        let width = 20, height = 6
        let target = CaptureTarget(columns: width, rows: height)
        let base = FocusableProbe("base")
        let ring = FocusRing()
        ring.register(base)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([base.layout, FlexSpacer()])
        }
        #expect(base.focused)

        let modal = FocusableProbe("modal")
        let handle = surface.showOverlay(modal, options: OverlayOptions(anchor: .center))
        #expect(modal.focused)
        #expect(!base.focused)          // dimmed while the modal is up

        // Input reaches the modal, not the base — and Tab does not traverse the ring.
        surface.handleInput(bytes("m"))
        surface.handleInput([0x09])
        surface.handleInput(bytes("n"))
        #expect(modal.received == [bytes("m"), [0x09], bytes("n")])
        #expect(base.received.isEmpty)

        // Hiding restores focus to the base region.
        handle.hide()
        #expect(!modal.focused)
        #expect(base.focused)
        surface.handleInput(bytes("o"))
        #expect(base.received == [bytes("o")])
    }

    /// A capturing overlay whose content is NOT Focusable (a plain-lines modal)
    /// must still block the background — both keystrokes and Tab traversal.
    @Test("A capturing overlay blocks the background even when its content is not focusable")
    func capturingNonFocusableOverlayBlocksInput() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let alpha = FocusableProbe("alpha")
        let bravo = FocusableProbe("bravo")
        let ring = FocusRing()
        ring.register(alpha)
        ring.register(bravo)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([alpha.layout, bravo.layout, FlexSpacer()])
        }

        // A modal made of plain lines (not Focusable). Default options -> capturing.
        surface.showOverlay(LinesComponent(["MODAL"]))
        surface.handleInput(bytes("x"))   // keystroke must not reach the ring
        surface.handleInput([0x09])       // Tab must not traverse the ring

        #expect(alpha.received.isEmpty)
        #expect(bravo.received.isEmpty)
        #expect(ring.current === alpha)   // focus did not move
        #expect(!alpha.focused)           // background caret dimmed under the modal

        // Removing the modal hands input back to the ring.
        surface.hideOverlay()
        #expect(alpha.focused)
        surface.handleInput(bytes("y"))
        #expect(alpha.received == [bytes("y")])
    }

    /// Hiding a capturing overlay through the handle's setHidden restores focus to
    /// the region below (input AND the caret flag), and re-showing re-takes it.
    @Test("setHidden on a capturing overlay restores and re-takes focus")
    func setHiddenRestoresFocus() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let base = FocusableProbe("base")
        let ring = FocusRing()
        ring.register(base)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([base.layout, FlexSpacer()])
        }

        let modal = FocusableProbe("modal")
        let handle = surface.showOverlay(modal)
        #expect(modal.focused)
        #expect(!base.focused)

        handle.setHidden(true)
        #expect(!modal.focused)           // hidden overlay no longer claims focus
        #expect(base.focused)             // revealed region shows its caret again
        surface.handleInput(bytes("y"))
        #expect(base.received == [bytes("y")])
        #expect(modal.received.isEmpty)

        handle.setHidden(false)           // re-show -> re-take focus
        #expect(modal.focused)
        #expect(!base.focused)
        surface.handleInput(bytes("z"))
        #expect(modal.received == [bytes("z")])
    }

    /// A `nonCapturing` overlay paints but never steals focus.
    @Test("A non-capturing overlay does not steal focus")
    func nonCapturingOverlayKeepsFocus() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let base = FocusableProbe("base")
        let ring = FocusRing()
        ring.register(base)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([base.layout, FlexSpacer()])
        }

        let toast = FocusableProbe("toast")
        surface.showOverlay(toast, options: OverlayOptions(anchor: .bottomCenter, nonCapturing: true))
        #expect(base.focused)
        #expect(!toast.focused)

        surface.handleInput(bytes("x"))
        #expect(base.received == [bytes("x")])
        #expect(toast.received.isEmpty)
    }

    /// Growing the terminal re-solves the tree: a bottom-anchored footer moves to
    /// the new last row and its old row is cleared.
    @Test("A resize re-solves the layout tree")
    func resizeReSolvesTree() throws {
        let oracle = ScreenOracle(rows: 8, cols: 20)   // sized to the grown terminal
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: 20, rows: 6)   // starts smaller

        let header = LinesComponent(["HEAD"])
        let footer = LinesComponent(["FOOT"])
        let surface = ScreenSurface(target: target, showHardwareCursor: false) {
            Column([header.layout, FlexSpacer(), footer.layout])
        }
        try drive(surface, into: oracle, from: target)
        #expect(visible(oracle.row(0)) == "HEAD")
        #expect(visible(oracle.row(5)) == "FOOT")   // bottom of a 6-row page

        // Grow to 8 rows. The injected resize is adopted like a SIGWINCH.
        target.setSize(TerminalSize(columns: 20, rows: 8))
        try drive(surface, into: oracle, from: target)
        #expect(visible(oracle.row(0)) == "HEAD")
        #expect(visible(oracle.row(7)) == "FOOT")   // footer followed the new bottom
        #expect(visible(oracle.row(5)) == "")       // old footer row cleared
    }

    /// An overlay wider than the screen, anchored into a corner, is clipped inside
    /// the page — never emitted as an over-wide row (which the core rejects).
    @Test("An over-wide corner overlay clips inside the screen")
    func edgeOverlayClips() throws {
        let width = 20, height = 6
        let oracle = ScreenOracle(rows: height, cols: width)
        oracle.feed(enterAltScreen)
        let target = CaptureTarget(columns: width, rows: height)

        let base = LinesComponent(["base"])
        let surface = ScreenSurface(target: target, showHardwareCursor: false) {
            Column([base.layout, FlexSpacer()])
        }
        let wide = LinesComponent([String(repeating: "Z", count: 50)])   // 50 cols on a 20-col screen
        surface.showOverlay(wide, options: OverlayOptions(anchor: .bottomRight))

        // Reaching here without a thrown over-wide DoMoError is half the proof; the
        // other half is that the clipped run lands within the row.
        try drive(surface, into: oracle, from: target)
        let bottom = visible(oracle.row(height - 1))
        #expect(bottom == String(repeating: "Z", count: width))   // exactly the screen width, no overflow
        #expect(oracle.grid[height - 1].count == width)
    }

    /// Coexistence: the exact `TerminalDriver` that runs a `TUI` runs a
    /// `ScreenSurface`, headlessly — scripted keystrokes traverse focus and reach
    /// the focused region through the whole input pipeline.
    @Test("The same driver runs a ScreenSurface end-to-end")
    func driverRunsScreenSurface() async {
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, resizeCont) = AsyncStream.makeStream(of: TerminalSize.self)
        let target = CaptureTarget(columns: 20, rows: 6)

        let alpha = FocusableProbe("alpha")
        let bravo = FocusableProbe("bravo")
        let ring = FocusRing()
        ring.register(alpha)
        ring.register(bravo)
        let surface = ScreenSurface(target: target, focus: ring, showHardwareCursor: false) {
            Column([alpha.layout, bravo.layout, FlexSpacer()])
        }

        let driver = TerminalDriver(input: input, resize: resize, lifecycle: NoopLifecycle())

        inputCont.yield([0x09])          // Tab -> focus bravo
        inputCont.yield(bytes("z"))      // 'z' -> bravo
        inputCont.finish()
        resizeCont.finish()

        await driver.run(surface, quit: QuitSignal())

        #expect(bravo.received == [bytes("z")])
        #expect(alpha.received.isEmpty)
    }
}
