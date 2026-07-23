// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/session/jsonl-storage.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation
import SystemPackage

/// A session tree persisted as one append-only JSONL file over
/// ``DoMoCore/JSONLinesFileWriter``/``DoMoCore/JSONLines``.
///
/// The store holds no in-memory copy of the tree. It is a value that names a
/// file and re-derives everything from it, so it is trivially `Sendable`, has no
/// cache to fall out of sync with the file another process appended to, and
/// nothing to flush or leak if the process dies. The mutable *tip* of a live
/// session — the leaf that moves as a run streams entries — is not this layer's
/// concern; it belongs to the session/harness layer above, which can cache it in
/// an `actor` rather than re-reading the file per append.
///
/// The file's first line is a ``SessionHeader``; every line after it is a
/// ``SessionTreeEntry``. The two are read by different paths on purpose — the
/// header strictly, the entries tolerantly — which is the pi asymmetry this port
/// exists to preserve.
public struct JSONLSessionStore: SessionStorage {
    public let path: FilePath
    public let permissions: FilePermissions

    /// Injected so tests are deterministic and never depend on the wall clock:
    /// the header timestamp and the timestamp component of the file name both
    /// come from here.
    private let now: @Sendable () -> Date

    /// Injected so tests can pin entry ids. The default is UUIDv7, whose string
    /// form sorts in creation order — the property the tree relies on.
    private let entryIDFactory: @Sendable () -> String

