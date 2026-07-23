// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/utils/json-parse.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import Foundation

// MARK: - Result

/// Whether a tolerant parse had to change anything to produce a value.
///
/// The distinction exists so a caller rendering a streaming tool-call preview
/// can say so. Silently returning `{"path": "READ"}` for a truncated
/// `{"path": "READM` is how a UI ends up claiming the model is about to edit a
/// file that does not exist.
public enum PartialJSONCompleteness: Sendable, Hashable {
    /// The input was strictly valid JSON from first byte to last. The value is
    /// exactly what a conforming parser would have produced.
    case complete

    /// Something was closed, dropped, completed, or reinterpreted. The value is
    /// a best effort and may gain or change members as more input arrives.
    ///
    /// This covers repairs that are not truncation — a trailing comma, a raw
    /// control character in a string — because the useful question at the call
    /// site is "did a strict parser accept this", and the answer there is no.
    case repaired
}

/// A tolerantly parsed value together with how much trust it deserves.
public struct PartialJSONResult: Sendable, Hashable {
    public var value: JSONValue
    public var completeness: PartialJSONCompleteness

    public init(value: JSONValue, completeness: PartialJSONCompleteness) {
        self.value = value
        self.completeness = completeness
    }

    public var isComplete: Bool { completeness == .complete }
}

/// Failures the tolerant parser will not paper over.
public enum PartialJSONError: Error, Sendable, Hashable {
    /// Input was empty or whitespace only. There is no prefix of a JSON value
    /// here to recover, not even an ambiguous one.
    case emptyInput

    /// The first non-blank byte could not begin any JSON value.
    case unrecoverable(byteOffset: Int)

    /// Nesting exceeded the configured limit. Reported rather than repaired:
    /// a document 10_000 arrays deep is a bug or an attack, and returning the
    /// outermost shell of one invites the caller to keep feeding it.
    case depthLimitExceeded(byteOffset: Int)
}

// MARK: - PartialJSON

/// Tolerant JSON parsing for values that arrive a chunk at a time.
///
/// A streaming tool call delivers its `arguments` as string fragments; to show
/// the user what the tool is about to do before the call completes, the harness
/// must parse a prefix that is almost certainly cut mid-token. This parser
/// consumes as much as it can and closes whatever is still open at EOF.
///
/// Ported from pi's `packages/ai/src/utils/json-parse.ts`, which composes the
/// npm `partial-json` package (at `Allow.ALL`) with its own `repairJson`
/// pre-pass. The semantics that matter are preserved: unterminated strings
/// close, unterminated containers close, trailing commas and dangling keys are
/// dropped, and a keyword truncated to a proper prefix (`tru`, `nul`) is
/// completed rather than discarded. Deliberate divergences are noted on the
/// members below.
public enum PartialJSON {
    /// Default maximum nesting depth.
    ///
    /// The parser is recursive descent, so depth is stack frames. 128 is far
    /// past anything a tool schema produces and small enough that the worst
    /// case still fits comfortably on a 512 KiB executor thread stack —
    /// upstream relies on the JS engine's `RangeError` for this, which is a
    /// stack overflow that happens to be catchable. Swift gets no such favour.
    public static let defaultDepthLimit = 128

    /// Hard ceiling on `depthLimit`. A caller may lower the limit but never
    /// raise it.
    ///
    /// Without a ceiling the guarantee inverts: `depthLimit` exists so deep
    /// input *throws* rather than overflowing the stack, but a caller passing a
    /// large value restores the overflow it was meant to prevent — and a stack
    /// overflow is an uncatchable `SIGBUS`, not something the agent loop can
    /// report. Safety belongs to the parser, not the call site.
    ///
    /// It equals ``defaultDepthLimit`` deliberately. A higher ceiling is not
    /// safe to offer: the usable depth depends on frame size and on which
    /// thread is parsing — the main thread has megabytes of stack, a
    /// concurrency executor thread has about 512 KiB — and debug frames are
    /// several times larger than release ones. A 512 ceiling was tried and
    /// crashed a debug test run at depth 511. Since no real tool-call payload
    /// nests anywhere near 128, there is nothing to buy by raising it.
    public static let maximumDepthLimit = defaultDepthLimit

