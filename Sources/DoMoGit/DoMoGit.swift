// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// The repository boundary used by Phase 12 surfaces.
///
/// Git is intentionally reached through ``Shell`` rather than through a second
/// subprocess implementation. That gives the facade one command policy in
/// production and lets tests assert the exact invocation without creating a
/// repository or depending on the developer's Git configuration.
public struct DoMoGit: Sendable {
    public let shell: any Shell

    /// Creates a facade over an injected command runner.
    public init(shell: any Shell) {
        self.shell = shell
    }

    /// Creates the production facade using the package's standard shell.
    public init() throws(DoMoError) {
        self.shell = try SubprocessShell()
    }

    /// Returns the commit at `HEAD`, or `nil` when `cwd` is not a repository or
    /// the repository has no commits yet.
    ///
    /// A missing start HEAD is not an error for session creation: the session can
    /// still run, it simply cannot later describe a Git diff from its beginning.
    public func head(at cwd: FilePath) async throws(DoMoError) -> String? {
        let result = try await runGit(["rev-parse", "--verify", "HEAD"], at: cwd)
        guard !result.timedOut else {
            throw DoMoError(.toolExecution(tool: "git"), "git rev-parse HEAD timed out")
        }
        guard result.exitCode != 0 else {
            let value = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        // `rev-parse --verify HEAD` uses status 128 both for a directory outside
        // a repository and for an unborn HEAD. Both mean that a session has no
        // usable checkpoint. Other failures (a killed process, for example) are
        // surfaced so the caller does not silently record a false baseline.
        if result.exitCode == 128 {
            return nil
        }
        throw Self.commandFailure(result, summary: "git rev-parse HEAD")
    }

    /// Returns the current branch and the files Git considers changed.
    public func status(at cwd: FilePath) async throws(DoMoError) -> GitStatus {
        let result = try await runGit(
            ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--"],
            at: cwd
        )
        guard result.isSuccess, !result.stdout.isTruncated else {
            throw Self.commandFailure(result, summary: "git status")
        }
        return GitStatusParser.parse(result.stdout.bytes)
    }

    /// Returns the working-tree diff from base, including untracked files.
    ///
    /// Tracked changes come from one git diff invocation. Untracked files are
    /// added with --no-index; Git returns status 1 for that intentional
    /// difference, which is accepted, while every other failure is surfaced.
    public func diff(
        from base: String,
        at cwd: FilePath,
        includeUntracked: Bool = true
    ) async throws(DoMoError) -> GitDiff {
        try Self.validateReference(base)
        let status = try await status(at: cwd)
        let tracked = try await runGit(
            [
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--unified=3",
                base,
                "--",
            ],
            at: cwd
        )
        guard tracked.isSuccess, !tracked.stdout.isTruncated else {
            throw Self.commandFailure(tracked, summary: "git diff \(base)")
        }

        var patch = tracked.stdout.text
        if includeUntracked {
            for file in status.files where file.kind == .untracked {
                let untracked = try await runGit(
                    [
                        "diff",
                        "--no-index",
                        "--no-color",
                        "--no-ext-diff",
                        "--unified=3",
                        "--",
                        "/dev/null",
                        file.path,
                    ],
                    at: cwd
                )
                guard (untracked.exitCode == 0 || untracked.exitCode == 1),
                      !untracked.stdout.isTruncated
                else {
                    throw Self.commandFailure(untracked, summary: "git diff \(file.path)")
                }
                if !untracked.stdout.text.isEmpty {
                    if !patch.isEmpty, !patch.hasSuffix("\n") { patch.append("\n") }
                    patch.append(untracked.stdout.text)
                }
            }
        }

        return GitDiff(
            base: base,
            branch: status.branch,
            files: GitDiffParser.parse(
                patch,
                status: Self.statusForDiff(status, includeUntracked: includeUntracked)
            ),
            patch: patch
        )
    }

    /// Returns the current working-tree diff, using HEAD when one exists.
    /// An empty repository still reports untracked files with a nil base.
    public func workingTreeDiff(
        at cwd: FilePath,
        includeUntracked: Bool = true
    ) async throws(DoMoError) -> GitDiff {
        let status = try await status(at: cwd)
        guard let base = try await head(at: cwd) else {
            var patch = ""
            if includeUntracked {
                for file in status.files where file.kind == .untracked {
                    let result = try await runGit(
                        [
                            "diff",
                            "--no-index",
                            "--no-color",
                            "--no-ext-diff",
                            "--unified=3",
                            "--",
                            "/dev/null",
                            file.path,
                        ],
                        at: cwd
                    )
                    guard result.exitCode == 0 || result.exitCode == 1 else {
                        throw Self.commandFailure(result, summary: "git diff \(file.path)")
                    }
                    if !result.stdout.text.isEmpty {
                        if !patch.isEmpty, !patch.hasSuffix("\n") { patch.append("\n") }
                        patch.append(result.stdout.text)
                    }
                }
            }
            return GitDiff(
                base: nil,
                branch: status.branch,
                files: GitDiffParser.parse(
                    patch,
                    status: Self.statusForDiff(status, includeUntracked: includeUntracked)
                ),
                patch: patch
            )
        }
        return try await diff(from: base, at: cwd, includeUntracked: includeUntracked)
    }

    /// Reverts one changed path to base. The path is always after Git's --
    /// separator and is restricted to the repository-relative workspace so a
    /// caller cannot turn the review action into an arbitrary filesystem write.
    public func restore(path: String, from base: String, at cwd: FilePath) async throws(DoMoError) {
        try Self.validateReference(base)
        try Self.validateRelativePath(path)
        let status = try await status(at: cwd)
        guard let file = status.files.first(where: { $0.path == path }) else { return }
        let result: ShellResult
        if file.kind == .untracked {
            result = try await runGit(["clean", "-f", "--", path], at: cwd)
        } else {
            result = try await runGit(
                ["restore", "--source", base, "--staged", "--worktree", "--", path],
                at: cwd
            )
        }
        guard result.isSuccess else {
            throw Self.commandFailure(result, summary: "git restore \(path)")
        }
    }

    /// Runs a Git subcommand with the repository policy applied consistently.
    ///
    /// The current shell seam accepts a command string, so every argument is
    /// single-quoted with POSIX-safe handling. Callers must still place `--`
    /// before path lists; this helper does not turn a path into an option.
    func runGit(_ arguments: [String], at cwd: FilePath) async throws(DoMoError) -> ShellResult {
        let command = ([
            "git",
            "--no-optional-locks",
            "-c",
            "core.quotepath=false",
        ] + arguments).map(Self.quote).joined(separator: " ")
        let request = ShellRequest(
            command,
            workingDirectory: cwd,
            environment: .inherit([
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "LC_ALL": "C",
            ]),
            timeout: .seconds(30),
            limits: ShellOutputLimits(head: 256 * 1024, tail: 256 * 1024)
        )
        return try await shell.run(request)
    }

    /// Shell-quotes one argument without allowing its contents to become shell
    /// syntax. The empty string is quoted too, because an omitted argument is a
    /// different Git request from an empty one.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validateReference(_ reference: String) throws(DoMoError) {
        guard !reference.isEmpty,
              !reference.hasPrefix("-"),
              !reference.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw DoMoError(.configuration, "Invalid Git revision: \(reference)")
        }
    }

    private static func statusForDiff(_ status: GitStatus, includeUntracked: Bool) -> GitStatus {
        guard !includeUntracked else { return status }
        return GitStatus(
            branch: status.branch,
            ahead: status.ahead,
            behind: status.behind,
            files: status.files.filter { $0.kind != .untracked }
        )
    }

    private static func validateRelativePath(_ path: String) throws(DoMoError) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !components.contains("..")
        else {
            throw DoMoError(.configuration, "Invalid repository-relative path: \(path)")
        }
    }

    private static func commandFailure(_ result: ShellResult, summary: String) -> DoMoError {
        let code = result.exitCode.map(String.init) ?? "signal \(result.signal.map(String.init) ?? "unknown")"
        let detail = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return DoMoError(
            .toolExecution(tool: "git"),
            "\(summary) failed with \(code)\(suffix)"
        )
    }
}

