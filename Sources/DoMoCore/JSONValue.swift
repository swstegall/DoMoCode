// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A fully-decoded JSON value.
///
/// This exists because the LLM wire format is heterogeneous in ways `Codable`
/// alone handles badly: tool-call arguments are arbitrary caller-defined
/// objects, provider responses carry vendor extensions nobody modeled, and tool
/// results must round-trip whatever a tool produced without the harness knowing
/// its shape.
///
/// `AnyCodable` is the usual answer and the wrong one here — it stores `Any`,
/// which is not `Sendable`, and this type crosses isolation boundaries
/// constantly. `JSONValue` is a plain enum, so `Sendable` and `Equatable` are
/// structural and free.
///
/// Numbers are deliberately split into `.int` and `.double` rather than
/// collapsed into one case. JSON has a single number type, but round-tripping
/// `1` as `1.0` corrupts tool arguments that a receiving tool then reads as an
/// array index or a token count.
///
/// Integral values normalize to `.int` however they were spelled, so `1.0`
/// decodes as `.int(1)`. That is a canonicalization rather than a loss — the
/// two denote the same JSON number — and it buys exactness past 2^53, where a
/// `Double` can no longer represent consecutive integers.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Typed accessors

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The value as an `Int`.
    ///
    /// Also converts from `.double` when the value is integral and within
    /// `Int`'s range. `JSONSerialization` and most JSON encoders surface whole
    /// numbers as `Double` depending on how they were written, and a caller
    /// asking for an array index should not have to care which arrived.
    public var intValue: Int? {
        switch self {
        case .int(let i):
            return i
        case .double(let d):
            guard d.rounded() == d, d >= -9_007_199_254_740_992, d <= 9_007_199_254_740_992 else {
                return nil
            }
            return Int(d)
        default:
            return nil
        }
    }

    /// The value as a `Double`, widening from `.int` when needed.
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - Subscripts

extension JSONValue {
    /// Member access, returning `nil` for a non-object or a missing key.
    ///
    /// Non-failing by design: reading vendor extensions off a provider response
    /// means walking paths that legitimately may not exist, and forcing every
    /// such read through `guard case .object` obscures the reading code.
    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let o) = self else { return nil }
            return o[key]
        }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    /// Element access, returning `nil` for a non-array or an out-of-bounds
    /// index. Negative indices return `nil` rather than trapping.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Order matters. `Bool` is attempted before the numeric types because
        // some decoders will happily decode `true` as `1`; `Int` is attempted
        // before `Double` so whole numbers keep their integer identity.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Encodes to UTF-8 JSON.
    ///
    /// Keys are sorted so output is byte-stable across runs. Session files are
    /// diffed and content-hashed, and `Dictionary` ordering is not stable
    /// between processes.
    public func encoded(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Encodes to a UTF-8 JSON string.
    public func encodedString(prettyPrinted: Bool = false) throws -> String {
        let data = try encoded(prettyPrinted: prettyPrinted)
        // JSONEncoder emits UTF-8 by contract, so this cannot fail in practice.
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONValueError.invalidUTF8
        }
        return string
    }

    /// Decodes from UTF-8 JSON.
    ///
    /// This is the strict parser. For model output that may be truncated
    /// mid-stream, use the tolerant parser instead.
    public init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes from a JSON string.
    public init(parsing string: String) throws {
        try self.init(parsing: Data(string.utf8))
    }
}

/// Failures that can arise converting a ``JSONValue`` to or from bytes.
public enum JSONValueError: Error, Sendable, Equatable {
    /// Encoded output was not valid UTF-8. Not reachable via `JSONEncoder`,
    /// which emits UTF-8 by contract; present so the conversion need not
    /// force-unwrap.
    case invalidUTF8
}

// MARK: - Description

extension JSONValue: CustomStringConvertible {
    /// Compact JSON, or a diagnostic placeholder if encoding somehow fails.
    ///
    /// `description` cannot throw, and this type appears in error messages and
    /// log lines where a placeholder is far better than a crash.
    public var description: String {
        (try? encodedString()) ?? "<unencodable JSON>"
    }
}
