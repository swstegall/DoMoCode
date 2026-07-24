// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// Header-only dimension readers (against hand-built minimal headers), the cell-
// sizing math, and the renderImage orchestrator.

import DoMoTermGraphics
import Foundation
import Testing

@Suite("Image dimensions and sizing")
struct ImageDimensionsTests {
    @Test("PNG dimensions read from the IHDR offsets")
    func png() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]  // signature
        bytes += [0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52]              // IHDR chunk header
        bytes += [0x00, 0x00, 0x00, 0x64]                                      // width = 100 (BE @16)
        bytes += [0x00, 0x00, 0x00, 0x32]                                      // height = 50 (BE @20)
        #expect(pngDimensions(Data(bytes)) == ImageDimensions(widthPx: 100, heightPx: 50))
    }

    @Test("JPEG dimensions read from the SOF0 marker (height then width)")
    func jpeg() {
        var bytes: [UInt8] = [0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08]  // SOI + SOF0 + len + precision
        bytes += [0x00, 0x64]   // height = 100 (BE @ off+5 == 7)
        bytes += [0x00, 0xc8]   // width  = 200 (BE @ off+7 == 9)
        bytes += [UInt8](repeating: 0, count: 8)  // pad so count > 11
        #expect(jpegDimensions(Data(bytes)) == ImageDimensions(widthPx: 200, heightPx: 100))
    }

    @Test("GIF dimensions read little-endian")
    func gif() {
        var bytes: [UInt8] = Array("GIF89a".utf8)
        bytes += [0x2c, 0x01]   // width  = 300 (LE @6)
        bytes += [0x96, 0x00]   // height = 150 (LE @8)
        #expect(gifDimensions(Data(bytes)) == ImageDimensions(widthPx: 300, heightPx: 150))
    }

    @Test("WebP VP8X dimensions are the 3-byte little-endian fields plus one")
    func webp() {
        var bytes: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array("VP8X".utf8)
        bytes += [UInt8](repeating: 0, count: 8)   // flags/canvas to reach offset 24
        bytes += [0x7f, 0x02, 0x00]                // width  = 0x27f + 1 = 640 (@24)
        bytes += [0xdf, 0x01, 0x00]                // height = 0x1df + 1 = 480 (@27)
        #expect(webpDimensions(Data(bytes)) == ImageDimensions(widthPx: 640, heightPx: 480))
    }

    @Test("BMP dimensions read signed little-endian, height taken absolute")
    func bmp() {
        var bytes: [UInt8] = [0x42, 0x4d]                       // "BM"
        bytes += [UInt8](repeating: 0, count: 16)               // to offset 18
        bytes += [0x20, 0x03, 0x00, 0x00]                       // width = 800 (LE @18)
        bytes += [0x58, 0xfd, 0xff, 0xff]                       // height = -680 -> abs 680 (top-down)
        #expect(bmpDimensions(Data(bytes)) == ImageDimensions(widthPx: 800, heightPx: 680))
    }

    @Test("Short or wrong-magic buffers return nil, not a crash")
    func garbageReturnsNil() {
        #expect(pngDimensions(Data([0x89, 0x50])) == nil)             // too short
        #expect(pngDimensions(Data([UInt8](repeating: 0, count: 24))) == nil)  // wrong magic
        #expect(jpegDimensions(Data([0x00, 0x01])) == nil)
        #expect(gifDimensions(Data(Array("GIF00a".utf8) + [0, 0, 0, 0])) == nil)
        #expect(imageDimensions(Data([0, 1, 2, 3]), mediaType: "image/tiff") == nil)  // unsupported type
    }

    @Test("imageDimensions dispatches by media type")
    func dispatch() {
        var png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        png += [0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x14]   // 10 x 20
        #expect(imageDimensions(Data(png), mediaType: "image/png") == ImageDimensions(widthPx: 10, heightPx: 20))
    }

    @Test("Cell sizing preserves aspect ratio and honors max width/height")
    func cellSizing() {
        let cell = CellDimensions(widthPx: 9, heightPx: 18)
        // 900x450 fitting 80 wide x 20 tall -> exactly 80x20 at 9x18 cells.
        #expect(calculateImageCellSize(ImageDimensions(widthPx: 900, heightPx: 450), maxWidthCells: 80, maxHeightCells: 20, cell: cell)
            == ImageCellSize(columns: 80, rows: 20))
        // Constrained by height: a square capped at 5 rows.
        #expect(calculateImageCellSize(ImageDimensions(widthPx: 100, heightPx: 100), maxWidthCells: 80, maxHeightCells: 5, cell: cell)
            == ImageCellSize(columns: 10, rows: 5))
        // Degenerate/zero dimensions never crash and never go below 1x1.
        let zero = calculateImageCellSize(ImageDimensions(widthPx: 0, heightPx: 0), maxWidthCells: 40, cell: cell)
        #expect(zero.columns >= 1 && zero.rows >= 1)
        // A total function: an extreme max cell count clamps instead of trapping on
        // an Int-multiply overflow.
        let extreme = calculateImageCellSize(ImageDimensions(widthPx: 100, heightPx: 100), maxWidthCells: Int.max, cell: cell)
        #expect(extreme.columns >= 1 && extreme.rows >= 1)
    }

    @Test("renderImage encodes for the active protocol and reports rows")
    func render() {
        let cell = CellDimensions(widthPx: 9, heightPx: 18)
        let dims = ImageDimensions(widthPx: 900, heightPx: 450)

        // No protocol -> nil (caller shows the text fallback).
        #expect(renderImage(base64Data: "QUJD", dimensions: dims,
                            capabilities: TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true),
                            cell: cell) == nil)

        // Kitty: sequence carries c=/r=/i=, rows reported, id echoed.
        let kitty = renderImage(base64Data: "QUJD", dimensions: dims,
                                capabilities: TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true),
                                cell: cell, maxWidthCells: 80, imageId: 99, moveCursor: false)
        #expect(kitty?.rows == 20)
        #expect(kitty?.imageId == 99)
        #expect(kitty?.sequence.contains("c=80,r=20,i=99") == true)

        // iTerm2: width=<cols>;height=auto, no id.
        let iterm = renderImage(base64Data: "QUJD", dimensions: dims,
                                capabilities: TerminalCapabilities(images: .iterm2, trueColor: true, hyperlinks: true),
                                cell: cell, maxWidthCells: 80)
        #expect(iterm?.rows == 20)
        #expect(iterm?.imageId == nil)
        #expect(iterm?.sequence.contains("width=80;height=auto") == true)
    }

    @Test("imageFallback formats name, media type, and dimensions")
    func fallback() {
        #expect(imageFallback(mediaType: "image/png", dimensions: ImageDimensions(widthPx: 100, heightPx: 50), filename: "x.png")
            == "[Image: x.png [image/png] 100x50]")
        #expect(imageFallback(mediaType: "image/jpeg") == "[Image: [image/jpeg]]")
    }
}