    /// Parses a UTF-8 JSON string, tolerating truncation and common model
    /// malformations.
    ///
    /// Throws only when nothing at all can be recovered; a truncated or
    /// malformed-but-recognizable document comes back as `.repaired`.
    public static func parse(
        _ text: String,
        depthLimit: Int = defaultDepthLimit
    ) throws(PartialJSONError) -> PartialJSONResult {
        try parse(bytes: Array(text.utf8), depthLimit: depthLimit)
    }

    /// Parses UTF-8 JSON bytes. Preferred when the caller already has the
    /// stream buffer as bytes: it skips a `String` round trip, and truncation
    /// inside a multi-byte scalar cannot be smuggled past `String`'s validation
    /// as U+FFFD before the parser ever sees it.
    public static func parse(
        _ data: Data,
        depthLimit: Int = defaultDepthLimit
    ) throws(PartialJSONError) -> PartialJSONResult {
        try parse(bytes: Array(data), depthLimit: depthLimit)
    }

    private static func parse(
        bytes: [UInt8],
        depthLimit: Int
    ) throws(PartialJSONError) -> PartialJSONResult {
        let effectiveDepthLimit = min(max(1, depthLimit), maximumDepthLimit)
        var parser = PartialJSONParser(bytes: bytes, depthLimit: effectiveDepthLimit)
        parser.skipWhitespace()
        guard !parser.isAtEnd else { throw PartialJSONError.emptyInput }

        guard let value = try parser.parseValue(depth: 0) else {
            throw PartialJSONError.unrecoverable(byteOffset: parser.index)
        }

        // Trailing bytes after a complete value are not an error — a provider
        // that concatenated two objects still told us about the first one — but
        // they do mean a strict parser would have rejected the input.
        parser.skipWhitespace()
        if !parser.isAtEnd { parser.didRepair = true }

        return PartialJSONResult(
            value: value,
            completeness: parser.didRepair ? .repaired : .complete
        )
    }

    /// The never-failing entry point, matching pi's `parseStreamingJson`.
    ///
    /// Falls back to an empty object rather than throwing, because every call
    /// site is a render path for a tool preview that must not take down the
    /// stream. The `.repaired` marker on the fallback is the only signal that
    /// the empty object is a placeholder and not a parsed `{}` — upstream
    /// returns a bare `{}` and loses that distinction.
    public static func parseStreaming(
        _ text: String?,
        depthLimit: Int = defaultDepthLimit
    ) -> PartialJSONResult {
        guard let text, !text.allSatisfy(\.isWhitespace) else {
            return PartialJSONResult(value: .object([:]), completeness: .repaired)
        }
        if let result = try? parse(text, depthLimit: depthLimit) {
            return result
        }
        // The parser already handles everything `repairJson` fixes, so this
        // second attempt only pays off for inputs the pre-pass rewrites into a
        // different shape entirely. Kept because it is upstream's last line of
        // defence and costs one allocation on an already-failed path.
        let repaired = repairJSON(text)
        if repaired != text, let result = try? parse(repaired, depthLimit: depthLimit) {
            return PartialJSONResult(value: result.value, completeness: .repaired)
        }
        return PartialJSONResult(value: .object([:]), completeness: .repaired)
    }

    // MARK: Repair

