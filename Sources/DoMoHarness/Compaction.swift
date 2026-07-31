// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/compaction/compaction.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

// MARK: - Summarization seam

/// What a summarization call produced: the prose, and what the call itself cost.
///
/// The usage rides back with the text rather than being supplied separately by
/// the orchestrator because the summarizer is the only thing that *knows* it.
/// Before this existed, ``Compaction/usage`` and ``BranchSummary/usage`` were
/// documented as "folded into session totals" and were unconditionally `nil` in
/// every session file ever written — the harness called ``compact(_:id:parentId:timestamp:usage:summarize:)``
/// without a `usage:` argument, and had nothing to pass even if it had. A
/// summarization request is a real, billable model call; leaving it out of the
/// total made every session look cheaper than it was, by exactly the turns it
/// worked hardest on.
///
/// `usage` is optional because a summarizer legitimately may not know: a
/// hand-written test double, or a cached summary, has no token counts to report.
/// `nil` means "not measured" and is never treated as zero.
public struct SummarizerResult: Sendable, Hashable {
    /// The summary prose. The only part the entry builder puts in front of the
    /// model.
    public var text: String

    /// Token/cost accounting for the summarization call, when the summarizer
    /// knows it.
    public var usage: Usage?

    public init(text: String, usage: Usage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// The LLM call that turns a slice of history into a summary.
///
/// It is injected rather than performed here so this whole file stays pure and
/// synchronous to test: the selection of what to summarize, the token math and
/// the entry it builds are all decided without a model, and only the summary
/// prose — and the price of producing it — come from outside.
public typealias Summarizer = @Sendable ([Message]) async throws -> SummarizerResult

// MARK: - Prompts

/// The text of the summarization request.
///
/// It lives here, beside the compaction logic, rather than on the harness that
/// happens to construct the default model call, because it is not the harness's
/// property: a CLI that points compaction at a cheaper small model builds its own
/// summarizer and must send the *same* words, or two sessions of the same
/// conversation compact into differently-shaped summaries depending on which
/// component made the request. One text, two callers.
public enum CompactionPrompts {
    /// The system prompt for a summarization request.
    public static let system =
        "You are summarizing a conversation so it can be continued with less context. "
        + "Produce a concise, faithful summary that preserves decisions, open questions, and any "
        + "facts the assistant will need to continue the task."

    /// The trailing user instruction appended after the history to summarize.
    public static let instruction =
        "Summarize the conversation so far, preserving everything needed to continue."

    /// A running summary that predates the messages being compacted, wrapped as
    /// the leading message of the next summarization request.
    ///
    /// Without it the second compaction of a path silently drops everything the
    /// first checkpoint stood for: the older messages are already gone from the
    /// path, so only the standing summary still represents them.
    public static func priorSummaryPreamble(_ previous: String) -> String {
        """
        The following is the running summary of the conversation before this point. \
        Fold it into the new summary so nothing it records is lost:

        """ + previous
    }
}

// MARK: - Token estimation

/// The context size implied by one provider ``Usage``.
///
/// pi computes `usage.totalTokens || input + output + cacheRead + cacheWrite`,
/// falling back to the sum when a provider reports no explicit total. In this
/// port ``Usage/totalTokens`` *is* that sum by construction, so the fallback is a
/// no-op — the function is kept as the named entry point the compaction logic and
/// its doc comments refer to, not as arithmetic that earns its own line.
public func calculateContextTokens(_ usage: Usage) -> Int {
    usage.totalTokens
}

/// A per-image proxy for vision-token cost, in the pre-divide character unit this
/// estimate accumulates. The real cost is model-dependent (tile-based on OpenAI,
/// area-based on Anthropic) and unknowable behind the gateway, so one conservative
/// constant stands in: roughly 1,500 tokens' worth, deliberately high — an image
/// that counted as zero is exactly how an image-bearing tail slips a request past
/// the window.
private let imageEstimatedChars = 6_000

/// A conservative per-message token estimate: characters divided by four, rounded
/// up, summed over the content this port can carry — images included, as a fixed
/// per-attachment proxy (see ``imageEstimatedChars``).
///
/// It exists for the messages a request has not yet been billed for — the tail
/// after the last assistant ``Usage`` — where there is no provider number to
/// trust. It is deliberately an over-estimate: undershooting here is what lets a
/// request quietly exceed the window between the check and the send.
public func estimateTokens(_ message: Message) -> Int {
    var chars = 0
    switch message {
    case .system(let system):
        chars = system.content.count
    case .user(let user):
        for block in user.content {
            if let text = block.textBlock {
                chars += text.text.count
            } else if block.imageBlock != nil {
                chars += imageEstimatedChars
            }
        }
    case .assistant(let assistant):
        for block in assistant.content {
            switch block {
            case .text(let text): chars += text.text.count
            case .reasoning(let reasoning): chars += reasoning.text.count
            case .toolCall(let call): chars += call.name.count + argumentsJSON(call.arguments).count
            case .toolResult: break
            case .image: chars += imageEstimatedChars
            }
        }
    case .tool(let result):
        chars = result.output.count + result.images.count * imageEstimatedChars
    }
    // Integer ceil(chars / 4), matching pi's `Math.ceil(chars / 4)` without ever
    // touching floating point.
    return (chars + 3) / 4
}

/// The JSON text of tool-call arguments, or a stable placeholder when it will not
/// serialize — mirroring pi's `safeJsonStringify`, so the character count of a
/// pathological arguments object never crashes the estimate.
private func argumentsJSON(_ arguments: JSONValue) -> String {
    (try? arguments.encodedString()) ?? "[unserializable]"
}

/// The ``Usage`` of `message` when it is a completed assistant turn that actually
/// consumed context, else `nil`.
///
/// Aborted and errored turns are skipped: their usage reflects a request that did
/// not land, and treating it as the standing context size would make compaction
/// fire on a failure that left the context unchanged.
private func assistantContextUsage(_ message: Message) -> Usage? {
    guard case .assistant(let assistant) = message else { return nil }
    guard assistant.stopReason != .aborted, assistant.stopReason != .error else { return nil }
    let usage = assistant.usage
    guard calculateContextTokens(usage) > 0 else { return nil }
    return usage
}

/// A context-size estimate for a message list, split into its trusted and
/// estimated halves.
public struct ContextUsageEstimate: Sendable, Hashable {
    /// Total estimated context tokens: `usageTokens + trailingTokens`.
    public var tokens: Int
    /// Tokens reported by the most recent assistant ``Usage``, or `0` when none
    /// exists.
    public var usageTokens: Int
    /// Heuristic tokens for the messages after that usage block.
    public var trailingTokens: Int
    /// Index of the message that supplied `usageTokens`, or `nil` when none did.
    public var lastUsageIndex: Int?

    public init(tokens: Int, usageTokens: Int, trailingTokens: Int, lastUsageIndex: Int?) {
        self.tokens = tokens
        self.usageTokens = usageTokens
        self.trailingTokens = trailingTokens
        self.lastUsageIndex = lastUsageIndex
    }
}

/// Estimate the context tokens a message list would occupy.
///
/// The heuristic anchors on the last real assistant ``Usage`` — the provider's
/// count for everything up to and including that turn — and only *estimates* the
/// tail after it. With no assistant usage anywhere (a session that has not yet
/// completed a turn), it falls back to the character heuristic over every message.
public func estimateContextTokens(_ messages: [Message]) -> ContextUsageEstimate {
    var anchor: (usage: Usage, index: Int)?
    for index in stride(from: messages.count - 1, through: 0, by: -1) {
        if let usage = assistantContextUsage(messages[index]) {
            anchor = (usage, index)
            break
        }
    }

    guard let anchor else {
        var estimated = 0
        for message in messages { estimated += estimateTokens(message) }
        return ContextUsageEstimate(tokens: estimated, usageTokens: 0, trailingTokens: estimated, lastUsageIndex: nil)
    }

    let usageTokens = calculateContextTokens(anchor.usage)
    var trailing = 0
    var index = anchor.index + 1
    while index < messages.count {
        trailing += estimateTokens(messages[index])
        index += 1
    }
    return ContextUsageEstimate(
        tokens: usageTokens + trailing,
        usageTokens: usageTokens,
        trailingTokens: trailing,
        lastUsageIndex: anchor.index
    )
}

// MARK: - Settings

/// When compaction fires and how much recent context it keeps.
public struct CompactionSettings: Sendable, Hashable, Codable {
    /// Whether automatic compaction runs at all. When off, ``shouldCompact(contextTokens:contextWindow:settings:)``
    /// is always `false`.
    public var enabled: Bool

    /// Tokens held back from the window for the summarization prompt and its
    /// output. Compaction triggers before the window is full so there is room to
    /// summarize; a reserve smaller than the summary round-trip would let
    /// compaction itself overflow.
    public var reserveTokens: Int

    /// Approximate tokens of recent history to keep verbatim after a compaction,
    /// so the summary never swallows the turn in progress.
    public var keepRecentTokens: Int

    /// Negative budgets are clamped to zero rather than rejected, because this
    /// initializer cannot throw and a negative reserve is not merely odd — it
    /// pushes the trigger threshold *above* the window, so compaction never fires
    /// and the run grows into a provider overflow. The decoder below, which can
    /// throw, refuses them outright so a settings file is told about its mistake
    /// instead of having it silently corrected.
    public init(enabled: Bool = true, reserveTokens: Int = 16384, keepRecentTokens: Int = 20000) {
        self.enabled = enabled
        self.reserveTokens = max(0, reserveTokens)
        self.keepRecentTokens = max(0, keepRecentTokens)
    }

    /// pi's defaults: a 16K reserve and ~20K of retained recent context.
    public static let `default` = CompactionSettings()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case reserveTokens
        case keepRecentTokens
    }

    /// Decodes a **partial** settings object, filling anything absent from the
    /// defaults.
    ///
    /// The synthesized decoder this replaces required all three keys, so the most
    /// natural thing a user could write — `"compaction": {"enabled": false}` — was
    /// a hard parse failure of the whole settings file. Every key is now
    /// `decodeIfPresent`, which is also what makes ``CompactionOverrides`` and this
    /// type decode from the same JSON shape.
    ///
    /// A negative budget is refused rather than clamped: this is authored
    /// configuration, and telling the author their number was ignored is worth
    /// more than quietly starting up with a different one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let reserveTokens = try container.decodeIfPresent(Int.self, forKey: .reserveTokens) ?? 16384
        let keepRecentTokens = try container.decodeIfPresent(Int.self, forKey: .keepRecentTokens) ?? 20000
        guard reserveTokens >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .reserveTokens,
                in: container,
                debugDescription: "reserveTokens must not be negative; got \(reserveTokens)"
            )
        }
        guard keepRecentTokens >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .keepRecentTokens,
                in: container,
                debugDescription: "keepRecentTokens must not be negative; got \(keepRecentTokens)"
            )
        }
        self.init(enabled: enabled, reserveTokens: reserveTokens, keepRecentTokens: keepRecentTokens)
    }

    /// These settings made workable against a known `contextWindow`.
    ///
    /// The two budgets are absolute token counts while the window is per-model, so
    /// nothing stops them from claiming the whole thing. The shipped defaults do
    /// exactly that on a 32K model: `16384 + 20000 = 36384` exceeds the window, so
    /// ``shouldCompact(contextTokens:contextWindow:settings:)`` fires at 15,616
    /// tokens, ``prepareCompaction(pathEntries:settings:)`` then finds nothing
    /// older than the 20,000-token recent budget and returns `nil`, and the run
    /// proceeds over-full with no entry written and nothing said. Silence is the
    /// worst part: the session simply grows until the provider rejects it.
    ///
    /// The rule is that the reserve and the recent budget together may claim at
    /// most **half** the window. That makes the post-compaction context at most
    /// half the window by construction, so every compaction demonstrably makes
    /// room, and the next turn always has the other half to work in. When they
    /// claim more, both are scaled down by the same factor so their sum lands on
    /// that budget — the ratio the caller asked for is preserved, only its scale
    /// is not.
    ///
    /// A window that already leaves the budgets room is returned **unchanged**, so
    /// the default 200K path is byte-for-byte what it was. Applying this twice is
    /// a no-op, since the first application already satisfies the bound.
    public func clamped(toContextWindow contextWindow: Int) -> CompactionSettings {
        guard contextWindow > 0 else { return self }
        let budget = contextWindow / 2
        let (sum, overflowed) = reserveTokens.addingReportingOverflow(keepRecentTokens)
        if overflowed {
            // Nothing meaningful to preserve about the ratio of two numbers whose
            // sum does not fit in an Int; split the budget evenly.
            return CompactionSettings(
                enabled: enabled,
                reserveTokens: budget / 2,
                keepRecentTokens: budget - budget / 2
            )
        }
        guard sum > budget else { return self }
        return CompactionSettings(
            enabled: enabled,
            reserveTokens: Self.scale(reserveTokens, into: budget, of: sum),
            keepRecentTokens: Self.scale(keepRecentTokens, into: budget, of: sum)
        )
    }

    /// `value * budget / total`, without trusting the product to fit.
    private static func scale(_ value: Int, into budget: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        let (product, overflowed) = value.multipliedReportingOverflow(by: budget)
        // Dividing first loses precision, which is strictly better than trapping.
        guard !overflowed else { return (value / total) * budget }
        return product / total
    }
}

