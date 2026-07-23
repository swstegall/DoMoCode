// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/session-manager.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import Foundation
import SystemPackage

// MARK: - Strictness

/// What a reader does when a line cannot be turned into a value.
///
/// This is a parameter rather than a fixed policy because pi is itself
/// inconsistent, and the inconsistency is load-bearing in both directions.
/// `loadEntriesFromFile` and `parseSessionEntries` in `session-manager.ts`
/// silently drop unparseable lines, which is what makes `--continue` survive a
/// crash mid-append. `jsonl-storage.ts` (`parseEntryLine`) throws a
/// `SessionError` on the very same bytes, because a session it is asked to open
/// by name should not come back quietly missing entries.
///
/// Swift makes the choice sharper than TypeScript does. pi's tolerant path casts
/// (`JSON.parse(line) as FileEntry`) and so accepts any line that is *syntactically*
/// JSON, garbage shape included; `Decodable` rejects a well-formed line whose
/// shape is wrong. So ``tolerant`` here drops strictly more lines than pi's
/// tolerant path does — a session entry with a field of the wrong type is skipped
/// rather than resurrected as a half-initialized object. That is the intended
/// behavior, but it means resume can silently shorten a session, which is why
/// ``JSONLinesReadOptions/onSkippedLine`` exists.
public enum JSONLinesStrictness: Sendable, Hashable {
    /// Skip lines that fail to decode, reporting them through
    /// ``JSONLinesReadOptions/onSkippedLine``. Use this for resume: a session
    /// truncated by a crash should still open.
    case tolerant

    /// Throw ``JSONLinesError`` on the first line that fails to decode. Use this
    /// for import, validation and migration, where silently losing an entry is
    /// worse than refusing the file.
    case strict
}

// MARK: - Errors

/// A single line that could not be decoded.
///
/// Carries the byte offset as well as the line number: the offset is what a
/// repair tool needs in order to truncate a file back to its last intact entry,
/// and it is not recoverable from the line number once the file contains
/// arbitrary-length tool results.
public struct JSONLinesError: Error, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The line is not JSON, is not valid UTF-8, or does not match the
        /// expected shape. All three are the same recovery action.
        case malformedLine

        /// The line exceeded ``JSONLinesReadOptions/maximumLineBytes`` and was
        /// abandoned without being buffered to completion.
        case lineTooLong
    }

    public var kind: Kind
    /// 1-based physical line number, counting blank and skipped lines.
    public var lineNumber: Int
    /// Byte offset of the first byte of the line within the stream.
    public var byteOffset: Int
    /// Bytes seen for this line. For ``Kind/lineTooLong`` this is how much was
    /// buffered before the limit tripped, not the true length of the line.
    public var byteCount: Int
    public var detail: String

    public init(kind: Kind, lineNumber: Int, byteOffset: Int, byteCount: Int, detail: String) {
        self.kind = kind
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
        self.byteCount = byteCount
        self.detail = detail
    }
}

extension JSONLinesError: CustomStringConvertible {
    public var description: String {
        "line \(lineNumber) (offset \(byteOffset), \(byteCount) bytes): \(detail)"
    }
}

// MARK: - Read options

/// How a JSONL stream is read.
public struct JSONLinesReadOptions: Sendable {
    public var strictness: JSONLinesStrictness

    /// Bytes requested per read. Only a performance knob for files, but tests
    /// use small values to force line boundaries, multi-byte UTF-8 scalars and
    /// CRLF pairs to straddle two reads.
    ///
    /// Clamped to at least 1 on every write, not just in ``init``: this is a
    /// settable property on a struct callers are expected to tweak in place, and
    /// a zero here makes the in-memory reader advance by nothing and spin
    /// forever, while a negative one traps inside `Data.index(_:offsetBy:)`.
    public var chunkSize: Int {
        get { storedChunkSize }
        set { storedChunkSize = Swift.max(1, newValue) }
    }

    private var storedChunkSize: Int = 64 * 1024

    /// Upper bound on a single line, or `nil` for unbounded.
    ///
    /// Unbounded is the default because a legitimate line can be enormous — a
    /// tool result holding an entire file — and truncating one at an arbitrary
    /// limit loses a real entry. A bound is still worth setting when reading
    /// files you did not write: without it, a corrupt file with no newline in it
    /// is read entirely into memory before it can be rejected.
    ///
    /// Clamped at zero: a negative bound would make even a blank line report
    /// ``JSONLinesError/Kind/lineTooLong``.
    public var maximumLineBytes: Int? {
        get { storedMaximumLineBytes }
        set { storedMaximumLineBytes = newValue.map { Swift.max(0, $0) } }
    }

