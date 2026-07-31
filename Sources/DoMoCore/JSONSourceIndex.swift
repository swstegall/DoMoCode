// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A second JSON parser, whose only output is *where things are*.
//
// Foundation's decoder throws away the byte positions on its way to a value, so
// once `JSONDecoder` reports that `model.contextWindow` is the wrong type there
// is no way back to the line it was on. This scanner keeps the positions and
// discards the values — the exact complement — and the two are joined in
// ``ConfigDiagnostic/init(decoding:source:file:)``.
//
// Written over `[UInt8]` in the style of `PartialJSON.swift`, and for the same
// reason: bytes have no grapheme-breaking cost, no `String.Index` arithmetic and
// no chance of an offset that means something different to the caller than it
// does to us. Unlike that parser, this one repairs nothing.

import Foundation

/// Byte ranges for every value in a JSON document, keyed by path.
///
/// Strict where ``PartialJSON`` is forgiving: a trailing comma, a bare
/// identifier, an unescaped control character in a string or a truncated
/// document is a thrown ``ConfigDiagnostic`` carrying the offset of the byte
/// that broke the grammar. That strictness is the feature. Foundation's parser
/// in this toolchain accepts trailing commas, so a settings.json with one
/// decodes on macOS and may not elsewhere; a scan that rejects it is how the
/// user hears about that before their teammate does.
public enum JSONSourceIndex {
    /// Where one value — and the key that named it — live in the source.
    public struct Entry: Sendable, Hashable {
        /// Byte range of the key token *including its quotes*, or `nil` for an
        /// array element and for the document's root value.
        ///
        /// The quotes are included because the opening quote is where the key
        /// visually starts, and a caret under the first letter of a key reads
        /// as pointing one character in.
        public var keyRange: Range<Int>?

        /// Byte range of the whole value token: for a container, from its
        /// opening brace or bracket through the byte after its closing one.
        public var valueRange: Range<Int>

        public init(keyRange: Range<Int>?, valueRange: Range<Int>) {
            self.keyRange = keyRange
            self.valueRange = valueRange
        }
    }

    /// Maximum nesting accepted before the scan gives up.
    ///
    /// The scanner is recursive descent, so nesting is stack frames and a
    /// document of ten thousand open brackets is a stack overflow — an
    /// uncatchable `SIGBUS`, not an error a config loader can report.
    ///
    /// 32 rather than ``PartialJSON/defaultDepthLimit``'s 128 because these
    /// frames are fatter (each level is a `parseValue` *and* a container frame,
    /// both carrying a path and a range) and the usable depth is whatever the
    /// running thread has: a concurrency executor thread gets about 512 KiB,
    /// and a debug build of this scanner was measured overflowing one somewhere
    /// between 96 and 127 levels. A settings.json nests five deep at the very
    /// most, so the margin costs nothing and the alternative is a crash with no
    /// diagnostic at all.
    public static let depthLimit = 32

    /// Scans a document and returns a byte range per key path.
    ///
    /// Paths are the components of the route to a value, outermost first, with
    /// array indices rendered as decimal strings: `{"a":[{"b":1}]}` yields
    /// `[]`, `["a"]`, `["a", "0"]` and `["a", "0", "b"]`. The root's entry is
    /// included so that a diagnostic with no key path still has somewhere to
    /// point.
    ///
    /// A repeated key keeps only its **last** occurrence. RFC 8259 leaves
    /// duplicate names undefined, so no single location can be right for both;
    /// last-wins is the convention, and picking one beats returning a path that
    /// silently means either.
    public static func index(_ bytes: [UInt8]) throws(ConfigDiagnostic) -> [[String]: Entry] {
        var scanner = JSONSourceScanner(bytes: bytes)
        try scanner.run()
        return scanner.entries
    }
}

// MARK: - Scanner