    /// Repairs malformed JSON string literals, byte for byte as pi's
    /// `repairJson` does: raw control characters inside strings get escaped,
    /// and a backslash that does not begin a valid escape gets doubled.
    ///
    /// Models emit both, routinely — an unescaped newline inside a `content`
    /// argument, or a Windows path written `"C:\Users"`.
    ///
    /// Note that a `\u` followed by non-hex is left alone, matching upstream:
    /// `u` is itself a valid escape initial, so the doubling branch never sees
    /// it. ``parse(_:depthLimit:)`` cleans up after that case on its own.
    public static func repairJSON(_ json: String) -> String {
        let bytes = Array(json.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inString = false
        var i = 0

        while i < bytes.count {
            let byte = bytes[i]

            guard inString else {
                out.append(byte)
                if byte == .quote { inString = true }
                i += 1
                continue
            }

            if byte == .quote {
                out.append(byte)
                inString = false
                i += 1
                continue
            }

            if byte == .backslash {
                guard i + 1 < bytes.count else {
                    out.append(.backslash)
                    out.append(.backslash)
                    i += 1
                    continue
                }
                let next = bytes[i + 1]

                if next == .lowerU, i + 5 < bytes.count,
                    bytes[(i + 2)...(i + 5)].allSatisfy(\.isHexDigit)
                {
                    out.append(contentsOf: bytes[i...(i + 5)])
                    i += 6
                    continue
                }

                if next.isValidEscapeInitial {
                    out.append(.backslash)
                    out.append(next)
                    i += 2
                    continue
                }

                out.append(.backslash)
                out.append(.backslash)
                i += 1
                continue
            }

            if byte < 0x20 {
                out.append(contentsOf: UInt8.escapedControl(byte))
            } else {
                out.append(byte)
            }
            i += 1
        }

        return String(decoding: out, as: UTF8.self)
    }

    /// Strict parse, retried once against ``repairJSON(_:)``. Port of pi's
    /// `parseJsonWithRepair`: for input that is supposed to be whole, where a
    /// silently truncated value would be worse than a thrown error.
    ///
    /// Rethrows the *original* error when the repair pass changed nothing, so
    /// the diagnostic describes the input the caller actually supplied.
    public static func parseWithRepair(_ text: String) throws -> JSONValue {
        do {
            return try JSONValue(parsing: text)
        } catch {
            let repaired = repairJSON(text)
            guard repaired != text else { throw error }
            return try JSONValue(parsing: repaired)
        }
    }
}

// MARK: - Parser

/// Recursive descent over UTF-8 bytes.
///
/// Bytes rather than `Character` or `Unicode.Scalar` because the input is a
/// stream prefix that can end in the middle of a scalar; grapheme breaking a
/// buffer that is by construction incomplete is both slower and wrong.
private struct PartialJSONParser {
    let bytes: [UInt8]
    let depthLimit: Int
    var index = 0
    var didRepair = false

    init(bytes: [UInt8], depthLimit: Int) {
        self.bytes = bytes
        self.depthLimit = depthLimit
    }

    /// U+FFFD, the stand-in for a surrogate that has no Swift representation.
    static let replacementCharacter: Unicode.Scalar = "\u{FFFD}"

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

    /// Returns `nil` when no value could be recovered at this position, having
    /// set `didRepair`. Callers treat that as "the container ends here".
    mutating func parseValue(depth: Int) throws(PartialJSONError) -> JSONValue? {
        skipWhitespace()
        guard let byte = peek() else {
            didRepair = true
            return nil
        }
        switch byte {
        case .quote:
            return .string(parseString())
        case .leftBrace:
            return try parseObject(depth: depth)
        case .leftBracket:
            return try parseArray(depth: depth)
        case .lowerT, .lowerF, .lowerN:
            return parseKeyword()
        default:
            return parseNumber()
        }
    }

    // MARK: Keywords

    private static let keywords: [(text: [UInt8], value: JSONValue)] = [
        (Array("true".utf8), .bool(true)),
        (Array("false".utf8), .bool(false)),
        (Array("null".utf8), .null),
    ]

    /// Upstream completes a keyword truncated to a proper prefix *at EOF* —
    /// `tru` becomes `true`, `nul` becomes `null` — and this port keeps that.
    /// It is only reachable at the very end of the buffer, so the guess is
    /// between a keyword and nothing, never between two keywords: no JSON
    /// keyword is a prefix of another.
    private mutating func parseKeyword() -> JSONValue? {
        for keyword in Self.keywords where matches(keyword.text) {
            index += keyword.text.count
            return keyword.value
        }
        for keyword in Self.keywords where isTruncatedPrefix(of: keyword.text) {
            index = bytes.count
            didRepair = true
            return keyword.value
        }
        didRepair = true
        return nil
    }

    private func matches(_ word: [UInt8]) -> Bool {
        guard index + word.count <= bytes.count else { return false }
        for (offset, byte) in word.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    private func isTruncatedPrefix(of word: [UInt8]) -> Bool {
        let remaining = bytes.count - index
        guard remaining > 0, remaining < word.count else { return false }
        for offset in 0..<remaining where bytes[index + offset] != word[offset] {
            return false
        }
        return true
    }

    // MARK: Numbers

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        while index < bytes.count, bytes[index].isNumberByte { index += 1 }
        guard index > start else {
            didRepair = true
            return nil
        }

        let token = Array(bytes[start..<index])

        // `1.2e`, `1e+`, `1.` — the stream stopped inside the literal. Upstream
        // truncates at the last `e` and retries; keeping the longest prefix that
        // satisfies the grammar is the same idea and also recovers the
        // fractional-point case, which upstream turns into a malformed-JSON
        // throw that discards the whole enclosing container.
        let kept = Self.longestWellFormedPrefix(token)
        if kept == token.count { return Self.number(fromWellFormed: token) }

        didRepair = true
        guard kept > 0 else { return nil }
        return Self.number(fromWellFormed: Array(token[0..<kept]))
    }

