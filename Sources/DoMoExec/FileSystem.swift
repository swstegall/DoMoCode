// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/env/nodejs.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The capability surface, the `FileKind`/`FileInfo` shapes, the path-resolution
// rules and the "missing path is `false`, not an error" contract on `exists` are
// ported from `packages/agent/src/harness/env/nodejs.ts` and the `FileSystem`
// interface in `packages/agent/src/harness/types.ts`. Text handling — BOM strip
// and restore, line-ending detection and restore — is ported from
// `packages/coding-agent/src/core/tools/edit-diff.ts`; image magic sniffing from
// `packages/coding-agent/src/utils/mime.ts`; display sanitization from
// `sanitizeBinaryOutput` in `packages/coding-agent/src/utils/shell.ts`; and the
// per-path mutation lock from
// `packages/coding-agent/src/core/tools/file-mutation-queue.ts`.

import DoMoCore
import Foundation
import SystemPackage

// MARK: - Metadata

/// What a path names, without following symlinks.
///
/// A symlink is its own kind rather than being reported as whatever it points
/// at. pi makes the same choice (`lstat`, never `stat`) and it is the only
/// choice that keeps a walker honest: a directory symlink reported as
/// `.directory` is an invitation to descend into a cycle, and a symlink leaf
/// reported as `.file` is how a write escapes a sandbox.
public enum FileKind: String, Sendable, Hashable, Codable, CaseIterable {
    case file
    case directory
    case symlink
}

/// Filesystem identity — the `(device, inode)` pair.
///
/// Path equality cannot answer "have I already walked this directory?" once
/// symlinks are followed, because the same inode is reachable under unboundedly
/// many names. ``FileWalker`` compares identities instead, which is what makes
/// its loop detection exact rather than heuristic.
public struct FileIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Metadata for one filesystem object, as addressed — symlinks are not followed.
public struct FileMetadata: Sendable, Hashable {
    /// The absolute path this metadata was read from. Not canonicalized; use
    /// ``FileSystem/canonicalPath(_:)`` when identity across links matters.
    public let path: FilePath
    public let kind: FileKind
    public let size: Int64
    public let modified: Date
    /// `nil` only when the backend did not report device and inode numbers.
    public let identity: FileIdentity?

    public init(
        path: FilePath,
        kind: FileKind,
        size: Int64,
        modified: Date,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.identity = identity
    }

    /// The basename, falling back to the whole path for a root path.
    public var name: String { path.lastComponent?.string ?? path.string }
}

// MARK: - Protocol

/// The one seam through which DoMoCode touches the filesystem.
///
/// ## Typed throws, not `Result`
///
/// pi's `ExecutionEnv` is contractually forbidden from throwing: *"Operation
/// methods must never throw or reject. All filesystem failures, including
/// unexpected backend failures, must be encoded in the returned `Result`."*
/// That rule is right, and it exists because TypeScript cannot express it any
/// other way. A `Promise<T>` says nothing about rejection, `throws` is not part
/// of a TypeScript signature, and no compiler will tell a caller it forgot the
/// failure path — so the only way to make failure part of the contract is to
/// move it into the return type, and then police "never throws" by review.
///
/// Swift has the feature TypeScript is emulating. `throws(DoMoError)` *is* the
/// closed-failure contract, checked by the compiler rather than by a comment:
/// nothing else can escape, and `catch` is exhaustive over ``DoMoError/Kind``
/// with no `default:`. Mirroring pi and returning `Result<T, DoMoError>` would
/// buy the identical guarantee while giving up `try`, giving up `defer`-based
/// cleanup ordering, and forcing every caller in the tool layer to unwrap by
/// hand — and `Result` composes especially badly with `async`, since there is no
/// `flatMap` that awaits.
///
/// The one property pi's rule protects that typed throws does *not* give for
/// free is cancellation: `Task.checkCancellation()` throws `CancellationError`,
/// which is not a `DoMoError`. Implementations must therefore convert it, and
/// every failure that is really an interrupt arrives as ``DoMoError/Kind/cancelled``
/// — see ``DoMoError/isCancellation``.
///
/// ## Isolation
///
/// Every requirement is `@concurrent` because this protocol is a module seam:
/// under `NonisolatedNonsendingByDefault` a plain `nonisolated async func` runs
/// on its caller's actor, and the caller here is frequently the main-actor TUI.
/// Blocking file I/O on the render loop is the failure this annotation prevents.
public protocol FileSystem: Sendable {

    /// The directory relative paths resolve against.
    var workingDirectory: FilePath { get }

