// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The ONE image loader for the package. `--image` on the command line, an
// `@path` mention in the REPL, and a file dropped onto the full-screen client
// all arrive here, so there is exactly one place that decides what counts as an
// attachable image and exactly one set of limits to reason about.

import DoMoCore
import Foundation
import SystemPackage

// MARK: - Limits

/// What an attachment surface will accept.
///
/// The three limits are independent on purpose. `maximumBytesPerImage` bounds
/// what a single stat-then-read can allocate; `maximumTotalBytes` bounds what
/// one turn costs on the wire and in the session log; `maximumCount` bounds the
/// UI, which renders one chip per attachment.
public struct ImageAttachmentLimits: Sendable, Hashable {

    /// How many images may ride one turn.
    public var maximumCount: Int

    /// The largest single image, in raw (pre-base64) bytes.
    public var maximumBytesPerImage: Int

    /// The largest total across all attachments on one turn.
    public var maximumTotalBytes: Int

    public init(
        maximumCount: Int = 8,
        maximumBytesPerImage: Int = 5 << 20,
        maximumTotalBytes: Int = 10 << 20
    ) {
        self.maximumCount = maximumCount
        self.maximumBytesPerImage = maximumBytesPerImage
        self.maximumTotalBytes = maximumTotalBytes
    }

    /// 8 files, 5 MiB each, 10 MiB total.
    ///
    /// 10 MiB of raw bytes is roughly 13.4 MiB once base64-encoded onto the
    /// wire, which is why the server's prompt-body cap has to be well above the
    /// default 4 MiB — see `DoMoServer.maximumPromptBodyBytes`.
    public static let `default` = ImageAttachmentLimits()

    /// Limits that refuse nothing, for a trusted operator path such as the
    /// `--image` flag, where silently declining a large file would be a
    /// regression rather than a safeguard.
    public static let unlimited = ImageAttachmentLimits(
        maximumCount: .max,
        maximumBytesPerImage: .max,
        maximumTotalBytes: .max
    )
}

// MARK: - Loaded image

/// One image read off disk and ready to attach.
public struct LoadedImage: Sendable, Hashable {

    /// The CANONICAL absolute path — every symlink resolved. This is the
    /// identity used for deduplication, so a link and its target attach once.
    public let path: FilePath

    /// The basename of the path AS DROPPED, before canonicalization: a user who
    /// drops `~/Desktop/latest.png` should see `latest.png` on the chip, not the
    /// name of whatever dated file that link currently points at.
    ///
    /// NOT sanitized. A filename is attacker-influenced text and can carry
    /// escape sequences; the display layer applies its own `sanitizeUntrustedText`.
    public let displayName: String

    /// Sniffed from the leading bytes by ``FileContentProbe/imageMediaType(_:)``,
    /// never inferred from the extension.
    public let mediaType: String

    public let data: Data

    public var byteCount: Int { data.count }

    public init(path: FilePath, displayName: String, mediaType: String, data: Data) {
        self.path = path
        self.displayName = displayName
        self.mediaType = mediaType
        self.data = data
    }

    /// A compact, locale-independent size for a chip label: `412 KB`, `1.1 MB`.
    ///
    /// Integer arithmetic rather than a formatter, because this string is
    /// asserted in tests and rendered into a fixed-width terminal cell grid;
    /// neither tolerates a locale deciding to use a comma for the decimal point.
    public static func formattedByteCount(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var scale = 1024
        var unit = 0
        while unit + 1 < units.count, bytes / scale >= 1024 {
            scale *= 1024
            unit += 1
        }
        let whole = bytes / scale
        guard whole < 10 else { return "\(whole) \(units[unit])" }
        let tenths = (bytes % scale) * 10 / scale
        return "\(whole).\(tenths) \(units[unit])"
    }
}

// MARK: - Rejection

