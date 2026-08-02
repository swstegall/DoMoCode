// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - Fixtures

/// The fixtures are written by hand rather than by shelling out to `git`. That is
/// the point of the type under test — it never runs git — and it keeps the suite
/// hermetic on a machine where git is absent, ancient, or configured with a
/// `init.defaultBranch` nobody predicted.
private func makeTemporaryDirectory() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gitinfo-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

private func makeDirectory(_ path: FilePath) throws {
    try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
}

private func write(_ text: String, to path: FilePath) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path.string))
}

/// A `.git` directory holding exactly one file: `HEAD`.
private func makeRepository(head: String, at directory: FilePath) throws {
    let gitDirectory = directory.appending(".git")
    try makeDirectory(gitDirectory)
    try write(head, to: gitDirectory.appending("HEAD"))
}

// MARK: - Symbolic HEAD

@Suite("GitInfo: a checkout on a branch")
struct GitInfoBranchTests {

    @Test("A plain .git/HEAD yields the branch name")
    func simpleBranch() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/main\n", at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "main")
    }

    @Test("A branch name containing slashes comes back whole")
    func slashedBranch() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/feature/phase-5a/footer\n", at: root)

        // Splitting on "/" and taking the last component would report "footer",
        // which is a different branch entirely.
        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "feature/phase-5a/footer")
    }

    @Test(
        "Trailing and leading whitespace around the ref is tolerated",
        arguments: [
            "ref: refs/heads/main",
            "ref: refs/heads/main\n",
            "ref: refs/heads/main\r\n",
            "ref: refs/heads/main   \n",
            "ref: refs/heads/main\n\n",
            "  ref: refs/heads/main\n",
        ]
    )
    func whitespaceVariants(head: String) throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: head, at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "main")
    }

    @Test("A trailing separator on the working directory does not defeat discovery")
    func trailingSeparatorOnInput() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/main\n", at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string + "/") == "main")
    }
}

// MARK: - Detached HEAD

@Suite("GitInfo: a detached HEAD")
struct GitInfoDetachedHeadTests {

    @Test("A sha1 object name is abbreviated to seven characters behind an @")
    func detachedSha1() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "0123456789abcdef0123456789abcdef01234567\n", at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "@0123456")
    }

    @Test("A sha256 object name is abbreviated the same way")
    func detachedSha256() throws {
        let root = try makeTemporaryDirectory()
        let objectName = String(repeating: "ab7f", count: 16)  // 64 hex digits
        try makeRepository(head: objectName + "\n", at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "@ab7fab7")
    }

    @Test(
        "A hex run of the wrong length is not an object name",
        arguments: [
            String(repeating: "a", count: 39),
            String(repeating: "a", count: 41),
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 7),
        ]
    )
    func nearMissObjectNames(head: String) throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: head + "\n", at: root)

        // A half-written HEAD must not be abbreviated into a plausible-looking
        // commit that never existed.
        #expect(GitInfo.branch(forWorkingDirectory: root.string) == nil)
    }
}

// MARK: - Worktrees and submodules

@Suite("GitInfo: a .git pointer file")
struct GitInfoPointerFileTests {

    @Test("An absolute gitdir: path is followed")
    func absoluteGitdir() throws {
        let root = try makeTemporaryDirectory()
        let store = root.appending("store/worktrees/wt")
        try makeDirectory(store)
        try write("ref: refs/heads/worktree-branch\n", to: store.appending("HEAD"))

        let work = root.appending("work")
        try makeDirectory(work)
        try write("gitdir: \(store.string)\n", to: work.appending(".git"))

        #expect(GitInfo.branch(forWorkingDirectory: work.string) == "worktree-branch")
    }

    @Test("A relative gitdir: path is resolved against the directory holding .git")
    func relativeGitdir() throws {
        let root = try makeTemporaryDirectory()
        let store = root.appending("store/modules/sub")
        try makeDirectory(store)
        try write("ref: refs/heads/submodule-branch\n", to: store.appending("HEAD"))

        let work = root.appending("work")
        try makeDirectory(work)
        try write("gitdir: ../store/modules/sub\n", to: work.appending(".git"))

        // Resolved against `work`, not against the process working directory —
        // which is what `git submodule` actually writes.
        #expect(GitInfo.branch(forWorkingDirectory: work.string) == "submodule-branch")
    }

    @Test("The space after gitdir: is optional")
    func gitdirWithoutSpace() throws {
        let root = try makeTemporaryDirectory()
        let store = root.appending("store")
        try makeDirectory(store)
        try write("ref: refs/heads/tight\n", to: store.appending("HEAD"))

        let work = root.appending("work")
        try makeDirectory(work)
        try write("gitdir:\(store.string)\n", to: work.appending(".git"))

        #expect(GitInfo.branch(forWorkingDirectory: work.string) == "tight")
    }

