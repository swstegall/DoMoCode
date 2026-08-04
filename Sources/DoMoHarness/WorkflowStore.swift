// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

/// Append-only persistence for workflow definitions and run snapshots.
///
/// Definitions are replaced logically by a later row with the same id, while
/// run snapshots are replaced logically by a later row with the same run id.
/// Earlier rows remain available for export and replay, and a crash can only
/// damage the final JSONL row.
public struct WorkflowStore: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    private let now: @Sendable () -> String

    public init(
        path: FilePath,
        permissions: FilePermissions = .ownerReadWrite,
        now: @escaping @Sendable () -> String = { WorkflowStore.timestamp() }
    ) {
        self.path = path
        self.permissions = permissions
        self.now = now
    }

    /// Creates the parent directory and an empty store when absent.
    public static func create(
        directory: FilePath,
        fileName: String = "workflows.jsonl",
        permissions: FilePermissions = .ownerReadWrite,
        now: @escaping @Sendable () -> String = { timestamp() }
    ) throws -> WorkflowStore {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let store = WorkflowStore(
            path: directory.appending(fileName),
            permissions: permissions,
            now: now
        )
        if !FileManager.default.fileExists(atPath: store.path.string) {
            try JSONLinesFileWriter(path: store.path, permissions: permissions)
                .replaceContents(with: [WorkflowStoreRecord]())
        }
        return store
    }

    public func append(definition: WorkflowDefinition) throws {
        try writer.append(WorkflowStoreRecord(definition: definition, timestamp: now()))
    }

    public func append(run: WorkflowRunRecord) throws {
        try writer.append(WorkflowStoreRecord(run: run, timestamp: now()))
    }

    /// Reads strictly: a workflow store is an explicit durable control record,
    /// so silently dropping a malformed row could resume the wrong stage.
    public func records() throws -> [WorkflowStoreRecord] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        return try JSONLines.decode(
            WorkflowStoreRecord.self,
            contentsOf: path,
            options: .strict
        )
    }

    public func definition(withID id: String) throws -> WorkflowDefinition? {
        var result: WorkflowDefinition?
        for record in try records() where record.kind == .definition && record.id == id {
            result = record.definition
        }
        return result
    }

    public func latestRun(withID id: String) throws -> WorkflowRunRecord? {
        var result: WorkflowRunRecord?
        for record in try records() where record.kind == .runSnapshot && record.id == id {
            result = record.run
        }
        return result
    }

    public func latestRuns() throws -> [WorkflowRunRecord] {
        var latest: [String: WorkflowRunRecord] = [:]
        for record in try records() where record.kind == .runSnapshot {
            if let run = record.run { latest[run.id] = run }
        }
        return latest.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    private var writer: JSONLinesFileWriter {
        JSONLinesFileWriter(path: path, permissions: permissions)
    }

    public static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