    public init(
        path: FilePath,
        permissions: FilePermissions = .ownerReadWrite,
        now: @escaping @Sendable () -> Date = { Date() },
        entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description }
    ) {
        self.path = path
        self.permissions = permissions
        self.now = now
        self.entryIDFactory = entryIDFactory
    }

    private var writer: JSONLinesFileWriter {
        JSONLinesFileWriter(path: path, permissions: permissions)
    }

    // MARK: - Creation, opening, listing

    // These are concrete factories rather than `SessionStorage` requirements
    // because they encode this backend's path scheme
    // (`<dir>/<sanitized-cwd>/<timestamp>_<uuid>.jsonl`); a different backend
    // would locate sessions differently. See the note on `SessionStorage`.

    /// Creates a new session file and writes its header as the first line.
    ///
    /// The directory is the *configured* session directory, always injected, so a
    /// test never has to touch the real `~/.domocode`. The file name embeds the
    /// creation timestamp and session id so a directory listing is sortable and
    /// unique without opening a single file.
    public static func create(
        cwd: String,
        sessionDirectory: FilePath,
        sessionID: String? = nil,
        parentSession: String? = nil,
        permissions: FilePermissions = .ownerReadWrite,
        now: @escaping @Sendable () -> Date = { Date() },
        entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description }
    ) throws -> JSONLSessionStore {
        let date = now()
        let timestamp = Self.iso8601(date)
        let id = sessionID ?? UUIDv7.generate().description
        let directory = sessionDirectory.appending(Self.sanitizedDirectoryName(forCwd: cwd))
        try Self.makeDirectory(directory)
        let fileName = "\(Self.fileTimestamp(from: timestamp))_\(id).jsonl"
        let filePath = directory.appending(fileName)
        let header = SessionHeader(id: id, timestamp: timestamp, cwd: cwd, parentSession: parentSession)
        let writer = JSONLinesFileWriter(path: filePath, permissions: permissions)
        do {
            try writer.replaceContents(with: [header])
        } catch {
            throw DoMoError(.file(path: filePath, errno: nil), "Failed to create session file", cause: error)
        }
        return JSONLSessionStore(path: filePath, permissions: permissions, now: now, entryIDFactory: entryIDFactory)
    }

    /// Opens an existing session file, validating its header.
    ///
    /// Opening validates eagerly (unlike listing, which tolerates a corrupt file
    /// by skipping it): a caller that named a specific session must be told now
    /// if that file is not a session, not handed a store that fails later.
    public static func open(
        path: FilePath,
        permissions: FilePermissions = .ownerReadWrite,
        now: @escaping @Sendable () -> Date = { Date() },
        entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description }
    ) throws -> JSONLSessionStore {
        let store = JSONLSessionStore(path: path, permissions: permissions, now: now, entryIDFactory: entryIDFactory)
        _ = try store.readHeader()
        return store
    }

    /// Lists the sessions recorded for `cwd` under `sessionDirectory`, newest by
    /// header timestamp last.
    ///
    /// A file whose header will not parse is skipped, not fatal: one corrupt file
    /// must not make the whole directory unlistable. This is the same fail-open
    /// stance as the bulk entry read, applied at the directory level.
    public static func list(cwd: String, sessionDirectory: FilePath) throws -> [SessionListing] {
        let directory = sessionDirectory.appending(Self.sanitizedDirectoryName(forCwd: cwd))
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.string) else {
            return []
        }
        var listings: [SessionListing] = []
        for name in names where name.hasSuffix(".jsonl") {
            let filePath = directory.appending(name)
            guard let header = try? JSONLSessionStore(path: filePath).readHeader() else { continue }
            listings.append(SessionListing(path: filePath, header: header))
        }
        listings.sort { $0.header.timestamp < $1.header.timestamp }
        return listings
    }

    // MARK: - Reads

    public func readHeader() throws -> SessionHeader {
        // Strict on purpose: the header is read as its own single line and decoded
        // with a throwing decoder, so a file whose first line is missing or
        // malformed surfaces a real error instead of an empty session. This is one
        // half of pi's read asymmetry — the other half is `readEntries`.
        guard let data = try Self.firstLineData(of: path) else {
            throw DoMoError(.file(path: path, errno: nil), "Session file is empty: \(path.string)")
        }
        do {
            return try JSONDecoder().decode(SessionHeader.self, from: data)
        } catch {
            throw DoMoError(.file(path: path, errno: nil), "Invalid session header: \(path.string)", cause: error)
        }
    }

    public func readEntries(
        onSkippedLine: (@Sendable (JSONLinesError) -> Void)? = nil
    ) throws -> [SessionTreeEntry] {
        // Tolerant on purpose: this is the resume path. A line that will not
        // decode — a crash-truncated final entry, or a malformed middle line — is
        // skipped and reported through `onSkippedLine`, never fatal, so a session
        // interrupted mid-append still yields everything written before the break.
        // The header line (type "session") decodes into the `AnyLine.header` case
        // and is filtered out here rather than counted as a skipped entry.
        let options = JSONLinesReadOptions(strictness: .tolerant, onSkippedLine: onSkippedLine)
        let lines = try JSONLines.decode(AnyLine.self, contentsOf: path, options: options)
        return lines.compactMap { line in
            if case .entry(let entry) = line.value { return entry }
            return nil
        }
    }

    public func createEntryID() -> String {
        entryIDFactory()
    }

    public func entry(withID id: String) throws -> SessionTreeEntry? {
        try readEntries().first { $0.id == id }
    }

    public func leafID() throws -> String? {
        try readEntries().last?.leafIdAfterEntry
    }

    public func pathToRootOrCompaction(from leafID: String?) throws -> [SessionTreeEntry] {
        guard let leafID else { return [] }
        let entries = try readEntries()
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        // Fails closed even though the entries above were read tolerantly: a leaf
        // or parent that the tolerant read dropped leaves a hole the *path* cannot
        // span, and resuming against a silently shortened context is worse than
        // refusing. This is exactly pi's `getPathToRootOrCompaction`, which throws
        // where the row decode skips.
        guard var current = byID[leafID] else {
            throw DoMoError(.file(path: path, errno: nil), "Session entry not found: \(leafID)")
        }
        var path: [SessionTreeEntry] = []
        var stopAtEntryID: String? = nil
        while true {
            path.insert(current, at: 0)
            if let stop = stopAtEntryID, current.id == stop { break }
            if case .compaction(let compaction) = current.payload {
                if compaction.retainedTail != nil { break }
                stopAtEntryID = compaction.firstKeptEntryId
            }
            guard let parentID = current.parentId else { break }
            guard let parent = byID[parentID] else {
                throw DoMoError(.file(path: self.path, errno: nil), "Session entry not found: \(parentID)")
            }
            current = parent
        }
        return path
    }

    // MARK: - Append

    public func appendEntry(_ entry: SessionTreeEntry) throws {
        do {
            try writer.append(entry)
        } catch {
            throw DoMoError(.file(path: path, errno: nil), "Failed to append session entry \(entry.id)", cause: error)
        }
    }

    // MARK: - File-line union

    /// A single physical line, either the header or a tree entry.
    ///
    /// One decodable type for both so the whole file can be read in a single
    /// tolerant pass: the discriminator `type` decides which, and the header line
    /// is filtered out by the caller instead of being reported as a bad entry.
    private struct AnyLine: Decodable {
        enum Value {
            case header(SessionHeader)
            case entry(SessionTreeEntry)
        }

        let value: Value

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "session" {
                value = .header(try SessionHeader(from: decoder))
            } else {
                value = .entry(try SessionTreeEntry(from: decoder))
            }
        }
    }

    // MARK: - Path helpers

    /// Encodes `cwd` into a single safe directory-name component.
    ///
    /// Mirrors pi's scheme: strip one leading separator, replace path separators
    /// and the Windows drive colon with `-`, and wrap in `--…--` so the encoded
    /// name is visually distinct from a real path segment.
    static func sanitizedDirectoryName(forCwd cwd: String) -> String {
        var stripped = Substring(cwd)
        if let first = stripped.first, first == "/" || first == "\\" {
            stripped = stripped.dropFirst()
        }
        let mapped = String(stripped.map { character in
            (character == "/" || character == "\\" || character == ":") ? "-" : character
        })
        return "--\(mapped)--"
    }

    /// Turns an ISO-8601 timestamp into a file-name-safe token by replacing the
    /// characters a filesystem dislikes (`:` and `.`) with `-`.
    static func fileTimestamp(from iso: String) -> String {
        String(iso.map { ($0 == ":" || $0 == ".") ? "-" : $0 })
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func makeDirectory(_ directory: FilePath) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: directory.string,
                withIntermediateDirectories: true
            )
        } catch {
            throw DoMoError(.file(path: directory, errno: nil), "Failed to create session directory", cause: error)
        }
    }

    /// Reads the bytes of the file's first line (excluding the newline), or `nil`
    /// for an empty file. Reads only as far as the first newline so a header can
    /// be read without loading a multi-gigabyte session.
    private static func firstLineData(of path: FilePath) throws -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path.string)) else {
            throw DoMoError(.file(path: path, errno: nil), "Session file not found: \(path.string)")
        }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return Self.trimmingTrailingWhitespace(buffer)
            }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : Self.trimmingTrailingWhitespace(buffer)
    }

    private static func trimmingTrailingWhitespace(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex {
            let byte = data[data.index(before: end)]
            let isWhitespace = byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
            if !isWhitespace { break }
            end = data.index(before: end)
        }
        return data[data.startIndex..<end]
    }
}
