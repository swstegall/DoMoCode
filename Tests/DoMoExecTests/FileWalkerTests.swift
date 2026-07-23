// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage
import Testing

// MARK: - Pattern unit tests

@Suite("Gitignore patterns")
struct GitignorePatternTests {

    private func matches(_ pattern: String, _ path: String, isDirectory: Bool = false) -> Bool {
        guard let compiled = GitignorePattern(line: pattern) else { return false }
        return compiled.matches(path, isDirectory: isDirectory)
    }

    @Test("blank lines and comments compile to nothing")
    func nonPatterns() {
        #expect(GitignorePattern(line: "") == nil)
        #expect(GitignorePattern(line: "   ") == nil)
        #expect(GitignorePattern(line: "# a comment") == nil)
        // An escaped hash is a literal filename, not a comment.
        #expect(GitignorePattern(line: "\\#literal") != nil)
    }

    @Test("an escaped leading `!` is a literal filename, not a negation")
    func escapedBang() {
        // gitignore(5): `\!x` names a file that literally begins with `!`. It
        // must not become a negation of `x` — that would re-include a file an
        // earlier pattern excluded instead of ignoring `!x`.
        let pattern = GitignorePattern(line: "\\!important.txt")
        #expect(pattern?.isNegated == false)
        #expect(matches("\\!important.txt", "!important.txt"))
        #expect(matches("\\!important.txt", "important.txt") == false)

        // And in a file, it produces an *ignore* decision for the literal name.
        let file = GitignoreFile(base: "", contents: "\\!keep.txt\n")
        #expect(file.decision(for: "!keep.txt", isDirectory: false) == true)
        #expect(file.decision(for: "keep.txt", isDirectory: false) == nil)

        // The unescaped forms are untouched: a real negation still negates, and
        // an escaped `#` is still a literal hash name.
        #expect(GitignorePattern(line: "!keep.log")?.isNegated == true)
        #expect(matches("\\#literal", "#literal"))
    }

    @Test("an unanchored name matches at any depth")
    func unanchored() {
        #expect(matches("foo", "foo"))
        #expect(matches("foo", "a/b/foo"))
        #expect(matches("*.log", "deep/nested/x.log"))
    }

    @Test("a pattern with a slash is anchored to the ignore file's directory")
    func anchored() {
        #expect(matches("a/foo", "a/foo"))
        #expect(matches("a/foo", "b/a/foo") == false)
        #expect(matches("/build", "build"))
        #expect(matches("/build", "src/build") == false)
    }

    @Test("a trailing slash restricts a pattern to directories")
    func directoryOnly() {
        #expect(matches("build/", "build", isDirectory: true))
        #expect(matches("build/", "build", isDirectory: false) == false)
        #expect(matches("build", "build", isDirectory: false))
    }

    @Test("`*` does not cross a slash but `**` does")
    func starSemantics() {
        #expect(matches("src/*.ts", "src/a.ts"))
        #expect(matches("src/*.ts", "src/nested/a.ts") == false)
        #expect(matches("src/**/*.ts", "src/a.ts"))
        #expect(matches("src/**/*.ts", "src/nested/deeply/a.ts"))
    }

    @Test("a leading `**/` matches in the current directory and below")
    func leadingDoubleStar() {
        #expect(matches("**/foo", "foo"))
        #expect(matches("**/foo", "a/b/foo"))
    }

    @Test("a trailing `/**` matches everything inside but not the directory itself")
    func trailingDoubleStar() {
        #expect(matches("logs/**", "logs/a.txt"))
        #expect(matches("logs/**", "logs/deep/a.txt"))
        #expect(matches("logs/**", "logs") == false)
    }

    @Test("character classes and ranges match one segment character")
    func characterClasses() {
        #expect(matches("file[0-9].txt", "file3.txt"))
        #expect(matches("file[0-9].txt", "fileA.txt") == false)
        #expect(matches("file[!0-9].txt", "fileA.txt"))
        #expect(matches("?.ts", "a.ts"))
        #expect(matches("?.ts", "ab.ts") == false)
    }

    @Test("trailing whitespace is stripped unless escaped")
    func trailingWhitespace() {
        #expect(matches("foo   ", "foo"))
        // A backslash-escaped trailing space is part of the name.
        let escaped = GitignorePattern(line: "foo\\ ")
        #expect(escaped?.matches("foo ", isDirectory: false) == true)
    }
}

// MARK: - Ignore-file precedence

@Suite("Gitignore file")
struct GitignoreFileTests {

