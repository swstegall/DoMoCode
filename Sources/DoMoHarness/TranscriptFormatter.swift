// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM
import Foundation

/// Which parts of a persisted transcript should cross an export or copy seam.
///
/// The same value is used by the CLI exporter and both interactive clients. That
/// is intentional: a copied transcript should not be a subtly different record
/// from the one written by `domo export`, and a caller can make the trade-off
/// explicit without teaching each surface its own formatter vocabulary.
public struct TranscriptFormatOptions: Sendable, Hashable {
    public var includeReasoning: Bool
    public var includeToolCalls: Bool
    public var includeToolResults: Bool
    public var includeMetadata: Bool

    public init(
        includeReasoning: Bool = true,
        includeToolCalls: Bool = true,
        includeToolResults: Bool = true,
        includeMetadata: Bool = false
    ) {
        self.includeReasoning = includeReasoning
        self.includeToolCalls = includeToolCalls
        self.includeToolResults = includeToolResults
        self.includeMetadata = includeMetadata
    }

    /// The complete conversational record, without session bookkeeping.
    public static let `default` = TranscriptFormatOptions()

    /// The compact form used by `/copy`: conversation content, tool activity,
    /// and reasoning, but not append-only bookkeeping such as labels or Git
    /// checkpoints.
    public static let copy = TranscriptFormatOptions()
}

