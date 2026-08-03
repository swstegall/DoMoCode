// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/session/session.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Context building

/// Controls how persisted tool results are projected into a model context.
///
/// The session JSONL remains the source of truth. This policy only changes the
/// transient messages sent to the model, so a later context inspection or a
/// resumed session can still inspect the complete result. Older tool results
/// are replaced by a short marker; oversized results also spill their full text
/// to a mode-restricted sidecar file and include its path in that marker.
public struct ContextOutputPolicy: Sendable, Hashable {
    /// The maximum number of characters retained from one tool result in the
    /// model-facing context.
    public var maximumToolOutputCharacters: Int

    /// Number of most-recent user turns whose tool results remain verbatim.
    /// Zero prunes every tool result; a negative value is clamped to zero.
    public var recentToolOutputTurns: Int

    /// Directory for full oversized results. Nil keeps the projection
    /// in-memory and reports that the omitted tail is unavailable from this
    /// context build.
    public var spillDirectory: String?

    public init(
        maximumToolOutputCharacters: Int = 20_000,
        recentToolOutputTurns: Int = 4,
        spillDirectory: String? = nil
    ) {
        self.maximumToolOutputCharacters = max(1, maximumToolOutputCharacters)
        self.recentToolOutputTurns = max(0, recentToolOutputTurns)
        self.spillDirectory = spillDirectory
    }

    public static let `default` = ContextOutputPolicy()
    public static let standard = ContextOutputPolicy()
}

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
    /// - `model_change`, `label`, `session_info`, `session_start` and `leaf` are metadata: they
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
        case .branchSummary, .modelChange, .label, .sessionInfo, .sessionStart, .leaf:
            return []
        }
    }

    /// The full message list for a resolved path: select the in-context entries,
    /// then project each to its messages.
    public static func messages(for pathEntries: [SessionTreeEntry]) -> [Message] {
        contextEntries(for: pathEntries).flatMap(messages(for:))
    }

    /// Build the model-facing context and apply a transient tool-output policy.
    ///
    /// The unqualified messages(for:) overload intentionally remains the
    /// lossless projection used by compaction and tree tests. Callers that are
    /// about to send a context to a provider use this overload so pruning never
    /// mutates the append-only session history.
    public static func messages(
        for pathEntries: [SessionTreeEntry],
        outputPolicy: ContextOutputPolicy
    ) throws -> [Message] {
        let messages = contextEntries(for: pathEntries).flatMap(messages(for:))
        return try pruneToolOutputs(messages, policy: outputPolicy)
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

    /// Resolve and project a session path with transient tool-output pruning.
    public static func buildContext(
        _ tree: SessionTree,
        from leafID: String? = nil,
        outputPolicy: ContextOutputPolicy
    ) throws -> [Message] {
        try messages(
            for: tree.pathToRootOrCompaction(from: leafID),
            outputPolicy: outputPolicy
        )
    }

    // MARK: - Tool-output projection

    private static func pruneToolOutputs(
        _ messages: [Message],
        policy: ContextOutputPolicy
    ) throws -> [Message] {
        let userTurnCount = messages.reduce(into: 0) { count, message in
            if case .user = message { count += 1 }
        }
        var currentUserTurn = 0
        var projected: [Message] = []
        projected.reserveCapacity(messages.count)

        for (index, message) in messages.enumerated() {
            switch message {
            case .user:
                currentUserTurn += 1
                projected.append(message)
            case .tool(let result):
                let age = userTurnCount - currentUserTurn
                let recent = age < policy.recentToolOutputTurns
                let oversized = result.output.count > policy.maximumToolOutputCharacters
                guard !recent || oversized || !result.images.isEmpty else {
                    projected.append(message)
                    continue
                }
                projected.append(
                    .tool(
                        try projectedToolResult(
                            result,
                            index: index,
                            keepRecent: recent,
                            policy: policy
                        )
                    )
                )
            default:
                projected.append(message)
            }
        }
        return projected
    }

    private static func projectedToolResult(
        _ result: ToolResultBlock,
        index: Int,
        keepRecent: Bool,
        policy: ContextOutputPolicy
    ) throws -> ToolResultBlock {
        let oversized = result.output.count > policy.maximumToolOutputCharacters
        var spillPath: String?
        if oversized, let directory = policy.spillDirectory {
            let path = "\(directory)/\(spillFileName(toolCallID: result.toolCallID, index: index))"
            try AtomicFileWrite.replace(at: path, with: result.output)
            spillPath = path
        }

        let marker: String
        if let spillPath {
            marker = "[Tool output pruned from context. Full output: \(spillPath)]"
        } else if oversized {
            marker = "[Tool output pruned from context; the full \(result.output.count)-character result was not spilled]"
        } else {
            marker = "[Tool output pruned from older context (\(result.output.count) characters)]"
        }

        let output: String
        if keepRecent {
            output = boundedPreview(result.output, maximumCharacters: policy.maximumToolOutputCharacters)
                + "\n\n"
                + marker
        } else {
            output = marker
        }

        return ToolResultBlock(
            toolCallID: result.toolCallID,
            toolName: result.toolName,
            output: output,
            isError: result.isError,
            // An old image can be as expensive as its text. It remains in the
            // durable entry, but only recent image-bearing results are sent.
            images: keepRecent ? result.images : []
        )
    }

    private static func boundedPreview(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let headCount = max(1, maximumCharacters / 2)
        let tailCount = max(0, maximumCharacters - headCount)
        let head = String(text.prefix(headCount))
        let tail = tailCount == 0 ? "" : String(text.suffix(tailCount))
        return head + "\n\n[... middle omitted from context ...]\n\n" + tail
    }

    private static func spillFileName(toolCallID: String, index: Int) -> String {
        let safeID = toolCallID
            .map { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    ? String(character)
                    : "-"
            }
            .joined()
        let trimmed = String(safeID.prefix(64))
        return "tool-\(index)-\(trimmed.isEmpty ? "output" : trimmed).txt"
    }

}
