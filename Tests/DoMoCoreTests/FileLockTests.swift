// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import SystemPackage
import Testing

import DoMoCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Fixtures

private func makeTemporaryDirectory() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("file-lock-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

private func read(_ path: FilePath) throws -> String {
    String(decoding: try Data(contentsOf: URL(fileURLWithPath: path.string)), as: UTF8.self)
}

/// The permission bits of `path`, or `0` when they cannot be read — a value no
/// expectation below accepts, so a missing file fails rather than passes.
private func mode(of path: FilePath) throws -> UInt32 {
    let attributes = try FileManager.default.attributesOfItem(atPath: path.string)
    guard let bits = attributes[.posixPermissions] as? NSNumber else { return 0 }
    return bits.uint32Value & 0o7777
}

/// Anything left over from an interrupted or failed replace.
private func temporaryFileNames(in directory: FilePath) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.string)
        .filter { $0.hasSuffix(".tmp") }
}

private struct Boom: Error {}

/// A latch two tasks can share.
///
/// A `final class` around the `Mutex` rather than a bare one, for the reason
/// `ServerClient.ActivityStamp` gives: a `Mutex` is non-copyable, so it cannot be
/// stored in a copyable struct and cannot be captured by two closures at once.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// A `FileLock` held by a background task until ``release()``.
private struct BackgroundHolder {
    let task: Task<Void, any Error>
    let released: Flag

    /// Lets the body finish and waits for the lock to actually be dropped, so a
    /// test that acquires next is measuring the lock rather than a race with it.
    func release() async throws {
        released.set()
        try await task.value
    }
}

