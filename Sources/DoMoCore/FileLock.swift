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
/// is what the first test in `FileLockTests` asserts, and what pins this choice.
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
/// they never created. ``sidecarPath(for:)`` spells the convention.
public struct FileLock: Sendable {

    /// How long to wait between acquisition attempts.
    ///
    /// Short enough that an uncontended hand-off is not perceptible next to the
    /// disk write it guards, long enough that a contended wait is a handful of
    /// suspensions rather than a spin.
    private static let pollInterval: Duration = .milliseconds(20)

    /// The conventional lock path for a document: a dot-prefixed sibling with a
    /// `.lock` suffix, so `…/settings.json` locks on `…/.settings.json.lock`.
    ///
    /// A sibling rather than a file in a shared lock directory: the lock has to
    /// live on the same filesystem and inherit the same permissions as the thing
    /// it protects, and a user who can write the document can always create it.
    public static func sidecarPath(for path: String) -> String {
        let file = FilePath(path)
        guard let name = file.lastComponent?.string else {
            // A bare root ("/") has no last component. Nothing sane locks that,
            // but returning a path rather than trapping keeps this total.
            return path + ".lock"
        }
        return file.removingLastComponent().appending(".\(name).lock").string
    }

    /// Runs `body` while holding an exclusive lock on `path`, or returns `nil`
    /// if the lock could not be taken before `timeout` elapsed.
    ///
    /// `nil` is the whole point of the signature: it is *not* an error, it is
    /// "somebody else is writing right now". A caller that must not lose the
    /// write retries or reports; a caller for whom the write is best-effort can
    /// ignore it. Throwing instead would push every caller into a `catch` that
    /// cannot tell contention from a broken filesystem.
    ///
    /// The parent directory is created if missing, because the alternative is
    /// that a first run on a fresh machine reports "busy" — which is a lie —
    /// for a config directory that simply does not exist yet.
    ///
    /// Cancellation during the wait ends the wait and yields `nil`; the body is
    /// never entered. Cancellation *inside* the body propagates as whatever the
    /// body throws, and the lock is released on the way out either way.
    ///
    /// - Parameters:
    ///   - path: The lock file. Pass ``sidecarPath(for:)`` of the document,
    ///     never the document itself.
    ///   - timeout: How long to keep trying before giving up.
    public static func withLock<T>(
        at path: String,
        timeout: Duration = .seconds(2),
        _ body: () async throws -> T
    ) async rethrows -> T? {
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
        guard
            let descriptor = try? FileDescriptor.open(
                file,
                .writeOnly,
                options: [.create],
                permissions: .ownerReadWrite
            )
        else { return nil }
        defer { try? descriptor.close() }
        guard await acquire(descriptor.rawValue, timeout: timeout) else { return nil }
        // Redundant with the close above — `close(2)` releases the lock — but
        // stated so the release is not an inference about a `defer` ordering
        // three lines away.
        defer { _ = flock(descriptor.rawValue, LOCK_UN) }
        return try await body()
    }

    /// Polls `LOCK_EX|LOCK_NB` until it succeeds or `timeout` elapses.
    ///
    /// The deadline comes from `ContinuousClock`, not `Date`: a wall-clock jump
    /// backwards (NTP, a laptop waking up) would otherwise extend the wait
    /// arbitrarily, and a jump forwards would abandon a lock that was about to
    /// be granted.
    ///
    /// Every attempt is made at least once, so `timeout: .zero` is a well-defined
    /// "try, do not wait".
    private static func acquire(_ descriptor: CInt, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if clock.now >= deadline { return false }
            // A cancelled task would otherwise busy-loop here: `Task.sleep`
            // returns immediately once cancelled, so the poll would spin at full
            // speed until the deadline.
            if Task.isCancelled { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
