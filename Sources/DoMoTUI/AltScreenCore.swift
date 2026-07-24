// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/tui.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The full-screen (alternate-screen) sibling of `RenderCore`. It reuses every
// piece of the inline diff that is mode-independent — cursor-marker extraction,
// per-line resets, terminal-output normalization, the fatal-width invariant, the
// first/last-changed scan, the `\x1b[2K` clear-then-rewrite primitive, and the
// CSI ?2026 synchronized-output wrapper — and swaps out the one thing that is
// mode-specific: RELATIVE cursor motion becomes ABSOLUTE CUP addressing. With
// that swap the whole family of scroll/viewport bookkeeping RenderCore carries
// (previous viewport top, high-water line count, transcript-scroll and
// appended-line branches) becomes dead weight and is excised: on the alternate
// screen the viewport IS the buffer, the row count is constant, and nothing ever
// scrolls.

import DoMoCore

// MARK: - AltScreenCore

/// The pure differential diff for a FIXED-HEIGHT alternate-screen frame:
/// `(previous rows, bookkeeping) + new rows -> the exact bytes to emit`, with no
/// timer, no terminal, and no I/O. The sibling of ``RenderCore``.
///
/// The alternate screen buffer (entered with `?1049h`) is a full page with no
/// scrollback: the caller composes exactly `height` rows — typically via a
/// ``CellBuffer`` — and this core paints them. Because the viewport equals the
/// buffer, every row has a fixed absolute position, so each changed span is
/// addressed with a CUP (`\x1b[row;colH`) instead of the relative
/// up/down/carriage-return motion the inline renderer threads against a moving
/// hardware-cursor row. That single substitution is why none of RenderCore's
/// scroll-vs-clamp machinery survives here: there is nowhere to scroll to.
///
/// Three strategies, the alt-screen analogues of RenderCore's:
///  1. **First render** — place every row by CUP, no clear (the alt buffer is
///     freshly cleared by `?1049h`).
///  2. **Full redraw** — `\x1b[2J` (screen only; `\x1b[3J` scrollback-clear is
///     meaningless and harmful in the alt buffer, and is dropped) then place
///     every row by CUP, on a width or height change (a resize repaints all rows
///     at the new size) or a forced redraw.
///  3. **Normal update** — CUP to the first changed row, then `\x1b[2K` + rewrite
///     for the contiguous changed span, each row re-addressed with its own CUP so
///     no relative motion is ever emitted.
///
/// Every frame is wrapped in CSI 2026 synchronized output. Every emitted row is
/// width-checked; an over-wide row throws ``DoMoError`` (never a `precondition`).
/// A pure value type, so a test can drive frame after frame straight into the
/// screen-state oracle.
public struct AltScreenCore {
    /// The full SGR + OSC-8-close reset appended to every emitted row, shared with
    /// the inline renderer so styling cannot bleed past a row's end.
    static let segmentReset = RenderCore.segmentReset

    // Bookkeeping — the state the diff reads and updates across frames. No
    // viewport/scroll state: on the alt screen the viewport is the whole buffer.
    var previousLines: [String] = []
    var previousWidth = 0
    var previousHeight = 0
    private(set) var fullRedrawCount = 0

    /// Move the real cursor to the caret (IME) position each frame.
    public var showHardwareCursor: Bool

    public init(showHardwareCursor: Bool = false) {
        self.showHardwareCursor = showHardwareCursor
    }

    /// How many full redraws have happened — the metric a test asserts against to
    /// prove the diff took the incremental CUP path, not the sledgehammer.
    public var fullRedraws: Int { fullRedrawCount }

    /// Reset all bookkeeping so the next frame is a forced full redraw. The
    /// alternate-screen analogue of ``RenderCore/forceFullRedraw()``; the `-1`
    /// sentinels make the width/height-changed guards fire and clear.
    public mutating func forceFullRedraw() {
        previousLines = []
        previousWidth = -1
        previousHeight = -1
    }

    // MARK: Cursor marker & line resets (mirrors RenderCore)

    /// Find ``cursorMarker`` in the buffer, strip it, and return its `(row, col)`.
    /// Scans the bottom `height` rows bottom-up; with viewport == buffer the scan
    /// covers the whole frame.
    mutating func extractCursorPosition(_ lines: inout [String], height: Int) -> (row: Int, col: Int)? {
        let viewportTop = max(0, lines.count - height)
        var row = lines.count - 1
        while row >= viewportTop {
            let line = lines[row]
            if let markerRange = line.range(of: cursorMarker) {
                let beforeMarker = String(line[line.startIndex..<markerRange.lowerBound])
                let col = visibleWidth(beforeMarker)
                lines[row] = beforeMarker + String(line[markerRange.upperBound...])
                return (row, col)
            }
            row -= 1
        }
        return nil
    }

    /// Append the per-line reset to every row (after normalization). Mirrors
    /// ``RenderCore``'s `applyLineResets`.
    func applyLineResets(_ lines: [String]) -> [String] {
        lines.map { normalizeTerminalOutput($0) + AltScreenCore.segmentReset }
    }

    // MARK: Absolute addressing

    /// A CUP to the zero-based `(row, col)`: `\x1b[row+1;col+1H`. The one motion
    /// primitive of the alt-screen renderer — every row is placed at its fixed
    /// absolute position, never relative to where the cursor last landed.
    private func cursorTo(row: Int, col: Int) -> String {
        "\u{1b}[\(row + 1);\(col + 1)H"
    }