/// Why one candidate path did not become an attachment.
///
/// A rejection is a value, not an error, because partial success is the normal
/// case: three photos and a PDF dropped together must attach the three and
/// explain the one, never fail the whole gesture.
public struct ImageAttachmentRejection: Sendable, Hashable, Error {

    public enum Reason: Sendable, Hashable {
        /// Nothing at that path.
        case missing
        /// A directory, a device, a socket — anything that is not a file.
        case notARegularFile
        /// It exists and is a file, but the bytes could not be read: permissions,
        /// a vanished mount, an I/O error.
        case unreadable
        /// The leading bytes are not PNG, JPEG, GIF, WebP or BMP. Content, not
        /// extension: a `.png` that is really a video is rejected here.
        case notAnImage
        /// Bigger than this surface accepts. `bytes` is the size on disk, which
        /// is known from the stat — the file is never read.
        case tooLarge(bytes: Int, limit: Int)
        /// The per-turn attachment count was already at its limit.
        case countLimitReached(limit: Int)
        /// Attaching it would push the turn past its total-bytes budget.
        case totalBytesExceeded(limit: Int)
    }

    /// The path as the caller named it, absolute but NOT canonicalized — a
    /// message about a missing path must echo the path the user actually gave.
    public let path: FilePath

    public let reason: Reason

    public init(path: FilePath, reason: Reason) {
        self.path = path
        self.reason = reason
    }

    /// The basename, or the whole path when there is no last component.
    public var displayName: String { path.lastComponent?.string ?? path.string }

    /// A one-line, user-facing explanation, safe to show verbatim.
    ///
    /// The phrase "is not a supported image" is load-bearing: it is asserted on
    /// stderr by `Tests/DoMoCLITests/ImageAttachmentEndToEndTests`, which is the
    /// contract the `--image` flag has published since it shipped.
    public var message: String {
        switch reason {
        case .missing:
            return "\(displayName): no such file"
        case .notARegularFile:
            return "\(displayName) is not a regular file"
        case .unreadable:
            return "\(displayName) could not be read"
        case .notAnImage:
            return "\(displayName) is not a supported image (PNG, JPEG, GIF, WebP, or BMP)"
        case .tooLarge(let bytes, let limit):
            return """
                \(displayName) is \(LoadedImage.formattedByteCount(bytes)), over the \
                \(LoadedImage.formattedByteCount(limit)) limit
                """
        case .countLimitReached(let limit):
            return "\(displayName) skipped: at most \(limit) image\(limit == 1 ? "" : "s") per message"
        case .totalBytesExceeded(let limit):
            return """
                \(displayName) skipped: attachments would exceed the \
                \(LoadedImage.formattedByteCount(limit)) total limit
                """
        }
    }
}

// MARK: - Result

/// The outcome of loading a batch of candidate paths.
public struct ImageAttachmentLoadResult: Sendable {

    public var loaded: [LoadedImage]
    public var rejected: [ImageAttachmentRejection]

    /// Paths that named an image already staged on this turn, as the caller
    /// spelled them.
    ///
    /// A duplicate is neither a success nor a failure, and it needs its own
    /// slot because those are the only two things the caller can otherwise
    /// conclude. Dragging the same photo onto the prompt twice must not be read
    /// as "this text was not a drop" — that would type the path into the prompt
    /// as literal text — and must not be read as "one more image attached"
    /// either.
    public var skippedDuplicates: [FilePath]

    /// The batch stopped early because the task was cancelled.
    ///
    /// ``loaded`` holds whatever was read before the stop; ``rejected``
    /// deliberately holds nothing the cancellation caused. A cancelled drop is a
    /// gesture the user took back, and it must produce silence rather than one
    /// "could not be read" notice per file.
    public var wasCancelled: Bool

    public init(
        loaded: [LoadedImage] = [],
        rejected: [ImageAttachmentRejection] = [],
        skippedDuplicates: [FilePath] = [],
        wasCancelled: Bool = false
    ) {
        self.loaded = loaded
        self.rejected = rejected
        self.skippedDuplicates = skippedDuplicates
        self.wasCancelled = wasCancelled
    }

