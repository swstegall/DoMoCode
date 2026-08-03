// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoTools
import DoMoToolsUI
import Foundation

/// Renders a session into one self-contained HTML document.
///
/// Message text is escaped and kept deliberately plain: the HTML export is a
/// durable transcript, not a second Markdown engine. Tool results are different
/// because their existing `ToolRenderer`s already know how to present diffs,
/// paths, truncation, and errors. They are rendered with
/// ``ToolRenderTheme/html`` and placed unchanged into the document, so terminal
/// and HTML tool output cannot drift.
public enum HTMLTranscriptExporter {
    private static let exportWidth = 1_000_000

    public static func render(
        header: SessionHeader,
        entries: [SessionTreeEntry],
        options: TranscriptFormatOptions = .default,
        registry: ToolRendererRegistry = .builtin
    ) -> String {
        var sections: [String] = []
        sections.append(headerHTML(header))

        var callsByID: [String: ToolCallBlock] = [:]
        for entry in entries {
            switch entry.payload {
            case .message(let message):
                sections.append(contentsOf: messageHTML(
                    message,
                    options: options,
                    callsByID: &callsByID,
                    registry: registry
                ))
            case .modelChange(let provider, let modelId) where options.includeMetadata:
                sections.append(metadataSection(
                    title: "Model change",
                    body: "<code>\(htmlEscape(provider))/\(htmlEscape(modelId))</code>"
                ))
            case .compaction(let compaction) where options.includeMetadata:
                sections.append(metadataSection(
                    title: "Compaction",
                    body: textHTML(compaction.summary) + "<p class=\"meta\">Tokens before compaction: \(compaction.tokensBefore).</p>"
                ))
            case .branchSummary(let summary) where options.includeMetadata:
                sections.append(metadataSection(title: "Branch summary", body: textHTML(summary.summary)))
            case .label(let targetId, let label) where options.includeMetadata:
                let value = label.map { "<code>\(htmlEscape($0))</code>" } ?? "<em>cleared</em>"
                sections.append(metadataSection(
                    title: "Label",
                    body: "<p>\(value) → <code>\(htmlEscape(targetId))</code></p>"
                ))
            case .sessionInfo(let name) where options.includeMetadata:
                sections.append(metadataSection(title: "Session info", body: textHTML(name ?? "Name cleared")))
            case .sessionStart(let head) where options.includeMetadata:
                sections.append(metadataSection(title: "Session start", body: "<p>Git HEAD: <code>\(htmlEscape(head))</code></p>"))
            case .workspaceCheckpoint(let snapshot) where options.includeMetadata:
                sections.append(metadataSection(title: "Workspace checkpoint", body: "<p><code>\(htmlEscape(snapshot.id))</code></p>"))
            case .historyAction(let action) where options.includeMetadata:
                sections.append(metadataSection(
                    title: "History \(htmlEscape(action.operation.rawValue))",
                    body: "<p>Target: <code>\(htmlEscape(action.targetEntryID))</code></p>"
                ))
            case .subagent(let event) where options.includeMetadata:
                var body = textHTML(event.description) + "<p class=\"meta\">Status: <code>\(htmlEscape(event.status.rawValue))</code></p>"
                if let output = event.output, !output.isEmpty { body += "<pre>\(htmlEscape(output))</pre>" }
                sections.append(metadataSection(title: "Subagent", body: body))
            case .leaf where options.includeMetadata:
                sections.append(metadataSection(title: "Branch move", body: "<p>The active conversation branch moved.</p>"))
            default:
                continue
            }
        }

        return document(header: header, sections: sections)
    }

