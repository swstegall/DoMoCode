// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import Foundation
import SystemPackage
import Testing

@Suite("Workflow store", .serialized)
struct WorkflowStoreTests {
    @Test("definitions and run snapshots append and recover latest state")
    func appendAndRecover() throws {
        let directory = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-workflows-\(UUID().uuidString)", isDirectory: true)
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: directory.string) }

        let store = try WorkflowStore.create(
            directory: directory,
            now: { "2026-01-01T00:00:00Z" }
        )
        let definition = WorkflowDefinition(
            id: "workflow-1",
            stages: [WorkflowStageDefinition(id: "ask", kind: .ask)]
        )
        try store.append(definition: definition)

        var pending = WorkflowRunRecord(
            id: "run-1",
            workflowID: definition.id,
            createdAt: "2026-01-01T00:00:00Z",
            stageIDs: ["ask"]
        )
        try store.append(run: pending)
        #expect(try store.records().count == 2)

        let updated = pending.updateStage(
            "ask",
            status: .succeeded,
            timestamp: "2026-01-01T00:01:00Z",
            output: "answer"
        )
        #expect(updated)
        pending.status = .succeeded
        pending.output = "answer"
        pending.updatedAt = "2026-01-01T00:01:00Z"
        try store.append(run: pending)

        #expect(try store.definition(withID: "workflow-1") == definition)
        #expect(try store.latestRun(withID: "run-1") == pending)
        #expect(try store.latestRuns().map(\.id) == ["run-1"])
        #expect(try store.records().count == 3)
    }
}
