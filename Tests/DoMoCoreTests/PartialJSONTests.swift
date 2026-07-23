// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

import DoMoCore

/// Parses and asserts the input was strictly valid.
private func complete(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws
    -> JSONValue
{
    let result = try PartialJSON.parse(text)
    #expect(result.completeness == .complete, "\(text)", sourceLocation: sourceLocation)
    return result.value
}

/// Parses and asserts something had to be fixed.
private func repaired(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws
    -> JSONValue
{
    let result = try PartialJSON.parse(text)
    #expect(result.completeness == .repaired, "\(text)", sourceLocation: sourceLocation)
    return result.value
}

private func repaired(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws
    -> JSONValue
{
    let result = try PartialJSON.parse(Data(bytes))
    #expect(result.completeness == .repaired, sourceLocation: sourceLocation)
    return result.value
}

// MARK: - Well-formed input

@Suite("PartialJSON: well-formed input")
struct PartialJSONWellFormedTests {
    @Test("Scalars round-trip and keep their number identity")
    func scalars() throws {
        #expect(try complete("null") == .null)
        #expect(try complete("true") == .bool(true))
        #expect(try complete("false") == .bool(false))
        #expect(try complete("\"hi\"") == .string("hi"))
        #expect(try complete("0") == .int(0))
        #expect(try complete("-17") == .int(-17))
        #expect(try complete("1.5") == .double(1.5))
        #expect(try complete("1e3") == .double(1000))
        #expect(try complete("-2.5E-2") == .double(-0.025))
        #expect(try complete("1.0") == .double(1.0))
    }

    @Test("Integers that overflow Int widen to Double rather than being dropped")
    func bigIntegers() throws {
        #expect(try complete("9223372036854775807") == .int(.max))
        #expect(try complete("99999999999999999999") == .double(1e20))
    }

    @Test("Containers, nesting and whitespace")
    func containers() throws {
        #expect(try complete("[]") == .array([]))
        #expect(try complete("{}") == .object([:]))
        #expect(try complete("  {\n\t\"a\" : [1, {\"b\": null}]\r\n}  ")
            == .object(["a": .array([.int(1), .object(["b": .null])])]))
    }

    @Test("Escape sequences including surrogate pairs")
    func escapes() throws {
        #expect(try complete(#""a\"b\\c\/d\b\f\n\r\te""#) == .string("a\"b\\c/d\u{08}\u{0C}\n\r\te"))
        #expect(try complete(#""\u00e9""#) == .string("é"))
        #expect(try complete(#""\uD83D\uDE00""#) == .string("😀"))
        #expect(try complete(#""\u0041\uD83D\uDE00\u0042""#) == .string("A😀B"))
    }

    @Test("A last-key-wins duplicate matches JSONSerialization")
    func duplicateKeys() throws {
        #expect(try complete(#"{"a":1,"a":2}"#) == .object(["a": .int(2)]))
    }

    @Test("Empty containers with interior whitespace are still complete")
    func emptyContainersWithWhitespace() throws {
        #expect(try complete("[  ]") == .array([]))
        #expect(try complete("{\n}") == .object([:]))
    }

    @Test("The Data overload agrees with the String overload")
    func dataOverload() throws {
        let text = #"{"a":[1,"é"],"b":true}"#
        let fromData = try PartialJSON.parse(Data(text.utf8))
        #expect(fromData == (try PartialJSON.parse(text)))
        #expect(fromData.completeness == .complete)
    }

    @Test("A NUL escape is a character, not a terminator")
    func nulEscape() throws {
        #expect(try complete(##""a\u0000b""##) == .string("a\u{0}b"))
    }
}

// MARK: - Truncation

@Suite("PartialJSON: truncation")
struct PartialJSONTruncationTests {
    @Test("An unterminated string closes where the stream stopped")
    func unterminatedString() throws {
        #expect(try repaired(#""READM"#) == .string("READM"))
        #expect(try repaired(#"{"path":"READM"#) == .object(["path": .string("READM")]))
        #expect(try repaired(#"{"path":"""#) == .object(["path": .string("")]))
    }

    @Test("An unterminated container closes")
    func unterminatedContainer() throws {
        #expect(try repaired("[") == .array([]))
        #expect(try repaired("{") == .object([:]))
        #expect(try repaired("[1,2") == .array([.int(1), .int(2)]))
        #expect(try repaired(#"{"a":{"b":[1,2"#)
            == .object(["a": .object(["b": .array([.int(1), .int(2)])])]))
    }

    @Test("A dangling key is dropped, never emitted with a placeholder value")
    func danglingKey() throws {
        #expect(try repaired(#"{"path"#) == .object([:]))
        #expect(try repaired(#"{"path""#) == .object([:]))
        #expect(try repaired(#"{"path" "#) == .object([:]))
        #expect(try repaired(#"{"path":"#) == .object([:]))
        #expect(try repaired(#"{"a":1,"path":"#) == .object(["a": .int(1)]))
    }

    @Test("A trailing comma is dropped, terminated or not")
    func trailingComma() throws {
        #expect(try repaired("[1,") == .array([.int(1)]))
        #expect(try repaired("[1,]") == .array([.int(1)]))
        #expect(try repaired(#"{"a":1,"#) == .object(["a": .int(1)]))
        #expect(try repaired(#"{"a":1,}"#) == .object(["a": .int(1)]))
        #expect(try repaired("[1,,2]") == .array([.int(1), .int(2)]))
    }

    @Test("A keyword truncated to a proper prefix is completed, as upstream does")
    func partialKeywords() throws {
        #expect(try repaired("t") == .bool(true))
        #expect(try repaired("tru") == .bool(true))
        #expect(try repaired("fals") == .bool(false))
        #expect(try repaired("nul") == .null)
        #expect(try repaired(#"{"ok":tru"#) == .object(["ok": .bool(true)]))
        #expect(try repaired("[nul") == .array([.null]))
    }

    @Test("A keyword prefix followed by more input is not a keyword")
    func keywordPrefixIsNotTruncation() throws {
        // The completion rule only fires at EOF, so `[t]` cannot become `[true]`.
        #expect(try repaired("[t]") == .array([]))
        #expect(try repaired("[truthy]") == .array([]))
    }

    @Test("A number truncated mid-literal keeps the part that parses")
    func truncatedNumbers() throws {
        #expect(try repaired("1.2e") == .double(1.2))
        #expect(try repaired("1.2e+") == .double(1.2))
        #expect(try repaired("1.") == .int(1))
        #expect(try repaired("[1.2e") == .array([.double(1.2)]))
        #expect(try repaired("[1.2e-") == .array([.double(1.2)]))
        #expect(try repaired(#"{"n":-3.0e"#) == .object(["n": .double(-3.0)]))
        // `-` alone carries no value at all.
        #expect(try repaired("[-") == .array([]))
        #expect(try repaired("[-,1]") == .array([]))
    }

    @Test("A number with no terminator is still read")
    func unterminatedNumber() throws {
        // Upstream accepts this too: `[12` yields 12 even though `123` may have
        // been on its way.
        #expect(try repaired("[12") == .array([.int(12)]))
        #expect(try complete("12") == .int(12))
    }

    @Test("Truncation inside an escape sequence drops the partial escape")
    func truncatedEscape() throws {
        #expect(try repaired(#""abc\"#) == .string("abc"))
        #expect(try repaired(#""abc\u"#) == .string("abc"))
        #expect(try repaired(#""abc\u12"#) == .string("abc"))
        #expect(try repaired(#""abc\u123"#) == .string("abc"))
        #expect(try repaired(#""abc\u1234"#) == .string("abc\u{1234}"))
        #expect(try repaired(#"{"k\u00"#) == .object([:]))
    }

    @Test("An escaped quote does not terminate the string")
    func escapedQuoteIsNotATerminator() throws {
        #expect(try complete(#""a\"b""#) == .string("a\"b"))
        #expect(try repaired(#""a\"b"#) == .string("a\"b"))
        // Trailing `\\` is a complete escape; the string is still open.
        #expect(try repaired(#""a\\"#) == .string("a\\"))
        #expect(try complete(#""a\\""#) == .string("a\\"))
    }
}

// MARK: - UTF-8 and surrogates

@Suite("PartialJSON: UTF-8 and surrogates")
struct PartialJSONUnicodeTests {
    @Test("Truncation inside a multi-byte scalar drops the incomplete scalar")
    func truncatedScalar() throws {
        let full = Array(#"{"a":"héllo"#.utf8)
        // `é` is C3 A9; cut between them.
        let cut = full.firstIndex(of: 0xC3)!
        #expect(try repaired(Array(full[..<(cut + 1)])) == .object(["a": .string("h")]))
        #expect(try repaired(Array(full[..<(cut + 2)])) == .object(["a": .string("hé")]))
    }

    @Test("A four-byte scalar cut at every offset never leaks U+FFFD")
    func truncatedEmoji() throws {
        let full = Array(#"["ab😀"#.utf8)
        let emojiStart = full.count - 4
        for taken in emojiStart...full.count {
            let value = try repaired(Array(full[..<taken]))
            let expected = taken == full.count ? "ab😀" : "ab"
            #expect(value == .array([.string(expected)]), "cut at \(taken)")
        }
    }

    @Test("A lone surrogate becomes U+FFFD, and a truncated pair is dropped")
    func loneSurrogates() throws {
        // Complete input, unpairable escape: Swift has no lone-surrogate String.
        #expect(try repaired(#""\uD83D""#) == .string("\u{FFFD}"))
        #expect(try repaired(#""\uDE00""#) == .string("\u{FFFD}"))
        #expect(try repaired(#""\uD83D\u0041""#) == .string("\u{FFFD}A"))
        // Truncated: the low half may still be coming, so drop the orphan.
        #expect(try repaired(#""ab\uD83D"#) == .string("ab"))
        #expect(try repaired(#""ab\uD83D\u"#) == .string("ab"))
        #expect(try repaired(#""ab\uD83D\uDE"#) == .string("ab"))
        #expect(try repaired(#""ab\uD83D\uDE00"#) == .string("ab😀"))
    }

    @Test("Non-ASCII passes through unexamined outside and inside escapes")
    func nonASCII() throws {
        #expect(try complete(#"{"ключ":"значение"}"#) == .object(["ключ": .string("значение")]))
        #expect(try complete(#"["日本語 🎌"]"#) == .array([.string("日本語 🎌")]))
    }
}

// MARK: - Malformation

@Suite("PartialJSON: malformed input")
struct PartialJSONMalformedTests {
    @Test("Raw control characters in a string are kept and flagged")
    func rawControlCharacters() throws {
        #expect(try repaired("\"a\nb\"") == .string("a\nb"))
        #expect(try repaired("\"a\u{01}b\"") == .string("a\u{01}b"))
        #expect(try repaired("{\"a\":\"x\ty\"}") == .object(["a": .string("x\ty")]))
    }

    @Test("An invalid escape degrades to literal characters")
    func invalidEscape() throws {
        #expect(try repaired(#""C:\Users""#) == .string(#"C:\Users"#))
        #expect(try repaired(#""a\qb""#) == .string(#"a\qb"#))
        #expect(try repaired(#""a\u12zz""#) == .string(#"a\u12zz"#))
    }

    @Test("Nothing parseable at all throws")
    func unrecoverable() {
        #expect(throws: PartialJSONError.emptyInput) { try PartialJSON.parse("") }
        #expect(throws: PartialJSONError.emptyInput) { try PartialJSON.parse("  \n ") }
        #expect(throws: PartialJSONError.self) { try PartialJSON.parse("xyz") }
        #expect(throws: PartialJSONError.self) { try PartialJSON.parse("-") }
        #expect(throws: PartialJSONError.self) { try PartialJSON.parse("}") }
    }

    @Test("Garbage after a value marks the result repaired but keeps the value")
    func trailingGarbage() throws {
        #expect(try repaired(#"{"a":1} {"b":2}"#) == .object(["a": .int(1)]))
        #expect(try repaired("[1] oops") == .array([.int(1)]))
    }

    @Test("A non-string object key ends the object instead of being invented")
    func unquotedKey() throws {
        // Upstream's parser would fabricate the key `a:1}` here.
        #expect(try repaired("{a:1}") == .object([:]))
        #expect(try repaired(#"{"a":1,b:2}"#) == .object(["a": .int(1)]))
    }

    @Test("A missing value drops its key rather than inventing null")
    func missingValue() throws {
        #expect(try repaired(#"{"a":}"#) == .object([:]))
        #expect(try repaired(#"{"a":1,"b":}"#) == .object(["a": .int(1)]))
        #expect(try repaired("[,1]") == .array([.int(1)]))
    }

    @Test("Nested truncation closes every open level")
    func nestedTruncation() throws {
        #expect(try repaired(#"{"a":{"b":"#) == .object(["a": .object([:])]))
        #expect(try repaired(#"[[[["#) == .array([.array([.array([.array([])])])]))
        #expect(try repaired(#"{"a":[{"b":[{"c":"x"#)
            == .object(["a": .array([.object(["b": .array([.object(["c": .string("x")])])])])]))
    }

    @Test("A missing colon ends the object")
    func missingColon() throws {
        #expect(try repaired(#"{"a" 1}"#) == .object([:]))
        #expect(try repaired(#"{"a":1,"b" 2}"#) == .object(["a": .int(1)]))
    }

    @Test("Numbers outside the JSON grammar are salvaged or dropped")
    func nonGrammaticalNumbers() throws {
        #expect(try repaired("01") == .int(0))
        #expect(try repaired("[+1]") == .array([]))
        #expect(try repaired("[.5]") == .array([]))
        // Grammatical but unrepresentable: dropped rather than encoded as inf.
        #expect(try repaired("[1e999]") == .array([]))
    }

    @Test("NaN and Infinity are not JSON, unlike upstream's partial-json defaults")
    func noExtendedLiterals() throws {
        #expect(try repaired("[NaN]") == .array([]))
        #expect(try repaired("[Infinity]") == .array([]))
    }
}

// MARK: - Depth

@Suite("PartialJSON: depth")
struct PartialJSONDepthTests {
    @Test("Nesting past the limit throws instead of overflowing the stack")
    func depthLimit() {
        let deep = String(repeating: "[", count: 10_000)
        #expect(throws: PartialJSONError.self) { try PartialJSON.parse(deep) }
        // The never-failing path absorbs it rather than trapping.
        #expect(PartialJSON.parseStreaming(deep) == PartialJSONResult(
            value: .object([:]), completeness: .repaired))
    }

    @Test("The limit is exact and configurable")
    func exactLimit() throws {
        #expect(try PartialJSON.parse("[[[]]]", depthLimit: 3).value
            == .array([.array([.array([])])]))
        #expect(throws: PartialJSONError.depthLimitExceeded(byteOffset: 2)) {
            try PartialJSON.parse("[[[]]]", depthLimit: 2)
        }
    }

    @Test("Nesting just under the default limit still parses")
    func justUnderDefault() throws {
        let depth = PartialJSON.defaultDepthLimit
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(try PartialJSON.parse(text).completeness == .complete)
        #expect(throws: PartialJSONError.self) {
            try PartialJSON.parse("[" + text + "]")
        }
    }
}

