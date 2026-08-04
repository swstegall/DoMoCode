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
/// (auto-scroll to the newest rows) unless the view carries a scroll offset, in
/// which case the viewport is that many rows further up.
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
        let rows = view.visualRows(
            width: rect.width,
            capabilities: capabilities,
            cell: cell,
            maxHeightRows: rect.height
        )
        // The viewport is `rect.height` rows ending `scrollOffset` rows above the
        // newest row. Clamping happens HERE — this is the only place that knows the
        // viewport height — and the clamped value is written back so the app's
        // scroll handler and the status line agree with what was actually painted
        // (a wheel spun past the top must not leave a phantom offset behind).
        let maxOffset = max(0, rows.count - rect.height)
        let offset = min(max(0, view.scrollOffset), maxOffset)
        view.scrollOffset = offset
        let end = max(0, rows.count - offset)
        let start = max(0, end - rect.height)
        let shown = Array(rows[start..<end])
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
