// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The gesture half of "let me highlight and copy text". `ScreenSelection` and
// friends (DoMoTUI/ScreenSelection.swift) are pure functions over a painted
// page; this is the object that turns a stream of mouse reports into one of
// those selections, decides which frame it is anchored to, and decides when it
// has stopped meaning anything.
//
// SCREEN-ANCHORED, NOT CONTENT-ANCHORED. `ScreenSurface.renderSync` rebuilds the
// whole layout tree from scratch every frame, and the nodes are value types with
// no identity, so there is nothing content-shaped to hang a selection on — only
// the rows that were actually painted. That is a real limitation and it is
// stated here rather than hidden: a selection is valid exactly as long as every
// row it covers still paints the same plain text at the same screen row.
//
// The invalidation policy is the whole design problem, because this app repaints
// about ten times a second while a turn is running. Two obvious answers are both
// wrong:
//
//   * invalidate on every frame — the selection dies on the first spinner tick,
//     i.e. roughly 100 ms after the user finishes dragging, and right-click
//     never has anything to copy;
//   * never invalidate — the selection keeps pointing at row 7 while row 7 is
//     rewritten by streaming text, so the highlight is over one thing and the
//     copy takes another. That is worse than losing the selection, because it is
//     silent and it produces a WRONG clipboard.
//
// So: only the SELECTED rows are compared, by their escape-stripped text
// (``capturedRows``), plus the page's shape (row count and width). A spinner
// tick repaints the status row and the streaming tail; a selection over history
// touches neither and survives. A selection that does cover the streaming tail
// is dropped on the very next token, which is correct — that text genuinely
// changed under it.

import DoMoTUI
import Foundation

/// Turns mouse reports into a ``ScreenSelection`` over the painted frame, and
/// decides when that selection has stopped meaning anything.
@MainActor
final class SelectionController {

    /// The live selection, or nil when nothing is selected.
    private(set) var selection: ScreenSelection?

    /// The pane's column window the active selection is confined to, so a drag
    /// that began in the transcript never cuts the sidebar into every line.
    private(set) var columns: Range<Int> = 0..<0

    /// Whether a button is still held, i.e. whether motion should extend.
    private(set) var isDragging = false

    /// The escape-stripped text of every row the selection touches, captured
    /// whenever the selection changes. The invalidation oracle.
    private var capturedRows: [Int: String] = [:]
    /// The painted page's shape when the rows were captured. A resize re-wraps
    /// everything, and comparing the shape catches it even in the unlikely case
    /// that every selected row's text survived the re-wrap byte for byte.
    private var capturedHeight = 0
    private var capturedWidth = 0

    private var lastClickAt = Date.distantPast
    private var lastClickCell: ScreenCell?
    private var clickCount = 0

    /// The multi-click window. 400 ms is the usual desktop double-click default
    /// and is generous enough for a trackpad.
    static let multiClickInterval: TimeInterval = 0.4

    // MARK: Gestures

    /// Left press.
    ///
    /// `shiftExtend` keeps the existing anchor and moves the focus — shift-click
    /// extends, exactly as a terminal's own selection does. Otherwise the click
    /// count decides: 1 starts a drag, 2 takes the word under the pointer, 3
    /// takes the row's content. The count wraps at 3, so a fourth click starts
    /// over rather than leaving the user stuck on line-select.
    func press(
        at cell: ScreenCell,
        columns paneColumns: Range<Int>,
        frame: [String],
        shiftExtend: Bool,
        now: Date
    ) {
        guard !frame.isEmpty, paneColumns.lowerBound < paneColumns.upperBound else {
            clear()
            return
        }

        // Shift-click extends the CURRENT selection, so it keeps the current
        // pane window: extending into a different pane would produce a selection
        // whose two ends disagree about which columns they are clamped to.
        if shiftExtend, let existing = selection {
            let target = clamp(cell, to: columns, frame: frame)
            selection = ScreenSelection(anchor: existing.anchor, focus: target)
            isDragging = true
            capture(frame)
            // A shift-click is a continuation, not the start of a click run: a
            // subsequent plain click in the same cell must not read as a
            // double-click on a word the user never clicked.
            resetClickRun()
            return
        }

        columns = paneColumns
        let target = clamp(cell, to: paneColumns, frame: frame)

        if now.timeIntervalSince(lastClickAt) < Self.multiClickInterval, lastClickCell == target {
            clickCount = clickCount % 3 + 1
        } else {
            clickCount = 1
        }
        lastClickAt = now
        lastClickCell = target

        switch clickCount {
        case 2:
            selection = expanded(target, in: frame, wordWise: true)
            // A word/line selection is finished the moment it is made. Leaving
            // the drag live would let the release's coordinate — which is the
            // click's own cell — collapse the word back to nothing.
            isDragging = false
        case 3:
            selection = expanded(target, in: frame, wordWise: false)
            isDragging = false
        default:
            // An empty selection: `isEmpty` is true until the pointer actually
            // moves, so a plain click paints nothing and copies nothing.
            selection = ScreenSelection(anchor: target, focus: target)
            isDragging = true
        }
        capture(frame)
    }

    /// Motion with the button held — move the focus. Ignored unless a drag is
    /// live, so a stray motion report cannot resurrect a finished selection.
    func drag(to cell: ScreenCell, frame: [String]) {
        guard isDragging, let existing = selection, !frame.isEmpty else { return }
        selection = ScreenSelection(anchor: existing.anchor, focus: clamp(cell, to: columns, frame: frame))
        capture(frame)
    }

