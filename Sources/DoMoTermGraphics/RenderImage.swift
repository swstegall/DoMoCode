// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal-image.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The orchestrator: pick the protocol from capabilities, size the image in cells,
// and encode. Unlike pi (which reads process-global capabilities/cell size inside
// renderImage), this takes them explicitly — capability and cell-size detection
// happen in whatever process owns the tty (the client), which may not be where the
// image bytes originate, so they are passed in rather than read from a global.

import DoMoCore

/// A ready-to-emit image escape and the number of terminal rows it occupies (so
/// the renderer can reserve that vertical space).
public struct RenderedImage: Sendable, Hashable {
    /// The full escape sequence to write at the image's position.
    public var sequence: String
    /// Terminal rows the image occupies (authoritative for Kitty via `r=`, an
    /// estimate for iTerm2, which sizes itself from `height=auto`).
    public var rows: Int
    /// The Kitty image id, if the Kitty protocol was used (for later deletion). nil
    /// for iTerm2, which has no image lifecycle.
    public var imageId: UInt32?

    public init(sequence: String, rows: Int, imageId: UInt32?) {
        self.sequence = sequence
        self.rows = rows
        self.imageId = imageId
    }
}

/// Encode `base64Data` for display, or nil if the terminal supports no image
/// protocol (the caller then shows ``imageFallback(mediaType:dimensions:filename:)``).
///
/// - Parameters:
///   - base64Data: the base64-encoded image bytes (PNG for Kitty's `f=100`).
///   - dimensions: the image's intrinsic pixel size (from ``imageDimensions(_:mediaType:)``).
///   - capabilities: the detected terminal capabilities (usually ``getCapabilities()``).
///   - cell: the terminal cell pixel size (usually ``getCellDimensions()``).
///   - imageId: a stable Kitty id (allocate once per logical image and reuse it
///     across frames — see ``allocateImageId()``). Ignored for iTerm2.
///   - moveCursor: whether Kitty moves the cursor after placement (the renderer
///     controls placement itself, so it passes `false`).
public func renderImage(
    base64Data: String,
    dimensions: ImageDimensions,
    capabilities: TerminalCapabilities,
    cell: CellDimensions,
    maxWidthCells: Int = 80,
    maxHeightCells: Int? = nil,
    imageId: UInt32? = nil,
    moveCursor: Bool = true,
    preserveAspectRatio: Bool = true
) -> RenderedImage? {
    guard let imageProtocol = capabilities.images else { return nil }
    let size = calculateImageCellSize(dimensions, maxWidthCells: maxWidthCells, maxHeightCells: maxHeightCells, cell: cell)

    switch imageProtocol {
    case .kitty:
        let sequence = encodeKitty(
            base64Data,
            columns: size.columns,
            rows: size.rows,
            imageId: imageId,
            moveCursor: moveCursor
        )
        return RenderedImage(sequence: sequence, rows: size.rows, imageId: imageId)
    case .iterm2:
        let sequence = encodeITerm2(
            base64Data,
            width: "\(size.columns)",
            height: "auto",
            preserveAspectRatio: preserveAspectRatio
        )
        return RenderedImage(sequence: sequence, rows: size.rows, imageId: nil)
    }
}

/// The text shown for an image on a terminal with no image protocol (or an
/// unreadable format) — the graceful upgrade of the old `[N image(s)]` marker.
public func imageFallback(mediaType: String, dimensions: ImageDimensions? = nil, filename: String? = nil) -> String {
    var parts: [String] = []
    if let filename { parts.append(filename) }
    parts.append("[\(mediaType)]")
    if let dimensions { parts.append("\(dimensions.widthPx)x\(dimensions.heightPx)") }
    return "[Image: \(parts.joined(separator: " "))]"
}
