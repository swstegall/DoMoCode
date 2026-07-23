// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

/// Confines filesystem access to a subtree, by realpath rather than by text.
///
/// The whole reason this type exists is that the obvious implementation is
/// wrong. `FilePath.lexicallyNormalized()` collapses `.` and `..` *as text*,
/// with no reference to the disk, so `/repo/link/../../etc/passwd` normalizes to
/// `/etc/passwd` — and if `link` is a symlink to `/var`, the kernel would have
/// gone to `/etc/passwd` anyway, but by a completely different route. Worse, the
/// clean-looking `/repo/link/secrets` needs no `..` at all: nothing about that
/// string says it leaves `/repo`, and lexical checks pass it.
///
/// So containment is decided only against a path that has been resolved through
/// every symlink — ``FileSystem/canonicalPath(_:allowingMissingComponents:)`` — and it
/// is decided on **every** access, not once at open time. A sandbox that
/// canonicalizes a directory handle and then trusts subsequent joins against it
/// is checking a path that no longer exists.
///
/// ## What this cannot do
///
/// Between the moment a path is resolved and the moment the syscall runs, another
/// process can replace a component with a symlink. Closing that window entirely
/// needs `openat(2)` walked component by component with `O_NOFOLLOW`, holding
/// descriptors rather than paths — which swift-system does not expose portably
/// and which `.strictMemorySafety()` would make ugly. What is done instead:
///
/// - resolution happens immediately before the operation, inside the same call,
///   so the window is a few microseconds rather than the lifetime of a tool call;
/// - mutations re-verify containment *after* the write
///   (``SandboxedFileSystem``), so a lost race becomes a loud error instead of a
///   silent escape;
/// - deletes never follow a symlink leaf, so unlinking a link inside the root can
///   never reach through it;
/// - ``FileMutationCoordinator`` serializes the agent's own concurrent writes,
///   which removes the only racer this process controls.
///
/// The residual risk is an *external* process actively racing the agent. That is
/// worth stating plainly rather than implying it is handled.
public struct PathSandbox: Sendable, Hashable {

    /// The canonical root. Every accepted path is this path or below it.
    public let root: FilePath

    /// Builds a sandbox for an existing directory.
    ///
    /// The root is canonicalized once here — on macOS `/tmp` is a symlink to
    /// `/private/tmp`, so a sandbox rooted at an uncanonicalized `/tmp` rejects
    /// every path inside itself.
    @concurrent
    public static func rooted(
        at root: FilePath,
        using fileSystem: some FileSystem
    ) async throws(DoMoError) -> PathSandbox {
        PathSandbox(canonicalRoot: try await fileSystem.canonicalPath(root))
    }

    /// Wraps a root that the caller has already canonicalized.
    ///
    /// Unchecked on purpose, for tests and for callers that canonicalized as part
    /// of some larger resolution. Passing an uncanonicalized path here does not
    /// fail — it silently narrows the sandbox to a subtree nothing resolves into.
    public init(canonicalRoot: FilePath) {
        self.root = canonicalRoot
    }

    /// Whether an *already canonical* path is the root or inside it.
    ///
    /// `FilePath.starts(with:)` compares components, which is what makes this
    /// correct: a `hasPrefix` on the strings would accept `/repo-backup` for a
    /// root of `/repo`.
    public func contains(_ canonicalPath: FilePath) -> Bool {
        canonicalPath == root || canonicalPath.starts(with: root)
    }

    // MARK: Resolution

    /// Resolves a path that must already exist, and rejects it if it leaves the
    /// root.
    @concurrent
    public func resolve(
        _ path: FilePath,
        using fileSystem: some FileSystem
    ) async throws(DoMoError) -> FilePath {
        let canonical = try await fileSystem.canonicalPath(path, allowingMissingComponents: false)
        return try checking(canonical, requested: path)
    }

    /// Resolves a path that is about to be written, where the leaf may not exist
    /// yet.
    ///
    /// An existing symlink leaf *is* followed, because the write will follow it:
    /// a link inside the root pointing at `/etc/passwd` must be rejected, not
    /// accepted on the strength of where the link itself lives.
    @concurrent
    public func resolveForWrite(
        _ path: FilePath,
        using fileSystem: some FileSystem
    ) async throws(DoMoError) -> FilePath {
        let canonical = try await fileSystem.canonicalPath(path, allowingMissingComponents: true)
        return try checking(canonical, requested: path)
    }

    /// Resolves a path that is about to be unlinked, leaving the leaf unresolved.
    ///
    /// The inverse of ``resolveForWrite(_:using:)``, for the same reason: `unlink`
    /// removes the link, not its target, so canonicalizing the leaf here would
    /// delete the wrong file — and would refuse to delete a dangling or
    /// outward-pointing link that is legitimately inside the root.
    @concurrent
    public func resolveForRemoval(
        _ path: FilePath,
        using fileSystem: some FileSystem
    ) async throws(DoMoError) -> FilePath {
        let absolute = fileSystem.absolutePath(path)
        guard let leaf = absolute.lastComponent, leaf.string != ".", leaf.string != ".." else {
            // Nothing to hold back: `.` and `..` are not symlinks, so full
            // resolution is both safe and the only way to name what they mean.
            return try await resolve(path, using: fileSystem)
        }
        var parent = absolute
        parent.removeLastComponent()
        let canonicalParent = try await fileSystem.canonicalPath(parent, allowingMissingComponents: true)
        let canonical = canonicalParent.appending(leaf)
        return try checking(canonical, requested: path)
    }

