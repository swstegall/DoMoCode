// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import SystemPackage
import Testing

import DoMoCore

// MARK: - Fixtures

/// Shaped like a pi session entry: a `type` tag, tree links, and a payload that
/// can be arbitrarily large.
private struct Entry: Codable, Equatable, Sendable {
    var type: String
    var id: String
    var parentId: String?
    var text: String

    init(type: String = "message", id: String, parentId: String? = nil, text: String = "") {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.text = text
    }
}

private func makeTemporaryDirectory() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jsonl-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

private func write(_ text: String, to path: FilePath) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path.string))
}

private func read(_ path: FilePath) throws -> String {
    String(decoding: try Data(contentsOf: URL(fileURLWithPath: path.string)), as: UTF8.self)
}

/// `onSkippedLine` is `@Sendable`, so the sink needs real synchronization rather
/// than a captured array.
private final class SkippedLineSink: Sendable {
    private let storage = Mutex<[JSONLinesError]>([])

    var errors: [JSONLinesError] { storage.withLock { $0 } }

    var options: JSONLinesReadOptions {
        JSONLinesReadOptions(strictness: .tolerant) { error in
            self.append(error)
        }
    }

    private func append(_ error: JSONLinesError) {
        storage.withLock { $0.append(error) }
    }
}

// MARK: - Encoding

@Suite("JSONL encoding")
struct JSONLinesEncodingTests {
    @Test("A line is newline-terminated and contains no interior newline")
    func lineShape() throws {
        let data = try JSONLines.encodeLine(Entry(id: "a", text: "one\ntwo\r\nthree"))
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        #expect(data.dropLast().contains(0x0D) == false)
    }

    @Test("Keys are sorted so appended lines are byte-stable")
    func sortedKeys() throws {
        let line = String(decoding: try JSONLines.encodeLine(Entry(id: "a")), as: UTF8.self)
        #expect(line == #"{"id":"a","text":"","type":"message"}"# + "\n")
    }

    @Test("Encoding a sequence terminates every line, including the last")
    func sequenceTerminated() throws {
        let data = try JSONLines.encode([Entry(id: "a"), Entry(id: "b")])
        #expect(data.last == 0x0A)
        #expect(data.filter { $0 == 0x0A }.count == 2)
    }

    @Test("Round trip preserves control characters inside strings")
    func roundTripControlCharacters() throws {
        let entries = [Entry(id: "a", text: "line\nbreak\ttab\r\n"), Entry(id: "b", text: "\u{1F600}")]
        let decoded = try JSONLines.decode(Entry.self, from: JSONLines.encode(entries))
        #expect(decoded == entries)
    }
}

// MARK: - Newlines and blank lines

@Suite("JSONL line framing")
struct JSONLinesFramingTests {
    @Test("Empty input yields no entries")
    func emptyInput() throws {
        #expect(try JSONLines.decode(Entry.self, from: Data()).isEmpty)
    }

