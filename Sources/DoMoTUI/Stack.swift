// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The flex containers — the 2-D analogue of `Container.render`'s 1-D
// top-to-bottom concatenation. A `Container` has no geometry: it stacks each
// child's line run in order because the inline model has no columns to divide. A
// `Row`/`Column` DOES have geometry: it partitions a `Rect` along one axis and
// hands each child a sub-rectangle, so a widget can sit BESIDE another, not only
// beneath it. Nesting a `Row` of a `Column` of widgets is the two-pane primitive
// (a sidebar Fixed/percent beside a main Column).
//
// The classic flex rounding trap lives here: integer main-axis math must sum to
// EXACTLY the container extent — no gap, no overrun — or the frame drifts a
// column. The remainder is distributed deterministically (first-come along the
// main axis) so the split is stable frame to frame.

import DoMoCore

// MARK: - Distribution

/// Split `mainExtent` cells among `measures` along the main axis: every fixed
/// (`flex == 0`) node keeps its `preferred` basis, and the leftover is shared by
/// the flexible nodes in proportion to their `flex` weight.
///
/// The integer split is the load-bearing part. Each flex node first takes the
/// FLOOR of its exact proportional share; the columns lost to flooring (the
/// remainder) are then handed out one at a time to the flex nodes in main-axis
/// order. So the sizes sum to EXACTLY `leftover` (hence to exactly `mainExtent`
/// once the fixed bases are added back) with no gap and no overrun, and a given
/// tree always splits the same way — e.g. three `weight`-1 flexes across 80 cells
/// land 27 / 27 / 26, never 26 / 26 / 26 (a lost column) or 27 / 27 / 27 (an
/// overrun). Fixed bases are clamped so a single over-large fixed node cannot
/// drive a sibling negative.
func distributeMainAxis(_ measures: [Measured], mainExtent: Int) -> [Int] {
    var sizes = [Int](repeating: 0, count: measures.count)
    var fixedTotal = 0
    var totalWeight = 0
    for m in measures {
        if m.flex > 0 {
            totalWeight += m.flex
        } else {
            let basis = Swift.max(0, m.preferred)
            fixedTotal += basis
        }
    }

    let leftover = Swift.max(0, mainExtent - fixedTotal)

    // No flex nodes: fixed nodes keep their basis, leftover (if any) stays unused
    // — a Spacer or a Flexible is how a caller reclaims it.
    guard totalWeight > 0 else {
        for i in measures.indices where measures[i].flex == 0 {
            sizes[i] = Swift.max(0, measures[i].preferred)
        }
        return sizes
    }

    // First pass: floor of the exact share for each flex node; basis for each
    // fixed node.
    var flexIndices: [Int] = []
    var assigned = 0
    for i in measures.indices {
        let m = measures[i]
        if m.flex > 0 {
            let share = leftover * m.flex / totalWeight
            sizes[i] = share
            assigned += share
            flexIndices.append(i)
        } else {
            sizes[i] = Swift.max(0, m.preferred)
        }
    }

    // Second pass: hand the flooring remainder out one cell at a time, in
    // main-axis order, so the total is exact and the split is deterministic. The
    // remainder is strictly less than the number of flex nodes, so a single
    // in-order sweep suffices.
    var remainder = leftover - assigned
    var k = 0
    while remainder > 0, k < flexIndices.count {
        sizes[flexIndices[k]] += 1
        remainder -= 1
        k += 1
    }

    return sizes
}

// MARK: - Stack (shared Row/Column engine)

/// The shared engine behind ``Row`` and ``Column``: measure every child on the
/// stack axis, distribute the main-axis extent with ``distributeMainAxis(_:mainExtent:)``,
/// and place each child in its slot at the full cross extent (stretch).
///
/// Cross-axis handling is stretch-only in 7b (each child fills the container's
/// cross extent). Per-anchor cross alignment reusing ``OverlayAnchor`` is a
/// documented deferral — the vocabulary is wired for it, but the minimal subset
/// this phase ships stretches, matching how the two-pane layout actually uses it.
/// Also documented out of scope for 7b: wrap, shrink-below-min, and reordering.
struct Stack: LayoutNode {
    var axis: Axis
    var children: [any LayoutNode]
    /// Per-side inset applied to the container's own rect before its children are
    /// laid out — the content box. Reuses ``OverlayMargin``.
    var padding: OverlayMargin?