    /// Makes a path absolute without touching the disk.
    ///
    /// Expands a leading `~`, accepts a `file://` URL, joins relative paths onto
    /// ``workingDirectory``, and lexically normalizes the result. Ported from
    /// pi's `resolvePath`.
    ///
    /// Lexical normalization removes `.` and `..` *textually*, which is not a
    /// containment check — see ``PathSandbox``.
    func absolutePath(_ path: FilePath) -> FilePath

    /// Resolves every symlink in the path, yielding a path with no links,
    /// no `.` and no `..` left in it.
    ///
    /// - Parameter allowingMissingComponents: when `true`, resolution stops at
    ///   the first component that does not exist and appends the rest verbatim.
    ///   This is the case that matters for writes: a new file — and any parent
    ///   directories the write will create — has no realpath of its own, but the
    ///   deepest existing ancestor does, and that ancestor is what a sandbox
    ///   check needs. Appending the missing tail verbatim is safe precisely
    ///   because a path not on disk can hold no symlinks.
    @concurrent
    func canonicalPath(_ path: FilePath, allowingMissingComponents: Bool) async throws(DoMoError) -> FilePath

    @concurrent
    func read(_ path: FilePath) async throws(DoMoError) -> Data

    /// Reads at most `maximumBytes` from the head of a file.
    ///
    /// Content classification needs a few kilobytes, not a few gigabytes; a
    /// coding agent that reads whole files just to decide they are binary has
    /// already lost.
    @concurrent
    func readPrefix(_ path: FilePath, maximumBytes: Int) async throws(DoMoError) -> Data

    /// Writes `contents`, creating intermediate directories. Ported from pi,
    /// which `mkdir -p`s the parent on every write.
    @concurrent
    func write(_ path: FilePath, _ contents: Data) async throws(DoMoError)

    @concurrent
    func append(_ path: FilePath, _ contents: Data) async throws(DoMoError)

    /// Whether the path exists, without following a final symlink.
    ///
    /// A missing path is `false`, not a failure; anything else — a permission
    /// denial on a parent directory, most usefully — still throws. Ported from
    /// pi, whose `exists` has exactly this asymmetry.
    @concurrent
    func exists(_ path: FilePath) async throws(DoMoError) -> Bool

    @concurrent
    func metadata(_ path: FilePath) async throws(DoMoError) -> FileMetadata

    @concurrent
    func createDirectory(_ path: FilePath, recursive: Bool) async throws(DoMoError)

    /// - Parameters:
    ///   - recursive: delete a non-empty directory. Without it a non-empty
    ///     directory fails with `ENOTEMPTY`.
    ///   - force: a missing path succeeds instead of failing.
    @concurrent
    func delete(_ path: FilePath, recursive: Bool, force: Bool) async throws(DoMoError)

    /// Directory entries, not recursive, symlinks unresolved. Entries whose kind
    /// is not file/directory/symlink — sockets, devices, fifos — are skipped
    /// rather than failing the listing, as in pi's `listDir`.
    @concurrent
    func list(_ path: FilePath) async throws(DoMoError) -> [FileMetadata]
}

extension FileSystem {

    public func canonicalPath(_ path: FilePath) async throws(DoMoError) -> FilePath {
        try await canonicalPath(path, allowingMissingComponents: false)
    }

    public func createDirectory(_ path: FilePath) async throws(DoMoError) {
        try await createDirectory(path, recursive: true)
    }

    public func delete(_ path: FilePath) async throws(DoMoError) {
        try await delete(path, recursive: false, force: false)
    }

    public func write(_ path: FilePath, text: String) async throws(DoMoError) {
        try await write(path, Data(text.utf8))
    }

    public func append(_ path: FilePath, text: String) async throws(DoMoError) {
        try await append(path, Data(text.utf8))
    }

    /// Reads a file and says what it is: text, a supported image, or bytes that
    /// must not reach a model's context.
    public func readContents(_ path: FilePath) async throws(DoMoError) -> FileContents {
        let bytes = try await read(path)
        switch FileContentProbe.classify(bytes) {
        case .text:
            return .text(try FileContentProbe.decode(bytes, path: path))
        case .image(let mediaType):
            return .image(mediaType: mediaType, bytes: bytes)
        case .binary(let reason):
            return .binary(bytes: bytes, reason: reason)
        }
    }

    /// Reads a file that is expected to be text, failing loudly if it is not.
    ///
    /// The failure is the point. `read` in pi decodes any byte sequence as UTF-8
    /// and hands the result to the model; a 400 KB ELF binary then arrives as a
    /// wall of U+FFFD that costs real tokens and teaches the model nothing.
    public func readText(_ path: FilePath) async throws(DoMoError) -> DecodedText {
        let bytes = try await read(path)
        switch FileContentProbe.classify(bytes) {
        case .text:
            return try FileContentProbe.decode(bytes, path: path)
        case .image(let mediaType):
            throw DoMoError(
                .file(path: path, errno: nil),
                "read \(path): file is an image (\(mediaType)), not text"
            )
        case .binary(let reason):
            throw DoMoError(
                .file(path: path, errno: nil),
                "read \(path): file is binary (\(reason.description)), not text"
            )
        }
    }
}