    @Test("A trailing newline does not produce a phantom final entry")
    func noTrailingAmbiguity() throws {
        let withNewline = Data(#"{"type":"message","id":"a","text":""}"# .utf8) + Data("\n".utf8)
        #expect(try JSONLines.decode(Entry.self, from: withNewline).count == 1)
    }

    @Test("A missing final newline still yields the final entry")
    func missingTrailingNewline() throws {
        let text = """
            {"type":"message","id":"a","text":""}
            {"type":"message","id":"b","text":""}
            """
        let decoded = try JSONLines.decode(Entry.self, from: Data(text.utf8), options: .strict)
        #expect(decoded.map(\.id) == ["a", "b"])
    }

    @Test("CRLF line endings are accepted, split across reads or not", arguments: [1, 3, 64 * 1024])
    func crlf(chunkSize: Int) throws {
        let text = #"{"type":"message","id":"a","text":""}"# + "\r\n"
            + #"{"type":"message","id":"b","text":""}"# + "\r\n"
        let options = JSONLinesReadOptions(strictness: .strict, chunkSize: chunkSize)
        #expect(try JSONLines.decode(Entry.self, from: Data(text.utf8), options: options).map(\.id) == ["a", "b"])
    }

    @Test("Blank and whitespace-only lines are ignored, not errors")
    func blankLines() throws {
        let text = "\n  \n\r\n" + #"{"type":"message","id":"a","text":""}"# + "\n\n\t\n"
        let decoded = try JSONLines.decode(Entry.self, from: Data(text.utf8), options: .strict)
        #expect(decoded.map(\.id) == ["a"])
    }

    @Test("A multi-byte scalar split across every possible read boundary survives")
    func multiByteAcrossBoundary() throws {
        // Four-, three- and two-byte scalars plus a combining pair, so a
        // one-byte chunk size lands inside each of them.
        let entries = [
            Entry(id: "a", text: "🙂 ünïcøde 漢字 e\u{0301}"),
            Entry(id: "b", text: "🇩🇪👩‍👩‍👧‍👦"),
        ]
        let data = try JSONLines.encode(entries)
        for chunkSize in [1, 2, 3, 5, 7] {
            let options = JSONLinesReadOptions(strictness: .strict, chunkSize: chunkSize)
            #expect(try JSONLines.decode(Entry.self, from: data, options: options) == entries)
        }
    }

    @Test("A degenerate chunk size cannot hang or trap the reader", arguments: [0, -1, Int.min + 1])
    func degenerateChunkSize(chunkSize: Int) throws {
        // `chunkSize` is a settable property and the tests below tweak it in
        // place, so the init's clamp is not the only place it has to hold. Zero
        // used to make the in-memory reader advance by nothing and spin forever
        // (and the file reader return no entries at all); a negative value used
        // to trap inside `Data.index(_:offsetBy:limitedBy:)`.
        var options = JSONLinesReadOptions(strictness: .strict)
        options.chunkSize = chunkSize
        #expect(options.chunkSize >= 1)

        let data = try JSONLines.encode([Entry(id: "a"), Entry(id: "b")])
        #expect(try JSONLines.decode(Entry.self, from: data, options: options).map(\.id) == ["a", "b"])

        let path = try makeTemporaryDirectory().appending("session.jsonl")
        try data.write(to: URL(fileURLWithPath: path.string))
        #expect(try JSONLines.decode(Entry.self, contentsOf: path, options: options).map(\.id) == ["a", "b"])
    }

    @Test("A negative line bound cannot turn a blank line into an error")
    func degenerateMaximumLineBytes() throws {
        let sink = SkippedLineSink()
        var options = sink.options
        options.maximumLineBytes = -1
        #expect(options.maximumLineBytes == 0)
        _ = try JSONLines.decode(Entry.self, from: Data("\n\n".utf8), options: options)
        #expect(sink.errors.isEmpty)
    }

    @Test("A very large single line is streamed, not chopped by the read buffer")
    func veryLargeLine() throws {
        let big = Entry(id: "big", text: String(repeating: "x", count: 4 * 1024 * 1024))
        let data = try JSONLines.encode([Entry(id: "a"), big, Entry(id: "b")])
        let options = JSONLinesReadOptions(strictness: .strict, chunkSize: 4096)
        let decoded = try JSONLines.decode(Entry.self, from: data, options: options)
        #expect(decoded.map(\.id) == ["a", "big", "b"])
        #expect(decoded[1].text.count == 4 * 1024 * 1024)
    }
}

// MARK: - Strictness

@Suite("JSONL strictness policy")
struct JSONLinesStrictnessTests {
    private static let mixed = """
        {"type":"message","id":"a","text":""}
        {"type":"message","id":"b",
        {"type":"message","id":"c","text":""}

        """

