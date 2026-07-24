// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The inline renderer's Kitty-image handling (Phase 7.5c): image lines are
// exempt from the width check, reserve r=N rows via cursor motion, are not
// re-emitted when unchanged, and are cleared with the delete-by-id command (a
// cell erase does not touch the graphics layer) when they change or the screen is
// cleared. Asserted on the emitted BYTES — SwiftTerm does not paint Kitty pixels,
// so the byte structure (not the resulting grid) is the contract here.

import DoMoCore
import DoMoTermGraphics
import DoMoTUI
import Testing

@MainActor
@Suite("Inline renderer — Kitty images")
struct RenderCoreImageTests {
    private func image(id: UInt32, rows: Int, payload: String = "QUJD") -> String {
        encodeKitty(payload, columns: 5, rows: rows, imageId: id, moveCursor: false)
    }

    @Test("A huge image line is exempt from the fatal-width check")
    func imageExemptFromWidthCheck() throws {
        var core = RenderCore()
        let big = image(id: 1, rows: 2, payload: String(repeating: "A", count: 6000))
        // Would throw if the width check measured the multi-KB escape as content.
        _ = try core.frame(lines: ["header", big, ""], width: 20, height: 10)
    }

    @Test("A first render reserves r-1 rows around the image with cursor motion")
    func firstRenderReservesRows() throws {
        var core = RenderCore()
        let img = image(id: 7, rows: 3)
        let out = try core.frame(lines: ["top", img, "", "", "bottom"], width: 20, height: 10)
        #expect(out.contains(img))
        #expect(out.contains("\u{1b}[2A"))   // up (reserved - 1 == 2)
        #expect(out.contains("\u{1b}[2B"))   // back down
    }

    @Test("An unchanged image is not re-emitted or deleted on the next frame")
    func unchangedImageNotReEmitted() throws {
        var core = RenderCore()
        let img = image(id: 3, rows: 3)
        let lines = ["top", img, "", "", "bottom"]
        _ = try core.frame(lines: lines, width: 20, height: 10)
        let second = try core.frame(lines: lines, width: 20, height: 10)
        #expect(!second.contains(img))
        #expect(!second.contains(deleteKittyImage(3)))
    }

    @Test("A changed image deletes the old id before emitting the new one")
    func changedImageDeletesOld() throws {
        var core = RenderCore()
        _ = try core.frame(lines: ["top", image(id: 1, rows: 3), "", "", "bot"], width: 20, height: 10)
        let newImage = image(id: 2, rows: 3, payload: "WFla")
        let second = try core.frame(lines: ["top", newImage, "", "", "bot"], width: 20, height: 10)
        #expect(second.contains(deleteKittyImage(1)))   // old pixels freed
        #expect(second.contains(newImage))              // new image placed
    }

    @Test("A full redraw deletes the previous frame's images before clearing")
    func fullRedrawDeletesPreviousImages() throws {
        var core = RenderCore()
        let img = image(id: 9, rows: 2)
        _ = try core.frame(lines: ["a", img, ""], width: 20, height: 10)
        // A width change forces fullRender(clear: true).
        let out = try core.frame(lines: ["a", img, ""], width: 30, height: 10)
        #expect(out.contains(deleteKittyImage(9)))
        #expect(out.contains("\u{1b}[2J"))
        // The delete precedes the screen clear so no stale pixels survive.
        let deleteIndex = out.range(of: deleteKittyImage(9))
        let clearIndex = out.range(of: "\u{1b}[2J")
        #expect(deleteIndex != nil && clearIndex != nil)
        if let deleteIndex, let clearIndex { #expect(deleteIndex.lowerBound < clearIndex.lowerBound) }
    }

    @Test("An image whose reserved block overflows the viewport bails to a full redraw")
    func oversizeImageBailsToFullRedraw() throws {
        var core = RenderCore()
        _ = try core.frame(lines: ["a", "b", "c", "d"], width: 20, height: 4)
        let redrawsBefore = core.fullRedraws
        // Image at row 1 reserving 4 rows in a height-4 viewport (start 1 + 4 > 4):
        // the incremental reserved-row clear would scroll, so it bails to fullRender.
        _ = try core.frame(lines: ["a", image(id: 5, rows: 4), "", "", ""], width: 20, height: 4)
        #expect(core.fullRedraws > redrawsBefore)   // took the full-redraw bail
    }
}