/// Takes `lock` through `FileLock.withLock` in a background task and returns only
/// once the body is demonstrably running, i.e. once the lock is really held.
///
/// In-process on purpose: a second `withLock` blocked by this one is the only
/// thing in the suite that can tell `flock(2)` (per open file description) from
/// `fcntl` record locks (per process, and so granted twice to one process).
private func holdInBackground(_ lock: String) async throws -> BackgroundHolder {
    let entered = Flag()
    let released = Flag()
    let task = Task { () async throws -> Void in
        _ = try await FileLock.withLock(at: lock, timeout: .seconds(10)) {
            entered.set()
            while !released.isSet {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    let clock = ContinuousClock()
    let giveUp = clock.now.advanced(by: .seconds(5))
    while !entered.isSet, clock.now < giveUp {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(entered.isSet, "the background holder never took \(lock), so nothing below proves anything")
    return BackgroundHolder(task: task, released: released)
}

// MARK: - The primitive

@Suite("FileLock — the flock(2) contract")
struct FileLockPrimitiveTests {

    /// What `flock(2)` promises, demonstrated on raw descriptors: it locks the
    /// open file *description*, so two descriptors in one process exclude each
    /// other, where `fcntl(F_SETLK)` — the obvious alternative, and the more
    /// portable one — locks per **process** and would grant both requests.
    ///
    /// This test does **not** pin `FileLock`'s choice of syscall, and it used to
    /// claim it did. It calls `flock` by hand and never touches `FileLock`, so a
    /// rewrite onto record locks leaves it green. The test that actually pins the
    /// choice is `FileLockScopeTests.withLockExcludesItselfWithinAProcess`,
    /// which drives `FileLock.withLock` twice in one process; this one is here to
    /// show the primitive's semantics unmixed with anything else.
    @Test("Two descriptors on one lock file exclude each other inside a single process")
    func exclusionHoldsWithinAProcess() throws {
        let path = try makeTemporaryDirectory().appending(".settings.json.lock")
        let first = try FileDescriptor.open(
            path, .writeOnly, options: [.create], permissions: .ownerReadWrite)
        defer { try? first.close() }
        let second = try FileDescriptor.open(
            path, .writeOnly, options: [.create], permissions: .ownerReadWrite)
        defer { try? second.close() }

        #expect(flock(first.rawValue, LOCK_EX | LOCK_NB) == 0)

        let refused = flock(second.rawValue, LOCK_EX | LOCK_NB)
        let reason = Errno(rawValue: errno)
        #expect(refused == -1)
        #expect(reason == .wouldBlock)

        #expect(flock(first.rawValue, LOCK_UN) == 0)
        #expect(flock(second.rawValue, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(second.rawValue, LOCK_UN) == 0)
    }

    @Test("The sidecar lock path is a dot-prefixed sibling, never the document itself")
    func sidecarNaming() {
        #expect(
            FileLock.sidecarPath(for: "/home/u/.domocode/settings.json")
                == "/home/u/.domocode/.settings.json.lock")
        #expect(FileLock.sidecarPath(for: "settings.json") == ".settings.json.lock")
    }

    /// The lock has to be the *same file* before and after the first write, and
    /// `URL.resolvingSymlinksInPath()` — which is how this path used to be
    /// derived — is not: it resolves a symlink only while the target exists.
    /// `AtomicFileWrite` follows the leaf through `readlink(2)`, which does not
    /// care, and creates the target on the first write. So the lock was taken on
    /// `.settings.json.lock` up to that instant and on `.real.json.lock` after
    /// it, and the next writer in took a lock file nobody was holding and
    /// walked into the critical section.
    @Test("The lock path does not move when a dangling symlink's target appears")
    func lockPathIsStableAcrossADanglingSymlink() throws {
        let root = try makeTemporaryDirectory()
        let config = root.appending("config")
        let dotfiles = root.appending("dotfiles")
        try FileManager.default.createDirectory(
            atPath: config.string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: dotfiles.string, withIntermediateDirectories: true)
        let document = config.appending("settings.json")
        let target = dotfiles.appending("real.json")
        // Dangling on purpose: `real.json` does not exist until the first write.
        try FileManager.default.createSymbolicLink(
            atPath: document.string, withDestinationPath: target.string)
        #expect(FileManager.default.fileExists(atPath: target.string) == false)

        let before = FileLock.lockPath(forDocumentAt: document.string)
        try AtomicFileWrite.replace(at: document.string, with: "{}")
        let after = FileLock.lockPath(forDocumentAt: document.string)

        #expect(FileManager.default.fileExists(atPath: target.string), "the premise is wrong")
        #expect(before == after)
        // And it is the sidecar of the file the write actually lands on.
        #expect(after == FileLock.sidecarPath(for: target.string))
    }

    /// A relative link target resolves against the link's own directory, so the
    /// lock path can carry a `..`. That is harmless — `flock(2)` locks the inode
    /// the kernel arrives at, and every spelling of the same sidecar arrives at
    /// the same one — but it is what the path looks like, so it is asserted
    /// rather than left to be discovered.
    @Test("A relative symlink target resolves against the link's own directory")
    func lockPathFollowsARelativeLinkTarget() throws {
        let root = try makeTemporaryDirectory()
        let config = root.appending("config")
        try FileManager.default.createDirectory(
            atPath: config.string, withIntermediateDirectories: true)
        let document = config.appending("settings.json")
        try FileManager.default.createSymbolicLink(
            atPath: document.string, withDestinationPath: "../dotfiles/real.json")

        let lock = FilePath(FileLock.lockPath(forDocumentAt: document.string))

        #expect(
            lock.lexicallyNormalized() == root.appending("dotfiles").appending(".real.json.lock"))
    }

    /// A path with no symlink in it is left exactly as written: no `/private`
    /// prefix, no `..` collapsing, no canonicalisation of parents. Locking an
    /// inode makes all of that unnecessary, and every bit of it is a way for the
    /// answer to change once some file starts existing.
    @Test("A plain document path is not canonicalised on the way to its lock")
    func lockPathLeavesAPlainPathAlone() throws {
        let directory = try makeTemporaryDirectory()
        let document = directory.appending("settings.json")

        #expect(
            FileLock.lockPath(forDocumentAt: document.string)
                == FileLock.sidecarPath(for: document.string))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: document.string))
        #expect(
            FileLock.lockPath(forDocumentAt: document.string)
                == FileLock.sidecarPath(for: document.string))
    }
}

// MARK: - withLock

@Suite("FileLock — withLock")
struct FileLockScopeTests {