// MARK: - Settings overrides

/// A settings file's partial statement about compaction: every field optional,
/// so "say nothing" and "say `false`" are different answers.
///
/// It is a separate type from ``CompactionSettings`` rather than an
/// all-optional version of it because the two answer different questions. The
/// settings value is what the harness runs on and always has all three numbers;
/// the override is what a *layer* of configuration said, and merging layers
/// requires being able to tell an absent key from a defaulted one — a project
/// file that omits `enabled` must not overwrite a user file that set it.
///
/// ``model`` has no counterpart on ``CompactionSettings`` on purpose: the harness
/// does not select models, it runs an injected ``Summarizer``. The name is
/// consumed one layer up, where a small-model summarizer is built and installed.
public struct CompactionOverrides: Sendable, Hashable, Codable {
    public var enabled: Bool?
    public var reserveTokens: Int?
    public var keepRecentTokens: Int?

    /// The model alias to summarize with. Read by whoever builds the summarizer;
    /// ``applied(to:)`` cannot carry it, because its result has nowhere to put it.
    public var model: String?

    public init(
        enabled: Bool? = nil,
        reserveTokens: Int? = nil,
        keepRecentTokens: Int? = nil,
        model: String? = nil
    ) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
        self.model = model
    }

    /// `base` with every field this override actually states replaced.
    ///
    /// ``model`` is deliberately dropped — see the note on the property.
    public func applied(to base: CompactionSettings) -> CompactionSettings {
        CompactionSettings(
            enabled: enabled ?? base.enabled,
            reserveTokens: reserveTokens ?? base.reserveTokens,
            keepRecentTokens: keepRecentTokens ?? base.keepRecentTokens
        )
    }

    /// This override layered on top of a weaker one, **field by field**: each
    /// field this one states wins, each field it is silent about falls through.
    ///
    /// Field-by-field and not whole-entry, matching how every other numeric knob
    /// in this configuration merges: a project file that only tunes
    /// `keepRecentTokens` must not silently discard the user's `model` choice.
    public func merged(over other: CompactionOverrides) -> CompactionOverrides {
        CompactionOverrides(
            enabled: enabled ?? other.enabled,
            reserveTokens: reserveTokens ?? other.reserveTokens,
            keepRecentTokens: keepRecentTokens ?? other.keepRecentTokens,
            model: model ?? other.model
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case reserveTokens
        case keepRecentTokens
        case model
    }

    /// Same validation as ``CompactionSettings/init(from:)``, so a negative budget
    /// is caught in whichever of the two shapes it was written in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        let reserve = try container.decodeIfPresent(Int.self, forKey: .reserveTokens)
        let keepRecent = try container.decodeIfPresent(Int.self, forKey: .keepRecentTokens)
        let model = try container.decodeIfPresent(String.self, forKey: .model)
        if let reserve, reserve < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .reserveTokens,
                in: container,
                debugDescription: "reserveTokens must not be negative; got \(reserve)"
            )
        }
        if let keepRecent, keepRecent < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .keepRecentTokens,
                in: container,
                debugDescription: "keepRecentTokens must not be negative; got \(keepRecent)"
            )
        }
        self.init(enabled: enabled, reserveTokens: reserve, keepRecentTokens: keepRecent, model: model)
    }
}

