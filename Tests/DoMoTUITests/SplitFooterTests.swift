// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

@MainActor
@Suite("Split-footer renderer")
struct SplitFooterTests {
    @Test("The first frame uses normal scrollback and pins the footer")
    func firstFrame() throws {
        let oracle = ScreenOracle(rows: 5, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 5)
        let tui = TUI(target: target, renderMode: .splitFooter)
        let content = LinesComponent(["L0", "L1", "L2", "status", "prompt"])
        tui.addChild(content)
        tui.setFooterRowsProvider { _, _ in 2 }

        try tui.renderSync()
        let bytes = target.drain()
        oracle.feed(bytes)

        #expect(!bytes.contains("\u{1b}[?1049h"))
        #expect(bytes.contains("\u{1b}[1;3r"))
        #expect(bytes.contains("\u{1b}]133;A\u{07}"))
        #expect(bytes.contains("\u{1b}]133;B\u{07}"))
        #expect(oracle.screen == ["L0", "L1", "L2", "status", "prompt"])
        #expect(!oracle.isCurrentBufferAlternate)
        #expect(tui.fullRedraws == 1)
    }

    @Test("Appending transcript scrolls only the transcript region")
    func appendPreservesFooterAndScrollback() throws {
        let oracle = ScreenOracle(rows: 5, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 5)
        let tui = TUI(target: target, renderMode: .splitFooter)
        let content = LinesComponent(["L0", "L1", "L2", "status", "prompt"])
        tui.addChild(content)
        tui.setFooterRowsProvider { _, _ in 2 }

        try tui.renderSync()
        oracle.feed(target.drain())

        content.lines = ["L0", "L1", "L2", "L3", "status", "prompt"]
        try tui.renderSync()
        let bytes = target.drain()
        oracle.feed(bytes)

        #expect(!bytes.contains("\u{1b}[2J"))
        #expect(tui.fullRedraws == 1)
        #expect(oracle.screen == ["L1", "L2", "L3", "status", "prompt"])
        #expect(oracle.transcriptTrimmed.contains("L0"))
        #expect(!oracle.isCurrentBufferAlternate)
    }

    @Test("An earlier transcript mutation repaints the region without clearing history")
    func mutationRepaintsWithoutClearingScrollback() throws {
        let oracle = ScreenOracle(rows: 5, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 5)
        let tui = TUI(target: target, renderMode: .splitFooter)
        let content = LinesComponent(["old", "status", "prompt"])
        tui.addChild(content)
        tui.setFooterRowsProvider { _, _ in 2 }

        try tui.renderSync()
        oracle.feed(target.drain())
        content.lines = ["new", "status", "prompt"]
        try tui.renderSync()
        let bytes = target.drain()
        oracle.feed(bytes)

        #expect(bytes.contains("\u{1b}[2J"))
        #expect(!bytes.contains("\u{1b}[3J"))
        #expect(oracle.row(2) == "new")
        #expect(oracle.screen.suffix(2) == ["status", "prompt"])
    }

    @Test("The hardware cursor stays in a multiline prompt footer")
    func multilinePromptCursor() throws {
        let oracle = ScreenOracle(rows: 5, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 5)
        let tui = TUI(target: target, showHardwareCursor: true, renderMode: .splitFooter)
        let transcript = LinesComponent(["L0"])
        let prompt = FocusableProbe("prompt", markerColumn: 2)
        tui.addChild(transcript)
        tui.addChild(LinesComponent(["status"]))
        tui.addChild(prompt)
        tui.setFocus(prompt)
        tui.setFooterRowsProvider { _, _ in 2 }

        try tui.renderSync()
        oracle.feed(target.drain())

        #expect(oracle.screen == ["", "", "L0", "status", "prompt"])
        #expect(oracle.cursor == (2, 4))
    }

    @Test("Changing the measured footer height forces a safe repaint")
    func footerHeightChange() throws {
        let oracle = ScreenOracle(rows: 5, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 5)
        let tui = TUI(target: target, renderMode: .splitFooter)
        let content = LinesComponent(["L0", "status", "prompt"])
        tui.addChild(content)
        var footerRows = 2
        tui.setFooterRowsProvider { _, _ in footerRows }

        try tui.renderSync()
        oracle.feed(target.drain())
        footerRows = 3
        content.lines = ["L0", "status", "prompt", "hint"]
        try tui.renderSync()
        let bytes = target.drain()
        oracle.feed(bytes)

        #expect(bytes.contains("\u{1b}[2J"))
        #expect(oracle.screen == ["", "L0", "status", "prompt", "hint"])
    }
}