    private static func messageHTML(
        _ message: Message,
        options: TranscriptFormatOptions,
        callsByID: inout [String: ToolCallBlock],
        registry: ToolRendererRegistry
    ) -> [String] {
        switch message {
        case .system(let system) where options.includeMetadata:
            return [messageSection(role: "System", body: textHTML(system.content))]
        case .system:
            return []
        case .user(let user):
            var body = textHTML(user.text)
            body += imageHTML(user.content.compactMap(\.imageBlock))
            return [messageSection(role: "User", body: body)]
        case .assistant(let assistant):
            var sections: [String] = []
            var body = textHTML(assistant.text)
            if let error = assistant.errorMessage, assistant.text.isEmpty {
                body += "<p class=\"error\"><strong>Error:</strong> \(htmlEscape(error))</p>"
            }
            if !body.isEmpty { sections.append(messageSection(role: "Assistant", body: body)) }
            if options.includeReasoning {
                let reasoning = assistant.content.compactMap(\.reasoningBlock?.text).joined()
                if !reasoning.isEmpty {
                    sections.append("<details class=\"reasoning\"><summary>Reasoning</summary>\(textHTML(reasoning))</details>")
                }
            }
            for call in assistant.toolCalls {
                callsByID[call.id] = call
                if options.includeToolCalls {
                    let arguments = (try? call.arguments.encodedString(prettyPrinted: true)) ?? call.arguments.description
                    sections.append(
                        "<section class=\"tool-call\"><h3>Tool call: <code>\(htmlEscape(call.name))</code></h3><pre>\(htmlEscape(arguments))</pre></section>"
                    )
                }
            }
            return sections
        case .tool(let result):
            guard options.includeToolResults else { return [] }
            let call = callsByID[result.toolCallID]
            let arguments = call?.arguments ?? .object([:])
            let content: [ToolContent] = [.text(result.output)] + result.images.map {
                .image(mediaType: $0.mediaType, data: $0.data)
            }
            let toolResult = ToolResult(content: content, isError: result.isError)
            let lines = registry.render(
                toolName: result.toolName,
                arguments: arguments,
                result: toolResult,
                width: exportWidth,
                theme: .html,
                expanded: true
            )
            let rendered = lines.joined(separator: "\n")
            return [
                "<section class=\"tool-result\"><h3>Tool result: <code>\(htmlEscape(result.toolName))</code>\(result.isError ? " <span class=\"domo-error\">error</span>" : "")</h3><pre class=\"tool-render\">\(rendered)</pre>\(imageHTML(result.images))</section>"
            ]
        }
    }

    private static func document(header: SessionHeader, sections: [String]) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>DoMoCode session \(htmlEscape(header.id))</title>
          <style>
            :root { color-scheme: light dark; --bg: #111827; --fg: #e5e7eb; --muted: #9ca3af; --panel: #1f2937; --accent: #67e8f9; --error: #fca5a5; --add: #86efac; --remove: #fca5a5; }
            body { max-width: 1000px; margin: 0 auto; padding: 2rem; background: var(--bg); color: var(--fg); font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
            header, section, details { margin: 0 0 1rem; padding: 1rem; border-radius: .5rem; background: var(--panel); }
            h1, h2, h3 { margin: 0 0 .75rem; font-size: 1rem; } h1 { font-size: 1.25rem; }
            p { white-space: pre-wrap; overflow-wrap: anywhere; } pre { overflow-x: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
            code { color: var(--accent); } .meta, .domo-muted, .domo-diff-context { color: var(--muted); }
            .domo-title { font-weight: 700; } .domo-accent { color: var(--accent); } .domo-error { color: var(--error); }
            .domo-warning { color: #fde68a; } .domo-diff-added, .domo-inverse { color: var(--add); }
            .domo-diff-removed { color: var(--remove); } .reasoning { opacity: .8; }
            .tool-render { margin: 0; } .error { color: var(--error); }
          </style>
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func headerHTML(_ header: SessionHeader) -> String {
        "<header><h1>DoMoCode session</h1><p class=\"meta\">Session: <code>\(htmlEscape(header.id))</code><br>Started: <code>\(htmlEscape(header.timestamp))</code><br>Working directory: <code>\(htmlEscape(header.cwd))</code></p></header>"
    }

    private static func messageSection(role: String, body: String) -> String {
        "<section class=\"message \(role.lowercased())\"><h2>\(role)</h2>\(body)</section>"
    }

    private static func metadataSection(title: String, body: String) -> String {
        "<section class=\"metadata\"><h2>\(title)</h2>\(body)</section>"
    }

    private static func textHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return "<p>\(htmlEscape(text))</p>"
    }

    private static func imageHTML(_ images: [ImageBlock]) -> String {
        guard !images.isEmpty else { return "" }
        return images.enumerated().map { index, image in
            "<p class=\"meta\">[Image \(index + 1): <code>\(htmlEscape(image.mediaType))</code>, \(image.data.count) bytes]</p>"
        }.joined()
    }
}
