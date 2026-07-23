// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage
import Testing

/// A sandbox root plus a sibling directory outside it, which is what every
/// escape test needs somewhere to escape *to*.
private struct Escapee {
    let outside: FilePath
    let root: FilePath
    let base: POSIXFileSystem
    let sandboxed: SandboxedFileSystem
}

private func withSandbox<T>(_ body: (Escapee) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { temporary, base in
        let root = temporary.appending("root")
        let outside = temporary.appending("outside")
        try await base.createDirectory(root)
        try await base.createDirectory(outside)
        try await base.write(outside.appending("secret.txt"), text: "classified\n")

        let sandboxed = try await SandboxedFileSystem.rooted(at: root, using: base)
        return try await body(
            Escapee(outside: outside, root: root, base: base, sandboxed: sandboxed)
        )
    }
}

// MARK: - Containment

@Suite("PathSandbox containment")
struct PathSandboxContainmentTests {

    @Test("containment is component-wise, so a sibling with a shared prefix is out")
    func componentWisePrefix() {
        let sandbox = PathSandbox(canonicalRoot: "/repo")
        #expect(sandbox.contains("/repo"))
        #expect(sandbox.contains("/repo/src/main.swift"))
        #expect(sandbox.contains("/repo-backup/src/main.swift") == false)
        #expect(sandbox.contains("/") == false)
    }

    @Test("the root is canonicalized, so a symlinked root still contains itself")
    func canonicalizesRoot() async throws {
        try await withTemporaryDirectory { temporary, base in
            let real = temporary.appending("real")
            try await base.createDirectory(real)
            let alias = temporary.appending("alias")
            try makeSymlink(at: alias, to: real.string)

            let sandbox = try await PathSandbox.rooted(at: alias, using: base)
            #expect(sandbox.root == real)
            #expect(sandbox.contains(real.appending("x")))
        }
    }
}

// MARK: - Escapes

@Suite("PathSandbox escapes")
struct PathSandboxEscapeTests {

    @Test("`..` traversal is rejected")
    func dotDotTraversal() async throws {
        try await withSandbox { fixture in
            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read("../outside/secret.txt")
            }
            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read(
                    fixture.root.appending("a").appending("..").appending("..")
                        .appending("outside").appending("secret.txt")
                )
            }
        }
    }

    @Test("`..` that stays inside the root is fine")
    func harmlessDotDot() async throws {
        try await withSandbox { fixture in
            try await fixture.sandboxed.write(
                fixture.root.appending("a").appending("b.txt"),
                text: "ok"
            )
            let text = try await fixture.sandboxed.readText("a/../a/b.txt")
            #expect(text.text == "ok")
        }
    }

    @Test("an absolute path outside the root is rejected")
    func absoluteOutside() async throws {
        try await withSandbox { fixture in
            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read(fixture.outside.appending("secret.txt"))
            }
            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read("/etc/hosts")
            }
        }
    }

    @Test("a real symlink pointing outside the root is rejected on read and write")
    func symlinkEscape() async throws {
        try await withSandbox { fixture in
            let link = fixture.root.appending("escape.txt")
            try makeSymlink(at: link, to: fixture.outside.appending("secret.txt").string)

            // Lexical normalization sees nothing wrong with this path — it has no
            // `..` in it at all — which is the entire reason realpath is required.
            #expect(link.lexicallyNormalized() == link)
            #expect(fixture.sandboxed.absolutePath(link).starts(with: fixture.root))

            await #expect(throws: DoMoError.self) { _ = try await fixture.sandboxed.read(link) }
            await #expect(throws: DoMoError.self) {
                try await fixture.sandboxed.write(link, text: "overwritten")
            }
            // The write must not have happened.
            let secret = try await fixture.base.readText(fixture.outside.appending("secret.txt"))
            #expect(secret.text == "classified\n")
        }
    }

    @Test("a chain of symlinks is followed all the way out and then rejected")
    func symlinkChainEscape() async throws {
        try await withSandbox { fixture in
            // Each hop lands inside the root; only the last one leaves.
            try makeSymlink(
                at: fixture.root.appending("hop3"),
                to: fixture.outside.appending("secret.txt").string
            )
            try makeSymlink(
                at: fixture.root.appending("hop2"),
                to: fixture.root.appending("hop3").string
            )
            try makeSymlink(
                at: fixture.root.appending("hop1"),
                to: fixture.root.appending("hop2").string
            )

            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read(fixture.root.appending("hop1"))
            }
        }
    }

    @Test("a symlinked *directory* pointing outside is rejected for paths beneath it")
    func directorySymlinkEscape() async throws {
        try await withSandbox { fixture in
            try makeSymlink(at: fixture.root.appending("out"), to: fixture.outside.string)
            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read("out/secret.txt")
            }
            await #expect(throws: DoMoError.self) {
                try await fixture.sandboxed.write("out/planted.txt", text: "x")
            }
            #expect(try await fixture.base.exists(fixture.outside.appending("planted.txt")) == false)
        }
    }

    @Test("symlinks that stay inside the root are followed normally")
    func containedSymlink() async throws {
        try await withSandbox { fixture in
            try await fixture.sandboxed.write(fixture.root.appending("real.txt"), text: "inside")
            try makeSymlink(
                at: fixture.root.appending("alias.txt"),
                to: fixture.root.appending("real.txt").string
            )
            let text = try await fixture.sandboxed.readText(fixture.root.appending("alias.txt"))
            #expect(text.text == "inside")
        }
    }
}

