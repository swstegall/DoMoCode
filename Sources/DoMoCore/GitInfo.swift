// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

/// The branch of a git working directory, read straight off `.git/HEAD`.
///
/// This is a deliberate stopgap sized for exactly one caller — the status footer,
/// which repaints on every keystroke and cannot afford to fork `git rev-parse`
/// for a string that is two small file reads away. There is no subprocess here
/// and no new dependency; that is the whole point.
///
/// Phase 12's `DoMoGit` facade subsumes it. Anything that needs git's object
/// model — status, diff, staging, remotes, resolving `HEAD` through the ref
/// packfile — belongs there, not here. Do not grow this type into the facade:
/// two half-facades that disagree about what "the current branch" means is worse
/// than the one that does not exist yet.
///
/// Every path through this type fails to `nil`. A footer must never be the reason
/// a session dies, so "not a repository", "unreadable", and "a HEAD shape we do
/// not recognise" all come back the same way: nothing to show.
public enum GitInfo {

    /// The branch name for `directory`, or `nil` when it is not inside a
    /// repository (or the repository's HEAD cannot be understood).
    ///
    /// Discovery walks *up* from `directory`, so the footer still names the branch
    /// when the process was started in a subdirectory of the checkout. It stops at
    /// the first `.git` — the same rule git itself uses, so a checkout nested
    /// inside another checkout reports the inner branch rather than the outer one.
    ///
    /// A symbolic HEAD (`ref: refs/heads/feature/foo`) yields the name whole,
    /// slashes included. A detached HEAD yields the abbreviated object name
    /// prefixed with `@`, so a footer never shows a bare hex run that reads like
    /// somebody's branch name.
    public static func branch(forWorkingDirectory directory: String) -> String? {
        guard let gitDirectory = repositoryDirectory(startingAt: directory) else { return nil }
        return branchName(inGitDirectory: gitDirectory)
    }
}

// MARK: - Discovery

extension GitInfo {

    /// How far up the tree discovery walks before giving up.
    ///
    /// A real checkout is a handful of components below the root, so this bound is
    /// never reached in practice. It exists because `directory` can come from
    /// configuration or from a model-supplied string: without it, a pathological
    /// path costs an unbounded number of `stat(2)` calls on every repaint.
    private static let maximumAncestorDepth = 128

    /// What sits at a candidate `.git` path.
    ///
    /// `missing` and `file` must stay distinguishable: `missing` means keep
    /// walking, `file` means we have found the repository and any further failure
    /// is this repository's failure, not a reason to inspect the parent's.
    private enum DotGitKind {
        case missing
        case directory
        case file
    }

    /// The directory holding `HEAD` for the repository governing `directory`.
    private static func repositoryDirectory(startingAt directory: String) -> FilePath? {
        // An empty string is not "the current directory" here. Treating it as one
        // would make a misconfigured working directory silently report whatever
        // repository the process happens to have been launched from.
        guard !directory.isEmpty else { return nil }

        var current = FilePath(directory)
        if current.isRelative {
            // Resolve against the process cwd so "walks up to the filesystem root"
            // is true of a relative argument too; otherwise the walk would stop at
            // whatever prefix the caller happened to pass in.
            current = FilePath(FileManager.default.currentDirectoryPath).appending(current.string)
        }
        // Collapsing `.` and `..` up front is what makes "walk up" mean walk up:
        // `removeLastComponent()` on `/a/b/..` would otherwise strip the `..` and
        // walk *down* into `/a/b`. The collapse is lexical, so a `..` that crosses
        // a symlink resolves differently from `cd` — the cost of that is a footer
        // with no branch on it, which is why it is not worth a stat(2) per level.
        current.lexicallyNormalize()

        for _ in 0..<maximumAncestorDepth {
            let dotGit = current.appending(".git")
            switch kind(of: dotGit) {
            case .directory:
                return dotGit
            case .file:
                // A linked worktree or a submodule: `.git` is a pointer file. A
                // broken pointer means "no branch", not "keep looking upward" —
                // reporting the parent repository's branch for a worktree whose
                // gitdir has been deleted would be a confident lie.
                return gitDirectory(fromPointerFileAt: dotGit, relativeTo: current)
            case .missing:
                // False at the filesystem root, which is where the walk ends.
                guard current.removeLastComponent() else { return nil }
            }
        }
        return nil
    }

