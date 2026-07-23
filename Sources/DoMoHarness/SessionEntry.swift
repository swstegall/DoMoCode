// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM
import Foundation

// MARK: - Session header

/// The first line of a session file: metadata about the session, deliberately
/// not a tree node.
///
/// It carries no `id`/`parentId`, so it can never be reached by walking the
/// tree, and the storage layer reads it separately from the entries. Keeping it
/// out of ``SessionTreeEntry`` is what lets header parsing fail closed (a file
/// whose first line is not a valid header is not a session at all) while entry
/// parsing fails open (a crash-truncated tail is recoverable) — the two halves
/// of pi's load path have different jobs and must not share a decoder.
public struct SessionHeader: Sendable, Hashable, Codable {
    /// The on-disk format version.
    ///
    /// pi is on v3 (the tree format this port implements); v1/v2 were the linear
    /// legacy layouts it auto-migrates from. DoMoCode starts its own numbering at
    /// 1 because it ships only the tree layout and has nothing to migrate — a
    /// shared number would falsely imply byte-compatibility with pi's files,
    /// which this port does not promise.
    public static let currentVersion = 1

    /// Discriminator. Always `"session"`; verified on decode so a stray entry
    /// line can never be mistaken for a header.
    public var type: String

    public var version: Int

    /// The session UUID (a full ``UUIDv7``), distinct from the per-entry ids.
    public var id: String

    /// ISO-8601 creation time. A string, not a `Date`, because the wire form is
    /// what gets diffed and inspected and round-tripping through `Date` would
    /// quietly renormalize it.
    public var timestamp: String

    /// The working directory the session was started in. Sessions are located
    /// by a sanitized form of this path.
    public var cwd: String

    /// For a forked session, the path to the session it was branched from.
    /// `nil` for a root session.
    public var parentSession: String?

    public init(
        version: Int = SessionHeader.currentVersion,
        id: String,
        timestamp: String,
        cwd: String,
        parentSession: String? = nil
    ) {
        self.type = "session"
        self.version = version
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.parentSession = parentSession
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case id
        case timestamp
        case cwd
        case parentSession
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "session" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "First line is not a session header (type=\(type))"
            )
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard version == SessionHeader.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported session version \(version)"
            )
        }
        self.type = type
        self.version = version
        self.id = try container.decode(String.self, forKey: .id)
        self.timestamp = try container.decode(String.self, forKey: .timestamp)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.parentSession = try container.decodeIfPresent(String.self, forKey: .parentSession)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(parentSession, forKey: .parentSession)
    }
}

// MARK: - Compaction payload

/// The summary that replaces the older half of a conversation once its context
/// grows too large.
///
/// A compaction entry is a checkpoint: context building stops walking backwards
/// once it reaches one. ``retainedTail`` is what makes a newer compaction
/// self-contained — the messages kept after the summary are materialized onto
/// the entry, so the checkpoint can be rebuilt without reading anything before
/// it. ``firstKeptEntryId`` is the older mechanism, retained only so sessions
/// written before ``retainedTail`` existed still load; new compactions should
/// carry ``retainedTail``.
public struct Compaction: Sendable, Hashable, Codable {
    /// The LLM-written summary of everything before the checkpoint.
    public var summary: String

    /// Estimated context size at the moment compaction fired, for display and
    /// for deciding whether to compact again.
    public var tokensBefore: Int

    /// Legacy pointer to the first entry kept after compaction. Superseded by
    /// ``retainedTail``; present only for backward compatibility.
    public var firstKeptEntryId: String?

    /// The messages kept after the checkpoint, materialized so context can be
    /// rebuilt from this entry alone.
    public var retainedTail: [Message]?

    /// Token/cost accounting for the summarization call itself, folded into
    /// session totals.
    public var usage: Usage?

    public init(
        summary: String,
        tokensBefore: Int,
        firstKeptEntryId: String? = nil,
        retainedTail: [Message]? = nil,
        usage: Usage? = nil
    ) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.firstKeptEntryId = firstKeptEntryId
        self.retainedTail = retainedTail
        self.usage = usage
    }
}