// MARK: - POSIX implementation

/// The only ``FileSystem`` that touches a real disk.
///
/// Built on `FileManager` and `Data` rather than on raw `open`/`read`: this
/// target is compiled with `.strictMemorySafety()`, and every byte-buffer syscall
/// wrapper costs an `unsafe` annotation whose only purpose would be to silence
/// the diagnostic. The price is that failures arrive as `NSError` and the
/// `errno` has to be dug back out of the underlying-error chain — see
/// ``DoMoError/file(mapping:path:while:)``.
///
/// A `struct`, and stateless apart from ``workingDirectory``, so `Sendable` is
/// structural and two tools can hold one without coordinating.
public struct POSIXFileSystem: FileSystem {

    public let workingDirectory: FilePath

    /// The directory a leading `~` expands to. Injectable because tests must be
    /// able to exercise tilde expansion without depending on the runner's home.
    public let homeDirectory: FilePath

    public init(
        workingDirectory: FilePath = FilePath(FileManager.default.currentDirectoryPath),
        homeDirectory: FilePath = FilePath(NSHomeDirectory())
    ) {
        self.workingDirectory = workingDirectory
        self.homeDirectory = homeDirectory
    }

    // MARK: Paths

    public func absolutePath(_ path: FilePath) -> FilePath {
        var candidate = path

        if let stripped = Self.strippingFileURLScheme(candidate) {
            candidate = stripped
        } else if candidate.string == "~" {
            candidate = homeDirectory
        } else if candidate.string.hasPrefix("~/") {
            candidate = homeDirectory.appending(String(candidate.string.dropFirst(2)))
        }

        if candidate.isRelative {
            candidate = workingDirectory.pushing(candidate)
        }
        return candidate.lexicallyNormalized()
    }

    /// Accepts the `file://` URLs pi accepts, and — as pi does — leaves a
    /// malformed one alone rather than failing, so a path that merely looks like
    /// a URL still resolves as an ordinary path.
    ///
    /// The prefix tested is `file:/`, not `file://`, because `FilePath` collapses
    /// runs of separators on construction: by the time a `file:///etc/hosts`
    /// argument reaches here it reads `file:/etc/hosts`.
    private static func strippingFileURLScheme(_ path: FilePath) -> FilePath? {
        guard path.string.hasPrefix("file:/") else { return nil }
        guard let url = URL(string: path.string), url.isFileURL, !url.path.isEmpty else {
            return nil
        }
        return FilePath(url.path)
    }

    /// The number of symlinks followed before declaring a loop.
    ///
    /// Matches the conventional `MAXSYMLINKS`. A loop must terminate here rather
    /// than in the kernel because the resolution below is done component by
    /// component in user space, so nothing else is counting.
    private static let maximumSymlinkHops = 40

    public func canonicalPath(
        _ path: FilePath,
        allowingMissingComponents: Bool
    ) async throws(DoMoError) -> FilePath {
        let absolute = absolutePath(path)
        // `absolutePath` already normalized lexically, which is safe here only
        // because the walk below re-derives every component against the real
        // filesystem; the normalized form is used purely to split the input.
        var pending = Array(absolute.components.map(\.string).reversed())
        var resolved = FilePath("/")
        var hops = 0

        while let component = pending.popLast() {
            try Self.checkCancellation()
            switch component {
            case ".":
                continue
            case "..":
                // Correct only because `resolved` is already link-free: popping a
                // component of a canonical path names the real parent, whereas
                // popping one of an unresolved path can name a directory that is
                // nowhere near where the kernel would have gone.
                resolved.removeLastComponent()
                continue
            default:
                break
            }

            let candidate = resolved.appending(component)
            let info: FileMetadata?
            do {
                info = try await metadata(candidate)
            } catch let error {
                guard case .file(_, let errno) = error.kind,
                    errno == .noSuchFileOrDirectory || errno == .notDirectory
                else { throw error }
                info = nil
            }

            guard let info else {
                guard allowingMissingComponents else {
                    throw DoMoError.file(
                        .noSuchFileOrDirectory,
                        path: candidate,
                        while: "resolve"
                    )
                }
                // The first component that does not exist ends resolution: a
                // path that is not on disk holds no symlinks, so the remaining
                // components are safe to append verbatim. This is what lets a
                // sandbox check a write whose parent directories will be created
                // by the write itself — `write` in pi `mkdir -p`s the tail.
                var result = candidate
                while let next = pending.popLast() {
                    switch next {
                    case ".": continue
                    case "..": result.removeLastComponent()
                    default: result.append(next)
                    }
                }
                return result
            }

            guard info.kind == .symlink else {
                resolved = candidate
                continue
            }

            hops += 1
            guard hops <= Self.maximumSymlinkHops else {
                throw DoMoError.file(.tooManySymbolicLinkLevels, path: candidate, while: "resolve")
            }

            let target = try Self.mapping(candidate, "read link") {
                FilePath(try FileManager.default.destinationOfSymbolicLink(atPath: candidate.string))
            }
            // An absolute target restarts resolution at the root; a relative one
            // is spliced in ahead of whatever is left, exactly as the kernel does.
            if target.isAbsolute {
                resolved = FilePath("/")
            }
            pending.append(contentsOf: target.components.map(\.string).reversed())
        }

        return resolved
    }

