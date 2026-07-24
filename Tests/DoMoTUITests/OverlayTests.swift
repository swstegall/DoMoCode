// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

@MainActor
@Suite("Overlays — compositing and focus")
struct OverlayTests {
    /// A base filled with a distinct character so the overlay is unmistakable.
    private func filledBase(rows: Int, cols: Int) -> LinesComponent {
        LinesComponent(Array(repeating: String(repeating: "x", count: cols), count: rows))
    }

    @Test("A centered overlay composites over base content at its anchor")
    func centeredOverlay() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))

        // width 4, centered: col = (20-4)/2 = 8, row = (6-1)/2 = 2.
        tui.showOverlay(Text("HI"), options: OverlayOptions(width: .absolute(4), anchor: .center))
        try oracle.drive(tui, from: target)

        #expect(oracle.cell(col: 7, row: 2)?.character == "x") // base to the left
        #expect(oracle.cell(col: 8, row: 2)?.character == "H")
        #expect(oracle.cell(col: 9, row: 2)?.character == "I")
        #expect(oracle.cell(col: 10, row: 2)?.character == " ") // overlay pad
        #expect(oracle.cell(col: 11, row: 2)?.character == " ")
        #expect(oracle.cell(col: 12, row: 2)?.character == "x") // base to the right
        // Rows above and below the overlay are untouched base content.
        #expect(oracle.row(1) == String(repeating: "x", count: 20))
        #expect(oracle.row(3) == String(repeating: "x", count: 20))
    }

    @Test("A top-left overlay anchors at the origin")
    func topLeftOverlay() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))
        tui.showOverlay(Text("TL"), options: OverlayOptions(width: .absolute(2), anchor: .topLeft))
        try oracle.drive(tui, from: target)

        #expect(oracle.cell(col: 0, row: 0)?.character == "T")
        #expect(oracle.cell(col: 1, row: 0)?.character == "L")
        #expect(oracle.cell(col: 2, row: 0)?.character == "x")
    }

    @Test("A bottom-right overlay anchors at the far corner")
    func bottomRightOverlay() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))
        tui.showOverlay(Text("BR"), options: OverlayOptions(width: .absolute(2), anchor: .bottomRight))
        try oracle.drive(tui, from: target)

        // col = 20-2 = 18, row = 6-1 = 5.
        #expect(oracle.cell(col: 18, row: 5)?.character == "B")
        #expect(oracle.cell(col: 19, row: 5)?.character == "R")
    }

    @Test("A percentage width resolves against the terminal width")
    func percentageWidth() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))
        // 50% of 20 = 10. Overlay content fills the whole 10-wide window.
        let overlay = Text(String(repeating: "O", count: 10))
        tui.showOverlay(overlay, options: OverlayOptions(width: .percent(50), anchor: .topLeft))
        let oracle = ScreenOracle(rows: 6, cols: 20)
        try oracle.drive(tui, from: target)

        for c in 0..<10 { #expect(oracle.cell(col: c, row: 0)?.character == "O") }
        #expect(oracle.cell(col: 10, row: 0)?.character == "x")
    }

    @Test("Margins inset the overlay from the terminal edges")
    func marginsInset() throws {
        let oracle = ScreenOracle(rows: 8, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 8)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 8, cols: 20))
        // top-left anchor with a 2-cell margin: origin becomes (2, 2).
        tui.showOverlay(
            Text("M"),
            options: OverlayOptions(width: .absolute(1), anchor: .topLeft, margin: OverlayMargin(all: 2))
        )
        try oracle.drive(tui, from: target)
        #expect(oracle.cell(col: 2, row: 2)?.character == "M")
        #expect(oracle.cell(col: 0, row: 0)?.character == "x")
    }

    @Test("A visible() predicate hides the overlay when it returns false")
    func visibilityPredicate() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))
        // Only show when the terminal is at least 40 columns wide (it is 20).
        tui.showOverlay(
            Text("HIDDEN"),
            options: OverlayOptions(width: .absolute(6), anchor: .topLeft, visible: { w, _ in w >= 40 })
        )
        try oracle.drive(tui, from: target)
        // Overlay suppressed: base content is intact.
        #expect(oracle.row(0) == String(repeating: "x", count: 20))
        #expect(!tui.hasOverlay())
    }

    @Test("A higher overlay stacks on top of a lower one")
    func zOrderStacking() throws {
        let oracle = ScreenOracle(rows: 6, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 6, cols: 20))
        // Two overlapping overlays at the same spot; the later (higher focusOrder) wins.
        tui.showOverlay(Text("AAAA"), options: OverlayOptions(width: .absolute(4), anchor: .topLeft))
        tui.showOverlay(Text("BB"), options: OverlayOptions(width: .absolute(2), anchor: .topLeft))
        try oracle.drive(tui, from: target)
        #expect(oracle.cell(col: 0, row: 0)?.character == "B")
        #expect(oracle.cell(col: 1, row: 0)?.character == "B")
        // Column 2 still shows the lower overlay.
        #expect(oracle.cell(col: 2, row: 0)?.character == "A")
    }

    // MARK: Focus state machine

    @Test("Showing a capturing overlay steals focus; hiding restores it")
    func focusCaptureAndRestore() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let baseFocus = FocusableProbe("base")
        tui.addChild(baseFocus)
        tui.setFocus(baseFocus)
        #expect(tui.focusedComponent === baseFocus)
        #expect(baseFocus.focused)

        let overlay = Text("modal")
        let handle = tui.showOverlay(overlay, options: OverlayOptions(anchor: .center))
        #expect(tui.focusedComponent === overlay)
        #expect(!baseFocus.focused)

        handle.hide()
        // Focus returns to whatever held it before the overlay.
        #expect(tui.focusedComponent === baseFocus)
        #expect(baseFocus.focused)
    }

    @Test("A non-capturing overlay does not steal focus")
    func nonCapturingOverlay() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let baseFocus = FocusableProbe("base")
        tui.addChild(baseFocus)
        tui.setFocus(baseFocus)

        tui.showOverlay(Text("toast"), options: OverlayOptions(anchor: .topRight, nonCapturing: true))
        #expect(tui.focusedComponent === baseFocus)
    }

    @Test("Eligible focus-restore reclaims focus on the next input")
    func eligibleFocusRestore() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let base = FocusableProbe("base")
        tui.addChild(base)
        tui.setFocus(base)

        let overlay = FocusableProbe("overlay")
        tui.showOverlay(overlay, options: OverlayOptions(anchor: .center))
        #expect(tui.focusedComponent === overlay)

        // Move focus back to a mounted, non-overlay component. The overlay becomes
        // "blocked" but pending; the overlay is a visible capturing modal so a
        // subsequent input restores it.
        tui.setFocus(base)
        #expect(tui.focusedComponent === base)

        // Input arrives while focus is on a non-overlay: the restore machine runs.
        tui.handleInput([0x61]) // 'a'
        #expect(tui.focusedComponent === overlay)
    }

    @Test("Input routes to the focused overlay component")
    func inputRoutesToFocused() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let overlay = FocusableProbe("modal")
        tui.showOverlay(overlay, options: OverlayOptions(anchor: .center))
        #expect(tui.focusedComponent === overlay)

        tui.handleInput([0x71]) // 'q'
        #expect(overlay.received == [[0x71]])
    }

    @Test("Key-release events are filtered unless the component opts in")
    func keyReleaseFiltering() throws {
        let target = CaptureTarget(columns: 20, rows: 6)
        let tui = TUI(target: target)
        let probe = FocusableProbe("modal")
        tui.showOverlay(probe, options: OverlayOptions(anchor: .center))
        #expect(tui.focusedComponent === probe)

        // A Kitty release event (":3u") is dropped by default.
        let release = Array("\u{1b}[97;1:3u".utf8)
        tui.handleInput(release)
        #expect(probe.received.isEmpty)

        // Opting in delivers it.
        probe.wantsKeyRelease = true
        tui.handleInput(release)
        #expect(probe.received == [release])
    }

    @Test("maxHeight clamps an overlay taller than its budget")
    func maxHeightClamp() throws {
        let oracle = ScreenOracle(rows: 8, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 8)
        let tui = TUI(target: target)
        tui.addChild(filledBase(rows: 8, cols: 20))
        // A five-line overlay clamped to two rows, anchored top-left.
        let tall = LinesComponent(["r0", "r1", "r2", "r3", "r4"])
        tui.showOverlay(tall, options: OverlayOptions(maxHeight: .absolute(2), anchor: .topLeft))
        try oracle.drive(tui, from: target)

        #expect(oracle.cell(col: 0, row: 0)?.character == "r")
        #expect(oracle.cell(col: 1, row: 0)?.character == "0")
        #expect(oracle.cell(col: 0, row: 1)?.character == "r")
        #expect(oracle.cell(col: 1, row: 1)?.character == "1")
        // Third overlay row was clamped away — base content shows through.
        #expect(oracle.cell(col: 0, row: 2)?.character == "x")
    }
}