    /// Left release — freeze the selection.
    ///
    /// A press and release in one cell with no motion leaves an EMPTY selection,
    /// which is cleared here: a plain click must not leave a phantom one-cell
    /// highlight behind, and must not make right-click copy one character.
    func release(at cell: ScreenCell, frame: [String]) {
        guard isDragging else { return }
        if let existing = selection, !frame.isEmpty {
            selection = ScreenSelection(anchor: existing.anchor, focus: clamp(cell, to: columns, frame: frame))
        }
        isDragging = false
        if selection?.isEmpty ?? true {
            clear()
            return
        }
        capture(frame)
    }

    func clear() {
        selection = nil
        isDragging = false
        capturedRows = [:]
        capturedHeight = 0
        capturedWidth = 0
        columns = 0..<0
    }

    /// Forget the click run, so the next press starts a fresh count.
    ///
    /// Called when something has moved the page out from under the pointer — a
    /// scroll — since a click at the same cell before and after a scroll is a
    /// click on two different pieces of text and must never expand to a word.
    func resetClickRun() {
        lastClickAt = .distantPast
        lastClickCell = nil
        clickCount = 0
    }

    // MARK: Validity

    /// Re-check the captured rows against the current frame, clearing the
    /// selection when any of them changed.
    ///
    /// - Returns: whether a selection survived. `true` when there was nothing to
    ///   check, so a caller can treat it as "nothing is wrong".
    @discardableResult
    func validate(against frame: [String]) -> Bool {
        guard selection != nil else { return true }
        // The page's shape first: a resize re-wraps every row, and a row count
        // or width that moved means the coordinates themselves are stale even if
        // some row's text happens to have survived.
        guard frame.count == capturedHeight, Self.width(of: frame) == capturedWidth else {
            clear()
            return false
        }
        for (row, text) in capturedRows {
            guard row >= 0, row < frame.count, strippingANSI(frame[row]) == text else {
                clear()
                return false
            }
        }
        return true
    }

    /// The frame with the selection highlighted, or the frame byte-identical.
    ///
    /// Byte-identical matters: `AltScreenCore`'s diff skips a row whose string
    /// did not change, so an unconditional rebuild here would repaint the whole
    /// page ten times a second.
    func decorate(_ frame: [String]) -> [String] {
        guard let selection, !selection.isEmpty, !frame.isEmpty else { return frame }
        return applySelectionHighlight(
            frame,
            selection: selection,
            columns: columns,
            width: Self.width(of: frame)
        )
    }

    /// The selection as plain text — no escapes, no trailing padding — or nil
    /// when there is nothing selected.
    func text(from frame: [String]) -> String? {
        guard let selection, !selection.isEmpty, !frame.isEmpty else { return nil }
        return selectionText(frame, selection: selection, columns: columns)
    }

    // MARK: Internals

    /// Every painted row is padded to the terminal width by `CellBuffer.flatten`,
    /// so row 0's visible width IS the page width. Measured rather than passed in
    /// so the controller needs no second copy of the terminal size to drift from.
    private static func width(of frame: [String]) -> Int {
        guard let first = frame.first else { return 0 }
        return visibleWidth(first)
    }

    private func clamp(_ cell: ScreenCell, to window: Range<Int>, frame: [String]) -> ScreenCell {
        let row = min(max(cell.row, 0), max(0, frame.count - 1))
        let lower = window.lowerBound
        // The upper bound is INCLUSIVE for a focus: a drag to the last column
        // must be able to select that column, and `columnSpan` is half-open, so
        // the focus is allowed to sit one past the last cell.
        let column = min(max(cell.column, lower), window.upperBound)
        return ScreenCell(row: row, column: column)
    }

    /// The word (or the whole row's content) under `cell`, as a selection in
    /// absolute screen columns.
    ///
    /// Computed on the PANE's slice of the row rather than on the whole row, so a
    /// word cannot run out of the transcript and into the sidebar, and so a
    /// triple-click starts at the pane's first column rather than at column 0 of
    /// the screen.
    private func expanded(_ cell: ScreenCell, in frame: [String], wordWise: Bool) -> ScreenSelection {
        guard cell.row >= 0, cell.row < frame.count else {
            return ScreenSelection(anchor: cell, focus: cell)
        }
        let lower = columns.lowerBound
        let slice = plainSliceByColumn(frame[cell.row], from: lower, to: columns.upperBound)
        let span: Range<Int>?
        if wordWise {
            span = wordColumnSpan(in: slice, atColumn: cell.column - lower)
        } else {
            let content = contentColumnSpan(in: slice)
            span = content.isEmpty ? nil : content
        }
        guard let span else { return ScreenSelection(anchor: cell, focus: cell) }
        let start = ScreenCell(row: cell.row, column: min(span.lowerBound + lower, columns.upperBound))
        let end = ScreenCell(row: cell.row, column: min(span.upperBound + lower, columns.upperBound))
        return ScreenSelection(anchor: start, focus: end)
    }

    private func capture(_ frame: [String]) {
        capturedRows = [:]
        capturedHeight = frame.count
        capturedWidth = Self.width(of: frame)
        guard let selection else { return }
        for row in selection.rows where row >= 0 && row < frame.count {
            capturedRows[row] = strippingANSI(frame[row])
        }
    }
}
