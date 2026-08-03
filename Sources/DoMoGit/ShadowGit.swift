// Copyright (c) 2025 opencode. MIT license.
// https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/snapshot/index.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The shadow-index shape and the use of a separate GIT_DIR are derived from
// opencode's MIT-licensed snapshot service. The Swift implementation and its
// conflict-safe restore planner are original to DoMoCode.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

// MARK: - Snapshot vocabulary

/// The status a workspace operation can truthfully report.
public enum WorkspaceSnapshotStatus: String, Sendable, Hashable, Codable {
    /// The requested snapshot operation completed. Individual paths may still
    /// be listed as skipped when a user changed them concurrently.
    case restored
    /// Snapshotting was not configured for this runtime.
    case snapshotsDisabled = "snapshots-disabled"
    /// Snapshotting was configured, but the workspace or shadow repository could
    /// not be used. This must never be presented as a successful restore.
    case unavailable
}

/// One immutable shadow-Git tree observation.
public struct WorkspaceSnapshot: Sendable, Hashable, Codable {
    /// The `write-tree` object id. It is a tree, never a commit or a ref.
    public let id: String
    /// The tree this observation was compared with, when one was available.
    public let previousID: String?
    /// Paths whose content changed between `previousID` and `id`. The list is
    /// intentionally scoped: revert never reads or writes a path outside it.
    public let files: [String]

    public init(id: String, previousID: String? = nil, files: [String] = []) {
        self.id = id
        self.previousID = previousID
        self.files = files
    }
}

/// A conflict-safe file restore plan. It is pure data so it can be tested and
/// reviewed without touching a worktree.
public struct WorkspaceRevertPlan: Sendable, Hashable, Codable {
    /// The tree the worktree must still match before a path is restored.
    public let expectedCurrentID: String
    /// The tree whose path contents should be restored.
    public let targetID: String
    /// The only paths the applier may inspect or mutate, in earliest-writer order.
    public let paths: [String]

    public init(expectedCurrentID: String, targetID: String, paths: [String]) {
        self.expectedCurrentID = expectedCurrentID
        self.targetID = targetID
        self.paths = paths
    }
}

/// The outcome of applying a revert plan.
public struct WorkspaceRestoreResult: Sendable, Hashable, Codable {
    public let status: WorkspaceSnapshotStatus
    public let restoredPaths: [String]
    public let skippedPaths: [String]
    public let failedPaths: [String]

    public init(
        status: WorkspaceSnapshotStatus,
        restoredPaths: [String] = [],
        skippedPaths: [String] = [],
        failedPaths: [String] = []
    ) {
        self.status = status
        self.restoredPaths = restoredPaths
        self.skippedPaths = skippedPaths
        self.failedPaths = failedPaths
    }

    public var isComplete: Bool { status == .restored && failedPaths.isEmpty && skippedPaths.isEmpty }
}

/// The source seam used by the harness and by the server's workspace-status
/// route. A future non-Git source can implement this without changing the
/// append-only session vocabulary.
public protocol WorkspaceSnapshotSource: Sendable {
    func availability() async -> WorkspaceSnapshotStatus
    func track(from previousID: String?) async throws(DoMoError) -> WorkspaceSnapshot
    func restore(_ plan: WorkspaceRevertPlan) async throws(DoMoError) -> WorkspaceRestoreResult
}