    // MARK: Reads

    public func read(_ path: FilePath) async throws(DoMoError) -> Data {
        try Self.checkCancellation()
        return try Self.mapping(path, "read") {
            try Data(contentsOf: URL(fileURLWithPath: path.string))
        }
    }

    public func readPrefix(_ path: FilePath, maximumBytes: Int) async throws(DoMoError) -> Data {
        guard maximumBytes > 0 else { return Data() }
        try Self.checkCancellation()
        return try Self.mapping(path, "read") {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
            defer { try? handle.close() }
            return try handle.read(upToCount: maximumBytes) ?? Data()
        }
    }

    // MARK: Writes

    public func write(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        try Self.checkCancellation()
        try await createParentDirectory(of: path)
        try Self.checkCancellation()
        try Self.mapping(path, "write") {
            try contents.write(to: URL(fileURLWithPath: path.string))
        }
    }

    public func append(_ path: FilePath, _ contents: Data) async throws(DoMoError) {
        try Self.checkCancellation()
        try await createParentDirectory(of: path)
        guard try await exists(path) else {
            try Self.mapping(path, "append") {
                try contents.write(to: URL(fileURLWithPath: path.string))
            }
            return
        }
        try Self.mapping(path, "append") {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path.string))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: contents)
        }
    }

    private func createParentDirectory(of path: FilePath) async throws(DoMoError) {
        var parent = path
        parent.removeLastComponent()
        guard !parent.isEmpty, parent.string != path.string else { return }
        try await createDirectory(parent, recursive: true)
    }

    // MARK: Metadata

    public func exists(_ path: FilePath) async throws(DoMoError) -> Bool {
        do {
            _ = try await metadata(path)
            return true
        } catch let error {
            if case .file(_, let errno) = error.kind,
                errno == .noSuchFileOrDirectory || errno == .notDirectory
            {
                return false
            }
            throw error
        }
    }

    public func metadata(_ path: FilePath) async throws(DoMoError) -> FileMetadata {
        try Self.checkCancellation()
        let attributes = try Self.mapping(path, "stat") {
            // `attributesOfItem` is an `lstat`: a symlink reports
            // `NSFileTypeSymbolicLink` rather than its target's type, which is
            // the behavior every caller here depends on.
            try FileManager.default.attributesOfItem(atPath: path.string)
        }
        guard let metadata = Self.metadata(path: path, attributes: attributes) else {
            throw DoMoError(
                .file(path: path, errno: .invalidArgument),
                "stat \(path): unsupported file type"
            )
        }
        return metadata
    }

    private static func metadata(
        path: FilePath,
        attributes: [FileAttributeKey: Any]
    ) -> FileMetadata? {
        let kind: FileKind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: kind = .file
        case .typeDirectory: kind = .directory
        case .typeSymbolicLink: kind = .symlink
        default: return nil
        }
        let identity: FileIdentity?
        if let device = attributes[.systemNumber] as? UInt64,
            let inode = attributes[.systemFileNumber] as? UInt64
        {
            identity = FileIdentity(device: device, inode: inode)
        } else {
            identity = nil
        }
        return FileMetadata(
            path: path,
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0),
            identity: identity
        )
    }

    // MARK: Directories

    public func createDirectory(_ path: FilePath, recursive: Bool) async throws(DoMoError) {
        try Self.checkCancellation()
        try Self.mapping(path, "create directory") {
            try FileManager.default.createDirectory(
                atPath: path.string,
                withIntermediateDirectories: recursive
            )
        }
    }

    public func delete(
        _ path: FilePath,
        recursive: Bool,
        force: Bool
    ) async throws(DoMoError) {
        try Self.checkCancellation()
        let info: FileMetadata
        do {
            info = try await metadata(path)
        } catch let error {
            if force, case .file(_, let errno) = error.kind,
                errno == .noSuchFileOrDirectory || errno == .notDirectory
            {
                return
            }
            throw error
        }
        // `removeItem` is always recursive, so a non-recursive delete has to
        // refuse a populated directory itself to keep pi's `rm` semantics.
        if info.kind == .directory, !recursive, try await !list(path).isEmpty {
            throw DoMoError.file(.directoryNotEmpty, path: path, while: "delete")
        }
        try Self.mapping(path, "delete") {
            try FileManager.default.removeItem(atPath: path.string)
        }
    }

    public func list(_ path: FilePath) async throws(DoMoError) -> [FileMetadata] {
        try Self.checkCancellation()
        let names = try Self.mapping(path, "list") {
            try FileManager.default.contentsOfDirectory(atPath: path.string)
        }
        var entries: [FileMetadata] = []
        entries.reserveCapacity(names.count)
        for name in names.sorted() {
            try Self.checkCancellation()
            let child = path.appending(name)
            do {
                entries.append(try await metadata(child))
            } catch let error {
                // A vanished entry and an unsupported type are both "not part of
                // the listing", matching pi, which drops entries it cannot turn
                // into a `FileInfo`. Anything else is a real failure.
                guard case .file(_, let errno) = error.kind,
                    errno == .noSuchFileOrDirectory || errno == .invalidArgument
                else { throw error }
            }
        }
        return entries
    }

    // MARK: Failure conversion

    private static func checkCancellation() throws(DoMoError) {
        guard Task.isCancelled else { return }
        throw DoMoError(.cancelled, "filesystem operation cancelled")
    }

    private static func mapping<T>(
        _ path: FilePath?,
        _ action: String,
        _ body: () throws -> T
    ) throws(DoMoError) -> T {
        do {
            return try body()
        } catch {
            throw DoMoError.file(mapping: error, path: path, while: action)
        }
    }
}