    private var storedMaximumLineBytes: Int?

    /// Called for each line dropped under ``JSONLinesStrictness/tolerant``.
    ///
    /// pi drops these silently, so a session that quietly loses half its history
    /// looks identical to one that never had it. Logging the drop is cheap and
    /// is the only signal that a session file needs repair.
    public var onSkippedLine: (@Sendable (JSONLinesError) -> Void)?

    public init(
        strictness: JSONLinesStrictness = .tolerant,
        chunkSize: Int = 64 * 1024,
        maximumLineBytes: Int? = nil,
        onSkippedLine: (@Sendable (JSONLinesError) -> Void)? = nil
    ) {
        self.strictness = strictness
        // A zero or negative chunk size would spin forever rather than fail.
        self.chunkSize = chunkSize
        self.maximumLineBytes = maximumLineBytes
        self.onSkippedLine = onSkippedLine
    }

    public static let tolerant = JSONLinesReadOptions(strictness: .tolerant)
    public static let strict = JSONLinesReadOptions(strictness: .strict)
}

// MARK: - Encoding

/// The JSON Lines codec: one JSON value per line, newline-terminated, appended
/// in place.
///
/// The format is chosen for its crash behavior rather than its elegance. An
/// append is a single `write(2)` to an `O_APPEND` descriptor, so a process that
/// dies mid-write damages at most the final line, and a reader that skips that
/// line recovers everything before it. Nothing rewrites earlier bytes, so there
/// is no window in which the file as a whole is invalid.
public enum JSONLines {
    /// Encodes one value as a newline-terminated JSONL line.
    ///
    /// The encoder is constructed here rather than accepted as a parameter, for
    /// two reasons. `JSONEncoder` is a non-`Sendable` class, so taking one would
    /// infect every writer with its isolation; and a caller-supplied encoder
    /// could carry `.prettyPrinted`, whose embedded newlines would silently
    /// shred one entry into many unparseable lines.
    ///
    /// Keys are sorted for the same reason as ``JSONValue/encoded(prettyPrinted:)``:
    /// session files are diffed and hashed, and `Dictionary` order is not stable
    /// across processes.
    public static func encodeLine(_ value: some Encodable) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// Encodes a sequence of values as a JSONL document, including the trailing
    /// newline after the final line.
    public static func encode<S: Sequence>(_ values: S) throws -> Data where S.Element: Encodable {
        var data = Data()
        for value in values {
            data.append(try encodeLine(value))
        }
        return data
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Line splitting

/// Splits a byte stream into lines without ever decoding text.
///
/// Splitting on the byte `0x0A` rather than on decoded characters is what makes
/// a chunk boundary in the middle of a multi-byte scalar a non-event: no UTF-8
/// continuation byte can be `0x0A`, so a line boundary found in bytes is always
/// a real one, and the scalar is reassembled by concatenation before anything
/// tries to read it as text. pi needs a `StringDecoder` to hold partial scalars
/// across reads precisely because it decodes each chunk to a string first.
struct JSONLinesLineBuffer {
    enum Event {
        /// A complete line, trimmed of ASCII whitespace (which subsumes the CR
        /// of a CRLF pair).
        case line(ArraySlice<UInt8>, number: Int, offset: Int)
        case tooLong(number: Int, offset: Int, byteCount: Int)
    }

    let maximumLineBytes: Int?

    private var pending: [UInt8] = []
    private var lineNumber = 1
    private var lineStartOffset = 0
    private var offset = 0
    /// Set when the current line blew the size limit: the rest of it is dropped
    /// as it arrives, so that reading can resume at the next newline instead of
    /// buffering a line that has already been rejected.
    private var isSkippingLine = false

    init(maximumLineBytes: Int?) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func push<C: Collection<UInt8>>(_ chunk: C, _ body: (Event) throws -> Void) rethrows {
        var index = chunk.startIndex
        while index != chunk.endIndex {
            guard let newline = chunk[index...].firstIndex(of: 0x0A) else {
                let tail = chunk[index...]
                offset += chunk.distance(from: index, to: chunk.endIndex)
                if !isSkippingLine {
                    pending.append(contentsOf: tail)
                    try enforceLimit(body)
                }
                return
            }

            offset += chunk.distance(from: index, to: newline) + 1
            if isSkippingLine {
                isSkippingLine = false
                pending.removeAll(keepingCapacity: false)
            } else {
                pending.append(contentsOf: chunk[index..<newline])
                try emit(body)
            }
            lineNumber += 1
            lineStartOffset = offset
            index = chunk.index(after: newline)
        }
    }

    /// Emits the bytes after the last newline, if any.
    ///
    /// A file ending in `"\n"` leaves nothing pending, so it yields no phantom
    /// final line; a file whose last entry was written without its newline —
    /// which is what a crash mid-append leaves behind — yields that entry as a
    /// line, and it is the decode step that decides whether the truncated JSON
    /// is usable.
    mutating func finish(_ body: (Event) throws -> Void) rethrows {
        guard !isSkippingLine, !pending.isEmpty else { return }
        try emit(body)
    }

    private mutating func emit(_ body: (Event) throws -> Void) rethrows {
        defer { pending.removeAll(keepingCapacity: true) }
        if let limit = maximumLineBytes, pending.count > limit {
            try body(.tooLong(number: lineNumber, offset: lineStartOffset, byteCount: pending.count))
            return
        }
        try body(.line(Self.trimmed(pending[...]), number: lineNumber, offset: lineStartOffset))
    }

    private mutating func enforceLimit(_ body: (Event) throws -> Void) rethrows {
        guard let limit = maximumLineBytes, pending.count > limit else { return }
        let byteCount = pending.count
        pending.removeAll(keepingCapacity: false)
        isSkippingLine = true
        try body(.tooLong(number: lineNumber, offset: lineStartOffset, byteCount: byteCount))
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end, isASCIIWhitespace(bytes[start]) { start += 1 }
        while end > start, isASCIIWhitespace(bytes[end - 1]) { end -= 1 }
        return bytes[start..<end]
    }
}

// MARK: - Line decoding

/// Applies the strictness policy to the events a ``JSONLinesLineBuffer`` produces.
struct JSONLinesLineDecoder<Element: Decodable> {
    private let options: JSONLinesReadOptions
    private let decoder = JSONDecoder()
    private var buffer: JSONLinesLineBuffer

    init(options: JSONLinesReadOptions) {
        self.options = options
        self.buffer = JSONLinesLineBuffer(maximumLineBytes: options.maximumLineBytes)
    }

    mutating func push<C: Collection<UInt8>>(
        _ chunk: C,
        _ body: (Element) throws -> Void
    ) throws {
        // The handler is built from locals rather than referring to `self`:
        // `buffer.push` holds `self.buffer` exclusively for the duration of the
        // call, and a closure that touched `self` would overlap that access.
        let decoder = decoder
        let options = options
        try buffer.push(chunk) { event in
            if let element = try Self.decode(event, using: decoder, options: options) {
                try body(element)
            }
        }
    }

    mutating func finish(_ body: (Element) throws -> Void) throws {
        let decoder = decoder
        let options = options
        try buffer.finish { event in
            if let element = try Self.decode(event, using: decoder, options: options) {
                try body(element)
            }
        }
    }

    private static func decode(
        _ event: JSONLinesLineBuffer.Event,
        using decoder: JSONDecoder,
        options: JSONLinesReadOptions
    ) throws -> Element? {
        switch event {
        case .tooLong(let number, let offset, let byteCount):
            try report(
                JSONLinesError(
                    kind: .lineTooLong,
                    lineNumber: number,
                    byteOffset: offset,
                    byteCount: byteCount,
                    detail: "line exceeds \(options.maximumLineBytes ?? 0) bytes"
                ),
                options: options
            )
            return nil

        case .line(let bytes, let number, let offset):
            // Blank lines are not entries and are not errors: pi skips any line
            // that is empty after trimming, and an editor or a partial flush can
            // leave one anywhere in the file.
            guard !bytes.isEmpty else { return nil }
            do {
                return try decoder.decode(Element.self, from: Data(bytes))
            } catch {
                try report(
                    JSONLinesError(
                        kind: .malformedLine,
                        lineNumber: number,
                        byteOffset: offset,
                        byteCount: bytes.count,
                        detail: String(describing: error)
                    ),
                    options: options
                )
                return nil
            }
        }
    }

    private static func report(_ error: JSONLinesError, options: JSONLinesReadOptions) throws {
        switch options.strictness {
        case .strict: throw error
        case .tolerant: options.onSkippedLine?(error)
        }
    }
}

// MARK: - Reading

extension JSONLines {
    /// Decodes an in-memory JSONL document, calling `body` per entry.
    public static func read<Element: Decodable>(
        _ type: Element.Type = Element.self,
        from data: Data,
        options: JSONLinesReadOptions = .tolerant,
        _ body: (Element) throws -> Void
    ) throws {
        var decoder = JSONLinesLineDecoder<Element>(options: options)
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: options.chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            try decoder.push(data[index..<end], body)
            index = end
        }
        try decoder.finish(body)
    }

    /// Decodes an in-memory JSONL document.
    public static func decode<Element: Decodable>(
        _ type: Element.Type = Element.self,
        from data: Data,
        options: JSONLinesReadOptions = .tolerant
    ) throws -> [Element] {
        var elements: [Element] = []
        try read(type, from: data, options: options) { elements.append($0) }
        return elements
    }

    /// Streams a JSONL file, calling `body` per entry.
    ///
    /// The file is read a chunk at a time and only one line is ever held in
    /// memory, so a multi-gigabyte session costs the size of its largest entry
    /// rather than the size of the file. This is the synchronous twin of
    /// ``JSONLinesFileReader``; use it when the caller is not already async, and
    /// note that both are strictly streaming — neither slurps.
    ///
    /// A missing file throws, where pi's `loadEntriesFromFile` returns `[]`.
    /// "Absent means empty" is a session-repository policy: at this layer it
    /// would swallow a typo'd path.
    public static func read<Element: Decodable>(
        _ type: Element.Type = Element.self,
        contentsOf path: FilePath,
        options: JSONLinesReadOptions = .tolerant,
        _ body: (Element) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
        defer { try? handle.close() }
        var decoder = JSONLinesLineDecoder<Element>(options: options)
        while let chunk = try handle.read(upToCount: options.chunkSize), !chunk.isEmpty {
            try decoder.push(chunk, body)
        }
        try decoder.finish(body)
    }

    /// Reads an entire JSONL file into memory.
    public static func decode<Element: Decodable>(
        _ type: Element.Type = Element.self,
        contentsOf path: FilePath,
        options: JSONLinesReadOptions = .tolerant
    ) throws -> [Element] {
        var elements: [Element] = []
        try read(type, contentsOf: path, options: options) { elements.append($0) }
        return elements
    }
}

// MARK: - Async reading

/// An `AsyncSequence` over the entries of a JSONL file.
///
/// The sequence is a value holding only a path, so it is `Sendable` and can be
/// iterated more than once; the file is opened lazily by the iterator, since
/// `makeAsyncIterator()` cannot throw.
public struct JSONLinesFileReader<Element: Decodable & Sendable>: AsyncSequence, Sendable {
    public let path: FilePath
    public let options: JSONLinesReadOptions

