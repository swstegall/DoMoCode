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

/// Safe defaults for ordinary image output. The client can raise these limits for
/// an explicit image-open action without making every tool result a large layout
/// block.
struct TranscriptImagePolicy: Sendable, Hashable {
    var maxColumns: Int = 40
    var maxRows: Int = 12
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

    /// Whether long failure bodies and failed-tool output are shown in full.
    /// Toggled by `^O`.
    ///
    /// A render-affecting flag, so it is part of the memo key below — in BOTH
    /// the tuple and the comparison. A flag in one and not the other is a toggle
    /// that silently does nothing: the key would still match, the cached rows
    /// would still be returned, and the user would press the advertised key and
    /// watch the screen not change.
    var expandErrors = false

    private let toolOutputCap = 8
    private let toolOutputCharCap = 4000

    /// How many wrapped rows a failure body gets before it is capped.
    ///
    /// Larger than a tool call's eight, because the thing being capped is the
    /// answer to "why did this fail" and the useful part of a provider body is
    /// often not in its first line. Lifted entirely by `^O`.
    private let errorBodyRowCap = 12

    /// The rows a FAILED tool call gets. A failure's output is the diagnosis —
    /// a compiler's error list, a stack trace — and eight rows of it is a
    /// truncation right through the middle of the thing being read.
    private let failedToolOutputCap = 24

    /// Ordinary transcript images are thumbnails, not unbounded layout blocks.
    /// The policy is configurable for an explicit image-open action.
    var imagePolicy = TranscriptImagePolicy()
    /// An explicit user action may use the whole available transcript viewport.
    var imagesExpanded = false

    /// The braille spinner, shared with ``DoMoTUI/Loader``'s frame set so every
    /// surface animates identically.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Memoize the rendered rows: the transcript is re-rendered every frame (e.g.
    /// on every keystroke), but only changes when an event lands — and re-encoding
    /// an image (base64 + escape) every frame would be very expensive. Keyed on the
    /// content, width, streaming flag, spinner frame, the graphics context, and
    /// the expand toggle.
    private var cache: (items: [TranscriptItem], running: Bool, spinnerFrame: Int, width: Int, maxHeightRows: Int?, imagePolicy: TranscriptImagePolicy, imagesExpanded: Bool, capabilities: TerminalCapabilities, cell: CellDimensions, expandErrors: Bool, rows: [TranscriptVisualRow])?

    /// The mixed text/image rows for the main pane, given the terminal's image
    /// capability and cell size.
    ///
    /// Also maintains the scroll anchor: when the user has scrolled up and new rows
    /// arrive at the bottom, the offset grows by the same amount so the content
    /// under their eyes does not slide away. At offset `0` nothing is adjusted, so
    /// the default "follow the tail" behaviour is unchanged.
    func visualRows(
        width: Int,
        capabilities: TerminalCapabilities,
        cell: CellDimensions,
        maxHeightRows: Int? = nil
    ) -> [TranscriptVisualRow] {
        guard width > 0 else { return [] }
        if let cache, cache.width == width, cache.running == running,
           cache.spinnerFrame == spinnerFrame,
           cache.maxHeightRows == maxHeightRows,
           cache.imagePolicy == imagePolicy,
           cache.imagesExpanded == imagesExpanded,
           cache.capabilities == capabilities, cache.cell == cell,
           cache.expandErrors == expandErrors, cache.items == items {
            return cache.rows
        }
        let previous = cache
        let rows = buildVisualRows(
            width: width,
            capabilities: capabilities,
            cell: cell,
            maxHeightRows: maxHeightRows
        )
        // Only an append (rows grew) shifts the anchor, and only when the previous
        // frame had the SAME geometry. A row count is only comparable at one width:
        // re-wrapping at a new width changes it for reasons that have nothing to do
        // with new content, so comparing across a resize walked the viewport
        // backwards through history on every drag of the window edge. A shrink — a
        // session switch, a re-seed — is left to ``TranscriptNode``'s clamp.
        // `expandErrors` is the first thing in the package that grows rows in the
        // MIDDLE rather than at the tail, and the anchor arithmetic above assumes an
        // append. Toggling it while scrolled therefore teleported the viewport back
        // through history by the size of every expansion above it, and toggling again
        // did not undo it. A toggle is not new content, so it does not move the anchor.
        if scrollOffset > 0,
           let previous,
           previous.width == width, previous.maxHeightRows == maxHeightRows,
           previous.imagePolicy == imagePolicy, previous.imagesExpanded == imagesExpanded,
           previous.capabilities == capabilities, previous.cell == cell,
           previous.expandErrors == expandErrors,
           rows.count > previous.rows.count {
            scrollOffset += rows.count - previous.rows.count
        }
        cache = (
            items,
            running,
            spinnerFrame,
            width,
            maxHeightRows,
            imagePolicy,
            imagesExpanded,
            capabilities,
            cell,
            expandErrors,
            rows
        )
        return rows
    }