/// Whether the running context has grown close enough to the window to compact.
///
/// The threshold is `contextWindow - reserveTokens`, not the window itself: the
/// summarization call needs room to run, so compaction must trigger while there
/// is still slack.
public func shouldCompact(contextTokens: Int, contextWindow: Int, settings: CompactionSettings) -> Bool {
    guard settings.enabled else { return false }
    return contextTokens > contextWindow - settings.reserveTokens
}

// MARK: - File-operations digest

/// The files a stretch of history touched, tracked so a compaction summary can
/// name them even though the tool calls that read and wrote them are gone.
public struct FileOperations: Sendable, Hashable {
    public var read: Set<String>
    public var written: Set<String>
    public var edited: Set<String>

    public init(read: Set<String> = [], written: Set<String> = [], edited: Set<String> = []) {
        self.read = read
        self.written = written
        self.edited = edited
    }
}

/// Fold one message's file-touching tool calls into `fileOps`.
///
/// Only assistant tool calls carry file paths, and only the three file tools are
/// recognized: a call with no `path` argument, or to any other tool, contributes
/// nothing. The tool *names* are pi's (`read`/`write`/`edit`); a backend that
/// renames them must adapt here.
public func extractFileOps(from message: Message, into fileOps: inout FileOperations) {
    guard case .assistant(let assistant) = message else { return }
    for block in assistant.content {
        guard case .toolCall(let call) = block, let path = call.arguments["path"]?.stringValue else { continue }
        switch call.name {
        case "read": fileOps.read.insert(path)
        case "write": fileOps.written.insert(path)
        case "edit": fileOps.edited.insert(path)
        default: break
        }
    }
}