// MARK: - Branch summary payload

/// A summary of an abandoned branch, recorded when the leaf is moved to an
/// earlier entry so the context from the discarded path is not simply lost.
public struct BranchSummary: Sendable, Hashable, Codable {
    /// The entry the abandoned branch was summarized up to.
    public var fromId: String

    /// The LLM-written summary of that branch.
    public var summary: String

    /// Token/cost accounting for the summarization call, folded into totals.
    public var usage: Usage?

    public init(fromId: String, summary: String, usage: Usage? = nil) {
        self.fromId = fromId
        self.summary = summary
        self.usage = usage
    }
}

// MARK: - Tree entry

/// One node in the append-only session DAG.
///
/// The id/parentId/timestamp envelope is shared by every entry; the ``payload``
/// is the type-specific body. Modeling this as one value with a payload enum,
/// rather than a protocol with a case per entry type, keeps the whole tree a
/// `Sendable` value that can be compared, hashed and copied without a single
/// existential — which is what the in-memory index and the round-trip tests
/// rely on.
///
/// The load-bearing set for Phase 3 is `message`, `compaction`, `branch_summary`,
/// `label`, `session_info` and `model_change`; `leaf` is included because tree
/// navigation records the active tip as a `leaf` entry and it is cheap. The
/// extension-facing entries (`custom`, `custom_message`) and the settings
/// entries pi has for thinking level and dynamic tool sets are deliberately not
/// modeled: DoMoCode has no extension host and no thinking-level or dynamic-tool
/// feature, so a case for each would be a wire shape nothing writes and every
/// switch still has to handle.
public struct SessionTreeEntry: Sendable, Hashable {
    public var id: String

    /// The parent node's id, or `nil` for the first entry in the tree.
    public var parentId: String?

    /// ISO-8601 creation time. A string for the same reason as the header's.
    public var timestamp: String

    public var payload: Payload

    public init(id: String, parentId: String?, timestamp: String, payload: Payload) {
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.payload = payload
    }

    /// The type-specific body of an entry.
    public enum Payload: Sendable, Hashable {
        /// A conversation turn.
        case message(Message)
        /// The user switched models mid-session.
        case modelChange(provider: String, modelId: String)
        /// A context-compaction checkpoint.
        case compaction(Compaction)
        /// A summary of an abandoned branch.
        case branchSummary(BranchSummary)
        /// A user bookmark on `targetId`. A `nil` `label` clears it.
        case label(targetId: String, label: String?)
        /// Session metadata such as a user-chosen display name.
        case sessionInfo(name: String?)
        /// A record that the active leaf moved to `targetId` (`nil` = before the
        /// first entry). Written by tree navigation, not by the conversation.
        case leaf(targetId: String?)
    }
}

extension SessionTreeEntry {
    /// The stable `type` discriminator written to disk for each payload.
    public enum EntryType: String, Sendable {
        case message
        case modelChange = "model_change"
        case compaction
        case branchSummary = "branch_summary"
        case label
        case sessionInfo = "session_info"
        case leaf
    }

    public var entryType: EntryType {
        switch payload {
        case .message: return .message
        case .modelChange: return .modelChange
        case .compaction: return .compaction
        case .branchSummary: return .branchSummary
        case .label: return .label
        case .sessionInfo: return .sessionInfo
        case .leaf: return .leaf
        }
    }

    /// The leaf id that is current *after* this entry is appended.
    ///
    /// A `leaf` entry names the tip explicitly (that is its whole purpose); every
    /// other entry becomes the tip itself. This is the one rule that lets the
    /// storage layer recover the current position by looking only at the last
    /// entry, without replaying navigation.
    public var leafIdAfterEntry: String? {
        if case .leaf(let targetId) = payload { return targetId }
        return id
    }
}

// MARK: - Tree entry Codable

