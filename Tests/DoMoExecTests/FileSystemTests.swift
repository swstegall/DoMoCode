// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage
import Testing

// MARK: - Shared fixtures

/// Runs `body` against a fresh, canonicalized temporary directory.
///
/// The canonicalization matters on macOS, where `NSTemporaryDirectory()` sits
/// under `/var`, itself a symlink to `/private/var`. A test that skips it is
/// testing the sandbox's rejection of its own root.
func withTemporaryDirectory<T>(
    _ body: (FilePath, POSIXFileSystem) async throws -> T
) async throws -> T {
    let manager = FileManager.default
    let raw = FilePath(NSTemporaryDirectory()).appending("domoexec-\(UUID().uuidString)")
    try manager.createDirectory(atPath: raw.string, withIntermediateDirectories: true)
    defer { try? manager.removeItem(atPath: raw.string) }
    let root = try await POSIXFileSystem().canonicalPath(raw)
    return try await body(root, POSIXFileSystem(workingDirectory: root))
}

func makeSymlink(at path: FilePath, to destination: String) throws {
    try FileManager.default.createSymbolicLink(atPath: path.string, withDestinationPath: destination)
}

func fileErrno(_ error: any Error) -> Errno? {
    guard let domo = error as? DoMoError, case .file(_, let errno) = domo.kind else { return nil }
    return errno
}

// MARK: - Paths

@Suite("POSIXFileSystem paths")
struct FileSystemPathTests {

    @Test("relative paths resolve against the working directory")
    func relativeResolution() {
        let fs = POSIXFileSystem(workingDirectory: "/work")
        #expect(fs.absolutePath("src/main.swift") == "/work/src/main.swift")
    }

    @Test("absolute paths are kept and lexically normalized")
    func absoluteNormalization() {
        let fs = POSIXFileSystem(workingDirectory: "/work")
        #expect(fs.absolutePath("/a/./b/../c") == "/a/c")
    }

    @Test("a leading tilde expands to the home directory")
    func tildeExpansion() {
        let fs = POSIXFileSystem(workingDirectory: "/work", homeDirectory: "/home/sam")
        #expect(fs.absolutePath("~") == "/home/sam")
        #expect(fs.absolutePath("~/notes.md") == "/home/sam/notes.md")
        // Only a leading `~/` is special; `~x` is an ordinary name.
        #expect(fs.absolutePath("~notes") == "/work/~notes")
    }

    @Test("file URLs are accepted, malformed ones stay literal")
    func fileURLs() {
        let fs = POSIXFileSystem(workingDirectory: "/work")
        #expect(fs.absolutePath("file:///etc/hosts") == "/etc/hosts")
        #expect(fs.absolutePath("notes/file.md") == "/work/notes/file.md")
    }
}

// MARK: - Basic operations

@Suite("POSIXFileSystem operations")
struct FileSystemOperationTests {