/// Accumulate the file operations across a whole message list.
public func fileOperations(from messages: [Message]) -> FileOperations {
    var fileOps = FileOperations()
    for message in messages { extractFileOps(from: message, into: &fileOps) }
    return fileOps
}

/// Split accumulated operations into a read-only list and a modified list.
///
/// A file that was both read and later written or edited counts only as modified:
/// the summary reader cares that its current contents differ from what was read,
/// not that it was ever read. Both lists are sorted so the digest is stable.
public func computeFileLists(_ fileOps: FileOperations) -> (readFiles: [String], modifiedFiles: [String]) {
    let modified = fileOps.edited.union(fileOps.written)
    let readOnly = fileOps.read.subtracting(modified).sorted()
    return (readOnly, modified.sorted())
}

/// Render read/modified file lists as the `<read-files>`/`<modified-files>` tag
/// block appended to a summary, or `""` when there is nothing to report.
public func formatFileOperations(readFiles: [String], modifiedFiles: [String]) -> String {
    var sections: [String] = []
    if !readFiles.isEmpty {
        sections.append("<read-files>\n\(readFiles.joined(separator: "\n"))\n</read-files>")
    }
    if !modifiedFiles.isEmpty {
        sections.append("<modified-files>\n\(modifiedFiles.joined(separator: "\n"))\n</modified-files>")
    }
    if sections.isEmpty { return "" }
    return "\n\n" + sections.joined(separator: "\n\n")
}