private struct JSONSourceScanner {
    let bytes: [UInt8]
    var index: Int
    var path: [String] = []
    var entries: [[String]: JSONSourceIndex.Entry] = [:]

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // A leading UTF-8 byte-order mark is not JSON, and RFC 8259 says so.
        // It is skipped anyway because Foundation's parser skips it: a scanner
        // that rejected a file the decoder had just accepted would strip the
        // caret off every diagnostic for that file, which is the opposite of
        // this type's job. Nothing else about the grammar is relaxed.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            self.index = 3
        } else {
            self.index = 0
        }
    }

    // MARK: Cursor

    var isAtEnd: Bool { index >= bytes.count }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func fail(_ problem: String, at offset: Int) -> ConfigDiagnostic {
        ConfigDiagnostic(
            file: nil,
            source: bytes,
            byteOffset: offset,
            keyPath: path,
            problem: problem
        )
    }

    // MARK: Document

    mutating func run() throws(ConfigDiagnostic) {
        skipWhitespace()
        guard !isAtEnd else {
            throw fail("the document is empty", at: index)
        }
        try parseValue(depth: 0, keyRange: nil)
        skipWhitespace()
        guard isAtEnd else {
            throw fail(
                "unexpected \(describeToken(at: index)) after the end of the document",
                at: index
            )
        }
    }

    // MARK: Values

    @discardableResult
    mutating func parseValue(
        depth: Int,
        keyRange: Range<Int>?
    ) throws(ConfigDiagnostic) -> Range<Int> {
        // `depth` counts enclosing containers, so the root value is 0 and the
        // limit is the number of nesting levels, not the number of levels plus
        // one.
        guard depth < JSONSourceIndex.depthLimit else {
            throw fail(
                "nested more than \(JSONSourceIndex.depthLimit) levels deep",
                at: index
            )
        }
        skipWhitespace()
        let start = index
        guard let byte = peek() else {
            throw fail("expected a value but the document ended", at: index)
        }

        switch byte {
        case .leftBrace: try parseObject(depth: depth)
        case .leftBracket: try parseArray(depth: depth)
        case .quote: _ = try parseString()
        case .lowerT, .lowerF, .lowerN: try parseKeyword()
        default: try parseNumber()
        }

        let range = start..<index
        entries[path] = JSONSourceIndex.Entry(keyRange: keyRange, valueRange: range)
        return range
    }

    mutating func parseObject(depth: Int) throws(ConfigDiagnostic) {
        index += 1
        skipWhitespace()
        if peek() == UInt8.rightBrace {
            index += 1
            return
        }

        while true {
            skipWhitespace()
            guard let byte = peek() else {
                throw fail("expected a key but the document ended", at: index)
            }
            guard byte == .quote else {
                throw fail("expected a quoted key, found \(describeToken(at: index))", at: index)
            }

            let keyStart = index
            let key = try parseString()
            let keyRange = keyStart..<index

            skipWhitespace()
            guard peek() == UInt8.colon else {
                throw fail("expected ':' after the key", at: index)
            }
            index += 1

            path.append(key)
            try parseValue(depth: depth + 1, keyRange: keyRange)
            path.removeLast()

            skipWhitespace()
            guard let separator = peek() else {
                throw fail("expected ',' or '}' but the document ended", at: index)
            }
            if separator == .comma {
                // The caret goes on the comma, not on the `}` that exposed it:
                // the comma is the byte to delete.
                let comma = index
                index += 1
                skipWhitespace()
                if peek() == UInt8.rightBrace {
                    throw fail("trailing comma before '}'", at: comma)
                }
                continue
            }
            if separator == .rightBrace {
                index += 1
                return
            }
            throw fail("expected ',' or '}', found \(describeToken(at: index))", at: index)
        }
    }

    mutating func parseArray(depth: Int) throws(ConfigDiagnostic) {
        index += 1
        skipWhitespace()
        if peek() == UInt8.rightBracket {
            index += 1
            return
        }

        var element = 0
        while true {
            path.append(String(element))
            try parseValue(depth: depth + 1, keyRange: nil)
            path.removeLast()
            element += 1

            skipWhitespace()
            guard let separator = peek() else {
                throw fail("expected ',' or ']' but the document ended", at: index)
            }
            if separator == .comma {
                let comma = index
                index += 1
                skipWhitespace()
                if peek() == UInt8.rightBracket {
                    throw fail("trailing comma before ']'", at: comma)
                }
                continue
            }
            if separator == .rightBracket {
                index += 1
                return
            }
            throw fail("expected ',' or ']', found \(describeToken(at: index))", at: index)
        }
    }

    // MARK: Keywords and numbers

    private static let keywords = ["true", "false", "null"]

    mutating func parseKeyword() throws(ConfigDiagnostic) {
        for keyword in Self.keywords where matches(keyword) {
            index += keyword.utf8.count
            return
        }
        throw fail("expected a value, found \(describeToken(at: index))", at: index)
    }

    func matches(_ word: String) -> Bool {
        let text = Array(word.utf8)
        guard index + text.count <= bytes.count else { return false }
        for (offset, byte) in text.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    /// RFC 8259's number grammar, which is narrower than `Double.init(_:)`
    /// accepts: `+1`, `.5`, `1.`, `01`, `0x10` and `nan` are all rejected here
    /// and all parse as a `Double`. Being stricter than the decoder is safe —
    /// the decoder never sees these bytes — while being looser would hand back
    /// an offset for a document Foundation refuses.
    mutating func parseNumber() throws(ConfigDiagnostic) {
        let start = index
        var isNegative = false
        if peek() == UInt8.minus {
            index += 1
            isNegative = true
        }

        guard let first = peek(), first.isDigit else {
            if isNegative {
                throw fail("expected a digit after '-'", at: index)
            }
            throw fail("expected a value, found \(describeToken(at: start))", at: start)
        }

        if first == .zero {
            index += 1
            if let next = peek(), next.isDigit {
                throw fail("numbers may not have a leading zero", at: start)
            }
        } else {
            while let digit = peek(), digit.isDigit { index += 1 }
        }

        if peek() == UInt8.period {
            index += 1
            guard let digit = peek(), digit.isDigit else {
                throw fail("expected a digit after '.'", at: index)
            }
            while let digit = peek(), digit.isDigit { index += 1 }
        }

        if let exponent = peek(), exponent == .lowerE || exponent == .upperE {
            index += 1
            if let sign = peek(), sign == .plus || sign == .minus { index += 1 }
            guard let digit = peek(), digit.isDigit else {
                throw fail("expected a digit in the exponent", at: index)
            }
            while let digit = peek(), digit.isDigit { index += 1 }
        }
    }

    // MARK: Strings

    /// Returns the decoded text, because object keys become path components and
    /// a key written `"a"` has to index the same as one written `"a"`.
    mutating func parseString() throws(ConfigDiagnostic) -> String {
        let openingQuote = index
        index += 1
        var out: [UInt8] = []

        while index < bytes.count {
            let byte = bytes[index]
            if byte == .quote {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte == .backslash {
                try appendEscape(into: &out, openingQuote: openingQuote)
                continue
            }
            if byte < 0x20 {
                throw fail(
                    "unescaped control character 0x\(Self.hex(byte)) in a string",
                    at: index
                )
            }
            out.append(byte)
            index += 1
        }

        // The caret goes on the opening quote. Pointing at end-of-file would be
        // technically true and useless: what the user has to find is the string
        // that never closed.
        throw fail("unterminated string", at: openingQuote)
    }

    mutating func appendEscape(
        into out: inout [UInt8],
        openingQuote: Int
    ) throws(ConfigDiagnostic) {
        let escapeStart = index
        index += 1
        guard index < bytes.count else {
            throw fail("unterminated string", at: openingQuote)
        }

        let escape = bytes[index]
        switch escape {
        case .quote, .backslash, .slash: out.append(escape)
        case .lowerB: out.append(0x08)
        case .lowerF: out.append(0x0C)
        case .lowerN: out.append(0x0A)
        case .lowerR: out.append(0x0D)
        case .lowerT: out.append(0x09)
        case .lowerU:
            index += 1
            try appendUnicodeEscape(into: &out, escapeStart: escapeStart, openingQuote: openingQuote)
            return
        default:
            throw fail(
                "invalid escape '\\\(Self.printable(escape))' in a string",
                at: escapeStart
            )
        }
        index += 1
    }

    /// On entry `index` is on the first hex digit; on return it is one past the
    /// whole escape.
    ///
    /// A lone surrogate becomes U+FFFD rather than an error. It is legal JSON
    /// text — the surrogate range is only illegal in the *encoded* form — and
    /// Swift's `String` cannot hold one, so refusing the document would reject
    /// a file the decoder reads happily.
    mutating func appendUnicodeEscape(
        into out: inout [UInt8],
        escapeStart: Int,
        openingQuote: Int
    ) throws(ConfigDiagnostic) {
        let code = try readHexQuad(escapeStart: escapeStart, openingQuote: openingQuote)

        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
            bytes[index] == .backslash, bytes[index + 1] == .lowerU
        {
            let lowEscapeStart = index
            index += 2
            let low = try readHexQuad(escapeStart: lowEscapeStart, openingQuote: openingQuote)
            if (0xDC00...0xDFFF).contains(low) {
                let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                append(scalar: Unicode.Scalar(combined) ?? Self.replacement, to: &out)
                return
            }
            append(scalar: Self.replacement, to: &out)
            append(scalar: Unicode.Scalar(low) ?? Self.replacement, to: &out)
            return
        }

        append(scalar: Unicode.Scalar(code) ?? Self.replacement, to: &out)
    }

    mutating func readHexQuad(
        escapeStart: Int,
        openingQuote: Int
    ) throws(ConfigDiagnostic) -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else {
                throw fail("unterminated string", at: openingQuote)
            }
            guard let digit = bytes[index].hexDigitValue else {
                throw fail(
                    "'\\u' must be followed by four hexadecimal digits",
                    at: escapeStart
                )
            }
            code = code << 4 | UInt32(digit)
            index += 1
        }
        return code
    }

    static let replacement: Unicode.Scalar = "\u{FFFD}"

    func append(scalar: Unicode.Scalar, to out: inout [UInt8]) {
        out.append(contentsOf: Array(String(scalar).utf8))
    }

    // MARK: Describing the offending bytes

    /// Names what is at `offset` for an error message: a bare word is quoted
    /// whole, so `{"a": foo}` says `found 'foo'` rather than `found 'f'` and
    /// the user sees their typo instead of a letter of it.
    func describeToken(at offset: Int) -> String {
        guard offset < bytes.count else { return "the end of the document" }
        var end = offset
        while end < bytes.count, end - offset < 16, bytes[end].isWordByte { end += 1 }
        if end > offset {
            return "'\(String(decoding: bytes[offset..<end], as: UTF8.self))'"
        }
        return "'\(Self.printable(bytes[offset]))'"
    }

    static func printable(_ byte: UInt8) -> String {
        if (0x20...0x7E).contains(byte) {
            return String(UnicodeScalar(byte))
        }
        return "0x\(hex(byte))"
    }

    static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }
}

