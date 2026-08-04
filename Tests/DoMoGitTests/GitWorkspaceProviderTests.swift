// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
@testable import DoMoGit
import Foundation
import SystemPackage
import Testing

@Suite("Git workspace provider", .serialized)
struct GitWorkspaceProviderTests {
    @Test("allocates an isolated worktree, checkpoints it, and promotes explicitly")
    func worktreeLifecycle() async throws {
        let fixture = try await GitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

        let provider = try GitWorkspaceProvider(
            repositoryRoot: fixture.repository,
            worktreeRoot: fixture.worktrees,
            rootSessionID: "root-session",
            git: fixture.git
        )
        guard let base = try await fixture.git.head(at: fixture.repository) else {
            Issue.record("fixture repository did not produce a base revision")
            return
        }
        let lease = try await provider.allocate(WorkspaceLeaseRequest(
            id: "child-lease",
            sessionID: "child-session",
            parentSessionID: "root-session",
            displayName: "Fix parser",
            rootPath: fixture.worktrees.appending("child").string,
            baseRevision: base,
            setupScript: "printf child > child.txt"
        ))

        #expect(lease.branchName.hasPrefix("domo/fix-parser-"))
        let diff = try await provider.diff(lease)
        #expect(diff.changedPaths == ["child.txt"])
        let checkpoint = try await provider.checkpoint(lease)
        #expect(!checkpoint.id.isEmpty)
        #expect(checkpoint.leaseID == lease.id)

        let promoted = try await provider.promote(WorkspacePromotionRequest(
            leaseID: lease.id,
            targetSessionID: "root-session",
            expectedBaseRevision: base,
            approved: true
        ))
        #expect(promoted.status == .promoted)
        #expect(FileManager.default.fileExists(
            atPath: fixture.repository.appending("child.txt").string
        ))

        try await provider.cleanup(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.rootPath))
        let branches = try await fixture.git.runGit(
            ["branch", "--list", lease.branchName],
            at: fixture.repository
        )
        #expect(branches.isSuccess)
        #expect(branches.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("refuses roots outside the provider and reports a dirty promotion target")
    func failsClosedAndReportsConflict() async throws {
        let fixture = try await GitWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let provider = try GitWorkspaceProvider(
            repositoryRoot: fixture.repository,
            worktreeRoot: fixture.worktrees,
            rootSessionID: "root-session",
            git: fixture.git
        )

        await #expect(throws: GitWorkspaceProviderError.invalidRoot("/tmp/not-owned")) {
            _ = try await provider.allocate(WorkspaceLeaseRequest(
                id: "outside",
                sessionID: "outside-session",
                displayName: "Outside",
                rootPath: "/tmp/not-owned"
            ))
        }

        guard let base = try await fixture.git.head(at: fixture.repository) else {
            Issue.record("fixture repository did not produce a base revision")
            return
        }
        let lease = try await provider.allocate(WorkspaceLeaseRequest(
            id: "dirty-target",
            sessionID: "dirty-session",
            displayName: "Dirty target",
            rootPath: fixture.worktrees.appending("dirty").string,
            baseRevision: base,
            setupScript: "printf child > child.txt"
        ))
        try Data("parent change\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repository.appending("parent.txt").string)
        )
        let result = try await provider.promote(WorkspacePromotionRequest(
            leaseID: lease.id,
            targetSessionID: "root-session",
            expectedBaseRevision: base,
            approved: true
        ))
        #expect(result.status == .conflicted)
        #expect(result.conflictingPaths == ["parent.txt"])
        try await provider.cleanup(lease)
    }
}

private struct GitWorkspaceFixture: Sendable {
    let baseURL: URL
    let repository: FilePath
    let worktrees: FilePath
    let git: DoMoGit

    init() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-git-provider-\(UUID().uuidString)")
        let repositoryURL = baseURL.appendingPathComponent("repository")
        let worktreesURL = baseURL.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreesURL, withIntermediateDirectories: true)

        let shell = try SubprocessShell()
        let repository = FilePath(repositoryURL.path)
        let git = DoMoGit(shell: shell)
        let initialized = try await shell.run(ShellRequest(
            "git init --quiet",
            workingDirectory: repository
        ))
        guard initialized.isSuccess else {
            throw FixtureError.command(initialized.stderr.text)
        }
        try Data("base\n".utf8).write(to: repositoryURL.appendingPathComponent("README.md"))
        let committed = try await shell.run(ShellRequest(
            "git config user.name DoMoCode && git config user.email domocode@localhost && git add -- README.md && git commit --quiet -m base",
            workingDirectory: repository
        ))
        guard committed.isSuccess else {
            throw FixtureError.command(committed.stderr.text)
        }
        self.baseURL = baseURL
        self.repository = repository
        self.worktrees = FilePath(worktreesURL.path)
        self.git = git
    }
}

private enum FixtureError: Error {
    case command(String)
}
