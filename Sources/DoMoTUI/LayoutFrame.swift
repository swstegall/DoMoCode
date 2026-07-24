// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The compose seam: turn a `LayoutNode` tree into a full frame. It solves the
// root against the frame `Size`, paints it into a fresh `CellBuffer`, and
// (`layoutLines`) flattens to exactly `height` rows of exactly `width` columns —
// precisely the shape `AltScreenCore.frame(lines:width:height:)` consumes. This
// is the minimal driver the tests exercise; the live full-screen coordinator
// that owns an `AltScreenCore`, a resize source, and input is Phase 7c.

import DoMoCore

/// Solve `root` against a `width × height` frame and paint it into a fresh
/// ``CellBuffer``.
///
/// The root is placed into the whole frame rect; a container root sub-divides it
/// internally, so no separate top-level measure pass is needed — `place` does its
/// own measuring as it descends. The returned buffer is not yet normalized; call
/// ``CellBuffer/flatten()`` (or use ``layoutLines(_:width:height:)``) to get the
/// exact `height × width` rows.
@MainActor
public func layoutBuffer(_ root: any LayoutNode, width: Int, height: Int) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    guard width > 0, height > 0 else { return buffer }
    root.place(in: Rect(x: 0, y: 0, width: width, height: height), into: &buffer)
    return buffer
}

/// Solve `root` and flatten to exactly `height` rows of exactly `width` visible
/// columns — the array ``AltScreenCore/frame(lines:width:height:hasOverlays:)``
/// paints directly. A resize is just another call at the new size: re-solving the
/// same tree against a new `width`/`height` yields the new rects, and the
/// alt-screen core repaints them.
@MainActor
public func layoutLines(_ root: any LayoutNode, width: Int, height: Int) -> [String] {
    layoutBuffer(root, width: width, height: height).flatten()
}
