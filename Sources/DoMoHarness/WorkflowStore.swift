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
        Self.replayLatestRun(from: try records(), runID: id)
    }

    public func latestRuns() throws -> [WorkflowRunRecord] {
        var latest: [String: WorkflowRunRecord] = [:]
        for record in try records() where record.kind == .runSnapshot {
            if let run = record.run { latest[run.id] = run }
        }
        return latest.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Returns the complete ordered history needed to archive or replay one run.
    /// All definition revisions for the workflow are retained, followed by every
    /// snapshot for the requested run. The original JSONL order is preserved.
    public func exportRecords(
        workflowID: String,
        runID: String
    ) throws -> [WorkflowStoreRecord] {
        Self.exportRecords(
            from: try records(),
            workflowID: workflowID,
            runID: runID
        )
    }

    /// Reconstructs the latest run state from an exported record sequence. This
    /// is intentionally pure: importing an archive never writes to the live
    /// store or starts an executor.
    public static func replayLatestRun(
        from records: [WorkflowStoreRecord],
        workflowID: String? = nil,
        runID: String
    ) -> WorkflowRunRecord? {
        var result: WorkflowRunRecord?
        for record in records where record.kind == .runSnapshot && record.id == runID {
            guard let run = record.run,
                  workflowID == nil || run.workflowID == workflowID
            else { continue }
            result = run
        }
        return result
    }

    /// Selects export records without touching the filesystem. Keeping this as a
    /// value operation lets import/export callers validate a downloaded archive
    /// before handing it to a store.
    public static func exportRecords(
        from records: [WorkflowStoreRecord],
        workflowID: String,
        runID: String
    ) -> [WorkflowStoreRecord] {
        records.filter { record in
            switch record.kind {
            case .definition:
                return record.id == workflowID
            case .runSnapshot:
                return record.run?.workflowID == workflowID && record.run?.id == runID
            }
        }
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
