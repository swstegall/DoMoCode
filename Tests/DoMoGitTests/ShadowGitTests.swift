// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
@testable import DoMoGit
import Foundation
import SystemPackage
import Testing

private final class ScratchDirectory: Sendable {
    let path: FilePath

    init() throws {
        let name = "domogit-tests-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    func appending(_ component: String) -> FilePath {
        path.appending(component)
    }
}

private func write(_ text: String, to path: FilePath) throws {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path.string).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(toFile: path.string, atomically: true, encoding: .utf8)
}

private func read(_ path: FilePath) throws -> String {
    try String(contentsOfFile: path.string, encoding: .utf8)
}

private func runGit(
    _ shell: SubprocessShell,
    in root: FilePath,
    _ arguments: [String]
) async throws {
    let command = (["git"] + arguments).map(DoMoGit.quote).joined(separator: " ")
    let result = try await shell.run(ShellRequest(
        command,
        workingDirectory: root,
        environment: .inherit([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
        ])
    ))
    #expect(result.isSuccess, "git \(arguments.joined(separator: " ")) failed: \(result.stderr.text)")
}

@Suite("Shadow Git snapshots", .serialized)
struct ShadowGitTests {
    @Test("revert planning admits each path at its earliest writer")
    func plannerUsesEarliestWriterAndScopesPaths() {
        let current = WorkspaceSnapshot(id: String(repeating: "c", count: 40), files: ["same", "latest"])
        let target = WorkspaceSnapshot(id: String(repeating: "t", count: 40))
        let intervening = [
            WorkspaceSnapshot(id: String(repeating: "a", count: 40), files: ["first", "same"]),
            WorkspaceSnapshot(id: String(repeating: "b", count: 40), files: ["same", "second"]),
            current,
        ]

        let plan = WorkspaceRevertPlanner.plan(
            current: current,
            target: target,
            intervening: intervening
        )

        #expect(plan.expectedCurrentID == current.id)
        #expect(plan.targetID == target.id)
        #expect(plan.paths == ["first", "same", "second", "latest"])
    }

    @Test("tracks ignored files in a separate shadow repository and restores changed paths")
    func tracksAndRestoresWorkspace() async throws {
        let scratch = try ScratchDirectory()
        let root = scratch.path
        let shell = try SubprocessShell()

        try write("*.ignored\n", to: root.appending(".gitignore"))
        try write("baseline\n", to: root.appending("tracked.txt"))
        try await runGit(shell, in: root, ["init", "--quiet"])
        try await runGit(shell, in: root, ["config", "user.email", "domo-tests@example.invalid"])
        try await runGit(shell, in: root, ["config", "user.name", "DoMo Tests"])
        try await runGit(shell, in: root, ["add", ".gitignore", "tracked.txt"])
        try await runGit(shell, in: root, ["commit", "--quiet", "-m", "baseline"])

        let snapshots = DoMoShadowGit(
            shell: shell,
            workspace: root,
            gitDirectory: scratch.appending("shadow.git")
        )
        #expect(await snapshots.availability() == .restored)

        let baseline = try await snapshots.track(from: nil)
        #expect(baseline.files.isEmpty)

        try write("assistant\n", to: root.appending("tracked.txt"))
        try write("created\n", to: root.appending("created.txt"))
        try write("ignored\n", to: root.appending("notes.ignored"))
        let assistant = try await snapshots.track(from: baseline.id)

        #expect(assistant.files == ["created.txt", "tracked.txt"])
        let plan = WorkspaceRevertPlanner.plan(
            current: assistant,
            target: baseline,
            intervening: [assistant]
        )
        let restored = try await snapshots.restore(plan)

        #expect(restored.status == .restored)
        #expect(restored.restoredPaths == ["created.txt", "tracked.txt"])
        #expect(try read(root.appending("tracked.txt")) == "baseline\n")
        #expect(!FileManager.default.fileExists(atPath: root.appending("created.txt").string))
        #expect(try read(root.appending("notes.ignored")) == "ignored\n")

        try write("assistant again\n", to: root.appending("tracked.txt"))
        let userSnapshot = try await snapshots.track(from: baseline.id)
        try write("manual edit\n", to: root.appending("tracked.txt"))
        let conflictPlan = WorkspaceRevertPlanner.plan(
            current: userSnapshot,
            target: baseline,
            intervening: [userSnapshot]
        )
        let conflict = try await snapshots.restore(conflictPlan)

        #expect(conflict.status == .restored)
        #expect(conflict.skippedPaths == ["tracked.txt"])
        #expect(conflict.failedPaths.isEmpty)
        #expect(try read(root.appending("tracked.txt")) == "manual edit\n")
    }
}
