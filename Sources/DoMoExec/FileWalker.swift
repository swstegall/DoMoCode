// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/skills.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The traversal shape — per-directory ignore files accumulated on the way down,
// the `.gitignore`/`.ignore`/`.fdignore` set, the dotfile and `node_modules`
// skips, and matching directories with a trailing slash — is ported from
// `loadSkillsFromDirInternal` and `addIgnoreRules` in
// `packages/agent/src/harness/skills.ts`. pi delegates the pattern semantics
// themselves to the `ignore` npm package and its `find` tool shells out to `fd`;
// neither has a Swift equivalent, so the matcher below is written against
// gitignore(5) directly.

import DoMoCore
import Foundation
import SystemPackage

// MARK: - Pattern

/// One line of a `.gitignore`.
///
/// Parsing and matching are separated from the walk because the interesting
/// failures are all in here — `!` ordering, `dir/` versus `dir`, whether a
/// pattern is anchored — and a matcher that can only be tested by creating a
/// directory tree does not get tested enough.
public struct GitignorePattern: Sendable, Hashable {

    /// The line this was parsed from, whitespace and `!` included.
    public let source: String

    /// A `!` pattern re-includes what an earlier pattern excluded.
    public let isNegated: Bool

    /// A trailing `/` restricts the pattern to directories. `build/` ignores the
    /// directory `build` and, because the walker then does not descend, its whole
    /// subtree; `build` alone also ignores a *file* named `build`.
    public let isDirectoryOnly: Bool

    /// Whether the pattern is pinned to the directory holding the `.gitignore`.
    ///
    /// gitignore(5): a separator at the beginning or middle of the pattern
    /// anchors it; a pattern with no separator (or only a trailing one) matches
    /// at any depth. This is why `foo` ignores `a/b/foo` but `a/foo` does not.
    public let isAnchored: Bool

    private let segments: [String]

    /// Returns `nil` for a line that matches nothing: blank, or a comment.
    public init?(line: String) {
        var body = Self.strippingTrailingWhitespace(line)
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("#") { return nil }
        // A leading `\#` or `\!` escapes the metacharacter: the line names a file
        // that literally begins with `#` or `!`. Dropping the backslash without
        // also suppressing the negation check below would turn `\!x` into a
        // *negation* of `x` — the opposite of ignoring a file named `!x`, and a
        // way to silently re-include something an earlier pattern excluded.
        var escapedLeading = false
        if body.hasPrefix("\\#") || body.hasPrefix("\\!") {
            escapedLeading = true
            body.removeFirst()
        }

        var negated = false
        if !escapedLeading, body.hasPrefix("!") {
            negated = true
            body.removeFirst()
            guard !body.isEmpty else { return nil }
        }

        var directoryOnly = false
        while body.hasSuffix("/") {
            directoryOnly = true
            body.removeLast()
        }
        guard !body.isEmpty else { return nil }

        var anchored = body.contains("/")
        if body.hasPrefix("/") {
            anchored = true
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        source = line
        isNegated = negated
        isDirectoryOnly = directoryOnly
        isAnchored = anchored
        // An unanchored pattern is exactly an anchored one with `**/` in front,
        // which removes the special case from the matcher entirely.
        segments = anchored ? body.split(separator: "/").map(String.init)
            : ["**"] + body.split(separator: "/").map(String.init)
    }

    /// Whether this pattern matches a path expressed relative to the directory
    /// containing the `.gitignore`.
    public func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
        if isDirectoryOnly && !isDirectory { return false }
        let path = relativePath.split(separator: "/").map(String.init)
        guard !path.isEmpty else { return false }
        return Self.match(segments, path)
    }

    // MARK: Parsing helpers

