// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// One transcript image, for the inline REPL. Unlike the full-screen client (which
// paints images into a separate CellBuffer layer because it owns an alt-screen
// grid), the inline path renders through the differential `RenderCore`, which
// already treats a Kitty/iTerm2 escape sequence as an opaque "image line": it skips
// width/reset normalization for it, reserves the blank rows below it, and deletes
// the Kitty image by id across frames. So an inline image is just a Component whose
// rows are `[escape] + reserved blanks` — the same technique `TranscriptView` uses,
// minus the alt-screen layer.

import DoMoLLM
import DoMoTermGraphics
import DoMoTUI

/// A single image block rendered as inline-terminal rows: the graphics escape plus
/// the blank rows it reserves when the terminal supports images, else a
/// `[Image: …]` text fallback.
@MainActor
final class ImageBlockView: Component {
    private let block: ImageBlock
    /// A stable Kitty id, allocated once at construction and reused across every
    /// frame so `RenderCore` deletes exactly this image (never a stale one) when the
    /// row moves or the transcript scrolls.
    private let imageId: UInt32
    private let capabilities: TerminalCapabilities
    private let cell: CellDimensions

    /// Re-encoding an image (base64 + escape) on every keystroke-driven frame would
    /// be very expensive; the rows only depend on the width, so memoize by it.
    private var cache: (width: Int, rows: [String])?

    init(block: ImageBlock, imageId: UInt32, capabilities: TerminalCapabilities, cell: CellDimensions) {
        self.block = block
        self.imageId = imageId
        self.capabilities = capabilities
        self.cell = cell
    }

    func render(width: Int) -> [String] {
        if let cache, cache.width == width { return cache.rows }
        let rows = build(width: width)
        cache = (width, rows)
        return rows
    }

    private func build(width: Int) -> [String] {
        guard width > 0 else { return [] }
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
               // The differential renderer owns the cursor and positions the image
               // itself, so a Kitty escape must not move the cursor (`C=1`).
               moveCursor: false
           ) {
            return reservedRows(escape: rendered.sequence, rows: max(1, rendered.rows))
        }
        // No image protocol, an unreadable format, or a non-PNG on Kitty: a text
        // marker (kept within the width the renderer's over-wide check enforces).
        return [truncateToWidth(imageFallback(mediaType: block.mediaType, dimensions: dimensions), width)]
    }

    /// Lay the escape and its reserved blank rows out for the differential renderer,
    /// which uses RELATIVE cursor motion. The layout is protocol-specific — a
    /// faithful port of pi's `components/image.ts`:
    ///
    /// - Kitty suppresses the cursor (`C=1`) and declares its height (`r=N`), so the
    ///   escape goes on the FIRST row and the renderer reserves the `N-1` blank rows
    ///   below it.
    /// - iTerm2 has no cursor-suppression and no row header — it draws inline and
    ///   advances the cursor by the image's height. So the blank rows come FIRST
    ///   (they reserve the footprint), and the escape goes on the LAST row prefixed
    ///   with a cursor-up of `N-1`: the cursor moves back to the block's top, iTerm2
    ///   draws from there, and its own downward advance lands the cursor back at the
    ///   block's bottom — keeping the renderer's cursor accounting consistent.
    ///   `isImageLine` still matches that row (it contains the iTerm2 prefix).
    private func reservedRows(escape: String, rows: Int) -> [String] {
        let blanks = rows - 1
        switch capabilities.images {
        case .iterm2:
            var lines = Array(repeating: "", count: blanks)
            let moveUp = blanks > 0 ? "\u{1b}[\(blanks)A" : ""
            lines.append(moveUp + escape)
            return lines
        default:  // .kitty (cursor held by C=1) — and the safe default
            return [escape] + Array(repeating: "", count: blanks)
        }
    }
}
