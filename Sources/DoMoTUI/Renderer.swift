// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/tui.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. `RenderCore` ports `TUI.doRender`
// and its diff bookkeeping verbatim; the Kitty-image handling is dropped (no
// image pipeline exists yet), which collapses pi's image-reserved-row loops to
// single-line handling and removes the `previousKittyImageIds` tracking.

import DoMoCore
import DoMoTermIO
import Foundation

// MARK: - Terminal output normalization

private nonisolated let thaiLaoAmScalars: Set<Unicode.Scalar> = ["\u{0e33}", "\u{0eb3}"]

/// Normalize a line for terminal output without changing its logical content.
///
/// Ported from `utils.ts`'s `normalizeTerminalOutput`. Two fixes travel together:
/// precomposed Thai/Lao AM vowels are swapped for their same-width compatibility
/// decompositions (some terminals leave stale cells otherwise during a repaint),
/// and literal tabs are expanded to the fixed layout width so a terminal's own
/// tab stops cannot wrap a line the layout believed was narrower. Tabs *inside*
/// escape sequences are left untouched.
nonisolated func normalizeTerminalOutput(_ string: String) -> String {
    var normalized = string
    if normalized.unicodeScalars.contains(where: { thaiLaoAmScalars.contains($0) }) {
        var swapped = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\u{0e33}" {
                swapped.append("\u{0e4d}"); swapped.append("\u{0e32}")
            } else if scalar == "\u{0eb3}" {
                swapped.append("\u{0ecd}"); swapped.append("\u{0eb2}")
            } else {
                swapped.append(scalar)
            }
        }
        normalized = String(swapped)
    }
    guard normalized.contains("\t") else { return normalized }

    let chars = Array(normalized)
    var result = ""
    var i = 0
    while i < chars.count {
        if let ansi = extractAnsiCode(chars, i) {
            result += ansi.code
            i += ansi.length
            continue
        }
        result += chars[i] == "\t" ? "   " : String(chars[i])
        i += 1
    }
    return result
}

// MARK: - RenderCore

/// The pure differential diff: `(previous lines, bookkeeping) + new lines -> the
/// exact bytes to emit`, with no timer, no terminal, and no I/O.
///
/// This is the heart of the inline renderer and the reason it is testable. pi's
/// `doRender` interleaves the diff with terminal writes and scheduling; splitting
/// the diff out into a value type lets a test drive frame after frame straight
/// into the screen-state oracle and assert the resulting cell grid — including
/// the scroll-vs-clamp distinction that a byte-recording harness cannot see.
///
/// The three strategies are pi's, unchanged:
///  1. **First render** — emit every line, no clear (the screen is assumed clean).
///  2. **Full redraw** — `\x1b[2J\x1b[H\x1b[3J` then everything, on a width
///     change, a height change, a shrink below the working area (when enabled),
///     or a change above the previous viewport.
///  3. **Normal update** — relative cursor motion + `\x1b[2K` + rewrite of only
///     the changed span, scrolling the transcript with `\r\n` when the change
///     falls past the viewport bottom, then clearing any trailing deleted lines.
///
/// Every frame is wrapped in CSI 2026 synchronized output and returned as one
/// string. Every emitted content line is width-checked; an over-wide line throws
/// ``DoMoError`` (never a `precondition`) so the caller can log and stop instead
/// of trapping in release.
public struct RenderCore {
    /// The full SGR + OSC-8-close reset appended to every emitted line so styling
    /// cannot bleed past a line's end. Byte-identical to pi's `SEGMENT_RESET`.
    static let segmentReset = "\u{1b}[0m\u{1b}]8;;\u{07}"

    // Bookkeeping — the state the diff reads and updates across frames.
    var previousLines: [String] = []
    var previousWidth = 0
    var previousHeight = 0
    var cursorRow = 0
    var hardwareCursorRow = 0
    var maxLinesRendered = 0
    var previousViewportTop = 0
    private(set) var fullRedrawCount = 0

    /// Move the real cursor to the caret (IME) position each frame.
    public var showHardwareCursor: Bool
    /// Full-redraw to clear vacated rows when content shrinks below its high-water
    /// mark. Off by default (matches pi's `PI_CLEAR_ON_SHRINK` default of off).
    public var clearOnShrink: Bool