    @Test("write then read round-trips")
    func writeRead() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("hello.txt")
            try await fs.write(path, text: "hello\n")
            try #expect(await fs.read(path) == Data("hello\n".utf8))
        }
    }

    @Test("write creates missing parent directories")
    func writeCreatesParents() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("a").appending("b").appending("c.txt")
            try await fs.write(path, text: "x")
            try #expect(await fs.exists(path))
            try #expect(await fs.metadata(root.appending("a")).kind == .directory)
        }
    }

    @Test("append extends an existing file and creates a missing one")
    func append() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("log.txt")
            try await fs.append(path, text: "one\n")
            try await fs.append(path, text: "two\n")
            let text = try await fs.readText(path)
            #expect(text.text == "one\ntwo\n")
        }
    }

    @Test("readPrefix stops at the requested byte count")
    func readPrefix() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("big.txt")
            try await fs.write(path, text: String(repeating: "a", count: 10_000))
            try #expect(await fs.readPrefix(path, maximumBytes: 16).count == 16)
            try #expect(await fs.readPrefix(path, maximumBytes: 0).isEmpty)
        }
    }

    @Test("exists is false for a missing path, not an error")
    func existsMissing() async throws {
        try await withTemporaryDirectory { root, fs in
            try #expect(await fs.exists(root.appending("nope")) == false)
            // A missing *parent* is equally just "does not exist".
            try #expect(await fs.exists(root.appending("nope").appending("deeper")) == false)
        }
    }

    @Test("metadata reports the addressed object, not the symlink target")
    func metadataDoesNotFollow() async throws {
        try await withTemporaryDirectory { root, fs in
            let target = root.appending("target.txt")
            try await fs.write(target, text: "abcd")
            let link = root.appending("link.txt")
            try makeSymlink(at: link, to: target.string)

            try #expect(await fs.metadata(target).kind == .file)
            try #expect(await fs.metadata(target).size == 4)
            try #expect(await fs.metadata(link).kind == .symlink)
        }
    }

    @Test("list is sorted and reports symlinks as symlinks")
    func list() async throws {
        try await withTemporaryDirectory { root, fs in
            try await fs.write(root.appending("b.txt"), text: "b")
            try await fs.write(root.appending("a.txt"), text: "a")
            try await fs.createDirectory(root.appending("c"))
            try makeSymlink(at: root.appending("d"), to: "a.txt")

            let entries = try await fs.list(root)
            #expect(entries.map(\.name) == ["a.txt", "b.txt", "c", "d"])
            #expect(entries.map(\.kind) == [.file, .file, .directory, .symlink])
        }
    }

    @Test("delete refuses a populated directory unless recursive")
    func deleteDirectory() async throws {
        try await withTemporaryDirectory { root, fs in
            let directory = root.appending("tree")
            try await fs.write(directory.appending("x.txt"), text: "x")

            await #expect(throws: DoMoError.self) {
                try await fs.delete(directory, recursive: false, force: false)
            }
            try await fs.delete(directory, recursive: true, force: false)
            try #expect(await fs.exists(directory) == false)
        }
    }

    @Test("delete of a missing path fails, or succeeds when forced")
    func deleteMissing() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("ghost")
            await #expect(throws: DoMoError.self) {
                try await fs.delete(path, recursive: false, force: false)
            }
            try await fs.delete(path, recursive: false, force: true)
        }
    }

    @Test("deleting a symlink removes the link, not its target")
    func deleteSymlink() async throws {
        try await withTemporaryDirectory { root, fs in
            let target = root.appending("target.txt")
            try await fs.write(target, text: "keep me")
            let link = root.appending("link.txt")
            try makeSymlink(at: link, to: target.string)

            try await fs.delete(link, recursive: false, force: false)
            try #expect(await fs.exists(link) == false)
            try #expect(await fs.exists(target))
        }
    }

    @Test("a missing file surfaces ENOENT rather than an opaque failure")
    func errnoRecovery() async throws {
        try await withTemporaryDirectory { root, fs in
            await #expect(throws: DoMoError.self) {
                _ = try await fs.read(root.appending("absent"))
            }
            do {
                _ = try await fs.read(root.appending("absent"))
                Issue.record("expected a failure")
            } catch {
                #expect(fileErrno(error) == .noSuchFileOrDirectory)
            }
        }
    }

    @Test("cancellation surfaces as .cancelled, not as a file error")
    func cancellation() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("x.txt")
            try await fs.write(path, text: "x")
            let task = Task {
                // Cancelled before it starts, so the first checkpoint fires.
                try await Task.sleep(for: .seconds(10))
                return try await fs.read(path)
            }
            task.cancel()
            let result = await task.result
            #expect(throws: Error.self) { try result.get() }
        }
    }
}

// MARK: - Canonicalization

@Suite("POSIXFileSystem canonicalPath")
struct CanonicalPathTests {

    @Test("symlinks are resolved, `..` is applied after resolution")
    func resolvesSymlinks() async throws {
        try await withTemporaryDirectory { root, fs in
            try await fs.createDirectory(root.appending("real").appending("nested"))
            try makeSymlink(at: root.appending("link"), to: root.appending("real").string)

            let canonical = try await fs.canonicalPath(root.appending("link").appending("nested"))
            #expect(canonical == root.appending("real").appending("nested"))
        }
    }

    @Test("a chain of symlinks is followed to the end")
    func followsChains() async throws {
        try await withTemporaryDirectory { root, fs in
            try await fs.createDirectory(root.appending("end"))
            try makeSymlink(at: root.appending("b"), to: root.appending("end").string)
            try makeSymlink(at: root.appending("a"), to: root.appending("b").string)

            try #expect(await fs.canonicalPath(root.appending("a")) == root.appending("end"))
        }
    }

