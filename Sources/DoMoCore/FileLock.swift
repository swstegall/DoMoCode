// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A cross-process advisory lock held for the duration of one closure.
///
/// It exists for read-modify-write on a shared file — `settings.json` being the
/// case that forced it. Two `domo` processes that each read the file, add their
/// own "allow always" grant and write the whole document back will silently drop
/// one of the two grants, and the user's only evidence is being asked again for
/// a permission they already granted.
///
/// ## Why `flock(2)`
///
/// A lock the kernel drops for us. `flock` releases on `close(2)` *and* on
/// process death, so there is no stale lock to detect and no pid to reap: a
/// `domo` killed with SIGKILL mid-write leaves nothing behind for the next
/// process to reason about. Every hand-rolled lockfile eventually grows a
/// "is the recorded pid still alive, and is it still *us*?" heuristic, and that
/// heuristic is wrong across containers, across pid namespaces, and after pid
/// reuse.
///
/// `fcntl(F_SETLK)` is the wrong primitive here even though it is the more
/// portable one. POSIX record locks are owned by the **process**, so a second
/// request from the same process is granted immediately and unlocking anywhere
/// releases everywhere. `domo --serve` runs two permission engines in one
/// process; with record locks both would be handed the lock, the in-process race
/// would survive the fix, and no test could see it. `flock` locks the open file
/// *description*, so two descriptors in one process exclude each other — which
/// is what `FileLockScopeTests.withLockExcludesItselfWithinAProcess` asserts by
/// driving ``withLock(at:timeout:_:)`` twice concurrently, and what pins this
/// choice. (`FileLockPrimitiveTests.exclusionHoldsWithinAProcess` demonstrates
/// the same semantics with raw `flock(2)` calls, but it never touches this type,
/// so it would stay green through a rewrite onto record locks and pins nothing.)
///
/// `swift-system`'s `OpenOptions.exclusiveLock` (`O_EXLOCK`) would be tidier and
/// is not an option: it is compiled only on Darwin and FreeBSD, and this package
/// has to build on Linux.
///
/// ## Why never `LOCK_EX` on its own
///
/// A blocking `flock` would park the calling thread. Under
/// `NonisolatedNonsendingByDefault` the body — and this call — run on the
/// caller's executor, so blocking pins a cooperative-pool thread for as long as
/// the other process holds the lock. The pool is sized to the core count, so a
/// few of those and the whole harness stops making progress. Polling
/// `LOCK_EX|LOCK_NB` and suspending between attempts keeps the thread free.
///
/// ## Lock a sidecar, never the file itself
///
/// Callers pass the path of a lock file, not of the document. Locking
/// `settings.json` directly means opening it `O_CREAT`, which leaves a 0-byte
/// `settings.json` behind whenever the merge that followed aborted — and
/// `Settings.load` turns a 0-byte settings file into a hard throw on every
/// later launch, so the CLI would refuse to start until the user deleted a file
/// they never created. ``sidecarPath(for:)`` spells the convention, and
/// ``lockPath(forDocumentAt:)`` — which resolves the document exactly the way
/// the write does — is what callers should actually use.
public struct FileLock: Sendable {

    /// What one ``withLock(at:timeout:_:)`` call did.
    ///
    /// Three outcomes rather than an optional, because the caller's message to
    /// the user differs for each and getting it wrong is a lie: "another process
    /// is writing" told to somebody whose lock file is a directory sends them
    /// hunting for a second `domo` that does not exist. A fourth possibility —
    /// the lock file cannot be opened at all — is *thrown* with its `errno`,
    /// because it is a broken filesystem rather than a scheduling outcome.
    public enum Outcome<Value> {
        /// The lock was held and `body` ran to completion, returning this.
        case ran(Value)
        /// Somebody else held the lock for the whole timeout; `body` never ran.
        case contended
        /// The task was cancelled while waiting for a lock somebody else held;
        /// `body` never ran. Distinct from ``contended`` because nothing is
        /// wrong with the peer — the caller stopped waiting.
        case cancelled

        /// The body's result, or `nil` when it never ran.
        public var value: Value? {
            if case .ran(let value) = self { return value }
            return nil
        }

        /// Whether the body ran.
        public var ranBody: Bool {
            if case .ran = self { return true }
            return false
        }
    }

    /// How long to wait between acquisition attempts.
    ///
    /// Short enough that an uncontended hand-off is not perceptible next to the
    /// disk write it guards, long enough that a contended wait is a handful of
    /// suspensions rather than a spin.
    private static let pollInterval: Duration = .milliseconds(20)

    /// The lock file guarding a read-modify-write of the document at `path`.
    ///
    /// The leaf is resolved with ``AtomicFileWrite/resolvingSymlinkLeaf(_:)`` —
    /// the *same* resolution the write itself uses — and that identity is the
    /// whole point. Deriving the lock path with `URL.resolvingSymlinksInPath()`
    /// instead looks equivalent and is not: it resolves a symlink only while the
    /// target exists, so for a `settings.json` symlinked at a target that has
    /// not been created yet the lock sat on `.settings.json.lock` before the
    /// first write and on `.real.json.lock` after it. The lock moved out from
    /// under whoever was holding it, and the next writer took a *different* file
    /// and walked straight into the critical section the lock exists to protect.
    ///
    /// Parent components are deliberately **not** canonicalised. `flock(2)`
    /// locks an inode, not a path, so `/tmp/x/.f.lock` and
    /// `/private/tmp/x/.f.lock` already exclude each other, and canonicalising a
    /// parent has the same "only once it exists" instability as the leaf.
    /// Following the leaf link is the one canonicalisation that changes which
    /// *file* is locked, and therefore the only one worth doing.
    public static func lockPath(forDocumentAt path: String) -> String {
        sidecarPath(for: AtomicFileWrite.resolvingSymlinkLeaf(FilePath(path)).string)
    }