    public init(showHardwareCursor: Bool = false, clearOnShrink: Bool = false) {
        self.showHardwareCursor = showHardwareCursor
        self.clearOnShrink = clearOnShrink
    }

    /// How many full redraws have happened — the metric pi exposes for tests that
    /// assert the diff took the incremental path, not the sledgehammer.
    public var fullRedraws: Int { fullRedrawCount }

    /// Reset all bookkeeping so the next frame is treated as a first render with a
    /// forced clear. Ports the `requestRender(force = true)` state reset.
    public mutating func forceFullRedraw() {
        previousLines = []
        previousWidth = -1
        previousHeight = -1
        cursorRow = 0
        hardwareCursorRow = 0
        maxLinesRendered = 0
        previousViewportTop = 0
    }

    // MARK: Cursor marker & line resets

    /// Find ``cursorMarker`` in the visible viewport, strip it, and return its
    /// `(row, col)`. Scans only the bottom `height` lines, bottom-up, like pi.
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

    /// Append the per-line reset to every line (after normalization). Ports
    /// `applyLineResets` sans the image guard, since no line is ever an image.
    func applyLineResets(_ lines: [String]) -> [String] {
        lines.map { normalizeTerminalOutput($0) + RenderCore.segmentReset }
    }

    // MARK: Full render

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
            buffer += "\u{1b}[2J\u{1b}[H\u{1b}[3J" // Clear screen, home, clear scrollback
        }
        for i in newLines.indices {
            if i > 0 { buffer += "\r\n" }
            buffer += newLines[i]
        }
        buffer += "\u{1b}[?2026l" // End synchronized output
        cursorRow = max(0, newLines.count - 1)
        hardwareCursorRow = cursorRow
        if clear {
            maxLinesRendered = newLines.count
        } else {
            maxLinesRendered = max(maxLinesRendered, newLines.count)
        }
        let bufferLength = max(height, newLines.count)
        previousViewportTop = max(0, bufferLength - height)
        buffer += positionHardwareCursor(cursorPos, totalLines: newLines.count)
        previousLines = newLines
        previousWidth = width
        previousHeight = height
        return buffer
    }

    // MARK: Hardware cursor

    /// Emit the relative motion that parks the real cursor at the caret, and the
    /// show/hide that follows. Ports `positionHardwareCursor`; the terminal's
    /// `hideCursor`/`showCursor` become the DEC private-mode sequences.
    mutating func positionHardwareCursor(_ cursorPos: (row: Int, col: Int)?, totalLines: Int) -> String {
        guard let cursorPos, totalLines > 0 else {
            return "\u{1b}[?25l"
        }
        let targetRow = max(0, min(cursorPos.row, totalLines - 1))
        let targetCol = max(0, cursorPos.col)
        let rowDelta = targetRow - hardwareCursorRow
        var buffer = ""
        if rowDelta > 0 {
            buffer += "\u{1b}[\(rowDelta)B"
        } else if rowDelta < 0 {
            buffer += "\u{1b}[\(-rowDelta)A"
        }
        buffer += "\u{1b}[\(targetCol + 1)G"
        hardwareCursorRow = targetRow
        buffer += showHardwareCursor ? "\u{1b}[?25h" : "\u{1b}[?25l"
        return buffer
    }

    // MARK: The diff

    /// Compute the bytes for one frame. `rawLines` are the composited component
    /// lines (base content with any overlays already merged in), *before* cursor
    /// extraction and line resets — the core does both so its behaviour is
    /// identical whether driven by the live `TUI` or straight from a test.
    ///
    /// - Parameter hasOverlays: whether any overlay is on the stack; suppresses
    ///   the shrink-clear path, which would fight the padding overlays rely on.
    public mutating func frame(
        lines rawLines: [String],
        width: Int,
        height: Int,
        hasOverlays: Bool = false
    ) throws(DoMoError) -> String {
        var newLines = rawLines
        let cursorPos = extractCursorPosition(&newLines, height: height)
        newLines = applyLineResets(newLines)

        // Fatal-width invariant, checked ONCE for every strategy. An over-wide
        // line shifts every following column, so pi dumps a crash log, stops, and
        // throws; we throw a catchable DoMoError rather than trapping in release.
        // Validating the whole frame here — not just the incremental rewrite loop
        // below — means the full-redraw paths (first render, width/height change,
        // shrink) are covered too, so this is the renderer's real safety net
        // against a component that failed to truncate its output.
        for i in newLines.indices {
            let lineWidth = visibleWidth(newLines[i])
            if lineWidth > width {
                throw DoMoError(
                    .malformedResponse,
                    "Rendered line \(i) exceeds terminal width (\(lineWidth) > \(width)). "
                        + "A component did not truncate its output; measure with visibleWidth() "
                        + "and clip with truncateToWidth()."
                )
            }
        }

        let widthChanged = previousWidth != 0 && previousWidth != width
        let heightChanged = previousHeight != 0 && previousHeight != height
        let previousBufferLength = previousHeight > 0 ? previousViewportTop + previousHeight : height
        var prevViewportTop = heightChanged ? max(0, previousBufferLength - height) : previousViewportTop
        var viewportTop = prevViewportTop
        var hardwareCursorRow = self.hardwareCursorRow
        func computeLineDiff(_ targetRow: Int) -> Int {
            let currentScreenRow = hardwareCursorRow - prevViewportTop
            let targetScreenRow = targetRow - viewportTop
            return targetScreenRow - currentScreenRow
        }

        // Strategy 1: first render — emit everything, assume a clean screen.
        if previousLines.isEmpty, !widthChanged, !heightChanged {
            return fullRender(clear: false, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }
        // Strategy 2a: width change — wrapping changes, so redraw everything.
        if widthChanged {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }
        // Strategy 2b: height change — keep the viewport aligned with a full redraw.
        // (pi keeps an incremental path for Termux keyboard toggles; not ported.)
        if heightChanged {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }
        // Strategy 2c: content shrank below the working area — clear vacated rows.
        if clearOnShrink, newLines.count < maxLinesRendered, !hasOverlays {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }

        // Find the first and last changed lines.
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
        let appendedLines = newLines.count > previousLines.count
        if appendedLines {
            if firstChanged == -1 { firstChanged = previousLines.count }
            lastChanged = newLines.count - 1
        }
        let appendStart = appendedLines && firstChanged == previousLines.count && firstChanged > 0

        // No changes — only the hardware cursor may need repositioning.
        if firstChanged == -1 {
            let buffer = positionHardwareCursor(cursorPos, totalLines: newLines.count)
            previousViewportTop = prevViewportTop
            previousHeight = height
            return buffer
        }

        // All changes are in deleted (trailing) lines — clear them, render nothing.
        if firstChanged >= newLines.count {
            var buffer = ""
            if previousLines.count > newLines.count {
                buffer = "\u{1b}[?2026h"
                let targetRow = max(0, newLines.count - 1)
                if targetRow < prevViewportTop {
                    return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
                }
                let lineDiff = computeLineDiff(targetRow)
                if lineDiff > 0 { buffer += "\u{1b}[\(lineDiff)B" } else if lineDiff < 0 { buffer += "\u{1b}[\(-lineDiff)A" }
                buffer += "\r"
                let extraLines = previousLines.count - newLines.count
                if extraLines > height {
                    return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
                }
                let clearStartOffset = newLines.count == 0 ? 0 : 1
                if extraLines > 0, clearStartOffset > 0 { buffer += "\u{1b}[\(clearStartOffset)B" }
                for i in 0..<extraLines {
                    buffer += "\r\u{1b}[2K"
                    if i < extraLines - 1 { buffer += "\u{1b}[1B" }
                }
                let moveBack = max(0, extraLines - 1 + clearStartOffset)
                if moveBack > 0 { buffer += "\u{1b}[\(moveBack)A" }
                buffer += "\u{1b}[?2026l"
                cursorRow = targetRow
                self.hardwareCursorRow = targetRow
            }
            buffer += positionHardwareCursor(cursorPos, totalLines: newLines.count)
            previousLines = newLines
            previousWidth = width
            previousHeight = height
            previousViewportTop = prevViewportTop
            return buffer
        }

        // The first change is above the previous viewport — can't reach it with a
        // relative move, so redraw everything.
        if firstChanged < prevViewportTop {
            return fullRender(clear: true, newLines: newLines, width: width, height: height, cursorPos: cursorPos)
        }

        // Strategy 3: normal differential update.
        var buffer = "\u{1b}[?2026h"
        let prevViewportBottom = prevViewportTop + height - 1
        let moveTargetRow = appendStart ? firstChanged - 1 : firstChanged
        if moveTargetRow > prevViewportBottom {
            // The change is below the viewport bottom: scroll the transcript up by
            // emitting real newlines at the bottom row (never a clamped cursor-down).
            let currentScreenRow = max(0, min(height - 1, hardwareCursorRow - prevViewportTop))
            let moveToBottom = height - 1 - currentScreenRow
            if moveToBottom > 0 { buffer += "\u{1b}[\(moveToBottom)B" }
            let scroll = moveTargetRow - prevViewportBottom
            buffer += String(repeating: "\r\n", count: scroll)
            prevViewportTop += scroll
            viewportTop += scroll
            hardwareCursorRow = moveTargetRow
        }

        let lineDiff = computeLineDiff(moveTargetRow)
        if lineDiff > 0 { buffer += "\u{1b}[\(lineDiff)B" } else if lineDiff < 0 { buffer += "\u{1b}[\(-lineDiff)A" }
        buffer += appendStart ? "\r\n" : "\r"

        // Rewrite only firstChanged..renderEnd, not everything to the end.
        let renderEnd = min(lastChanged, newLines.count - 1)
        for i in firstChanged...renderEnd {
            if i > firstChanged { buffer += "\r\n" }
            let line = newLines[i]
            buffer += "\u{1b}[2K" // Clear current line
            let lineWidth = visibleWidth(line)
            if lineWidth > width {
                // FATAL: an over-wide line shifts every following column. pi dumps
                // a crash log, stops, and throws; we throw a catchable DoMoError
                // rather than trapping in release.
                throw DoMoError(
                    .malformedResponse,
                    "Rendered line \(i) exceeds terminal width (\(lineWidth) > \(width)). "
                        + "A component did not truncate its output; measure with visibleWidth() "
                        + "and clip with truncateToWidth()."
                )
            }
            buffer += line
        }

        var finalCursorRow = renderEnd
        // Clear any lines the previous frame had that this one does not.
        if previousLines.count > newLines.count {
            if renderEnd < newLines.count - 1 {
                let moveDown = newLines.count - 1 - renderEnd
                buffer += "\u{1b}[\(moveDown)B"
                finalCursorRow = newLines.count - 1
            }
            let extraLines = previousLines.count - newLines.count
            for _ in newLines.count..<previousLines.count {
                buffer += "\r\n\u{1b}[2K"
            }
            buffer += "\u{1b}[\(extraLines)A"
        }
        buffer += "\u{1b}[?2026l"

        cursorRow = max(0, newLines.count - 1)
        self.hardwareCursorRow = finalCursorRow
        maxLinesRendered = max(maxLinesRendered, newLines.count)
        previousViewportTop = max(prevViewportTop, finalCursorRow - height + 1)
        buffer += positionHardwareCursor(cursorPos, totalLines: newLines.count)

        previousLines = newLines
        previousWidth = width
        previousHeight = height
        return buffer
    }
}