// MARK: - repairJSON

@Suite("PartialJSON: repairJSON")
struct PartialJSONRepairTests {
    @Test("Control characters inside strings are escaped, outside they are not")
    func controlCharacters() {
        #expect(PartialJSON.repairJSON("{\"a\":\"x\ny\"}") == #"{"a":"x\ny"}"#)
        #expect(PartialJSON.repairJSON("{\"a\":\"\u{01}\"}") == #"{"a":"\u0001"}"#)
        #expect(PartialJSON.repairJSON("{\"a\":\"\t\u{08}\u{0C}\r\"}") == #"{"a":"\t\b\f\r"}"#)
        // A newline between tokens is legal whitespace and must survive.
        #expect(PartialJSON.repairJSON("{\n\"a\": 1\n}") == "{\n\"a\": 1\n}")
    }

    @Test("Invalid backslash escapes are doubled, valid ones are left alone")
    func backslashes() {
        #expect(PartialJSON.repairJSON(#"{"p":"C:\Users"}"#) == #"{"p":"C:\\Users"}"#)
        #expect(PartialJSON.repairJSON(#"{"p":"a\/b\n\t\"c\""}"#) == #"{"p":"a\/b\n\t\"c\""}"#)
        #expect(PartialJSON.repairJSON(#"{"p":"\u00e9"}"#) == #"{"p":"\u00e9"}"#)
        // A trailing backslash has nothing to escape, so it becomes a literal.
        #expect(PartialJSON.repairJSON(#"{"p":"x\"#) == #"{"p":"x\\"#)
    }

