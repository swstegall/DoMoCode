// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/session/session.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Context building

/// Projects a resolved session path into the `[Message]` list an agent run is
/// seeded with.
///
/// The two stages are kept separate on purpose. ``contextEntries(for:)`` decides
/// *which* entries are in play once compaction is accounted for; ``messages(for:)``
/// turns those entries into what the model actually reads. Splitting them is what
/// lets an interactive layer render the selected entries (labels, model changes)
/// while the model sees only the messages — pi's `buildContextEntries` versus
/// `buildSessionContext`.
public enum ContextBuilder {
    /// Text wrapped around a compaction summary so the model reads it as a
    /// recap of everything before the checkpoint rather than as live dialogue.
    /// Verbatim from pi so a summary written by one and replayed by the other
    /// lands identically.
    static let compactionSummaryPrefix = """
        The conversation history before this point was compacted into the following summary:

        <summary>

        """
    static let compactionSummarySuffix = "\n</summary>"

    /// Text wrapped around a branch summary, distinguishing "a path we came back
    /// from" from "the history before a checkpoint".
    static let branchSummaryPrefix = """
        The following is a summary of a branch that this conversation came back from:

        <summary>

        """
    static let branchSummarySuffix = "</summary>"

    /// Applies the compaction transform to a leaf→root path, yielding the entries
    /// that are actually in context.
    ///
    /// A path with no compaction passes through unchanged. Otherwise the *last*
    /// compaction on the path is the checkpoint: the returned list begins with it
    /// (its summary stands in for everything earlier), then includes the retained
    /// span — the entries after it when a `retainedTail` makes it self-contained,
    /// or the entries from `firstKeptEntryId` onward for a legacy compaction that
    /// stored only the pointer. This is pi's `defaultContextEntryTransform`.
    ///
    /// The input is expected to be a ``SessionTree/pathToRootOrCompaction(from:)``
    /// result, which already stops the walk at the checkpoint; running the
    /// transform over it is idempotent for the `retainedTail` case and reselects
    /// the kept span for the legacy case, matching pi's `buildContext` pipeline
    /// exactly.
    public static func contextEntries(for pathEntries: [SessionTreeEntry]) -> [SessionTreeEntry] {
        var compaction: (entry: SessionTreeEntry, detail: Compaction)?
        for entry in pathEntries {
            if case .compaction(let detail) = entry.payload {
                compaction = (entry, detail)
            }
        }
        guard let compaction else { return pathEntries }

        let compactionIndex = pathEntries.firstIndex { $0.id == compaction.entry.id } ?? 0
        var result: [SessionTreeEntry] = [compaction.entry]
        if compaction.detail.retainedTail != nil {
            result.append(contentsOf: pathEntries[(compactionIndex + 1)...])
            return result
        }
        if let firstKeptEntryID = compaction.detail.firstKeptEntryId {
            var foundFirstKept = false
            for entry in pathEntries[..<compactionIndex] {
                if entry.id == firstKeptEntryID { foundFirstKept = true }
                if foundFirstKept { result.append(entry) }
            }
        }
        result.append(contentsOf: pathEntries[(compactionIndex + 1)...])
        return result
    }

    /// The context messages one entry contributes, in order.
    ///
    /// - `message` is its own ``Message``.
    /// - `compaction` becomes its wrapped summary message, followed by the
    ///   materialized `retainedTail` (the recent turns kept verbatim after the
    ///   checkpoint), if any.
    /// - `branch_summary` becomes its wrapped summary message, but only when it
    ///   carries text — an empty summary contributes nothing.
    /// - `model_change`, `label`, `session_info` and `leaf` are metadata: they
    ///   steer the harness or the UI and are never shown to the model, so they
    ///   contribute no message. This is pi's `sessionEntryToContextMessages`.
    ///
    /// pi's `compactionSummary`/`branchSummary` message roles do not exist in this
    /// port's ``Message``; pi collapses them to `user` messages with the wrapping
    /// text at `convertToLlm` time, so the projection produces that `user` message
    /// directly.
    public static func messages(for entry: SessionTreeEntry) -> [Message] {
        switch entry.payload {
        case .message(let message):
            return [message]
        case .compaction(let compaction):
            let summary = Message.user(compactionSummaryPrefix + compaction.summary + compactionSummarySuffix)
            return [summary] + (compaction.retainedTail ?? [])
        case .branchSummary(let branch) where !branch.summary.isEmpty:
            return [Message.user(branchSummaryPrefix + branch.summary + branchSummarySuffix)]
        case .branchSummary, .modelChange, .label, .sessionInfo, .leaf:
            return []
        }
    }

    /// The full message list for a resolved path: select the in-context entries,
    /// then project each to its messages.
    public static func messages(for pathEntries: [SessionTreeEntry]) -> [Message] {
        contextEntries(for: pathEntries).flatMap(messages(for:))
    }

    /// The messages for a session's active branch: resolve the path from the leaf
    /// to the root or nearest compaction, then project.
    ///
    /// Resolution throws on a dangling `parentId` in the active chain (see
    /// ``SessionTree/pathToRootOrCompaction(from:)``) even though the entries were
    /// bulk-read tolerantly — feeding the model a silently truncated conversation
    /// is the failure this refuses. The result is ordered oldest-first, ready to
    /// seed `AgentContext.messages`.
    public static func buildContext(_ tree: SessionTree, from leafID: String? = nil) throws -> [Message] {
        messages(for: try tree.pathToRootOrCompaction(from: leafID))
    }
}
