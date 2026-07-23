// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/session/session.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation
import SystemPackage

// MARK: - In-memory tree

/// An immutable in-memory view of a session's entries, indexed for navigation.
///
/// This is the read-side companion to ``JSONLSessionStore``: the store owns the
/// file and re-derives everything from it per call, whereas a ``SessionTree`` is
/// a snapshot built once from a bulk read and then navigated without further I/O.
/// Building the id index up front is what makes ``entry(withID:)`` and the path
/// walks O(1) per hop instead of a linear scan of the file for every parent.
///
/// The snapshot is deliberately taken *after* the tolerant bulk read
/// (``SessionStorage/readEntries(onSkippedLine:)``) has already dropped any line
/// that would not decode. That is one half of pi's read asymmetry; the other
/// half lives on the resolvers below (``pathToRootOrCompaction(from:)`` and
/// ``branch(from:)``), which throw on a structural hole the bulk read left
/// behind. See the WHY comment on each.
public struct SessionTree: Sendable {
    /// Every entry, in file (append) order. Because entry ids are UUIDv7 this is
    /// also chronological, which is why children and the reversed path walks come
    /// out in a stable, meaningful order without a secondary sort.
    public let entries: [SessionTreeEntry]

    /// The active tip, recovered from the last entry exactly as the store does
    /// (a `leaf` entry names the tip; anything else *is* the tip). `nil` for a
    /// session with no entries.
    public let leafID: String?

    private let byID: [String: SessionTreeEntry]

    public init(entries: [SessionTreeEntry]) {
        self.entries = entries
        self.byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.leafID = entries.last?.leafIdAfterEntry
    }

    /// Loads every entry from `storage` and indexes it.
    ///
    /// The read is tolerant on purpose — a crash-truncated tail or a malformed
    /// middle line is skipped and reported through `onSkippedLine`, never fatal —
    /// because this is the resume path and a session interrupted mid-append must
    /// still yield the tree that was written before the break. The throwing
    /// counterpart is the *path* resolution below.
    public static func load(
        from storage: some SessionStorage,
        onSkippedLine: (@Sendable (JSONLinesError) -> Void)? = nil
    ) throws -> SessionTree {
        SessionTree(entries: try storage.readEntries(onSkippedLine: onSkippedLine))
    }

    // MARK: - Lookups

    /// One entry by id, or `nil` when the id is not in the snapshot. Absence is a
    /// stale-id signal for the caller, not corruption — contrast the path walks.
    public func entry(withID id: String) -> SessionTreeEntry? {
        byID[id]
    }

    /// The direct children of `parentID` (`nil` for the tree roots), in file
    /// order.
    ///
    /// A linear pass rather than a prebuilt adjacency map: branching is rare, the
    /// snapshot is already resident, and a second index would have to be kept
    /// consistent with `entries` for a query the UI makes occasionally.
    public func children(of parentID: String?) -> [SessionTreeEntry] {
        entries.filter { $0.parentId == parentID }
    }

    // MARK: - Path resolution

    /// The full path from the root down to `fromID` (or the current leaf), in
    /// chronological order.
    ///
    /// This is pi's `getBranch`: it walks the parent chain and reverses, so the
    /// result reads oldest-first. Unlike the tolerant bulk read that produced the
    /// snapshot, it throws on a dangling `parentId` or a missing start entry:
    /// a hole in the *active* chain cannot be silently spanned, and a fork or a
    /// resume built on a chain that quietly lost its middle is worse than a
    /// refusal. This is the throwing half of the read asymmetry.
    public func branch(from fromID: String? = nil) throws -> [SessionTreeEntry] {
        guard let start = fromID ?? leafID else { return [] }
        guard var current = byID[start] else {
            throw DoMoError(.file(path: nil, errno: nil), "Session entry not found: \(start)")
        }
        var path: [SessionTreeEntry] = []
        while true {
            path.insert(current, at: 0)
            guard let parentID = current.parentId else { break }
            guard let parent = byID[parentID] else {
                throw DoMoError(.file(path: nil, errno: nil), "Session entry not found: \(parentID)")
            }
            current = parent
        }
        return path
    }