    /// Every candidate resolved, and there was at least one.
    ///
    /// This is what ``ImageAttachmentLoader/resolveDrop(candidates:using:limits:alreadyLoaded:)``
    /// ranks readings by: a reading that produced even one rejection is the wrong
    /// reading of the drop, not a partially successful one.
    ///
    /// A batch of nothing but duplicates counts, because every path in it named
    /// a real image — it just named one that is already attached. The caller
    /// consumes the text and adds no chip. A cancelled batch never counts: it
    /// stopped before it knew.
    public var isCompleteSuccess: Bool {
        guard !wasCancelled, rejected.isEmpty else { return false }
        return !loaded.isEmpty || !skippedDuplicates.isEmpty
    }

    /// Total raw bytes of everything loaded.
    public var byteCount: Int { loaded.reduce(0) { $0 + $1.byteCount } }
}

// MARK: - Loader

/// Reads candidate paths into attachable images.
public enum ImageAttachmentLoader {

    /// Read one path into a ``LoadedImage``, or say why not.
    ///
    /// The order of operations is the point, and it is stat → sniff → read:
    ///
    /// 1. `absolutePath` — expands `~` and strips a `file://` scheme;
    /// 2. `canonicalPath` — resolves symlinks, so identity is a real inode and a
    ///    link to an image is an image;
    /// 3. `metadata` — rejects anything that is not a regular file, and rejects
    ///    on `size` BEFORE any read, so a 4 GB video dropped as `photo.png`
    ///    never enters memory;
    /// 4. `readPrefix(_:maximumBytes:)` at ``FileContentProbe/imageSniffLength``
    ///    plus ``FileContentProbe/imageMediaType(_:)`` — rejects a non-image
    ///    after 4100 bytes, not after the whole file;
    /// 5. `read` — the full bytes, only once 3 and 4 have both passed. The size
    ///    is re-checked against the limit afterwards, because a file can grow
    ///    between the stat and the read.
    ///
    /// `@concurrent` is load-bearing rather than decorative. Every caller is a
    /// main-actor UI, and under `NonisolatedNonsendingByDefault` an unmarked
    /// `async func` runs on its CALLER's actor — so without this a 5 MiB read
    /// and its base64 encoding would happen on the render loop, which is exactly
    /// the stall `InteractiveMode.extractImageAttachments` already documents.
    @concurrent
    public static func load(
        _ path: FilePath,
        using fileSystem: some FileSystem,
        maximumBytes: Int = ImageAttachmentLimits.default.maximumBytesPerImage
    ) async -> Result<LoadedImage, ImageAttachmentRejection> {
        let absolute = fileSystem.absolutePath(path)
        let displayName = absolute.lastComponent?.string ?? absolute.string

        func reject(_ reason: ImageAttachmentRejection.Reason) -> Result<
            LoadedImage, ImageAttachmentRejection
        > {
            .failure(ImageAttachmentRejection(path: absolute, reason: reason))
        }

        let canonical: FilePath
        do {
            canonical = try await fileSystem.canonicalPath(absolute)
        } catch {
            return reject(Self.reason(for: error))
        }

        let info: FileMetadata
        do {
            info = try await fileSystem.metadata(canonical)
        } catch {
            return reject(Self.reason(for: error))
        }

        guard info.kind == .file else { return reject(.notARegularFile) }

        // `size` is Int64 and a hostile filesystem could report anything; clamp
        // into Int rather than trapping on the conversion.
        let size = info.size > Int64(Int.max) ? Int.max : Int(max(0, info.size))
        guard size <= maximumBytes else {
            return reject(.tooLarge(bytes: size, limit: maximumBytes))
        }

        let head: Data
        do {
            head = try await fileSystem.readPrefix(
                canonical,
                maximumBytes: FileContentProbe.imageSniffLength
            )
        } catch {
            return reject(Self.reason(for: error))
        }

        guard let mediaType = FileContentProbe.imageMediaType(head) else {
            return reject(.notAnImage)
        }

        let bytes: Data
        do {
            bytes = try await fileSystem.read(canonical)
        } catch {
            return reject(Self.reason(for: error))
        }

        // The stat is a promise about the past, not the present.
        guard bytes.count <= maximumBytes else {
            return reject(.tooLarge(bytes: bytes.count, limit: maximumBytes))
        }

        return .success(
            LoadedImage(
                path: canonical,
                displayName: displayName,
                mediaType: mediaType,
                data: bytes
            )
        )
    }

