// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage
import Synchronization
import DoMoExec
import Testing

// MARK: - Fixtures

/// Byte patterns the sniffer accepts, and some it must not.
enum ImageBytes {

    /// A 16-byte PNG: the 8-byte signature, an `IHDR` chunk length of 13, then
    /// the `IHDR` tag — exactly what `isPNG` requires, with no `acTL`.
    static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ])

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    static let gif = Data("GIF89a".utf8) + Data([0x01, 0x00, 0x01, 0x00])

    static let webp = Data("RIFF".utf8) + Data([0x1A, 0, 0, 0]) + Data("WEBPVP8 ".utf8)

    /// A lossless JPEG (SOF55), which the pipeline downstream cannot decode and
    /// the sniffer therefore refuses.
    static let losslessJPEG = Data([0xFF, 0xD8, 0xFF, 0xF7, 0x00, 0x10])

    /// An MP4 `ftyp` box. Named `.png` in the tests below, to prove the sniff is
    /// by content and not by extension.
    static let mp4 = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypmp42".utf8)

    static let text = Data("hello, this is not an image\n".utf8)

    /// A PNG padded out to `bytes` total, so a size limit has something to bite.
    static func png(paddedTo bytes: Int) -> Data {
        precondition(bytes >= png.count)
        return png + Data(repeating: 0x00, count: bytes - png.count)
    }
}

/// Records which filesystem operations a loader performed, so a test can assert
/// what was NOT done — that an oversized file was never read, most importantly.
final class FileSystemCallLog: Sendable {

    private let entries = Mutex<[String]>([])

    func record(_ operation: String, _ path: FilePath) {
        entries.withLock { $0.append("\(operation):\(path.string)") }
    }

    var all: [String] { entries.withLock { $0 } }

    func count(_ operation: String) -> Int {
        all.count { $0.hasPrefix("\(operation):") }
    }
}

/// An in-memory ``FileSystem``.
///
/// Everything the image loader needs is a lie a test can tell: a file whose
/// stat says 4 GB without allocating one, a file that grows between the stat and
/// the read, a file that exists but refuses to be read. None of that is
/// expressible against a real temp directory, which is why the loader is written
/// against the seam rather than against `Data(contentsOf:)`.
struct StubFileSystem: FileSystem {

    enum Node: Sendable {
        case file(Data)
        /// Reports `size` from `metadata` but hands `bytes` to a reader — a file
        /// that lied, or one that changed underneath.
        case sized(size: Int64, bytes: Data)
        /// Stats as a regular file of `size`, then fails every read.
        case denied(size: Int64)
        case directory
        case symlink(String)
    }

    let nodes: [String: Node]
    let log: FileSystemCallLog
    let workingDirectory: FilePath
    let homeDirectory: FilePath

    /// Whether every operation checks `Task.isCancelled` first and throws
    /// `DoMoError(.cancelled,)`, exactly as `POSIXFileSystem.checkCancellation`
    /// does. Off by default so the rest of the suite is unaffected; a loader
    /// tested only against a stub that ignores cancellation cannot be shown to
    /// handle it.
    let checksCancellation: Bool

    /// Called at the start of every operation, BEFORE the cancellation check, so
    /// a test can change the world — cancel the running task, most usefully — at
    /// an exact point in a batch instead of racing it.
    let onOperation: @Sendable (String, FilePath) -> Void

    init(
        nodes: [String: Node],
        log: FileSystemCallLog = FileSystemCallLog(),
        workingDirectory: FilePath = "/work",
        homeDirectory: FilePath = "/home/sam",
        checksCancellation: Bool = false,
        onOperation: @escaping @Sendable (String, FilePath) -> Void = { _, _ in }
    ) {
        self.checksCancellation = checksCancellation
        self.onOperation = onOperation
        // Ancestors are implied, so a test names only the files it cares about.
        var filled = nodes
        for key in nodes.keys {
            var path = FilePath(key)
            while path.removeLastComponent(), !path.components.isEmpty {
                if filled[path.string] == nil { filled[path.string] = .directory }
            }
        }
        self.nodes = filled
        self.log = log
        self.workingDirectory = workingDirectory
        self.homeDirectory = homeDirectory
    }

    /// Delegated so the stub and the real filesystem agree, byte for byte, about
    /// `~` expansion and `file://` stripping — the two places a drop arrives.
    func absolutePath(_ path: FilePath) -> FilePath {
        POSIXFileSystem(workingDirectory: workingDirectory, homeDirectory: homeDirectory)
            .absolutePath(path)
    }

    /// The hook and the cancellation check every operation runs first.
    private func begin(_ operation: String, _ path: FilePath) throws(DoMoError) {
        onOperation(operation, path)
        guard checksCancellation, Task.isCancelled else { return }
        throw DoMoError(.cancelled, "filesystem operation cancelled")
    }

