// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/trust-manager.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Trust-requiring project resources

/// Whether `directory` carries project-local resources that must be gated behind
/// project trust before a run may act on them.
///
/// This is pi's `hasTrustRequiringProjectResources`, covering project settings and
/// every prompt resource the Phase 5b loader can inject: system files, ancestor
/// instructions, commands, and skills. These files can change what the agent is
/// told to do or cause a trusted command template to read files and run inline
/// shell, so a repository must not supply them without the user having said "I
/// trust this directory".
///
/// A bare `.domocode` directory (or one holding only a `sessions/` cache) does
/// *not* count, matching pi: trust guards *input* the project would inject, not
/// the mere presence of the config folder. The check is the single gate every
/// such resource passes through.
public func projectRequiresTrust(directory: FilePath) -> Bool {
    func hasResource(_ path: FilePath) -> Bool {
        guard FileManager.default.fileExists(atPath: path.string) else { return false }
        let isDirectory = try? URL(fileURLWithPath: path.string)
            .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        if isDirectory != true { return true }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path.string) else { return false }
        return !entries.isEmpty
    }

    var current = directory
    while true {
        let candidates = [
            current.appending(".domocode").appending("settings.json"),
            current.appending(".domocode").appending("SYSTEM.md"),
            current.appending("SYSTEM.md"),
            current.appending("AGENTS.md"),
            current.appending("CLAUDE.md"),
            current.appending(".domocode").appending("commands"),
            current.appending(".domocode").appending("skills"),
            current.appending(".claude").appending("commands"),
            current.appending(".claude").appending("skills"),
            current.appending(".agents").appending("commands"),
            current.appending(".agents").appending("skills"),
        ]
        if candidates.contains(where: hasResource) { return true }
        let parent = current.removingLastComponent()
        if parent == current { return false }
        current = parent
    }
}

// MARK: - Trust store

/// A record of which project directories the user has decided to trust (or
/// explicitly distrust), keyed by resolved absolute path.
///
/// Ported from pi's `ProjectTrustStore`: a single JSON object at
/// `<configDir>/trust.json` mapping a canonical directory path to a boolean
/// decision, with the *nearest* saved decision on the current-or-ancestor path
/// winning. Trusting `/work` therefore trusts `/work/repo` unless `/work/repo`
/// carries its own decision.
///
/// It stores **only** a path and a yes/no bit — never a secret, never anything
/// about what runs. It is the input-loading guard pi's security model describes,
/// not a sandbox: a trusted directory may still do anything the user's account
/// can, which is why the decision is the user's to make explicitly.
///
/// The read is *strict* on purpose (contrast the tolerant session-entry read): a
/// trust file that will not parse is a security-relevant surprise, and silently
/// treating a corrupt store as "empty" would downgrade every saved decision to
/// "no record" — turning a recorded *distrust* into a fresh prompt. Failing loud
/// is the safe direction for a trust boundary.
public struct TrustStore: Sendable {
    /// The `trust.json` this store reads and writes.
    public let path: FilePath

    public init(configDirectory: FilePath) {
        self.path = configDirectory.appending("trust.json")
    }

    /// The nearest saved decision for `directory` or any ancestor, or `nil` when
    /// no decision has been recorded on the path at all.
    ///
    /// `nil` is distinct from `false`: `nil` means "never asked" (a caller may
    /// prompt, or in non-interactive mode refuse-with-instructions), while
    /// `false` means "explicitly distrusted" and a caller should honor it.
    ///
    /// Deliberately unlocked. The file is only ever replaced by `rename(2)`, so a
    /// reader sees either the whole old document or the whole new one; taking the
    /// write lock to read would make every launch wait on any launch that happened to
    /// be recording a decision.
    public func decision(for directory: FilePath) throws(DoMoError) -> Bool? {
        let table = try load()
        var current = Self.canonical(directory)
        while true {
            if let decision = table[current] { return decision }
            let parent = Self.parent(of: current)
            if parent == current { return nil }
            current = parent
        }
    }

