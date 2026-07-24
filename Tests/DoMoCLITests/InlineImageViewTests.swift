// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 7.5d: the inline REPL renders a tool's image blocks through `ImageBlockView`,
// which emits a graphics escape row (plus reserved blank rows) on a graphics
// terminal and a `[Image: …]` text marker otherwise. These tests exercise the view
// directly with explicit capabilities — the REPL's own capability detection reads
// the process tty and is not injectable, exactly as the full-screen client's is.

import DoMoLLM
import DoMoTermGraphics
import DoMoTUI
import Foundation
import Testing

@testable import DoMoCLI

@MainActor
@Suite("Inline image view")
struct InlineImageViewTests {
    /// A PNG header the dimension sniffer reads as `width`×`height`.
    private func png(width: Int, height: Int) -> ImageBlock {
        func be(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52]
        bytes += be(width) + be(height)
        return ImageBlock(mediaType: "image/png", data: Data(bytes))
    }

    private func kitty() -> TerminalCapabilities {
        TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true)
    }

    @Test("On a Kitty terminal the first row is the graphics escape and the rest are reserved blanks")
    func kittyEmitsEscapeAndReservedRows() {
        let view = ImageBlockView(block: png(width: 90, height: 45), imageId: 7, capabilities: kitty(), cell: .default)
        let rows = view.render(width: 40)
        #expect(rows.count > 1)
        // The escape is a Kitty graphics APC sequence carrying the allocated id.
        #expect(isImageLine(rows[0]))
        #expect(parseKittyImageHeader(rows[0])?.imageId == 7)
        // Every row after the escape is a reserved blank (the renderer paints around
        // them), so the image's full vertical footprint is held.
        #expect(rows.dropFirst().allSatisfy { $0.isEmpty })
    }

    @Test("On iTerm2 the blank rows come first and the escape is the last row, prefixed by a cursor-up")
    func iterm2LayoutReservesThenDrawsLast() {
        // iTerm2 (unlike Kitty) has no cursor-suppression and no row header, so the
        // differential renderer needs pi's reverse layout: reserve the footprint
        // with blanks, then draw on the last row after moving the cursor back to the
        // block's top. A 90×45 image is 10 cell rows at width 40.
        let caps = TerminalCapabilities(images: .iterm2, trueColor: true, hyperlinks: true)
        let view = ImageBlockView(block: png(width: 90, height: 45), imageId: 3, capabilities: caps, cell: .default)
        let rows = view.render(width: 40)
        #expect(rows.count > 1)
        // The escape is the LAST row, not the first.
        #expect(isImageLine(rows.last!))
        #expect(rows.last!.hasPrefix("\u{1b}[\(rows.count - 1)A"))   // cursor-up of N-1
        #expect(rows.last!.contains("\u{1b}]1337;File="))            // iTerm2 escape follows
        // Every row before the last is a reserved blank, and none is an image line.
        #expect(rows.dropLast().allSatisfy { $0.isEmpty })
    }

    @Test("With no image protocol the view degrades to a bounded text marker")
    func noProtocolFallsBackToText() {
        let caps = TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false)
        let view = ImageBlockView(block: png(width: 90, height: 45), imageId: 1, capabilities: caps, cell: .default)
        let rows = view.render(width: 40)
        #expect(rows.count == 1)
        #expect(!isImageLine(rows[0]))
        #expect(rows[0].contains("Image"))
        // The marker respects the width contract the renderer enforces.
        #expect(visibleWidth(rows[0]) <= 40)
    }

    @Test("An unreadable image (no dimensions) also falls back to text, even on Kitty")
    func unreadableImageFallsBack() {
        let bogus = ImageBlock(mediaType: "image/png", data: Data([0x00, 0x01, 0x02]))
        let view = ImageBlockView(block: bogus, imageId: 1, capabilities: kitty(), cell: .default)
        let rows = view.render(width: 40)
        #expect(rows.count == 1)
        #expect(!isImageLine(rows[0]))
    }

    @Test("Rendering the same width twice returns identical rows (memoized, no re-encode)")
    func memoizesByWidth() {
        let view = ImageBlockView(block: png(width: 90, height: 45), imageId: 9, capabilities: kitty(), cell: .default)
        let first = view.render(width: 40)
        let second = view.render(width: 40)
        #expect(first == second)
    }
}
