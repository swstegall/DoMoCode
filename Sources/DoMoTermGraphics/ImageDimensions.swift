// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal-image.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Header-only pixel-dimension readers, ported from terminal-image.ts. Each reads a
// handful of fixed-offset bytes from the RAW image data (DoMoCode already holds
// decoded bytes on ImageBlock, so these take `Data`, not base64) and returns nil
// on anything short or unrecognized. BMP is a DoMoCode addition — pi drops it, but
// the CLI accepts `.bmp` as image input, so it gets a reader here too.

import DoMoCore
import Foundation

// MARK: - Types

/// An image's intrinsic pixel size.
public struct ImageDimensions: Sendable, Hashable {
    public var widthPx: Int
    public var heightPx: Int
    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// An image's footprint in terminal cells.
public struct ImageCellSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

// MARK: - Byte reading

private extension Data {
    /// Byte at logical offset `i` (relative to `startIndex`, so slices work).
    func u8(_ i: Int) -> UInt8 { self[startIndex + i] }
    func u16be(_ i: Int) -> Int { (Int(u8(i)) << 8) | Int(u8(i + 1)) }
    func u16le(_ i: Int) -> Int { Int(u8(i)) | (Int(u8(i + 1)) << 8) }
    func u32be(_ i: Int) -> Int {
        (Int(u8(i)) << 24) | (Int(u8(i + 1)) << 16) | (Int(u8(i + 2)) << 8) | Int(u8(i + 3))
    }
    func u32le(_ i: Int) -> Int {
        Int(u8(i)) | (Int(u8(i + 1)) << 8) | (Int(u8(i + 2)) << 16) | (Int(u8(i + 3)) << 24)
    }
    /// Signed little-endian 32-bit (BMP width/height can be negative for top-down).
    func i32le(_ i: Int) -> Int { Int(Int32(bitPattern: UInt32(truncatingIfNeeded: u32le(i)))) }
    func ascii(_ range: Range<Int>) -> String {
        String(decoding: (range.lowerBound..<range.upperBound).map { u8($0) }, as: UTF8.self)
    }
}

// MARK: - Format readers

public func pngDimensions(_ data: Data) -> ImageDimensions? {
    guard data.count >= 24 else { return nil }
    guard data.u8(0) == 0x89, data.u8(1) == 0x50, data.u8(2) == 0x4e, data.u8(3) == 0x47 else { return nil }
    return ImageDimensions(widthPx: data.u32be(16), heightPx: data.u32be(20))
}

public func jpegDimensions(_ data: Data) -> ImageDimensions? {
    guard data.count >= 2, data.u8(0) == 0xff, data.u8(1) == 0xd8 else { return nil }
    var offset = 2
    while offset < data.count - 9 {
        if data.u8(offset) != 0xff { offset += 1; continue }
        let marker = data.u8(offset + 1)
        // SOF0 / SOF1 / SOF2 carry the frame dimensions.
        if marker >= 0xc0, marker <= 0xc2 {
            return ImageDimensions(widthPx: data.u16be(offset + 7), heightPx: data.u16be(offset + 5))
        }
        if offset + 3 >= data.count { return nil }
        let length = data.u16be(offset + 2)
        if length < 2 { return nil }
        offset += 2 + length
    }
    return nil
}

public func gifDimensions(_ data: Data) -> ImageDimensions? {
    guard data.count >= 10 else { return nil }
    let signature = data.ascii(0..<6)
    guard signature == "GIF87a" || signature == "GIF89a" else { return nil }
    return ImageDimensions(widthPx: data.u16le(6), heightPx: data.u16le(8))
}

public func webpDimensions(_ data: Data) -> ImageDimensions? {
    guard data.count >= 30 else { return nil }
    guard data.ascii(0..<4) == "RIFF", data.ascii(8..<12) == "WEBP" else { return nil }
    switch data.ascii(12..<16) {
    case "VP8 ":
        return ImageDimensions(widthPx: data.u16le(26) & 0x3fff, heightPx: data.u16le(28) & 0x3fff)
    case "VP8L":
        let bits = data.u32le(21)
        return ImageDimensions(widthPx: (bits & 0x3fff) + 1, heightPx: ((bits >> 14) & 0x3fff) + 1)
    case "VP8X":
        let width = (Int(data.u8(24)) | (Int(data.u8(25)) << 8) | (Int(data.u8(26)) << 16)) + 1
        let height = (Int(data.u8(27)) | (Int(data.u8(28)) << 8) | (Int(data.u8(29)) << 16)) + 1
        return ImageDimensions(widthPx: width, heightPx: height)
    default:
        return nil
    }
}

/// BMP dimensions (a DoMoCode addition; pi does not read BMP). Height is signed —
/// negative means a top-down bitmap — so it is taken absolute.
public func bmpDimensions(_ data: Data) -> ImageDimensions? {
    guard data.count >= 26 else { return nil }
    guard data.u8(0) == 0x42, data.u8(1) == 0x4d else { return nil }   // "BM"
    return ImageDimensions(widthPx: abs(data.i32le(18)), heightPx: abs(data.i32le(22)))
}

/// Read intrinsic pixel dimensions for a supported media type, or nil.
public func imageDimensions(_ data: Data, mediaType: String) -> ImageDimensions? {
    switch mediaType {
    case "image/png": return pngDimensions(data)
    case "image/jpeg": return jpegDimensions(data)
    case "image/gif": return gifDimensions(data)
    case "image/webp": return webpDimensions(data)
    case "image/bmp": return bmpDimensions(data)
    default: return nil
    }
}

// MARK: - Cell sizing

/// Convert an image's pixel dimensions into a cell footprint, scaling to fit
/// `maxWidthCells` (and optionally `maxHeightCells`) while preserving aspect ratio.
/// Ported exactly from pi's `calculateImageCellSize`.
public func calculateImageCellSize(
    _ image: ImageDimensions,
    maxWidthCells: Int,
    maxHeightCells: Int? = nil,
    cell: CellDimensions = .default
) -> ImageCellSize {
    let maxWidth = max(1, maxWidthCells)
    let maxHeight = maxHeightCells.map { max(1, $0) }
    let imageWidth = max(1, image.widthPx)
    let imageHeight = max(1, image.heightPx)

    // All arithmetic in Double, matching pi's float math — an Int multiply
    // (`maxWidth * cell.widthPx`) would trap on overflow at extreme cell counts,
    // where pi (and this) simply clamp to the max.
    let widthScale = (Double(maxWidth) * Double(cell.widthPx)) / Double(imageWidth)
    let heightScale = maxHeight.map { (Double($0) * Double(cell.heightPx)) / Double(imageHeight) } ?? widthScale
    let scale = min(widthScale, heightScale)

    let columns = clampedInt((Double(imageWidth) * scale / Double(cell.widthPx)).rounded(.up))
    let rows = clampedInt((Double(imageHeight) * scale / Double(cell.heightPx)).rounded(.up))

    return ImageCellSize(
        columns: max(1, min(maxWidth, columns)),
        rows: max(1, maxHeight.map { min($0, rows) } ?? rows)
    )
}

/// Convert a non-negative Double to Int without trapping on an out-of-range value
/// (saturating at `Int.max`), so the sizing math is a total function.
private func clampedInt(_ value: Double) -> Int {
    if value >= Double(Int.max) { return Int.max }
    if value <= 0 { return 0 }
    return Int(value)
}