    @Test("a symlink loop fails instead of hanging")
    func detectsLoops() async throws {
        try await withTemporaryDirectory { root, fs in
            try makeSymlink(at: root.appending("x"), to: root.appending("y").string)
            try makeSymlink(at: root.appending("y"), to: root.appending("x").string)

            do {
                _ = try await fs.canonicalPath(root.appending("x"))
                Issue.record("expected a loop failure")
            } catch {
                #expect(fileErrno(error) == .tooManySymbolicLinkLevels)
            }
        }
    }

    @Test("a missing tail fails by default and is appended verbatim on request")
    func missingComponents() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("new.txt")
            await #expect(throws: DoMoError.self) {
                _ = try await fs.canonicalPath(path, allowingMissingComponents: false)
            }
            try #expect(await fs.canonicalPath(path, allowingMissingComponents: true) == path)
            // A whole missing tail — the parent directories a write would create
            // — resolves to its deepest existing ancestor plus the rest.
            try #expect(
                await fs.canonicalPath(
                    root.appending("gone").appending("new.txt"),
                    allowingMissingComponents: true
                ) == root.appending("gone").appending("new.txt")
            )
            // The existing prefix is still canonicalized through symlinks.
            try await fs.createDirectory(root.appending("real"))
            try makeSymlink(at: root.appending("link"), to: root.appending("real").string)
            try #expect(
                await fs.canonicalPath(
                    root.appending("link").appending("child").appending("leaf.txt"),
                    allowingMissingComponents: true
                ) == root.appending("real").appending("child").appending("leaf.txt")
            )
        }
    }
}

// MARK: - Content classification

@Suite("Content classification")
struct FileContentProbeTests {

    @Test("plain UTF-8 is text")
    func text() {
        #expect(FileContentProbe.classify(Data("let x = 1\n".utf8)) == .text(.utf8))
    }

    @Test("a NUL byte makes it binary")
    func nulByte() {
        var bytes = Data("ELF".utf8)
        bytes.append(0)
        bytes.append(contentsOf: Array("more".utf8))
        #expect(FileContentProbe.classify(bytes) == .binary(.embeddedNUL))
    }

    @Test("mostly-undecodable bytes are binary even without a NUL")
    func lossy() {
        let bytes = Data((0..<512).map { _ in UInt8.random(in: 0x80...0xFE) })
        #expect(FileContentProbe.classify(bytes) == .binary(.lossy))
    }

    @Test("PNG, GIF, WEBP and JPEG magic are recognized")
    func imageMagic() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        png.append(contentsOf: Array("IHDR".utf8))
        png.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(FileContentProbe.imageMediaType(png) == "image/png")

        #expect(FileContentProbe.imageMediaType(Data("GIF89a...".utf8)) == "image/gif")

        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        webp.append(contentsOf: Array("WEBP".utf8))
        #expect(FileContentProbe.imageMediaType(webp) == "image/webp")

        #expect(FileContentProbe.imageMediaType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        // pi refuses lossless JPEG (SOF55), whose image pipeline cannot read it.
        #expect(FileContentProbe.imageMediaType(Data([0xFF, 0xD8, 0xFF, 0xF7])) == nil)
    }

    @Test("an animated PNG is not offered as an image")
    func animatedPNG() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        png.append(contentsOf: Array("IHDR".utf8))
        png.append(contentsOf: [UInt8](repeating: 0, count: 13))
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x08])
        png.append(contentsOf: Array("acTL".utf8))
        png.append(contentsOf: [UInt8](repeating: 0, count: 12))
        #expect(FileContentProbe.imageMediaType(png) == nil)
    }

    @Test("a text file beginning \"BM\" is not mistaken for a bitmap")
    func bmpFalsePositive() {
        let source = Data("BM is a common way to start a sentence about bitmaps.\n".utf8)
        #expect(FileContentProbe.imageMediaType(source) == nil)
        #expect(FileContentProbe.classify(source) == .text(.utf8))
    }

    @Test("a UTF-8 BOM is detected, stripped, and restored on write-back")
    func byteOrderMark() throws {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(contentsOf: Array("alpha\n".utf8))
        let decoded = try FileContentProbe.decode(bytes)
        #expect(decoded.text == "alpha\n")
        #expect(decoded.hasByteOrderMark)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.reencoding("alpha\n") == bytes)
    }

    @Test("UTF-16 with a BOM decodes and round-trips")
    func utf16() throws {
        let bytes = try #require("héllo\n".data(using: .utf16LittleEndian).map {
            Data([0xFF, 0xFE]) + $0
        })
        let decoded = try FileContentProbe.decode(bytes)
        #expect(decoded.text == "héllo\n")
        #expect(decoded.encoding == .utf16(bigEndian: false))
        #expect(decoded.reencoding(decoded.text) == bytes)
    }

    @Test("the first terminator decides the line ending")
    func lineEndings() {
        #expect(FileContentProbe.lineEnding(of: "a\r\nb\n") == .crlf)
        #expect(FileContentProbe.lineEnding(of: "a\nb\r\n") == .lf)
        #expect(FileContentProbe.lineEnding(of: "no terminator") == .lf)
    }

    @Test("CRLF survives an edit round-trip")
    func crlfRoundTrip() throws {
        let decoded = try FileContentProbe.decode(Data("one\r\ntwo\r\n".utf8))
        #expect(decoded.lineEnding == .crlf)
        #expect(decoded.normalizedToLF == "one\ntwo\n")
        #expect(decoded.reencoding("one\nTWO\n") == Data("one\r\nTWO\r\n".utf8))
    }

    @Test("display sanitization drops controls but keeps tab and newline")
    func sanitize() {
        #expect(FileContentProbe.sanitizedForDisplay("a\u{0}b\u{1B}c\td\ne") == "abc\td\ne")
        #expect(FileContentProbe.sanitizedForDisplay("x\u{FFFA}y") == "xy")
    }

    @Test("readText refuses a binary file instead of decoding it lossily")
    func readTextRefusesBinary() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("a.out")
            try await fs.write(path, Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02]))
            await #expect(throws: DoMoError.self) { _ = try await fs.readText(path) }

            switch try await fs.readContents(path) {
            case .binary(_, let reason): #expect(reason == .embeddedNUL)
            default: Issue.record("expected binary contents")
            }
        }
    }
}

