// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI

/// A one-cell layout node used between the session sidebar and the main pane.
/// The node is deliberately part of the layout tree, so the divider consumes the
/// same column that ``ClientLayout`` removes from main-pane measurements.
@MainActor
struct VerticalDividerNode: LayoutNode {
    let color: String

    func measure(available: Size, axis: Axis) -> Measured {
        Measured(min: 1, preferred: 1, flex: 0)
    }

    func place(in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }
        let glyph = color.isEmpty ? "│" : color + "│" + "\u{1b}[0m"
        for row in 0..<rect.height {
            buffer.place(
                lines: [glyph],
                at: CellRect(row: rect.y + row, col: rect.x, width: 1, height: 1)
            )
        }
    }
}