extension SessionTreeEntry: Codable {
    // The discriminated shape is hand-written rather than synthesized because
    // the on-disk layout is a public contract other tools inspect: `type` is a
    // sibling of the payload fields (flat, not nested), the discriminator
    // strings are snake_case and fixed, and `parentId` is always present as
    // `null` for the first entry rather than omitted. Enum synthesis would nest
    // the payload under a per-case key and invent its own discriminator, none of
    // which matches the format pi documents.
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case parentId
        case timestamp
        // Payload-specific:
        case message
        case provider
        case modelId
        case summary
        case tokensBefore
        case firstKeptEntryId
        case retainedTail
        case usage
        case fromId
        case targetId
        case label
        case name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let entryType = EntryType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown session entry type: \(rawType)"
            )
        }
        self.id = try container.decode(String.self, forKey: .id)
        self.parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        self.timestamp = try container.decode(String.self, forKey: .timestamp)

        switch entryType {
        case .message:
            self.payload = .message(try container.decode(Message.self, forKey: .message))
        case .modelChange:
            self.payload = .modelChange(
                provider: try container.decode(String.self, forKey: .provider),
                modelId: try container.decode(String.self, forKey: .modelId)
            )
        case .compaction:
            self.payload = .compaction(
                Compaction(
                    summary: try container.decode(String.self, forKey: .summary),
                    tokensBefore: try container.decode(Int.self, forKey: .tokensBefore),
                    firstKeptEntryId: try container.decodeIfPresent(String.self, forKey: .firstKeptEntryId),
                    retainedTail: try container.decodeIfPresent([Message].self, forKey: .retainedTail),
                    usage: try container.decodeIfPresent(Usage.self, forKey: .usage)
                )
            )
        case .branchSummary:
            self.payload = .branchSummary(
                BranchSummary(
                    fromId: try container.decode(String.self, forKey: .fromId),
                    summary: try container.decode(String.self, forKey: .summary),
                    usage: try container.decodeIfPresent(Usage.self, forKey: .usage)
                )
            )
        case .label:
            self.payload = .label(
                targetId: try container.decode(String.self, forKey: .targetId),
                label: try container.decodeIfPresent(String.self, forKey: .label)
            )
        case .sessionInfo:
            self.payload = .sessionInfo(name: try container.decodeIfPresent(String.self, forKey: .name))
        case .leaf:
            self.payload = .leaf(targetId: try container.decodeIfPresent(String.self, forKey: .targetId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryType.rawValue, forKey: .type)
        try container.encode(id, forKey: .id)
        // Always emitted, `null` for the root, so a reader never has to
        // distinguish "no parent" from "field forgotten".
        try container.encode(parentId, forKey: .parentId)
        try container.encode(timestamp, forKey: .timestamp)

        switch payload {
        case .message(let message):
            try container.encode(message, forKey: .message)
        case .modelChange(let provider, let modelId):
            try container.encode(provider, forKey: .provider)
            try container.encode(modelId, forKey: .modelId)
        case .compaction(let compaction):
            try container.encode(compaction.summary, forKey: .summary)
            try container.encode(compaction.tokensBefore, forKey: .tokensBefore)
            try container.encodeIfPresent(compaction.firstKeptEntryId, forKey: .firstKeptEntryId)
            try container.encodeIfPresent(compaction.retainedTail, forKey: .retainedTail)
            try container.encodeIfPresent(compaction.usage, forKey: .usage)
        case .branchSummary(let branch):
            try container.encode(branch.fromId, forKey: .fromId)
            try container.encode(branch.summary, forKey: .summary)
            try container.encodeIfPresent(branch.usage, forKey: .usage)
        case .label(let targetId, let label):
            try container.encode(targetId, forKey: .targetId)
            // Omitted when cleared, mirroring pi's `label: string | undefined`.
            try container.encodeIfPresent(label, forKey: .label)
        case .sessionInfo(let name):
            try container.encodeIfPresent(name, forKey: .name)
        case .leaf(let targetId):
            // Present as `null` when the leaf is reset to before the first entry,
            // which is a distinct state from "no targetId field".
            try container.encode(targetId, forKey: .targetId)
        }
    }
}