    @Test("An escaped quote does not end the in-string state")
    func escapedQuoteTracking() {
        #expect(PartialJSON.repairJSON("{\"a\":\"say \\\"hi\\\"\",\"b\":\"c\\d\"}")
            == "{\"a\":\"say \\\"hi\\\"\",\"b\":\"c\\\\d\"}")
    }

    @Test("A short or non-hex \\u sequence is left as upstream leaves it")
    func shortUnicodeEscape() {
        // `u` is a valid escape initial, so the doubling branch never sees it.
        #expect(PartialJSON.repairJSON(#"{"p":"\u12"}"#) == #"{"p":"\u12"}"#)
        #expect(PartialJSON.repairJSON(#"{"p":"\uZZZZ"}"#) == #"{"p":"\uZZZZ"}"#)
    }

    @Test("Repaired output is what a strict parser then accepts")
    func repairThenStrictParse() throws {
        let broken = "{\"content\":\"line1\nline2\tend\",\"path\":\"C:\\Users\\x\"}"
        let value = try PartialJSON.parseWithRepair(broken)
        #expect(value == .object([
            "content": .string("line1\nline2\tend"),
            "path": .string(#"C:\Users\x"#),
        ]))
    }

    @Test("parseWithRepair rethrows the original error when repair changes nothing")
    func repairRethrows() {
        #expect(throws: (any Error).self) { try PartialJSON.parseWithRepair("{") }
        #expect(throws: (any Error).self) { try PartialJSON.parseWithRepair("nope") }
    }

    @Test("Non-ASCII bytes survive the repair pass untouched")
    func repairPreservesUTF8() {
        #expect(PartialJSON.repairJSON(#"{"a":"日本語 😀"}"#) == #"{"a":"日本語 😀"}"#)
    }
}

