// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The full-screen image layer. pi renders images inline, where an image is just
// a line in the scrolling transcript; the alternate-screen two-pane client cannot
// do that — an image sits in the main pane, sharing its rows with sidebar text, so
// the fixed-height absolute-CUP renderer would erase the image's pixels every time
// it repaints a shared row. So images here are NOT part of the text grid: they are
// a separate layer of placements the renderer (a) paints text AROUND — clearing
// only the columns an image does not cover — and (b) emits/deletes incrementally,
// re-transmitting a Kitty image only when it actually changes.

import DoMoCore
import DoMoTermGraphics

// MARK: - Placement

/// One image placed on the full-screen page: its top-left cell, its cell
/// footprint, the escape to emit, and (for Kitty) the id used to delete it.
public struct ImagePlacement: Sendable, Hashable {
    /// Top-left cell row (0-based, absolute on the page).
    public var row: Int
    /// Top-left cell column.
    public var col: Int
    /// Cell columns the image spans (Kitty `c=`).
    public var cellWidth: Int
    /// Cell rows the image spans (Kitty `r=`).
    public var cellRows: Int
    /// The full graphics escape to write at `(row, col)`.
    public var escape: String
    /// The Kitty image id, for delete-by-id. nil for iTerm2 (no lifecycle).
    public var imageId: UInt32?

    public init(row: Int, col: Int, cellWidth: Int, cellRows: Int, escape: String, imageId: UInt32?) {
        self.row = row
        self.col = col
        self.cellWidth = cellWidth
        self.cellRows = cellRows
        self.escape = escape
        self.imageId = imageId
    }
}

// MARK: - Coverage

/// The covered column ranges per row: `[row: [(startCol, endColExclusive)]]`,
/// clamped to the page. A cell inside a covered range holds image pixels, so the
/// text renderer must not clear or paint it.
func imageCoverageByRow(_ images: [ImagePlacement], width: Int, height: Int) -> [Int: [(Int, Int)]] {
    var coverage: [Int: [(Int, Int)]] = [:]
    for image in images {
        let start = max(0, image.col)
        let end = min(width, image.col + image.cellWidth)
        guard end > start, image.cellRows > 0 else { continue }
        let firstRow = max(0, image.row)
        let lastRow = min(height - 1, image.row + image.cellRows - 1)
        guard firstRow <= lastRow else { continue }
        for row in firstRow...lastRow {
            coverage[row, default: []].append((start, end))
        }
    }
    return coverage
}

/// Merge overlapping or touching column ranges into a minimal sorted set.
func mergeColumnRanges(_ ranges: [(Int, Int)]) -> [(Int, Int)] {
    guard ranges.count > 1 else { return ranges }
    let sorted = ranges.sorted { $0.0 < $1.0 }
    var merged: [(Int, Int)] = [sorted[0]]
    for range in sorted.dropFirst() {
        let last = merged[merged.count - 1]
        if range.0 <= last.1 {
            merged[merged.count - 1] = (last.0, max(last.1, range.1))
        } else {
            merged.append(range)
        }
    }
    return merged
}

// MARK: - Incremental diff

/// The delete-by-id sequence for images that left or changed since last frame, and
/// the images to (re-)emit this frame — everything not byte-identically stable.
/// An unchanged Kitty image is neither deleted nor re-emitted (no flicker, no
/// re-transmit); an iTerm2 image (no id) is always re-emitted since it cannot be
/// tracked or deleted.
func diffImageLayer(previous: [ImagePlacement], current: [ImagePlacement]) -> (deletes: String, emits: String) {
    let currentSet = Set(current)
    let previousSet = Set(previous)

    var deletes = ""
    for image in previous where !currentSet.contains(image) {
        if let id = image.imageId, id > 0 { deletes += deleteKittyImage(id) }
    }

    var emits = ""
    for image in current where !previousSet.contains(image) {
        emits += "\u{1b}[\(image.row + 1);\(image.col + 1)H" + image.escape
    }
    return (deletes, emits)
}