    /// Length of the longest prefix of `token` that is a complete JSON number,
    /// or `0` when no prefix is one.
    ///
    /// The grammar here is stricter than `Double.init(_:)`: `0x10`, `1_0`, `+1`,
    /// `.5`, `1.` and `nan` all parse as `Double` and none of them are JSON.
    ///
    /// Found in one left-to-right pass rather than by trimming a byte at a time
    /// and revalidating. `isNumberByte` accepts `.`, `e`, `E`, `+` and `-`
    /// anywhere, so `0.` + 10_000 digits + 1_000_000 periods is a *single*
    /// number token; trim-and-revalidate rescans the whole digit run on every
    /// trim and took four seconds on that input in release. A model does not
    /// have to be adversarial to emit a long digit run followed by junk, and
    /// streaming re-parses the accumulated buffer on every chunk.
    private static func longestWellFormedPrefix(_ token: [UInt8]) -> Int {
        var i = 0
        let count = token.count
        if i < count, token[i] == .minus { i += 1 }

        guard i < count, token[i].isDigit else { return 0 }
        if token[i] == .zero {
            i += 1
            // A leading zero may not be followed by more digits, so the longest
            // valid prefix stops right after it: `0123` yields `0`.
            if i < count, token[i].isDigit { return i }
        } else {
            while i < count, token[i].isDigit { i += 1 }
        }
        var best = i

        if i < count, token[i] == .period {
            var j = i + 1
            guard j < count, token[j].isDigit else { return best }
            while j < count, token[j].isDigit { j += 1 }
            i = j
            best = j
        }

        if i < count, token[i] == .lowerE || token[i] == .upperE {
            var j = i + 1
            if j < count, token[j] == .plus || token[j] == .minus { j += 1 }
            guard j < count, token[j].isDigit else { return best }
            while j < count, token[j].isDigit { j += 1 }
            best = j
        }

        return best
    }

    /// `nil` for a grammatically valid literal that no Swift number can hold
    /// (`1e999`). Dropping it beats returning `.double(.infinity)`, which
    /// re-encodes as invalid JSON and fails much further from the cause.
    private static func number(fromWellFormed token: [UInt8]) -> JSONValue? {
        let text = String(decoding: token, as: UTF8.self)
        let isIntegral = !token.contains {
            $0 == .period || $0 == .lowerE || $0 == .upperE
        }
        if isIntegral, let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { return nil }
        return .double(value)
    }

    // MARK: Strings

    /// Always returns a string: an unterminated literal closes where the input
    /// stopped. `didRepair` carries the news.
    private mutating func parseString() -> String {
        index += 1
        var out: [UInt8] = []

        while index < bytes.count {
            let byte = bytes[index]

            if byte == .quote {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }

            if byte == .backslash {
                if appendEscape(into: &out) { continue }
                return finishTruncated(out)
            }

            // Raw control characters are illegal in a JSON string and models
            // emit them constantly. Kept verbatim rather than dropped: an
            // unescaped newline in a file-edit argument is content.
            if byte < 0x20 { didRepair = true }
            out.append(byte)
            index += 1
        }

        return finishTruncated(out)
    }

    /// Consumes one escape sequence. Returns `false` when the input ran out
    /// inside it, in which case the partial escape has been discarded and the
    /// string must be closed.
    private mutating func appendEscape(into out: inout [UInt8]) -> Bool {
        index += 1
        guard index < bytes.count else {
            index = bytes.count
            return false
        }

        let escape = bytes[index]
        switch escape {
        case .quote, .backslash, .slash:
            out.append(escape)
        case .lowerB: out.append(0x08)
        case .lowerF: out.append(0x0C)
        case .lowerN: out.append(0x0A)
        case .lowerR: out.append(0x0D)
        case .lowerT: out.append(0x09)
        case .lowerU:
            return appendUnicodeEscape(into: &out)
        default:
            // An unknown escape becomes a literal backslash and character —
            // the same result `repairJSON(_:)` would have produced by doubling
            // the backslash, so the two paths agree on `"C:\Users"`.
            didRepair = true
            out.append(.backslash)
            out.append(escape)
        }
        index += 1
        return true
    }

