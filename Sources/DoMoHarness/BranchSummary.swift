// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/compaction/branch-summarization.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Selection

/// The pure outcome of choosing which of a branch's messages to summarize.
///
/// Like ``CompactionPreparation``, this is decided without a model so the
/// selection and its token budgeting can be tested against fixed inputs; only the
/// summary prose is deferred to an injected ``Summarizer``.
public struct BranchPreparation: Sendable, Hashable {
    /// The branch messages to summarize, oldest first, trimmed to the budget.
    public var messages: [Message]

    /// Read-only files the branch touched, for the digest.
    public var readFiles: [String]

    /// Modified files the branch touched, for the digest.
    public var modifiedFiles: [String]

    /// Estimated tokens of the selected messages.
    public var totalTokens: Int

    public init(messages: [Message], readFiles: [String], modifiedFiles: [String], totalTokens: Int) {
        self.messages = messages
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
        self.totalTokens = totalTokens
    }
}

/// Project one branch entry to the message it contributes, or `nil`.
///
/// Tool results are dropped: a branch summary is a narrative of what the branch
/// did, and a bare tool result with no surrounding call reads as noise in it.
/// Compaction and branch-summary entries contribute their already-written summary
/// text as a user message, so a branch that itself contains earlier summaries
/// still folds them in.
private func branchMessage(from entry: SessionTreeEntry) -> Message? {
    switch entry.payload {
    case .message(let message):
        if case .tool = message { return nil }
        return message
    case .branchSummary(let branch): return .user(UserMessage(content: [.text(branch.summary)]))
    case .compaction(let compaction): return .user(UserMessage(content: [.text(compaction.summary)]))
    case .modelChange, .label, .sessionInfo, .leaf: return nil
    }
}

/// Select branch entries to summarize, newest-first within an optional token
/// budget.
///
/// A `tokenBudget` of `0` means no limit. When the budget is exceeded mid-walk the
/// selection stops, except that a compaction or branch-summary message — which is
/// itself a dense checkpoint worth keeping — is still admitted if there is slack
/// under 90% of the budget, matching pi. File operations are accumulated across
/// every considered message so the digest reflects the whole branch even when the
/// summarized slice is trimmed.
///
/// pi additionally seeds file operations from a prior branch-summary entry's
/// stored `details`; this port does not model those details on ``BranchSummary``
/// (they are extension/legacy only), so that seeding is intentionally absent.
public func prepareBranchEntries(_ entries: [SessionTreeEntry], tokenBudget: Int = 0) -> BranchPreparation {
    var fileOps = FileOperations()
    var messages: [Message] = []
    var totalTokens = 0

    for index in stride(from: entries.count - 1, through: 0, by: -1) {
        let entry = entries[index]
        guard let message = branchMessage(from: entry) else { continue }
        extractFileOps(from: message, into: &fileOps)

        let tokens = estimateTokens(message)
        if tokenBudget > 0, totalTokens + tokens > tokenBudget {
            let isCheckpoint: Bool
            switch entry.payload {
            case .compaction, .branchSummary: isCheckpoint = true
            default: isCheckpoint = false
            }
            if isCheckpoint, totalTokens < (tokenBudget * 9) / 10 {
                messages.insert(message, at: 0)
                totalTokens += tokens
            }
            break
        }

        messages.insert(message, at: 0)
        totalTokens += tokens
    }

    let lists = computeFileLists(fileOps)
    return BranchPreparation(
        messages: messages,
        readFiles: lists.readFiles,
        modifiedFiles: lists.modifiedFiles,
        totalTokens: totalTokens
    )
}

// MARK: - Entry construction

/// Prepended to every branch summary so the model, on returning to this leaf,
/// reads the summary as an aside about a path not taken rather than as the
/// conversation continuing.
let branchSummaryPreamble = """
The user explored a different conversation branch before returning here.
Summary of that exploration:


"""

/// Build the branch-summary entry from a preparation and a ready summary — pure,
/// so the entry's shape is testable without a model call.
///
/// The stock preamble and the file-operations digest bracket the summary text,
/// matching pi, so the stored summary is self-describing.
public func makeBranchSummaryEntry(
    from preparation: BranchPreparation,
    fromId: String,
    id: String,
    parentId: String?,
    timestamp: String,
    summary: String,
    usage: Usage? = nil
) -> SessionTreeEntry {
    let digest = formatFileOperations(readFiles: preparation.readFiles, modifiedFiles: preparation.modifiedFiles)
    let branch = BranchSummary(fromId: fromId, summary: branchSummaryPreamble + summary + digest, usage: usage)
    return SessionTreeEntry(id: id, parentId: parentId, timestamp: timestamp, payload: .branchSummary(branch))
}

/// Run the injected summarizer over the prepared branch and return the finished
/// branch-summary entry.
///
/// With nothing selected — an empty branch, or one that projected to no messages —
/// the summarizer is not called and a fixed "No content to summarize" entry is
/// written, matching pi and sparing a pointless model round-trip. A summarizer
/// that throws propagates unchanged.
public func summarizeBranch(
    _ preparation: BranchPreparation,
    fromId: String,
    id: String,
    parentId: String?,
    timestamp: String,
    usage: Usage? = nil,
    summarize: Summarizer
) async throws -> SessionTreeEntry {
    guard !preparation.messages.isEmpty else {
        let branch = BranchSummary(fromId: fromId, summary: "No content to summarize", usage: usage)
        return SessionTreeEntry(id: id, parentId: parentId, timestamp: timestamp, payload: .branchSummary(branch))
    }
    let summary = try await summarize(preparation.messages)
    return makeBranchSummaryEntry(
        from: preparation,
        fromId: fromId,
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        summary: summary,
        usage: usage
    )
}