    /// The reason the whole type exists: without the lock every task reads the
    /// same value, and seven of the eight increments vanish.
    @Test("Concurrent locked read-modify-write loses no update")
    func concurrentIncrementsAllLand() async throws {
        let directory = try makeTemporaryDirectory()
        let counter = directory.appending("counter.txt")
        let lock = FileLock.sidecarPath(for: counter.string)
        try Data("0".utf8).write(to: URL(fileURLWithPath: counter.string))

        let workers = 8
        let url = URL(fileURLWithPath: counter.string)
        // A throwing group so a lock file that could not be opened fails the test
        // as itself, instead of arriving three lines later as a missing increment.
        let acquired = try await withThrowingTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<workers {
                group.addTask {
                    let outcome = try await FileLock.withLock(at: lock, timeout: .seconds(30)) {
                        let text = (try? Data(contentsOf: url)).map {
                            String(decoding: $0, as: UTF8.self)
                        }
                        let value = text.flatMap { Int($0) } ?? -1_000_000
                        // Widens the read-modify-write window so that an absent
                        // lock loses updates every run rather than occasionally.
                        try? await Task.sleep(for: .milliseconds(20))
                        try? Data("\(value + 1)".utf8).write(to: url)
                    }
                    return outcome.ranBody
                }
            }
            var count = 0
            for try await held in group where held { count += 1 }
            return count
        }

