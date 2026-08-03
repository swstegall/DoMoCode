// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The normal-screen split-footer renderer. It deliberately keeps the terminal
// as the owner of transcript history: the upper DECSTBM region receives appended
// lines, while the footer is redrawn by absolute CUP below that region.

import DoMoCore
import DoMoTermGraphics
import DoMoTermIO

/// A differential renderer for a normal terminal with a pinned footer.
///
/// The input is the same flattened component line array as RenderCore, with the
/// final footerRows lines belonging to the status/prompt footer. Appends take
/// the terminal's scrolling path; a mutation of an earlier transcript line
/// falls back to repainting the visible scroll region without clearing
/// scrollback. This is what makes the mode useful for shell selection: old
/// transcript is never hidden in an alternate buffer.
public struct SplitFooterCore {
    private var previousTranscript: [String] = []
    private var previousFooter: [String] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var previousFooterRows = 0
    private var hasRendered = false
    private let lineRenderer = RenderCore()
    private(set) var fullRedrawCount = 0

    public init() {}

    /// How many non-incremental visible-region repaints have occurred.
    public var fullRedraws: Int { fullRedrawCount }

    /// Reset state so the next frame establishes a fresh split.
    public mutating func forceFullRedraw() {
        previousTranscript = []
        previousFooter = []
        previousWidth = -1
        previousHeight = -1
        previousFooterRows = 0
        hasRendered = false
    }

    /// Pad the transcript before its footer so overlay geometry remains
    /// screen-relative while the footer still occupies the bottom rows.
    public static func paddedLines(
        _ lines: [String],
        footerRows requestedFooterRows: Int,
        height: Int
    ) -> [String] {
        let footerRows = normalizedFooterRows(requestedFooterRows, height: height)
        let footerStart = max(0, lines.count - footerRows)
        let transcript = Array(lines[..<footerStart])
        var footer = footerStart < lines.count
            ? Array(lines[footerStart...])
            : Array(repeating: "", count: footerRows)
        if footer.count < footerRows {
            footer.append(contentsOf: Array(repeating: "", count: footerRows - footer.count))
        }
        let transcriptHeight = max(0, height - footerRows)
        guard transcript.count < transcriptHeight else { return lines }
        return Array(repeating: "", count: transcriptHeight - transcript.count)
            + transcript
            + footer
    }

    /// Produce one terminal frame.
    public mutating func frame(
        lines rawLines: [String],
        width: Int,
        height: Int,
        footerRows requestedFooterRows: Int,
        hasOverlays: Bool = false
    ) throws(DoMoError) -> String {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let footerRows = Self.normalizedFooterRows(requestedFooterRows, height: safeHeight)

        var lines = rawLines
        let cursor = extractCursor(&lines, footerRows: footerRows, height: safeHeight)
        let footerStart = max(0, lines.count - footerRows)
        let transcript = Array(lines[..<footerStart])
        var footer = footerStart < lines.count
            ? Array(lines[footerStart...])
            : Array(repeating: "", count: footerRows)
        if footer.count < footerRows {
            footer.append(contentsOf: Array(repeating: "", count: footerRows - footer.count))
        }
        let visibleTranscript = visibleTranscriptLines(
            transcript,
            rows: max(0, safeHeight - footerRows)
        )
        let renderedTranscript = try validateAndReset(
            visibleTranscript,
            width: safeWidth,
            label: "transcript"
        )
        let renderedFooter = try validateAndReset(footer, width: safeWidth, label: "footer")

        let widthChanged = previousWidth > 0 && previousWidth != safeWidth
        let heightChanged = previousHeight > 0 && previousHeight != safeHeight
        let footerChanged = previousFooterRows != footerRows || previousFooter != renderedFooter
        let transcriptAppend = isStrictAppend(from: previousTranscript, to: transcript)
        let transcriptChanged = previousTranscript != transcript
        let mustRepaint = !hasRendered
            || widthChanged
            || heightChanged
            || previousFooterRows != footerRows
            || hasOverlays
            || (transcriptChanged && !transcriptAppend)

        var bytes = "\u{1b}[?2026h"
        bytes += "\u{1b}[1;\(max(1, safeHeight - footerRows))r"
        if mustRepaint {
            fullRedrawCount += 1
            bytes += "\u{1b}[2J\u{1b}[H"
            bytes += drawTranscript(renderedTranscript)
            bytes += drawFooter(
                renderedFooter,
                footerTop: max(1, safeHeight - footerRows + 1)
            )
        } else {
            if transcriptAppend {
                bytes += appendTranscript(
                    renderedTranscript,
                    oldCount: previousTranscript.count,
                    newCount: transcript.count,
                    scrollBottom: max(1, safeHeight - footerRows)
                )
            }
            if footerChanged {
                bytes += drawFooter(
                    renderedFooter,
                    footerTop: max(1, safeHeight - footerRows + 1)
                )
            }
        }
        bytes += positionCursor(cursor, height: safeHeight)
        bytes += "\u{1b}[?2026l"

        previousTranscript = transcript
        previousFooter = renderedFooter
        previousWidth = safeWidth
        previousHeight = safeHeight
        previousFooterRows = footerRows
        hasRendered = true
        return bytes
    }

