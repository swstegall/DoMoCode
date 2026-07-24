// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The full-screen renderer's image layer (Phase 7.5c part 2). Images are tracked
// apart from the text grid; the renderer paints text AROUND their coverage (so a
// shared row never erases the pixels) and emits/deletes them incrementally. There
// is no pi reference for this — pi is inline-only — so it is asserted on the
// emitted bytes (SwiftTerm does not paint Kitty pixels): the image escape at its
// CUP, the per-segment painting of a covered row, and the incremental delete.

import DoMoCore
import DoMoTermGraphics
import Testing

@testable import DoMoTUI

@MainActor
@Suite("Alt-screen renderer — image layer")
struct AltScreenCoreImageTests {
    private func placement(row: Int, col: Int, cols: Int, rows: Int, id: UInt32) -> ImagePlacement {
        ImagePlacement(
            row: row, col: col, cellWidth: cols, cellRows: rows,
            escape: encodeKitty("QUJD", columns: cols, rows: rows, imageId: id, moveCursor: false),
            imageId: id
        )
    }

    private func grid(_ lines: [String], height: Int) -> [String] {
        var padded = lines
        while padded.count < height { padded.append("") }
        return padded
    }

    @Test("Coverage maps an image's rectangle to per-row column ranges")
    func coverage() {
        let cov = imageCoverageByRow([placement(row: 2, col: 5, cols: 3, rows: 2, id: 1)], width: 20, height: 10)
        #expect(cov[2]?.first?.0 == 5 && cov[2]?.first?.1 == 8)
        #expect(cov[3]?.first?.0 == 5 && cov[3]?.first?.1 == 8)
        #expect(cov[1] == nil)
        #expect(cov[4] == nil)
    }

    @Test("Overlapping and touching column ranges merge")
    func merge() {
        let a = mergeColumnRanges([(0, 5), (3, 8), (10, 12)])
        #expect(a.count == 2)
        #expect(a[0].0 == 0 && a[0].1 == 8)
        let b = mergeColumnRanges([(0, 5), (5, 8)])   // touching
        #expect(b.count == 1 && b[0].0 == 0 && b[0].1 == 8)
    }

    @Test("The image diff deletes changed/removed and emits new, skipping stable")
    func diff() {
        let a = placement(row: 1, col: 0, cols: 4, rows: 2, id: 1)
        let b = placement(row: 1, col: 0, cols: 4, rows: 2, id: 2)
        let same = diffImageLayer(previous: [a], current: [a])
        #expect(same.deletes.isEmpty && same.emits.isEmpty)
        let changed = diffImageLayer(previous: [a], current: [b])
        #expect(changed.deletes.contains(deleteKittyImage(1)))
        #expect(changed.emits.contains(b.escape))
        let removed = diffImageLayer(previous: [a], current: [])
        #expect(removed.deletes.contains(deleteKittyImage(1)) && removed.emits.isEmpty)
    }

    @Test("A first frame emits the image at its CUP and paints text around it")
    func firstFrameEmitsImage() throws {
        var core = AltScreenCore()
        let img = placement(row: 1, col: 10, cols: 4, rows: 2, id: 7)
        let text = grid(["top", "SIDEBAR", "sidebar2", "bottom"], height: 6)
        let out = try core.frame(lines: text, width: 20, height: 6, images: [img])
        #expect(out.contains(img.escape))
        #expect(out.contains("\u{1b}[2;11H"))   // CUP to (row 1, col 10)
    }

    @Test("An unchanged image is not re-emitted; a changed one deletes the old id")
    func incrementalImage() throws {
        var core = AltScreenCore()
        let text = grid(["a", "", "", "d"], height: 4)
        let img1 = placement(row: 1, col: 0, cols: 4, rows: 2, id: 1)
        _ = try core.frame(lines: text, width: 20, height: 4, images: [img1])
        let second = try core.frame(lines: text, width: 20, height: 4, images: [img1])
        #expect(!second.contains(img1.escape))          // unchanged -> not re-emitted
        #expect(!second.contains(deleteKittyImage(1)))
        let img2 = placement(row: 1, col: 0, cols: 4, rows: 2, id: 2)
        let third = try core.frame(lines: text, width: 20, height: 4, images: [img2])
        #expect(third.contains(deleteKittyImage(1)))     // old freed
        #expect(third.contains(img2.escape))             // new placed
    }

    @Test("A covered row is painted in uncovered segments, never a full-row clear")
    func coveredRowSegments() throws {
        var core = AltScreenCore()
        // Image covers cols 5..9 on rows 0..1; row 0 has text in cols 0..4 and 10..14.
        let img = placement(row: 0, col: 5, cols: 5, rows: 2, id: 3)
        let text = grid(["LEFT      RIGHT", "aaaaa     bbbbb"], height: 4)
        let out = try core.frame(lines: text, width: 15, height: 4, images: [img])
        #expect(out.contains(img.escape))
        #expect(out.contains("\u{1b}[1;1H"))    // left segment CUP at (0,0)
        #expect(out.contains("\u{1b}[1;11H"))   // right segment CUP at (0,10)
    }

    @Test("An image-only change (text grid unchanged) still updates the image layer")
    func imageOnlyChange() throws {
        var core = AltScreenCore()
        let text = grid(["x", "y", "z"], height: 4)
        _ = try core.frame(lines: text, width: 20, height: 4, images: [])
        // Same text, but now an image appears — must be emitted despite no text change.
        let img = placement(row: 0, col: 8, cols: 3, rows: 1, id: 9)
        let out = try core.frame(lines: text, width: 20, height: 4, images: [img])
        #expect(out.contains(img.escape))
    }
}