    @concurrent
    func canonicalPath(
        _ path: FilePath,
        allowingMissingComponents: Bool
    ) async throws(DoMoError) -> FilePath {
        try begin("canonicalPath", path)
        var pending = Array(absolutePath(path).components.map(\.string).reversed())
        var resolved = FilePath("/")
        var hops = 0

        while let component = pending.popLast() {
            switch component {
            case ".": continue
            case "..":
                resolved.removeLastComponent()
                continue
            default: break
            }
            let candidate = resolved.appending(component)
            guard let node = nodes[candidate.string] else {
                guard allowingMissingComponents else {
                    throw DoMoError.file(.noSuchFileOrDirectory, path: candidate, while: "resolve")
                }
                var result = candidate
                while let next = pending.popLast() { result.append(next) }
                return result
            }
            guard case .symlink(let target) = node else {
                resolved = candidate
                continue
            }
            hops += 1
            guard hops <= 40 else {
                throw DoMoError.file(.tooManySymbolicLinkLevels, path: candidate, while: "resolve")
            }
            let destination = FilePath(target)
            if destination.isAbsolute { resolved = FilePath("/") }
            pending.append(contentsOf: destination.components.map(\.string).reversed())
        }
        return resolved
    }

    private func node(at path: FilePath) throws(DoMoError) -> Node {
        guard let node = nodes[path.string] else {
            throw DoMoError.file(.noSuchFileOrDirectory, path: path, while: "stat")
        }
        return node
    }

    private func bytes(at path: FilePath) throws(DoMoError) -> Data {
        switch try node(at: path) {
        case .file(let data): return data
        case .sized(_, let data): return data
        case .denied: throw DoMoError.file(.permissionDenied, path: path, while: "read")
        case .directory: throw DoMoError.file(.isDirectory, path: path, while: "read")
        case .symlink: throw DoMoError.file(.tooManySymbolicLinkLevels, path: path, while: "read")
        }
    }

    @concurrent
    func read(_ path: FilePath) async throws(DoMoError) -> Data {
        log.record("read", path)
        try begin("read", path)
        return try bytes(at: path)
    }

    @concurrent
    func readPrefix(_ path: FilePath, maximumBytes: Int) async throws(DoMoError) -> Data {
        log.record("readPrefix", path)
        try begin("readPrefix", path)
        return try bytes(at: path).prefix(maximumBytes)
    }

    @concurrent
    func metadata(_ path: FilePath) async throws(DoMoError) -> FileMetadata {
        log.record("metadata", path)
        try begin("metadata", path)
        let kind: FileKind
        let size: Int64
        switch try node(at: path) {
        case .file(let data):
            kind = .file
            size = Int64(data.count)
        case .sized(let declared, _):
            kind = .file
            size = declared
        case .denied(let declared):
            kind = .file
            size = declared
        case .directory:
            kind = .directory
            size = 0
        case .symlink:
            kind = .symlink
            size = 0
        }
        return FileMetadata(
            path: path,
            kind: kind,
            size: size,
            modified: Date(timeIntervalSince1970: 0)
        )
    }

    @concurrent
    func exists(_ path: FilePath) async throws(DoMoError) -> Bool {
        nodes[absolutePath(path).string] != nil
    }

    @concurrent
    func write(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        throw DoMoError.file(.notSupported, path: path, while: "write")
    }

    @concurrent
    func append(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        throw DoMoError.file(.notSupported, path: path, while: "append")
    }

    @concurrent
    func createDirectory(_ path: FilePath, recursive: Bool) async throws(DoMoError) {
        throw DoMoError.file(.notSupported, path: path, while: "mkdir")
    }

    @concurrent
    func delete(_ path: FilePath, recursive: Bool, force: Bool) async throws(DoMoError) {
        throw DoMoError.file(.notSupported, path: path, while: "delete")
    }

    @concurrent
    func list(_ path: FilePath) async throws(DoMoError) -> [FileMetadata] {
        throw DoMoError.file(.notSupported, path: path, while: "list")
    }
}

private func reason(
    _ result: Result<LoadedImage, ImageAttachmentRejection>
) -> ImageAttachmentRejection.Reason? {
    guard case .failure(let rejection) = result else { return nil }
    return rejection.reason
}

// MARK: - One image

@Suite("ImageAttachmentLoader.load")
struct ImageAttachmentLoadTests {

    @Test("a PNG loads with its sniffed media type and its exact bytes")
    func loadsPNG() async throws {
        let fs = StubFileSystem(nodes: ["/pics/shot.png": .file(ImageBytes.png)])
        let image = try #require(try? await ImageAttachmentLoader.load("/pics/shot.png", using: fs).get())
        #expect(image.path == "/pics/shot.png")
        #expect(image.displayName == "shot.png")
        #expect(image.mediaType == "image/png")
        #expect(image.data == ImageBytes.png)
        #expect(image.byteCount == ImageBytes.png.count)
    }

    @Test(
        "every supported format is recognized by its magic bytes",
        arguments: [
            (ImageBytes.png, "image/png"),
            (ImageBytes.jpeg, "image/jpeg"),
            (ImageBytes.gif, "image/gif"),
            (ImageBytes.webp, "image/webp"),
        ]
    )
    func sniffsFormats(_ bytes: Data, _ mediaType: String) async {
        let fs = StubFileSystem(nodes: ["/a/f.bin": .file(bytes)])
        let result = await ImageAttachmentLoader.load("/a/f.bin", using: fs)
        #expect((try? result.get())?.mediaType == mediaType)
    }