    // MARK: Layout and validation

    private static func normalizedFooterRows(_ requested: Int, height: Int) -> Int {
        let safeHeight = max(1, height)
        return min(safeHeight, max(1, requested))
    }

    private func visibleTranscriptLines(_ lines: [String], rows: Int) -> [String] {
        guard rows > 0 else { return [] }
        if lines.count >= rows {
            return Array(lines.suffix(rows))
        }
        return Array(repeating: "", count: rows - lines.count) + lines
    }

    private func validateAndReset(
        _ lines: [String],
        width: Int,
        label: String
    ) throws(DoMoError) -> [String] {
        let resetLines = lineRenderer.applyLineResets(lines)
        for (index, line) in resetLines.enumerated() {
            if isImageLine(line) { continue }
            let lineWidth = visibleWidth(line)
            if lineWidth > width {
                throw DoMoError(
                    .malformedResponse,
                    "Rendered \(label) line \(index) exceeds terminal width (\(lineWidth) > \(width))."
                )
            }
        }
        return resetLines
    }

    private func isStrictAppend(from old: [String], to new: [String]) -> Bool {
        guard new.count > old.count else { return false }
        return new.indices.contains(old.count)
            && Array(new.prefix(old.count)) == old
    }

    // MARK: Cursor marker

    private struct Cursor {
        var row: Int
        var column: Int
    }

    private func extractCursor(
        _ lines: inout [String],
        footerRows: Int,
        height: Int
    ) -> Cursor? {
        guard !lines.isEmpty else { return nil }
        let start = max(0, lines.count - footerRows)
        let bottom = lines.count
        for index in stride(from: bottom - 1, through: start, by: -1) {
            guard let marker = lines[index].range(of: cursorMarker) else { continue }
            let before = String(lines[index][..<marker.lowerBound])
            let after = String(lines[index][marker.upperBound...])
            lines[index] = before + after
            let footerOffset = index - start
            let viewportFooterTop = max(0, height - footerRows)
            return Cursor(row: viewportFooterTop + footerOffset, column: visibleWidth(before))
        }
        return nil
    }

    private func positionCursor(_ cursor: Cursor?, height: Int) -> String {
        guard let cursor else { return "\u{1b}[?25l" }
        let row = min(max(0, cursor.row), max(0, height - 1)) + 1
        let column = max(0, cursor.column) + 1
        return "\u{1b}[\(row);\(column)H\u{1b}[?25h"
    }

    // MARK: Terminal writes

    private func drawTranscript(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        var result = "\u{1b}[1;1H\u{1b}[1;\(max(1, lines.count))r"
        for index in lines.indices {
            if index > 0 { result += "\r\n" }
            result += lines[index]
        }
        return result
    }

    private func drawFooter(_ lines: [String], footerTop: Int) -> String {
        var result = "\u{1b}[\(footerTop);1H"
        for index in lines.indices {
            if index > 0 { result += "\r\n" }
            result += "\u{1b}[2K"
            if index == 0 {
                result += String(decoding: TerminalNativeSequence.promptMark(.promptStart), as: UTF8.self)
            }
            result += lines[index]
        }
        result += String(decoding: TerminalNativeSequence.promptMark(.promptEnd), as: UTF8.self)
        return result
    }

    private func appendTranscript(
        _ renderedLines: [String],
        oldCount: Int,
        newCount: Int,
        scrollBottom: Int
    ) -> String {
        guard newCount > oldCount else { return "" }
        let appended = Array(renderedLines.suffix(newCount - oldCount))
        guard !appended.isEmpty else { return "" }
        let oldVisibleCount = min(oldCount, scrollBottom)
        let firstRow: String
        if oldCount >= scrollBottom {
            firstRow = "\u{1b}[\(scrollBottom);1H\r\n"
        } else {
            firstRow = "\u{1b}[\(oldVisibleCount + 1);1H"
        }
        var result = firstRow
        for index in appended.indices {
            if index > 0 { result += "\r\n" }
            result += "\u{1b}[2K" + appended[index]
        }
        return result
    }
}
