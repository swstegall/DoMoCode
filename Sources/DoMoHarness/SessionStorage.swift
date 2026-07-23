// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import SystemPackage

// MARK: - Listing

/// A session file located on disk, paired with its header.
///
/// Returned by session discovery so a caller can present or pick a session
/// without opening it for reading. Kept as a value so a listing of a directory
/// is `Sendable` and cheap to sort.
public struct SessionListing: Sendable, Hashable {
    public var path: FilePath
    public var header: SessionHeader

    public init(path: FilePath, header: SessionHeader) {
        self.path = path
        self.header = header
    }
}

// MARK: - Storage protocol

/// The persistence surface a session tree is read from and appended to.
///
/// This is deliberately the *instance* interface only — the operations that act
/// on one already-located session file. Creating, opening and locating session
/// files are not here: those necessarily encode a backend's own path scheme
/// (the JSONL store's sanitized-cwd directory layout, a future database's
/// connection), so they live as concrete factories on the conforming type rather
/// than as protocol requirements that would force every backend to speak the
/// JSONL store's dialect. Keeping the protocol to backend-agnostic reads and
/// one append is what lets it stay small and `Sendable`.
///
/// The split between the tolerant reads and the throwing resolvers is the whole
/// point of the protocol and is load-bearing: see ``readEntries(onSkippedLine:)``
/// versus ``pathToRootOrCompaction(from:)`` and ``readHeader()``.
public protocol SessionStorage: Sendable {
    /// The file this store reads and appends.
    var path: FilePath { get }

    /// Reads and validates the session header.
    ///
    /// Fails closed: a file whose first line is not a valid header is not a
    /// session, and returning a placeholder would let a mistyped path masquerade
    /// as an empty session. Contrast ``readEntries(onSkippedLine:)``.
    func readHeader() throws -> SessionHeader

    /// Mints an id for a new entry. UUIDv7, so ids sort lexicographically in
    /// creation order — the property the tree, branch materialization and JSONL
    /// replay all depend on.
    func createEntryID() -> String

    /// Durably appends one fully-formed entry. The caller owns id/parentId; the
    /// store only writes. Crash-safe: an interrupted append damages at most the
    /// final line.
    func appendEntry(_ entry: SessionTreeEntry) throws

    /// Reads every entry, skipping (and reporting) any line that will not decode.
    ///
    /// Fails open: this is the resume path, where a session truncated by a crash
    /// must still yield everything written before the truncation. Malformed lines
    /// are dropped rather than fatal, and surfaced through `onSkippedLine` so a
    /// silently shortened session is at least observable.
    func readEntries(onSkippedLine: (@Sendable (JSONLinesError) -> Void)?) throws -> [SessionTreeEntry]

    /// Looks up one entry by id, or `nil` if it is not present. Absence is not
    /// an error here — it is the caller's cue that an id is stale.
    func entry(withID id: String) throws -> SessionTreeEntry?

    /// The current tip of the tree, recovered from the last written entry, or
    /// `nil` for a session with no entries yet.
    func leafID() throws -> String?

    /// The active context path: walks `leafID` to the root, stopping at the
    /// nearest compaction checkpoint.
    ///
    /// Fails closed on a broken tree even though ``readEntries(onSkippedLine:)``
    /// fails open on the same file: a dangling `parentId` or a missing leaf means
    /// the *path* cannot be reconstructed, and resuming against a silently
    /// shortened context is worse than refusing. This is pi's asymmetry — the row
    /// decoder skips, the path resolver throws.
    func pathToRootOrCompaction(from leafID: String?) throws -> [SessionTreeEntry]
}

extension SessionStorage {
    /// Reads every entry, discarding the report of skipped lines.
    public func readEntries() throws -> [SessionTreeEntry] {
        try readEntries(onSkippedLine: nil)
    }
}