// MARK: - Foundation error conversion

extension DoMoError {

    /// Recovers a POSIX `errno` from a Foundation failure.
    ///
    /// `FileManager` and `Data` report failures as `NSCocoaErrorDomain`, which
    /// collapses distinctions the tool layer needs — `ENOTDIR` and `ENOENT` both
    /// surface as `fileReadNoSuchFile`, and ``FileSystem/exists(_:)`` has to tell
    /// "missing" from "denied" to honor its contract. The real number is usually
    /// still there, one level down under `NSUnderlyingErrorKey`, so that chain is
    /// walked first and the Cocoa code is only a fallback.
    static func file(mapping error: any Error, path: FilePath?, while action: String) -> DoMoError {
        if DoMoError.isCancellation(error) {
            return DoMoError(.cancelled, "\(action) cancelled", cause: error)
        }
        if let domo = error as? DoMoError { return domo }

        guard let errno = posixErrno(of: error) ?? cocoaErrno(of: error) else {
            let target = path.map { " \($0)" } ?? ""
            return DoMoError(
                .file(path: path, errno: nil),
                "\(action)\(target)",
                cause: error
            )
        }
        return DoMoError.file(errno, path: path, while: action)
    }

    private static func posixErrno(of error: any Error) -> Errno? {
        var next: NSError? = error as NSError
        var depth = 0
        while let current = next, depth < 8 {
            if current.domain == NSPOSIXErrorDomain {
                return Errno(rawValue: CInt(current.code))
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    private static func cocoaErrno(of error: any Error) -> Errno? {
        guard let cocoa = error as? CocoaError else { return nil }
        switch cocoa.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .noSuchFileOrDirectory
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .permissionDenied
        case .fileWriteFileExists:
            return .fileExists
        case .fileReadInvalidFileName, .fileWriteInvalidFileName:
            return .invalidArgument
        case .fileWriteOutOfSpace:
            return .noSpace
        case .fileWriteVolumeReadOnly:
            return .readOnlyFileSystem
        default:
            return nil
        }
    }
}

// MARK: - Content classification

/// What a file turned out to contain.
public enum FileContents: Sendable {
    case text(DecodedText)
    case image(mediaType: String, bytes: Data)
    case binary(bytes: Data, reason: BinaryReason)
}

/// Why a byte sequence was judged unfit for a model's context.
public enum BinaryReason: Sendable, Hashable, CustomStringConvertible {
    /// A NUL byte appeared in the sniff window.
    case embeddedNUL
    /// The bytes are not valid text in any encoding this type recognizes.
    case undecodable
    /// Decoding succeeded but produced enough replacement characters that the
    /// result would be noise.
    case lossy

    public var description: String {
        switch self {
        case .embeddedNUL: return "contains NUL bytes"
        case .undecodable: return "not decodable as text"
        case .lossy: return "mostly undecodable bytes"
        }
    }
}

/// How a text file's bytes map to characters.
public enum TextEncoding: Sendable, Hashable {
    case utf8
    case utf16(bigEndian: Bool)
    case utf32(bigEndian: Bool)
}

/// The line terminator a file uses.
public enum LineEnding: Sendable, Hashable {
    case lf
    case crlf

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        }
    }
}

