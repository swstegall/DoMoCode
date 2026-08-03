// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

/// The four durable memory classes kept outside the workspace checkout.
public enum ProjectMemoryKind: String, Codable, Hashable, Sendable, CaseIterable {
    case project
    case environment
    case correction
    case sessionDigest
}

/// One typed project-memory record.
public struct ProjectMemoryRecord: Codable, Hashable, Sendable {
    public let id: String
    public let kind: ProjectMemoryKind
    public let title: String
    public let content: String
    public let createdAt: String
    public let updatedAt: String
    public let sourceSessionID: String?
    public let tags: [String]

    public init(
        id: String,
        kind: ProjectMemoryKind,
        title: String,
        content: String,
        createdAt: String,
        updatedAt: String,
        sourceSessionID: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceSessionID = sourceSessionID
        self.tags = tags
    }
}

/// The model-facing memory storage seam.
public protocol ProjectMemoryProvider: Sendable {
    func list() async throws -> [ProjectMemoryRecord]

    func remember(
        kind: ProjectMemoryKind,
        title: String,
        content: String,
        sourceSessionID: String?,
        tags: [String],
        id: String?
    ) async throws -> ProjectMemoryRecord

    func forget(id: String) async throws -> Bool
}

/// A small, typed, project-scoped memory document outside the repository.
///
/// The path is derived from a stable opaque workspace key under the user's
/// configuration directory, so the memory file neither lives in the checkout nor
/// repeats the checkout path in its filename. Writes are read-modify-write under
/// FileLock and committed through AtomicFileWrite.
public struct ProjectMemoryStore: ProjectMemoryProvider, Sendable {
    public static let defaultByteBudget = 256 * 1024
    public static let maximumRecordBytes = 16 * 1024

    public let path: FilePath
    public let byteBudget: Int

    private let now: @Sendable () -> Date