    /// `index` is on the `u` on entry and one past the whole escape on return —
    /// unlike the single-character escapes, which share `appendEscape`'s final
    /// increment.
    private mutating func appendUnicodeEscape(into out: inout [UInt8]) -> Bool {
        switch readHexQuad(at: index + 1) {
        case .truncated:
            index = bytes.count
            return false
        case .invalid:
            didRepair = true
            out.append(.backslash)
            out.append(.lowerU)
            index += 1
            return true
        case .value(let code):
            index += 5
            return appendScalar(code, into: &out)
        }
    }

    /// `index` is one past the escape that produced `code`.
    private mutating func appendScalar(_ code: UInt32, into out: inout [UInt8]) -> Bool {
        if (0xD800...0xDBFF).contains(code) {
            switch lowSurrogate(after: index) {
            case .truncated:
                // The pair's second half never arrived. Dropping the orphan is
                // the only honest option: Swift's `String` cannot hold a lone
                // surrogate at all, so there is nothing to keep.
                index = bytes.count
                return false
            case .invalid:
                didRepair = true
                append(scalar: Self.replacementCharacter, to: &out)
            case .value(let low):
                index += 6
                let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                append(scalar: Unicode.Scalar(combined) ?? Self.replacementCharacter, to: &out)
            }
            return true
        }

        if (0xDC00...0xDFFF).contains(code) {
            didRepair = true
            append(scalar: Self.replacementCharacter, to: &out)
            return true
        }

        append(scalar: Unicode.Scalar(code) ?? Self.replacementCharacter, to: &out)
        return true
    }

    private func append(scalar: Unicode.Scalar, to out: inout [UInt8]) {
        out.append(contentsOf: Array(String(scalar).utf8))
    }

    private enum HexQuad {
        case value(UInt32)
        /// Ran off the end of the buffer — the stream was cut inside the escape.
        case truncated
        /// A non-hex byte arrived while the buffer still had room.
        case invalid
    }

    private func readHexQuad(at start: Int) -> HexQuad {
        var code: UInt32 = 0
        for offset in 0..<4 {
            let position = start + offset
            guard position < bytes.count else { return .truncated }
            guard let digit = bytes[position].hexDigitValue else { return .invalid }
            code = code << 4 | UInt32(digit)
        }
        return .value(code)
    }

    /// Looks for `\uDC00`-`\uDFFF` at `start` without consuming it.
    private func lowSurrogate(after start: Int) -> HexQuad {
        guard start < bytes.count else { return .truncated }
        guard bytes[start] == .backslash else { return .invalid }
        guard start + 1 < bytes.count else { return .truncated }
        guard bytes[start + 1] == .lowerU else { return .invalid }
        switch readHexQuad(at: start + 2) {
        case .value(let code):
            return (0xDC00...0xDFFF).contains(code) ? .value(code) : .invalid
        case .truncated: return .truncated
        case .invalid: return .invalid
        }
    }