// MARK: - RenderTarget

/// The sink a live ``TUI`` writes frames to, and the size it renders against.
///
/// Deliberately tiny: the renderer folds cursor show/hide and every escape into
/// the frame string it hands to ``write(_:)``, so a target only has to report a
/// size and accept bytes. This keeps the renderer decoupled from the POSIX
/// terminal lifecycle (which arrives with the interactive-CLI wiring) and lets a
/// test drive the whole pipeline with an in-memory capture.
public protocol RenderTarget: AnyObject {
    var columns: Int { get }
    var rows: Int { get }
    func write(_ bytes: String)
}

// MARK: - TUI

/// The live inline renderer: a ``Container`` root that owns a ``RenderCore``, an
/// overlay stack, focus, and the render-coalescing scheduler.
///
/// `TUI` composes overlays into the base line array, runs the diff, and writes
/// the result to its ``RenderTarget``. The diff itself lives in ``RenderCore`` so
/// it can be tested without any of this; `TUI` adds only the parts that need a
/// terminal and a clock — overlay compositing, focus, input dispatch, and the
/// coalescing throttle.
@MainActor
public final class TUI: Container {
    let target: any RenderTarget
    var core: RenderCore

    // Overlay + focus state (methods live in Overlay.swift).
    var focusedComponent: Component?
    var focusOrderCounter = 0
    var overlayStack: [OverlayStackEntry] = []
    var overlayFocusRestore: OverlayFocusRestoreState = .inactive