    @Test("A malformed middle line is skipped when tolerant")
    func malformedMiddleTolerant() throws {
        let sink = SkippedLineSink()
        let decoded = try JSONLines.decode(Entry.self, from: Data(Self.mixed.utf8), options: sink.options)
        #expect(decoded.map(\.id) == ["a", "c"])
        #expect(sink.errors.count == 1)
        #expect(sink.errors.first?.kind == .malformedLine)
        #expect(sink.errors.first?.lineNumber == 2)
    }

    @Test("A malformed middle line throws when strict")
    func malformedMiddleStrict() throws {
        let error = #expect(throws: JSONLinesError.self) {
            try JSONLines.decode(Entry.self, from: Data(Self.mixed.utf8), options: .strict)
        }
        #expect(error?.lineNumber == 2)
        #expect(error?.kind == .malformedLine)
    }

    @Test("Entries before a strict failure still reach the caller")
    func strictYieldsPrefixBeforeThrowing() throws {
        var seen: [String] = []
        #expect(throws: JSONLinesError.self) {
            try JSONLines.read(Entry.self, from: Data(Self.mixed.utf8), options: .strict) { seen.append($0.id) }
        }
        #expect(seen == ["a"])
    }

    @Test("The reported byte offset points at the start of the bad line")
    func byteOffset() throws {
        let sink = SkippedLineSink()
        _ = try JSONLines.decode(Entry.self, from: Data(Self.mixed.utf8), options: sink.options)
        let firstLineBytes = Self.mixed.split(separator: "\n", omittingEmptySubsequences: false)[0].utf8.count
        #expect(sink.errors.first?.byteOffset == firstLineBytes + 1)
    }

    @Test("Well-formed JSON of the wrong shape is a malformed line, not an entry")
    func shapeMismatch() throws {
        // pi's tolerant path casts rather than validates, so it would keep this
        // line as a half-initialized entry; Decodable rejects it. Documented
        // divergence — the point of the test is that the rejection is reported.
        let text = """
            {"type":"message","id":"a","text":""}
            {"type":"message","id":42,"text":""}
            """
        let sink = SkippedLineSink()
        let decoded = try JSONLines.decode(Entry.self, from: Data(text.utf8), options: sink.options)
        #expect(decoded.map(\.id) == ["a"])
        #expect(sink.errors.count == 1)

        #expect(throws: JSONLinesError.self) {
            try JSONLines.decode(Entry.self, from: Data(text.utf8), options: .strict)
        }
    }

    @Test("A tolerant read of a heterogeneous session keeps unknown entry types")
    func heterogeneousAsJSONValue() throws {
        let text = """
            {"type":"session","version":3,"id":"s"}
            {"type":"message","id":"a"}
            {"type":"invented_by_an_extension","id":"b"}
            """
        let decoded = try JSONLines.decode(JSONValue.self, from: Data(text.utf8), options: .strict)
        #expect(decoded.count == 3)
        #expect(decoded[0]["version"]?.intValue == 3)
    }
}

// MARK: - Crash truncation

@Suite("JSONL crash truncation")
struct JSONLinesTruncationTests {
    /// Two good entries followed by the first 20 bytes of a third: what an
    /// `O_APPEND` write interrupted by SIGKILL leaves on disk.
    private static func truncatedDocument() throws -> Data {
        var data = try JSONLines.encode([Entry(id: "a"), Entry(id: "b")])
        data.append(try JSONLines.encodeLine(Entry(id: "c")).prefix(20))
        return data
    }

    @Test("A truncated final line is skipped when tolerant")
    func truncatedTolerant() throws {
        let sink = SkippedLineSink()
        let decoded = try JSONLines.decode(Entry.self, from: try Self.truncatedDocument(), options: sink.options)
        #expect(decoded.map(\.id) == ["a", "b"])
        #expect(sink.errors.map(\.lineNumber) == [3])
    }