    @Test("a .png that is really a video is rejected on its bytes, not its name")
    func sniffsByContentNotExtension() async {
        let fs = StubFileSystem(nodes: ["/a/movie.png": .file(ImageBytes.mp4)])
        #expect(reason(await ImageAttachmentLoader.load("/a/movie.png", using: fs)) == .notAnImage)
    }

    @Test("a lossless JPEG is refused like any other unsupported format")
    func refusesLosslessJPEG() async {
        let fs = StubFileSystem(nodes: ["/a/scan.jpg": .file(ImageBytes.losslessJPEG)])
        #expect(reason(await ImageAttachmentLoader.load("/a/scan.jpg", using: fs)) == .notAnImage)
    }

    @Test("a text file is not an image")
    func rejectsText() async {
        let fs = StubFileSystem(nodes: ["/a/notes.txt": .file(ImageBytes.text)])
        #expect(reason(await ImageAttachmentLoader.load("/a/notes.txt", using: fs)) == .notAnImage)
    }

    @Test("an empty file is not an image")
    func rejectsEmptyFile() async {
        let fs = StubFileSystem(nodes: ["/a/empty.png": .file(Data())])
        #expect(reason(await ImageAttachmentLoader.load("/a/empty.png", using: fs)) == .notAnImage)
    }

    @Test("a directory is not a regular file")
    func rejectsDirectory() async {
        let fs = StubFileSystem(nodes: ["/a": .directory, "/a/pics": .directory])
        #expect(reason(await ImageAttachmentLoader.load("/a/pics", using: fs)) == .notARegularFile)
    }

    @Test("a missing path is missing, not unreadable")
    func rejectsMissing() async {
        let fs = StubFileSystem(nodes: [:])
        #expect(reason(await ImageAttachmentLoader.load("/a/gone.png", using: fs)) == .missing)
    }

    @Test("a file that exists but cannot be read is unreadable")
    func rejectsUnreadable() async {
        let fs = StubFileSystem(nodes: ["/a": .directory, "/a/locked.png": .denied(size: 16)])
        #expect(reason(await ImageAttachmentLoader.load("/a/locked.png", using: fs)) == .unreadable)
    }

    @Test("an oversized file is refused from its stat and never read")
    func refusesOversizedWithoutReading() async {
        // Four gigabytes, declared. If the loader read before it checked, this
        // test would be the one that noticed — and in production it would be a
        // four-gigabyte allocation on a drop.
        let fs = StubFileSystem(
            nodes: ["/a": .directory, "/a/huge.png": .sized(size: 4 << 30, bytes: ImageBytes.png)]
        )
        let result = await ImageAttachmentLoader.load(
            "/a/huge.png",
            using: fs,
            maximumBytes: 5 << 20
        )
        #expect(reason(result) == .tooLarge(bytes: 4 << 30, limit: 5 << 20))
        #expect(fs.log.count("metadata") >= 1)
        #expect(fs.log.count("readPrefix") == 0)
        #expect(fs.log.count("read") == 0)
    }

    @Test("a non-image is refused after the 4100-byte sniff, never read whole")
    func sniffsBeforeReadingWhole() async {
        let fs = StubFileSystem(
            nodes: ["/a/blob.png": .sized(size: 1 << 20, bytes: Data(repeating: 0x41, count: 8192))]
        )
        #expect(reason(await ImageAttachmentLoader.load("/a/blob.png", using: fs)) == .notAnImage)
        #expect(fs.log.count("readPrefix") == 1)
        #expect(fs.log.count("read") == 0)
    }

    @Test("a file that grows between the stat and the read is caught by the re-check")
    func rechecksSizeAfterReading() async {
        // The stat promises 16 bytes; the read delivers 2 MiB.
        let fs = StubFileSystem(
            nodes: ["/a/grows.png": .sized(size: 16, bytes: ImageBytes.png(paddedTo: 2 << 20))]
        )
        let result = await ImageAttachmentLoader.load(
            "/a/grows.png",
            using: fs,
            maximumBytes: 1 << 20
        )
        #expect(reason(result) == .tooLarge(bytes: 2 << 20, limit: 1 << 20))
    }