    // Render scheduling.
    private var renderRequested = false
    private var renderScheduled = false
    private var stopped = false
    private static let minRenderIntervalMS = 16.0
    private var lastRenderAt = Date.distantPast

    /// Called if a scheduled render throws (an over-wide line). The synchronous
    /// ``renderSync()`` throws directly instead.
    public var onRenderError: ((DoMoError) -> Void)?

    public init(target: any RenderTarget, showHardwareCursor: Bool = false, clearOnShrink: Bool = false) {
        self.target = target
        self.core = RenderCore(showHardwareCursor: showHardwareCursor, clearOnShrink: clearOnShrink)
        super.init()
    }

    /// How many full redraws the diff has taken.
    public var fullRedraws: Int { core.fullRedraws }

    /// Whether the focused component is a game-style consumer of key releases.
    var focusedWantsKeyRelease: Bool { focusedComponent?.wantsKeyRelease ?? false }

    public override func invalidate() {
        super.invalidate()
        for overlay in overlayStack { overlay.component.invalidate() }
    }

    // MARK: Rendering

    /// Render one frame synchronously and write it. Throws on an over-wide line.
    ///
    /// This is the timer-free entry the oracle drives: compose overlays, run the
    /// diff, write the bytes. ``requestRender()`` is the coalescing wrapper around
    /// it for live use.
    public func renderSync() throws(DoMoError) {
        guard !stopped else { return }
        let width = target.columns
        let height = target.rows
        var lines = render(width: width)
        if !overlayStack.isEmpty {
            lines = compositeOverlays(lines, termWidth: width, termHeight: height)
        }
        let bytes = try core.frame(lines: lines, width: width, height: height, hasOverlays: !overlayStack.isEmpty)
        target.write(bytes)
        lastRenderAt = Date()
    }

