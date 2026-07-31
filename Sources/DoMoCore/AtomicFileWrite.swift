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

/// Replacing a file's contents in one step, without changing what the file *is*.
///
/// Not `Data.write(options: .atomic)`. Foundation's atomic write creates its
/// temp through `open(2)` at 0666, so under the usual umask the result is 0644 —
/// world-readable — and it **re-creates** the file on every write, so a user who
/// ran `chmod 600 settings.json` silently lost that the next time the harness
/// saved a permission grant. It also replaces a symlink with a regular file,
/// which quietly detaches a dotfiles-managed config from its repository.
///
/// So this preserves rather than imposes: an existing file keeps its mode, and a
/// symlinked path is written *through* to its target. `createPermissions`
/// applies only when there is nothing to preserve.
///
/// Atomicity here is `rename(2)`'s: a reader sees either the whole old file or
/// the whole new one, never a truncated file and never a 0-byte one. It is not
/// durability — nothing calls `fsync`, matching ``JSONLinesFileWriter`` — and it
/// is not mutual exclusion: two writers that each read-modify-write will still
/// lose one of the two edits, and ``FileLock`` is what stops that.
public enum AtomicFileWrite {

    /// Writes `contents` to `path`, replacing whatever was there.
    ///
    /// - Parameters:
    ///   - path: The document. A symlink is followed to its target, and the
    ///     symlink itself survives.
    ///   - contents: Encoded UTF-8.
    ///   - createPermissions: The mode for a file that does not exist yet. 0600
    ///     by default: everything this is used for — settings, grants, session
    ///     state — is either a credential or a record of what the user typed.
    ///     Ignored when the file already exists, whose mode is preserved instead.
    ///
    /// Throws rather than touching anything when `path` names something that is
    /// not a regular file; see `existingPermissions` below for why that case is
    /// dangerous rather than merely wrong.
    public static func replace(
        at path: String,
        with contents: String,
        createPermissions: FilePermissions = .ownerReadWrite
    ) throws(DoMoError) {
        let destination = resolvingSymlinkLeaf(FilePath(path))
        // Checked first, so a refusal has created no directory and no temp.
        let permissions = try existingPermissions(at: destination) ?? createPermissions

        let directory = destination.removingLastComponent().string
        let parent = FilePath(directory.isEmpty ? "." : directory)
        // Best-effort: if this fails, the `open` below fails with the errno that
        // actually explains why, which is a better message than anything that
        // could be reported from here.
        try? FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true
        )

        let name = destination.lastComponent?.string ?? "file"
        let temporary = parent.appending(".\(name)-\(UUID().uuidString).tmp")