    /// Load a batch, enforcing the count and total-bytes limits against
    /// `alreadyLoaded` — the attachments already staged on this turn.
    ///
    /// Partial success is the contract: every path is attempted, and a path that
    /// cannot be attached produces a rejection rather than ending the batch.
    /// Nothing is ever truncated to fit; an image that would overflow the total
    /// budget is refused whole, with the reason that names the budget.
    ///
    /// Duplicates — by canonical path, so a symlink and its target count once —
    /// are skipped silently, and recorded in
    /// ``ImageAttachmentLoadResult/skippedDuplicates``. Attaching a file twice is
    /// not an error the user needs to hear about, and it is not a failed reading
    /// of the drop either; the caller needs to be able to tell those two apart
    /// from each other.
    ///
    /// Cancellation ENDS the batch. `POSIXFileSystem` checks
    /// `Task.isCancelled` before every read and stat and throws
    /// `DoMoError(.cancelled,)`, which arrives here indistinguishable from a
    /// permission failure; classifying it as one would turn a cancelled
    /// eight-image drop into eight bogus "could not be read" notices. The task
    /// flag is checked instead of the error because it is the same condition
    /// (`FileSystem.checkCancellation` throws only when it is set) and it also
    /// catches a cancellation that lands BETWEEN two files, where there is no
    /// error to inspect.
    @concurrent
    public static func loadAll(
        _ paths: [FilePath],
        using fileSystem: some FileSystem,
        limits: ImageAttachmentLimits = .default,
        alreadyLoaded: [LoadedImage] = []
    ) async -> ImageAttachmentLoadResult {
        var result = ImageAttachmentLoadResult()
        var seen = Set(alreadyLoaded.map(\.path))
        var count = alreadyLoaded.count
        var total = alreadyLoaded.reduce(0) { $0 + $1.byteCount }

        for path in paths {
            guard !Task.isCancelled else {
                result.wasCancelled = true
                return result
            }

            let absolute = fileSystem.absolutePath(path)

            // Cheap identity check first, so a duplicate costs a readlink walk
            // rather than a full read. A path that will not canonicalize falls
            // through to `load`, which reports the real reason.
            if let canonical = try? await fileSystem.canonicalPath(absolute),
                seen.contains(canonical)
            {
                result.skippedDuplicates.append(absolute)
                continue
            }

            guard count < limits.maximumCount else {
                result.rejected.append(
                    ImageAttachmentRejection(
                        path: absolute,
                        reason: .countLimitReached(limit: limits.maximumCount)
                    )
                )
                continue
            }

            // Capping at the smaller of the two budgets means an image too big
            // for the REMAINING total is refused from its stat, without ever
            // being read — the reason is then restated in the caller's terms.
            let remaining = max(0, limits.maximumTotalBytes - total)
            let cap = min(limits.maximumBytesPerImage, remaining)

            switch await load(absolute, using: fileSystem, maximumBytes: cap) {
            case .success(let image):
                guard seen.insert(image.path).inserted else {
                    result.skippedDuplicates.append(absolute)
                    continue
                }
                result.loaded.append(image)
                count += 1
                total += image.byteCount

            case .failure(let rejection):
                // A cancelled read reaches `load` as an ordinary filesystem
                // error and comes back as `.unreadable`. It is not one, and it
                // is not the user's business either.
                guard !Task.isCancelled else {
                    result.wasCancelled = true
                    return result
                }
                result.rejected.append(Self.restating(rejection, against: limits, remaining: remaining))
            }
        }

        return result
    }