    /// Creates the per-workspace memory path beneath configDirectory/memory.
    public init(
        configDirectory: FilePath,
        cwd: String,
        byteBudget: Int = ProjectMemoryStore.defaultByteBudget,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            path: configDirectory
                .appending("memory")
                .appending(Self.workspaceKey(for: cwd))
                .appending("memory.json"),
            byteBudget: byteBudget,
            now: now
        )
    }

    /// An explicit path initializer for tests and embedding applications.
    public init(
        path: FilePath,
        byteBudget: Int = ProjectMemoryStore.defaultByteBudget,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.path = path
        self.byteBudget = max(1, byteBudget)
        self.now = now
    }

    public func list() async throws -> [ProjectMemoryRecord] {
        try Self.readRecords(at: path).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public func remember(
        kind: ProjectMemoryKind,
        title: String,
        content: String,
        sourceSessionID: String? = nil,
        tags: [String] = [],
        id: String? = nil
    ) async throws -> ProjectMemoryRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw ProjectMemoryError.emptyTitle }
        guard !normalizedContent.isEmpty else { throw ProjectMemoryError.emptyContent }
        guard normalizedContent.utf8.count <= Self.maximumRecordBytes else {
            throw ProjectMemoryError.recordTooLarge(limit: Self.maximumRecordBytes)
        }

        try Self.requireSafe(normalizedTitle, field: "title")
        try Self.requireSafe(normalizedContent, field: "content")
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedID = normalizedID?.isEmpty == false ? normalizedID : nil
        if let requestedID {
            try Self.requireSafe(requestedID, field: "id")
        }
        let normalizedSession = sourceSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedSession, !normalizedSession.isEmpty {
            try Self.requireSafe(normalizedSession, field: "sourceSessionID")
        }
        let normalizedTags = Array(
            Set(
                tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        for tag in normalizedTags { try Self.requireSafe(tag, field: "tags") }

        let timestamp = Self.iso8601(now())
        let lockPath = FileLock.lockPath(forDocumentAt: path.string)
        let outcome = try await FileLock.withLock(at: lockPath) {
            var records = try Self.readRecords(at: path)
            let existingIndex: Int?
            if let requestedID {
                existingIndex = records.firstIndex { $0.id == requestedID }
            } else {
                existingIndex = records.firstIndex {
                    $0.kind == kind && $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame
                }
            }

            let record: ProjectMemoryRecord
            if let existingIndex {
                let existing = records[existingIndex]
                record = ProjectMemoryRecord(
                    id: existing.id,
                    kind: kind,
                    title: normalizedTitle,
                    content: normalizedContent,
                    createdAt: existing.createdAt,
                    updatedAt: timestamp,
                    sourceSessionID: normalizedSession?.isEmpty == false ? normalizedSession : nil,
                    tags: normalizedTags
                )
                records[existingIndex] = record
            } else {
                record = ProjectMemoryRecord(
                    id: requestedID ?? UUIDv7.generate().description,
                    kind: kind,
                    title: normalizedTitle,
                    content: normalizedContent,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    sourceSessionID: normalizedSession?.isEmpty == false ? normalizedSession : nil,
                    tags: normalizedTags
                )
                records.append(record)
            }

            let data = try Self.encoded(records)
            guard data.count <= byteBudget else {
                throw ProjectMemoryError.byteBudgetExceeded(limit: byteBudget, required: data.count)
            }
            try AtomicFileWrite.replace(
                at: path.string,
                with: String(decoding: data, as: UTF8.self)
            )
            return record
        }
        switch outcome {
        case .ran(let record):
            return record
        case .contended:
            throw ProjectMemoryError.lockContended
        case .cancelled:
            throw ProjectMemoryError.cancelled
        }
    }

    public func forget(id: String) async throws -> Bool {
        let lockPath = FileLock.lockPath(forDocumentAt: path.string)
        let outcome = try await FileLock.withLock(at: lockPath) {
            var records = try Self.readRecords(at: path)
            guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
            records.remove(at: index)
            let data = try Self.encoded(records)
            guard data.count <= byteBudget else {
                throw ProjectMemoryError.byteBudgetExceeded(limit: byteBudget, required: data.count)
            }
            try AtomicFileWrite.replace(
                at: path.string,
                with: String(decoding: data, as: UTF8.self)
            )
            return true
        }
        switch outcome {
        case .ran(let removed):
            return removed
        case .contended:
            throw ProjectMemoryError.lockContended
        case .cancelled:
            throw ProjectMemoryError.cancelled
        }
    }

    private struct MemoryDocument: Codable {
        let version: Int
        var records: [ProjectMemoryRecord]

        init(records: [ProjectMemoryRecord]) {
            version = 1
            self.records = records
        }
    }

    private static func readRecords(at path: FilePath) throws -> [ProjectMemoryRecord] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
            let document = try JSONDecoder().decode(MemoryDocument.self, from: data)
            guard document.version == 1 else {
                throw ProjectMemoryError.unsupportedVersion(document.version)
            }
            return document.records
        } catch let error as ProjectMemoryError {
            throw error
        } catch {
            throw ProjectMemoryError.malformedFile(path: path.string)
        }
    }

    private static func encoded(_ records: [ProjectMemoryRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(MemoryDocument(records: records))
    }

    /// One gate for every user/model-supplied field written to memory.
    ///
    /// Redaction.diagnostic is the same process-wide registry and pattern
    /// definition used by diagnostics, tool failures, and session-facing errors.
    /// A changed result is rejected rather than writing a scrubbed approximation:
    /// memory must never become a second place where a secret-shaped value can
    /// persist in disguise.
    private static func requireSafe(_ value: String, field: String) throws {
        guard Redaction.diagnostic(value) == value else {
            throw ProjectMemoryError.secretDetected(field: field)
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func workspaceKey(for cwd: String) -> String {
        // FNV-1a is used only as a stable opaque directory key. The full path is
        // not stored in the memory filename, and a collision merely makes two
        // workspaces share a bounded, redaction-gated file rather than exposing
        // the path or corrupting a session.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in cwd.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public enum ProjectMemoryError: Error, Sendable, Equatable {
    case emptyTitle
    case emptyContent
    case secretDetected(field: String)
    case recordTooLarge(limit: Int)
    case byteBudgetExceeded(limit: Int, required: Int)
    case malformedFile(path: String)
    case unsupportedVersion(Int)
    case lockContended
    case cancelled
}