    /// gitignore(5): trailing spaces are ignored unless escaped with a backslash.
    private static func strippingTrailingWhitespace(_ line: String) -> String {
        var characters = Array(line)
        while let last = characters.last, last == " " || last == "\t" {
            // A backslash before the space keeps it, and an even number of
            // backslashes means the last one is itself escaped.
            var backslashes = 0
            var index = characters.count - 2
            while index >= 0, characters[index] == "\\" {
                backslashes += 1
                index -= 1
            }
            if backslashes % 2 == 1 { break }
            characters.removeLast()
        }
        return String(characters)
    }

    // MARK: Matching

    /// Segment-wise match where `**` spans zero or more whole segments.
    ///
    /// A trailing `**` is the one asymmetry: gitignore(5) says `a/**` matches
    /// *everything inside* `a`, so it must not match `a` itself.
    private static func match(_ pattern: [String], _ path: [String]) -> Bool {
        var memo = Set<Int>()
        func walk(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == path.count }
            let key = p &* (path.count &+ 1) &+ t
            if memo.contains(key) { return false }
            let result: Bool
            if pattern[p] == "**" {
                if p == pattern.count - 1 {
                    result = t < path.count
                } else {
                    var found = false
                    for skip in t...path.count where walk(p + 1, skip) {
                        found = true
                        break
                    }
                    result = found
                }
            } else if t < path.count, matchSegment(Array(pattern[p]), Array(path[t])) {
                result = walk(p + 1, t + 1)
            } else {
                result = false
            }
            if !result { memo.insert(key) }
            return result
        }
        return walk(0, 0)
    }

    /// Glob match inside one path segment: `*`, `?`, `[...]`, and `\` escapes.
    /// None of the wildcards cross a `/`, which is why this only ever sees one
    /// segment at a time.
    private static func matchSegment(_ pattern: [Character], _ text: [Character]) -> Bool {
        var memo = Set<Int>()
        func walk(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == text.count }
            let key = p &* (text.count &+ 1) &+ t
            if memo.contains(key) { return false }
            let result: Bool
            switch pattern[p] {
            case "*":
                var found = false
                for skip in t...text.count where walk(p + 1, skip) {
                    found = true
                    break
                }
                result = found
            case "?":
                result = t < text.count && walk(p + 1, t + 1)
            case "[":
                if let (matched, next) = matchClass(pattern, p, t < text.count ? text[t] : nil) {
                    result = matched && walk(next, t + 1)
                } else {
                    // An unterminated `[` is a literal bracket, as in fnmatch.
                    result = t < text.count && text[t] == "[" && walk(p + 1, t + 1)
                }
            case "\\" where p + 1 < pattern.count:
                result = t < text.count && text[t] == pattern[p + 1] && walk(p + 2, t + 1)
            default:
                result = t < text.count && text[t] == pattern[p] && walk(p + 1, t + 1)
            }
            if !result { memo.insert(key) }
            return result
        }
        return walk(0, 0)
    }

    /// Parses `[...]` starting at `start`, returning whether `character` is in
    /// the class and the pattern index just past the closing `]`. `nil` means the
    /// class never closed.
    private static func matchClass(
        _ pattern: [Character],
        _ start: Int,
        _ character: Character?
    ) -> (Bool, Int)? {
        var index = start + 1
        var negated = false
        if index < pattern.count, pattern[index] == "!" || pattern[index] == "^" {
            negated = true
            index += 1
        }
        // A `]` immediately after the (optional) negation is a literal `]`.
        var members: [ClosedRange<Character>] = []
        var first = true
        while index < pattern.count {
            if pattern[index] == "]" && !first {
                guard let character else { return (negated, index + 1) }
                let contains = members.contains { $0.contains(character) }
                return (contains != negated, index + 1)
            }
            first = false
            var low = pattern[index]
            if low == "\\", index + 1 < pattern.count {
                index += 1
                low = pattern[index]
            }
            if index + 2 < pattern.count, pattern[index + 1] == "-", pattern[index + 2] != "]" {
                var high = pattern[index + 2]
                index += 2
                if high == "\\", index + 1 < pattern.count {
                    index += 1
                    high = pattern[index]
                }
                if low <= high { members.append(low...high) }
            } else {
                members.append(low...low)
            }
            index += 1
        }
        return nil
    }
}

