// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A tiny order-preserving JSON parser, used ONLY to read the `permission` block from
// settings.json. `JSONValue`/`JSONDecoder` both store objects as unordered
// dictionaries, but permission precedence is last-match-wins, so a rule block's key
// order is load-bearing (`{ "*": "deny", "git *": "allow" }` means "deny all but git";
// reversed, git is denied). This parses objects as ordered `[(key, value)]` lists so
// `fromConfig` sees the author's order. Other settings keys are parsed (to be skipped
// correctly) but their values are otherwise unused.
//
// ## Why the grammar is not strict RFC 8259
//
// settings.json is read TWICE — by `JSONDecoder` for `Settings`, and by this parser
// for the `permission` block — and the two must accept exactly the same documents.
// When they disagree the failure is silent and total: a user with one trailing comma
// anywhere in the file keeps their `model` and `baseUrl` (Foundation shrugs) while
// their entire permission block evaporates to `[]`, and every "Allow always" they
// click afterwards is refused persistence with no message. So this deliberately
// accepts the two things Foundation accepts and RFC 8259 does not — a trailing comma
// before `}` or `]`, and a leading UTF-8 BOM — and nothing else. Both were verified
// against `JSONDecoder` on this platform rather than assumed; see
// `OrderedJSONGrammarTests`, which re-checks the agreement so a Foundation change
// cannot reintroduce the divergence quietly.
//
// The other half of that fix is that a parse failure is now REPORTABLE:
// ``parseOrderedJSON(text:file:)`` throws a ``ConfigDiagnostic`` carrying the offset,
// the key path and a caret. The optional-returning ``parseOrderedJSON(_:)`` remains
// for callers that genuinely have nothing to say about a failure.

import DoMoCore

/// A JSON value whose objects preserve key insertion order.
public indirect enum OrderedJSONValue: Sendable, Equatable {
    case string(String)
    /// The raw number TOKEN as written, serialized back verbatim — so a round-trip
    /// (read → write a grant → save) never reformats a large integer, an exponent, or
    /// a trailing-zero float in some OTHER settings key.
    case number(String)
    case bool(Bool)
    case null
    case array([OrderedJSONValue])
    case object([(key: String, value: OrderedJSONValue)])

    public static func == (lhs: OrderedJSONValue, rhs: OrderedJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    /// The value for `key` in an object, or nil.
    ///
    /// A duplicated key resolves to its **first** occurrence, which is what
    /// `JSONDecoder` does with the same bytes (verified on this platform, and pinned
    /// by `OrderedJSONGrammarTests`). The alignment is the point: if the two readers
    /// of settings.json picked different occurrences of a duplicated `permission`
    /// key, the block the engine enforced would not be the block the rest of the
    /// file was read from. Duplicates are accepted rather than rejected for the same
    /// reason — rejecting what Foundation accepts is the failure mode this file
    /// exists to prevent.
    public subscript(_ key: String) -> OrderedJSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }
}

/// Parses JSON text into an ``OrderedJSONValue``, or throws a ``ConfigDiagnostic``
/// pointing at the byte that stopped it.
///
/// - Parameters:
///   - text: The document.
///   - file: The path to name in the diagnostic, when the text came from one.
public func parseOrderedJSON(text: String, file: String? = nil) throws(ConfigDiagnostic) -> OrderedJSONValue {
    var parser = OrderedJSONParser(Array(text.unicodeScalars))
    guard let value = parser.parseDocument() else {
        throw parser.diagnostic(file: file, text: text)
    }
    return value
}

/// Parses JSON text into an ``OrderedJSONValue``, or nil on malformed input or
/// trailing garbage.
///
/// Prefer ``parseOrderedJSON(text:file:)`` anywhere the user could be told what went
/// wrong; a bare nil here is only appropriate where there is nothing to report to.
public func parseOrderedJSON(_ text: String) -> OrderedJSONValue? {
    try? parseOrderedJSON(text: text)
}

