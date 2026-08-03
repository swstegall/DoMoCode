// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import SystemPackage
import Testing

@Suite("Replay command")
struct ReplayCommandTests {
    @Test("parses the session, branch point, and JSON options")
    func parsesOptions() throws {
        let command = try ReplayCommand.parse([
            "session.jsonl",
            "--until", "entry-7",
            "--json",
        ])
        #expect(command.sessionPath == "session.jsonl")
        #expect(command.until == "entry-7")
        #expect(command.json)
    }

    @Test("root --replay validates and materializes a resumeable branch")
    func rootReplayValidatesAndMaterializesBranch() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let sessionRoot = FilePath(workspace.root.path).appending("sessions")
        let source = try JSONLSessionStore.create(
            cwd: workspace.workDirectory.path,
            sessionDirectory: sessionRoot,
            sessionID: "source-session",
            now: { Date(timeIntervalSince1970: 1_775_000_000) }
        )
        let userID = try append(
            source,
            payload: .message(.user("read the file")),
            parent: nil
        )
        let call = ToolCallBlock(
            id: "call-1",
            name: "read",
            arguments: .object(["path": .string("notes.txt")])
        )
        let assistantID = try append(
            source,
            payload: .message(.assistant(
                AssistantMessage(
                    content: [.toolCall(call)],
                    model: "m",
                    stopReason: .toolUse
                )
            )),
            parent: userID
        )
        let resultID = try append(
            source,
            payload: .message(.tool(
                ToolResultBlock(toolCallID: "call-1", toolName: "read", output: "saved")
            )),
            parent: assistantID
        )

        let process = try runDomo(
            arguments: [
                "--replay", source.path.string,
                "--until", resultID,
                "--json",
            ],
            workspace: workspace
        )
        #expect(process.exitCode == 0)
        #expect(process.standardError.isEmpty)

        let report = try JSONDecoder().decode(ReplayReport.self, from: Data(process.standardOutput.utf8))
        #expect(report.sourcePath == source.path.string)
        #expect(report.untilEntryID == resultID)
        #expect(report.recordedToolCalls == 1)
        #expect(report.branchPath != source.path.string)
        #expect(FileManager.default.fileExists(atPath: report.branchPath))

        let branch = try JSONLSessionStore.open(path: FilePath(report.branchPath))
        #expect(try branch.readHeader().parentSession == source.path.string)
        #expect(try branch.readEntries().map(\.id) == [userID, assistantID, resultID])
    }

    private func append(
        _ store: JSONLSessionStore,
        payload: SessionTreeEntry.Payload,
        parent: String?
    ) throws -> String {
        let id = store.createEntryID()
        try store.appendEntry(
            SessionTreeEntry(
                id: id,
                parentId: parent,
                timestamp: "2026-08-03T12:00:00.000Z",
                payload: payload
            )
        )
        return id
    }
}
