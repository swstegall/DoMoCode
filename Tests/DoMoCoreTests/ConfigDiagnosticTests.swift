// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

import DoMoCore

// DoMoCore's position type is `ConfigSourceLocation` and not `SourceLocation`
// precisely because swift-testing exports a `SourceLocation` of its own: a
// DoMoCore type by that name is ambiguous in every file that imports both, which
// broke `PartialJSONTests` the moment it was introduced.
private typealias Location = ConfigSourceLocation

/// Byte offset of `needle`'s first occurrence, computed independently of
/// anything under test so an assertion about a location cannot be satisfied by
/// the implementation agreeing with itself.
private func byteOffset(of needle: String, in text: String) throws -> Int {
    let range = try #require(text.range(of: needle), "\(needle) is not in \(text)")
    return String(text[text.startIndex..<range.lowerBound]).utf8.count
}

private func scanFailure(_ text: String) throws -> ConfigDiagnostic {
    try #require(throws: ConfigDiagnostic.self) {
        _ = try JSONSourceIndex.index(Array(text.utf8))
    }
}

// MARK: - ConfigSourceLocation.locate

@Suite("ConfigSourceLocation.locate")
struct ConfigSourceLocationTests {
    @Test("Offset zero is line 1, column 1, even in an empty document")
    func origin() {
        #expect(Location.locate(byteOffset: 0, in: []) == Location(byteOffset: 0, line: 1, column: 1))
        #expect(
            Location.locate(byteOffset: 0, in: Array("abc".utf8))
                == Location(byteOffset: 0, line: 1, column: 1)
        )
    }

    @Test("The last byte of a document is located, not clamped away")
    func lastByte() {
        let bytes = Array("ab\ncd".utf8)
        let location = Location.locate(byteOffset: 4, in: bytes)
        #expect(location == Location(byteOffset: 4, line: 2, column: 2))
    }

    @Test("An offset past the end reports end-of-file rather than trapping")
    func pastEnd() {
        let bytes = Array("ab\ncd".utf8)
        #expect(Location.locate(byteOffset: 5, in: bytes) == Location(byteOffset: 5, line: 2, column: 3))
        #expect(Location.locate(byteOffset: 9_999, in: bytes) == Location(byteOffset: 5, line: 2, column: 3))
        #expect(Location.locate(byteOffset: -3, in: bytes) == Location(byteOffset: 0, line: 1, column: 1))
    }

    @Test("A trailing newline puts end-of-file on a fresh line")
    func endsWithNewline() {
        let bytes = Array("ab\n".utf8)
        #expect(Location.locate(byteOffset: 3, in: bytes) == Location(byteOffset: 3, line: 2, column: 1))
    }

    @Test("The CR of a CRLF pair is part of the terminator and costs no column")
    func carriageReturn() {
        let bytes = Array("ab\r\ncd".utf8)
        // The LF sits directly after `b`, so it is at column 3. Counting the CR
        // as a character would make it 4 and slide every caret on a Windows
        // file one place right.
        #expect(Location.locate(byteOffset: 3, in: bytes) == Location(byteOffset: 3, line: 1, column: 3))
        #expect(Location.locate(byteOffset: 4, in: bytes) == Location(byteOffset: 4, line: 2, column: 1))
        #expect(Location.locate(byteOffset: 5, in: bytes) == Location(byteOffset: 5, line: 2, column: 2))
    }

    @Test("Columns count Unicode scalars, not bytes")
    func multibyteScalars() {
        // "héllo": h is 1 byte, é is 2, so the first `l` is byte 3 / column 3.
        let accented = Array("héllo".utf8)
        #expect(accented.count == 6)
        #expect(Location.locate(byteOffset: 3, in: accented) == Location(byteOffset: 3, line: 1, column: 3))

        // A four-byte scalar is still one column.
        let emoji = Array("🙂x".utf8)
        #expect(emoji.count == 5)
        #expect(Location.locate(byteOffset: 4, in: emoji) == Location(byteOffset: 4, line: 1, column: 2))
    }

    @Test("Multi-byte scalars on an earlier line do not leak into the next line's column")
    func multibyteAcrossLines() {
        let bytes = Array("é\nb".utf8)
        #expect(Location.locate(byteOffset: 3, in: bytes) == Location(byteOffset: 3, line: 2, column: 1))
    }

    @Test("A tab is one column here; expansion happens only in the excerpt")
    func tabs() {
        let bytes = Array("\t\tx".utf8)
        #expect(Location.locate(byteOffset: 2, in: bytes) == Location(byteOffset: 2, line: 1, column: 3))
    }
}