private struct OrderedJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    /// The key path in progress, so a diagnostic can name the setting and not only
    /// the offset. Never unwound on the failure path — ``record(_:at:)`` copies it at
    /// the moment of failure, and the parse is abandoned immediately afterwards.
    private var path: [String] = []

    private var failureProblem: String?
    private var failureIndex: Int?
    private var failurePath: [String] = []

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    var isAtEnd: Bool { index >= scalars.count }
    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    // MARK: - Failure reporting

    /// Records the FIRST failure and keeps it. Later frames unwinding through
    /// `return nil` would otherwise overwrite the innermost, most specific complaint
    /// with the outermost, least useful one ("the file is not valid JSON").
    private mutating func record(_ problem: String, at position: Int? = nil) {
        guard failureProblem == nil else { return }
        failureProblem = problem
        failureIndex = position ?? index
        failurePath = path
    }

    private mutating func fail<T>(_ problem: String, at position: Int? = nil) -> T? {
        record(problem, at: position)
        return nil
    }

    /// The diagnostic for a parse that returned nil.
    ///
    /// `text` is passed back in rather than reconstructed from `scalars` so the byte
    /// offsets are offsets into the caller's actual bytes.
    func diagnostic(file: String?, text: String) -> ConfigDiagnostic {
        ConfigDiagnostic(
            file: file,
            source: Array(text.utf8),
            byteOffset: byteOffset(ofScalarIndex: failureIndex ?? scalars.count),
            keyPath: failurePath,
            problem: failureProblem ?? "the file is not valid JSON"
        )
    }

    /// The UTF-8 byte offset of a scalar index.
    ///
    /// Computed on the failure path only: the parser indexes scalars (so a `\u` escape
    /// and a caret column are natural), while ``ConfigDiagnostic`` locates by byte, and
    /// carrying both counters through every `index += 1` would be one more thing to
    /// keep in agreement.
    private func byteOffset(ofScalarIndex target: Int) -> Int {
        var offset = 0
        for position in 0..<min(max(0, target), scalars.count) {
            offset += Self.utf8Length(scalars[position])
        }
        return offset
    }

    private static func utf8Length(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }

    // MARK: - Grammar

    mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 }
    }

    /// A whole document: one value, optionally preceded by a byte-order mark and
    /// followed by nothing but whitespace.
    mutating func parseDocument() -> OrderedJSONValue? {
        // A UTF-8 BOM decodes to U+FEFF, which is not JSON whitespace — but
        // Foundation skips exactly one, and only as the very first scalar (`  \u{FEFF}{}`
        // and `{\u{FEFF}}` are both rejected there). Matching that exactly, rather
        // than treating U+FEFF as whitespace generally, keeps the two parsers
        // accepting the same set of files in both directions.
        if index == 0, current == "\u{FEFF}" { index += 1 }
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        guard isAtEnd else { return fail("unexpected content after the top-level value") }
        return value
    }

    mutating func parseValue() -> OrderedJSONValue? {
        skipWhitespace()
        guard let c = current else { return fail("unexpected end of input, expected a value") }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map(OrderedJSONValue.string)
        case "t", "f": return parseBool()
        case "n": return parseNull()
        default: return parseNumber()
        }
    }

    private mutating func expect(_ scalar: Unicode.Scalar) -> Bool {
        skipWhitespace()
        guard current == scalar else { return false }
        index += 1
        return true
    }

    private mutating func parseObject() -> OrderedJSONValue? {
        guard expect("{") else { return fail("expected '{'") }
        var pairs: [(key: String, value: OrderedJSONValue)] = []
        skipWhitespace()
        if current == "}" { index += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard current == "\"" else {
                return fail(
                    current == nil
                        ? "unexpected end of input, expected an object key"
                        : "expected a quoted object key"
                )
            }
            guard let key = parseString() else { return nil }
            guard expect(":") else { return fail("expected ':' after the object key \"\(key)\"") }
            path.append(key)
            guard let value = parseValue() else { return nil }
            path.removeLast()
            pairs.append((key: key, value: value))
            skipWhitespace()
            if current == "," {
                index += 1
                // A trailing comma. Foundation accepts it and so must this — see the
                // file header; the two parsers disagreeing here silently deletes the
                // user's whole permission block.
                skipWhitespace()
                if current == "}" { index += 1; return .object(pairs) }
                continue
            }
            if current == "}" { index += 1; return .object(pairs) }
            return fail(
                current == nil
                    ? "unexpected end of input, expected ',' or '}'"
                    : "expected ',' or '}' after an object member"
            )
        }
    }

    private mutating func parseArray() -> OrderedJSONValue? {
        guard expect("[") else { return fail("expected '['") }
        var items: [OrderedJSONValue] = []
        skipWhitespace()
        if current == "]" { index += 1; return .array(items) }
        while true {
            path.append(String(items.count))
            guard let value = parseValue() else { return nil }
            path.removeLast()
            items.append(value)
            skipWhitespace()
            if current == "," {
                index += 1
                // Trailing comma, as in `parseObject`.
                skipWhitespace()
                if current == "]" { index += 1; return .array(items) }
                continue
            }
            if current == "]" { index += 1; return .array(items) }
            return fail(
                current == nil
                    ? "unexpected end of input, expected ',' or ']'"
                    : "expected ',' or ']' after an array element"
            )
        }
    }

    private mutating func parseString() -> String? {
        let opening = index
        guard current == "\"" else { return fail("expected a string") }
        index += 1
        var result = String.UnicodeScalarView()
        while let c = current {
            index += 1
            if c == "\"" { return String(result) }
            if c == "\\" {
                guard let escape = current else {
                    return fail("unexpected end of input inside a string escape")
                }
                index += 1
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    result.append(scalar)
                default: return fail("invalid string escape \"\\\(escape)\"", at: index - 1)
                }
                continue
            }
            result.append(c)
        }
        return fail("unterminated string", at: opening)
    }

    /// Four hex digits, consumed. A method rather than a nested function so that the
    /// failure-recording calls around it are ordinary accesses to `self` and not
    /// interleaved with a local function's capture of it.
    private mutating func hex4() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let c = current, let digit = c.hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard let first = hex4() else { return fail("expected four hexadecimal digits after \\u") }
        // Surrogate pair.
        if first >= 0xD800, first <= 0xDBFF {
            guard current == "\\", index + 1 < scalars.count, scalars[index + 1] == "u" else {
                return fail("expected a low surrogate \\u escape after a high surrogate")
            }
            index += 2
            guard let second = hex4(), second >= 0xDC00, second <= 0xDFFF else {
                return fail("expected a low surrogate in the range \\uDC00-\\uDFFF")
            }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            return Unicode.Scalar(combined)
        }
        guard let scalar = Unicode.Scalar(first) else {
            return fail("\\u escape is an unpaired surrogate, which is not a character")
        }
        return scalar
    }

    private mutating func parseBool() -> OrderedJSONValue? {
        let start = index
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        return fail("expected 'true' or 'false'", at: start)
    }

    private mutating func parseNull() -> OrderedJSONValue? {
        let start = index
        if match("null") { return .null }
        return fail("expected 'null'", at: start)
    }

    private mutating func match(_ literal: String) -> Bool {
        let target = Array(literal.unicodeScalars)
        guard index + target.count <= scalars.count else { return false }
        for (offset, scalar) in target.enumerated() where scalars[index + offset] != scalar { return false }
        index += target.count
        return true
    }

    private mutating func parseNumber() -> OrderedJSONValue? {
        let start = index
        if current == "-" { index += 1 }
        while let c = current, ("0"..."9").contains(c) || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
            index += 1
        }
        guard start < index else {
            let found = current.map { "'\($0)'" } ?? "end of input"
            return fail("expected a value, found \(found)", at: start)
        }
        let string = String(String.UnicodeScalarView(scalars[start..<index]))
        // Validated, but the raw token is what is kept and written back.
        guard Double(string) != nil else { return fail("\"\(string)\" is not a number", at: start) }
        return .number(string)
    }
}

