// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A fixed height × width row accumulator for the full-screen (alternate-screen)
// renderer. Unlike a classic terminal cell grid it does not store one struct per
// column: its backing store is styled `[String]` rows with ANSI carried in-band,
// the same representation every component in this package already emits. The
// splice/place primitive is the overlay compositor's `compositeLineAt` /
// `extractSegments`, lifted (in Overlay.swift) into `nonisolated` free functions
// so a `CellBuffer` can place a span without an owning `TUI`.

import DoMoCore

// MARK: - Rect

/// A rectangular window into a ``CellBuffer``, in cell coordinates: `row`/`col`
/// are the top-left corner (zero-based), `width`/`height` the span. Rows and
/// columns that fall outside the buffer are clipped by ``CellBuffer/place(lines:at:)``.
public struct CellRect: Equatable, Sendable {
    public var row: Int
    public var col: Int
    public var width: Int
    public var height: Int

    public init(row: Int, col: Int, width: Int, height: Int) {
        self.row = row
        self.col = col
        self.width = width
        self.height = height
    }
}

// MARK: - CellBuffer

/// A fixed `height × width` frame the full-screen renderer composes into.
///
/// The buffer holds exactly `height` styled rows. Content is written by
/// ``setRow(_:_:)`` (replace a whole row) or ``place(lines:at:)`` (splice a block
/// of lines into a sub-rectangle, carrying the base row's styling around the
/// window via ``compositeLineAt(_:_:startCol:overlayWidth:totalWidth:)``).
/// ``flatten()`` normalizes the result to exactly `height` rows of exactly
/// `width` visible columns — short rows blank-filled, over-wide rows clipped —
/// which is precisely the invariant ``AltScreenCore/frame(lines:width:height:hasOverlays:)``
/// relies on (viewport == buffer, one screen row per line).
///
/// A pure value type: no terminal, no owning renderer, trivially testable (it
/// sits within the module's default `MainActor` isolation, like ``RenderCore``).
/// For Phase 7a a single full-frame ``place(lines:at:)`` is enough; the layout
/// tree that drives many sub-rectangles is Phase 7b.
public struct CellBuffer {
    public let width: Int
    public let height: Int

    /// The styled rows, always exactly `height` entries. Each is a logical line
    /// that ``flatten()`` clips/pads to `width`; between writes a row may be
    /// shorter or (transiently, mid-splice) wider than `width`.
    private var rows: [String]

    /// An empty buffer of the given size: every row blank.
    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.rows = Array(repeating: "", count: self.height)
    }

    // MARK: Writing

    /// Replace row `index` wholesale. Out-of-range indices are ignored. The
    /// content is stored as-is and normalized to `width` only at ``flatten()``.
    public mutating func setRow(_ index: Int, _ content: String) {
        guard index >= 0, index < height else { return }
        rows[index] = content
    }

    /// Splice a block of `lines` into the sub-rectangle `rect`.
    ///
    /// Each line is placed on its own row starting at `rect.row`, spliced in at
    /// `rect.col` across `rect.width` columns with
    /// ``compositeLineAt(_:_:startCol:overlayWidth:totalWidth:)`` so the existing
    /// row content on either side of the window survives with its styling intact.
    /// Lines beyond `rect.height`, and rows outside the buffer, are clipped.
    public mutating func place(lines: [String], at rect: CellRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let count = min(lines.count, rect.height)
        for i in 0..<count {
            let targetRow = rect.row + i
            guard targetRow >= 0, targetRow < height else { continue }
            rows[targetRow] = compositeLineAt(
                rows[targetRow],
                lines[i],
                startCol: rect.col,
                overlayWidth: rect.width,
                totalWidth: width
            )
        }
    }

    // MARK: Reading

    /// The finished frame: exactly `height` rows, each exactly `width` visible
    /// columns. A row narrower than `width` is blank-filled with
    /// ``padToWidth(_:_:with:)``; a row wider than `width` is clipped with a
    /// strict ``sliceByColumn(_:from:to:strict:)`` (which drops a wide cluster
    /// straddling the right edge, then pads the vacated column). This is the
    /// representation ``AltScreenCore`` addresses row-by-row with absolute CUP.
    public func flatten() -> [String] {
        rows.map { row in
            let clipped = visibleWidth(row) > width
                ? sliceByColumn(row, from: 0, to: width, strict: true)
                : row
            return padToWidth(clipped, width)
        }
    }
}