// MARK: - JSONSourceIndex, well-formed input

@Suite("JSONSourceIndex: byte ranges")
struct JSONSourceIndexTests {
    @Test("Every value, including the root, gets a byte range keyed by its path")
    func ranges() throws {
        //          0123456789...
        let text = #"{"a": {"b": [1, 2]}}"#
        let index = try JSONSourceIndex.index(Array(text.utf8))

        #expect(Set(index.keys) == [[], ["a"], ["a", "b"], ["a", "b", "0"], ["a", "b", "1"]])

        let root = try #require(index[[]])
        #expect(root.valueRange == 0..<20)
        #expect(root.keyRange == nil)

        let outer = try #require(index[["a"]])
        #expect(outer.keyRange == 1..<4)  // includes both quotes
        #expect(outer.valueRange == 6..<19)

        let inner = try #require(index[["a", "b"]])
        #expect(inner.keyRange == 7..<10)
        #expect(inner.valueRange == 12..<18)

        let first = try #require(index[["a", "b", "0"]])
        #expect(first.keyRange == nil)
        #expect(first.valueRange == 13..<14)

        let second = try #require(index[["a", "b", "1"]])
        #expect(second.valueRange == 16..<17)
    }

    @Test("Empty containers are indexed and contribute no element paths")
    func emptyContainers() throws {
        let text = #"{"a": {}, "b": []}"#
        let index = try JSONSourceIndex.index(Array(text.utf8))
        #expect(Set(index.keys) == [[], ["a"], ["b"]])
        #expect(index[["a"]]?.valueRange == 6..<8)
        #expect(index[["b"]]?.valueRange == 15..<17)
    }

    @Test("A repeated key keeps its last occurrence")
    func duplicateKeys() throws {
        let text = #"{"a": 1, "a": 22}"#
        let index = try JSONSourceIndex.index(Array(text.utf8))
        #expect(index[["a"]]?.valueRange == 14..<16)
    }

