// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing
@testable import DoMoTUI

private let escBytes: [UInt8] = [0x1b]
private let aBytes: [UInt8] = [0x61]

@MainActor
@Suite("Loader and TruncatedText")
struct LoaderTests {
    // MARK: Loader frame advance

    @Test("The spinner frame advances only on tick and wraps")
    func frameAdvance() {
        let loader = Loader(frames: ["A", "B", "C"])
        #expect(loader.frameIndex == 0)
        #expect(loader.render(width: 20)[1].contains("A"))

        loader.tick()
        #expect(loader.frameIndex == 1)
        #expect(loader.render(width: 20)[1].contains("B"))

        loader.tick()
        loader.tick() // wraps 2 -> 0
        #expect(loader.frameIndex == 0)
    }

    @Test("A single-frame indicator never advances")
    func singleFrameStatic() {
        let loader = Loader(frames: ["*"])
        loader.tick()
        loader.tick()
        #expect(loader.frameIndex == 0)
    }

    @Test("Render is a leading blank line then the spinner and message")
    func renderShape() {
        let loader = Loader(message: "Working")
        let lines = loader.render(width: 40)
        #expect(lines.first == "")
        #expect(lines.count >= 2)
        #expect(lines[1].contains("Working"))
        // The default braille frame 0 is present.
        #expect(lines[1].contains(Loader.defaultFrames[0]))
    }

    @Test("Every rendered line fits the width budget")
    func rendersWithinWidth() {
        let loader = Loader(message: String(repeating: "status ", count: 30))
        for width in [8, 20, 40, 80] {
            for line in loader.render(width: width) {
                #expect(visibleWidth(line) <= width)
            }
        }
    }

    @Test("setMessage updates the rendered text")
    func setMessage() {
        let loader = Loader(message: "one")
        loader.setMessage("two")
        #expect(loader.render(width: 20)[1].contains("two"))
    }

    @Test("Loader through the screen oracle stays within width")
    func loaderThroughOracle() throws {
        let loader = Loader(message: "Loading data")
        let oracle = ScreenOracle(rows: 4, cols: 24)
        let target = CaptureTarget(columns: 24, rows: 4)
        let tui = TUI(target: target)
        tui.addChild(loader)
        try oracle.drive(tui, from: target)
        #expect(oracle.screen.contains { $0.contains("Loading data") })
        for r in 0..<4 { #expect(visibleWidth(oracle.row(r)) <= 24) }

        // Advance a frame and re-render: the diff path stays clean.
        loader.tick()
        try oracle.drive(tui, from: target)
        for r in 0..<4 { #expect(visibleWidth(oracle.row(r)) <= 24) }
    }

    // MARK: CancellableLoader

    @Test("CancellableLoader reports cancellation on Escape via flag and callback")
    func cancellableCancel() {
        let loader = CancellableLoader(message: "Working")
        var cancelledCallback = false
        loader.onCancel = { cancelledCallback = true }

        loader.handleInput(aBytes) // ignored
        #expect(!loader.cancelled)

        loader.handleInput(escBytes)
        #expect(loader.cancelled)
        #expect(cancelledCallback)

        // Idempotent: a second cancel does not fire the callback again.
        cancelledCallback = false
        loader.handleInput(escBytes)
        #expect(!cancelledCallback)
    }

    @Test("CancellableLoader still animates like a Loader")
    func cancellableAnimates() {
        let loader = CancellableLoader(frames: ["A", "B"])
        #expect(loader.frameIndex == 0)
        loader.tick()
        #expect(loader.frameIndex == 1)
    }

    // MARK: TruncatedText

    @Test("Short text passes through, padded to the full width")
    func truncatedShort() {
        let lines = TruncatedText("hi").render(width: 10)
        #expect(lines.count == 1)
        #expect(visibleWidth(lines[0]) == 10)
        #expect(lines[0].hasPrefix("hi"))
    }

    @Test("Long text is truncated with an ellipsis and fits the width")
    func truncatedLong() {
        let lines = TruncatedText("this is a very long line indeed").render(width: 12)
        #expect(lines.count == 1)
        #expect(visibleWidth(lines[0]) <= 12)
        #expect(lines[0].contains("..."))
    }

    @Test("Only the first physical line is shown")
    func truncatedFirstLineOnly() {
        let lines = TruncatedText("first line\nsecond line").render(width: 40)
        #expect(lines.count == 1)
        #expect(lines[0].contains("first line"))
        #expect(!lines[0].contains("second"))
    }

    @Test("Padding adds blank rows and horizontal inset, every line at full width")
    func truncatedPadding() {
        let lines = TruncatedText("x", paddingX: 2, paddingY: 1).render(width: 10)
        #expect(lines.count == 3) // pad row, content, pad row
        for line in lines { #expect(visibleWidth(line) == 10) }
        // Content row has two leading spaces then the text.
        #expect(lines[1].hasPrefix("  x"))
    }

    @Test("Padding wider than half the width still fits the budget")
    func truncatedPaddingOverflowClamped() {
        // Regression: when paddingX * 2 >= width the available-width floor could
        // not reserve both pads, so the composed line overran `width` — an
        // over-wide (renderer-fatal) line. Every case must now land within budget.
        for (text, width, px) in [
            ("hello world", 2, 1), ("hello world", 6, 3), ("hello world", 8, 5),
            ("你好世界你好世界", 7, 4), ("x", 1, 1),
        ] {
            for line in TruncatedText(text, paddingX: px).render(width: width) {
                #expect(visibleWidth(line) <= width,
                        "TruncatedText over budget at width \(width) paddingX \(px): \(visibleWidth(line))")
            }
        }
    }

    @Test("TruncatedText through the oracle fits the width")
    func truncatedThroughOracle() throws {
        let oracle = ScreenOracle(rows: 3, cols: 16)
        let target = CaptureTarget(columns: 16, rows: 3)
        let tui = TUI(target: target)
        tui.addChild(TruncatedText("a fairly long status message", paddingX: 1))
        try oracle.drive(tui, from: target)
        for r in 0..<3 { #expect(visibleWidth(oracle.row(r)) <= 16) }
        #expect(oracle.row(0).contains("..."))
    }
}