    private static func kind(of path: FilePath) -> DotGitKind {
        // `fileExists(atPath:)` first, because `resourceValues` throws for both
        // "absent" and "present but unreadable" and would collapse the two cases
        // this walk depends on telling apart. The single-argument spelling is also
        // the one without an `UnsafeMutablePointer` out-parameter, which is what
        // `.strictMemorySafety()` is switched on to catch (same reasoning as
        // `SubprocessShell.validate(workingDirectory:)`).
        guard FileManager.default.fileExists(atPath: path.string) else { return .missing }
        let isDirectory = try? URL(fileURLWithPath: path.string)
            .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        return isDirectory == true ? .directory : .file
    }

    /// Git writes `gitdir: <path>` into the `.git` file of a linked worktree or a
    /// submodule. The path may be absolute or relative to the directory holding
    /// the `.git` file, and git tolerates the space after the colon being absent,
    /// so this parser does too.
    private static func gitDirectory(
        fromPointerFileAt path: FilePath,
        relativeTo base: FilePath
    ) -> FilePath? {
        guard let text = readSmallFile(at: path) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(gitdirPrefix) else { return nil }
        let target = trimmed.dropFirst(gitdirPrefix.count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        let resolved = FilePath(target)
        // Deliberately not normalized: `../store/modules/sub` is handed to the
        // kernel with its `..` intact, which resolves it through symlinks the way
        // `cd` would rather than the way string arithmetic would.
        return resolved.isRelative ? base.appending(target) : resolved
    }

    private static let gitdirPrefix = "gitdir:"
}

// MARK: - HEAD

extension GitInfo {

    /// The one symbolic form worth understanding. HEAD can be pointed outside
    /// `refs/heads` — `git symbolic-ref` will do it — and that is not a branch;
    /// answering `nil` beats printing `refs/remotes/origin/main` into a footer
    /// that has room for a word.
    private static let symbolicHeadPrefix = "ref: refs/heads/"

    /// How much of a detached HEAD's object name is shown. Seven is git's
    /// traditional short-sha width, so the footer reads like the shas the user
    /// already sees in `git log --oneline`.
    private static let abbreviatedObjectNameLength = 7

    private static func branchName(inGitDirectory gitDirectory: FilePath) -> String? {
        guard let text = readSmallFile(at: gitDirectory.appending("HEAD")) else { return nil }
        return branchName(fromHead: text)
    }

    private static func branchName(fromHead contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix(symbolicHeadPrefix) {
            // A branch name may itself contain slashes, so strip the known prefix
            // rather than splitting on "/" and taking the last piece: that would
            // report `feature/foo` as `foo` and make two branches indistinguishable.
            let name = String(trimmed.dropFirst(symbolicHeadPrefix.count))
            return name.isEmpty ? nil : name
        }

        guard isObjectName(trimmed) else { return nil }
        return "@" + String(trimmed.prefix(abbreviatedObjectNameLength))
    }

    /// A raw object name: 40 hex digits for a sha1 repository, 64 for a sha256
    /// one. Requiring the exact length and ASCII-only digits is what keeps a
    /// truncated or half-written HEAD from being abbreviated into a plausible
    /// looking commit that does not exist.
    private static func isObjectName(_ text: String) -> Bool {
        guard text.count == 40 || text.count == 64 else { return false }
        return text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

// MARK: - Reading

extension GitInfo {

    /// The read ceiling for a candidate file.
    ///
    /// `HEAD` is about 41 bytes and a `.git` pointer file is one path. The cap is
    /// what stops a directory that merely happens to contain a large file named
    /// `.git` from pulling megabytes through a footer repaint.
    private static let maximumFileBytes = 4096

    private static func readSmallFile(at path: FilePath) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path.string)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes) else { return nil }
        // Decoding with replacement rather than failing: a HEAD with one stray byte
        // at the end still has a perfectly good ref on the front of it.
        return String(decoding: data, as: UTF8.self)
    }
}
