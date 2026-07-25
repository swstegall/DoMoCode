// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A tiny order-preserving JSON parser, used ONLY to read the `permission` block from
// settings.json. `JSONValue`/`JSONDecoder` both store objects as unordered
// dictionaries, but permission precedence is last-match-wins, so a rule block's key
// order is load-bearing (`{ "*": "deny", "git *": "allow" }` means "deny all but git";
// reversed, git is denied). This parses objects as ordered `[(key, value)]` lists so
// `fromConfig` sees the author's order. Standard JSON grammar; other settings keys are
// parsed (to be skipped correctly) but their values are otherwise unused.

/// A JSON value whose objects preserve key insertion order.
public indirect enum OrderedJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
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

    /// The value for `key` in an object (first occurrence), or nil.
    public subscript(_ key: String) -> OrderedJSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }
}

/// Parses JSON text into an ``OrderedJSONValue``. Returns nil on malformed input or
/// trailing garbage.
public func parseOrderedJSON(_ text: String) -> OrderedJSONValue? {
    var parser = OrderedJSONParser(Array(text.unicodeScalars))
    guard let value = parser.parseValue() else { return nil }
    parser.skipWhitespace()
    guard parser.isAtEnd else { return nil }
    return value
}

private struct OrderedJSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    var isAtEnd: Bool { index >= scalars.count }
    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 }
    }

    mutating func parseValue() -> OrderedJSONValue? {
        skipWhitespace()
        guard let c = current else { return nil }
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
        guard expect("{") else { return nil }
        var pairs: [(key: String, value: OrderedJSONValue)] = []
        skipWhitespace()
        if current == "}" { index += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard current == "\"", let key = parseString() else { return nil }
            guard expect(":") else { return nil }
            guard let value = parseValue() else { return nil }
            pairs.append((key: key, value: value))
            skipWhitespace()
            if current == "," { index += 1; continue }
            if current == "}" { index += 1; return .object(pairs) }
            return nil
        }
    }

    private mutating func parseArray() -> OrderedJSONValue? {
        guard expect("[") else { return nil }
        var items: [OrderedJSONValue] = []
        skipWhitespace()
        if current == "]" { index += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            if current == "," { index += 1; continue }
            if current == "]" { index += 1; return .array(items) }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        guard current == "\"" else { return nil }
        index += 1
        var result = String.UnicodeScalarView()
        while let c = current {
            index += 1
            if c == "\"" { return String(result) }
            if c == "\\" {
                guard let escape = current else { return nil }
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
                default: return nil
                }
                continue
            }
            result.append(c)
        }
        return nil
    }

    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        func hex4() -> UInt32? {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = current, let digit = c.hexDigitValue else { return nil }
                value = value * 16 + UInt32(digit)
                index += 1
            }
            return value
        }
        guard let first = hex4() else { return nil }
        // Surrogate pair.
        if first >= 0xD800, first <= 0xDBFF {
            guard current == "\\" else { return nil }
            index += 1
            guard current == "u" else { return nil }
            index += 1
            guard let second = hex4(), second >= 0xDC00, second <= 0xDFFF else { return nil }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            return Unicode.Scalar(combined)
        }
        return Unicode.Scalar(first)
    }

    private mutating func parseBool() -> OrderedJSONValue? {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        return nil
    }

    private mutating func parseNull() -> OrderedJSONValue? {
        match("null") ? .null : nil
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
        guard start < index else { return nil }
        let string = String(String.UnicodeScalarView(scalars[start..<index]))
        return Double(string).map(OrderedJSONValue.number)
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
    case .number(let n):
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
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