    /// The active context path: the walk from `fromID` (or the leaf) toward the
    /// root, stopping at the nearest compaction checkpoint.
    ///
    /// A compaction with a `retainedTail` is self-contained, so the walk stops
    /// *on* it — everything before it is represented by its summary. A legacy
    /// compaction with only `firstKeptEntryId` keeps walking until that id, so the
    /// kept span is materialized. This mirrors ``JSONLSessionStore``'s file-backed
    /// resolver; the snapshot version exists so the context builder can run
    /// without another file read after the tree is already loaded.
    ///
    /// Throws on the same structural corruption as ``branch(from:)`` and for the
    /// same reason: resuming against a silently shortened conversation is the
    /// failure this refusal prevents.
    public func pathToRootOrCompaction(from fromID: String? = nil) throws -> [SessionTreeEntry] {
        guard let start = fromID ?? leafID else { return [] }
        guard var current = byID[start] else {
            throw DoMoError(.file(path: nil, errno: nil), "Session entry not found: \(start)")
        }
        var path: [SessionTreeEntry] = []
        var stopAtEntryID: String? = nil
        while true {
            path.insert(current, at: 0)
            if let stop = stopAtEntryID, current.id == stop { break }
            if case .compaction(let compaction) = current.payload {
                if compaction.retainedTail != nil { break }
                stopAtEntryID = compaction.firstKeptEntryId
            }
            guard let parentID = current.parentId else { break }
            guard let parent = byID[parentID] else {
                throw DoMoError(.file(path: nil, errno: nil), "Session entry not found: \(parentID)")
            }
            current = parent
        }
        return path
    }
}

// MARK: - Moving the leaf

extension SessionStorage {
    /// Moves the active leaf to an earlier entry (or to before the first entry),
    /// starting a new branch — pi's `branch`/`setLeafId`.
    ///
    /// The store is append-only and re-derives the leaf from the last line, so
    /// "moving" the tip is itself an append: a `leaf` entry naming the new target.
    /// The next real entry appended will therefore be a child of `targetID`,
    /// forming the branch, while the abandoned path stays on disk untouched.
    ///
    /// `timestamp` is supplied by the caller because this layer mints ids but not
    /// clock values — the harness owns the injected clock. A non-`nil` `targetID`
    /// that names no entry throws rather than stranding the leaf on a phantom id.
    @discardableResult
    public func moveLeaf(to targetID: String?, timestamp: String) throws -> String {
        if let targetID, try entry(withID: targetID) == nil {
            throw DoMoError(.file(path: path, errno: nil), "Session entry not found: \(targetID)")
        }
        let id = createEntryID()
        let entry = SessionTreeEntry(
            id: id,
            parentId: try leafID(),
            timestamp: timestamp,
            payload: .leaf(targetId: targetID)
        )
        try appendEntry(entry)
        return id
    }
}

// MARK: - Forking

extension JSONLSessionStore {
    /// Extracts the path from the root down to `leafID` into a brand-new session
    /// file whose header names this session as its parent — pi's
    /// `createBranchedSession`.
    ///
    /// The fork is a linear re-chaining of the active path: `label` entries are
    /// dropped and the survivors are relinked so no retained entry is left
    /// pointing at a removed parent. Entry ids are preserved (only `parentId` is
    /// rewritten) so references into the branch — a `firstKeptEntryId`, a
    /// `retainedTail`'s provenance — keep resolving in the new file.
    ///
    /// `sessionDirectory` is passed in rather than read back off `path` because a
    /// stateless store deliberately does not remember where its session tree
    /// lives; the caller that knows the configured directory supplies it, and the
    /// new file lands beside its siblings under the same sanitized-cwd scheme.
    ///
    /// Reading the branch throws on a broken chain (see
    /// ``SessionTree/branch(from:)``): a fork of a path that silently lost its
    /// middle would be a corrupt session masquerading as a clean one.
    public func createBranchedSession(
        leafID: String,
        sessionDirectory: FilePath,
        now: @escaping @Sendable () -> Date = { Date() },
        entryIDFactory: @escaping @Sendable () -> String = { UUIDv7.generate().description }
    ) throws -> JSONLSessionStore {
        let header = try readHeader()
        let tree = try SessionTree.load(from: self)
        let path = try tree.branch(from: leafID)
        guard !path.isEmpty else {
            throw DoMoError(.file(path: self.path, errno: nil), "Session entry not found: \(leafID)")
        }

        // Drop labels and re-chain: because labels are real tree nodes, a later
        // entry can be a child of a label, so removing labels without relinking
        // would orphan the tail. Each survivor's parent becomes the previous
        // survivor (nil for the first), preserving order and ids.
        var rechained: [SessionTreeEntry] = []
        var parentID: String? = nil
        for entry in path {
            if case .label = entry.payload { continue }
            rechained.append(
                SessionTreeEntry(
                    id: entry.id,
                    parentId: parentID,
                    timestamp: entry.timestamp,
                    payload: entry.payload
                )
            )
            parentID = entry.id
        }

        let forked = try JSONLSessionStore.create(
            cwd: header.cwd,
            sessionDirectory: sessionDirectory,
            parentSession: self.path.string,
            permissions: permissions,
            now: now,
            entryIDFactory: entryIDFactory
        )
        for entry in rechained {
            try forked.appendEntry(entry)
        }
        return forked
    }
}