    public init(path: FilePath, options: JSONLinesReadOptions = .tolerant) {
        self.path = path
        self.options = options
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(path: path, options: options)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let path: FilePath
        private let options: JSONLinesReadOptions
        private var handle: FileHandle?
        private var decoder: JSONLinesLineDecoder<Element>
        private var ready: [Element] = []
        private var readyIndex = 0
        private var isFinished = false
        /// A strict-mode failure is held until everything decoded ahead of it
        /// has been handed to the caller. The synchronous reader gets this for
        /// free — it calls `body` as it goes, so the prefix has already been
        /// delivered by the time it throws — but the iterator decodes a whole
        /// chunk before returning anything, so rethrowing immediately would
        /// discard up to `chunkSize` worth of good entries.
        private var pendingFailure: (any Error)?

        init(path: FilePath, options: JSONLinesReadOptions) {
            self.path = path
            self.options = options
            self.decoder = JSONLinesLineDecoder<Element>(options: options)
        }

        public mutating func next() async throws -> Element? {
            while true {
                if readyIndex < ready.count {
                    defer { readyIndex += 1 }
                    return ready[readyIndex]
                }
                if let failure = pendingFailure {
                    pendingFailure = nil
                    isFinished = true
                    throw failure
                }
                if isFinished { return nil }

                ready.removeAll(keepingCapacity: true)
                readyIndex = 0

                // Reading a local file is a blocking syscall on whatever
                // executor the caller is running on. Yielding once per chunk
                // keeps a long session from monopolising a cooperative thread;
                // moving the read to a thread of its own would cost more than
                // the read does.
                await Task.yield()
                try Task.checkCancellation()

                let handle = try openIfNeeded()
                if let chunk = try handle.read(upToCount: options.chunkSize), !chunk.isEmpty {
                    do {
                        try decoder.push(chunk) { ready.append($0) }
                    } catch {
                        pendingFailure = error
                    }
                } else {
                    isFinished = true
                    do {
                        try decoder.finish { ready.append($0) }
                    } catch {
                        pendingFailure = error
                    }
                    try? handle.close()
                    self.handle = nil
                }
            }
        }

        private mutating func openIfNeeded() throws -> FileHandle {
            if let handle { return handle }
            let opened = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
            handle = opened
            return opened
        }
    }
}

// MARK: - Writing

/// Append-only JSONL file writer.
///
/// Holds a path rather than an open descriptor, and opens `O_APPEND` per call —
/// the same shape as pi's `appendFileSync`. Keeping no descriptor open means the
/// writer is a `Sendable` value with no lifecycle, no flush-on-deinit question
/// and nothing to leak if the process is killed; the extra `open`/`close` pair
/// is invisible next to the model round-trip that produced the entry.
///
/// Durability is deliberately not promised. Nothing here calls `fsync`, so a
/// power loss can lose the tail of the file — pi does not fsync either, and the
/// cost of a synchronous flush per entry is far larger than the cost of losing
/// the last entry of an interrupted session.
public struct JSONLinesFileWriter: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    /// - Parameter permissions: Applied only when the file is created. `0600` by
    ///   default because session files contain prompts, file contents and
    ///   sometimes credentials pasted into a chat.
    public init(path: FilePath, permissions: FilePermissions = .ownerReadWrite) {
        self.path = path
        self.permissions = permissions
    }