// MARK: - Creation

@Suite("PathSandbox creation")
struct PathSandboxCreationTests {

    @Test("a new leaf under an existing parent resolves and is contained")
    func newLeaf() async throws {
        try await withSandbox { fixture in
            let path = fixture.root.appending("new.txt")
            let resolved = try await fixture.sandboxed.canonicalPath(
                path,
                allowingMissingComponents: true
            )
            #expect(resolved == path)
            try await fixture.sandboxed.write(path, text: "hello")
            #expect(try await fixture.sandboxed.exists(path))
        }
    }

    @Test("a new leaf whose parent is a symlink out of the root is rejected")
    func newLeafUnderEscapedParent() async throws {
        try await withSandbox { fixture in
            try makeSymlink(at: fixture.root.appending("out"), to: fixture.outside.string)
            await #expect(throws: DoMoError.self) {
                try await fixture.sandboxed.write("out/new.txt", text: "x")
            }
        }
    }

    @Test("exists answers false for a missing path rather than reporting an escape")
    func existsIsNotAnEscape() async throws {
        try await withSandbox { fixture in
            try #expect(await fixture.sandboxed.exists("nothing/here.txt") == false)
        }
    }

    @Test("createDirectory is confined, including through a symlinked parent")
    func createDirectoryConfined() async throws {
        try await withSandbox { fixture in
            try await fixture.sandboxed.createDirectory("a/b/c", recursive: true)
            try #expect(await fixture.sandboxed.metadata("a/b/c").kind == .directory)

            try makeSymlink(at: fixture.root.appending("out"), to: fixture.outside.string)
            await #expect(throws: DoMoError.self) {
                try await fixture.sandboxed.createDirectory("out/planted", recursive: true)
            }
        }
    }
}

// MARK: - Removal

@Suite("PathSandbox removal")
struct PathSandboxRemovalTests {

    @Test("deleting a symlink that points outside removes the link, not the target")
    func deleteOutwardSymlink() async throws {
        try await withSandbox { fixture in
            let link = fixture.root.appending("escape.txt")
            let secret = fixture.outside.appending("secret.txt")
            try makeSymlink(at: link, to: secret.string)

            try await fixture.sandboxed.delete(link, recursive: false, force: false)
            try #expect(await fixture.sandboxed.exists(link) == false)
            try #expect(await fixture.base.exists(secret))
        }
    }

    @Test("deleting through a symlinked directory that leaves the root is rejected")
    func deleteThroughEscapedDirectory() async throws {
        try await withSandbox { fixture in
            try makeSymlink(at: fixture.root.appending("out"), to: fixture.outside.string)
            await #expect(throws: DoMoError.self) {
                try await fixture.sandboxed.delete("out/secret.txt", recursive: false, force: false)
            }
            try #expect(await fixture.base.exists(fixture.outside.appending("secret.txt")))
        }
    }

    @Test("metadata on an outward symlink inside the root reports the link itself")
    func metadataOnOutwardLink() async throws {
        try await withSandbox { fixture in
            let link = fixture.root.appending("escape.txt")
            try makeSymlink(at: link, to: fixture.outside.appending("secret.txt").string)
            try #expect(await fixture.sandboxed.metadata(link).kind == .symlink)
        }
    }
}

