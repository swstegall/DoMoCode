// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A layout node that shows the *tail* of a component. `ComponentBox` clips a
// too-tall component to its first rows; a transcript wants the opposite — the
// newest lines, pinned to the bottom of the viewport. This is that: render the
// component at the rect width, keep the last `rect.height` lines, and paint them.

import DoMoTUI

/// Places a component's LAST `rect.height` rendered lines into its rect —
/// auto-scroll-to-bottom for a growing log/transcript. Shorter content fills from
/// the top with blanks below (the ``CellBuffer`` leaves unwritten rows blank).
@MainActor
struct TailBox: LayoutNode {
    let component: any Component

    init(_ component: any Component) {
        self.component = component
    }

    func measure(available: Size, axis: Axis) -> Measured {
        // Always used inside a `Flexible`, which decides the extent; report a
        // modest, fully-flexible need so a bare use still expands rather than
        // pinning to content height.
        Measured(min: 0, preferred: 0, flex: 1)
    }

    func place(in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }
        let all = component.render(width: rect.width)
        let visible = all.count > rect.height ? Array(all.suffix(rect.height)) : all
        buffer.place(lines: visible, at: CellRect(row: rect.y, col: rect.x, width: rect.width, height: rect.height))
    }
}