/// Converts persisted messages and session entries into stable, clipboard-safe
/// Markdown.
///
/// This deliberately lives beside the session model rather than in a UI target.
/// Session files are the lossless source for export, while a remote client may
/// only have the projected message history; both can ask this formatter for the
/// same Markdown vocabulary. It does not render Markdown to ANSI or HTML — those
/// are presentation concerns layered on top of this lossless text form.
public enum TranscriptFormatter {
    /// Formats the supplied timeline in its already-selected branch order.
    ///
    /// Callers that have a complete tree should pass `SessionTree.branch()` (or
    /// another explicitly chosen branch), not every line in the JSONL file. The
    /// formatter preserves the caller's order so replay and branch export never
    /// silently mix abandoned siblings into the active conversation.
    public static func markdown(
        header: SessionHeader? = nil,
        entries: [SessionTreeEntry],
        options: TranscriptFormatOptions = .default
    ) -> String {
        var sections: [String] = []
        if let header {
            sections.append(headerSection(header))
        }

        for entry in entries {
            switch entry.payload {
            case .message(let message):
                sections.append(contentsOf: messageSections(message, options: options))
            case .modelChange(let provider, let modelId) where options.includeMetadata:
                sections.append("## Model change\n\n`\(markdownCode(provider))/\(markdownCode(modelId))`")
            case .agentChange(let name) where options.includeMetadata:
                sections.append("## Agent change\n\n`\(name.map(markdownCode) ?? "base")`")
            case .compaction(let compaction) where options.includeMetadata:
                var body = "## Compaction\n\n\(compaction.summary)"
                body += "\n\n_Tokens before compaction: \(compaction.tokensBefore)._"
                sections.append(body)
            case .branchSummary(let summary) where options.includeMetadata:
                sections.append("## Branch summary\n\n\(summary.summary)")
            case .label(let targetId, let label) where options.includeMetadata:
                let value = label.map { "`\(markdownCode($0))`" } ?? "_cleared_"
                sections.append("## Label\n\n\(value) → `\(markdownCode(targetId))`")
            case .sessionInfo(let name) where options.includeMetadata:
                sections.append("## Session info\n\n\(name.map { "Name: \(escapeMetadata($0))" } ?? "Name cleared")")
            case .sessionStart(let head) where options.includeMetadata:
                sections.append("## Session start\n\nGit HEAD: `\(markdownCode(head))`")
            case .workspaceCheckpoint(let snapshot) where options.includeMetadata:
                sections.append("## Workspace checkpoint\n\n`\(markdownCode(snapshot.id))`")
            case .historyAction(let action) where options.includeMetadata:
                sections.append("## History \(action.operation.rawValue)\n\nTarget: `\(markdownCode(action.targetEntryID))`")
            case .subagent(let event) where options.includeMetadata:
                sections.append(subagentSection(event))
            case .recovery(let envelope) where options.includeMetadata:
                sections.append(recoverySection(envelope))
            case .leaf where options.includeMetadata:
                sections.append("## Branch move\n\nThe active conversation branch moved.")
            default:
                continue
            }
        }

        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Formats a projected message history, as returned by the server to a
    /// remote client. This uses the same message formatter as file export.
    public static func markdown(
        messages: [Message],
        options: TranscriptFormatOptions = .copy
    ) -> String {
        let sections = messages.flatMap { messageSections($0, options: options) }
        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: Message projection

    private static func messageSections(
        _ message: Message,
        options: TranscriptFormatOptions
    ) -> [String] {
        switch message {
        case .system(let system):
            guard options.includeMetadata else { return [] }
            return ["## System\n\n\(system.content)"]
        case .user(let user):
            var body = "## User\n\n\(user.text)"
            body += imageMarkers(user.content.compactMap(\.imageBlock))
            return [body]
        case .assistant(let assistant):
            var sections: [String] = []
            var body = "## Assistant"
            if !assistant.text.isEmpty { body += "\n\n\(assistant.text)" }
            if let error = assistant.errorMessage, assistant.text.isEmpty {
                body += "\n\n**Error:** \(error)"
            }
            if !body.hasSuffix("## Assistant") || !assistant.content.isEmpty {
                sections.append(body)
            }
            if options.includeReasoning {
                let reasoning = assistant.content.compactMap(\.reasoningBlock?.text).joined()
                if !reasoning.isEmpty {
                    sections.append("### Reasoning\n\n\(reasoning)")
                }
            }
            if options.includeToolCalls {
                for call in assistant.toolCalls {
                    sections.append(toolCallSection(call))
                }
            }
            if options.includeMetadata, assistant.stopReason != .stop {
                sections.append("_Assistant stop reason: `\(markdownCode(assistant.stopReason.rawValue))`._")
            }
            return sections
        case .tool(let result):
            guard options.includeToolResults else { return [] }
            return [toolResultSection(result)]
        }
    }

    private static func headerSection(_ header: SessionHeader) -> String {
        var lines = ["# DoMoCode session", "", "- Session: `\(markdownCode(header.id))`", "- Started: `\(markdownCode(header.timestamp))`", "- Working directory: `\(markdownCode(header.cwd))`"]
        if let parent = header.parentSession {
            lines.append("- Parent session: `\(markdownCode(parent))`")
        }
        return lines.joined(separator: "\n")
    }

    private static func toolCallSection(_ call: ToolCallBlock) -> String {
        "### Tool call: `\(markdownCode(call.name))` (\(markdownCode(call.id)))\n\n" + fenced(
            (try? call.arguments.encodedString(prettyPrinted: true)) ?? call.arguments.description,
            language: "json"
        )
    }

    private static func toolResultSection(_ result: ToolResultBlock) -> String {
        let state = result.isError ? " — error" : ""
        var body = "### Tool result: `\(markdownCode(result.toolName))`\(state)\n\n"
        body += fenced(result.output, language: "text")
        body += imageMarkers(result.images)
        return body
    }

    private static func subagentSection(_ event: SubagentTaskEvent) -> String {
        var body = "## Subagent\n\n- Task: \(escapeMetadata(event.description))\n- Status: `\(markdownCode(event.status.rawValue))`"
        if let output = event.output, !output.isEmpty {
            body += "\n\n" + fenced(output, language: "text")
        }
        return body
    }

    private static func recoverySection(_ envelope: RecoveryEnvelope) -> String {
        var body = "## Recovery\n\n- Kind: `\(markdownCode(envelope.originalKind))`"
        if let status = envelope.status {
            body += "\n- Status: `\(status)`"
        }
        body += "\n- Error: \(escapeMetadata(envelope.error))"
        if let diagnosis = envelope.diagnosis, !diagnosis.isEmpty {
            body += "\n- Diagnosis: \(escapeMetadata(diagnosis))"
        }
        return body
    }

    private static func imageMarkers(_ images: [ImageBlock]) -> String {
        guard !images.isEmpty else { return "" }
        return "\n\n" + images.enumerated().map { index, image in
            "_[Image \(index + 1): `\(markdownCode(image.mediaType))`, \(image.data.count) bytes]_"
        }.joined(separator: "\n")
    }

    /// Select a fence longer than every backtick run in the body. Tool output is
    /// model- and process-controlled, so assuming three backticks is not safe:
    /// one command can print a Markdown fence and terminate the export early.
    private static func fenced(_ text: String, language: String) -> String {
        let longest = longestBacktickRun(in: text)
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func markdownCode(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "\\`")
    }

    private static func escapeMetadata(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
