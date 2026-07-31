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

// MARK: - The primitive

@Suite("FileLock — the flock(2) contract")
struct FileLockPrimitiveTests {

    /// The assertion that pins the choice of syscall, and the only one that can.
    ///
    /// `flock` locks the open file *description*, so two descriptors in one
    /// process exclude each other. `fcntl(F_SETLK)` — the obvious alternative,
    /// and the more portable one — locks per **process**: this same sequence
    /// would grant both requests, `domo --serve`'s two permission engines would
    /// both proceed, and the in-process half of the race would survive the fix
    /// with the suite green. If this test ever starts failing, the implementation
    /// has been rewritten onto record locks.
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
        let acquired = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    // Annotated because a `Void`-returning body infers `()?`,
                    // which the package's warnings-as-errors setting rejects.
                    let held: Void? = await FileLock.withLock(at: lock, timeout: .seconds(30)) {
                        let text = (try? Data(contentsOf: url)).map {
                            String(decoding: $0, as: UTF8.self)
                        }
                        let value = text.flatMap { Int($0) } ?? -1_000_000
                        // Widens the read-modify-write window so that an absent
                        // lock loses updates every run rather than occasionally.
                        try? await Task.sleep(for: .milliseconds(20))
                        try? Data("\(value + 1)".utf8).write(to: url)
                    }
                    return held != nil
                }
            }
            var count = 0
            for await held in group where held { count += 1 }
            return count
        }

        #expect(acquired == workers)
        #expect(try read(counter) == "8")
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
        let recovered = await FileLock.withLock(at: lock, timeout: .milliseconds(250)) { 7 }
        #expect(recovered == 7)
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

        let recovered = await FileLock.withLock(at: lock, timeout: .milliseconds(250)) { 7 }
        #expect(recovered == 7)
    }

    @Test("A held lock makes withLock return nil, after waiting, without running the body")
    func timesOutWhileHeldElsewhere() async throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending(".settings.json.lock")
        let holder = try FileDescriptor.open(
            path, .writeOnly, options: [.create], permissions: .ownerReadWrite)
        #expect(flock(holder.rawValue, LOCK_EX | LOCK_NB) == 0)

        let ran = Mutex(false)
        let clock = ContinuousClock()
        let start = clock.now
        let refused = await FileLock.withLock(at: path.string, timeout: .milliseconds(150)) {
            ran.withLock { $0 = true }
            return 7
        }
        let waited = clock.now - start

        #expect(refused == nil)
        #expect(ran.withLock { $0 } == false)
        // It polled to the deadline rather than answering on the first refusal.
        #expect(waited >= .milliseconds(120))

        #expect(flock(holder.rawValue, LOCK_UN) == 0)
        try holder.close()

        let granted = await FileLock.withLock(at: path.string, timeout: .seconds(5)) { 7 }
        #expect(granted == 7)
    }

    /// Opening `settings.json` itself `O_CREAT` to lock it leaves a 0-byte
    /// settings.json behind whenever the write that followed did not happen —
    /// and `Settings.load` turns a 0-byte settings file into a hard throw on
    /// every later launch. Locking must not be able to create the document.
    @Test("Locking does not create the document it protects")
    func lockingLeavesTheDocumentAlone() async throws {
        let directory = try makeTemporaryDirectory()
        let document = directory.appending("settings.json")

        let held = await FileLock.withLock(at: FileLock.sidecarPath(for: document.string)) { 1 }

        #expect(held == 1)
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

        let held = await FileLock.withLock(at: lock.string, timeout: .seconds(1)) { 3 }

        #expect(held == 3)
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
}