/// Pure planner for a range of per-step snapshots.
public enum WorkspaceRevertPlanner {
    /// Builds a plan from the current tree back to `target`.
    ///
    /// `intervening` is ordered oldest-first and contains the snapshots after
    /// `target`, through and including `current`. A path is admitted once, at
    /// its earliest writer. That earliest-writer-wins rule makes the plan stable
    /// when several assistant steps touched the same file and, more importantly,
    /// means a file nobody touched is never even inspected by the applier.
    public static func plan(
        current: WorkspaceSnapshot,
        target: WorkspaceSnapshot,
        intervening: [WorkspaceSnapshot]
    ) -> WorkspaceRevertPlan {
        var seen: Set<String> = []
        var paths: [String] = []
        for snapshot in intervening {
            for path in snapshot.files where seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return WorkspaceRevertPlan(
            expectedCurrentID: current.id,
            targetID: target.id,
            paths: paths
        )
    }
}

// MARK: - Shadow Git

/// A Git index and object database kept outside the user's repository.
///
/// The shadow repository has no commits, branches, or reflog. Each call to
/// ``track(from:)`` stages the visible worktree into its private index and calls
/// `write-tree`; the returned tree id is enough to restore selected paths later.
/// The user's real repository is never used as `GIT_DIR`, and its only role is to
/// answer `check-ignore --no-index` for the exact candidate path set.
public actor DoMoShadowGit: WorkspaceSnapshotSource {
    public let shell: any Shell
    public let workspace: FilePath
    public let gitDirectory: FilePath

    private var initialized = false

    public init(shell: any Shell, workspace: FilePath, gitDirectory: FilePath) {
        self.shell = shell
        self.workspace = workspace
        self.gitDirectory = gitDirectory
    }

    /// Production construction using the package's standard subprocess runner.
    public init(workspace: FilePath, gitDirectory: FilePath) throws(DoMoError) {
        self.shell = try SubprocessShell()
        self.workspace = workspace
        self.gitDirectory = gitDirectory
    }

    public func availability() async -> WorkspaceSnapshotStatus {
        do {
            let result = try await runReal(["rev-parse", "--is-inside-work-tree"])
            guard result.isSuccess, result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return .unavailable
            }
            return .restored
        } catch {
            return .unavailable
        }
    }

    public func track(from previousID: String?) async throws(DoMoError) -> WorkspaceSnapshot {
        try await ensureAvailable()
        try await ensureInitialized()

        let candidates = try await visiblePaths()
        if !candidates.isEmpty {
            let ignored = try await ignoredPaths(candidates)
            if !ignored.isEmpty {
                try await removeFromIndex(ignored)
            }
            let allowed = candidates.filter { !ignored.contains($0) }
            if !allowed.isEmpty {
                try await addToIndex(allowed)
            }
        }

        let tree = try await writeTree()
        let files: [String]
        if let previousID {
            files = try await changedPaths(from: previousID, to: tree)
        } else {
            files = []
        }
        return WorkspaceSnapshot(id: tree, previousID: previousID, files: files)
    }

    public func restore(_ plan: WorkspaceRevertPlan) async throws(DoMoError) -> WorkspaceRestoreResult {
        try await ensureAvailable()
        try await ensureInitialized()
        guard !plan.paths.isEmpty else { return WorkspaceRestoreResult(status: .restored) }

        var restored: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        for path in plan.paths {
            try Self.validateRelativePath(path)
            // The shadow repository intentionally has no commits, so ordinary
            // `status` would report every indexed path as added. `diff-files`
            // compares only the worktree with the private index and therefore
            // detects a concurrent user edit without needing a fake commit.
            let worktreeDiff = try await runShadow(["diff-files", "--name-only", "-z", "--", path])
            guard worktreeDiff.isSuccess else {
                failed.append(path)
                continue
            }
            // A clean path still matches the expected snapshot. Any worktree
            // difference, including a deletion, is a conflict.
            guard worktreeDiff.stdout.text.isEmpty else {
                skipped.append(path)
                continue
            }

            let targetPath = try await runShadow(["ls-tree", "-r", "--name-only", plan.targetID, "--", path])
            guard targetPath.isSuccess else {
                failed.append(path)
                continue
            }
            let existsInTarget = !targetPath.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let result: ShellResult
            if existsInTarget {
                result = try await runShadow(["checkout", "--quiet", plan.targetID, "--", path])
            } else {
                // The current snapshot stages every visible path, so a path
                // absent from the target is normally present in this private
                // index and `git rm` removes exactly that path from the worktree.
                result = try await runShadow(["rm", "-f", "--ignore-unmatch", "--", path])
            }
            if result.isSuccess {
                restored.append(path)
            } else {
                failed.append(path)
            }
        }

        return WorkspaceRestoreResult(
            status: failed.isEmpty ? .restored : .unavailable,
            restoredPaths: restored,
            skippedPaths: skipped,
            failedPaths: failed
        )
    }