// MARK: - Mutation coordinator

private actor Overlap {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

@Suite("FileMutationCoordinator")
struct FileMutationCoordinatorTests {

    @Test("concurrent mutations of one file never overlap")
    func serializesSamePath() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("counter.txt")
            try await fs.write(path, text: "")
            let coordinator = FileMutationCoordinator(fileSystem: fs)
            let overlap = Overlap()

            await withTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        try? await coordinator.withMutation(of: path) {
                            await overlap.enter()
                            let existing = (try? await fs.readText(path).text) ?? ""
                            try await Task.sleep(for: .milliseconds(1))
                            try await fs.write(path, text: existing + "\(index)\n")
                            await overlap.leave()
                        }
                    }
                }
            }

            #expect(await overlap.peak == 1)
            let lines = try await fs.readText(path).text
                .split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.count == 16)
        }
    }

    @Test("mutations of different files run concurrently")
    func parallelDifferentPaths() async throws {
        try await withTemporaryDirectory { root, fs in
            let coordinator = FileMutationCoordinator(fileSystem: fs)
            let overlap = Overlap()

            await withTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    let path = root.appending("f\(index).txt")
                    group.addTask {
                        try? await coordinator.withMutation(of: path) {
                            await overlap.enter()
                            try await Task.sleep(for: .milliseconds(30))
                            await overlap.leave()
                        }
                    }
                }
            }

            #expect(await overlap.peak > 1)
        }
    }

    @Test("two names for one file share a lock")
    func canonicalKey() async throws {
        try await withTemporaryDirectory { root, fs in
            let target = root.appending("target.txt")
            try await fs.write(target, text: "")
            let link = root.appending("link.txt")
            try makeSymlink(at: link, to: target.string)

            let coordinator = FileMutationCoordinator(fileSystem: fs)
            let overlap = Overlap()

            await withTaskGroup(of: Void.self) { group in
                for path in [target, link, FilePath("target.txt")] {
                    group.addTask {
                        try? await coordinator.withMutation(of: path) {
                            await overlap.enter()
                            try await Task.sleep(for: .milliseconds(20))
                            await overlap.leave()
                        }
                    }
                }
            }

            #expect(await overlap.peak == 1)
        }
    }

    @Test("a throwing body still releases the lock")
    func releasesOnThrow() async throws {
        try await withTemporaryDirectory { root, fs in
            let path = root.appending("x.txt")
            let coordinator = FileMutationCoordinator(fileSystem: fs)
            struct Boom: Error {}

            await #expect(throws: Boom.self) {
                try await coordinator.withMutation(of: path) { throw Boom() }
            }
            let value = try await coordinator.withMutation(of: path) { 42 }
            #expect(value == 42)
        }
    }
}