    @Test("A truncated final line throws when strict, after the good entries")
    func truncatedStrict() throws {
        var seen: [String] = []
        let error = #expect(throws: JSONLinesError.self) {
            try JSONLines.read(Entry.self, from: try Self.truncatedDocument(), options: .strict) {
                seen.append($0.id)
            }
        }
        #expect(seen == ["a", "b"])
        #expect(error?.lineNumber == 3)
    }

    @Test("A line truncated inside a multi-byte scalar is skipped, not fatal")
    func truncatedInsideScalar() throws {
        var data = try JSONLines.encode([Entry(id: "a")])
        // Cut one byte into the trailing emoji's UTF-8 sequence.
        let partial = try JSONLines.encodeLine(Entry(id: "b", text: "🙂"))
        data.append(partial.prefix(partial.count - 4))
        let decoded = try JSONLines.decode(Entry.self, from: data)
        #expect(decoded.map(\.id) == ["a"])
    }

    @Test("An overlong line is abandoned and reading resumes at the next line")
    func lineTooLongTolerant() throws {
        let sink = SkippedLineSink()
        var options = sink.options
        options.maximumLineBytes = 128
        options.chunkSize = 16
        let data = try JSONLines.encode([
            Entry(id: "a"),
            Entry(id: "huge", text: String(repeating: "x", count: 4096)),
            Entry(id: "b"),
        ])
        let decoded = try JSONLines.decode(Entry.self, from: data, options: options)
        #expect(decoded.map(\.id) == ["a", "b"])
        #expect(sink.errors.map(\.kind) == [.lineTooLong])
        #expect(sink.errors.first?.lineNumber == 2)
    }

    @Test("An overlong line throws when strict")
    func lineTooLongStrict() throws {
        var options = JSONLinesReadOptions.strict
        options.maximumLineBytes = 128
        let data = try JSONLines.encode([Entry(id: "huge", text: String(repeating: "x", count: 4096))])
        let error = #expect(throws: JSONLinesError.self) {
            try JSONLines.decode(Entry.self, from: data, options: options)
        }
        #expect(error?.kind == .lineTooLong)
    }
}

// MARK: - Files

@Suite("JSONL files")
struct JSONLinesFileTests {
    @Test("An empty file yields no entries")
    func emptyFile() throws {
        let path = try makeTemporaryDirectory().appending("empty.jsonl")
        try write("", to: path)
        #expect(try JSONLines.decode(Entry.self, contentsOf: path, options: .strict).isEmpty)
    }