/// A text file's contents plus everything needed to write it back unchanged.
///
/// The three carried facts — BOM, encoding, line ending — exist because an edit
/// tool must not silently rewrite them. pi learned this in `edit.ts`: it strips
/// the BOM before matching (*"the model will not include an invisible BOM in
/// oldText"*), normalizes CRLF to LF for matching, and then restores both before
/// writing. Skipping that turns a three-line edit into a whole-file diff.
public struct DecodedText: Sendable, Hashable {

    /// The text, with any BOM removed and line endings left as they were.
    public let text: String
    public let encoding: TextEncoding
    public let hasByteOrderMark: Bool
    /// The file's dominant line ending: whichever form the *first* terminator
    /// uses. Ported from pi's `detectLineEnding`, which compares the index of the
    /// first `\r\n` against the first `\n`.
    public let lineEnding: LineEnding
    /// Whether decoding had to substitute U+FFFD for malformed bytes.
    public let isLossy: Bool

    public init(
        text: String,
        encoding: TextEncoding,
        hasByteOrderMark: Bool,
        lineEnding: LineEnding,
        isLossy: Bool
    ) {
        self.text = text
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = lineEnding
        self.isLossy = isLossy
    }

    /// ``text`` with every terminator collapsed to `\n`, which is the form a
    /// matcher or a differ should work in. Ported from `normalizeToLF`.
    public var normalizedToLF: String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Re-encodes LF-normalized replacement text into the file's original shape:
    /// original BOM, original line endings, original encoding. Ported from the
    /// `bom + restoreLineEndings(newContent, originalEnding)` step in `edit.ts`.
    public func reencoding(_ replacement: String) -> Data {
        var restored = replacement
        if lineEnding == .crlf {
            restored = restored.replacingOccurrences(of: "\n", with: "\r\n")
        }
        if hasByteOrderMark {
            restored = "\u{FEFF}" + restored
        }
        switch encoding {
        case .utf8:
            return Data(restored.utf8)
        case .utf16(let bigEndian):
            return restored.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian) ?? Data()
        case .utf32(let bigEndian):
            return restored.data(using: bigEndian ? .utf32BigEndian : .utf32LittleEndian) ?? Data()
        }
    }
}

/// Decides whether bytes are text, a supported image, or neither.
///
/// pi has no explicit binary check: `read` sniffs for an image and otherwise
/// calls `buffer.toString("utf-8")`, which never fails and happily produces a
/// page of U+FFFD. The image sniffing here is a direct port of `mime.ts`,
/// including its refusal of animated PNGs and its BMP header validation. The
/// NUL-byte test is a deliberate addition, taken from git's `buffer_is_binary`,
/// because a lossily-decoded object file in a context window is expensive
/// nonsense and the model has no way to tell it was not the file's real content.
public enum FileContentProbe {

    /// pi's `IMAGE_TYPE_SNIFF_BYTES`.
    public static let imageSniffLength = 4100

    /// git's binary-detection window (`FIRST_FEW_BYTES`).
    public static let binarySniffLength = 8000

    /// Above this share of replacement characters, decoded text is treated as
    /// binary. Well-formed UTF-8 with the occasional bad byte stays readable;
    /// a compiled object decodes to almost nothing else.
    public static let maximumReplacementRatio = 0.1

    public enum Classification: Sendable, Hashable {
        case text(TextEncoding)
        case image(mediaType: String)
        case binary(BinaryReason)
    }

    public static func classify(_ bytes: Data) -> Classification {
        if let mediaType = imageMediaType(bytes) {
            return .image(mediaType: mediaType)
        }
        if let encoding = byteOrderMark(bytes)?.encoding {
            return .text(encoding)
        }
        let window = [UInt8](bytes.prefix(binarySniffLength))
        if window.contains(0) {
            return .binary(.embeddedNUL)
        }
        guard let text = decodeUTF8(bytes) else {
            return .binary(.undecodable)
        }
        return isMostlyReplacement(text) ? .binary(.lossy) : .text(.utf8)
    }

