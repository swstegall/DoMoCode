// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

import DoMoCore

@Suite("JSONValue")
struct JSONValueTests {

    // MARK: - Number identity

    /// The reason `.int` and `.double` are separate cases. A tool argument that
    /// went out as `1` must not come back as `1.0`, because the receiving tool
    /// may read it as an array index or a line number.
    @Test("Whole numbers survive a round trip as integers")
    func integersDoNotBecomeDoubles() throws {
        let value = try JSONValue(parsing: #"{"line": 42}"#)
        #expect(value["line"] == .int(42))
        #expect(try value.encodedString() == #"{"line":42}"#)
    }

    @Test("Fractional numbers stay doubles")
    func doublesStayDoubles() throws {
        let value = try JSONValue(parsing: #"{"temperature": 0.7}"#)
        #expect(value["temperature"] == .double(0.7))
    }

    /// Integral values normalize to `.int` however they were spelled, because
    /// JSON has a single number type and `1` and `1.0` denote the same number.
    /// The direction that would actually be lossy — `42` arriving as `42.0` —
    /// is the one prevented.
    @Test("Integral values normalize to .int regardless of spelling")
    func integralValuesNormalize() throws {
        #expect(try JSONValue(parsing: "1.0") == .int(1))
        #expect(try JSONValue(parsing: "1e18") == .int(1_000_000_000_000_000_000))
    }

    /// A consequence of attempting `Int` before `Double`, and a real win rather
    /// than an accident: past 2^53 a `Double` cannot represent consecutive
    /// integers, so decoding numerically-first would silently round. A session
    /// id or byte offset in that range survives exactly.
    @Test("Integers beyond 2^53 keep full precision")
    func largeIntegersKeepPrecision() throws {
        let value = try JSONValue(parsing: "9007199254740993")
        #expect(value == .int(9_007_199_254_740_993))
        #expect(Double(9_007_199_254_740_993) == 9_007_199_254_740_992, "the precision being avoided")
    }

    @Test("Values needing more precision than Int stay doubles")
    func nonIntegralStaysDouble() throws {
        #expect(try JSONValue(parsing: "1.0000000000000002") == .double(1.0000000000000002))
        #expect(try JSONValue(parsing: "1.5") == .double(1.5))
    }

    /// Non-finite values have no JSON representation; the decoder must reject
    /// rather than coerce them to a sentinel.
    @Test("Overflowing literals are rejected")
    func nonFiniteRejected() {
        #expect(throws: (any Error).self) { try JSONValue(parsing: "1e400") }
    }

    @Test("intValue converts integral doubles but rejects fractional ones")
    func intValueConversion() {
        #expect(JSONValue.double(3.0).intValue == 3)
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.int(7).intValue == 7)
        #expect(JSONValue.string("7").intValue == nil)
    }

    /// Beyond 2^53 a `Double` cannot represent consecutive integers, so
    /// converting would silently return a neighbouring value.
    @Test("intValue rejects doubles beyond exact-integer range")
    func intValueRejectsUnsafeDoubles() {
        #expect(JSONValue.double(1e18).intValue == nil)
        #expect(JSONValue.double(-1e18).intValue == nil)
        #expect(JSONValue.double(9_007_199_254_740_992).intValue != nil)
    }

    @Test("doubleValue widens from int")
    func doubleValueWidens() {
        #expect(JSONValue.int(3).doubleValue == 3.0)
        #expect(JSONValue.double(3.5).doubleValue == 3.5)
        #expect(JSONValue.bool(true).doubleValue == nil)
    }

    // MARK: - Booleans vs numbers

    /// Some decoders will decode `true` as `1`. The decoding order in
    /// `init(from:)` exists to prevent that; this pins it.
    @Test("Booleans do not decode as numbers")
    func boolsAreNotNumbers() throws {
        #expect(try JSONValue(parsing: "true") == .bool(true))
        #expect(try JSONValue(parsing: "false") == .bool(false))
        #expect(try JSONValue(parsing: "1") == .int(1))
        #expect(try JSONValue(parsing: "0") == .int(0))
    }

    // MARK: - Round trips

    @Test("Nested structures round-trip exactly")
    func nestedRoundTrip() throws {
        let source = """
            {"a":[1,2.5,"x",null,true],"b":{"c":{"d":[]}},"e":{}}
            """
        let value = try JSONValue(parsing: source)
        let reencoded = try value.encodedString()
        #expect(try JSONValue(parsing: reencoded) == value)
    }

    /// Session files are diffed and content-hashed, so encoding must be
    /// byte-stable across processes. `Dictionary` ordering is not.
    @Test("Object keys encode in sorted order")
    func keysAreSorted() throws {
        let value: JSONValue = ["zebra": 1, "apple": 2, "mango": 3]
        #expect(try value.encodedString() == #"{"apple":2,"mango":3,"zebra":1}"#)
    }

    @Test("Unicode and escapes survive a round trip")
    func unicodeRoundTrip() throws {
        let value: JSONValue = ["k": "line\nbreak\ttab \"quoted\" \\slash 👨‍👩‍👧‍👦 日本語"]
        let decoded = try JSONValue(parsing: value.encodedString())
        #expect(decoded == value)
    }

    @Test("Empty containers are preserved and distinct")
    func emptyContainers() throws {
        #expect(try JSONValue(parsing: "[]") == .array([]))
        #expect(try JSONValue(parsing: "{}") == .object([:]))
        #expect(JSONValue.array([]) != JSONValue.object([:]))
    }

    // MARK: - Null

    /// `.null` present and key absent are different facts — a provider
    /// explicitly nulling a field is not the same as omitting it.
    @Test("Explicit null is distinct from an absent key")
    func nullIsNotAbsence() throws {
        let value = try JSONValue(parsing: #"{"present": null}"#)
        #expect(value["present"] == .null)
        #expect(value["present"]?.isNull == true)
        #expect(value["absent"] == nil)
    }

    // MARK: - Subscripts

    @Test("Subscripts return nil rather than trapping on the wrong shape")
    func subscriptsAreForgiving() throws {
        let object: JSONValue = ["a": 1]
        let array: JSONValue = [10, 20]

        #expect(object["a"] == .int(1))
        #expect(object["missing"] == nil)
        #expect(object[0] == nil, "member subscript on an object index should be nil")

        #expect(array[0] == .int(10))
        #expect(array[5] == nil)
        #expect(array[-1] == nil, "negative index must not trap")
        #expect(array["key"] == nil)

        #expect(JSONValue.string("x")["key"] == nil)
    }

    @Test("Setting through the member subscript replaces and removes")
    func subscriptSet() {
        var value: JSONValue = ["a": 1]
        value["b"] = .string("two")
        #expect(value["b"] == .string("two"))

        value["a"] = nil
        #expect(value["a"] == nil)
        #expect(value.objectValue?.count == 1)
    }

    /// Setting on a non-object is a no-op rather than a trap or a silent
    /// coercion into an object, which would discard the existing value.
    @Test("Setting on a non-object does nothing")
    func subscriptSetOnNonObject() {
        var value: JSONValue = .string("scalar")
        value["k"] = .int(1)
        #expect(value == .string("scalar"))
    }

    // MARK: - Literals

    @Test("Literal conformances build the expected cases")
    func literals() {
        #expect(JSONValue(nilLiteral: ()) == .null)

        let mixed: JSONValue = ["n": nil, "b": true, "i": 1, "d": 1.5, "s": "x", "a": [1, 2]]
        #expect(mixed["n"] == .null)
        #expect(mixed["b"] == .bool(true))
        #expect(mixed["i"] == .int(1))
        #expect(mixed["d"] == .double(1.5))
        #expect(mixed["s"] == .string("x"))
        #expect(mixed["a"] == .array([.int(1), .int(2)]))
    }

    /// A duplicate key in a dictionary literal traps by default in Swift. The
    /// `uniquingKeysWith` in the initializer makes last-wins explicit instead.
    @Test("Duplicate literal keys take the last value")
    func duplicateLiteralKeys() {
        let value: JSONValue = ["k": 1, "k": 2]
        #expect(value["k"] == .int(2))
    }

    // MARK: - Errors

    @Test("Malformed JSON throws rather than returning a partial value")
    func malformedInputThrows() {
        #expect(throws: (any Error).self) { try JSONValue(parsing: "{") }
        #expect(throws: (any Error).self) { try JSONValue(parsing: #"{"a": }"#) }
        #expect(throws: (any Error).self) { try JSONValue(parsing: "") }
        #expect(throws: (any Error).self) { try JSONValue(parsing: "not json") }
    }

    // MARK: - Description

    /// `description` reaches log lines and error messages, so it must never
    /// trap or throw regardless of contents.
    @Test("description emits compact JSON")
    func descriptionIsCompactJSON() {
        let value: JSONValue = ["b": 2, "a": 1]
        #expect(value.description == #"{"a":1,"b":2}"#)
        #expect(JSONValue.null.description == "null")
    }

    // MARK: - Sendable

    /// The reason this type exists rather than `AnyCodable`: it crosses
    /// isolation boundaries constantly, so `Sendable` has to be structural.
    @Test("Values cross isolation boundaries")
    func sendableAcrossActors() async {
        let value: JSONValue = ["nested": ["deep": [1, 2, 3]]]

        actor Receiver {
            func accept(_ value: JSONValue) -> Int? { value["nested"]?["deep"]?[2]?.intValue }
        }

        let received = await Receiver().accept(value)
        #expect(received == 3)
    }
}
