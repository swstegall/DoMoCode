// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/types.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoGit
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

    /// The cumulative files the compacted history read without modifying.
    /// Optional for sessions written before the manifest was introduced.
    public var readFiles: [String]?

    /// The cumulative files the compacted history wrote or edited. Optional for
    /// sessions written before the manifest was introduced.
    public var modifiedFiles: [String]?

    public init(
        summary: String,
        tokensBefore: Int,
        firstKeptEntryId: String? = nil,
        retainedTail: [Message]? = nil,
        usage: Usage? = nil,
        readFiles: [String]? = nil,
        modifiedFiles: [String]? = nil
    ) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.firstKeptEntryId = firstKeptEntryId
        self.retainedTail = retainedTail
        self.usage = usage
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
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

// MARK: - Workspace history payloads

/// The append-only operation recorded when conversation and workspace history
/// move together.
public enum SessionHistoryOperation: String, Sendable, Hashable, Codable {
    case undo
    case redo
}

/// A durable record of a workspace history move.
///
/// `fromEntryID` and `targetEntryID` are workspace-checkpoint entry ids, not
/// arbitrary message ids. The entry itself is physically appended after
/// `fromEntryID`, while ``SessionTreeEntry/leafIdAfterEntry`` points the active
/// branch at `targetEntryID`; that is what makes navigation append-only without
/// leaving a synthetic action message in the model context.
public struct SessionHistoryAction: Sendable, Hashable, Codable {
    public let operation: SessionHistoryOperation
    public let fromEntryID: String
    public let targetEntryID: String
    public let fromSnapshotID: String
    public let targetSnapshotID: String
    public let paths: [String]
    public let restoredPaths: [String]
    public let skippedPaths: [String]
    public let failedPaths: [String]
    public let status: WorkspaceSnapshotStatus