// MARK: - Time of check, time of use

/// A filesystem that lets a test run arbitrary damage between a sandbox's
/// resolution and the write it authorized. This is the attacker in a TOCTOU
/// race, made deterministic.
private struct RacingFileSystem: FileSystem {

    let base: POSIXFileSystem
    let beforeWrite: @Sendable () -> Void

    var workingDirectory: FilePath { base.workingDirectory }

    func absolutePath(_ path: FilePath) -> FilePath { base.absolutePath(path) }

    @concurrent
    func canonicalPath(
        _ path: FilePath,
        allowingMissingComponents: Bool
    ) async throws(DoMoError) -> FilePath {
        try await base.canonicalPath(path, allowingMissingComponents: allowingMissingComponents)
    }

    @concurrent
    func read(_ path: FilePath) async throws(DoMoError) -> Data {
        try await base.read(path)
    }

    @concurrent
    func readPrefix(_ path: FilePath, maximumBytes: Int) async throws(DoMoError) -> Data {
        try await base.readPrefix(path, maximumBytes: maximumBytes)
    }

    @concurrent
    func write(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        beforeWrite()
        try await base.write(path, contents)
    }

    @concurrent
    func append(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        try await base.append(path, contents)
    }

    @concurrent
    func exists(_ path: FilePath) async throws(DoMoError) -> Bool {
        try await base.exists(path)
    }

    @concurrent
    func metadata(_ path: FilePath) async throws(DoMoError) -> FileMetadata {
        try await base.metadata(path)
    }

    @concurrent
    func createDirectory(_ path: FilePath, recursive: Bool) async throws(DoMoError) {
        try await base.createDirectory(path, recursive: recursive)
    }

    @concurrent
    func delete(_ path: FilePath, recursive: Bool, force: Bool) async throws(DoMoError) {
        try await base.delete(path, recursive: recursive, force: force)
    }

    @concurrent
    func list(_ path: FilePath) async throws(DoMoError) -> [FileMetadata] {
        try await base.list(path)
    }
}

@Suite("PathSandbox time-of-check/time-of-use")
struct PathSandboxRaceTests {

    @Test("every access re-resolves, so swapping a component is caught next call")
    func resolvesOnEveryAccess() async throws {
        try await withSandbox { fixture in
            let directory = fixture.root.appending("dir")
            try await fixture.base.createDirectory(directory)
            try await fixture.base.write(directory.appending("f.txt"), text: "inside")
            #expect(try await fixture.sandboxed.readText("dir/f.txt").text == "inside")

            // The path string is unchanged; only the filesystem moved underneath.
            try await fixture.base.delete(directory, recursive: true, force: false)
            try makeSymlink(at: directory, to: fixture.outside.string)

            await #expect(throws: DoMoError.self) {
                _ = try await fixture.sandboxed.read("dir/secret.txt")
            }
        }
    }

    @Test("a component swapped mid-write is caught by the post-write re-check")
    func postWriteVerification() async throws {
        try await withSandbox { fixture in
            let directory = fixture.root.appending("dir")
            try await fixture.base.createDirectory(directory)

            let outside = fixture.outside
            let racing = RacingFileSystem(base: fixture.base) {
                // Exactly the race the sandbox cannot prevent: between resolve
                // and write, `dir` stops being a directory inside the root.
                try? FileManager.default.removeItem(atPath: directory.string)
                try? FileManager.default.createSymbolicLink(
                    atPath: directory.string,
                    withDestinationPath: outside.string
                )
            }
            let sandboxed = SandboxedFileSystem(base: racing, sandbox: fixture.sandboxed.sandbox)

            await #expect(throws: DoMoError.self) {
                try await sandboxed.write("dir/planted.txt", text: "x")
            }
            // The escape still happened — the point is that it is now reported
            // rather than silent.
            try #expect(await fixture.base.exists(outside.appending("planted.txt")))
        }
    }
}