    @Test("a size exactly at the limit is accepted; one byte more is not")
    func boundaryIsInclusive() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/at.png": .file(ImageBytes.png(paddedTo: 1024)),
                "/a/over.png": .file(ImageBytes.png(paddedTo: 1025)),
            ]
        )
        #expect((try? await ImageAttachmentLoader.load("/a/at.png", using: fs, maximumBytes: 1024).get()) != nil)
        #expect(
            reason(await ImageAttachmentLoader.load("/a/over.png", using: fs, maximumBytes: 1024))
                == .tooLarge(bytes: 1025, limit: 1024)
        )
    }

    @Test("a symlink resolves to its target, but keeps the dropped name on the chip")
    func followsSymlink() async throws {
        let fs = StubFileSystem(
            nodes: [
                "/pics": .directory,
                "/pics/2026-07-28.png": .file(ImageBytes.png),
                "/pics/latest.png": .symlink("/pics/2026-07-28.png"),
            ]
        )
        let image = try #require(try? await ImageAttachmentLoader.load("/pics/latest.png", using: fs).get())
        #expect(image.path == "/pics/2026-07-28.png")
        #expect(image.displayName == "latest.png")
    }

    @Test("a tilde path expands against the injected home directory")
    func expandsTilde() async throws {
        let fs = StubFileSystem(
            nodes: ["/home/sam": .directory, "/home/sam/shot.png": .file(ImageBytes.png)],
            homeDirectory: "/home/sam"
        )
        let image = try #require(try? await ImageAttachmentLoader.load("~/shot.png", using: fs).get())
        #expect(image.path == "/home/sam/shot.png")
    }

    @Test("a relative path resolves against the working directory")
    func expandsRelative() async throws {
        let fs = StubFileSystem(
            nodes: ["/work": .directory, "/work/shot.png": .file(ImageBytes.png)],
            workingDirectory: "/work"
        )
        let image = try #require(try? await ImageAttachmentLoader.load("shot.png", using: fs).get())
        #expect(image.path == "/work/shot.png")
    }

    @Test("a file: URL handed straight to the loader still resolves")
    func acceptsFileURL() async throws {
        let fs = StubFileSystem(nodes: ["/pics": .directory, "/pics/a.png": .file(ImageBytes.png)])
        let image = try #require(try? await ImageAttachmentLoader.load("file:///pics/a.png", using: fs).get())
        #expect(image.path == "/pics/a.png")
    }

    @Test("the rejection's path is the path as given, so the message names it")
    func rejectionEchoesTheGivenPath() async {
        let fs = StubFileSystem(nodes: [:])
        let result = await ImageAttachmentLoader.load("/a/gone.png", using: fs)
        guard case .failure(let rejection) = result else {
            Issue.record("expected a rejection")
            return
        }
        #expect(rejection.path == "/a/gone.png")
        #expect(rejection.displayName == "gone.png")
    }
}

// MARK: - Batches and limits

@Suite("ImageAttachmentLoader.loadAll")
struct ImageAttachmentLoadAllTests {

    private func manyPNGs(_ count: Int, bytesEach: Int = 16) -> [String: StubFileSystem.Node] {
        var nodes: [String: StubFileSystem.Node] = ["/pics": .directory]
        for index in 1...count {
            nodes["/pics/\(index).png"] = .file(ImageBytes.png(paddedTo: bytesEach))
        }
        return nodes
    }

    private func paths(_ count: Int) -> [FilePath] {
        (1...count).map { FilePath("/pics/\($0).png") }
    }

