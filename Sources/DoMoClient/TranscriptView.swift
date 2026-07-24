// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The main pane's transcript renderer. Text items wrap to the pane width (role
// marker, dimmed reasoning, capped tool output); an image item becomes an image
// visual row (the graphics escape + the blank rows it reserves) when the terminal
// supports images, else a `[Image: …]` fallback line. `visualRows` is the mixed
// text/image output the layout node places; `render` flattens it to text only for
// the Component protocol and the pure-text tests.

import DoMoLLM
import DoMoTermGraphics
import DoMoTUI

/// One row of rendered transcript: a text line, or an image (its escape plus the
/// cell footprint the renderer paints text around).
enum TranscriptVisualRow: Sendable, Hashable {
    case text(String)
    case image(escape: String, imageId: UInt32?, cellWidth: Int, cellRows: Int)
}

/// Renders `[TranscriptItem]` to visual rows (text + images) for the main pane.
@MainActor
final class TranscriptView: Component {
    /// The transcript to render; set from `EventStore.transcript` each frame.
    var items: [TranscriptItem] = []
    /// Whether the selected session has a turn in flight (shows a streaming hint).
    var running = false

    private let toolOutputCap = 8
    private let toolOutputCharCap = 4000

    /// Memoize the rendered rows: the transcript is re-rendered every frame (e.g.
    /// on every keystroke), but only changes when an event lands — and re-encoding
    /// an image (base64 + escape) every frame would be very expensive. Keyed on the
    /// content, width, streaming flag, and the graphics context.
    private var cache: (items: [TranscriptItem], running: Bool, width: Int, capabilities: TerminalCapabilities, cell: CellDimensions, rows: [TranscriptVisualRow])?

    /// The mixed text/image rows for the main pane, given the terminal's image
    /// capability and cell size.
    func visualRows(width: Int, capabilities: TerminalCapabilities, cell: CellDimensions) -> [TranscriptVisualRow] {
        guard width > 0 else { return [] }
        if let cache, cache.width == width, cache.running == running,
           cache.capabilities == capabilities, cache.cell == cell, cache.items == items {
            return cache.rows
        }
        let rows = buildVisualRows(width: width, capabilities: capabilities, cell: cell)
        cache = (items, running, width, capabilities, cell, rows)
        return rows
    }

    /// Text-only rendering for the Component protocol: with no image protocol,
    /// images become their `[Image: …]` fallback line.
    func render(width: Int) -> [String] {
        visualRows(width: width, capabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false), cell: .default)
            .compactMap { if case .text(let line) = $0 { line } else { nil } }
    }

    private func buildVisualRows(width: Int, capabilities: TerminalCapabilities, cell: CellDimensions) -> [TranscriptVisualRow] {
        var rows: [TranscriptVisualRow] = []
        for item in items {
            switch item {
            case .user(let text):
                rows += labeledWrap("› ", text, width: width).map(TranscriptVisualRow.text)
            case .assistant(let text):
                rows += wrapToWidth(text, width: width).map(TranscriptVisualRow.text)
            case .reasoning(let text):
                rows += wrapToWidth(text, width: width).map { TranscriptVisualRow.text(dim($0)) }
            case .tool(let name, let output, let isError, let imageCount):
                rows.append(.text(toolHeader(name: name, isError: isError, imageCount: imageCount, width: width)))
                rows += toolBody(output, width: width).map(TranscriptVisualRow.text)
            case .image(let block, let imageId):
                rows += imageRows(block, imageId: imageId, width: width, capabilities: capabilities, cell: cell)
            }
            rows.append(.text(""))   // a blank spacer between items
        }
        if running { rows.append(.text(dim("…"))) }
        return rows
    }

    private func imageRows(_ block: ImageBlock, imageId: UInt32, width: Int, capabilities: TerminalCapabilities, cell: CellDimensions) -> [TranscriptVisualRow] {
        let dimensions = imageDimensions(block.data, mediaType: block.mediaType)
        if let dimensions,
           let rendered = renderImage(
               base64Data: block.data.base64EncodedString(),
               dimensions: dimensions,
               mediaType: block.mediaType,
               capabilities: capabilities,
               cell: cell,
               maxWidthCells: width,
               imageId: imageId,
               moveCursor: false
           ) {
            var rows: [TranscriptVisualRow] = [
                .image(escape: rendered.sequence, imageId: rendered.imageId, cellWidth: rendered.columns, cellRows: rendered.rows)
            ]
            // Reserve the blank rows the image also occupies (the renderer paints
            // text around them; they stay blank in the text grid).
            for _ in 1..<max(1, rendered.rows) { rows.append(.text("")) }
            return rows
        }
        // No image protocol, or an unreadable format: fall back to a text marker.
        return [.text(truncateToWidth(imageFallback(mediaType: block.mediaType, dimensions: dimensions), width))]
    }

    private func toolHeader(name: String, isError: Bool, imageCount: Int, width: Int) -> String {
        var header = (isError ? "✗ " : "⚙ ") + name
        if imageCount > 0 { header += " [\(imageCount) image\(imageCount == 1 ? "" : "s")]" }
        let styled = isError ? header : dim(header)
        return truncateToWidth(styled, width)
    }

    private func toolBody(_ output: String, width: Int) -> [String] {
        guard !output.isEmpty else { return [] }
        let overCharCap = output.count > toolOutputCharCap
        let bounded = overCharCap ? String(output.prefix(toolOutputCharCap)) : output
        var wrapped = wrapToWidth(bounded, width: max(1, width - 2)).map { "  " + $0 }
        if wrapped.count > toolOutputCap || overCharCap {
            wrapped = Array(wrapped.prefix(toolOutputCap)) + [dim("  … (output truncated)")]
        }
        return wrapped
    }
}