    public init(
        operation: SessionHistoryOperation,
        fromEntryID: String,
        targetEntryID: String,
        fromSnapshotID: String,
        targetSnapshotID: String,
        paths: [String],
        restoredPaths: [String] = [],
        skippedPaths: [String] = [],
        failedPaths: [String] = [],
        status: WorkspaceSnapshotStatus
    ) {
        self.operation = operation
        self.fromEntryID = fromEntryID
        self.targetEntryID = targetEntryID
        self.fromSnapshotID = fromSnapshotID
        self.targetSnapshotID = targetSnapshotID
        self.paths = paths
        self.restoredPaths = restoredPaths
        self.skippedPaths = skippedPaths
        self.failedPaths = failedPaths
        self.status = status
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
/// `label`, `session_info` and `model_change`; `session_start` records the Git
/// checkpoint for Phase 12, `workspace_checkpoint` and `history_action` carry
/// Phase 13's append-only file/conversation history, `subagent` records a
/// navigable delegated child, `recovery` records a bounded provider diagnostic,
/// and `leaf` is included because tree navigation records the active tip as a
/// `leaf` entry and it is cheap. The extension-facing
/// entries (`custom`, `custom_message`) and the
/// settings entries pi has for thinking level and dynamic tool sets are
/// deliberately not modeled: DoMoCode has no extension host and no
/// thinking-level or dynamic-tool feature, so a case for each would be a wire
/// shape nothing writes and every switch still has to handle.
public struct SessionTreeEntry: Sendable, Hashable {
    public var id: String

    /// The parent node's id, or `nil` for the first entry in the tree.
    public var parentId: String?

    /// ISO-8601 creation time. A string for the same reason as the header's.
    public var timestamp: String

    public var payload: Payload

    /// A 0-based ordering key, assigned by the writing harness at append time,
    /// scoped to this session **file**.
    ///
    /// It exists because neither `timestamp` nor `id` can answer "how much of
    /// this file have I already seen?" cheaply and correctly: timestamps repeat
    /// within a millisecond and are pinned to a constant in every harness test,
    /// and comparing UUIDv7 ids only works while nothing renumbers. A small
    /// integer lets a reader resume mid-file and lets throughput be reported per
    /// entry.
    ///
    /// It is an **ordering key, never an index or a count**. Gaps are normal and
    /// expected: the tolerant bulk read drops a line that will not decode, a
    /// fork renumbers the surviving path from 0, and a process can die between
    /// minting a number and appending the entry that carries it. Indexing
    /// `entries[entry.seq!]` is therefore wrong, and so is treating the largest
    /// `seq` as "the number of entries".
    ///
    /// Uniqueness within a file is only best effort. The value is monotonic per
    /// *writer*, and nothing in this layer prevents two writers from resuming one
    /// file — `ServerRuntime.forceClearRun` deliberately opens a second harness
    /// on a live session — so two entries can legitimately carry the same number.
    ///
    /// `nil` on every entry written before this field existed, and on any entry
    /// whose writer did not assign one; it is not backfillable, because the
    /// information was never recorded.
    public var seq: Int?

    /// Wall-clock milliseconds this entry's turn took, measured by the writing
    /// harness off a monotonic clock.
    ///
    /// `nil` means "not measured", which is a different claim from `0`
    /// ("measured, and it took under a millisecond") — so a consumer that wants
    /// an average must skip `nil` rather than coalesce it. Entries that are not
    /// the product of a timed turn (a `leaf` move, a `label`) leave it `nil`.
    ///
    /// Preserved verbatim across a fork: it is a real measurement of the original
    /// turn and re-deriving it in the new file is impossible.
    public var elapsedMs: Int?

    /// Usage for a metadata-only LLM call, currently session auto-titling.
    ///
    /// The JSONL envelope already has a `usage` key for compaction and branch
    /// summaries. Reusing it for `session_info` keeps the title's cost recoverable
    /// without changing the established payload case or making every existing
    /// switch over `Payload` grow another associated value.
    public var metadataUsage: Usage?

    public init(
        id: String,
        parentId: String?,
        timestamp: String,
        payload: Payload,
        seq: Int? = nil,
        elapsedMs: Int? = nil,
        metadataUsage: Usage? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.payload = payload
        self.seq = seq
        self.elapsedMs = elapsedMs
        self.metadataUsage = metadataUsage
    }

    /// The type-specific body of an entry.
    public enum Payload: Sendable, Hashable {
        /// A conversation turn.
        case message(Message)
        /// The user switched models mid-session.
        case modelChange(provider: String, modelId: String)
        /// The user selected (or cleared) the persistent agent profile.
        case agentChange(name: String?)
        /// A context-compaction checkpoint.
        case compaction(Compaction)
        /// A summary of an abandoned branch.
        case branchSummary(BranchSummary)
        /// A user bookmark on `targetId`. A `nil` `label` clears it.
        case label(targetId: String, label: String?)
        /// Session metadata such as a user-chosen display name.
        case sessionInfo(name: String?)
        /// The repository commit at which this session began. It is metadata,
        /// not conversation context, and is present only when the caller found
        /// a committed Git HEAD at session creation time.
        case sessionStart(head: String)
        /// A shadow-Git tree captured at a conversation boundary.
        case workspaceCheckpoint(WorkspaceSnapshot)
        /// An undo or redo operation that moved the active branch.
        case historyAction(SessionHistoryAction)
        /// A record that the active leaf moved to `targetId` (`nil` = before the
        /// first entry). Written by tree navigation, not by the conversation.
        case leaf(targetId: String?)
        /// A delegated child-session lifecycle event.
        case subagent(SubagentTaskEvent)
        /// A redacted, typed provider-failure diagnostic. It is durable metadata,
        /// never a model-facing conversation message.
        case recovery(RecoveryEnvelope)
    }
}

extension SessionTreeEntry {
    /// The stable `type` discriminator written to disk for each payload.
    public enum EntryType: String, Sendable {
        case message
        case modelChange = "model_change"
        case agentChange = "agent_change"
        case compaction
        case branchSummary = "branch_summary"
        case label
        case sessionInfo = "session_info"
        case sessionStart = "session_start"
        case workspaceCheckpoint = "workspace_checkpoint"
        case historyAction = "history_action"
        case leaf
        case subagent
        case recovery
    }

    public var entryType: EntryType {
        switch payload {
        case .message: return .message
        case .modelChange: return .modelChange
        case .agentChange: return .agentChange
        case .compaction: return .compaction
        case .branchSummary: return .branchSummary
        case .label: return .label
        case .sessionInfo: return .sessionInfo
        case .sessionStart: return .sessionStart
        case .workspaceCheckpoint: return .workspaceCheckpoint
        case .historyAction: return .historyAction
        case .leaf: return .leaf
        case .subagent: return .subagent
        case .recovery: return .recovery
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
        if case .historyAction(let action) = payload { return action.targetEntryID }
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
        // Envelope, added after the format shipped. This is ONE FLAT namespace
        // shared by all payload shapes (`summary` and `usage` are each
        // used by two of them, `targetId` by two), so a new envelope key has to
        // be checked against every payload's fields, not just the envelope's:
        // neither `seq` nor `elapsedMs` appears in any payload below. `usage`
        // is also reused by `session_info` for an LLM-generated title.
        case seq
        case elapsedMs
        // Payload-specific:
        case message
        case provider
        case modelId
        case agent
        case summary
        case tokensBefore
        case firstKeptEntryId
        case retainedTail
        case usage
        case readFiles
        case modifiedFiles
        case fromId
        case targetId
        case label
        case name
        case head
        case snapshotId
        case previousSnapshotId
        case files
        case operation
        case fromSnapshotId
        case targetSnapshotId
        case restoredPaths
        case skippedPaths
        case failedPaths
        case status
        case subagent
        case recovery
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
        // `decodeIfPresent` so every line written before these fields existed
        // still decodes — the same backward-compatibility move
        // `ToolResultBlock`'s hand-written Codable makes for `images`
        // (`Sources/DoMoLLM/Message.swift`). The encode side omits them when
        // `nil`, so an entry that carries neither is byte-identical to what this
        // format produced before they were added.
        self.seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        self.elapsedMs = try container.decodeIfPresent(Int.self, forKey: .elapsedMs)
        self.metadataUsage = nil

        switch entryType {
        case .message:
            self.payload = .message(try container.decode(Message.self, forKey: .message))
        case .modelChange:
            self.payload = .modelChange(
                provider: try container.decode(String.self, forKey: .provider),
                modelId: try container.decode(String.self, forKey: .modelId)
            )
        case .agentChange:
            self.payload = .agentChange(name: try container.decodeIfPresent(String.self, forKey: .agent))
        case .compaction:
            self.payload = .compaction(
                Compaction(
                    summary: try container.decode(String.self, forKey: .summary),
                    tokensBefore: try container.decode(Int.self, forKey: .tokensBefore),
                    firstKeptEntryId: try container.decodeIfPresent(String.self, forKey: .firstKeptEntryId),
                    retainedTail: try container.decodeIfPresent([Message].self, forKey: .retainedTail),
                    usage: try container.decodeIfPresent(Usage.self, forKey: .usage),
                    readFiles: try container.decodeIfPresent([String].self, forKey: .readFiles),
                    modifiedFiles: try container.decodeIfPresent([String].self, forKey: .modifiedFiles)
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
            self.metadataUsage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        case .sessionStart:
            self.payload = .sessionStart(head: try container.decode(String.self, forKey: .head))
        case .workspaceCheckpoint:
            self.payload = .workspaceCheckpoint(
                WorkspaceSnapshot(
                    id: try container.decode(String.self, forKey: .snapshotId),
                    previousID: try container.decodeIfPresent(String.self, forKey: .previousSnapshotId),
                    files: try container.decode([String].self, forKey: .files)
                )
            )
        case .historyAction:
            let rawOperation = try container.decode(String.self, forKey: .operation)
            guard let operation = SessionHistoryOperation(rawValue: rawOperation) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operation,
                    in: container,
                    debugDescription: "Unknown session history operation: \(rawOperation)"
                )
            }
            let rawStatus = try container.decode(String.self, forKey: .status)
            guard let status = WorkspaceSnapshotStatus(rawValue: rawStatus) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "Unknown workspace snapshot status: \(rawStatus)"
                )
            }
            self.payload = .historyAction(
                SessionHistoryAction(
                    operation: operation,
                    fromEntryID: try container.decode(String.self, forKey: .fromId),
                    targetEntryID: try container.decode(String.self, forKey: .targetId),
                    fromSnapshotID: try container.decode(String.self, forKey: .fromSnapshotId),
                    targetSnapshotID: try container.decode(String.self, forKey: .targetSnapshotId),
                    paths: try container.decode([String].self, forKey: .files),
                    restoredPaths: try container.decode([String].self, forKey: .restoredPaths),
                    skippedPaths: try container.decode([String].self, forKey: .skippedPaths),
                    failedPaths: try container.decode([String].self, forKey: .failedPaths),
                    status: status
                )
            )
        case .leaf:
            self.payload = .leaf(targetId: try container.decodeIfPresent(String.self, forKey: .targetId))
        case .subagent:
            self.payload = .subagent(try container.decode(SubagentTaskEvent.self, forKey: .subagent))
        case .recovery:
            self.payload = .recovery(try container.decode(RecoveryEnvelope.self, forKey: .recovery))
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
        // Omitted when nil, unlike `parentId` above: a missing `seq` is not a
        // distinct state that a reader has to tell apart from anything, and
        // omitting keeps an entry without them byte-for-byte identical to the
        // lines already on disk. `ToolResultBlock.images` omits for the same
        // reason; the `leaf` payload's explicit `null` targetId does not,
        // because there "reset to before the first entry" IS a distinct state.
        try container.encodeIfPresent(seq, forKey: .seq)
        try container.encodeIfPresent(elapsedMs, forKey: .elapsedMs)

        switch payload {
        case .message(let message):
            try container.encode(message, forKey: .message)
        case .modelChange(let provider, let modelId):
            try container.encode(provider, forKey: .provider)
            try container.encode(modelId, forKey: .modelId)
        case .agentChange(let name):
            try container.encodeIfPresent(name, forKey: .agent)
        case .compaction(let compaction):
            try container.encode(compaction.summary, forKey: .summary)
            try container.encode(compaction.tokensBefore, forKey: .tokensBefore)
            try container.encodeIfPresent(compaction.firstKeptEntryId, forKey: .firstKeptEntryId)
            try container.encodeIfPresent(compaction.retainedTail, forKey: .retainedTail)
            try container.encodeIfPresent(compaction.usage, forKey: .usage)
            try container.encodeIfPresent(compaction.readFiles, forKey: .readFiles)
            try container.encodeIfPresent(compaction.modifiedFiles, forKey: .modifiedFiles)
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
            try container.encodeIfPresent(metadataUsage, forKey: .usage)
        case .sessionStart(let head):
            try container.encode(head, forKey: .head)
        case .workspaceCheckpoint(let snapshot):
            try container.encode(snapshot.id, forKey: .snapshotId)
            try container.encodeIfPresent(snapshot.previousID, forKey: .previousSnapshotId)
            try container.encode(snapshot.files, forKey: .files)
        case .historyAction(let action):
            try container.encode(action.operation.rawValue, forKey: .operation)
            try container.encode(action.fromEntryID, forKey: .fromId)
            try container.encode(action.targetEntryID, forKey: .targetId)
            try container.encode(action.fromSnapshotID, forKey: .fromSnapshotId)
            try container.encode(action.targetSnapshotID, forKey: .targetSnapshotId)
            try container.encode(action.paths, forKey: .files)
            try container.encode(action.restoredPaths, forKey: .restoredPaths)
            try container.encode(action.skippedPaths, forKey: .skippedPaths)
            try container.encode(action.failedPaths, forKey: .failedPaths)
            try container.encode(action.status.rawValue, forKey: .status)
        case .leaf(let targetId):
            // Present as `null` when the leaf is reset to before the first entry,
            // which is a distinct state from "no targetId field".
            try container.encode(targetId, forKey: .targetId)
        case .subagent(let event):
            try container.encode(event, forKey: .subagent)
        case .recovery(let envelope):
            try container.encode(envelope, forKey: .recovery)
        }
    }
}
