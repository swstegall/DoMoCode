// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// A local ``WorkspaceProvider`` backed by Git worktrees.
///
/// The provider owns only paths below ``worktreeRoot`` and keeps snapshot
/// object databases outside each worktree. Allocation creates a uniquely named
/// branch and worktree; checkpoint and diff never touch the parent repository;
/// promotion is the only operation that can merge into another registered
/// session, and it is separately gated by ``WorkspacePromotionRequest.approved``.
public actor GitWorkspaceProvider: WorkspaceProvider {
    public let repositoryRoot: FilePath
    public let worktreeRoot: FilePath
    public let rootSessionID: String?
    public let git: DoMoGit

    private struct Record: Sendable {
        var lease: WorkspaceLease
        let snapshotDirectory: FilePath
    }

    private var records: [String: Record] = [:]
    private var sessions: [String: String] = [:]
    private var snapshots: [String: DoMoShadowGit] = [:]

    public init(
        repositoryRoot: FilePath,
        worktreeRoot: FilePath,
        rootSessionID: String? = nil,
        git: DoMoGit
    ) throws(GitWorkspaceProviderError) {
        let repository = try Self.existingDirectory(repositoryRoot)
        let worktrees = try Self.existingDirectory(worktreeRoot)
        guard repository != worktrees,
              !Self.rootsOverlap(repository, worktrees)
        else { throw .invalidRoot(worktreeRoot.string) }
        if let rootSessionID {
            guard Self.isSafeIdentifier(rootSessionID) else {
                throw .invalidSessionID(rootSessionID)
            }
        }
        self.repositoryRoot = FilePath(repository)
        self.worktreeRoot = FilePath(worktrees)
        self.rootSessionID = rootSessionID
        self.git = git
        if let rootSessionID {
            self.sessions[rootSessionID] = repository
        }
    }

    /// Production construction using the package's standard shell runner.
    /// Callers that need Seatbelt/bubblewrap pass a sandboxed ``DoMoGit`` to
    /// the designated initializer so Git and setup scripts share one policy.
    public init(
        repositoryRoot: FilePath,
        worktreeRoot: FilePath,
        rootSessionID: String? = nil
    ) throws(DoMoError) {
        self.repositoryRoot = repositoryRoot
        self.worktreeRoot = worktreeRoot
        self.rootSessionID = rootSessionID
        self.git = try DoMoGit()
        let repository = URL(fileURLWithPath: repositoryRoot.string).standardizedFileURL.path
        let worktrees = URL(fileURLWithPath: worktreeRoot.string).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: repository),
              FileManager.default.fileExists(atPath: worktrees)
        else {
            throw DoMoError(.configuration, "Git workspace roots must already exist")
        }
        guard repository != worktrees,
              !Self.rootsOverlap(repository, worktrees)
        else {
            throw DoMoError(.configuration, "Git worktree root must be separate from the repository")
        }
        if let rootSessionID, !Self.isSafeIdentifier(rootSessionID) {
            throw DoMoError(.configuration, "Invalid root session id")
        }
        if let rootSessionID {
            self.sessions[rootSessionID] = repository
        }
    }

    public func allocate(_ request: WorkspaceLeaseRequest) async throws -> WorkspaceLease {
        guard Self.isSafeIdentifier(request.id) else {
            throw GitWorkspaceProviderError.invalidLeaseID(request.id)
        }
        guard records[request.id] == nil else {
            throw GitWorkspaceProviderError.duplicateLease(request.id)
        }
        guard sessions[request.sessionID] == nil else {
            throw GitWorkspaceProviderError.duplicateSession(request.sessionID)
        }
        let root = try Self.worktreePath(request.rootPath, below: worktreeRoot.string)
        guard !FileManager.default.fileExists(atPath: root) else {
            throw GitWorkspaceProviderError.rootUnavailable(root)
        }
        let base = try await baseRevision(for: request.baseRevision)
        let branch = WorkspaceBranchNaming.branchName(
            sessionID: request.sessionID,
            label: request.displayName
        )
        let add = try await git.runGit(
            ["worktree", "add", "--quiet", "-b", branch, root, base],
            at: repositoryRoot
        )
        guard add.isSuccess else {
            throw Self.commandFailure(add, operation: "git worktree add")
        }

        let lease = WorkspaceLease(
            id: request.id,
            sessionID: request.sessionID,
            parentSessionID: request.parentSessionID,
            rootPath: root,
            branchName: branch,
            baseRevision: base
        )
        do {
            if let setupScript = request.setupScript,
               !setupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let setup = try await git.shell.run(Self.setupRequest(setupScript, root: root))
                guard setup.isSuccess else {
                    throw Self.commandFailure(setup, operation: "workspace setup")
                }
            }
        } catch {
            try? await removeWorktree(root: root, branch: branch)
            if let error = error as? GitWorkspaceProviderError { throw error }
            throw GitWorkspaceProviderError.commandFailed(
                operation: "workspace setup",
                message: Redaction.diagnostic(String(describing: error))
            )
        }

        let snapshotDirectory = FilePath(
            worktreeRoot.appending(".domocode-snapshots").appending(request.id).string
        )
        records[request.id] = Record(lease: lease, snapshotDirectory: snapshotDirectory)
        sessions[request.sessionID] = root
        return lease
    }

    public func checkpoint(_ lease: WorkspaceLease) async throws -> WorkspaceCheckpoint {
        guard var record = records[lease.id] else {
            throw GitWorkspaceProviderError.unknownLease(lease.id)
        }
        guard lease.rootPath == record.lease.rootPath,
              lease.branchName == record.lease.branchName
        else { throw GitWorkspaceProviderError.invalidLeaseState(lease.id) }
        try FileManager.default.createDirectory(
            atPath: record.snapshotDirectory.string,
            withIntermediateDirectories: true
        )
        let source: DoMoShadowGit
        if let existing = snapshots[lease.id] {
            source = existing
        } else {
            source = DoMoShadowGit(
                shell: git.shell,
                workspace: FilePath(record.lease.rootPath),
                gitDirectory: record.snapshotDirectory
            )
            snapshots[lease.id] = source
        }
        let snapshot = try await source.track(from: lease.checkpointID)
        record.lease.checkpointID = snapshot.id
        records[lease.id] = record
        return WorkspaceCheckpoint(
            id: snapshot.id,
            leaseID: lease.id,
            revision: try await git.head(at: FilePath(record.lease.rootPath)),
            createdAt: Self.timestamp(),
            metadata: [
                "changedPaths": .array(snapshot.files.map { .string($0) }),
            ]
        )
    }

    public func diff(_ lease: WorkspaceLease) async throws -> WorkspaceDiffSummary {
        guard let record = records[lease.id], record.lease.rootPath == lease.rootPath else {
            throw GitWorkspaceProviderError.unknownLease(lease.id)
        }
        let diff = try await git.workingTreeDiff(
            at: FilePath(record.lease.rootPath),
            includeUntracked: true
        )
        let hasConflicts = diff.files.contains { $0.status == .conflicted }
        return WorkspaceDiffSummary(
            leaseID: lease.id,
            baseRevision: record.lease.baseRevision,
            changedPaths: diff.files.map(\.path),
            patch: diff.patch.isEmpty ? nil : diff.patch,
            hasConflicts: hasConflicts
        )
    }

    public func promote(_ request: WorkspacePromotionRequest) async throws -> WorkspacePromotionResult {
        guard request.approved else {
            return WorkspacePromotionResult(
                status: .requiresApproval,
                leaseID: request.leaseID,
                message: "Promotion requires explicit approval"
            )
        }
        guard let record = records[request.leaseID] else {
            throw GitWorkspaceProviderError.unknownLease(request.leaseID)
        }
        guard let targetPath = sessions[request.targetSessionID] else {
            return WorkspacePromotionResult(
                status: .rejected,
                leaseID: request.leaseID,
                message: "Promotion target session is not registered"
            )
        }
        let target = FilePath(targetPath)
        let targetStatus = try await git.status(at: target)
        guard targetStatus.files.isEmpty else {
            return WorkspacePromotionResult(
                status: .conflicted,
                leaseID: request.leaseID,
                message: "Promotion target has uncommitted changes",
                conflictingPaths: targetStatus.files.map(\.path)
            )
        }
        let actualBase = try await git.head(at: target)
        if let expected = request.expectedBaseRevision, actualBase != expected {
            return WorkspacePromotionResult(
                status: .conflicted,
                leaseID: request.leaseID,
                message: "Promotion target moved since its expected revision"
            )
        }

        try await commitPendingChanges(for: record.lease)

        let merge = try await git.runGit(
            ["merge", "--no-edit", "--no-ff", record.lease.branchName],
            at: target
        )
        guard merge.isSuccess else {
            let conflicts = (try? await git.status(at: target))?.files.map(\.path) ?? []
            _ = try? await git.runGit(["merge", "--abort"], at: target)
            return WorkspacePromotionResult(
                status: .conflicted,
                leaseID: request.leaseID,
                message: "Git could not promote the workspace",
                conflictingPaths: conflicts
            )
        }
        return WorkspacePromotionResult(
            status: .promoted,
            leaseID: request.leaseID,
            message: "Workspace promoted",
            resultingRevision: try await git.head(at: target)
        )
    }

    public func cleanup(_ lease: WorkspaceLease) async throws {
        guard let record = records[lease.id] else {
            throw GitWorkspaceProviderError.unknownLease(lease.id)
        }
        try await removeWorktree(root: record.lease.rootPath, branch: record.lease.branchName)
        try? FileManager.default.removeItem(atPath: record.snapshotDirectory.string)
        snapshots.removeValue(forKey: lease.id)
        records.removeValue(forKey: lease.id)
        sessions.removeValue(forKey: lease.sessionID)
    }

    private func baseRevision(for requested: String?) async throws -> String {
        let revision: String
        if let requested {
            revision = requested
        } else if let head = try await git.head(at: repositoryRoot) {
            revision = head
        } else {
            throw GitWorkspaceProviderError.noBaseRevision
        }
        guard Self.isSafeRevision(revision) else {
            throw GitWorkspaceProviderError.invalidRevision(revision)
        }
        return revision
    }

    private func removeWorktree(root: String, branch: String) async throws {
        let removed = try await git.runGit(["worktree", "remove", "--force", root], at: repositoryRoot)
        guard removed.isSuccess else {
            throw Self.commandFailure(removed, operation: "git worktree remove")
        }
        let deleted = try await git.runGit(["branch", "-D", branch], at: repositoryRoot)
        guard deleted.isSuccess else {
            throw Self.commandFailure(deleted, operation: "git branch cleanup")
        }
    }

    private static func setupRequest(_ script: String, root: String) -> ShellRequest {
        ShellRequest(
            script,
            workingDirectory: FilePath(root),
            environment: ShellEnvironment.inherit([
                "CI": "1",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "LC_ALL": "C",
            ]).pinnedForSandbox(workspace: FilePath(root)),
            timeout: .seconds(300),
            limits: ShellOutputLimits(head: 64 * 1024, tail: 64 * 1024),
            sandboxRole: .workspaceSetup
        )
    }

    private func commitPendingChanges(for lease: WorkspaceLease) async throws {
        let status = try await git.status(at: FilePath(lease.rootPath))
        guard !status.files.isEmpty else { return }
        let add = try await git.runGit(
            [
                "add", "-A", "--", ".",
                ":(exclude).cache/**",
                ":(exclude).config/**",
                ":(exclude).local/**",
            ],
            at: FilePath(lease.rootPath)
        )
        guard add.isSuccess else {
            throw Self.commandFailure(add, operation: "stage workspace changes")
        }
        let staged = try await git.runGit(
            ["diff", "--cached", "--quiet", "--"],
            at: FilePath(lease.rootPath)
        )
        guard staged.exitCode != 0 else { return }
        let commit = try await git.runGit(
            [
                "-c", "user.name=DoMoCode",
                "-c", "user.email=domocode@localhost",
                "commit", "--quiet", "-m", "DoMoCode workspace promotion",
            ],
            at: FilePath(lease.rootPath)
        )
        guard commit.isSuccess else {
            throw Self.commandFailure(commit, operation: "commit workspace changes")
        }
    }

    private static func existingDirectory(_ path: FilePath) throws(GitWorkspaceProviderError) -> String {
        let normalized = URL(fileURLWithPath: path.string)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let values = try? URL(fileURLWithPath: normalized)
            .resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw .rootUnavailable(normalized)
        }
        return normalized
    }

    private static func worktreePath(_ path: String, below root: String) throws(GitWorkspaceProviderError) -> String {
        guard !path.isEmpty, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw .invalidRoot(path) }
        let normalized = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard normalized != root, normalized.hasPrefix(root + "/") else {
            throw .invalidRoot(path)
        }
        return normalized
    }

    private static func rootsOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5a)
                || (scalar.value >= 0x61 && scalar.value <= 0x7a)
                || scalar.value == 0x2d
                || scalar.value == 0x5f
                || scalar.value == 0x2e
        }
    }

    private static func isSafeRevision(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private static func commandFailure(
        _ result: ShellResult,
        operation: String
    ) -> GitWorkspaceProviderError {
        let code = result.exitCode.map(String.init) ?? "signal \(result.signal.map(String.init) ?? "unknown")"
        let detail = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(
            operation: operation,
            message: Redaction.diagnostic(detail.isEmpty ? "exit \(code)" : "exit \(code): \(detail)")
        )
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public enum GitWorkspaceProviderError: Error, Sendable, Equatable {
    case invalidRoot(String)
    case rootUnavailable(String)
    case invalidSessionID(String)
    case invalidLeaseID(String)
    case duplicateLease(String)
    case duplicateSession(String)
    case unknownLease(String)
    case invalidLeaseState(String)
    case noBaseRevision
    case invalidRevision(String)
    case commandFailed(operation: String, message: String)
}
