// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import SystemPackage

/// The source category that made a historical excerpt searchable.
public enum SessionRecallCategory: String, Sendable, Hashable, Codable {
    case user
    case assistant
    case file
    case toolError
}

/// One ranked, deliberately small excerpt from an earlier session.
public struct SessionRecallHit: Sendable, Hashable {
    public let sessionID: String
    public let entryID: String?
    public let timestamp: String
    public let category: SessionRecallCategory
    public let score: Double
    public let snippet: String

    public init(
        sessionID: String,
        entryID: String?,
        timestamp: String,
        category: SessionRecallCategory,
        score: Double,
        snippet: String
    ) {
        self.sessionID = sessionID
        self.entryID = entryID
        self.timestamp = timestamp
        self.category = category
        self.score = score
        self.snippet = snippet
    }
}

/// The read-only seam a model-facing recall tool consumes.
public protocol SessionRecallProvider: Sendable {
    func search(query: String, limit: Int) throws -> [SessionRecallHit]
}

/// A live, on-demand index over this workspace's own JSONL sessions.
///
/// It intentionally has no secondary database: each search re-reads the small
/// session headers and entries that already exist, so a newly completed session
/// is searchable immediately and there is no index to invalidate or protect.
public struct SessionRecallIndex: SessionRecallProvider, Sendable {
    public let cwd: String
    public let sessionDirectory: FilePath

    public init(cwd: String, sessionDirectory: FilePath) {
        self.cwd = cwd
        self.sessionDirectory = sessionDirectory
    }

    public func search(query: String, limit: Int = 5) throws -> [SessionRecallHit] {
        let queryTokens = Self.tokens(query)
        guard !queryTokens.isEmpty else {
            throw SessionRecallError.emptyQuery
        }

        let boundedLimit = min(max(limit, 1), 10)
        let listings = try JSONLSessionStore.list(cwd: cwd, sessionDirectory: sessionDirectory)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(listings.count * 4)

        for (sessionOrdinal, listing) in listings.enumerated() {
            // A crash-truncated or concurrently-written session should not make
            // every other historical session unavailable. JSONL reads are already
            // tolerant line-by-line; skipping only a file-level read failure keeps
            // that same fail-open behavior at the index boundary.
            guard let entries = try? JSONLSessionStore(path: listing.path).readEntries() else { continue }
            for (entryOrdinal, entry) in entries.enumerated() {
                Self.appendCandidates(
                    from: entry,
                    sessionID: listing.header.id,
                    sessionTimestamp: listing.header.timestamp,
                    sessionOrdinal: sessionOrdinal,
                    entryOrdinal: entryOrdinal,
                    into: &candidates
                )
            }
        }

        return candidates
            .compactMap { candidate in
                guard let lexicalScore = Self.score(candidate.text, query: query, tokens: queryTokens) else {
                    return nil
                }
                let categoryWeight: Double = switch candidate.category {
                case .user: 4.0
                case .assistant: 3.0
                case .file: 3.5
                case .toolError: 2.5
                }
                return SessionRecallHit(
                    sessionID: candidate.sessionID,
                    entryID: candidate.entryID,
                    timestamp: candidate.timestamp,
                    category: candidate.category,
                    score: lexicalScore + categoryWeight + candidate.recency,
                    // Redaction is defense in depth for model-visible history;
                    // the session itself remains an immutable record of what ran.
                    snippet: Self.elideMiddle(Redaction.diagnostic(candidate.text), limit: 900)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.sessionID < rhs.sessionID
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    private struct Candidate: Sendable {
        let sessionID: String
        let entryID: String?
        let timestamp: String
        let category: SessionRecallCategory
        let text: String
        let recency: Double
    }

    private static func appendCandidates(
        from entry: SessionTreeEntry,
        sessionID: String,
        sessionTimestamp: String,
        sessionOrdinal: Int,
        entryOrdinal: Int,
        into candidates: inout [Candidate]
    ) {
        func append(_ category: SessionRecallCategory, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            candidates.append(
                Candidate(
                    sessionID: sessionID,
                    entryID: entry.id,
                    timestamp: entry.timestamp.isEmpty ? sessionTimestamp : entry.timestamp,
                    category: category,
                    text: trimmed,
                    recency: Double(sessionOrdinal) * 0.0001 + Double(entryOrdinal) * 0.000001
                )
            )
        }

        switch entry.payload {
        case .message(let message):
            switch message {
            case .user(let user):
                append(.user, user.content.compactMap(\.textBlock?.text).joined())
            case .assistant(let assistant):
                // `AssistantMessage.text` intentionally sees only `.text`; this
                // excludes reasoning and tool-call JSON from recall.
                append(.assistant, assistant.text)
                for call in assistant.toolCalls {
                    for reference in fileReferences(in: call.arguments) {
                        append(.file, reference)
                    }
                }
            case .tool(let result):
                // Successful tool output is intentionally not historical memory.
                if result.isError { append(.toolError, result.output) }
            case .system:
                break
            }
        case .compaction(let compaction):
            append(.assistant, compaction.summary)
            for path in compaction.readFiles ?? [] { append(.file, path) }
            for path in compaction.modifiedFiles ?? [] { append(.file, path) }
        case .branchSummary(let summary):
            append(.assistant, summary.summary)
        case .workspaceCheckpoint(let snapshot):
            for path in snapshot.files { append(.file, path) }
        case .modelChange, .label, .sessionInfo, .sessionStart, .historyAction, .leaf, .subagent:
            break
        }
    }

    private static func fileReferences(in value: JSONValue) -> [String] {
        let pathKeys: Set<String> = [
            "path", "paths", "file", "files", "filename", "filenames",
            "filepath", "filepaths", "file_path", "file_paths",
        ]

        func collect(_ value: JSONValue, key: String? = nil) -> [String] {
            switch value {
            case .string(let string):
                guard let key, pathKeys.contains(key.lowercased()) else { return [] }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            case .array(let values):
                return values.flatMap { collect($0, key: key) }
            case .object(let object):
                return object.flatMap { collect($0.value, key: $0.key) }
            case .null, .bool, .int, .double:
                return []
            }
        }

        return collect(value)
    }

    private static func score(_ text: String, query: String, tokens: [String]) -> Double? {
        let haystack = tokensOf(text)
        let matches = tokens.reduce(into: 0) { count, token in
            if haystack.contains(token) { count += 1 }
        }
        guard matches > 0 else { return nil }

        var score = Double(matches) / Double(tokens.count) * 10
        if text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) {
            score += 4
        }
        return score
    }

    private static func tokens(_ text: String) -> [String] {
        tokensOf(text)
    }

    private static func tokensOf(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Keeps both ends of history. A tail-only limit is particularly bad for
    /// decisions because the conclusion often follows a long explanation.
    public static func elideMiddle(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let marker = " … [middle omitted] … "
        guard limit > marker.count + 2 else { return String(text.prefix(limit)) }
        let available = limit - marker.count
        let prefixCount = (available * 3) / 5
        let suffixCount = available - prefixCount
        return String(text.prefix(prefixCount)) + marker + String(text.suffix(suffixCount))
    }
}

public enum SessionRecallError: Error, Sendable, Equatable {
    case emptyQuery
}