    private mutating func finishTruncated(_ out: [UInt8]) -> String {
        didRepair = true
        var bytes = out
        Self.dropIncompleteTrailingScalar(&bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A chunk boundary can fall inside a multi-byte scalar. Without this the
    /// preview shows a U+FFFD that will vanish on the next chunk, which reads
    /// as corruption rather than as progress.
    private static func dropIncompleteTrailingScalar(_ out: inout [UInt8]) {
        var continuations = 0
        var i = out.count - 1
        while i >= 0, continuations <= 3 {
            let byte = out[i]
            if byte & 0xC0 == 0x80 {
                continuations += 1
                i -= 1
                continue
            }
            let needed: Int
            switch byte {
            case 0x00...0x7F: needed = 1
            case 0xC0...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF7: needed = 4
            default: return  // Stray continuation run or invalid lead; not our business.
            }
            let available = continuations + 1
            if available < needed { out.removeLast(available) }
            return
        }
    }

    // MARK: Containers

    private mutating func parseObject(depth: Int) throws(PartialJSONError) -> JSONValue {
        guard depth < depthLimit else {
            throw PartialJSONError.depthLimitExceeded(byteOffset: index)
        }
        index += 1
        var object: [String: JSONValue] = [:]
        var afterComma = false

        while true {
            skipWhitespace()
            guard let byte = peek() else {
                didRepair = true
                return .object(object)
            }

            if byte == .rightBrace {
                if afterComma { didRepair = true }
                index += 1
                return .object(object)
            }

            if byte == .comma {
                didRepair = true
                index += 1
                afterComma = true
                continue
            }

            // A key that is not a string literal means the input is malformed
            // in a way truncation cannot explain. Close here rather than
            // guessing at an unquoted key, which upstream does and turns
            // `{a:1}` into `{"a:1}": …}`.
            guard byte == .quote else {
                didRepair = true
                return .object(object)
            }

            let key = parseString()

            skipWhitespace()
            guard peek() == UInt8.colon else {
                // Dangling key: `{"path"` or `{"path":`. Dropped, not emitted
                // with a placeholder value — a preview showing `path: null` is
                // a claim the model never made.
                didRepair = true
                return .object(object)
            }
            index += 1

            guard let value = try parseValue(depth: depth + 1) else {
                didRepair = true
                return .object(object)
            }
            object[key] = value
            afterComma = false

            skipWhitespace()
            guard let separator = peek() else {
                didRepair = true
                return .object(object)
            }
            if separator == .comma {
                index += 1
                afterComma = true
                continue
            }
            if separator == .rightBrace {
                index += 1
                return .object(object)
            }
            didRepair = true
            return .object(object)
        }
    }

    private mutating func parseArray(depth: Int) throws(PartialJSONError) -> JSONValue {
        guard depth < depthLimit else {
            throw PartialJSONError.depthLimitExceeded(byteOffset: index)
        }
        index += 1
        var array: [JSONValue] = []
        var afterComma = false

        while true {
            skipWhitespace()
            guard let byte = peek() else {
                didRepair = true
                return .array(array)
            }

            if byte == .rightBracket {
                if afterComma { didRepair = true }
                index += 1
                return .array(array)
            }

            if byte == .comma {
                didRepair = true
                index += 1
                afterComma = true
                continue
            }

            guard let value = try parseValue(depth: depth + 1) else {
                didRepair = true
                return .array(array)
            }
            array.append(value)
            afterComma = false

            skipWhitespace()
            guard let separator = peek() else {
                didRepair = true
                return .array(array)
            }
            if separator == .comma {
                index += 1
                afterComma = true
                continue
            }
            if separator == .rightBracket {
                index += 1
                return .array(array)
            }
            didRepair = true
            return .array(array)
        }
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

    fileprivate var isNumberByte: Bool {
        isDigit || self == .minus || self == .plus || self == .period
            || self == .lowerE || self == .upperE
    }

    fileprivate var isHexDigit: Bool { hexDigitValue != nil }

    fileprivate var hexDigitValue: UInt8? {
        switch self {
        case 0x30...0x39: return self - 0x30
        case 0x41...0x46: return self - 0x41 + 10
        case 0x61...0x66: return self - 0x61 + 10
        default: return nil
        }
    }

    /// The characters JSON permits directly after a backslash.
    fileprivate var isValidEscapeInitial: Bool {
        switch self {
        case .quote, .backslash, .slash, .lowerB, .lowerF, .lowerN, .lowerR, .lowerT, .lowerU:
            return true
        default:
            return false
        }
    }

    fileprivate static func escapedControl(_ byte: UInt8) -> [UInt8] {
        switch byte {
        case 0x08: return Array("\\b".utf8)
        case 0x0C: return Array("\\f".utf8)
        case 0x0A: return Array("\\n".utf8)
        case 0x0D: return Array("\\r".utf8)
        case 0x09: return Array("\\t".utf8)
        default:
            let digits = "0123456789abcdef".utf8.map { $0 }
            return [
                .backslash, .lowerU, .zero, .zero,
                digits[Int(byte >> 4)], digits[Int(byte & 0x0F)],
            ]
        }
    }
}