    /// Jump back to the newest content.
    func scrollToBottom() {
        scrollOffset = 0
    }

    var hasImages: Bool {
        items.contains { item in
            if case .image = item { return true }
            return false
        }
    }

    func toggleImageExpansion() {
        guard hasImages else { return }
        imagesExpanded.toggle()
    }

    /// Text-only rendering for the Component protocol: with no image protocol,
    /// images become their `[Image: …]` fallback line.
    func render(width: Int) -> [String] {
        visualRows(width: width, capabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false), cell: .default)
            .compactMap { if case .text(let line) = $0 { line } else { nil } }
    }

    private func buildVisualRows(
        width: Int,
        capabilities: TerminalCapabilities,
        cell: CellDimensions,
        maxHeightRows: Int?
    ) -> [TranscriptVisualRow] {
        var rows: [TranscriptVisualRow] = []
        for item in items {
            switch item {
            case .user(let text):
                rows += labeledWrap("› ", text, width: width).map(TranscriptVisualRow.text)
            case .assistant(let text):
                rows += assistantRows(text, width: width, capabilities: capabilities)
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
                rows += toolBody(output, width: width, failed: state == .failed)
                    .map(TranscriptVisualRow.text)
            case .image(let block, let imageId):
                rows += imageRows(
                    block,
                    imageId: imageId,
                    width: width,
                    maxHeightRows: maxHeightRows,
                    capabilities: capabilities,
                    cell: cell
                )
            case .error(let headline, let message, let hint):
                rows += errorRows(headline: headline, message: message, hint: hint, width: width)
                    .map(TranscriptVisualRow.text)
            }
            rows.append(.text(""))   // a blank spacer between items
        }
        if running { rows.append(.text(dim(spinner() + " working…"))) }
        return rows
    }

    /// The full-screen client keeps ordinary assistant text deliberately plain
    /// on conservative terminals, but hands it to the existing Markdown renderer
    /// when OSC 8 is known to be supported. That makes `[label](url)` clickable
    /// without putting hyperlink escapes into terminals that will display them.
    private func assistantRows(
        _ text: String,
        width: Int,
        capabilities: TerminalCapabilities
    ) -> [TranscriptVisualRow] {
        guard capabilities.hyperlinks else {
            return wrapToWidth(text, width: width).map(TranscriptVisualRow.text)
        }
        // Markdown treats a soft line break as paragraph whitespace. The event
        // store, however, preserves assistant newlines as transcript rows: the
        // selection and scroll surfaces rely on that one-to-one geometry. Render
        // each source line separately so OSC 8 support cannot collapse rows while
        // still giving each line the existing Markdown/link treatment.
        var rows: [TranscriptVisualRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                rows.append(.text(""))
            } else {
                rows += Markdown(String(line), useHyperlinks: true, streaming: running)
                    .render(width: width)
                    .map(TranscriptVisualRow.text)
            }
        }
        return rows
    }

    /// The current spinner glyph.
    private func spinner() -> String {
        let frames = Self.spinnerFrames
        return frames[((spinnerFrame % frames.count) + frames.count) % frames.count]
    }

    private func imageRows(
        _ block: ImageBlock,
        imageId: UInt32,
        width: Int,
        maxHeightRows: Int?,
        capabilities: TerminalCapabilities,
        cell: CellDimensions
    ) -> [TranscriptVisualRow] {
        let dimensions = imageDimensions(block.data, mediaType: block.mediaType)
        let configuredColumns = max(1, imagePolicy.maxColumns)
        let configuredRows = max(1, imagePolicy.maxRows)
        let maxColumns = imagesExpanded ? width : min(configuredColumns, width)
        let maxRows = imagesExpanded
            ? max(1, maxHeightRows ?? configuredRows)
            : min(configuredRows, max(1, maxHeightRows ?? configuredRows))
        if let dimensions,
           let rendered = renderImage(
               base64Data: block.data.base64EncodedString(),
               dimensions: dimensions,
               mediaType: block.mediaType,
               capabilities: capabilities,
               cell: cell,
               maxWidthCells: maxColumns,
               maxHeightCells: maxRows,
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

    /// The rows for a ``TranscriptItem/error(headline:message:hint:)``.
    ///
    /// `✗ <headline>` in bold red, the message indented two spaces and wrapped,
    /// then `→ <hint>` dimmed when there is one. The SGR is applied AFTER
    /// wrapping, never before — the same discipline `toolBody` follows — so the
    /// wrap arithmetic is over plain text and every emitted row's visible width
    /// is exactly what it looks like.
    ///
    /// All three parts are sanitized here rather than trusted from the caller:
    /// the message is gateway-controlled prose, and a headline or hint that came
    /// off the wire went through `ErrorPresentation` but not necessarily through
    /// anything that strips an ESC. Sanitizing at the render boundary means
    /// there is one place to be right about it.
    private func errorRows(headline: String, message: String, hint: String?, width: Int) -> [String] {
        guard width > 0 else { return [] }
        // The two-space indent is dropped rather than clamped on a pane too
        // narrow to hold it: `max(1, width - 2)` bottoms out at 1, and adding a
        // two-column prefix to that is three columns in a two-column pane. A
        // one-column-wide error row is useless either way, but an OVER-WIDE one
        // corrupts the frame around it.
        let indent = width >= 4 ? "  " : ""
        let bodyWidth = max(1, width - indent.count)

        var rows: [String] = [
            truncateToWidth("\u{1b}[1;31m" + "✗ " + sanitizeUntrustedText(headline) + sgrReset, width)
        ]
        let body = sanitizeUntrustedText(message)
        if !body.isEmpty {
            let wrapped = wrapToWidth(body, width: bodyWidth)
            let shown = expandErrors ? wrapped : Array(wrapped.prefix(errorBodyRowCap))
            rows += shown.map { indent + "\u{1b}[31m" + $0 + sgrReset }
            // Capped, but never DEAD-ended: the footer counts what is behind it
            // and names the key that lifts the cap, so a body whose useful part
            // is on line 40 is reachable rather than merely alluded to.
            rows += moreRow(hidden: wrapped.count - shown.count, width: bodyWidth, indent: indent)
        }
        if let hint, !hint.isEmpty {
            rows += wrapToWidth("→ " + sanitizeUntrustedText(hint), width: bodyWidth).map {
                dim(indent + $0)
            }
        }
        return rows
    }

    /// The "there is more, and here is how to see it" footer, or nothing when
    /// nothing was hidden.
    ///
    /// The indent is emitted OUTSIDE the SGR so the row keeps the alignment of
    /// the body it follows, and the text is truncated to the body width BEFORE
    /// styling so the arithmetic stays over plain text.
    private func moreRow(hidden: Int, width: Int, indent: String) -> [String] {
        guard hidden > 0 else { return [] }
        let text = "… \(hidden) more line\(hidden == 1 ? "" : "s") — ^O to expand"
        return [indent + dim(truncateToWidth(text, width))]
    }

    /// A tool call's output, capped — with headroom for the case that needs it.
    ///
    /// A FAILED call gets three times the rows of a successful one, because its
    /// output is the diagnosis and not merely a receipt; `^O` lifts the cap on
    /// both. The old eight-row cap plus a dead-end `… (output truncated)` is
    /// why "a tool failed and I cannot see why" was a real complaint: the text
    /// was always there, it just had no door.
    private func toolBody(_ output: String, width: Int, failed: Bool) -> [String] {
        guard !output.isEmpty, width > 0 else { return [] }
        // The two-space indent is DROPPED, not clamped, on a pane too narrow to
        // hold it. `max(1, width - 2)` bottoms out at one column, and prefixing
        // that with two spaces emits a three-column row into a two-column pane —
        // which does not wrap, it overwrites whatever is drawn to the right.
        let indent = width >= 4 ? "  " : ""
        let bodyWidth = max(1, width - indent.count)

        // The CHARACTER cap holds even when expanded: the row cap is a display
        // budget the user may spend, but a multi-megabyte body is a repaint cost
        // no single keystroke should be able to buy. Its own footer says so
        // without offering a key, because no key reveals more.
        let overCharCap = output.count > toolOutputCharCap
        let bounded = overCharCap ? String(output.prefix(toolOutputCharCap)) : output
        let rowCap = failed ? failedToolOutputCap : toolOutputCap
        let wrapped = wrapToWidth(bounded, width: bodyWidth)
        let shown = expandErrors ? wrapped : Array(wrapped.prefix(rowCap))
        var rows = shown.map { indent + $0 }
        rows += moreRow(hidden: wrapped.count - shown.count, width: bodyWidth, indent: indent)
        if overCharCap {
            rows.append(indent + dim(truncateToWidth("… (output truncated)", bodyWidth)))
        }
        return rows
    }
}
