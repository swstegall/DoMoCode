// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The 1-D -> 2-D adapter. Every existing widget (`Text`, `Markdown`,
// `SelectList`, `Box`, …) already satisfies `Component` — width in, lines out,
// self-sizing height — and NONE of them are rewritten to join the layout tree.
// `ComponentBox` wraps one and gives it the `LayoutNode` two-pass protocol: it
// MEASURES by rendering the component at a candidate width and counting lines,
// and it PLACES by re-rendering at the assigned width and splicing the produced
// lines, row by row, into the shared `CellBuffer` at the assigned rect.
//
// The tricky part is the PLACE-time clip/pad, and it is delegated to the same
// primitives the whole package trusts: `sliceWithWidth(strict:)` cuts each line
// to exactly `rect.width` visible columns WITHOUT splitting a grapheme cluster or
// an ANSI escape (a wide cluster straddling the right edge is dropped, never
// halved), and `padToWidth` fills a short line to the exact width with real
// spaces. In-band SGR styling is preserved because the slicer carries the active
// style across the cut — never naive `String` slicing.

import DoMoCore

// MARK: - ComponentBox

/// Adapts a ``Component`` into a ``LayoutNode`` leaf, with zero changes to the
/// component itself.
///
/// A `Component` self-sizes its height from a width and cannot negotiate size, so
/// on its own it is a fixed-size leaf: ``measure(available:axis:)`` reports
/// `flex == 0`, and its `preferred` is the component's natural extent on the
/// queried axis (its rendered line COUNT vertically, its longest rendered line
/// WIDTH horizontally). Wrap the box in a ``Flexible`` to make it grow, or a
/// ``Fixed`` to pin its extent.
///
/// At PLACE time the component is re-rendered at `rect.width` and each of the
/// `rect.height` rows is filled: the produced line for that row (blank when the
/// widget produced fewer lines) is sliced to exactly `rect.width` columns and
/// padded to fill, then spliced into the buffer with the 7a
/// ``CellBuffer/place(lines:at:)``. Extra produced lines are clipped to the rect;
/// they never overflow into a sibling.
public struct ComponentBox: LayoutNode {
    public var component: any Component

    public init(_ component: any Component) {
        self.component = component
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        let width = Swift.max(0, available.width)
        guard width > 0 else { return Measured(min: 0, preferred: 0, flex: 0) }
        let lines = component.render(width: width)
        switch axis {
        case .vertical:
            // Main axis is height: the natural extent is the line count.
            return Measured(min: 0, preferred: lines.count, flex: 0)
        case .horizontal:
            // Main axis is width: the natural extent is the longest line, capped
            // at the width the component was measured against.
            let widest = lines.reduce(0) { Swift.max($0, visibleWidth($1)) }
            return Measured(min: 0, preferred: Swift.min(widest, width), flex: 0)
        }
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }
        let produced = component.render(width: rect.width)

        // Build EXACTLY rect.height rows, each EXACTLY rect.width visible columns.
        // A missing row (widget produced fewer lines) is a blank; an extra row
        // (produced more) is dropped by the height cap — so the block never
        // overflows the rect into a sibling, and short widgets blank-fill.
        var rows: [String] = []
        rows.reserveCapacity(rect.height)
        for i in 0..<rect.height {
            let raw = i < produced.count ? produced[i] : ""
            // Strict slice: never overhang the right edge, dropping a wide cluster
            // that would straddle it rather than splitting it. SGR active at the
            // cut is carried in by the slicer, so styling survives.
            let clipped = sliceWithWidth(raw, from: 0, to: rect.width, strict: true).text
            rows.append(padToWidth(clipped, rect.width))
        }

        buffer.place(
            lines: rows,
            at: CellRect(row: rect.y, col: rect.x, width: rect.width, height: rect.height)
        )
    }
}

// MARK: - Component -> LayoutNode convenience

public extension Component {
    /// This component as a ``LayoutNode`` leaf. Sugar for ``ComponentBox/init(_:)``
    /// so a tree reads `myText.layout` at the leaves.
    var layout: ComponentBox { ComponentBox(self) }
}