    @Test("three good files and one bad one attach three and explain one")
    func partialSuccess() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/1.png": .file(ImageBytes.png),
                "/a/2.png": .file(ImageBytes.jpeg),
                "/a/3.png": .file(ImageBytes.gif),
                "/a/notes.txt": .file(ImageBytes.text),
            ]
        )
        let result = await ImageAttachmentLoader.loadAll(
            ["/a/1.png", "/a/notes.txt", "/a/2.png", "/a/3.png"],
            using: fs
        )
        #expect(result.loaded.count == 3)
        #expect(result.rejected.count == 1)
        #expect(result.rejected.first?.reason == .notAnImage)
        #expect(result.isCompleteSuccess == false)
        // Order is the order the caller gave, minus the rejections.
        #expect(result.loaded.map(\.displayName) == ["1.png", "2.png", "3.png"])
    }

    @Test("ten images against a limit of eight attach eight and refuse two")
    func countLimit() async {
        let fs = StubFileSystem(nodes: manyPNGs(10))
        let result = await ImageAttachmentLoader.loadAll(
            paths(10),
            using: fs,
            limits: ImageAttachmentLimits(maximumCount: 8)
        )
        #expect(result.loaded.count == 8)
        #expect(result.rejected.count == 2)
        #expect(result.rejected.allSatisfy { $0.reason == .countLimitReached(limit: 8) })
        #expect(result.rejected.first?.message.contains("at most 8 images") == true)
    }

    @Test("attachments already staged count against the count limit")
    func alreadyLoadedCountsAgainstCount() async {
        let fs = StubFileSystem(nodes: manyPNGs(4))
        let staged = LoadedImage(
            path: "/elsewhere/old.png",
            displayName: "old.png",
            mediaType: "image/png",
            data: ImageBytes.png
        )
        let result = await ImageAttachmentLoader.loadAll(
            paths(4),
            using: fs,
            limits: ImageAttachmentLimits(maximumCount: 3),
            alreadyLoaded: [staged]
        )
        #expect(result.loaded.count == 2)
        #expect(result.rejected.count == 2)
    }

    @Test("the running total stops the batch and names the total budget, not the per-image one")
    func totalBytesLimit() async {
        let fs = StubFileSystem(nodes: manyPNGs(4, bytesEach: 400))
        let result = await ImageAttachmentLoader.loadAll(
            paths(4),
            using: fs,
            limits: ImageAttachmentLimits(
                maximumCount: 8,
                maximumBytesPerImage: 1000,
                maximumTotalBytes: 1000
            )
        )
        #expect(result.loaded.count == 2)  // 400 + 400 fits; the third would be 1200
        #expect(result.rejected.count == 2)
        #expect(result.rejected.allSatisfy { $0.reason == .totalBytesExceeded(limit: 1000) })
        #expect(result.rejected.first?.message.contains("total limit") == true)
    }

    @Test("a file too big for ANY budget keeps the honest per-image reason")
    func perImageLimitIsNotRelabelled() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/big.png": .sized(size: 9_000, bytes: ImageBytes.png),
                "/a/ok.png": .file(ImageBytes.png(paddedTo: 100)),
            ]
        )
        let result = await ImageAttachmentLoader.loadAll(
            ["/a/big.png", "/a/ok.png"],
            using: fs,
            limits: ImageAttachmentLimits(
                maximumCount: 8,
                maximumBytesPerImage: 1_000,
                maximumTotalBytes: 100_000
            )
        )
        #expect(result.rejected.first?.reason == .tooLarge(bytes: 9_000, limit: 1_000))
        #expect(result.loaded.count == 1)  // the batch continues past a rejection
    }

    @Test("already-staged bytes count against the total budget")
    func alreadyLoadedCountsAgainstBytes() async {
        let fs = StubFileSystem(nodes: manyPNGs(1, bytesEach: 400))
        let staged = LoadedImage(
            path: "/elsewhere/old.png",
            displayName: "old.png",
            mediaType: "image/png",
            data: ImageBytes.png(paddedTo: 800)
        )
        let result = await ImageAttachmentLoader.loadAll(
            paths(1),
            using: fs,
            limits: ImageAttachmentLimits(maximumBytesPerImage: 1000, maximumTotalBytes: 1000),
            alreadyLoaded: [staged]
        )
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.first?.reason == .totalBytesExceeded(limit: 1000))
    }

    @Test("a symlink and its target attach once, with no rejection")
    func dedupesAcrossSymlinks() async {
        let fs = StubFileSystem(
            nodes: [
                "/pics": .directory,
                "/pics/real.png": .file(ImageBytes.png),
                "/pics/link.png": .symlink("/pics/real.png"),
            ]
        )
        let result = await ImageAttachmentLoader.loadAll(["/pics/link.png", "/pics/real.png"], using: fs)
        #expect(result.loaded.count == 1)
        #expect(result.rejected.isEmpty)
        #expect(result.isCompleteSuccess)
        // The first spelling wins the chip label.
        #expect(result.loaded.first?.displayName == "link.png")
        // The second spelling is a duplicate, not a failure and not a second image.
        #expect(result.skippedDuplicates == ["/pics/real.png"])
    }

    @Test("a path repeated in one drop attaches once and is not read twice")
    func dedupesIdenticalPaths() async {
        let fs = StubFileSystem(nodes: ["/a/x.png": .file(ImageBytes.png)])
        let result = await ImageAttachmentLoader.loadAll(["/a/x.png", "/a/x.png"], using: fs)
        #expect(result.loaded.count == 1)
        #expect(fs.log.count("read") == 1)
    }

    @Test("an already-staged image is not attached a second time, and says so")
    func dedupesAgainstAlreadyLoaded() async {
        let fs = StubFileSystem(nodes: ["/a/x.png": .file(ImageBytes.png)])
        let staged = LoadedImage(
            path: "/a/x.png",
            displayName: "x.png",
            mediaType: "image/png",
            data: ImageBytes.png
        )
        let result = await ImageAttachmentLoader.loadAll(["/a/x.png"], using: fs, alreadyLoaded: [staged])
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.isEmpty)
        // The skip is RECORDED. An empty result would be indistinguishable from
        // "this was not a drop", which is what makes the caller re-insert the
        // path as prompt text.
        #expect(result.skippedDuplicates == ["/a/x.png"])
        #expect(result.isCompleteSuccess)
    }

    @Test("a path repeated in one drop is recorded as the duplicate it is")
    func recordsRepeatedPathsAsDuplicates() async {
        let fs = StubFileSystem(nodes: ["/a/x.png": .file(ImageBytes.png)])
        let result = await ImageAttachmentLoader.loadAll(["/a/x.png", "/a/x.png"], using: fs)
        #expect(result.loaded.map(\.path) == ["/a/x.png"])
        #expect(result.skippedDuplicates == ["/a/x.png"])
        #expect(result.isCompleteSuccess)
    }

    @Test("no paths is an empty, non-successful result")
    func emptyBatch() async {
        let fs = StubFileSystem(nodes: [:])
        let result = await ImageAttachmentLoader.loadAll([], using: fs)
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.isEmpty)
        #expect(result.skippedDuplicates.isEmpty)
        // Nothing was asked for, so nothing succeeded: a duplicate is a success
        // only because a real image was named.
        #expect(result.isCompleteSuccess == false)
        #expect(result.byteCount == 0)
    }

    @Test("the unlimited preset refuses nothing on size or count")
    func unlimitedPreset() async {
        let fs = StubFileSystem(nodes: manyPNGs(12, bytesEach: 4096))
        let result = await ImageAttachmentLoader.loadAll(
            paths(12),
            using: fs,
            limits: .unlimited
        )
        #expect(result.loaded.count == 12)
        #expect(result.rejected.isEmpty)
        #expect(result.byteCount == 12 * 4096)
    }
}