// MARK: - Selection

/// The pure outcome of deciding what a compaction summarizes and what it keeps.
///
/// Everything a summarizer and the entry builder need is here, with no model call
/// and no persistence — which is what lets the whole selection be tested against
/// fixed inputs.
public struct CompactionPreparation: Sendable, Hashable {
    /// The older messages the summary will replace, oldest first.
    public var messagesToSummarize: [Message]

    /// The recent messages kept verbatim, materialized so the checkpoint is
    /// self-contained. Stored directly on the compaction entry's ``Compaction/retainedTail``.
    public var retainedTail: [Message]

    /// The id of the first retained entry, kept as a legacy/diagnostic pointer.
    /// ``retainedTail`` is the authoritative record of what survives; this can be
    /// `nil` when the retained tail is materialized from a prior checkpoint and
    /// has no backing entry.
    public var firstKeptEntryId: String?

    /// Estimated context tokens at the moment compaction was prepared.
    public var tokensBefore: Int

    /// The standing checkpoint summary this run updates, when compacting a path
    /// that already crosses a compaction. Fed to the summarizer as prior context.
    public var previousSummary: String?

    /// Read-only files touched by the summarized history, for the digest.
    public var readFiles: [String]

    /// Modified files touched by the summarized history, for the digest.
    public var modifiedFiles: [String]