    /// Park the real cursor at the caret with an absolute CUP, then show/hide it.
    /// The alt-screen analogue of ``RenderCore/positionHardwareCursor(_:totalLines:)``
    /// with the relative row delta replaced by a CUP — so no `hardwareCursorRow`
    /// needs tracking.
    private func positionHardwareCursor(_ cursorPos: (row: Int, col: Int)?, totalLines: Int) -> String {
        guard let cursorPos, totalLines > 0 else {
            return "\u{1b}[?25l"
        }
        let targetRow = max(0, min(cursorPos.row, totalLines - 1))
        let targetCol = max(0, cursorPos.col)
        var buffer = cursorTo(row: targetRow, col: targetCol)
        buffer += showHardwareCursor ? "\u{1b}[?25h" : "\u{1b}[?25l"
        return buffer
    }

    // MARK: Full render

    /// Place every row by CUP. `clear` emits `\x1b[2J` first (screen only — never
    /// `\x1b[3J`, which would clobber scrollback the alt buffer does not own).
    private mutating func fullRender(
        clear: Bool,
        newLines: [String],
        width: Int,
        height: Int,
        cursorPos: (row: Int, col: Int)?
    ) -> String {
        fullRedrawCount += 1
        var buffer = "\u{1b}[?2026h" // Begin synchronized output
        if clear {
            buffer += "\u{1b}[2J" // Clear the alt-screen page (no scrollback clear)
        }
        for i in newLines.indices {
            buffer += cursorTo(row: i, col: 0)
            buffer += newLines[i]
        }
        buffer += "\u{1b}[?2026l" // End synchronized output
        buffer += positionHardwareCursor(cursorPos, totalLines: newLines.count)
        previousLines = newLines
        previousWidth = width
        previousHeight = height
        return buffer
    }

    // MARK: The diff

    /// Compute the bytes for one alt-screen frame. `rawLines` are the composed
    /// rows (base content with any overlays already merged in), *before* cursor
    /// extraction and line resets — the core does both, so its behaviour is
    /// identical whether driven by a live coordinator or straight from a test.
    ///
    /// The caller guarantees exactly `height` rows (viewport == buffer); a
    /// ``CellBuffer``'s ``CellBuffer/flatten()`` produces exactly that.
    ///
    /// - Parameter hasOverlays: accepted for signature-parity with
    ///   ``RenderCore/frame(lines:width:height:hasOverlays:)``. There is no
    ///   shrink-clear path on a constant-height buffer, so it currently changes
    ///   nothing; it is kept so a caller can swap the two cores without edits.
    public mutating func frame(
        lines rawLines: [String],
        width: Int,
        height: Int,
        hasOverlays: Bool = false
    ) throws(DoMoError) -> String {
        _ = hasOverlays
        var newLines = rawLines
        let cursorPos = extractCursorPosition(&newLines, height: height)
        newLines = applyLineResets(newLines)

        // Fatal-width invariant, checked ONCE for every strategy — the whole-frame
        // net that covers the full-redraw paths as well as the incremental one. An
        // over-wide row shifts every following column; throw a catchable DoMoError
        // rather than trapping in release.
        for i in newLines.indices {
            let lineWidth = visibleWidth(newLines[i])
            if lineWidth > width {
                throw AltScreenCore.overWide(row: i, measured: lineWidth, width: width)
            }
        }

        let widthChanged = previousWidth != 0 && previousWidth != width
        let heightChanged = previousHeight != 0 && previousHeight != height

        // Strategy 1: first render — place everything, the alt buffer is clean.
        if previousLines.isEmpty, !widthChanged, !heightChanged {
            return fullRender(clear: false, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }
        // Strategy 2a: width change — wrapping changes, repaint all rows.
        if widthChanged {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }
        // Strategy 2b: height change — repaint all rows at the new height.
        if heightChanged {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }

        // Find the first and last changed rows. The row count is constant
        // (viewport == buffer), so there is no appended-row path to consider.
        var firstChanged = -1
        var lastChanged = -1
        let maxLines = max(newLines.count, previousLines.count)
        for i in 0..<maxLines {
            let oldLine = i < previousLines.count ? previousLines[i] : ""
            let newLine = i < newLines.count ? newLines[i] : ""
            if oldLine != newLine {
                if firstChanged == -1 { firstChanged = i }
                lastChanged = i
            }
        }

        // No changes — only the hardware cursor may need repositioning.
        if firstChanged == -1 {
            let buffer = positionHardwareCursor(cursorPos, totalLines: newLines.count)
            previousWidth = width
            previousHeight = height
            return buffer
        }

        // Strategy 3: normal differential update. Rewrite the contiguous changed
        // span, each row re-addressed with an absolute CUP + `\x1b[2K` clear, so no
        // relative motion is ever emitted and no unchanged row is touched outside
        // the span.
        var buffer = "\u{1b}[?2026h"
        let renderEnd = min(lastChanged, newLines.count - 1)
        for i in firstChanged...renderEnd {
            let line = newLines[i]
            let lineWidth = visibleWidth(line)
            if lineWidth > width {
                throw AltScreenCore.overWide(row: i, measured: lineWidth, width: width)
            }
            buffer += cursorTo(row: i, col: 0)
            buffer += "\u{1b}[2K" // Clear the row before rewriting it
            buffer += line
        }
        buffer += "\u{1b}[?2026l"
        buffer += positionHardwareCursor(cursorPos, totalLines: newLines.count)

        previousLines = newLines
        previousWidth = width
        previousHeight = height
        return buffer
    }

    /// The fatal over-wide-row error, shared by the whole-frame and per-span
    /// checks. Byte-identical message to ``RenderCore``'s.
    private static func overWide(row: Int, measured: Int, width: Int) -> DoMoError {
        DoMoError(
            .malformedResponse,
            "Rendered line \(row) exceeds terminal width (\(measured) > \(width)). "
                + "A component did not truncate its output; measure with visibleWidth() "
                + "and clip with truncateToWidth()."
        )
    }
}
