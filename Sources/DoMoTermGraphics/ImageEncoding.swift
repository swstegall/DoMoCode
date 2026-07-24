// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal-image.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two image-protocol encoders, ported byte-for-byte from terminal-image.ts.
// These build raw control-byte sequences: the Kitty envelope is APC
// `ESC _ G … ESC \` (the ST terminator is the two bytes 0x1B 0x5C), the iTerm2
// envelope is OSC `ESC ] 1337;File= … BEL` (0x07). Getting a terminator wrong
// yields no image and a corrupted line, so the escapes are spelled explicitly.

import DoMoCore

// MARK: - Prefixes

/// The Kitty graphics APC introducer, `ESC _ G`.
public let kittyPrefix = "\u{1b}_G"
/// The iTerm2 inline-image OSC introducer, `ESC ] 1337;File=`.
public let iterm2Prefix = "\u{1b}]1337;File="

/// The Kitty String Terminator: `ESC \` (two bytes, 0x1B 0x5C).
private let kittyTerminator = "\u{1b}\\"
/// The iTerm2 terminator: BEL (0x07).
private let iterm2Terminator = "\u{07}"
/// Base64 payload chunk size (Kitty requires transmission in ≤4096-char chunks).
private let kittyChunkSize = 4096

// MARK: - Kitty

/// A random Kitty image id in `[1, 0xffffffff]` — random, not sequential, to
/// avoid collisions between independent producers. Only collision-avoidance, so a
/// plain PRNG is fine.
public func allocateImageId() -> UInt32 {
    UInt32.random(in: 1...UInt32.max)
}

/// Encode a base64 PNG payload as a Kitty graphics escape.
///
/// Base params are always `a=T,f=100,q=2` (transmit+display, PNG format, suppress
/// all responses), then `C=1` when the cursor must not move, and `c`/`r`/`i` for
/// the cell columns/rows and image id. Payloads over 4096 base64 chars are split
/// into `m=1` (more) chunks ending in an `m=0` (final) chunk, each in its own
/// envelope, concatenated with no separator.
public func encodeKitty(
    _ base64Data: String,
    columns: Int? = nil,
    rows: Int? = nil,
    imageId: UInt32? = nil,
    moveCursor: Bool = true
) -> String {
    var params = ["a=T", "f=100", "q=2"]
    if !moveCursor { params.append("C=1") }
    // Omit non-positive c/r/i: pi omits 0 (a falsy value), and `c=0`/`r=0` are
    // invalid Kitty anyway. renderImage always passes ≥1, so this only guards
    // direct callers.
    if let columns, columns > 0 { params.append("c=\(columns)") }
    if let rows, rows > 0 { params.append("r=\(rows)") }
    if let imageId, imageId > 0 { params.append("i=\(imageId)") }
    let header = params.joined(separator: ",")

    // base64 is ASCII, so UTF-8 byte count == character count and slicing bytes is
    // equivalent to slicing characters — and far cheaper than `[Character]`.
    let bytes = Array(base64Data.utf8)
    if bytes.count <= kittyChunkSize {
        return "\(kittyPrefix)\(header);\(base64Data)\(kittyTerminator)"
    }

    var result = ""
    var offset = 0
    var isFirst = true
    while offset < bytes.count {
        let end = min(offset + kittyChunkSize, bytes.count)
        let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
        let isLast = end >= bytes.count
        if isFirst {
            result += "\(kittyPrefix)\(header),m=1;\(chunk)\(kittyTerminator)"
            isFirst = false
        } else if isLast {
            result += "\(kittyPrefix)m=0;\(chunk)\(kittyTerminator)"
        } else {
            result += "\(kittyPrefix)m=1;\(chunk)\(kittyTerminator)"
        }
        offset += kittyChunkSize
    }
    return result
}

/// Delete a Kitty image by id (uppercase `I` also frees its data).
public func deleteKittyImage(_ imageId: UInt32) -> String {
    "\(kittyPrefix)a=d,d=I,i=\(imageId),q=2\(kittyTerminator)"
}