// MARK: - Resolving a drop

@Suite("ImageAttachmentLoader.resolveDrop")
struct ImageAttachmentResolveDropTests {

    @Test("the whole-string reading wins when tokenizing shredded the name")
    func picksTheReadingThatExists() async {
        // Exactly what kitty sends for a file with a space in its name.
        let fs = StubFileSystem(
            nodes: ["/Users/x": .directory, "/Users/x/my pic.png": .file(ImageBytes.png)]
        )
        let candidates = DroppedPaths.candidates("/Users/x/my pic.png")
        let result = await ImageAttachmentLoader.resolveDrop(candidates: candidates, using: fs)
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.first?.displayName == "my pic.png")
    }

    @Test("a reading with one missing path loses to a later, complete one")
    func skipsIncompleteReadings() async {
        let fs = StubFileSystem(nodes: ["/a/b c.png": .file(ImageBytes.png)])
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: [["/a/b", "c.png"], ["/a/b c.png"]],
            using: fs
        )
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.map(\.path) == ["/a/b c.png"])
    }

    @Test("a literal %20 filename beats its decoded near-miss")
    func literalPercentWinsOverDecoded() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/my%20pic.png": .file(ImageBytes.png),
                "/a/my pic.png": .file(ImageBytes.jpeg),
            ]
        )
        let candidates = DroppedPaths.candidates("/a/my%20pic.png")
        let result = await ImageAttachmentLoader.resolveDrop(candidates: candidates, using: fs)
        #expect(result.loaded.first?.path == "/a/my%20pic.png")
    }

    @Test("the kitty percent-encoding bug is recovered when only the decoded name exists")
    func percentDecodedFallbackResolves() async {
        let fs = StubFileSystem(nodes: ["/a/my pic.png": .file(ImageBytes.png)])
        let candidates = DroppedPaths.candidates("/a/my%20pic.png")
        let result = await ImageAttachmentLoader.resolveDrop(candidates: candidates, using: fs)
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.first?.path == "/a/my pic.png")
    }

    @Test("when nothing resolves, the FIRST reading's rejection is the one reported")
    func reportsTheMostLikelyReading() async {
        let fs = StubFileSystem(nodes: [:])
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: [["/a/first.png"], ["/a/second.png"]],
            using: fs
        )
        #expect(result.isCompleteSuccess == false)
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.map(\.displayName) == ["first.png"])
        #expect(result.rejected.first?.reason == .missing)
    }

    @Test("no candidates is an empty, non-successful result")
    func noCandidates() async {
        let fs = StubFileSystem(nodes: [:])
        let result = await ImageAttachmentLoader.resolveDrop(candidates: [], using: fs)
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.isEmpty)
        #expect(result.isCompleteSuccess == false)
    }

    @Test("a partially-good reading is not 'complete', so a later reading still gets a turn")
    func partialIsNotComplete() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/one.png": .file(ImageBytes.png),
                "/a/one.png two.png": .file(ImageBytes.jpeg),
            ]
        )
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: [["/a/one.png", "two.png"], ["/a/one.png two.png"]],
            using: fs
        )
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.map(\.path) == ["/a/one.png two.png"])
    }

    @Test("a whole drop from a Terminal.app-shaped paste resolves end to end")
    func endToEndFromEscapedDrop() async {
        let fs = StubFileSystem(
            nodes: [
                "/Users/x/my pic.png": .file(ImageBytes.png),
                "/Users/x/b.png": .file(ImageBytes.jpeg),
            ]
        )
        let candidates = DroppedPaths.candidates(#"/Users/x/my\ pic.png /Users/x/b.png"#)
        let result = await ImageAttachmentLoader.resolveDrop(candidates: candidates, using: fs)
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.map(\.displayName) == ["my pic.png", "b.png"])
    }

    @Test("dropping a photo that is already attached is not a failed reading")
    func reDroppingAStagedImageSucceeds() async {
        let fs = StubFileSystem(nodes: ["/a/x.png": .file(ImageBytes.png)])
        let staged = LoadedImage(
            path: "/a/x.png",
            displayName: "x.png",
            mediaType: "image/png",
            data: ImageBytes.png
        )
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: DroppedPaths.candidates("/a/x.png"),
            using: fs,
            alreadyLoaded: [staged]
        )
        // The caller has two outcomes: attach, or hand the text back to the
        // prompt verbatim. An empty non-success would pick the second, and drag
        // the same photo in twice would type `/a/x.png` into the message.
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.isEmpty)
        #expect(result.rejected.isEmpty)
        #expect(result.skippedDuplicates == ["/a/x.png"])
    }

    @Test("a re-drop of one staged and one new photo attaches only the new one")
    func reDropOfAMixedSelection() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/x.png": .file(ImageBytes.png),
                "/a/y.png": .file(ImageBytes.jpeg),
            ]
        )
        let staged = LoadedImage(
            path: "/a/x.png",
            displayName: "x.png",
            mediaType: "image/png",
            data: ImageBytes.png
        )
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: [["/a/x.png", "/a/y.png"]],
            using: fs,
            alreadyLoaded: [staged]
        )
        #expect(result.isCompleteSuccess)
        #expect(result.loaded.map(\.path) == ["/a/y.png"])
        #expect(result.skippedDuplicates == ["/a/x.png"])
    }

    @Test("limits apply to a drop exactly as they do to a batch")
    func limitsApplyToDrops() async {
        let fs = StubFileSystem(
            nodes: [
                "/a/1.png": .file(ImageBytes.png),
                "/a/2.png": .file(ImageBytes.png),
            ]
        )
        let result = await ImageAttachmentLoader.resolveDrop(
            candidates: [["/a/1.png", "/a/2.png"]],
            using: fs,
            limits: ImageAttachmentLimits(maximumCount: 1)
        )
        #expect(result.loaded.count == 1)
        #expect(result.rejected.first?.reason == .countLimitReached(limit: 1))
    }
}