    public init(
        messagesToSummarize: [Message],
        retainedTail: [Message],
        firstKeptEntryId: String?,
        tokensBefore: Int,
        previousSummary: String?,
        readFiles: [String],
        modifiedFiles: [String]
    ) {
        self.messagesToSummarize = messagesToSummarize
        self.retainedTail = retainedTail
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.previousSummary = previousSummary
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
    }
}

/// One conversation message paired with the entry it came from, if any.
///
/// The id is `nil` for a message materialized from a prior checkpoint's retained
/// tail — those predate the current entries and carry no node of their own.
private struct SourcedMessage {
    var message: Message
    var entryID: String?
}

/// Project one path entry to the conversation message it contributes, or `nil`.
///
/// A compaction entry contributes nothing here: it is the checkpoint boundary,
/// handled by ``prepareCompaction(pathEntries:settings:)`` before projection, not
/// a message to re-summarize. A branch-summary entry has no message case in this
/// port's ``Message`` model, so its already-summarized text is carried as a user
/// message — enough for token accounting and for feeding the next summary, which
/// is all this projection is for.
private func compactionMessage(from entry: SessionTreeEntry) -> Message? {
    switch entry.payload {
    case .message(let message): return message
    case .branchSummary(let branch): return .user(UserMessage(content: [.text(branch.summary)]))
    case .compaction, .modelChange, .label, .sessionInfo, .leaf: return nil
    }
}

/// Choose the index in `messages` where retained history begins.
///
/// Only user messages are candidates: retaining from a user turn never orphans a
/// tool result and never splits a turn, so the retained tail is always replayable
/// as-is. Walking from the end, tokens accumulate until the recent budget is met,
/// then the earliest user boundary at or after that point becomes the cut.
///
/// Two deliberate fallbacks, both matching pi's `findCutPoint`: with no user
/// boundary at all, nothing can be cut safely and the function returns `0`
/// (summarize nothing); when the budget fills inside the most recent turn with no
/// boundary after it, the cut stays at the earliest boundary rather than
/// discarding that turn. This port does not implement pi's split-turn path, which
/// summarizes a single oversized turn's prefix separately — so a lone turn larger
/// than `keepRecentTokens` is kept whole and the context is not bounded below it.
public func findCutIndex(_ messages: [Message], keepRecentTokens: Int) -> Int {
    var boundaries: [Int] = []
    for (index, message) in messages.enumerated() {
        if case .user = message { boundaries.append(index) }
    }
    guard let firstBoundary = boundaries.first else { return 0 }

    var cut = firstBoundary
    var accumulated = 0
    var index = messages.count - 1
    while index >= 0 {
        accumulated += estimateTokens(messages[index])
        if accumulated >= keepRecentTokens {
            if let boundary = boundaries.first(where: { $0 >= index }) { cut = boundary }
            break
        }
        index -= 1
    }
    return cut
}