    /// Decodes bytes already believed to be text.
    public static func decode(_ bytes: Data, path: FilePath? = nil) throws(DoMoError) -> DecodedText {
        let mark = byteOrderMark(bytes)
        let encoding = mark?.encoding ?? .utf8
        let body = bytes.dropFirst(mark?.length ?? 0)

        let text: String
        var lossy = false
        switch encoding {
        case .utf8:
            let strict = String(data: body, encoding: .utf8)
            lossy = strict == nil
            text = strict ?? String(decoding: body, as: UTF8.self)
        case .utf16(let bigEndian):
            guard
                let decoded = String(
                    data: body,
                    encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian
                )
            else {
                throw DoMoError(
                    .file(path: path, errno: .illegalByteSequence),
                    "decode \(path.map(\.description) ?? "text"): invalid UTF-16"
                )
            }
            text = decoded
        case .utf32(let bigEndian):
            guard
                let decoded = String(
                    data: body,
                    encoding: bigEndian ? .utf32BigEndian : .utf32LittleEndian
                )
            else {
                throw DoMoError(
                    .file(path: path, errno: .illegalByteSequence),
                    "decode \(path.map(\.description) ?? "text"): invalid UTF-32"
                )
            }
            text = decoded
        }

        return DecodedText(
            text: text,
            encoding: encoding,
            hasByteOrderMark: mark != nil,
            lineEnding: lineEnding(of: text),
            isLossy: lossy
        )
    }

    /// The first terminator wins. Ported from pi's `detectLineEnding`.
    ///
    /// Scans scalars, not `Character`s, and this is not a stylistic choice:
    /// Swift's grapheme breaking makes `"\r\n"` a *single* `Character`, so
    /// `firstIndex(of: "\n")` skips right over every CRLF in the file and reports
    /// the first lone LF instead — which is the opposite answer.
    public static func lineEnding(of text: String) -> LineEnding {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == "\n" { return previous == "\r" ? .crlf : .lf }
            previous = scalar
        }
        return .lf
    }

    /// Removes characters that break terminal width measurement or corrupt a
    /// transcript: C0 controls other than tab/newline/carriage-return, and the
    /// U+FFF9–U+FFFB interlinear annotation marks. Ported verbatim in intent
    /// from pi's `sanitizeBinaryOutput`.
    public static func sanitizedForDisplay(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    switch scalar.value {
                    case 0x09, 0x0A, 0x0D: return true
                    case 0x00...0x1F: return false
                    case 0xFFF9...0xFFFB: return false
                    default: return true
                    }
                }
            )
        )
    }

    // MARK: BOM

    private struct ByteOrderMark {
        let encoding: TextEncoding
        let length: Int
    }

    /// UTF-32's marks must be tested before UTF-16's: `FF FE 00 00` starts with
    /// the UTF-16LE mark, so checking in the other order misreads a UTF-32LE file
    /// as UTF-16LE text beginning with a NUL.
    private static func byteOrderMark(_ bytes: Data) -> ByteOrderMark? {
        let head = [UInt8](bytes.prefix(4))
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return ByteOrderMark(encoding: .utf32(bigEndian: false), length: 4)
        }
        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return ByteOrderMark(encoding: .utf32(bigEndian: true), length: 4)
        }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) {
            return ByteOrderMark(encoding: .utf8, length: 3)
        }
        if head.starts(with: [0xFF, 0xFE]) {
            return ByteOrderMark(encoding: .utf16(bigEndian: false), length: 2)
        }
        if head.starts(with: [0xFE, 0xFF]) {
            return ByteOrderMark(encoding: .utf16(bigEndian: true), length: 2)
        }
        return nil
    }

    private static func decodeUTF8(_ bytes: Data) -> String? {
        if let strict = String(data: bytes, encoding: .utf8) { return strict }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isMostlyReplacement(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var replacements = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar == "\u{FFFD}" { replacements += 1 }
        }
        return Double(replacements) / Double(total) > maximumReplacementRatio
    }

    // MARK: Image magic

    /// The supported image types, ported from pi's `detectSupportedImageMimeType`.
    public static func imageMediaType(_ bytes: Data) -> String? {
        let head = [UInt8](bytes.prefix(imageSniffLength))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            // 0xF7 is a lossless JPEG (SOF55); pi rejects it because the image
            // pipeline downstream cannot decode it.
            return head.count > 3 && head[3] == 0xF7 ? nil : "image/jpeg"
        }
        if head.starts(with: pngSignature) {
            return isPNG(head) && !isAnimatedPNG(head) ? "image/png" : nil
        }
        if matchesASCII(head, at: 0, "GIF") {
            return "image/gif"
        }
        if matchesASCII(head, at: 0, "RIFF"), matchesASCII(head, at: 8, "WEBP") {
            return "image/webp"
        }
        if matchesASCII(head, at: 0, "BM"), isBMP(head) {
            return "image/bmp"
        }
        return nil
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func isPNG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 16
            && readUInt32BigEndian(bytes, at: pngSignature.count) == 13
            && matchesASCII(bytes, at: 12, "IHDR")
    }

    /// An APNG is rejected because only its first frame would survive the
    /// resize-and-attach path, which is a silent lie about what was read.
    private static func isAnimatedPNG(_ bytes: [UInt8]) -> Bool {
        var offset = pngSignature.count
        while offset + 8 <= bytes.count {
            guard let chunkLength = readUInt32BigEndian(bytes, at: offset) else { return false }
            let typeOffset = offset + 4
            if matchesASCII(bytes, at: typeOffset, "acTL") { return true }
            if matchesASCII(bytes, at: typeOffset, "IDAT") { return false }
            let next = offset + 8 + Int(chunkLength) + 4
            if next <= offset || next > bytes.count { return false }
            offset = next
        }
        return false
    }

    /// `BM` alone is two extremely common bytes, so pi validates the DIB header
    /// before believing it. Without this, any text file starting "BM" would be
    /// attached as an image.
    private static func isBMP(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 26 else { return false }
        guard let declaredSize = readUInt32LittleEndian(bytes, at: 2),
            let pixelOffset = readUInt32LittleEndian(bytes, at: 10),
            let headerSize = readUInt32LittleEndian(bytes, at: 14)
        else { return false }
        if declaredSize != 0 && declaredSize < 26 { return false }
        if pixelOffset < 14 + headerSize { return false }
        if declaredSize != 0 && pixelOffset >= declaredSize { return false }

        let planes: UInt16
        let bitsPerPixel: UInt16
        if headerSize == 12 {
            guard let p = readUInt16LittleEndian(bytes, at: 22),
                let b = readUInt16LittleEndian(bytes, at: 24)
            else { return false }
            planes = p
            bitsPerPixel = b
        } else if headerSize >= 40 && headerSize <= 124 {
            guard bytes.count >= 30,
                let p = readUInt16LittleEndian(bytes, at: 26),
                let b = readUInt16LittleEndian(bytes, at: 28)
            else { return false }
            planes = p
            bitsPerPixel = b
        } else {
            return false
        }
        return planes == 1 && [1, 4, 8, 16, 24, 32].contains(bitsPerPixel)
    }

    private static func matchesASCII(_ bytes: [UInt8], at offset: Int, _ text: String) -> Bool {
        let expected = Array(text.utf8)
        guard offset >= 0, offset + expected.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }

    private static func readUInt32BigEndian(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func readUInt32LittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt16LittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}