        // The mode is settled before a single byte is written, so the contents are
        // never on disk under a looser mode than the caller asked for, not even
        // for an instant. `.exclusiveCreate` because a temp name we did not
        // create is a temp name somebody else owns.
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                temporary,
                .writeOnly,
                options: [.create, .truncate, .exclusiveCreate],
                permissions: permissions
            )
        } catch {
            throw failure(error, path: temporary, while: "create temporary file for")
        }
        // `open` intersects the requested mode with the process umask, so a
        // preserved 0666 comes back as 0644 under the common umask 022 and the
        // mode drifts on every save while this claims to preserve it. The result
        // is deliberately ignored: a filesystem that refuses chmod (a mounted FAT
        // volume) leaves the file at `mode & ~umask`, which is never *looser*
        // than requested, and losing the user's settings would be the worse
        // failure.
        _ = fchmod(descriptor.rawValue, permissions.rawValue)

        var writeFailure: (any Error)?
        do {
            try descriptor.writeAll(Data(contents.utf8))
        } catch {
            writeFailure = error
        }
        // Closed exactly once on every path. `close(2)` frees the descriptor even
        // when it reports an error, so a second close could land on a number the
        // kernel has already handed to another thread.
        do {
            try descriptor.close()
        } catch {
            writeFailure = writeFailure ?? error
        }
        if let error = writeFailure {
            try? FileManager.default.removeItem(atPath: temporary.string)
            throw failure(error, path: temporary, while: "write")
        }

        let destinationURL = URL(fileURLWithPath: destination.string)
        let temporaryURL = URL(fileURLWithPath: temporary.string)
        do {
            if FileManager.default.fileExists(atPath: destination.string) {
                // `.usingNewMetadataOnly` is what carries the temp's mode across
                // the replace. Without it the result takes the *old* file's
                // metadata — which lands on almost the same mode, since the temp
                // was created at the old file's mode, but puts the decision in
                // two places that can disagree. One of them masks to the
                // permission bits and the other does not.
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            // The temp is ours and nobody else can see it, so removing it is
            // unconditional. Leaving it would accumulate one file per failed save
            // in the user's config directory.
            try? FileManager.default.removeItem(atPath: temporary.string)
            throw failure(error, path: destination, while: "replace")
        }
    }

    /// `path` with a final symlink component followed to what it names, or
    /// `path` unchanged when the leaf is not a symlink — including when it does
    /// not exist yet.
    ///
    /// Only the leaf, and only through `readlink(2)`'s answer: this deliberately
    /// does *not* use `URL.resolvingSymlinksInPath()`, which also canonicalises
    /// every parent component (turning `/tmp/x` into `/private/tmp/x` on macOS)
    /// and so reports a path the caller never asked about.
    ///
    /// A relative target resolves against the link's own directory, which is
    /// what `readlink` means. The hop limit ends a symlink cycle; the path
    /// returned in that case is still a symlink, and the subsequent `open` fails
    /// with `ELOOP`, which is the honest error.
    private static func resolvingSymlinkLeaf(_ path: FilePath) -> FilePath {
        var current = path
        for _ in 0..<8 {
            guard
                let target = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: current.string
                )
            else { return current }
            current = current.removingLastComponent().pushing(FilePath(target))
        }
        return current
    }

    /// The mode of an existing regular file at `path`, `nil` when there is
    /// nothing there to preserve — and a hard error when there is something
    /// there that is not a regular file.
    ///
    /// The refusal is not fastidiousness, it is data loss. `replaceItemAt` does
    /// **not** fail on a directory destination the way `rename(2)` does: on
    /// macOS it falls back to removing the original and moving the replacement
    /// into its place, so pointing this function at a directory deletes that
    /// directory and everything under it and reports success. A device or a
    /// FIFO would likewise be unlinked and replaced by a regular file. Nothing
    /// this API is for wants either outcome, so it stops before creating
    /// anything.
    private static func existingPermissions(
        at path: FilePath
    ) throws(DoMoError) -> FilePermissions? {
        // A failure here is "nothing is there", the normal first-write case. It
        // can also be an unreadable parent directory, and then the temp `open`
        // in that same directory fails and reports the errno that explains it.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.string) else {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular else {
            throw DoMoError(
                .file(path: path, errno: type == .typeDirectory ? .isDirectory : nil),
                "refusing to replace \(path): it is not a regular file"
            )
        }
        guard let mode = attributes[.posixPermissions] as? NSNumber else { return nil }
        // Masked to the permission bits: the type bits from `st_mode` are not
        // part of what `open(2)` or `fchmod(2)` accept, and `numericCast` would
        // trap converting them on a platform where `mode_t` is 16 bits.
        return FilePermissions(rawValue: numericCast(mode.uint32Value & 0o7777))
    }

    /// Converts a filesystem failure into the taxonomy the rest of the harness
    /// switches on, keeping the `errno` when there was one.
    private static func failure(
        _ error: any Error,
        path: FilePath,
        while action: String
    ) -> DoMoError {
        if let errno = error as? Errno {
            return DoMoError.file(errno, path: path, while: action)
        }
        return DoMoError(
            wrapping: error,
            as: .file(path: path, errno: nil),
            "\(action) \(path)"
        )
    }
}