// MARK: - parseStreaming

@Suite("PartialJSON: parseStreaming")
struct PartialJSONStreamingTests {
    @Test("Blank and absent input yield the empty-object placeholder")
    func blankInput() {
        for input: String? in [nil, "", "   ", "\n\t"] {
            let result = PartialJSON.parseStreaming(input)
            #expect(result.value == .object([:]))
            #expect(result.completeness == .repaired)
        }
    }

    @Test("Unparseable input never throws")
    func neverThrows() {
        #expect(PartialJSON.parseStreaming("!!!").value == .object([:]))
        #expect(PartialJSON.parseStreaming("-").value == .object([:]))
    }

    @Test("Completeness is reported through the never-failing path too")
    func completenessSurvives() {
        #expect(PartialJSON.parseStreaming(#"{"a":1}"#).isComplete)
        #expect(!PartialJSON.parseStreaming(#"{"a":1"#).isComplete)
    }

    @Test("Every prefix of a real tool call parses, and only the last is complete")
    func growingPrefixes() {
        let arguments = #"""
        {"path":"src/main.swift","edits":[{"old":"foo \"bar\"","new":"日本 😀"},\#
        {"old":"x","new":"y"}],"dryRun":false,"count":42,"ratio":-1.5e-3,"note":null}
        """#
        let bytes = Array(arguments.utf8)
        for taken in 1...bytes.count {
            let result = PartialJSON.parseStreaming(String(decoding: bytes[..<taken], as: UTF8.self))
            let shouldBeComplete = taken == bytes.count
            #expect(result.isComplete == shouldBeComplete, "prefix length \(taken)")
            if !shouldBeComplete {
                // A partial preview is always an object here, never a stray scalar.
                #expect(result.value.objectValue != nil, "prefix length \(taken)")
            }
        }
    }

    @Test("Byte-level prefixes, which can cut inside a scalar, behave the same")
    func growingBytePrefixes() throws {
        let arguments = #"{"note":"héllo 😀 日本","ok":true}"#
        let bytes = Array(arguments.utf8)
        for taken in 1..<bytes.count {
            let result = try PartialJSON.parse(Data(bytes[..<taken]))
            #expect(result.completeness == .repaired, "prefix length \(taken)")
            let note = result.value["note"]?.stringValue
            #expect(note == nil || "héllo 😀 日本".hasPrefix(note!), "prefix length \(taken)")
        }
        #expect(try PartialJSON.parse(Data(bytes)).completeness == .complete)
    }
}

// MARK: - Adversarial

@Suite("PartialJSON: adversarial")
struct PartialJSONAdversarialTests {
    /// Deterministic so a failure is reproducible; the point is coverage of byte
    /// sequences no hand-written case would think to try.
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @Test("Random byte soup never crashes and never hangs")
    func randomBytes() {
        var rng = Random(state: 0x1234_5678_9ABC_DEF0)
        let alphabet = Array(#"{}[]",:\/ tnr0123456789.eE-+u"#.utf8) + [0x00, 0x01, 0xC3, 0xE2, 0xF0]
        for _ in 0..<4000 {
            let length = Int.random(in: 0...60, using: &rng)
            var bytes: [UInt8] = []
            for _ in 0..<length { bytes.append(alphabet.randomElement(using: &rng)!) }
            _ = PartialJSON.parseStreaming(String(decoding: bytes, as: UTF8.self))
            _ = try? PartialJSON.parse(Data(bytes))
            _ = PartialJSON.repairJSON(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test("A repaired document re-parses to the same value")
    func repairIsStable() throws {
        let inputs = [
            "{\"a\":\"x\ny\"}", #"{"p":"C:\Users"}"#, #"{"a":1,}"#, "[1,2]",
        ]
        for input in inputs {
            let once = try PartialJSON.parse(input).value
            let twice = try PartialJSON.parse(PartialJSON.repairJSON(input)).value
            #expect(once == twice, "\(input)")
        }
    }

    @Test("A closed partial value re-encodes to JSON a strict parser accepts")
    func outputIsAlwaysValidJSON() throws {
        let prefixes = [
            #"{"a":"x"#, #"[1.2e"#, #"{"a":[{"b":"tru"#, #""ab\uD83D"#, "[tru",
            "{\"a\":\"x\u{01}y\"", #"{"a":"\u12"#,
        ]
        for prefix in prefixes {
            let value = try PartialJSON.parse(prefix).value
            let encoded = try value.encodedString()
            #expect(try JSONValue(parsing: encoded) == value, "\(prefix)")
        }
    }

    @Test("A million-character string literal is linear, not quadratic")
    func longString() throws {
        let text = "\"" + String(repeating: "a", count: 1_000_000)
        let result = try PartialJSON.parse(text)
        #expect(result.value.stringValue?.count == 1_000_000)
        #expect(result.completeness == .repaired)
    }

    @Test("A very long invalid number token terminates")
    func longInvalidNumber() throws {
        // Note this one is cheap however the number path is written: the token
        // fails the grammar on its second byte, so nothing rescans. See
        // `longMalformedNumberIsLinear` for the shape that does.
        let text = "[" + String(repeating: "-", count: 5000)
        #expect(try PartialJSON.parse(text).value == .array([]))
    }

    @Test("A long malformed number token is linear, not quadratic")
    func longMalformedNumberIsLinear() throws {
        // `.`, `e`, `E`, `+` and `-` are all number bytes wherever they appear,
        // so this is one number token whose longest valid prefix is the leading
        // `0.999…`. Rejecting it by trimming a byte at a time and revalidating
        // rescans the entire digit run on every trim; that took four seconds
        // here in release, and the streaming path re-parses on every chunk.
        let digits = String(repeating: "9", count: 10_000)
        let text = #"{"a":0."# + digits + String(repeating: ".", count: 1_000_000) + "}"

        var result: PartialJSONResult?
        let elapsed = try ContinuousClock().measure {
            result = try PartialJSON.parse(text)
        }

        #expect(elapsed < .seconds(2))
        #expect(result?.value == .object(["a": .double(Double("0." + digits)!)]))
        #expect(result?.completeness == .repaired)
    }
}

@Suite("PartialJSON: depth limit is the parser's own bound")
struct PartialJSONDepthCeilingTests {

    /// The point of `depthLimit` is that deep input throws instead of
    /// overflowing the stack. A caller-supplied limit large enough to overflow
    /// would invert that guarantee, and a stack overflow is an uncatchable
    /// `SIGBUS` rather than something the agent loop can report — so the bound
    /// belongs to the parser, not the call site.
    @Test("An oversized caller limit is clamped rather than honored")
    func callerCannotRaiseTheCeiling() {
        let deep = String(repeating: "[", count: 100_000)

        #expect(throws: PartialJSONError.self) {
            _ = try PartialJSON.parse(deep, depthLimit: Int.max)
        }
        #expect(throws: PartialJSONError.self) {
            _ = try PartialJSON.parse(deep, depthLimit: 1_000_000)
        }
        #expect(throws: PartialJSONError.self) {
            _ = try PartialJSON.parse(Data(deep.utf8), depthLimit: Int.max)
        }
    }

    /// Nesting just inside the ceiling must still parse, so the clamp bounds
    /// the stack without quietly rejecting legitimate documents.
    ///
    /// This runs on a `Task`, which gets the ~512 KiB executor stack rather
    /// than the main thread's megabytes. That is the tighter of the two budgets
    /// the parser actually runs under, so it is the one worth asserting
    /// against — a ceiling that only survives on the main thread would still
    /// `SIGBUS` inside the agent loop.
    @Test("Nesting within the ceiling still parses on an executor thread")
    func withinCeilingStillParses() async throws {
        let depth = PartialJSON.maximumDepthLimit - 1
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)

        let completeness = try await Task {
            try PartialJSON.parse(nested, depthLimit: Int.max).completeness
        }.value

        #expect(completeness == .complete)
    }

    /// A non-positive limit is nonsense rather than a request for zero depth;
    /// it must not underflow into rejecting everything or trapping.
    @Test("A non-positive limit is clamped up, not honored")
    func nonPositiveLimitClamps() throws {
        #expect(throws: PartialJSONError.self) {
            _ = try PartialJSON.parse("[[1]]", depthLimit: -5)
        }
        let flat = try PartialJSON.parse("1", depthLimit: 0)
        #expect(flat.value == .int(1))
    }
}