// MARK: - Cancellation

/// A gate a spawned task waits at before doing any work, so a test can cancel
/// it FIRST. Without it the child races the `cancel()` call and the test is
/// only usually right.
private final class TaskGate: Sendable {
    private let opened = Mutex(false)
    func open() { opened.withLock { $0 = true } }
    func wait() async { while !opened.withLock({ $0 }) { await Task.yield() } }
}

/// Holds the task under test so a filesystem operation can cancel it at an
/// exact point in a batch.
private final class CancelBox: Sendable {
    private let handle = Mutex<Task<ImageAttachmentLoadResult, Never>?>(nil)
    func arm(_ task: Task<ImageAttachmentLoadResult, Never>) { handle.withLock { $0 = task } }
    func cancel() { handle.withLock { $0 }?.cancel() }
    func waitUntilArmed() async {
        while handle.withLock({ $0 }) == nil { await Task.yield() }
    }
}

/// `POSIXFileSystem` checks `Task.isCancelled` before every read and stat and
/// throws `DoMoError(.cancelled,)`. That arrives at the loader looking exactly
/// like a permission failure, and a loader that classifies it as one turns a
/// cancelled eight-image drop into eight "could not be read" notices. These
/// tests use `checksCancellation: true`, because a stub that ignores
/// cancellation cannot show any of this.
@Suite("ImageAttachmentLoader cancellation")
struct ImageAttachmentCancellationTests {

    private static let threePNGs: [String: StubFileSystem.Node] = [
        "/a/1.png": .file(ImageBytes.png),
        "/a/2.png": .file(ImageBytes.png),
        "/a/3.png": .file(ImageBytes.png),
    ]

    @Test("a batch cancelled before it starts does nothing and says nothing")
    func cancelledBeforeStart() async {
        let gate = TaskGate()
        let fs = StubFileSystem(nodes: Self.threePNGs, checksCancellation: true)
        let task = Task {
            await gate.wait()
            return await ImageAttachmentLoader.loadAll(
                ["/a/1.png", "/a/2.png", "/a/3.png"],
                using: fs
            )
        }
        task.cancel()
        gate.open()
        let result = await task.value

        #expect(result.wasCancelled)
        // The bug this pins: three bogus `.unreadable` rejections, one per file.
        #expect(result.rejected.isEmpty)
        #expect(result.loaded.isEmpty)
        #expect(result.isCompleteSuccess == false)
        // And it stopped, rather than walking the rest of the batch.
        #expect(fs.log.all.isEmpty)
    }

    @Test("the batch stops on cancellation even when the filesystem never notices")
    func cancelledAgainstAFilesystemThatDoesNotCheck() async {
        // `checksCancellation` is OFF: every read succeeds, so nothing throws
        // and there is no error to classify. The loop itself has to look. This
        // is the case the original suite could not see, because its only
        // filesystem was this one.
        let gate = TaskGate()
        let fs = StubFileSystem(nodes: Self.threePNGs)
        let task = Task {
            await gate.wait()
            return await ImageAttachmentLoader.loadAll(
                ["/a/1.png", "/a/2.png", "/a/3.png"],
                using: fs
            )
        }
        task.cancel()
        gate.open()
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(result.loaded.isEmpty)
        #expect(fs.log.count("read") == 0)
    }

    @Test("cancellation partway through keeps what was read and rejects nothing")
    func cancelledMidBatch() async {
        let box = CancelBox()
        let fs = StubFileSystem(
            nodes: Self.threePNGs,
            checksCancellation: true,
            onOperation: { _, path in
                if path.string == "/a/2.png" { box.cancel() }
            }
        )
        let task = Task {
            await box.waitUntilArmed()
            return await ImageAttachmentLoader.loadAll(
                ["/a/1.png", "/a/2.png", "/a/3.png"],
                using: fs
            )
        }
        box.arm(task)
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(result.loaded.map(\.path) == ["/a/1.png"])
        // `/a/2.png` was cancelled mid-`load`, which reaches the batch as an
        // ordinary rejection. It must not be shown as one.
        #expect(result.rejected.isEmpty)
        #expect(result.isCompleteSuccess == false)
        // `/a/3.png` was never touched.
        #expect(fs.log.count("read") == 1)
    }