// MARK: - Ignore file

/// The patterns from one ignore file, together with the directory they apply to.
public struct GitignoreFile: Sendable, Hashable {

    /// The directory holding this file, relative to the walk root. `""` for the
    /// root's own ignore file. No leading or trailing slash.
    public let base: String
    public let patterns: [GitignorePattern]

    public init(base: String, patterns: [GitignorePattern]) {
        self.base = base
        self.patterns = patterns
    }

    public init(base: String, contents: String) {
        self.init(
            base: base,
            patterns: contents.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { GitignorePattern(line: String($0).replacingOccurrences(of: "\r", with: "")) }
        )
    }

    /// `true` ignored, `false` explicitly re-included, `nil` no opinion.
    ///
    /// Within one file the **last** matching pattern wins — that is what makes
    /// `!` work at all — so the scan runs backwards and stops at the first hit.
    public func decision(for relativePath: String, isDirectory: Bool) -> Bool? {
        guard let scoped = scoped(relativePath) else { return nil }
        for pattern in patterns.reversed() where pattern.matches(scoped, isDirectory: isDirectory) {
            return !pattern.isNegated
        }
        return nil
    }

    /// Re-expresses a root-relative path relative to ``base``, or `nil` when the
    /// path is not under this file's directory.
    private func scoped(_ relativePath: String) -> String? {
        guard !base.isEmpty else { return relativePath }
        let prefix = base + "/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        return String(relativePath.dropFirst(prefix.count))
    }
}

/// The stack of ignore files in effect at some point in a walk.
public struct GitignoreMatcher: Sendable, Hashable {

    private var files: [GitignoreFile]

    public init(files: [GitignoreFile] = []) {
        self.files = files
    }

    public mutating func push(_ file: GitignoreFile) {
        files.append(file)
    }

    /// Whether a root-relative path is ignored.
    ///
    /// Files are consulted deepest-first, and the first one with an opinion wins:
    /// gitignore(5) gives a nested `.gitignore` precedence over its parents, so a
    /// `!keep.log` in `src/` survives a `*.log` at the root.
    public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        for file in files.reversed() {
            if let decision = file.decision(for: relativePath, isDirectory: isDirectory) {
                return decision
            }
        }
        return false
    }
}

// MARK: - Walker

/// Recursive directory traversal with gitignore semantics, loop protection and
/// hard caps.
///
/// The caps are not defensive decoration. A coding agent points this at whatever
/// directory it was started in, and `$HOME` with a symlink to `/` in it is not a
/// hypothetical; without a bound on depth, entries and cycles, "list the files
/// here" becomes an unkillable traversal of the whole machine.
public struct FileWalker: Sendable {

    /// pi's `IGNORE_FILE_NAMES`, in the order it applies them.
    public static let defaultIgnoreFileNames = [".gitignore", ".ignore", ".fdignore"]

    /// The always-on ignores. pi hardcodes the same two — `node_modules` by name
    /// in its skills walk, and both as `**/node_modules/**` and `**/.git/**` in
    /// `find` — because a walk that descends into either produces tens of
    /// thousands of results nobody wanted.
    public static let defaultIgnorePatterns = ["node_modules/", ".git/"]

    public struct Options: Sendable {

        /// Directory levels below the root. `0` lists only the root's own
        /// entries.
        public var maximumDepth: Int

        /// Entries **returned**. pi's `find` defaults to 1000 results.
        public var maximumResults: Int

        /// Entries **examined**, ignored ones included. Separate from
        /// ``maximumResults`` because a tight `.gitignore` over a huge tree
        /// produces few results and still takes minutes.
        public var maximumVisited: Int

