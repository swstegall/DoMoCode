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
    /// The animation frame for in-flight tool calls and the streaming hint. The app
    /// advances it on a clock while anything is running; a still frame means a still
    /// spinner, which is exactly the signal a stalled UI should give.
    var spinnerFrame = 0

    /// How far the viewport is scrolled UP from the bottom, in visual rows. `0`
    /// means pinned to the newest content (the default, and where a new prompt
    /// snaps it back to).
    ///
    /// Held here rather than in the layout node because the node is a value type
    /// rebuilt every frame, and because the clamp has to survive content changes:
    /// ``TranscriptNode`` writes back the clamped value after it learns the
    /// viewport height, which only it knows.
    var scrollOffset = 0

    private let toolOutputCap = 8
    private let toolOutputCharCap = 4000

    /// The braille spinner, shared with ``DoMoTUI/Loader``'s frame set so every
    /// surface animates identically.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Memoize the rendered rows: the transcript is re-rendered every frame (e.g.
    /// on every keystroke), but only changes when an event lands — and re-encoding
    /// an image (base64 + escape) every frame would be very expensive. Keyed on the
    /// content, width, streaming flag, spinner frame, and the graphics context.
    private var cache: (items: [TranscriptItem], running: Bool, spinnerFrame: Int, width: Int, capabilities: TerminalCapabilities, cell: CellDimensions, rows: [TranscriptVisualRow])?

    /// The mixed text/image rows for the main pane, given the terminal's image
    /// capability and cell size.
    ///
    /// Also maintains the scroll anchor: when the user has scrolled up and new rows
    /// arrive at the bottom, the offset grows by the same amount so the content
    /// under their eyes does not slide away. At offset `0` nothing is adjusted, so
    /// the default "follow the tail" behaviour is unchanged.
    func visualRows(width: Int, capabilities: TerminalCapabilities, cell: CellDimensions) -> [TranscriptVisualRow] {
        guard width > 0 else { return [] }
        if let cache, cache.width == width, cache.running == running,
           cache.spinnerFrame == spinnerFrame,
           cache.capabilities == capabilities, cache.cell == cell, cache.items == items {
            return cache.rows
        }
        let previous = cache
        let rows = buildVisualRows(width: width, capabilities: capabilities, cell: cell)
        // Only an append (rows grew) shifts the anchor, and only when the previous
        // frame had the SAME geometry. A row count is only comparable at one width:
        // re-wrapping at a new width changes it for reasons that have nothing to do
        // with new content, so comparing across a resize walked the viewport
        // backwards through history on every drag of the window edge. A shrink — a
        // session switch, a re-seed — is left to ``TranscriptNode``'s clamp.
        if scrollOffset > 0,
           let previous,
           previous.width == width, previous.capabilities == capabilities, previous.cell == cell,
           rows.count > previous.rows.count {
            scrollOffset += rows.count - previous.rows.count
        }
        cache = (items, running, spinnerFrame, width, capabilities, cell, rows)
        return rows
    }

    /// Jump back to the newest content.
    func scrollToBottom() {
        scrollOffset = 0
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
            case .tool(let name, let detail, let output, let state, let imageCount):
                rows.append(.text(toolHeader(name: name, detail: detail, state: state, imageCount: imageCount, width: width)))
                if state == .awaitingApproval {
                    rows.append(.text(truncateToWidth(
                        "\u{1b}[33m" + "    ↳ waiting for your approval — answer the prompt below" + sgrReset,
                        width
                    )))
                }
                rows += toolBody(output, width: width).map(TranscriptVisualRow.text)
            case .image(let block, let imageId):
                rows += imageRows(block, imageId: imageId, width: width, capabilities: capabilities, cell: cell)
            }
            rows.append(.text(""))   // a blank spacer between items
        }
        if running { rows.append(.text(dim(spinner() + " working…"))) }
        return rows
    }

    /// The current spinner glyph.
    private func spinner() -> String {
        let frames = Self.spinnerFrames
        return frames[((spinnerFrame % frames.count) + frames.count) % frames.count]
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

    /// The one-line header for a tool call: a state glyph, the tool name, and the
    /// argument summary — `⠙ edit  src/Foo.swift`.
    ///
    /// The state glyph is the whole point: a running call spins, a parked call shows
    /// an hourglass, and a finished one settles to a tick or a cross. Previously
    /// every state rendered as the same static `⚙`, so "running", "waiting for you"
    /// and "done, no output" were indistinguishable.
    ///
    /// The name is styled, never the summary, and the summary is elided from the
    /// LEFT so a long path keeps the filename that identifies it. Only the name and
    /// glyph carry SGR, so the width arithmetic below is over plain text.
    private func toolHeader(name: String, detail: String, state: ToolCallState, imageCount: Int, width: Int) -> String {
        let glyph: String
        let color: String
        switch state {
        case .running:
            glyph = spinner()
            color = "\u{1b}[36m"   // cyan — in flight
        case .awaitingApproval:
            glyph = "⏳"
            color = "\u{1b}[33m"   // yellow — needs you
        case .succeeded:
            glyph = "✓"
            color = "\u{1b}[32m"   // green
        case .failed:
            glyph = "✗"
            color = "\u{1b}[31m"   // red
        }

        var suffix = ""
        if imageCount > 0 { suffix = " [\(imageCount) image\(imageCount == 1 ? "" : "s")]" }

        // Budget: glyph + space + name + suffix + two spaces before the summary.
        let head = glyph + " " + name + suffix
        let headWidth = visibleWidth(head)
        let styledHead = color + glyph + sgrReset + " " + color + name + sgrReset + dim(suffix)
        guard !detail.isEmpty else { return truncateToWidth(styledHead, width) }

        let separator = "  "
        let remaining = width - headWidth - visibleWidth(separator)
        guard remaining > 1 else { return truncateToWidth(styledHead, width) }
        return styledHead + separator + dim(elideLeading(detail, width: remaining))
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