    @Test("a cancelled drop is not resolved by a later reading")
    func cancelledDropStopsSearching() async {
        // Two readings, the second of which WOULD resolve completely. A
        // cancelled drop must not come back as a successful attachment of a file
        // the user was in the middle of taking back.
        let gate = TaskGate()
        let fs = StubFileSystem(nodes: ["/a/b c.png": .file(ImageBytes.png)])
        let task = Task {
            await gate.wait()
            return await ImageAttachmentLoader.resolveDrop(
                candidates: [["/a/b", "c.png"], ["/a/b c.png"]],
                using: fs
            )
        }
        task.cancel()
        gate.open()
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(result.rejected.isEmpty)
        #expect(result.loaded.isEmpty)
        #expect(result.isCompleteSuccess == false)
        #expect(fs.log.all.isEmpty)
    }

    @Test("an uncancelled batch on a cancellation-checking filesystem is unaffected")
    func uncancelledBatchIsNormal() async {
        let fs = StubFileSystem(nodes: Self.threePNGs, checksCancellation: true)
        let result = await ImageAttachmentLoader.loadAll(
            ["/a/1.png", "/a/2.png", "/a/3.png"],
            using: fs
        )
        #expect(result.wasCancelled == false)
        #expect(result.loaded.count == 3)
        #expect(result.isCompleteSuccess)
    }
}

// MARK: - Messages

@Suite("ImageAttachmentRejection messages")
struct ImageAttachmentMessageTests {

    @Test("every reason produces a one-line message the UI can show verbatim")
    func everyReasonHasAMessage() {
        let reasons: [ImageAttachmentRejection.Reason] = [
            .missing,
            .notARegularFile,
            .unreadable,
            .notAnImage,
            .tooLarge(bytes: 6 << 20, limit: 5 << 20),
            .countLimitReached(limit: 8),
            .totalBytesExceeded(limit: 10 << 20),
        ]
        for reason in reasons {
            let message = ImageAttachmentRejection(path: "/a/shot.tiff", reason: reason).message
            #expect(message.contains("shot.tiff"))
            #expect(message.contains("\n") == false)
            #expect(message.isEmpty == false)
        }
    }

    @Test("the --image flag's published wording is preserved")
    func preservesTheCLIWording() {
        let message = ImageAttachmentRejection(path: "/a/shot.tiff", reason: .notAnImage).message
        // Tests/DoMoCLITests/ImageAttachmentEndToEndTests asserts this substring
        // on stderr; it is the contract `--image` has published since it shipped.
        #expect(message.contains("not a supported image"))
        #expect(message.contains("PNG, JPEG, GIF, WebP, or BMP"))
    }

    @Test("sizes are formatted without a locale getting a vote")
    func formatsByteCounts() {
        #expect(LoadedImage.formattedByteCount(0) == "0 B")
        #expect(LoadedImage.formattedByteCount(1023) == "1023 B")
        #expect(LoadedImage.formattedByteCount(1024) == "1.0 KB")
        #expect(LoadedImage.formattedByteCount(1536) == "1.5 KB")
        #expect(LoadedImage.formattedByteCount(412 * 1024) == "412 KB")
        #expect(LoadedImage.formattedByteCount(1 << 20) == "1.0 MB")
        // Truncated, never rounded up: 1.19 MiB reads as 1.1 MB.
        #expect(LoadedImage.formattedByteCount((1 << 20) + 200 * 1024) == "1.1 MB")
        #expect(LoadedImage.formattedByteCount(5 << 20) == "5.0 MB")
        #expect(LoadedImage.formattedByteCount(4 << 30) == "4.0 GB")
    }

    @Test("the single-image message names the size and the limit")
    func tooLargeMessageIsSpecific() {
        let message = ImageAttachmentRejection(
            path: "/a/photo.png",
            reason: .tooLarge(bytes: 6 << 20, limit: 5 << 20)
        ).message
        #expect(message.contains("6.0 MB"))
        #expect(message.contains("5.0 MB"))
    }

    @Test("one image is not pluralized")
    func singularCountMessage() {
        let message = ImageAttachmentRejection(path: "/a/b.png", reason: .countLimitReached(limit: 1))
            .message
        #expect(message.contains("at most 1 image per message"))
    }
}

// MARK: - Isolation

@Suite("ImageAttachmentLoader isolation")
struct ImageAttachmentIsolationTests {

    /// Under `NonisolatedNonsendingByDefault` an unmarked `async func` runs on
    /// its caller's actor, so a 5 MiB read from a main-actor UI would land on
    /// the render loop. `@concurrent` is what stops that, and this test only
    /// proves the call is well-formed FROM the main actor — the annotation
    /// itself is checked by the compiler, not at runtime.
    @Test("the loader is callable from the main actor")
    @MainActor
    func callableFromMainActor() async {
        let fs = StubFileSystem(nodes: ["/a/x.png": .file(ImageBytes.png)])
        let result = await ImageAttachmentLoader.load("/a/x.png", using: fs)
        #expect((try? result.get()) != nil)
        let all = await ImageAttachmentLoader.loadAll(["/a/x.png"], using: fs)
        #expect(all.isCompleteSuccess)
        let drop = await ImageAttachmentLoader.resolveDrop(candidates: [["/a/x.png"]], using: fs)
        #expect(drop.isCompleteSuccess)
    }
}