    @Test("Escapes in a key are decoded, so the path matches the decoder's key")
    func escapedKeys() throws {
        let index = try JSONSourceIndex.index(Array(#"{"ab": 1, "c\td": 2}"#.utf8))
        #expect(Set(index.keys) == [[], ["ab"], ["c\td"]])
    }

    @Test("A surrogate pair in a key becomes one scalar")
    func surrogatePairKey() throws {
        let index = try JSONSourceIndex.index(Array(#"{"🙂": 1}"#.utf8))
        #expect(Set(index.keys) == [[], ["🙂"]])
    }

    @Test("A leading byte-order mark is skipped, as Foundation skips it")
    func byteOrderMark() throws {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array(#"{"a": 1}"#.utf8)
        let index = try JSONSourceIndex.index(bytes)
        #expect(index[["a"]]?.valueRange == 9..<10)
        #expect(index[["a"]]?.keyRange == 4..<7)
    }

    @Test("Scalars, negatives and exponents are accepted at the top level")
    func scalarDocuments() throws {
        for text in ["null", "true", "false", "-1.5e+10", #""x""#, "0"] {
            let index = try JSONSourceIndex.index(Array(text.utf8))
            #expect(index[[]]?.valueRange == 0..<text.utf8.count, "\(text)")
        }
    }
}

// MARK: - JSONSourceIndex, failures

@Suite("JSONSourceIndex: failures")
struct JSONSourceIndexFailureTests {
    @Test("A trailing comma points at the comma, which is the byte to delete")
    func trailingCommaInObject() throws {
        let diagnostic = try scanFailure(#"{"a": 1,}"#)
        #expect(diagnostic.location?.byteOffset == 7)
        #expect(diagnostic.location?.column == 8)
        #expect(diagnostic.problem == "trailing comma before '}'")
        #expect(diagnostic.caretColumn == 8)
    }

    @Test("A trailing comma in an array points at the comma too")
    func trailingCommaInArray() throws {
        let diagnostic = try scanFailure(#"{"a": [1,]}"#)
        #expect(diagnostic.location?.byteOffset == 8)
        #expect(diagnostic.problem == "trailing comma before ']'")
        // The path is still inside the array when the comma is rejected.
        #expect(diagnostic.keyPath == ["a"])
    }

    @Test("An unterminated string points at its opening quote, not at EOF")
    func unterminatedString() throws {
        let text = #"{"a": "oops}"#
        let diagnostic = try scanFailure(text)
        #expect(diagnostic.location?.byteOffset == 6)
        #expect(diagnostic.location?.byteOffset != text.utf8.count)
        #expect(diagnostic.problem == "unterminated string")
    }

    @Test("A bare identifier is quoted back whole")
    func bareIdentifier() throws {
        let diagnostic = try scanFailure(#"{"a": foo}"#)
        #expect(diagnostic.location?.byteOffset == 6)
        #expect(diagnostic.problem == "expected a value, found 'foo'")
        #expect(diagnostic.keyPath == ["a"])
    }

    @Test("A keyword truncated to a prefix is not completed")
    func truncatedKeyword() throws {
        let diagnostic = try scanFailure(#"{"a": tru}"#)
        #expect(diagnostic.problem == "expected a value, found 'tru'")
    }

    @Test("A truncated document points one past its last byte")
    func truncatedDocument() throws {
        let text = #"{"a": 1"#
        let diagnostic = try scanFailure(text)
        #expect(diagnostic.location?.byteOffset == text.utf8.count)
        #expect(diagnostic.problem == "expected ',' or '}' but the document ended")
    }

    @Test("A document cut inside a nested container reports the innermost path")
    func truncatedNested() throws {
        let diagnostic = try scanFailure(#"{"a": {"b": "#)
        #expect(diagnostic.keyPath == ["a", "b"])
        #expect(diagnostic.problem == "expected a value but the document ended")
    }

    @Test("Numbers follow RFC 8259, not Double.init")
    func numberGrammar() throws {
        #expect(try scanFailure(#"{"a": 01}"#).problem == "numbers may not have a leading zero")
        #expect(try scanFailure(#"{"a": 1.}"#).problem == "expected a digit after '.'")
        #expect(try scanFailure(#"{"a": 1e}"#).problem == "expected a digit in the exponent")
        #expect(try scanFailure(#"{"a": +1}"#).problem == "expected a value, found '+1'")
        #expect(try scanFailure(#"{"a": -}"#).problem == "expected a digit after '-'")
        // `.5` and `0x10` both parse as Double and neither is JSON. The hex
        // literal is rejected one byte later, where `0` stops being a number.
        #expect(try scanFailure(#"{"a": .5}"#).problem == "expected a value, found '.5'")
        let hex = try scanFailure(#"{"a": 0x10}"#)
        #expect(hex.location?.byteOffset == 7)
        #expect(hex.problem == "expected ',' or '}', found 'x10'")
    }

    @Test("An unescaped control character in a string is rejected where it sits")
    func controlCharacter() throws {
        let diagnostic = try scanFailure("{\"a\": \"x\ty\"}")
        #expect(diagnostic.location?.byteOffset == 8)
        #expect(diagnostic.problem == "unescaped control character 0x09 in a string")
    }

    @Test("A malformed unicode escape names the escape, not the string")
    func malformedEscape() throws {
        let diagnostic = try scanFailure(#"{"a": "\u12g4"}"#)
        #expect(diagnostic.location?.byteOffset == 7)
        #expect(diagnostic.problem == "'\\u' must be followed by four hexadecimal digits")
        #expect(try scanFailure(#"{"a": "\q"}"#).problem == "invalid escape '\\q' in a string")
    }

    @Test("Structural mistakes name what was expected")
    func structure() throws {
        #expect(try scanFailure("").problem == "the document is empty")
        #expect(try scanFailure("   \n  ").problem == "the document is empty")
        #expect(try scanFailure(#"{a: 1}"#).problem == "expected a quoted key, found 'a'")
        #expect(try scanFailure(#"{"a" 1}"#).problem == "expected ':' after the key")
        #expect(try scanFailure(#"{"a": 1 "b": 2}"#).problem == "expected ',' or '}', found '\"'")
        let trailing = try scanFailure(#"{"a": 1} junk"#)
        #expect(trailing.problem == "unexpected 'junk' after the end of the document")
        #expect(trailing.location?.byteOffset == 9)
    }

    @Test("Nesting beyond the depth limit is reported instead of overflowing the stack")
    func depthLimit() throws {
        let limit = JSONSourceIndex.depthLimit
        #expect(limit == 32)

        let deep = String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)
        let diagnostic = try scanFailure(deep)
        #expect(diagnostic.problem == "nested more than 32 levels deep")

        // Exactly the limit still scans, so the guard is not off by one — and
        // the root plus one entry per level accounts for every path.
        let atLimit = String(repeating: "[", count: limit) + String(repeating: "]", count: limit)
        #expect(try JSONSourceIndex.index(Array(atLimit.utf8)).count == limit)
    }
}

// MARK: - Bridging DecodingError

private struct Sample: Codable {
    var name: String
    var contextWindow: Int
}

/// A `Decodable` that rejects its own input, which is the only way to reach
/// `dataCorrupted` on a document that parses cleanly.
private struct Positive: Codable {
    var contextWindow: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextWindow = try container.decode(Int.self, forKey: .contextWindow)
        guard contextWindow > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .contextWindow,
                in: container,
                debugDescription: "contextWindow must be positive"
            )
        }
    }
}

private struct PlainError: Error {
    var text: String
}

private func diagnose<T: Decodable>(_ type: T.Type, _ json: String, file: String? = "settings.json")
    throws -> ConfigDiagnostic
{
    let source = Array(json.utf8)
    do {
        _ = try JSONDecoder().decode(type, from: Data(source))
        throw PlainError(text: "\(json) decoded when it should not have")
    } catch let error as PlainError {
        throw error
    } catch {
        return ConfigDiagnostic(decoding: error, source: source, file: file)
    }
}

@Suite("ConfigDiagnostic: bridging a decoding failure")
struct ConfigDiagnosticBridgeTests {
    @Test("typeMismatch is located at the offending value")
    func typeMismatch() throws {
        let json = "{\n  \"name\": \"x\",\n  \"contextWindow\": \"big\"\n}"
        let diagnostic = try diagnose(Sample.self, json)
        #expect(diagnostic.file == "settings.json")
        #expect(diagnostic.keyPath == ["contextWindow"])
        #expect(diagnostic.problem == "expected a value of type Int")
        #expect(diagnostic.location?.byteOffset == (try byteOffset(of: "\"big\"", in: json)))
        #expect(diagnostic.location?.line == 3)
        #expect(diagnostic.location?.column == 20)
        #expect(diagnostic.excerpt == "  \"contextWindow\": \"big\"")
        #expect(diagnostic.caretColumn == 20)
    }

    @Test("keyNotFound is located at the container that lacks the key")
    func keyNotFound() throws {
        let json = "{\n  \"name\": \"x\"\n}"
        let diagnostic = try diagnose(Sample.self, json)
        #expect(diagnostic.keyPath == ["contextWindow"])
        #expect(diagnostic.problem == "missing required key \"contextWindow\"")
        #expect(diagnostic.location == Location(byteOffset: 0, line: 1, column: 1))
        #expect(diagnostic.excerpt == "{")
    }

    @Test("keyNotFound inside a nested object points at that object's brace")
    func nestedKeyNotFound() throws {
        struct Outer: Decodable {
            var inner: Sample
        }
        let json = #"{"inner": {"name": "x"}}"#
        let diagnostic = try diagnose(Outer.self, json)
        #expect(diagnostic.keyPath == ["inner", "contextWindow"])
        #expect(diagnostic.location?.byteOffset == (try byteOffset(of: "{\"name\"", in: json)))
    }

    @Test("valueNotFound names the type and the null")
    func valueNotFound() throws {
        let json = #"{"name": null, "contextWindow": 1}"#
        let diagnostic = try diagnose(Sample.self, json)
        #expect(diagnostic.keyPath == ["name"])
        #expect(diagnostic.problem == "expected a value of type String, found null")
        #expect(diagnostic.location?.byteOffset == (try byteOffset(of: "null", in: json)))
    }

    @Test("A Decodable's own dataCorrupted keeps its message and gains a location")
    func semanticDataCorrupted() throws {
        let json = "{\n  \"contextWindow\": -5\n}"
        let diagnostic = try diagnose(Positive.self, json)
        #expect(diagnostic.keyPath == ["contextWindow"])
        #expect(diagnostic.problem == "contextWindow must be positive")
        #expect(diagnostic.location?.byteOffset == (try byteOffset(of: "-5", in: json)))
        #expect(diagnostic.location?.line == 2)
        #expect(diagnostic.caretColumn == 20)
    }

    @Test("A syntax error is reported from our scanner, not from Foundation's prose")
    func syntaxErrorPrefersTheScanner() throws {
        let json = #"{"name": tru}"#
        let diagnostic = try diagnose(Sample.self, json)
        #expect(diagnostic.problem == "expected a value, found 'tru'")
        #expect(diagnostic.location?.byteOffset == 9)
        #expect(diagnostic.file == "settings.json")
    }

    @Test("An unterminated string still gets a location, which Foundation cannot supply")
    func unterminatedStringHasALocation() throws {
        let json = "{\"name\": \"x}"
        let diagnostic = try diagnose(Sample.self, json)
        #expect(diagnostic.problem == "unterminated string")
        #expect(diagnostic.location?.byteOffset == 9)
    }

    @Test("A trailing comma Foundation accepts is still reported")
    func trailingCommaIsCaughtEvenWhenTheDecodeSucceeds() throws {
        // Foundation parses this happily, so there is no DecodingError at all;
        // the diagnostic has to come from the scanner.
        let json = #"{"name": "x", "contextWindow": 1,}"#
        let source = Array(json.utf8)
        #expect(throws: ConfigDiagnostic.self) { _ = try JSONSourceIndex.index(source) }
        let decoded = try? JSONDecoder().decode(Sample.self, from: Data(source))
        #expect(decoded?.contextWindow == 1)
    }

    @Test("A non-decoding error is carried through without inventing a location")
    func foreignError() {
        let source = Array(#"{"name": "x", "contextWindow": 1}"#.utf8)
        let diagnostic = ConfigDiagnostic(
            decoding: PlainError(text: "disk on fire"),
            source: source,
            file: "settings.json"
        )
        #expect(diagnostic.location == nil)
        #expect(diagnostic.excerpt == nil)
        #expect(diagnostic.keyPath == [])
        #expect(diagnostic.problem.contains("disk on fire"))
        #expect(diagnostic.file == "settings.json")
    }

    @Test("Re-bridging a diagnostic only fills in the file")
    func idempotent() {
        let original = ConfigDiagnostic(
            file: nil,
            location: Location(byteOffset: 3, line: 1, column: 4),
            keyPath: ["model"],
            problem: "unreadable",
            excerpt: "abcd",
            caretColumn: 4
        )
        let bridged = ConfigDiagnostic(decoding: original, source: [], file: "settings.json")
        #expect(bridged.file == "settings.json")
        #expect(bridged.location == original.location)
        #expect(bridged.keyPath == ["model"])
        #expect(bridged.problem == "unreadable")
        #expect(bridged.excerpt == "abcd")

        let named = ConfigDiagnostic(
            file: "user.json",
            location: nil,
            keyPath: [],
            problem: "p",
            excerpt: nil,
            caretColumn: nil
        )
        #expect(ConfigDiagnostic(decoding: named, source: [], file: "project.json").file == "user.json")
    }
}

// MARK: - Rendering

@Suite("ConfigDiagnostic: rendering")
struct ConfigDiagnosticRenderingTests {
    @Test("An ASCII key renders header, excerpt and caret")
    func asciiCaret() throws {
        let json = "{\n  \"model\": 1\n}"
        let diagnostic = ConfigDiagnostic(
            file: "/tmp/settings.json",
            source: Array(json.utf8),
            byteOffset: try byteOffset(of: "1", in: json),
            keyPath: ["model"],
            problem: "expected a value of type String"
        )
        #expect(
            diagnostic.description == """
                /tmp/settings.json:2:12: model — expected a value of type String
                  "model": 1
                           ^
                """
        )
    }

    @Test("A key preceded by an emoji keeps the caret under the value")
    func emojiCaret() throws {
        let json = #"{"🙂key": 1}"#
        let diagnostic = ConfigDiagnostic(
            file: "settings.json",
            source: Array(json.utf8),
            byteOffset: try byteOffset(of: "1", in: json),
            keyPath: ["🙂key"],
            problem: "expected a string"
        )
        // Byte 12 but column 10: the emoji is four bytes and one scalar. A byte
        // column would print the caret three places past the value.
        #expect(diagnostic.location == Location(byteOffset: 12, line: 1, column: 10))
        #expect(diagnostic.caretColumn == 10)

        let lines = diagnostic.description.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines[0] == "settings.json:1:10: 🙂key — expected a string")
        #expect(lines[1] == #"{"🙂key": 1}"#)
        #expect(lines[2] == String(repeating: " ", count: 9) + "^")
    }

    @Test("Tabs are expanded and the caret is moved with them")
    func tabExpansion() throws {
        let json = "{\n\t\"model\": 1\n}"
        let diagnostic = ConfigDiagnostic(
            file: nil,
            source: Array(json.utf8),
            byteOffset: try byteOffset(of: "1", in: json),
            keyPath: [],
            problem: "expected a string"
        )
        #expect(diagnostic.location?.column == 11)
        #expect(diagnostic.excerpt == "    \"model\": 1")
        #expect(diagnostic.caretColumn == 14)
        #expect(
            diagnostic.description == """
                2:11: expected a string
                    "model": 1
                             ^
                """
        )
    }

    @Test("The CR of a CRLF line ending is not part of the excerpt")
    func crlfExcerpt() throws {
        let json = "{\r\n  \"model\": 1\r\n}"
        let diagnostic = ConfigDiagnostic(
            file: nil,
            source: Array(json.utf8),
            byteOffset: try byteOffset(of: "1", in: json),
            keyPath: ["model"],
            problem: "expected a string"
        )
        #expect(diagnostic.excerpt == "  \"model\": 1")
        #expect(diagnostic.caretColumn == 12)
    }

    @Test("A very long line is windowed around the caret")
    func longLineWindowing() {
        let json = String(repeating: "a", count: 500)
        let diagnostic = ConfigDiagnostic(
            file: nil,
            source: Array(json.utf8),
            byteOffset: 300,
            keyPath: [],
            problem: "nonsense"
        )
        let excerpt = diagnostic.excerpt
        #expect(excerpt?.unicodeScalars.count == 162)
        #expect(excerpt?.hasPrefix("…") == true)
        #expect(excerpt?.hasSuffix("…") == true)
        #expect(diagnostic.caretColumn == 82)
    }

    @Test("A short line is not windowed")
    func shortLineIsVerbatim() {
        let json = String(repeating: "a", count: 199)
        let diagnostic = ConfigDiagnostic(
            file: nil,
            source: Array(json.utf8),
            byteOffset: 198,
            keyPath: [],
            problem: "nonsense"
        )
        #expect(diagnostic.excerpt == json)
        #expect(diagnostic.caretColumn == 199)
    }

    @Test("An empty line yields no excerpt rather than a bare caret")
    func noExcerpt() {
        let diagnostic = ConfigDiagnostic(
            file: "settings.json",
            source: Array("{\n\n}".utf8),
            byteOffset: 2,
            keyPath: [],
            problem: "nothing here"
        )
        #expect(diagnostic.excerpt == nil)
        #expect(diagnostic.caretColumn == nil)
        #expect(diagnostic.description == "settings.json:2:1: nothing here")
    }

    @Test("The headline degrades gracefully as parts go missing")
    func headlineForms() {
        #expect(
            ConfigDiagnostic(
                file: "a.json", location: nil, keyPath: ["x", "0", "y"], problem: "bad",
                excerpt: nil, caretColumn: nil
            ).headline == "a.json: x.0.y — bad"
        )
        #expect(
            ConfigDiagnostic(
                file: nil, location: nil, keyPath: [], problem: "bad",
                excerpt: nil, caretColumn: nil
            ).headline == "bad"
        )
        #expect(
            ConfigDiagnostic(
                file: nil, location: Location(byteOffset: 0, line: 7, column: 2), keyPath: [],
                problem: "bad", excerpt: nil, caretColumn: nil
            ).headline == "7:2: bad"
        )
    }

    @Test("description is multi-line, and headline is the single-line form")
    func multiline() throws {
        let json = "{\n  \"model\": 1\n}"
        let diagnostic = ConfigDiagnostic(
            file: "s.json",
            source: Array(json.utf8),
            byteOffset: try byteOffset(of: "1", in: json),
            keyPath: ["model"],
            problem: "expected a string"
        )
        #expect(diagnostic.description.contains("\n"))
        #expect(!diagnostic.headline.contains("\n"))
        #expect(diagnostic.description.hasPrefix(diagnostic.headline))
    }

    @Test("localizedDescription is the diagnostic, not Foundation's placeholder")
    func localized() {
        let diagnostic = ConfigDiagnostic(
            file: "s.json", location: nil, keyPath: ["model"], problem: "expected a string",
            excerpt: nil, caretColumn: nil
        )
        let error: any Error = diagnostic
        #expect(error.localizedDescription == "s.json: model — expected a string")
    }
}