/// The source boundary for review surfaces.
///
/// Git is the first implementation, but the client/server review protocol should
/// not need to know whether a future source is a shadow repository, a worktree, or
/// another local history. Keeping the checkpoint, diff, and restore operations
/// together also prevents a caller from accidentally asking one source for a base
/// and another source to restore it.
public protocol DiffSource: Sendable {
    func head(at cwd: FilePath) async throws(DoMoError) -> String?
    func diff(from base: String, at cwd: FilePath, includeUntracked: Bool) async throws(DoMoError) -> GitDiff
    func workingTreeDiff(at cwd: FilePath, includeUntracked: Bool) async throws(DoMoError) -> GitDiff
    func restore(path: String, from base: String, at cwd: FilePath) async throws(DoMoError)
}

extension DoMoGit: DiffSource {}

// MARK: - Public Git value types

public struct GitFileStatus: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case conflicted
        case untracked
        case ignored
        case unknown
    }

    public let path: String
    public let oldPath: String?
    public let indexStatus: String
    public let workTreeStatus: String
    public let kind: Kind

    public init(
        path: String,
        oldPath: String? = nil,
        indexStatus: String = " ",
        workTreeStatus: String = " ",
        kind: Kind
    ) {
        self.path = path
        self.oldPath = oldPath
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.kind = kind
    }
}

public struct GitStatus: Sendable, Hashable, Codable {
    public let branch: String?
    public let ahead: Int?
    public let behind: Int?
    public let files: [GitFileStatus]

    public init(
        branch: String?,
        ahead: Int? = nil,
        behind: Int? = nil,
        files: [GitFileStatus] = []
    ) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public var isDirty: Bool { !files.isEmpty }
}

public enum GitDiffLineKind: String, Sendable, Hashable, Codable {
    case context
    case addition
    case deletion
    case metadata
}

public struct GitDiffLine: Sendable, Hashable, Codable {
    public let kind: GitDiffLineKind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?

    public init(kind: GitDiffLineKind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

public struct GitDiffHunk: Sendable, Hashable, Codable {
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [GitDiffLine]

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [GitDiffLine]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    public var additions: Int { lines.count(where: { $0.kind == .addition }) }
    public var deletions: Int { lines.count(where: { $0.kind == .deletion }) }
}

public struct GitDiffFile: Sendable, Hashable, Codable {
    public let path: String
    public let oldPath: String?
    public let status: GitFileStatus.Kind
    public let hunks: [GitDiffHunk]
    public let binary: Bool

    public init(
        path: String,
        oldPath: String? = nil,
        status: GitFileStatus.Kind = .modified,
        hunks: [GitDiffHunk] = [],
        binary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.hunks = hunks
        self.binary = binary
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
}

public struct GitDiff: Sendable, Hashable, Codable {
    public let base: String?
    public let branch: String?
    public let files: [GitDiffFile]
    public let patch: String

    public init(base: String?, branch: String?, files: [GitDiffFile], patch: String) {
        self.base = base
        self.branch = branch
        self.files = files
        self.patch = patch
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}
