// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The flexbox-lite LAYOUT layer for the full-screen (alternate-screen) TUI. It
// is the 2-D generalization of the single-box overlay solver
// (`resolveOverlayLayout` in Overlay.swift): where an overlay resolves ONE
// window's `(width, row, col)` against the terminal, a `LayoutNode` tree resolves
// MANY sub-rectangles that tile a frame with no gap and no overrun. Every
// existing `Component` becomes a leaf via `ComponentBox` with zero rewrites — the
// node adds the size negotiation a `Component` (width-in, lines-out, self-sizing
// height) cannot itself participate in.
//
// The vocabulary is deliberately REUSED from the overlay layer: `SizeValue`
// (`.absolute`/`.percent`) drives `Fixed`; `OverlayMargin` drives per-side
// padding and item margin. What 7b adds is the two-pass MEASURE/PLACE protocol
// and the flex containers `Row`/`Column`, the horizontal/vertical analogue of
// `Container.render`'s 1-D top-to-bottom concatenation.

import DoMoCore

// MARK: - Geometry

/// A width × height extent in terminal cells. The unit the MEASURE pass reasons
/// about — "how much room is available" and "how much a node wants".
public struct Size: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A placed rectangle in cell coordinates: `(x, y)` the zero-based top-left
/// corner, `width`/`height` the span. The unit the PLACE pass paints into — a
/// node writes itself into exactly this window of the shared ``CellBuffer`` (via
/// the 7a ``CellBuffer/place(lines:at:)`` splice, which clips overflow and
/// blank-fills short rows). Cells outside the buffer are clipped there.
public struct Rect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// This rect inset on each side by `margin` (a `nil` side is zero), never
    /// shrinking below a zero-size window. The primitive behind both container
    /// padding (inset the content box) and item margin (inset within a slot).
    func inset(by margin: OverlayMargin?) -> Rect {
        guard let margin else { return self }
        let top = max(0, margin.top ?? 0)
        let right = max(0, margin.right ?? 0)
        let bottom = max(0, margin.bottom ?? 0)
        let left = max(0, margin.left ?? 0)
        return Rect(
            x: x + left,
            y: y + top,
            width: max(0, width - left - right),
            height: max(0, height - top - bottom)
        )
    }
}

/// Which way a flex container distributes its children, and therefore which cell
/// dimension is the MAIN axis a ``Measured`` describes. ``Row`` is
/// ``horizontal`` (main = width); ``Column`` is ``vertical`` (main = height).
///
/// Threaded into ``LayoutNode/measure(available:axis:)`` because a node's
/// main-axis need is axis-dependent: `Fixed(.percent(50))` is 50% of the *width*
/// in a `Row` but 50% of the *height* in a `Column`, and a widget's natural
/// extent is its line COUNT vertically but its longest-line WIDTH horizontally.
public enum Axis: Hashable, Sendable {
    case horizontal
    case vertical
}

/// A node's MAIN-axis need, the output of the MEASURE pass.
///
/// Only the main axis negotiates size; the cross axis simply stretches to (clamps
/// at) the container's cross extent. `preferred` is the natural/basis size a
/// `flex == 0` (fixed) node claims outright. `flex` is the weight a node uses to
/// claim a share of whatever main-axis space is left AFTER every fixed node is
/// satisfied — `0` means "not flexible". `min` is the floor a node would like
/// (recorded for completeness; 7b does not shrink a fixed node below it — see the
/// documented "no shrink-below-min" subset on ``Row``/``Column``).
public struct Measured: Hashable, Sendable {
    public var min: Int
    public var preferred: Int
    public var flex: Int

    public init(min: Int, preferred: Int, flex: Int) {
        self.min = min
        self.preferred = preferred
        self.flex = flex
    }
}

// MARK: - LayoutNode

/// A participant in the two-pass full-screen layout: MEASURE then PLACE.
///
/// A ``Component`` takes only a width and self-sizes its height, so it cannot
/// take part in a size negotiation — there is no way to ask it "how tall would
/// you like to be, and would you grow to fill leftover space?". `LayoutNode` adds
/// exactly that:
///
///  1. **MEASURE** — ``measure(available:axis:)`` reports a ``Measured`` main-axis
///     need against an available ``Size``. The `axis` says which cell dimension
///     is the main axis (a `Row` measures width, a `Column` height), because a
///     node's need is axis-dependent.
///  2. **PLACE** — ``place(in:into:)`` paints the node into an assigned ``Rect``
///     of the shared ``CellBuffer``. By the time `place` runs the container has
///     already resolved the rect, so no axis is needed here.
///
/// The sizing wrappers (``Fixed``/``Flexible``/``Spacer``) DEFINE their main size
/// by rule and merely FORWARD `place` to their wrapped child at the resolved
/// rect, so a wrapped child's own `measure` is never consulted for sizing — only
/// its `place` runs. That is what lets a `Flexible(1, Column([...]))` nest: the
/// outer container hands the `Column` a rect and the `Column` sub-divides it.
///
/// `MainActor` by the module default (like ``Component``): the layout solve, the
/// `CellBuffer` it paints, and the render loop are one thread.
public protocol LayoutNode {
    /// Report this node's MAIN-axis need (`min`/`preferred`/`flex`) for the given
    /// `axis`, measuring against `available`. The cross axis is not negotiated —
    /// it clamps to `available` at place time.
    func measure(available: Size, axis: Axis) -> Measured