/// Delete all visible Kitty images (uppercase `A` also frees their data).
public func deleteAllKittyImages() -> String {
    "\(kittyPrefix)a=d,d=A,q=2\(kittyTerminator)"
}

// MARK: - iTerm2

/// Encode a base64 image payload as an iTerm2 inline-image escape.
///
/// `width`/`height` accept a number or a keyword like `"auto"`/`"100px"`
/// (``renderImage`` passes `width=<cols>`, `height="auto"`). `name` is base64-
/// encoded; `preserveAspectRatio` is emitted only when false (matching pi).
public func encodeITerm2(
    _ base64Data: String,
    width: String? = nil,
    height: String? = nil,
    name: String? = nil,
    preserveAspectRatio: Bool = true,
    inline: Bool = true
) -> String {
    var params = ["inline=\(inline ? 1 : 0)"]
    if let width { params.append("width=\(width)") }
    if let height { params.append("height=\(height)") }
    if let name, !name.isEmpty { params.append("name=\(base64(name))") }   // pi omits an empty name
    if !preserveAspectRatio { params.append("preserveAspectRatio=0") }
    return "\(iterm2Prefix)\(params.joined(separator: ";")):\(base64Data)\(iterm2Terminator)"
}

private func base64(_ text: String) -> String {
    var bytes = Array(text.utf8)
    // Small hand-rolled base64 to avoid a Foundation import for one filename.
    let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var out = ""
    while bytes.count % 3 != 0 { bytes.append(0) }
    let padding = (3 - text.utf8.count % 3) % 3
    var index = 0
    while index < bytes.count {
        let n = (Int(bytes[index]) << 16) | (Int(bytes[index + 1]) << 8) | Int(bytes[index + 2])
        out.append(table[(n >> 18) & 0x3f])
        out.append(table[(n >> 12) & 0x3f])
        out.append(table[(n >> 6) & 0x3f])
        out.append(table[n & 0x3f])
        index += 3
    }
    if padding > 0 { out = String(out.dropLast(padding)) + String(repeating: "=", count: padding) }
    return out
}

// MARK: - Image-line detection (for the differential renderer)

/// Whether a rendered line carries an image escape — so the differential renderer
/// can treat it as opaque (never diff, clip, or reflow it). Fast path checks the
/// prefix (single-row image); slow path checks anywhere (a multi-row image line
/// may carry a cursor-motion prefix, though DoMoCode keeps motion in the render
/// loop, not the stored line).
public func isImageLine(_ line: String) -> Bool {
    if line.hasPrefix(kittyPrefix) || line.hasPrefix(iterm2Prefix) { return true }
    return line.contains(kittyPrefix) || line.contains(iterm2Prefix)
}

/// The `i` (image id) and `r` (rows) a Kitty image line's header declares, for the
/// renderer's reserved-row and delete-tracking bookkeeping. Reads the first
/// `ESC_G … ;` header (a chunked image carries the header only on its first
/// chunk). Returns nil if the line has no Kitty header.
public func parseKittyImageHeader(_ line: String) -> (imageId: UInt32?, rows: Int?)? {
    guard let prefixRange = line.range(of: kittyPrefix) else { return nil }
    let afterPrefix = line[prefixRange.upperBound...]
    guard let semicolon = afterPrefix.firstIndex(of: ";") else { return nil }
    let header = afterPrefix[afterPrefix.startIndex..<semicolon]
    var imageId: UInt32?
    var rows: Int?
    for pair in header.split(separator: ",") {
        let keyValue = pair.split(separator: "=", maxSplits: 1)
        guard keyValue.count == 2 else { continue }
        switch keyValue[0] {
        case "i": imageId = UInt32(keyValue[1])
        case "r": rows = Int(keyValue[1])
        default: break
        }
    }
    return (imageId, rows)
}