    func measure(available: Size, axis measureAxis: Axis) -> Measured {
        // Best-effort natural size for the RARE case a bare Row/Column is measured
        // by a parent (in normal use a container is wrapped in Fixed/Flexible,
        // whose own measure never consults this). Flex children contribute no
        // natural extent.
        let content = Size(
            width: Swift.max(0, available.width - horizontalPadding),
            height: Swift.max(0, available.height - verticalPadding)
        )
        if measureAxis == axis {
            // Parent stacks us the same way we stack: our natural main extent is
            // the sum of our fixed children's bases.
            var sum = 0
            for child in children {
                let m = child.measure(available: content, axis: axis)
                if m.flex == 0 { sum += Swift.max(0, m.preferred) }
            }
            let pad = measureAxis == .horizontal ? horizontalPadding : verticalPadding
            return Measured(min: sum + pad, preferred: sum + pad, flex: 0)
        } else {
            // Parent stacks us across our axis: our natural cross extent is the
            // widest/tallest child.
            var mx = 0
            for child in children {
                let m = child.measure(available: content, axis: measureAxis)
                mx = Swift.max(mx, m.preferred)
            }
            let pad = measureAxis == .horizontal ? horizontalPadding : verticalPadding
            return Measured(min: mx + pad, preferred: mx + pad, flex: 0)
        }
    }

    func place(in rect: Rect, into buffer: inout CellBuffer) {
        let content = rect.inset(by: padding)
        guard content.width > 0, content.height > 0, !children.isEmpty else { return }

        let available = Size(width: content.width, height: content.height)
        let measures = children.map { $0.measure(available: available, axis: axis) }
        let mainExtent = axis.main(available)
        let sizes = distributeMainAxis(measures, mainExtent: mainExtent)

        var offset = axis == .horizontal ? content.x : content.y
        for i in children.indices {
            let mainSize = sizes[i]
            let childRect: Rect
            switch axis {
            case .horizontal:
                childRect = Rect(x: offset, y: content.y, width: mainSize, height: content.height)
            case .vertical:
                childRect = Rect(x: content.x, y: offset, width: content.width, height: mainSize)
            }
            children[i].place(in: childRect, into: &buffer)
            offset += mainSize
        }
    }

    private var horizontalPadding: Int {
        Swift.max(0, padding?.left ?? 0) + Swift.max(0, padding?.right ?? 0)
    }

    private var verticalPadding: Int {
        Swift.max(0, padding?.top ?? 0) + Swift.max(0, padding?.bottom ?? 0)
    }
}

// MARK: - Row

/// A flex container that lays its children LEFT-TO-RIGHT (main axis = width). The
/// horizontal sibling of ``Column`` and the two-pane workhorse: a `Row` of a
/// `Fixed(.absolute(20))` sidebar and a `Flexible(1)` main region tiles a width
/// exactly, the sidebar owning columns `0..<20` and the main region the rest.
public struct Row: LayoutNode {
    private var stack: Stack

    public init(_ children: [any LayoutNode], padding: OverlayMargin? = nil) {
        self.stack = Stack(axis: .horizontal, children: children, padding: padding)
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        stack.measure(available: available, axis: axis)
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        stack.place(in: rect, into: &buffer)
    }
}

// MARK: - Column

/// A flex container that lays its children TOP-TO-BOTTOM (main axis = height).
/// The direct 2-D generalization of ``Container/render(width:)`` — where
/// `Container` concatenates line runs, `Column` partitions rows — so a header
/// `Fixed(1)`, a `Flexible(1)` transcript, and a footer `Fixed(1)` tile a height
/// exactly: the header at the top row, the footer at the bottom row, the
/// transcript filling everything between.
public struct Column: LayoutNode {
    private var stack: Stack

    public init(_ children: [any LayoutNode], padding: OverlayMargin? = nil) {
        self.stack = Stack(axis: .vertical, children: children, padding: padding)
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        stack.measure(available: available, axis: axis)
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        stack.place(in: rect, into: &buffer)
    }
}