    /// Try each reading of a drop in order, keeping the first that resolves
    /// COMPLETELY — every path an image.
    ///
    /// This is where `DroppedPaths.candidates` and the filesystem meet: the
    /// parser cannot tell `/Users/x/my pic.png` (one file with a space) from
    /// `/Users/x/my` and `pic.png` (two files) without asking the disk, so it
    /// offers both and this picks.
    ///
    /// A reading in which every path was ALREADY staged resolves completely too,
    /// with nothing loaded. Re-dropping a photo that is already attached is a
    /// no-op, not a failed reading; treating it as a failure would make the
    /// caller re-insert the path into the prompt as text.
    ///
    /// When no reading resolves completely, the FIRST reading's result is
    /// returned, because it is the most likely intended one and therefore the
    /// one whose rejection message names the path the user meant. With no
    /// candidates at all the result is empty — which is not a success, so a
    /// caller can treat "nothing resolved" uniformly. A cancelled reading stops
    /// the search: the remaining readings would only be cancelled as well.
    @concurrent
    public static func resolveDrop(
        candidates: [[String]],
        using fileSystem: some FileSystem,
        limits: ImageAttachmentLimits = .default,
        alreadyLoaded: [LoadedImage] = []
    ) async -> ImageAttachmentLoadResult {
        var first: ImageAttachmentLoadResult?
        for candidate in candidates {
            let result = await loadAll(
                candidate.map { FilePath($0) },
                using: fileSystem,
                limits: limits,
                alreadyLoaded: alreadyLoaded
            )
            if result.isCompleteSuccess || result.wasCancelled { return result }
            if first == nil { first = result }
        }
        return first ?? ImageAttachmentLoadResult()
    }

    // MARK: Reasons

    /// Map a filesystem failure onto a rejection reason.
    ///
    /// Only "there is nothing there" is distinguished, because it is the only
    /// one the user can act on differently. A sandbox refusal, a permission
    /// denial and an I/O error are all `unreadable`: they mean the same thing to
    /// someone who just dropped a file.
    ///
    /// Cancellation (`DoMoError.isCancellation`) is deliberately NOT given a
    /// reason of its own. A rejection is a fact ABOUT A PATH, and "the user took
    /// the gesture back" is not one; ``ImageAttachmentRejection/Reason`` would
    /// have to grow a case that every switch over it then has to render. It is
    /// caught one level up instead, in ``loadAll(_:using:limits:alreadyLoaded:)``,
    /// which drops the rejection entirely rather than labelling it.
    private static func reason(for error: DoMoError) -> ImageAttachmentRejection.Reason {
        guard case .file(_, let errno) = error.kind else { return .unreadable }
        switch errno {
        case .noSuchFileOrDirectory, .notDirectory: return .missing
        default: return .unreadable
        }
    }

    /// Re-label a per-image size rejection as a total-budget one when the file
    /// would have fit on its own.
    ///
    /// Without this, the ninth photo of a batch reads "over the 5 MB limit" when
    /// it is 2 MB — technically true of the cap that was applied, and useless.
    private static func restating(
        _ rejection: ImageAttachmentRejection,
        against limits: ImageAttachmentLimits,
        remaining: Int
    ) -> ImageAttachmentRejection {
        guard case .tooLarge(let bytes, _) = rejection.reason,
            bytes > remaining,
            bytes <= limits.maximumBytesPerImage
        else { return rejection }
        return ImageAttachmentRejection(
            path: rejection.path,
            reason: .totalBytesExceeded(limit: limits.maximumTotalBytes)
        )
    }
}