    @Test("within one file the last matching pattern wins, so `!` re-includes")
    func negationWithinFile() {
        let file = GitignoreFile(base: "", contents: "*.log\n!keep.log\n")
        #expect(file.decision(for: "debug.log", isDirectory: false) == true)
        #expect(file.decision(for: "keep.log", isDirectory: false) == false)
        #expect(file.decision(for: "notes.txt", isDirectory: false) == nil)
    }

    @Test("a nested ignore file overrides a parent's decision")
    func nestedPrecedence() {
        var matcher = GitignoreMatcher()
        matcher.push(GitignoreFile(base: "", contents: "*.log\n"))
        matcher.push(GitignoreFile(base: "src", contents: "!important.log\n"))
        #expect(matcher.isIgnored("root.log", isDirectory: false))
        #expect(matcher.isIgnored("src/important.log", isDirectory: false) == false)
        // A file the nested one has no opinion on still falls through to the parent.
        #expect(matcher.isIgnored("src/other.log", isDirectory: false))
    }

    @Test("patterns only apply at or below the directory that declared them")
    func scoping() {
        let file = GitignoreFile(base: "src", contents: "*.tmp\n")
        #expect(file.decision(for: "src/a.tmp", isDirectory: false) == true)
        #expect(file.decision(for: "other/a.tmp", isDirectory: false) == nil)
    }
}

// MARK: - Walk fixtures

/// Builds a tree from `path: contents` pairs — a directory for a `nil` value —
/// and returns the walk root.
private func buildTree(
    _ entries: [(String, String?)],
    in root: FilePath,
    using fs: POSIXFileSystem
) async throws {
    for (relative, contents) in entries {
        let path = root.appending(relative)
        if let contents {
            try await fs.write(path, text: contents)
        } else {
            try await fs.createDirectory(path)
        }
    }
}

private func relativePaths(_ outcome: FileWalker.Outcome) -> Set<String> {
    Set(outcome.entries.map(\.relativePath))
}

// MARK: - Walk behavior

@Suite("FileWalker")
struct FileWalkerTests {