    /// Records `trusted` for `directory` (canonicalized), creating `trust.json`
    /// and its parent directory if needed. A prior decision for the exact path is
    /// overwritten; ancestor decisions are left untouched.
    ///
    /// The read, the edit and the write are one locked step. Without the lock, two
    /// `domo` processes trusting two different directories at once each read the same
    /// table, each add their own key and each write the whole document back — and one
    /// of the two decisions is gone, with the only symptom being that the user is
    /// asked to trust a directory they already trusted. A lock timeout is a real
    /// error here rather than best-effort silence, because every caller of this
    /// already handles a throw and a lost trust decision is a security-relevant
    /// surprise.
    public func setDecision(_ trusted: Bool, for directory: FilePath) throws(DoMoError) {
        // Before the lock, because on a first run the config directory does not exist
        // yet and both the lock file and trust.json need it. (For a symlinked store the
        // lock is a sibling of the link's *target* instead; ``withLock(_:)`` creates
        // that directory itself.)
        let parent = Self.parent(of: path.string)
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw DoMoError(.file(path: FilePath(parent), errno: nil), "Could not create config directory", cause: error)
        }

        try withLock { () throws(DoMoError) in
            var table = try load()
            table[Self.canonical(directory)] = trusted
            try save(table)
        }
    }

    // MARK: - Locking

    /// How long to keep trying for the lock before calling it contention.
    ///
    /// A trust decision is written at most twice in a process, at startup, and the
    /// critical section is one small read and one small write — so anything past a
    /// couple of seconds is a stuck or dead peer, not a queue.
    private static let lockTimeout: Duration = .seconds(2)

    /// The sidecar lock file guarding a write.
    ///
    /// Derived with ``FileLock/lockPath(forDocumentAt:)``, which follows a symlinked
    /// leaf exactly the way ``AtomicFileWrite`` follows it when it writes — so a
    /// dotfiles-symlinked trust.json is locked where it is written. Processes that
    /// spell the *parent* differently (`/tmp` versus `/private/tmp`, `$HOME` versus
    /// its real location) need no help: `flock(2)` locks an inode, and both spellings
    /// name the same one.
    ///
    /// It used to be `URL.resolvingSymlinksInPath()`, which resolves a symlink only
    /// once the target exists. For a trust.json symlinked at a file no decision had
    /// created yet, the lock therefore lived on `.trust.json.lock` before the first
    /// write and on `.real.json.lock` after it — and this is the store where that is
    /// worst, because ``setDecision(_:for:)`` then *succeeds* under a lock somebody
    /// else is holding rather than throwing, silently bypassing the guarantee its own
    /// documentation makes.
    ///
    /// Internal rather than private so a test can hold it and check that a write
    /// respects it; there is no other way to assert the lock exists.
    var lockPath: String {
        FileLock.lockPath(forDocumentAt: path.string)
    }

    /// Runs `body` holding an exclusive `flock(2)` on `.trust.json.lock`.
    ///
    /// This is ``FileLock`` open-coded, and only because it must be **synchronous**:
    /// `setDecision(_:for:)` is sync, its caller `ensureProjectTrust` is sync, and
    /// making either `async` would ripple through command entry points this file has
    /// no business changing. The cost is a `Thread.sleep` on a contended acquire
    /// instead of a suspension — acceptable exactly here, where the call happens once
    /// at startup before the harness or any concurrency exists, and nowhere else.
    /// When `ensureProjectTrust` can be async, delete this and call
    /// `FileLock.withLock`.
    ///
    /// A sidecar (``lockPath``), never trust.json itself: `O_CREAT` on the document
    /// would leave a 0-byte trust.json, which ``load()`` — strict on purpose — turns
    /// into a hard error on every later launch.
    private func withLock(_ body: () throws(DoMoError) -> Void) throws(DoMoError) {
        let lockPath = FilePath(self.lockPath)

        // The lock is a sibling of the *resolved* trust.json, which for a symlinked
        // store is a directory `setDecision(_:for:)` never created — it created the
        // config directory the link lives in. `FileLock.withLock` creates its own
        // parent for the same reason; this is the open-coded copy of that, and without
        // it a store symlinked into a not-yet-created dotfiles directory fails to lock
        // a write that would otherwise have succeeded.
        let lockDirectory = lockPath.removingLastComponent().string
        if !lockDirectory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: lockDirectory,
                withIntermediateDirectories: true
            )
        }

        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                lockPath,
                .writeOnly,
                options: [.create],
                permissions: .ownerReadWrite
            )
        } catch {
            throw DoMoError(
                .file(path: lockPath, errno: error as? Errno),
                "Could not open the trust store lock \(lockPath.string)",
                cause: error
            )
        }
        defer { try? descriptor.close() }

        guard Self.acquire(descriptor.rawValue) else {
            throw DoMoError(
                .file(path: path, errno: nil),
                "Another DoMoCode process is updating \(path.string). Try again in a moment."
            )
        }
        // Redundant with the close above — `close(2)` drops an `flock` — but stated
        // rather than left as an inference about `defer` ordering.
        defer { _ = flock(descriptor.rawValue, LOCK_UN) }

        try body()
    }

    /// Polls `LOCK_EX|LOCK_NB` until it succeeds or ``lockTimeout`` elapses.
    ///
    /// Never a blocking `LOCK_EX`: a peer that took the lock and then stopped (a
    /// suspended process, a debugger) would hang the CLI at startup with no way out
    /// but a signal. The deadline is on `ContinuousClock`, so an NTP step cannot
    /// extend or truncate the wait.
    private static func acquire(_ descriptor: CInt) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if clock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - File I/O

    private func load() throws(DoMoError) -> [String: Bool] {
        let url = URL(fileURLWithPath: path.string)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Absent is the common case: no decision has ever been saved.
            return [:]
        }
        do {
            // A trust file is a flat object of path → bool. `null` (pi's "cleared"
            // sentinel) decodes as an absent key here, which is the same as no
            // decision — DoMoCode never writes `null`, but tolerating it keeps a
            // pi-written store readable.
            return try JSONDecoder().decode([String: Bool].self, from: data)
        } catch {
            throw DoMoError(
                .configuration,
                "Could not parse trust store \(path.string). Fix or remove it to re-establish project trust.",
                cause: error
            )
        }
    }

    /// Writes the whole table. Called only from ``setDecision(_:for:)``, which has
    /// already created the directory and taken the lock.
    private func save(_ table: [String: Bool]) throws(DoMoError) {
        let encoder = JSONEncoder()
        // Sorted keys so the file is stable across writes and reviewable in a
        // diff — the same reason the session wire sorts its keys.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do {
            data = try encoder.encode(table)
        } catch {
            throw DoMoError(.file(path: path, errno: nil), "Could not encode trust store", cause: error)
        }
        // `AtomicFileWrite` rather than `Data.write(options: .atomic)`. Measured on
        // Darwin 27 under umask 022: Foundation creates the file at 0644 — so a
        // brand-new trust.json is world-readable — and replaces a symlink with a
        // regular file, detaching a dotfiles-managed store from its repository. It
        // does carry an existing file's mode across on this platform, so that half is
        // belt and braces here rather than a fix.
        //
        // `String(decoding:as:)` rather than `String(data:encoding:)` because
        // `JSONEncoder` output is UTF-8 by construction, so there is no failure case
        // to invent a message for.
        try AtomicFileWrite.replace(at: path.string, with: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Path normalization

    /// The canonical key for a directory: an absolute path with symlinks and
    /// `.`/`..` resolved, so two spellings of the same directory (a symlinked
    /// `/tmp` vs `/private/tmp`, a relative vs absolute cwd) collapse to one key
    /// and cannot each carry a divergent decision.
    static func canonical(_ directory: FilePath) -> String {
        let resolved = URL(fileURLWithPath: directory.string).resolvingSymlinksInPath().path
        return resolved.isEmpty ? "/" : resolved
    }

    /// The parent directory path, or the input itself at a filesystem root — the
    /// termination signal for the ancestor walk.
    private static func parent(of pathString: String) -> String {
        let url = URL(fileURLWithPath: pathString)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