        #expect(acquired == workers)
        #expect(try read(counter) == "8")
    }

    /// The assertion that actually pins `flock(2)` over `fcntl(F_SETLK)`, and the
    /// only one in this file that can: two `withLock` calls, one process, one
    /// lock file. Record locks are owned by the process, so the second call would
    /// be granted on the spot, the body would run inside the first body's
    /// critical section, and `domo --serve`'s two permission engines would lose a
    /// grant to each other with the whole suite green.
    ///
    /// Deterministic on purpose — it does not depend on the scheduler
    /// interleaving anything, so it fails on every machine and every run if the
    /// primitive is swapped.
    @Test("Two concurrent withLock calls in one process exclude each other")
    func withLockExcludesItselfWithinAProcess() async throws {
        let directory = try makeTemporaryDirectory()
        let lock = directory.appending(".settings.json.lock").string
        let holder = try await holdInBackground(lock)

        let ran = Flag()
        let second = try await FileLock.withLock(at: lock, timeout: .milliseconds(200)) {
            () -> Int in
            ran.set()
            return 7
        }

        #expect(second == .contended)
        #expect(ran.isSet == false)

        try await holder.release()
        // And the lock really was released, so the exclusion above was the lock
        // working rather than the lock being permanently stuck.
        let after = try await FileLock.withLock(at: lock, timeout: .seconds(5)) { 7 }
        #expect(after == .ran(7))
    }

    /// The justification for ``FileLock/lockPath(forDocumentAt:)`` leaving parent
    /// components exactly as the caller spelled them: two spellings of one
    /// document, one of them through a symlinked directory, produce two different
    /// lock path *strings* and still exclude each other, because `flock(2)` locks
    /// the inode both strings name.
    ///
    /// This is what makes it safe to drop the old `resolvingSymlinksInPath()`
    /// canonicalisation — which bought nothing here and cost the lock its
    /// identity across the first write.
    @Test("Two spellings of one lock file exclude each other without canonicalisation")
    func differentParentSpellingsStillExclude() async throws {
        let root = try makeTemporaryDirectory()
        let real = root.appending("real")
        try FileManager.default.createDirectory(
            atPath: real.string, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appending("link").string, withDestinationPath: "real")

        let viaReal = FileLock.lockPath(forDocumentAt: real.appending("settings.json").string)
        let viaLink = FileLock.lockPath(
            forDocumentAt: root.appending("link").appending("settings.json").string)
        #expect(viaReal != viaLink, "the premise is wrong: the two spellings are one string")

        let holder = try await holdInBackground(viaReal)
        let ran = Flag()
        let second = try await FileLock.withLock(at: viaLink, timeout: .milliseconds(200)) {
            () -> Int in
            ran.set()
            return 7
        }

        #expect(second == .contended)
        #expect(ran.isSet == false)
        try await holder.release()
    }

    @Test("The lock is released when the body throws")
    func releasedWhenBodyThrows() async throws {
        let directory = try makeTemporaryDirectory()
        let lock = directory.appending(".settings.json.lock").string

        await #expect(throws: Boom.self) {
            _ = try await FileLock.withLock(at: lock) { () throws -> Int in throw Boom() }
        }

        // A short timeout on purpose: if the first call leaked the lock this
        // fails fast instead of hanging the suite.
        let recovered = try await FileLock.withLock(at: lock, timeout: .milliseconds(250)) { 7 }
        #expect(recovered == .ran(7))
    }

    @Test("The lock is released when the holding task is cancelled")
    func releasedWhenTaskCancelled() async throws {
        let directory = try makeTemporaryDirectory()
        let lock = directory.appending(".settings.json.lock").string
        let entered = Mutex(false)

        let holder = Task {
            _ = try? await FileLock.withLock(at: lock, timeout: .seconds(10)) {
                entered.withLock { $0 = true }
                try await Task.sleep(for: .seconds(60))
            }
        }
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: .seconds(5))
        while !entered.withLock({ $0 }), clock.now < giveUp {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered.withLock { $0 })

        holder.cancel()
        await holder.value

        let recovered = try await FileLock.withLock(at: lock, timeout: .milliseconds(250)) { 7 }
        #expect(recovered == .ran(7))
    }

    /// The `Task.isCancelled` check inside the poll loop is the only thing
    /// between a cancelled contended wait and a full-speed spin to the deadline,
    /// and for a long time nothing could see it: deleting it left every outcome
    /// unchanged (`nil` either way) and only burned a core for the rest of the
    /// timeout. Reporting cancellation as its own outcome is what makes the
    /// deletion visible — without the check this returns `.contended`, five
    /// seconds late.
    @Test("A cancelled wait ends at once, says it was cancelled, and never enters the body")
    func cancelledWaitIsNotReportedAsContention() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending(".settings.json.lock")
        let holder = try FileDescriptor.open(
            path, .writeOnly, options: [.create], permissions: .ownerReadWrite)
        defer { try? holder.close() }
        #expect(flock(holder.rawValue, LOCK_EX | LOCK_NB) == 0)

        let ran = Flag()
        let waiter = Task { () async throws -> FileLock.Outcome<Int> in
            try await FileLock.withLock(at: path.string, timeout: .seconds(5)) { () -> Int in
                ran.set()
                return 7
            }
        }
        // Long enough that the waiter is demonstrably in the poll loop rather
        // than being cancelled before it ever attempted the lock.
        try await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let start = clock.now
        waiter.cancel()
        let outcome = try await waiter.value
        let waited = clock.now - start

        #expect(outcome == .cancelled)
        #expect(ran.isSet == false)
        // Well inside the five-second timeout: cancellation ends the wait, it
        // does not merely change what is reported at the end of it.
        #expect(waited < .seconds(1))

        #expect(flock(holder.rawValue, LOCK_UN) == 0)
    }

    /// A lock file that cannot be opened at all is a broken filesystem, not a
    /// busy peer. Folding it into "another process is writing" — which is what
    /// the old `nil` did for EACCES on a 0400 lock file, for EROFS, and for the
    /// ENOTDIR below — sends the user hunting for a second `domo` that does not
    /// exist.
    @Test("A lock file that cannot be opened throws with its errno, and the body never runs")
    func unopenableLockFileIsAnErrorNotContention() async throws {
        let directory = try makeTemporaryDirectory()
        // A regular file standing where a directory would have to be: `open` on
        // anything beneath it fails ENOTDIR, for root as well as for anyone else.
        let obstacle = directory.appending("blocked")
        try Data("x".utf8).write(to: URL(fileURLWithPath: obstacle.string))
        let lock = obstacle.appending(".settings.json.lock")

        let ran = Flag()
        let failure = await #expect(throws: DoMoError.self) {
            _ = try await FileLock.withLock(at: lock.string, timeout: .milliseconds(50)) {
                () -> Int in
                ran.set()
                return 7
            }
        }

        #expect(ran.isSet == false)
        guard case .file(_, let code)? = failure?.kind else {
            Issue.record("expected a .file failure, got \(String(describing: failure))")
            return
        }
        #expect(code == .notDirectory, "the errno that explains it must survive")
    }

    @Test("A held lock makes withLock report contention, after waiting, without running the body")
    func timesOutWhileHeldElsewhere() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending(".settings.json.lock")
        let holder = try FileDescriptor.open(
            path, .writeOnly, options: [.create], permissions: .ownerReadWrite)
        #expect(flock(holder.rawValue, LOCK_EX | LOCK_NB) == 0)

        let ran = Mutex(false)
        let clock = ContinuousClock()
        let start = clock.now
        let refused = try await FileLock.withLock(at: path.string, timeout: .milliseconds(150)) {
            () -> Int in
            ran.withLock { $0 = true }
            return 7
        }
        let waited = clock.now - start

        #expect(refused == .contended)
        #expect(ran.withLock { $0 } == false)
        // It polled to the deadline rather than answering on the first refusal.
        #expect(waited >= .milliseconds(120))

        #expect(flock(holder.rawValue, LOCK_UN) == 0)
        try holder.close()

        let granted = try await FileLock.withLock(at: path.string, timeout: .seconds(5)) { 7 }
        #expect(granted == .ran(7))
    }

    /// Opening `settings.json` itself `O_CREAT` to lock it leaves a 0-byte
    /// settings.json behind whenever the write that followed did not happen —
    /// and `Settings.load` turns a 0-byte settings file into a hard throw on
    /// every later launch. Locking must not be able to create the document.
    @Test("Locking does not create the document it protects")
    func lockingLeavesTheDocumentAlone() async throws {
        let directory = try makeTemporaryDirectory()
        let document = directory.appending("settings.json")

        let held = try await FileLock.withLock(at: FileLock.sidecarPath(for: document.string)) { 1 }

        #expect(held == .ran(1))
        #expect(FileManager.default.fileExists(atPath: document.string) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appending(".settings.json.lock").string))
    }

    /// A first run has no `~/.domocode` yet. Reporting that as "busy" would be a
    /// lie, and the caller would skip the very write that creates the file.
    @Test("Locking creates the directory the lock file lives in")
    func createsTheLockDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let lock = root.appending("nested").appending(".settings.json.lock")

        let held = try await FileLock.withLock(at: lock.string, timeout: .seconds(1)) { 3 }

        #expect(held == .ran(3))
    }
}

