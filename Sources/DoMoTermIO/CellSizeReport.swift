// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The terminal cell-pixel-size query and its reply parser, for terminals whose
// kernel `ws_xpixel`/`ws_ypixel` come back zero. pi issues XTWINOPS 16 (`CSI 16 t`)
// on startup and reads the `CSI 6 ; height ; width t` reply; this is the pure
// half — emitting the query bytes and parsing the reply — with the async plumbing
// (write the query, intercept the reply off the input stream) left to the client
// that owns the tty.

import DoMoCore

/// The XTWINOPS "report cell size in pixels" query: `CSI 16 t`. Write this to the
/// terminal; it answers with a report ``parseCellPixelSizeReport(_:)`` decodes.
public let cellPixelSizeQuery = "\u{1b}[16t"

/// Parse a terminal's cell-size report, `ESC [ 6 ; <heightPx> ; <widthPx> t`, into
/// a ``CellPixelSize``. Note the wire order is HEIGHT then WIDTH. Returns nil for
/// any other sequence (including the text-area report `4;…t` and the window report
/// `8;…t`, which share the `t` final byte but a different leading number).
public func parseCellPixelSizeReport(_ report: String) -> CellPixelSize? {
    guard report.hasPrefix("\u{1b}[6;"), report.hasSuffix("t") else { return nil }
    // Strip the "ESC [ 6 ;" prefix (4 characters) and the trailing "t".
    let body = report.dropFirst(4).dropLast()
    let parts = body.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let height = Int(parts[0]), let width = Int(parts[1]),
          height > 0, width > 0
    else { return nil }
    return CellPixelSize(widthPx: width, heightPx: height)
}
