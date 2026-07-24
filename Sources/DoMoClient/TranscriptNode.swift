// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The transcript as a layout node. Unlike TailBox (which only tail-clips a
// component's text lines), this places BOTH text and images: an image visual row
// becomes a CellBuffer.placeImage at its screen position, which the alt-screen
// renderer paints text around and emits as a separate layer. Newest content is
// pinned to the bottom, like a scrolling transcript.

import DoMoTermGraphics
import DoMoTUI

/// Lays the transcript's text + image rows into a rect, pinned to the bottom
/// (auto-scroll to the newest rows).
@MainActor
struct TranscriptNode: LayoutNode {
    let view: TranscriptView
    let capabilities: TerminalCapabilities
    let cell: CellDimensions

    init(view: TranscriptView, capabilities: TerminalCapabilities, cell: CellDimensions) {
        self.view = view
        self.capabilities = capabilities
        self.cell = cell
    }

    func measure(available: Size, axis: Axis) -> Measured {
        // Used inside a Flexible, which decides the extent; report a fully-flexible
        // need so it expands rather than pinning to content height.
        Measured(min: 0, preferred: 0, flex: 1)
    }

    func place(in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }
        let rows = view.visualRows(width: rect.width, capabilities: capabilities, cell: cell)
        // Tail-clip to the last rect.height visual rows (newest at the bottom).
        let shown = rows.count > rect.height ? Array(rows.suffix(rect.height)) : rows
        for (i, row) in shown.enumerated() {
            let screenRow = rect.y + i
            switch row {
            case .text(let line):
                buffer.place(lines: [line], at: CellRect(row: screenRow, col: rect.x, width: rect.width, height: 1))
            case .image(let escape, let imageId, let cellWidth, let cellRows):
                // Clamp the footprint to what remains in the rect so the coverage the
                // renderer computes stays on-page; the text grid at these cells is
                // left blank (nothing is placed there).
                buffer.placeImage(
                    escape,
                    imageId: imageId,
                    row: screenRow,
                    col: rect.x,
                    cellWidth: min(cellWidth, rect.width),
                    cellRows: min(cellRows, rect.height - i)
                )
            }
        }
    }
}