    /// Force the next frame to be a full clear+redraw (theme change, resize).
    public func requestFullRedraw() {
        core.forceFullRedraw()
        requestRender()
    }

    /// Coalesce a render request. Multiple calls in one turn collapse to a single
    /// frame, throttled to ``minRenderIntervalMS``. Ports pi's
    /// `requestRender`/`scheduleRender` (nextTick + 16 ms) onto the main-actor
    /// clock. The diff itself is untouched — this only decides *when* to run it.
    public func requestRender() {
        guard !stopped else { return }
        renderRequested = true
        scheduleRender()
    }

    private func scheduleRender() {
        guard !stopped, !renderScheduled, renderRequested else { return }
        renderScheduled = true
        let elapsed = Date().timeIntervalSince(lastRenderAt) * 1000
        let delay = max(0, TUI.minRenderIntervalMS - elapsed) / 1000
        let deadline = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard !self.stopped, self.renderRequested else { return }
            self.renderRequested = false
            do {
                try self.renderSync()
            } catch let error as DoMoError {
                self.onRenderError?(error)
                return
            } catch {
                return
            }
            if self.renderRequested { self.scheduleRender() }
        }
    }

    /// Stop scheduling further frames.
    public func stop() {
        stopped = true
    }

    // MARK: Input

    /// Dispatch framed input bytes to the focused component.
    ///
    /// Ports the focus-visibility revalidation, the overlay focus-restore
    /// transition, and the key-release filter from `TUI.handleInput`. Key decoding
    /// stays in the component (which consults `Keybindings`); the renderer only
    /// routes bytes and, on any handled input, requests a render.
    public func handleInput(_ data: [UInt8]) {
        revalidateFocusedOverlayVisibility()
        applyOverlayFocusRestoreOnInput()

        guard let focused = focusedComponent else { return }
        // Filter out Kitty key-release events unless the component opts in, using
        // DoMoTermIO's `isKeyRelease` — the renderer never decodes keys itself.
        if isKeyRelease(data), !focused.wantsKeyRelease { return }
        focused.handleInput(data)
        requestRender()
    }
}