        /// Whether to descend through directory symlinks. Off by default, which
        /// is both git's behavior and the only setting for which cycles are
        /// impossible.
        public var followSymlinks: Bool

        /// Whether dotfiles are returned. pi's walk skips them.
        public var includeHidden: Bool

        /// Whether directories appear in the results, or only their contents.
        public var includeDirectories: Bool

        public var respectIgnoreFiles: Bool
        public var ignoreFileNames: [String]

        /// Patterns applied at the root, before any ignore file.
        public var ignorePatterns: [String]

        public init(
            maximumDepth: Int = 64,
            maximumResults: Int = 1000,
            maximumVisited: Int = 200_000,
            followSymlinks: Bool = false,
            includeHidden: Bool = false,
            includeDirectories: Bool = false,
            respectIgnoreFiles: Bool = true,
            ignoreFileNames: [String] = FileWalker.defaultIgnoreFileNames,
            ignorePatterns: [String] = FileWalker.defaultIgnorePatterns
        ) {
            self.maximumDepth = maximumDepth
            self.maximumResults = maximumResults
            self.maximumVisited = maximumVisited
            self.followSymlinks = followSymlinks
            self.includeHidden = includeHidden
            self.includeDirectories = includeDirectories
            self.respectIgnoreFiles = respectIgnoreFiles
            self.ignoreFileNames = ignoreFileNames
            self.ignorePatterns = ignorePatterns
        }
    }

    /// One returned entry.
    public struct Entry: Sendable, Hashable {
        /// Slash-separated, relative to the walk root, never with a leading `./`.
        public let relativePath: String
        public let metadata: FileMetadata

        public init(relativePath: String, metadata: FileMetadata) {
            self.relativePath = relativePath
            self.metadata = metadata
        }
    }

    /// The result, with every cap that fired reported rather than silently
    /// applied — a truncated listing the model believes is complete is worse
    /// than no listing.
    public struct Outcome: Sendable {
        public let entries: [Entry]
        public let reachedResultLimit: Bool
        public let reachedVisitLimit: Bool
        public let reachedDepthLimit: Bool
        /// Directories skipped because they were already on the current path —
        /// that is, symlink cycles.
        public let symlinkCyclesSkipped: Int

        public var wasTruncated: Bool {
            reachedResultLimit || reachedVisitLimit || reachedDepthLimit
        }
    }

    public let fileSystem: any FileSystem
    public let options: Options

    public init(fileSystem: any FileSystem, options: Options = Options()) {
        self.fileSystem = fileSystem
        self.options = options
    }

    /// One directory's worth of pending state. An explicit stack rather than
    /// recursion so the depth cap is a number rather than a hope about the
    /// native stack.
    private struct Frame {
        let path: FilePath
        let relativePath: String
        let depth: Int
        let matcher: GitignoreMatcher
        /// Identities on the path from the root to here. Membership means a
        /// cycle; a global visited-set would instead prune legitimate diamonds,
        /// where two directories link to one shared subtree.
        let ancestors: Set<FileIdentity>
    }