// MARK: - Byte vocabulary

extension UInt8 {
    fileprivate static let quote = UInt8(ascii: "\"")
    fileprivate static let backslash = UInt8(ascii: "\\")
    fileprivate static let slash = UInt8(ascii: "/")
    fileprivate static let comma = UInt8(ascii: ",")
    fileprivate static let colon = UInt8(ascii: ":")
    fileprivate static let minus = UInt8(ascii: "-")
    fileprivate static let plus = UInt8(ascii: "+")
    fileprivate static let period = UInt8(ascii: ".")
    fileprivate static let zero = UInt8(ascii: "0")
    fileprivate static let leftBrace = UInt8(ascii: "{")
    fileprivate static let rightBrace = UInt8(ascii: "}")
    fileprivate static let leftBracket = UInt8(ascii: "[")
    fileprivate static let rightBracket = UInt8(ascii: "]")
    fileprivate static let lowerB = UInt8(ascii: "b")
    fileprivate static let lowerE = UInt8(ascii: "e")
    fileprivate static let upperE = UInt8(ascii: "E")
    fileprivate static let lowerF = UInt8(ascii: "f")
    fileprivate static let lowerN = UInt8(ascii: "n")
    fileprivate static let lowerR = UInt8(ascii: "r")
    fileprivate static let lowerT = UInt8(ascii: "t")
    fileprivate static let lowerU = UInt8(ascii: "u")

    fileprivate var isDigit: Bool { (0x30...0x39).contains(self) }

    /// What a bare identifier or number-like token is made of, for the sole
    /// purpose of quoting it back at the user in an error.
    fileprivate var isWordByte: Bool {
        isDigit || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
            || self == UInt8(ascii: "_") || self == .minus || self == .plus || self == .period
    }

    fileprivate var hexDigitValue: UInt8? {
        switch self {
        case 0x30...0x39: return self - 0x30
        case 0x41...0x46: return self - 0x41 + 10
        case 0x61...0x66: return self - 0x61 + 10
        default: return nil
        }
    }
}