    // MARK: Setup and tracking

    private func ensureAvailable() async throws(DoMoError) {
        let result = try await runReal(["rev-parse", "--is-inside-work-tree"])
        guard result.isSuccess, result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw Self.failure(result, summary: "workspace is not a Git worktree")
        }
    }

    private func ensureInitialized() async throws(DoMoError) {
        guard !initialized else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: gitDirectory.string,
                withIntermediateDirectories: true
            )
        } catch {
            throw DoMoError(
                .file(path: gitDirectory, errno: nil),
                "create shadow Git directory",
                cause: error
            )
        }
        // `git init --bare` rejects `--work-tree`; add the work-tree setting
        // immediately after initialization instead.
        let initResult = try await runShadowSetup(["init", "--bare", "--quiet"])
        guard initResult.isSuccess else {
            throw Self.failure(initResult, summary: "initialize shadow Git directory")
        }
        for (key, value) in [
            ("core.bare", "false"),
            ("core.worktree", workspace.string),
            ("core.logallrefupdates", "false"),
            ("core.quotepath", "false"),
            ("index.version", "4"),
        ] {
            let result = try await runShadow(["config", key, value])
            guard result.isSuccess else {
                throw Self.failure(result, summary: "configure shadow Git directory")
            }
        }
        initialized = true
    }

    private func visiblePaths() async throws(DoMoError) -> [String] {
        let real = try await runReal([
            "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"
        ])
        guard real.isSuccess, !real.stdout.isTruncated else {
            throw Self.failure(real, summary: "list workspace files")
        }
        let shadow = try await runShadow(["ls-files", "-z", "--"])
        guard shadow.isSuccess, !shadow.stdout.isTruncated else {
            throw Self.failure(shadow, summary: "list shadow files")
        }
        var seen: Set<String> = []
        var paths: [String] = []
        for path in Self.nulSeparated(real.stdout.bytes) + Self.nulSeparated(shadow.stdout.bytes) {
            guard !path.isEmpty, !isShadowPath(path), seen.insert(path).inserted else { continue }
            try Self.validateRelativePath(path)
            paths.append(path)
        }
        return paths.sorted()
    }

    /// The session data directory normally lives outside the worktree, but
    /// excluding it here makes the source safe for callers that colocate the
    /// shadow repository under the project root (and prevents self-snapshotting).
    private func isShadowPath(_ path: String) -> Bool {
        let root = URL(fileURLWithPath: workspace.string).standardizedFileURL.path
        let shadow = URL(fileURLWithPath: gitDirectory.string).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard shadow.hasPrefix(prefix) else { return false }
        let relative = String(shadow.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !relative.isEmpty && (path == relative || path.hasPrefix(relative + "/"))
    }

    private func ignoredPaths(_ paths: [String]) async throws(DoMoError) -> Set<String> {
        let result = try await runReal(
            ["check-ignore", "--no-index", "--stdin", "-z"],
            input: Self.nulInput(paths)
        )
        guard result.exitCode == 0 || result.exitCode == 1, !result.stdout.isTruncated else {
            throw Self.failure(result, summary: "check workspace ignore rules")
        }
        return Set(Self.nulSeparated(result.stdout.bytes))
    }

    private func addToIndex(_ paths: [String]) async throws(DoMoError) {
        let result = try await runShadow(
            ["add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul"],
            input: Self.nulInput(paths.map { ":(top,literal)\($0)" })
        )
        guard result.isSuccess else {
            throw Self.failure(result, summary: "stage shadow snapshot files")
        }
    }

    private func removeFromIndex(_ paths: Set<String>) async throws(DoMoError) {
        let values = paths.sorted()
        guard !values.isEmpty else { return }
        let result = try await runShadow(
            ["rm", "--cached", "-f", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"],
            input: Self.nulInput(values.map { ":(top,literal)\($0)" })
        )
        guard result.isSuccess else {
            throw Self.failure(result, summary: "remove ignored files from shadow snapshot")
        }
    }

    private func writeTree() async throws(DoMoError) -> String {
        let result = try await runShadow(["write-tree"])
        guard result.isSuccess, !result.stdout.isTruncated else {
            throw Self.failure(result, summary: "write shadow snapshot tree")
        }
        let tree = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else {
            throw DoMoError(.toolExecution(tool: "git"), "shadow Git returned an empty tree id")
        }
        return tree
    }

    private func changedPaths(from: String, to: String) async throws(DoMoError) -> [String] {
        try Self.validateTreeID(from)
        try Self.validateTreeID(to)
        let result = try await runShadow(["diff", "--no-ext-diff", "--name-only", "-z", from, to, "--"])
        guard result.isSuccess, !result.stdout.isTruncated else {
            throw Self.failure(result, summary: "compare shadow snapshots")
        }
        return Self.nulSeparated(result.stdout.bytes).sorted()
    }

    // MARK: Shell boundary

    private func runReal(_ arguments: [String], input: ShellInput = .none) async throws(DoMoError) -> ShellResult {
        try await run(arguments, gitDirectory: nil, input: input)
    }

    private func runShadow(_ arguments: [String], input: ShellInput = .none) async throws(DoMoError) -> ShellResult {
        try await run(arguments, gitDirectory: gitDirectory, includeWorkTree: true, input: input)
    }

    private func runShadowSetup(_ arguments: [String], input: ShellInput = .none) async throws(DoMoError) -> ShellResult {
        try await run(arguments, gitDirectory: gitDirectory, includeWorkTree: false, input: input)
    }

    private func run(
        _ arguments: [String],
        gitDirectory: FilePath?,
        includeWorkTree: Bool = true,
        input: ShellInput
    ) async throws(DoMoError) -> ShellResult {
        var commandArguments = ["git", "--no-optional-locks", "-c", "core.quotepath=false"]
        if let gitDirectory {
            commandArguments += ["--git-dir", gitDirectory.string]
            if includeWorkTree {
                commandArguments += ["--work-tree", workspace.string]
            }
        }
        commandArguments += arguments
        let command = commandArguments.map(DoMoGit.quote).joined(separator: " ")
        return try await shell.run(
            ShellRequest(
                command,
                workingDirectory: workspace,
                environment: .inherit([
                    "GIT_DIR": nil,
                    "GIT_WORK_TREE": nil,
                    "GIT_TERMINAL_PROMPT": "0",
                    "GIT_OPTIONAL_LOCKS": "0",
                    "LC_ALL": "C",
                ]),
                standardInput: input,
                timeout: .seconds(30),
                limits: ShellOutputLimits(head: 4 * 1024 * 1024, tail: 4 * 1024 * 1024)
            )
        )
    }

    private static func nulInput(_ paths: [String]) -> ShellInput {
        .bytes(paths.flatMap { Array($0.utf8) + [0] })
    }

    private static func nulSeparated(_ bytes: [UInt8]) -> [String] {
        String(decoding: bytes, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func validateTreeID(_ id: String) throws(DoMoError) {
        guard id.count == 40, id.allSatisfy({ $0.isHexDigit }) else {
            throw DoMoError(.configuration, "Invalid shadow Git tree id: \(id)")
        }
    }

    private static func validateRelativePath(_ path: String) throws(DoMoError) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !components.contains("..")
        else {
            throw DoMoError(.configuration, "Invalid workspace-relative path: \(path)")
        }
    }

    private static func failure(_ result: ShellResult, summary: String) -> DoMoError {
        let code: String
        if let exitCode = result.exitCode {
            code = String(exitCode)
        } else if let signal = result.signal {
            code = "signal \(signal)"
        } else {
            code = "unknown"
        }
        let detail = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return DoMoError(.toolExecution(tool: "git"), "\(summary) failed with \(code)\(suffix)")
    }
}