// MARK: - AtomicFileWrite

@Suite("AtomicFileWrite")
struct AtomicFileWriteTests {

    /// Foundation's `atomically: true` re-creates the file at 0644, so a user's
    /// `chmod 640` was silently reverted by the next save.
    @Test("Replacing an existing file preserves its mode")
    func preservesExistingMode() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending("settings.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path.string))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640], ofItemAtPath: path.string)

        try AtomicFileWrite.replace(at: path.string, with: #"{"model":"x"}"#)

        // 0640 is deliberately not the 0600 default: a create-at-createPermissions
        // implementation would come out 0600 here and this would catch it.
        #expect(try mode(of: path) == 0o640)
        #expect(try read(path) == #"{"model":"x"}"#)
    }

    /// `open(2)` intersects the mode it is handed with the process umask, so a
    /// preserved 0666 comes back 0644 under the usual 022: the file would drift
    /// to a *different* mode on every save while the function claimed to
    /// preserve one. The `fchmod` after create is what this pins, and nothing
    /// else in the suite does — a preserved 0640 survives umask 022 untouched.
    ///
    /// Under a umask of 000 this assertion is merely true rather than sharp.
    /// 022 and 002, the two anyone runs, both strip the other-write bit.
    @Test("A preserved mode is restored exactly, not filtered through the umask")
    func preservationDefeatsTheUmask() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending("settings.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path.string))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666], ofItemAtPath: path.string)

        try AtomicFileWrite.replace(at: path.string, with: "x")

        #expect(try mode(of: path) == 0o666)
    }

    @Test("A file this creates gets exactly the requested mode")
    func createsWithRequestedMode() throws {
        let directory = try makeTemporaryDirectory()

        let defaulted = directory.appending("default.json")
        try AtomicFileWrite.replace(at: defaulted.string, with: "a")
        #expect(try mode(of: defaulted) == 0o600)

        let explicit = directory.appending("explicit.json")
        try AtomicFileWrite.replace(
            at: explicit.string, with: "b", createPermissions: FilePermissions(rawValue: 0o644))
        #expect(try mode(of: explicit) == 0o644)
    }

    /// A dotfiles-managed config is a symlink into a repository. Replacing the
    /// link with a regular file detaches it, and the user's next `git status` is
    /// the first they hear of it.
    @Test("A symlinked path is written through: the link survives, the target changes")
    func writesThroughASymlink() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appending("real.json")
        let link = directory.appending("settings.json")
        try Data("old".utf8).write(to: URL(fileURLWithPath: target.string))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640], ofItemAtPath: target.string)
        // A RELATIVE link destination, which is what a dotfiles setup produces
        // and what an implementation that resolves against the wrong directory
        // gets wrong.
        try FileManager.default.createSymbolicLink(
            atPath: link.string, withDestinationPath: "real.json")

        try AtomicFileWrite.replace(at: link.string, with: "new")

        let type =
            try FileManager.default.attributesOfItem(atPath: link.string)[.type]
            as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try read(target) == "new")
        #expect(try mode(of: target) == 0o640)
    }

    @Test("Replacing a longer file leaves no tail of the old contents")
    func replaceTruncates() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending("settings.json")

        try AtomicFileWrite.replace(at: path.string, with: String(repeating: "x", count: 4096))
        try AtomicFileWrite.replace(at: path.string, with: "🙂 ok")

        #expect(try read(path) == "🙂 ok")
    }

    @Test("Replacing into a directory that does not exist yet creates it")
    func createsMissingParentDirectory() throws {
        let root = try makeTemporaryDirectory()
        let path = root.appending("nested").appending("settings.json")

        try AtomicFileWrite.replace(at: path.string, with: "a")

        #expect(try read(path) == "a")
    }

    @Test("A successful replace leaves no temporary file behind")
    func successCleansUp() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending("settings.json")

        try AtomicFileWrite.replace(at: path.string, with: "a")
        try AtomicFileWrite.replace(at: path.string, with: "b")

        #expect(try temporaryFileNames(in: directory).isEmpty)
        #expect(try read(path) == "b")
    }

    /// `FileManager.replaceItemAt` does not fail on a directory destination the
    /// way `rename(2)` does: on macOS it removes the original and moves the
    /// replacement into its place, so without the guard this call **deletes the
    /// directory and everything under it** and reports success. That was
    /// measured, not assumed. The surviving `child` is the assertion that
    /// matters; if the guard is removed it is the one that fails.
    @Test("Replacing a directory is refused, and the directory survives intact")
    func refusesToReplaceANonRegularFile() throws {
        let directory = try makeTemporaryDirectory()
        let obstacle = directory.appending("settings.json")
        let child = obstacle.appending("child")
        try FileManager.default.createDirectory(
            atPath: obstacle.string, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: child.string))

        #expect(throws: DoMoError.self) {
            try AtomicFileWrite.replace(at: obstacle.string, with: "hello")
        }

        #expect(try read(child) == "x")
        #expect(try temporaryFileNames(in: directory).isEmpty)
    }

    /// The hop limit ends a symlink cycle by giving up on a path that is *still*
    /// a symlink. What happens next is worth pinning, because the comment used to
    /// claim the `open` fails with `ELOOP`: it never gets there.
    /// `attributesOfItem` does not follow symlinks, so `existingPermissions` sees
    /// a link where it wants a regular file and refuses before anything is
    /// created — which is also the better outcome, since it means no temp file.
    @Test("A symlink cycle is refused as 'not a regular file', before anything is created")
    func refusesASymlinkCycle() throws {
        let directory = try makeTemporaryDirectory()
        let first = directory.appending("settings.json")
        let second = directory.appending("other.json")
        try FileManager.default.createSymbolicLink(
            atPath: first.string, withDestinationPath: "other.json")
        try FileManager.default.createSymbolicLink(
            atPath: second.string, withDestinationPath: "settings.json")

        let failure = #expect(throws: DoMoError.self) {
            try AtomicFileWrite.replace(at: first.string, with: "hello")
        }

        #expect(failure?.message.contains("not a regular file") == true)
        #expect(try temporaryFileNames(in: directory).isEmpty)
        // Both links survive: nothing was replaced on the way to the refusal.
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: first.string)
                == "other.json")
    }
}