/// Serialize an ``OrderedJSONValue`` back to pretty-printed JSON text (2-space
/// indent), preserving object key order. Used to write a settings.json back after
/// its `permission` block is updated, leaving every other key untouched.
public func serializeOrderedJSON(_ value: OrderedJSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent)
    let childPad = String(repeating: " ", count: indent + 2)
    switch value {
    case .string(let s): return encodeJSONString(s)
    case .number(let raw): return raw  // verbatim — no reformatting
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array(let items):
        if items.isEmpty { return "[]" }
        let body = items.map { childPad + serializeOrderedJSON($0, indent: indent + 2) }.joined(separator: ",\n")
        return "[\n" + body + "\n" + pad + "]"
    case .object(let pairs):
        if pairs.isEmpty { return "{}" }
        let body = pairs
            .map { childPad + encodeJSONString($0.key) + ": " + serializeOrderedJSON($0.value, indent: indent + 2) }
            .joined(separator: ",\n")
        return "{\n" + body + "\n" + pad + "}"
    }
}

/// A JSON string literal with the standard escapes.
private func encodeJSONString(_ string: String) -> String {
    var result = "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        case "\r": result += "\\r"
        case "\u{08}": result += "\\b"
        case "\u{0C}": result += "\\f"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

extension Unicode.Scalar {
    fileprivate var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61 + 10)
        case "A"..."F": return Int(value - 0x41 + 10)
        default: return nil
        }
    }
}