    /// Appends one value as a single line.
    public func append(_ value: some Encodable) throws {
        try appendBytes(JSONLines.encodeLine(value))
    }

    /// Appends several values in one write.
    ///
    /// Batching matters for crash behavior, not for speed: one `write(2)` of the
    /// whole batch can be torn only at its end, whereas a loop of appends can be
    /// interrupted between any two of them.
    public func append<S: Sequence>(contentsOf values: S) throws where S.Element: Encodable {
        let payload = try JSONLines.encode(values)
        guard !payload.isEmpty else { return }
        try appendBytes(payload)
    }

    /// Replaces the file's contents, creating it if absent.
    ///
    /// The only non-append operation, and the only one with a window in which
    /// the file is neither the old session nor the new one. It exists because
    /// creating a session must be able to overwrite a stale file at the same
    /// path; it is not part of the append path and must not be used there.
    public func replaceContents<S: Sequence>(with values: S) throws where S.Element: Encodable {
        let payload = try JSONLines.encode(values)
        let descriptor = try FileDescriptor.open(
            path,
            .writeOnly,
            options: [.create, .truncate],
            permissions: permissions
        )
        defer { try? descriptor.close() }
        try descriptor.writeAll(payload)
    }

    private func appendBytes(_ payload: Data) throws {
        // Encode before opening: an encoder that throws must not be able to
        // leave a half-written line behind it.
        let needsSeparator = try endsWithoutNewline()
        let descriptor = try FileDescriptor.open(
            path,
            .writeOnly,
            options: [.append, .create],
            permissions: permissions
        )
        defer { try? descriptor.close() }
        if needsSeparator {
            // The previous process died between writing an entry and writing its
            // newline. `O_APPEND` would glue this entry onto that fragment,
            // turning one lost entry into two; a separator confines the damage
            // to the fragment. pi does not do this, and loses the next entry too.
            try descriptor.writeAll([0x0A] + payload)
        } else {
            try descriptor.writeAll(payload)
        }
    }

    private func endsWithoutNewline() throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path.string)) else {
            return false
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end > 0 else { return false }
        try handle.seek(toOffset: end - 1)
        return try handle.read(upToCount: 1)?.first != 0x0A
    }
}