    /// Paint this node into `rect` of `buffer`, using the 7a splice
    /// (``CellBuffer/place(lines:at:)`` / ``compositeLineAt(_:_:startCol:overlayWidth:totalWidth:)``)
    /// so content on either side of the window survives with its styling intact.
    func place(in rect: Rect, into buffer: inout CellBuffer)
}

extension Axis {
    /// The main-axis extent of `size` for this axis — width horizontally, height
    /// vertically. The one place the axis picks a dimension.
    func main(_ size: Size) -> Int {
        self == .horizontal ? size.width : size.height
    }
}

// MARK: - Fixed

/// A node fixed to a specific MAIN-axis extent, its basis a ``SizeValue`` —
/// `.absolute(n)` for `n` cells, or `.percent(p)` for `p`% of the container's
/// main-axis extent (the same `SizeValue` the overlay solver resolves for an
/// overlay's width). `flex` is `0`: a `Fixed` never grows into leftover space, it
/// claims its basis and no more.
///
/// The basis is resolved at MEASURE time against the axis: `.percent(50)` is half
/// the width inside a ``Row`` but half the height inside a ``Column``. `place`
/// forwards to the wrapped child at the resolved rect (inset by any item
/// ``margin``), so the child paints without knowing it was sized by rule.
public struct Fixed: LayoutNode {
    public var basis: SizeValue
    public var child: any LayoutNode
    /// Per-side space held back INSIDE this node's assigned slot before the child
    /// is placed. Does not reduce the main-axis basis the container distributes
    /// (documented simplification) — it only insets the child within the slot.
    public var margin: OverlayMargin?

    public init(_ basis: SizeValue, _ child: any LayoutNode, margin: OverlayMargin? = nil) {
        self.basis = basis
        self.child = child
        self.margin = margin
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        let resolved: Int
        switch basis {
        case .absolute(let n):
            resolved = max(0, n)
        case .percent(let p):
            resolved = Swift.max(0, Int((Double(axis.main(available)) * p / 100).rounded(.down)))
        }
        return Measured(min: resolved, preferred: resolved, flex: 0)
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        child.place(in: rect.inset(by: margin), into: &buffer)
    }
}

// MARK: - Flexible

/// A node that GROWS to fill a share of the container's leftover main-axis space,
/// proportional to its `weight`. After every ``Fixed`` basis is subtracted, the
/// remaining extent is split among the flex nodes by weight (integer math, exact
/// remainder distribution — see ``Row``/``Column``). A `weight` of `2` claims
/// twice the share of a sibling `weight` `1`.
///
/// Like ``Fixed`` it forwards `place` to its wrapped child at the resolved rect,
/// so any `Component` (via ``ComponentBox``) or nested container becomes flexible
/// without change.
public struct Flexible: LayoutNode {
    public var weight: Int
    public var child: any LayoutNode
    public var margin: OverlayMargin?

    public init(_ weight: Int = 1, _ child: any LayoutNode, margin: OverlayMargin? = nil) {
        self.weight = Swift.max(1, weight)
        self.child = child
        self.margin = margin
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        Measured(min: 0, preferred: 0, flex: weight)
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        child.place(in: rect.inset(by: margin), into: &buffer)
    }
}

// MARK: - Spacer

/// A flexible BLANK: a ``Flexible`` with no child, used to push siblings apart or
/// to the ends of a container. It claims a weighted share of leftover main-axis
/// space and paints nothing — the ``CellBuffer`` already blank-fills the region
/// at ``CellBuffer/flatten()``, so a spacer simply reserves the gap.
///
/// Named `FlexSpacer` (not `Spacer`) because ``Spacer`` is already the 1-D
/// blank-lines ``Component``; this is its main-axis-flexible layout sibling.
public struct FlexSpacer: LayoutNode {
    public var weight: Int

    public init(weight: Int = 1) {
        self.weight = Swift.max(1, weight)
    }

    public func measure(available: Size, axis: Axis) -> Measured {
        Measured(min: 0, preferred: 0, flex: weight)
    }

    public func place(in rect: Rect, into buffer: inout CellBuffer) {
        // Intentionally blank: the buffer starts blank and no sibling overlaps
        // this rect, so leaving it untouched IS the blank fill.
    }
}
