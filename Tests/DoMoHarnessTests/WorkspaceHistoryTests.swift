// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoGit
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

private actor SnapshotScript: WorkspaceSnapshotSource {
    private let snapshots: [WorkspaceSnapshot]
    private var index = 0
    private var plans: [WorkspaceRevertPlan] = []

    init(_ snapshots: [WorkspaceSnapshot]) {
        self.snapshots = snapshots
    }

    func availability() async -> WorkspaceSnapshotStatus { .restored }

    func track(from previousID: String?) async throws(DoMoError) -> WorkspaceSnapshot {
        guard !snapshots.isEmpty else {
            throw DoMoError(.configuration, "snapshot script is empty")
        }
        let value = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return WorkspaceSnapshot(id: value.id, previousID: previousID, files: value.files)
    }

    func restore(_ plan: WorkspaceRevertPlan) async throws(DoMoError) -> WorkspaceRestoreResult {
        plans.append(plan)
        return WorkspaceRestoreResult(status: .restored, restoredPaths: plan.paths)
    }

    var recordedPlans: [WorkspaceRevertPlan] { plans }
}

private func scriptedStream(_ text: String) -> AgentStreamFn {
    { _ in
        let message = AssistantMessage(
            content: [.text(text)],
            model: "test-model",
            usage: Usage(input: 1, output: 1),
            stopReason: .stop
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.start(AssistantSnapshot(model: message.model)))
            continuation.yield(.done(message))
            continuation.finish()
        }
    }
}

private func makeWorkspaceSessionDirectory() -> FilePath {
    FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-workspace-history-\(UUID().uuidString)")
            .path
    )
}

private func userTexts(_ messages: [Message]) -> [String] {
    messages.compactMap { message in
        guard case .user(let user) = message else { return nil }
        return user.text
    }
}

@Suite("Workspace history")
struct WorkspaceHistoryTests {
    @Test("checkpoint entries make undo and redo move conversation and files together")
    func undoAndRedoMoveBothHistories() async throws {
        let source = SnapshotScript([
            WorkspaceSnapshot(id: "base", files: []),
            WorkspaceSnapshot(id: "one", files: ["Sources/One.swift"]),
            WorkspaceSnapshot(id: "two", files: ["Sources/One.swift", "Sources/Two.swift"]),
        ])
        var configuration = AgentHarness.Configuration(
            model: "test-model",
            streamFn: scriptedStream("answer"),
            compaction: CompactionSettings(enabled: false),
            now: { Date(timeIntervalSince1970: 1_770_000_000) }
        )
        configuration.workspaceSnapshots = source
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeWorkspaceSessionDirectory(),
            configuration: configuration
        )

        _ = try await harness.run(prompt: "first")
        _ = try await harness.run(prompt: "second")

        let beforeUndo = try await harness.timeline()
        #expect(beforeUndo.filter {
            if case .workspaceCheckpoint = $0.payload { return true }
            return false
        }.count == 3)
        #expect(userTexts(try await harness.contextMessages()) == ["first", "second"])

        let undo = try await harness.undo()
        #expect(undo.moved)
        #expect(undo.status == .restored)
        #expect(undo.restoredPaths == ["Sources/One.swift", "Sources/Two.swift"])
        #expect(userTexts(try await harness.contextMessages()) == ["first"])
        #expect((await source.recordedPlans).last?.paths == ["Sources/One.swift", "Sources/Two.swift"])

        let redo = try await harness.redo()
        #expect(redo.moved)
        #expect(redo.status == .restored)
        #expect(userTexts(try await harness.contextMessages()) == ["first", "second"])
        let timeline = try await harness.timeline()
        guard case .historyAction(let action) = timeline.last?.payload else {
            Issue.record("expected a durable redo action")
            return
        }
        #expect(action.operation == .redo)
        #expect(action.skippedPaths.isEmpty)
    }

    @Test("a conversation-only turn still gets its own checkpoint and is undoable")
    func unchangedWorkspaceStillMovesConversation() async throws {
        let source = SnapshotScript([
            WorkspaceSnapshot(id: "same", files: []),
            WorkspaceSnapshot(id: "same", files: []),
        ])
        var configuration = AgentHarness.Configuration(
            model: "test-model",
            streamFn: scriptedStream("answer"),
            compaction: CompactionSettings(enabled: false)
        )
        configuration.workspaceSnapshots = source
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeWorkspaceSessionDirectory(),
            configuration: configuration
        )

        _ = try await harness.run(prompt: "only turn")
        let result = try await harness.undo()

        #expect(result.moved)
        #expect(result.restoredPaths.isEmpty)
        #expect((try await harness.contextMessages()).isEmpty)
    }

    @Test("workspace history payloads round-trip without entering model context")
    func payloadsRoundTrip() throws {
        let checkpoint = SessionTreeEntry(
            id: "checkpoint-entry",
            parentId: nil,
            timestamp: "2026-08-03T12:00:00.000Z",
            payload: .workspaceCheckpoint(WorkspaceSnapshot(
                id: String(repeating: "a", count: 40),
                previousID: nil,
                files: ["a.swift"]
            ))
        )
        let action = SessionTreeEntry(
            id: "history-entry",
            parentId: checkpoint.id,
            timestamp: "2026-08-03T12:00:01.000Z",
            payload: .historyAction(SessionHistoryAction(
                operation: .undo,
                fromEntryID: checkpoint.id,
                targetEntryID: checkpoint.id,
                fromSnapshotID: String(repeating: "b", count: 40),
                targetSnapshotID: String(repeating: "a", count: 40),
                paths: ["a.swift"],
                restoredPaths: ["a.swift"],
                status: .restored
            ))
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SessionTreeEntry.self, from: encoder.encode(checkpoint)) == checkpoint)
        #expect(try decoder.decode(SessionTreeEntry.self, from: encoder.encode(action)) == action)
        #expect(action.leafIdAfterEntry == checkpoint.id)
        #expect(ContextBuilder.messages(for: [checkpoint, action]).isEmpty)
    }

    @Test("without a source undo truthfully reports snapshots-disabled")
    func disabledHistoryDoesNotClaimRestore() async throws {
        let configuration = AgentHarness.Configuration(
            model: "test-model",
            streamFn: scriptedStream("answer"),
            compaction: CompactionSettings(enabled: false)
        )
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: makeWorkspaceSessionDirectory(),
            configuration: configuration
        )

        let result = try await harness.undo()
        #expect(!result.moved)
        #expect(result.status == .snapshotsDisabled)
        #expect(await harness.workspaceStatus() == .snapshotsDisabled)
    }
}