// MARK: - Mutation coordinator

/// Serializes mutations that target the same file.
///
/// Two tool calls in one assistant turn can name the same file — pi's parallel
/// tool execution makes this routine — and read-modify-write is what `edit` does,
/// so interleaving them loses one of the edits with no error anywhere. pi solves
/// it with a `Map<string, Promise<void>>` chained per canonical path; an actor
/// holding the same map is the Swift shape, and it is an actor rather than a
/// `Mutex` precisely because the critical section is `await`-ing real I/O.
///
/// The key is the canonical path, so `./src/a.ts`, `/repo/src/a.ts` and a symlink
/// pointing at either all serialize against each other. For a path that does not
/// exist yet the lexically absolute path is the key instead, which is pi's
/// fallback on `ENOENT`/`ENOTDIR`.
///
/// Waiting is deliberately *not* cancellable. pi's `edit.ts` carries the reason:
/// *"Do not reject from an abort event listener here: that would release the
/// mutation queue while an in-flight filesystem operation may still finish."*
/// Cancellation is observed inside `body`, between `await`s, where the file is
/// in a known state.
public actor FileMutationCoordinator {

    private let fileSystem: any FileSystem
    /// Key present means held. The array is the FIFO of waiters behind it, so a
    /// long queue on one file cannot starve the task that arrived first.
    private var waiters: [FilePath: [CheckedContinuation<Void, Never>]] = [:]

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    /// Runs `body` with exclusive access to `path`, releasing the lock even if
    /// `body` throws.
    ///
    /// `throws(any Error)` rather than `throws(DoMoError)` on purpose: `body`
    /// belongs to the caller and may fail in its own vocabulary. Widening here is
    /// the documented exception in ``DoMoError`` — a signature spanning two error
    /// domains cannot be typed, and narrowing would force callers to pre-wrap.
    public func withMutation<T: Sendable>(
        of path: FilePath,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let key = await key(for: path)
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    /// The canonical path, or the lexically absolute path when the file does not
    /// exist yet — a write and the edit that follows it must land on one key.
    private func key(for path: FilePath) async -> FilePath {
        if let canonical = try? await fileSystem.canonicalPath(path, allowingMissingComponents: true) {
            return canonical
        }
        return fileSystem.absolutePath(path)
    }

    private func acquire(_ key: FilePath) async {
        guard waiters[key] != nil else {
            waiters[key] = []
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: FilePath) {
        guard var queue = waiters[key] else { return }
        guard !queue.isEmpty else {
            waiters[key] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue
        next.resume()
    }
}