    @Test("A pointer file without the gitdir: key yields nil")
    func unrecognisedPointerFile() throws {
        let root = try makeTemporaryDirectory()
        let store = root.appending("store")
        try makeDirectory(store)
        try write("ref: refs/heads/reachable\n", to: store.appending("HEAD"))

        let work = root.appending("work")
        try makeDirectory(work)
        // A bare path with no key. The target is a perfectly good git directory,
        // so an implementation that treats the whole file as a path would answer
        // "reachable" here — which is why the target is real rather than junk.
        try write("\(store.string)\n", to: work.appending(".git"))

        #expect(GitInfo.branch(forWorkingDirectory: work.string) == nil)
    }

    @Test("A pointer file naming a directory with no HEAD yields nil")
    func pointerToHeadlessGitDirectory() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/outer\n", at: root)
        let store = root.appending("store")
        try makeDirectory(store)

        let work = root.appending("work")
        try makeDirectory(work)
        try write("gitdir: \(store.string)\n", to: work.appending(".git"))

        // `root` is a real checkout, so resuming the upward walk after the pointer
        // fails would answer "outer" instead of nil.
        #expect(GitInfo.branch(forWorkingDirectory: work.string) == nil)
    }

    @Test("A broken pointer file does not fall through to the enclosing repository")
    func brokenPointerDoesNotReportTheParentBranch() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/outer\n", at: root)

        let work = root.appending("work")
        try makeDirectory(work)
        try write("gitdir: \(root.appending("gone").string)\n", to: work.appending(".git"))

        // The enclosing checkout is real and reachable, so returning "outer" here
        // is the failure this asserts against: a worktree whose gitdir was deleted
        // has no branch, and saying "outer" would be a confident lie.
        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "outer")
        #expect(GitInfo.branch(forWorkingDirectory: work.string) == nil)
    }
}

// MARK: - Discovery

@Suite("GitInfo: finding the repository")
struct GitInfoDiscoveryTests {

    @Test("A nested subdirectory finds the enclosing repository")
    func discoveryFromSubdirectory() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/main\n", at: root)
        let nested = root.appending("Sources/DoMoCore/deep")
        try makeDirectory(nested)

        #expect(GitInfo.branch(forWorkingDirectory: nested.string) == "main")
    }

    @Test("The walk stops at the innermost repository")
    func innermostRepositoryWins() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/outer\n", at: root)

        let inner = root.appending("vendor/inner")
        try makeDirectory(inner)
        try makeRepository(head: "ref: refs/heads/inner\n", at: inner)
        let deep = inner.appending("src")
        try makeDirectory(deep)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "outer")
        #expect(GitInfo.branch(forWorkingDirectory: deep.string) == "inner")
    }

    @Test("The upward walk is bounded")
    func walkDepthIsCapped() throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: "ref: refs/heads/capped\n", at: root)

        var deep = root
        for _ in 0..<200 { deep = deep.appending("d") }
        try makeDirectory(deep)

        // The same repository is found from the top, so the nil below is the bound
        // doing its job rather than a broken fixture.
        #expect(GitInfo.branch(forWorkingDirectory: root.string) == "capped")
        #expect(GitInfo.branch(forWorkingDirectory: deep.string) == nil)
    }
}

// MARK: - Refusals

@Suite("GitInfo: nothing to show")
struct GitInfoRefusalTests {

    @Test("A directory that is not in a repository yields nil")
    func notARepository() throws {
        let root = try makeTemporaryDirectory()
        let repository = root.appending("repo")
        try makeDirectory(repository)
        try makeRepository(head: "ref: refs/heads/main\n", at: repository)
        let plain = root.appending("plain")
        try makeDirectory(plain)

        #expect(GitInfo.branch(forWorkingDirectory: repository.string) == "main")
        #expect(GitInfo.branch(forWorkingDirectory: plain.string) == nil)
    }

    @Test("A .git directory with no HEAD yields nil")
    func gitDirectoryWithoutHead() throws {
        let root = try makeTemporaryDirectory()
        try makeDirectory(root.appending(".git"))

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == nil)
    }

    @Test("A directory that does not exist yields nil")
    func missingDirectory() throws {
        let root = try makeTemporaryDirectory()

        #expect(GitInfo.branch(forWorkingDirectory: root.appending("nope/nope").string) == nil)
    }

    @Test("An empty working directory string yields nil rather than the process cwd")
    func emptyWorkingDirectory() {
        // Run from inside the checkout — the normal case — a fallback to the
        // process working directory would return this repository's branch, and
        // this assertion is what catches it.
        #expect(GitInfo.branch(forWorkingDirectory: "") == nil)
    }

    @Test(
        "An unrecognised HEAD yields nil",
        arguments: [
            "",
            "\n",
            "   \n\n",
            "garbage\n",
            "ref: refs/heads/\n",
            "ref: refs/remotes/origin/main\n",
            "ref: refs/tags/v1.0.0\n",
            "refs/heads/main\n",
        ]
    )
    func unrecognisedHead(head: String) throws {
        let root = try makeTemporaryDirectory()
        try makeRepository(head: head, at: root)

        #expect(GitInfo.branch(forWorkingDirectory: root.string) == nil)
    }
}