/// Decide what a compaction of `pathEntries` would summarize and keep, or `nil`
/// when compaction does not apply.
///
/// Returns `nil` for an empty path, for a path already tipped by a compaction, and
/// for a path where the recent budget already covers everything (nothing older to
/// summarize) — in each case there is no useful checkpoint to write.
///
/// A path that itself crosses a prior compaction (its retained tail materialized
/// on that entry) is handled: the prior summary becomes ``CompactionPreparation/previousSummary``,
/// its retained tail becomes the oldest messages of the region under
/// consideration, and the new summary is an update over both.
public func prepareCompaction(
    pathEntries: [SessionTreeEntry],
    settings: CompactionSettings
) -> CompactionPreparation? {
    guard let last = pathEntries.last else { return nil }
    if case .compaction = last.payload { return nil }

    var priorCompactionIndex: Int?
    for index in stride(from: pathEntries.count - 1, through: 0, by: -1) {
        if case .compaction = pathEntries[index].payload {
            priorCompactionIndex = index
            break
        }
    }

    var previousSummary: String?
    var priorRetained: [Message] = []
    var boundaryStart = 0
    if let priorCompactionIndex, case .compaction(let prior) = pathEntries[priorCompactionIndex].payload {
        previousSummary = prior.summary
        priorRetained = prior.retainedTail ?? []
        boundaryStart = priorCompactionIndex + 1
    }

    var stream: [SourcedMessage] = priorRetained.map { SourcedMessage(message: $0, entryID: nil) }
    for entry in pathEntries[boundaryStart...] {
        if let message = compactionMessage(from: entry) {
            stream.append(SourcedMessage(message: message, entryID: entry.id))
        }
    }

    let messages = stream.map(\.message)
    var tokensBefore = estimateContextTokens(messages).tokens
    if let previousSummary {
        // The standing summary is part of what a fresh turn would send, so it
        // counts toward the size compaction is trying to bound.
        tokensBefore += estimateTokens(.user(UserMessage(content: [.text(previousSummary)])))
    }

    let cut = findCutIndex(messages, keepRecentTokens: settings.keepRecentTokens)
    let messagesToSummarize = Array(messages[..<cut])
    guard !messagesToSummarize.isEmpty else { return nil }
    let retainedTail = Array(messages[cut...])

    let firstKeptEntryID = stream[cut...].first(where: { $0.entryID != nil })?.entryID
        ?? stream.last(where: { $0.entryID != nil })?.entryID

    var fileOps = FileOperations()
    for message in messagesToSummarize { extractFileOps(from: message, into: &fileOps) }
    let lists = computeFileLists(fileOps)

    return CompactionPreparation(
        messagesToSummarize: messagesToSummarize,
        retainedTail: retainedTail,
        firstKeptEntryId: firstKeptEntryID,
        tokensBefore: tokensBefore,
        previousSummary: previousSummary,
        readFiles: lists.readFiles,
        modifiedFiles: lists.modifiedFiles
    )
}

// MARK: - Entry construction

/// Build the compaction entry from a preparation and a ready summary — pure, so
/// the entry's shape can be checked without a model call.
///
/// The file-operations digest is appended to the summary text here, not stored on
/// the entry as separate details (pi's `details` field is extension/legacy only
/// and is not modeled), so a reader that only shows the summary still sees which
/// files the compacted history touched.
public func makeCompactionEntry(
    from preparation: CompactionPreparation,
    id: String,
    parentId: String?,
    timestamp: String,
    summary: String,
    usage: Usage? = nil
) -> SessionTreeEntry {
    let digest = formatFileOperations(readFiles: preparation.readFiles, modifiedFiles: preparation.modifiedFiles)
    let compaction = Compaction(
        summary: summary + digest,
        tokensBefore: preparation.tokensBefore,
        firstKeptEntryId: preparation.firstKeptEntryId,
        retainedTail: preparation.retainedTail,
        usage: usage
    )
    return SessionTreeEntry(id: id, parentId: parentId, timestamp: timestamp, payload: .compaction(compaction))
}

/// Run the injected summarizer over the prepared history and return the finished
/// compaction entry.
///
/// The only impure step: everything about *what* the entry contains was decided
/// by ``prepareCompaction(pathEntries:settings:)``; this adds the summary prose
/// and nothing else. When the preparation carries a ``CompactionPreparation/previousSummary``
/// (this path already crosses an earlier checkpoint), that prior summary is
/// prepended to the messages handed to the summarizer, so the narrative it holds
/// is carried forward instead of being lost the second time the path compacts.
/// A summarizer that throws propagates unchanged — the caller gets a real error
/// and writes no entry, which is the correct outcome for a context that could not
/// be summarized.
///
/// - Parameter usage: An accounting override. `nil` — the normal case — means the
///   entry carries whatever the summarizer reported on its ``SummarizerResult``,
///   which is the only party that actually measured the call. A non-`nil` value
///   wins, for a caller that wraps a summarizer and measures the request itself.
public func compact(
    _ preparation: CompactionPreparation,
    id: String,
    parentId: String?,
    timestamp: String,
    usage: Usage? = nil,
    summarize: Summarizer
) async throws -> SessionTreeEntry {
    var toSummarize = preparation.messagesToSummarize
    if let previousSummary = preparation.previousSummary {
        toSummarize.insert(.user(CompactionPrompts.priorSummaryPreamble(previousSummary)), at: 0)
    }
    let summarized = try await summarize(toSummarize)
    return makeCompactionEntry(
        from: preparation,
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        summary: summarized.text,
        usage: usage ?? summarized.usage
    )
}