    /// The containment test itself, separated so the failure reads the same
    /// wherever it comes from.
    public func checking(_ canonicalPath: FilePath, requested: FilePath) throws(DoMoError) -> FilePath {
        guard contains(canonicalPath) else {
            throw DoMoError(
                .file(path: requested, errno: nil),
                "\(requested) resolves to \(canonicalPath), which is outside \(root)"
            )
        }
        return canonicalPath
    }
}

// MARK: - Sandboxed filesystem

/// A ``FileSystem`` that resolves and prefix-checks on every single call.
///
/// The wrapper shape is the point. A sandbox exposed as a helper the caller is
/// expected to remember to invoke is a sandbox with a hole in it — the one tool
/// that forgets is the one that matters. Here the only reachable API is the
/// checked one.
public struct SandboxedFileSystem: FileSystem {

    public let base: any FileSystem
    public let sandbox: PathSandbox

    public init(base: any FileSystem, sandbox: PathSandbox) {
        self.base = base
        self.sandbox = sandbox
    }

    /// Builds a filesystem confined to `root`, canonicalizing the root and
    /// pointing the working directory at it so relative paths land inside.
    @concurrent
    public static func rooted(
        at root: FilePath,
        using base: some FileSystem
    ) async throws(DoMoError) -> SandboxedFileSystem {
        let sandbox = try await PathSandbox.rooted(at: root, using: base)
        return SandboxedFileSystem(base: base, sandbox: sandbox)
    }

    public var workingDirectory: FilePath { sandbox.root }

    /// Lexical only, and therefore *not* a containment guarantee — it is the same
    /// operation the base filesystem performs, exposed because callers need to
    /// turn user input into an absolute path before anything else. Every method
    /// that touches the disk re-resolves.
    public func absolutePath(_ path: FilePath) -> FilePath {
        let absolute = path.isRelative ? sandbox.root.pushing(path) : path
        return absolute.lexicallyNormalized()
    }

    public func canonicalPath(
        _ path: FilePath,
        allowingMissingComponents: Bool
    ) async throws(DoMoError) -> FilePath {
        allowingMissingComponents
            ? try await sandbox.resolveForWrite(rebased(path), using: base)
            : try await sandbox.resolve(rebased(path), using: base)
    }

    // MARK: Reads

    public func read(_ path: FilePath) async throws(DoMoError) -> Data {
        try await base.read(try await sandbox.resolve(rebased(path), using: base))
    }

    public func readPrefix(_ path: FilePath, maximumBytes: Int) async throws(DoMoError) -> Data {
        try await base.readPrefix(
            try await sandbox.resolve(rebased(path), using: base),
            maximumBytes: maximumBytes
        )
    }

    public func exists(_ path: FilePath) async throws(DoMoError) -> Bool {
        // A path whose parent is missing is "does not exist", not "escaped": the
        // resolution failure and the answer are the same fact.
        let resolved: FilePath
        do {
            resolved = try await sandbox.resolveForWrite(rebased(path), using: base)
        } catch let error {
            guard case .file(_, let errno) = error.kind,
                errno == .noSuchFileOrDirectory || errno == .notDirectory
            else { throw error }
            return false
        }
        return try await base.exists(resolved)
    }

    public func metadata(_ path: FilePath) async throws(DoMoError) -> FileMetadata {
        // Removal semantics, not read semantics: `metadata` is an `lstat`, so a
        // symlink leaf must survive to be reported as `.symlink`.
        try await base.metadata(try await sandbox.resolveForRemoval(rebased(path), using: base))
    }

    public func list(_ path: FilePath) async throws(DoMoError) -> [FileMetadata] {
        try await base.list(try await sandbox.resolve(rebased(path), using: base))
    }

    // MARK: Mutations

    public func write(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        let resolved = try await sandbox.resolveForWrite(rebased(path), using: base)
        try await base.write(resolved, contents)
        try await verifyStillContained(resolved, requested: path)
    }

    public func append(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        let resolved = try await sandbox.resolveForWrite(rebased(path), using: base)
        try await base.append(resolved, contents)
        try await verifyStillContained(resolved, requested: path)
    }

    public func createDirectory(_ path: FilePath, recursive: Bool) async throws(DoMoError) {
        let resolved = try await sandbox.resolveForWrite(rebased(path), using: base)
        try await base.createDirectory(resolved, recursive: recursive)
        try await verifyStillContained(resolved, requested: path)
    }

    public func delete(
        _ path: FilePath,
        recursive: Bool,
        force: Bool
    ) async throws(DoMoError) {
        let resolved: FilePath
        do {
            resolved = try await sandbox.resolveForRemoval(rebased(path), using: base)
        } catch let error {
            guard force, case .file(_, let errno) = error.kind,
                errno == .noSuchFileOrDirectory || errno == .notDirectory
            else { throw error }
            return
        }
        try await base.delete(resolved, recursive: recursive, force: force)
    }

    // MARK: Internals

    /// Re-anchors a relative path onto the sandbox root rather than the base
    /// filesystem's working directory, which may be somewhere else entirely.
    private func rebased(_ path: FilePath) -> FilePath {
        path.isRelative ? sandbox.root.pushing(path) : path
    }

    /// Post-write containment check.
    ///
    /// This cannot prevent a race, only report one: if a component was swapped
    /// for an outward symlink between the resolve and the write, the bytes are
    /// already gone. Failing loudly is still worth the syscall — a silent escape
    /// is discovered by whoever reads the file that got clobbered, which may be
    /// nobody.
    private func verifyStillContained(
        _ resolved: FilePath,
        requested: FilePath
    ) async throws(DoMoError) {
        let recanonicalized = try await base.canonicalPath(resolved, allowingMissingComponents: true)
        _ = try sandbox.checking(recanonicalized, requested: requested)
    }
}