    @Test("A missing file throws rather than reading as empty")
    func missingFile() throws {
        let path = try makeTemporaryDirectory().appending("absent.jsonl")
        #expect(throws: (any Error).self) {
            try JSONLines.decode(Entry.self, contentsOf: path)
        }
    }

    @Test("Appended entries are readable, one line each")
    func appendRoundTrip() throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        let writer = JSONLinesFileWriter(path: path)
        try writer.append(Entry(type: "session", id: "s"))
        try writer.append(Entry(id: "a", parentId: nil))
        try writer.append(contentsOf: [Entry(id: "b", parentId: "a"), Entry(id: "c", parentId: "b")])

        let decoded = try JSONLines.decode(Entry.self, contentsOf: path, options: .strict)
        #expect(decoded.map(\.id) == ["s", "a", "b", "c"])
        #expect(try read(path).hasSuffix("\n"))
    }

    @Test("Appending after a crash-truncated tail loses only the partial entry")
    func appendAfterTruncation() throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        let writer = JSONLinesFileWriter(path: path)
        try writer.append(Entry(id: "a"))
        // Simulate the interrupted write: a partial line with no newline.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path.string))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"mess"#.utf8))
        try handle.close()

        try writer.append(Entry(id: "b"))

        let sink = SkippedLineSink()
        let decoded = try JSONLines.decode(Entry.self, contentsOf: path, options: sink.options)
        #expect(decoded.map(\.id) == ["a", "b"])
        #expect(sink.errors.map(\.kind) == [.malformedLine])
    }

    @Test("Replacing contents truncates the previous file")
    func replaceContents() throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        let writer = JSONLinesFileWriter(path: path)
        try writer.append(contentsOf: (0..<20).map { Entry(id: "\($0)") })
        try writer.replaceContents(with: [Entry(type: "session", id: "s")])
        #expect(try JSONLines.decode(Entry.self, contentsOf: path, options: .strict).map(\.id) == ["s"])
    }

    @Test("A new session file is created private to its owner")
    func permissions() throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        try JSONLinesFileWriter(path: path).append(Entry(id: "a"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.string)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test("The async reader streams a file that straddles chunk boundaries")
    func asyncReader() async throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        let entries = (0..<50).map { Entry(id: "\($0)", text: "🙂 payload \($0)") }
        try JSONLinesFileWriter(path: path).append(contentsOf: entries)

        let reader = JSONLinesFileReader<Entry>(
            path: path,
            options: JSONLinesReadOptions(strictness: .strict, chunkSize: 7)
        )
        var decoded: [Entry] = []
        for try await entry in reader { decoded.append(entry) }
        #expect(decoded == entries)
    }

    @Test("The async reader stops at a truncated tail without losing what precedes it")
    func asyncReaderTruncated() async throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        var data = try JSONLines.encode([Entry(id: "a"), Entry(id: "b")])
        data.append(try JSONLines.encodeLine(Entry(id: "c")).prefix(12))
        try data.write(to: URL(fileURLWithPath: path.string))

        var tolerant: [String] = []
        for try await entry in JSONLinesFileReader<Entry>(path: path) { tolerant.append(entry.id) }
        #expect(tolerant == ["a", "b"])

        var strict: [String] = []
        await #expect(throws: JSONLinesError.self) {
            for try await entry in JSONLinesFileReader<Entry>(path: path, options: .strict) {
                strict.append(entry.id)
            }
        }
        #expect(strict == ["a", "b"])
    }

    @Test("The async reader delivers the prefix before a strict failure, like the sync reader")
    func asyncStrictYieldsPrefixBeforeThrowing() async throws {
        // The iterator decodes a whole chunk before it returns anything, so a
        // strict failure part-way through a chunk used to discard every good
        // entry decoded ahead of it — up to `chunkSize` worth — while the
        // synchronous reader delivered them. The two must agree.
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        var data = try JSONLines.encode([Entry(id: "a"), Entry(id: "b")])
        data.append(Data((#"{"type":"message","id":"c","# + "\n").utf8))
        data.append(try JSONLines.encode([Entry(id: "d")]))
        try data.write(to: URL(fileURLWithPath: path.string))

        var synchronous: [String] = []
        #expect(throws: JSONLinesError.self) {
            try JSONLines.read(Entry.self, contentsOf: path, options: .strict) { synchronous.append($0.id) }
        }
        #expect(synchronous == ["a", "b"])

        // One chunk large enough to hold the whole file, so the failure lands in
        // the same chunk as the entries that precede it.
        var asynchronous: [String] = []
        await #expect(throws: JSONLinesError.self) {
            for try await entry in JSONLinesFileReader<Entry>(path: path, options: .strict) {
                asynchronous.append(entry.id)
            }
        }
        #expect(asynchronous == synchronous)
    }

    @Test("The async sequence can be iterated twice")
    func asyncReaderRepeatable() async throws {
        let path = try makeTemporaryDirectory().appending("session.jsonl")
        try JSONLinesFileWriter(path: path).append(contentsOf: [Entry(id: "a"), Entry(id: "b")])
        let reader = JSONLinesFileReader<Entry>(path: path, options: .strict)
        for _ in 0..<2 {
            var ids: [String] = []
            for try await entry in reader { ids.append(entry.id) }
            #expect(ids == ["a", "b"])
        }
    }
}