    @Test("returns files recursively, relative to the root")
    func basicWalk() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [("a.txt", "a"), ("sub", nil), ("sub/b.txt", "b"), ("sub/deep", nil),
                 ("sub/deep/c.txt", "c")],
                in: root,
                using: fs
            )
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(outcome) == ["a.txt", "sub/b.txt", "sub/deep/c.txt"])
            #expect(outcome.wasTruncated == false)
        }
    }

    @Test("the default ignores hide .git and node_modules")
    func defaultIgnores() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [("keep.txt", "k"),
                 (".git", nil), (".git/config", "x"),
                 ("node_modules", nil), ("node_modules/lib.js", "y")],
                in: root,
                using: fs
            )
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(outcome) == ["keep.txt"])
        }
    }

    @Test("dotfiles are skipped by default and included on request")
    func hiddenFiles() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree([("visible.txt", "v"), (".env", "secret")], in: root, using: fs)

            let hidden = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(hidden) == ["visible.txt"])

            var options = FileWalker.Options()
            options.includeHidden = true
            let shown = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(relativePaths(shown) == ["visible.txt", ".env"])
        }
    }

    @Test("a root .gitignore is honored, negation included")
    func rootGitignore() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [(".gitignore", "*.log\n!keep.log\n"),
                 ("a.log", "a"), ("keep.log", "k"), ("main.swift", "s")],
                in: root,
                using: fs
            )
            var options = FileWalker.Options()
            options.includeHidden = true
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(relativePaths(outcome) == [".gitignore", "keep.log", "main.swift"])
        }
    }

    @Test("a nested .gitignore takes precedence over the root's")
    func nestedGitignore() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [(".gitignore", "*.log\n"),
                 ("root.log", "r"),
                 ("src", nil), ("src/.gitignore", "!keep.log\n"),
                 ("src/keep.log", "k"), ("src/drop.log", "d")],
                in: root,
                using: fs
            )
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(outcome) == ["src/keep.log"])
        }
    }

    @Test("a directory-only ignore prunes the whole subtree")
    func directoryOnlyIgnore() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [(".gitignore", "build/\n"),
                 ("build", nil), ("build/out.o", "o"), ("build/deep", nil),
                 ("build/deep/x.o", "x"),
                 ("src.txt", "s")],
                in: root,
                using: fs
            )
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(outcome) == ["src.txt"])
        }
    }

    @Test("a `**`-anchored pattern matches across directory levels")
    func doubleStarAnchoring() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [(".gitignore", "**/generated/**\n"),
                 ("a", nil), ("a/generated", nil), ("a/generated/x.ts", "x"),
                 ("a/keep.ts", "k")],
                in: root,
                using: fs
            )
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            #expect(relativePaths(outcome) == ["a/keep.ts"])
        }
    }

    @Test("directories can be included in the results")
    func includeDirectories() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree([("d", nil), ("d/f.txt", "f")], in: root, using: fs)
            var options = FileWalker.Options()
            options.includeDirectories = true
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(relativePaths(outcome) == ["d", "d/f.txt"])
        }
    }

    // MARK: Caps

    @Test("the result cap stops the walk and is reported")
    func resultCap() async throws {
        try await withTemporaryDirectory { root, fs in
            for index in 0..<20 {
                try await fs.write(root.appending("f\(index).txt"), text: "x")
            }
            var options = FileWalker.Options()
            options.maximumResults = 5
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(outcome.entries.count == 5)
            #expect(outcome.reachedResultLimit)
            #expect(outcome.wasTruncated)
        }
    }

    @Test("the depth cap stops descent and is reported")
    func depthCap() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [("top.txt", "t"),
                 ("a", nil), ("a/mid.txt", "m"),
                 ("a/b", nil), ("a/b/deep.txt", "d")],
                in: root,
                using: fs
            )
            var options = FileWalker.Options()
            options.maximumDepth = 1
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(relativePaths(outcome) == ["top.txt", "a/mid.txt"])
            #expect(outcome.reachedDepthLimit)
        }
    }

    @Test("the visit cap bounds work even when few results survive the ignores")
    func visitCap() async throws {
        try await withTemporaryDirectory { root, fs in
            for index in 0..<50 {
                try await fs.write(root.appending("f\(index).log"), text: "x")
            }
            try await fs.write(root.appending(".gitignore"), text: "*.log\n")
            var options = FileWalker.Options()
            options.maximumVisited = 10
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(outcome.reachedVisitLimit)
        }
    }

    // MARK: Symlinks

    @Test("a symlink is listed as a leaf but not descended into by default")
    func symlinksNotFollowed() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree([("real", nil), ("real/x.txt", "x")], in: root, using: fs)
            try makeSymlink(at: root.appending("link"), to: root.appending("real").string)
            let outcome = try await FileWalker(fileSystem: fs).walk(root)
            // The link itself is an entry; its target's contents are not reached,
            // so `link/x.txt` never appears.
            #expect(relativePaths(outcome) == ["real/x.txt", "link"])
        }
    }

    @Test("a symlink loop is detected rather than followed forever")
    func symlinkLoop() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree([("a", nil), ("a/b", nil), ("a/b/keep.txt", "k")], in: root, using: fs)
            // a/b/loop points back at a — a cycle once symlinks are followed.
            try makeSymlink(at: root.appending("a").appending("b").appending("loop"),
                to: root.appending("a").string)

            var options = FileWalker.Options()
            options.followSymlinks = true
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(outcome.entries.contains { $0.relativePath.hasSuffix("keep.txt") })
            #expect(outcome.symlinkCyclesSkipped >= 1)
        }
    }

    @Test("two links to one shared subtree are both walked — not a false cycle")
    func sharedSubtreeIsNotACycle() async throws {
        try await withTemporaryDirectory { root, fs in
            try await buildTree(
                [("shared", nil), ("shared/x.txt", "x"),
                 ("one", nil), ("two", nil)],
                in: root,
                using: fs
            )
            try makeSymlink(at: root.appending("one").appending("s"),
                to: root.appending("shared").string)
            try makeSymlink(at: root.appending("two").appending("s"),
                to: root.appending("shared").string)

            var options = FileWalker.Options()
            options.followSymlinks = true
            let outcome = try await FileWalker(fileSystem: fs, options: options).walk(root)
            #expect(outcome.entries.contains { $0.relativePath == "one/s/x.txt" })
            #expect(outcome.entries.contains { $0.relativePath == "two/s/x.txt" })
            #expect(outcome.symlinkCyclesSkipped == 0)
        }
    }

    @Test("walking a non-directory fails")
    func walkNonDirectory() async throws {
        try await withTemporaryDirectory { root, fs in
            let file = root.appending("f.txt")
            try await fs.write(file, text: "x")
            await #expect(throws: DoMoError.self) {
                _ = try await FileWalker(fileSystem: fs).walk(file)
            }
        }
    }
}