    @concurrent
    public func walk(_ root: FilePath) async throws(DoMoError) -> Outcome {
        let rootPath = try await fileSystem.canonicalPath(root)
        let rootInfo = try await fileSystem.metadata(rootPath)
        guard rootInfo.kind == .directory else {
            throw DoMoError.file(.notDirectory, path: rootPath, while: "walk")
        }

        var matcher = GitignoreMatcher()
        let seeded = options.ignorePatterns.compactMap { GitignorePattern(line: $0) }
        if !seeded.isEmpty {
            matcher.push(GitignoreFile(base: "", patterns: seeded))
        }

        var entries: [Entry] = []
        var visited = 0
        var reachedResultLimit = false
        var reachedVisitLimit = false
        var reachedDepthLimit = false
        var cyclesSkipped = 0

        var stack = [
            Frame(
                path: rootPath,
                relativePath: "",
                depth: 0,
                matcher: matcher,
                ancestors: rootInfo.identity.map { [$0] } ?? []
            )
        ]

        while let frame = stack.popLast() {
            try checkCancellation()
            if reachedResultLimit || reachedVisitLimit { break }

            var frameMatcher = frame.matcher
            if options.respectIgnoreFiles {
                for name in options.ignoreFileNames {
                    guard let contents = try await ignoreFileContents(frame.path.appending(name))
                    else { continue }
                    frameMatcher.push(GitignoreFile(base: frame.relativePath, contents: contents))
                }
            }

            let children = try await fileSystem.list(frame.path)
            var descend: [Frame] = []

            for child in children {
                try checkCancellation()
                visited += 1
                if visited > options.maximumVisited {
                    reachedVisitLimit = true
                    break
                }

                let name = child.name
                if !options.includeHidden && name.hasPrefix(".") { continue }

                let relativePath =
                    frame.relativePath.isEmpty ? name : "\(frame.relativePath)/\(name)"
                let isDirectory = child.kind == .directory
                if frameMatcher.isIgnored(relativePath, isDirectory: isDirectory) { continue }

                if !isDirectory || options.includeDirectories {
                    guard entries.count < options.maximumResults else {
                        reachedResultLimit = true
                        break
                    }
                    entries.append(Entry(relativePath: relativePath, metadata: child))
                }

                guard let target = try await descendable(child) else { continue }
                guard frame.depth < options.maximumDepth else {
                    reachedDepthLimit = true
                    continue
                }
                if let identity = target.identity, frame.ancestors.contains(identity) {
                    cyclesSkipped += 1
                    continue
                }
                var ancestors = frame.ancestors
                if let identity = target.identity { ancestors.insert(identity) }
                descend.append(
                    Frame(
                        path: target.path,
                        relativePath: relativePath,
                        depth: frame.depth + 1,
                        matcher: frameMatcher,
                        ancestors: ancestors
                    )
                )
            }

            // `list` returns sorted entries and this is a LIFO stack, so children
            // go on in reverse to come off in order.
            stack.append(contentsOf: descend.reversed())
        }

        return Outcome(
            entries: entries,
            reachedResultLimit: reachedResultLimit,
            reachedVisitLimit: reachedVisitLimit,
            reachedDepthLimit: reachedDepthLimit,
            symlinkCyclesSkipped: cyclesSkipped
        )
    }

    // MARK: Internals

    /// The directory to descend into for an entry, or `nil` if there is none.
    ///
    /// A symlink is only followed when asked for, and then it is `stat`ed through
    /// so the identity used for cycle detection is the *target's* — comparing the
    /// link's own inode would never detect anything, since each link in a cycle
    /// has a distinct one.
    private func descendable(_ entry: FileMetadata) async throws(DoMoError) -> FileMetadata? {
        switch entry.kind {
        case .directory:
            return entry
        case .file:
            return nil
        case .symlink:
            guard options.followSymlinks else { return nil }
            guard let target = try? await fileSystem.canonicalPath(entry.path),
                let info = try? await fileSystem.metadata(target),
                info.kind == .directory
            else { return nil }
            return info
        }
    }

    /// An ignore file's text, or `nil` when it is absent or unreadable.
    ///
    /// Unreadable is deliberately not fatal: pi records a diagnostic and carries
    /// on, because one `.gitignore` with a permission problem should not fail a
    /// listing of the tree around it.
    private func ignoreFileContents(_ path: FilePath) async throws(DoMoError) -> String? {
        do {
            guard try await fileSystem.metadata(path).kind == .file else { return nil }
        } catch let error {
            guard case .file = error.kind else { throw error }
            return nil
        }
        guard let bytes = try? await fileSystem.read(path) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func checkCancellation() throws(DoMoError) {
        guard Task.isCancelled else { return }
        throw DoMoError(.cancelled, "walk cancelled")
    }
}