    /// The conventional lock path for a document: a dot-prefixed sibling with a
    /// `.lock` suffix, so `…/settings.json` locks on `…/.settings.json.lock`.
    ///
    /// A sibling rather than a file in a shared lock directory: the lock has to
    /// live on the same filesystem and inherit the same permissions as the thing
    /// it protects, and a user who can write the document can always create it.
    ///
    /// This is the naming convention only; it does no symlink resolution. Prefer
    /// ``lockPath(forDocumentAt:)`` unless the caller has already resolved the
    /// document itself.
    public static func sidecarPath(for path: String) -> String {
        let file = FilePath(path)
        guard let name = file.lastComponent?.string else {
            // A bare root ("/") has no last component. Nothing sane locks that,
            // but returning a path rather than trapping keeps this total.
            return path + ".lock"
        }
        return file.removingLastComponent().appending(".\(name).lock").string
    }

    /// Runs `body` while holding an exclusive lock on `path`, reporting through
    /// ``Outcome`` when it could not be taken before `timeout` elapsed.
    ///
    /// ``Outcome/contended`` is the whole point of the signature: it is *not* an
    /// error, it is "somebody else is writing right now". A caller that must not
    /// lose the write retries or reports; a caller for whom the write is
    /// best-effort can ignore it.
    ///
    /// What it deliberately does not cover is a lock file that cannot be opened
    /// at all — EACCES on a 0400 lock file, ENOTDIR, EROFS. Those used to be
    /// folded into the same "busy" answer, which sent the user looking for a
    /// second `domo` that did not exist while the real cause (a mode, a mount, a
    /// path component that is a file) went unmentioned. They now `throw` a
    /// ``DoMoError`` carrying the `errno`. The function is `throws` rather than
    /// `rethrows` for exactly that reason, so a non-throwing body still needs a
    /// `try`.
    ///
    /// The parent directory is created if missing, because the alternative is
    /// that a first run on a fresh machine reports "busy" — which is a lie —
    /// for a config directory that simply does not exist yet.
    ///
    /// Cancellation during the wait ends the wait and yields
    /// ``Outcome/cancelled``; the body is never entered. Cancellation *inside*
    /// the body propagates as whatever the body throws, and the lock is released
    /// on the way out either way. An *uncontended* acquire still succeeds under
    /// cancellation: the first `flock` attempt is made unconditionally, so a
    /// cancelled task can still finish a save nobody is competing for.
    ///
    /// - Parameters:
    ///   - path: The lock file. Pass ``lockPath(forDocumentAt:)`` of the
    ///     document, never the document itself.
    ///   - timeout: How long to keep trying before giving up.
    public static func withLock<T>(
        at path: String,
        timeout: Duration = .seconds(2),
        _ body: () async throws -> T
    ) async throws -> Outcome<T> {
        let file = FilePath(path)
        let directory = file.removingLastComponent().string
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        }
        // `.create` without `.exclusiveCreate`: the lock file is meant to be
        // shared and to outlive any one holder. It is never read or written, so
        // a leftover empty file is inert — unlike a leftover empty settings.json.
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                file,
                .writeOnly,
                options: [.create],
                permissions: .ownerReadWrite
            )
        } catch let errno as Errno {
            throw DoMoError.file(errno, path: file, while: "open the lock file")
        } catch {
            throw DoMoError(
                wrapping: error,
                as: .file(path: file, errno: nil),
                "open the lock file \(file)"
            )
        }
        defer { try? descriptor.close() }
        switch await acquire(descriptor.rawValue, timeout: timeout) {
        case .acquired:
            break
        case .timedOut:
            return .contended
        case .cancelled:
            return .cancelled
        }
        // Redundant with the close above — `close(2)` releases the lock — but
        // stated so the release is not an inference about a `defer` ordering
        // three lines away.
        defer { _ = flock(descriptor.rawValue, LOCK_UN) }
        let value = try await body()
        return .ran(value)
    }

    /// Why ``acquire(_:timeout:)`` stopped trying.
    private enum Acquisition {
        case acquired
        case timedOut
        case cancelled
    }

    /// Polls `LOCK_EX|LOCK_NB` until it succeeds, `timeout` elapses, or the task
    /// is cancelled.
    ///
    /// The deadline comes from `ContinuousClock`, not `Date`: a wall-clock jump
    /// backwards (NTP, a laptop waking up) would otherwise extend the wait
    /// arbitrarily, and a jump forwards would abandon a lock that was about to
    /// be granted.
    ///
    /// Every attempt is made at least once, so `timeout: .zero` is a well-defined
    /// "try, do not wait" — and so is an already-cancelled task, which still gets
    /// one attempt before the cancellation check.
    ///
    /// The deadline is checked before cancellation, so a wait that ran out at the
    /// same moment it was cancelled reports ``Acquisition/timedOut``: the peer
    /// really did hold the lock for the whole timeout, which is what the caller
    /// would have been told a microsecond earlier.
    private static func acquire(_ descriptor: CInt, timeout: Duration) async -> Acquisition {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .acquired }
            if clock.now >= deadline { return .timedOut }
            // A cancelled task would otherwise busy-loop here: `Task.sleep`
            // returns immediately once cancelled, so the poll would spin at full
            // speed until the deadline. Reporting it as its own outcome is what
            // makes deleting this line fail a test rather than only burn a core.
            if Task.isCancelled { return .cancelled }
            try? await Task.sleep(for: pollInterval)
        }
    }
}

extension FileLock.Outcome: Sendable where Value: Sendable {}
extension FileLock.Outcome: Equatable where Value: Equatable {}
