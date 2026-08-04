// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

// MARK: - Web fetch

/// Fetches a web page through the context's permission-gated network seam.
public struct WebFetchTool: Tool {
    private static let defaultMaxBytes = 100_000
    private static let maximumMaxBytes = 5_000_000

    public init() {}

    public let name = "webfetch"
    public let description = """
        Fetch a URL and return its text. Only http and https URLs are accepted. \
        The response is bounded so a large page cannot consume the whole context.
        """

    public var parameters: JSONSchema {
        .object(
            .required("url", .string(description: "The http or https URL to fetch")),
            .optional(
                "maxBytes",
                .number(description: "Maximum response bytes to decode (default: 100000)")
            )
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let rawURL = try args.requiredString("url")
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else {
                return ToolResult.error("Invalid URL: webfetch accepts only http and https URLs.")
            }

            let requestedLimit = try args.optionalInt("maxBytes") ?? Self.defaultMaxBytes
            let maxBytes = min(max(1, requestedLimit), Self.maximumMaxBytes)
            let response = try await context.webFetch(url)
            guard (200..<300).contains(response.statusCode) else {
                return ToolResult.error(
                    "webfetch received HTTP \(response.statusCode) from \(rawURL)",
                    details: .object([
                        "statusCode": .int(response.statusCode),
                        "url": .string(rawURL),
                    ])
                )
            }

            let byteLimited = response.data.count > maxBytes
            let body = String(decoding: response.data.prefix(maxBytes), as: UTF8.self)
            let truncation = OutputTruncation.head(body)
            var output = truncation.content
            let truncated = byteLimited || truncation.truncated
            if truncated {
                output += "\n\n[Response truncated; request a smaller section or a larger maxBytes.]"
            }
            return ToolResult.text(
                output.isEmpty ? "(empty response)" : output,
                details: .object([
                    "statusCode": .int(response.statusCode),
                    "url": .string(rawURL),
                    "contentType": response.contentType.map(JSONValue.string) ?? .null,
                    "truncated": .bool(truncated),
                    "bytes": .int(min(response.data.count, maxBytes)),
                ])
            )
        }
    }
}

// MARK: - Web search

/// Searches through an injected provider. The native surface intentionally has
/// no built-in endpoint: deployments can supply a hosted API or an MCP-backed
/// adapter without putting provider credentials into the tool layer.
public struct WebSearchTool: Tool {
    private static let defaultLimit = 5
    private static let maximumLimit = 10

    public init() {}

    public let name = "websearch"
    public let description = "Search the web through the configured search provider and return ranked links with snippets."

    public var parameters: JSONSchema {
        .object(
            .required("query", .string(description: "The web search query")),
            .optional("limit", .number(description: "Maximum results to return (default: 5, maximum: 10)"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let query = try args.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return ToolResult.error("websearch: query must not be empty.") }
            guard let provider = context.webSearch else {
                return ToolResult.error(
                    "websearch is unavailable: configure a search provider or expose search through MCP."
                )
            }
            let requestedLimit = try args.optionalInt("limit") ?? Self.defaultLimit
            let limit = min(max(1, requestedLimit), Self.maximumLimit)
            let hits = Array(try await provider(query, limit).prefix(limit))
            guard !hits.isEmpty else {
                return ToolResult.text(
                    "No web results for \(query).",
                    details: .object([
                        "query": .string(query),
                        "results": .array([]),
                    ])
                )
            }

            let text = hits.enumerated().map { index, hit in
                var line = "\(index + 1). \(hit.title) — \(hit.url)"
                if let snippet = hit.snippet, !snippet.isEmpty {
                    line += "\n   \(snippet)"
                }
                return line
            }.joined(separator: "\n")
            let details = JSONValue.object([
                "query": .string(query),
                "results": .array(hits.map { hit in
                    .object([
                        "title": .string(hit.title),
                        "url": .string(hit.url),
                        "snippet": hit.snippet.map(JSONValue.string) ?? .null,
                    ])
                }),
            ])
            return ToolResult.text(text, details: details)
        }
    }
}

// MARK: - Questions

/// Presents structured multiple-choice questions to an interactive surface.
/// Headless contexts reject the call rather than waiting forever for UI input.
public struct QuestionTool: Tool {
    public init() {}

    public let name = "question"
    public let description = """
        Ask the user one or more structured multiple-choice questions. This tool \
        requires an interactive surface and cannot run in headless print mode.
        """

    public var parameters: JSONSchema {
        let option = JSONSchema.object(
            .required("label", .string(description: "Option text")),
            .optional("description", .string(description: "Optional explanation"))
        )
        let question = JSONSchema.object(
            .optional("header", .string(description: "Short label")),
            .required("question", .string(description: "Question to ask")),
            .required("options", .array(of: option, minItems: 1)),
            .optional("multiple", .boolean(description: "Allow more than one option"))
        )
        return .object(.required("questions", .array(of: question, minItems: 1)))
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            guard let rawQuestions = try args.optionalArray("questions") else {
                throw args.fault("missing required array argument \"questions\"")
            }
            let questions = try Self.parse(rawQuestions, tool: name)
            guard let handler = context.questionHandler else {
                return ToolResult.error(
                    "The question tool is unavailable in headless mode. Continue without asking the user."
                )
            }
            guard let answers = await handler(questions) else {
                return ToolResult.error("The user cancelled the question prompt.")
            }

            var lines: [String] = []
            var encodedAnswers: [JSONValue] = []
            for (index, question) in questions.enumerated() {
                let selected = index < answers.count ? answers[index].selectedLabels : []
                let answerText = selected.isEmpty ? "(no selection)" : selected.joined(separator: ", ")
                lines.append("\(question.question): \(answerText)")
                encodedAnswers.append(
                    .object([
                        "question": .string(question.question),
                        "selected": .array(selected.map(JSONValue.string)),
                    ])
                )
            }
            return ToolResult.text(
                lines.joined(separator: "\n"),
                details: .object(["answers": .array(encodedAnswers)])
            )
        }
    }

    private static func parse(
        _ rawQuestions: [JSONValue],
        tool: String
    ) throws(DoMoError) -> [QuestionPrompt] {
        var questions: [QuestionPrompt] = []
        questions.reserveCapacity(rawQuestions.count)
        for (index, rawQuestion) in rawQuestions.enumerated() {
            guard case .object(let object) = rawQuestion else {
                throw DoMoError(.toolExecution(tool: tool), "question: questions[\(index)] must be an object")
            }
            guard let question = object["question"]?.stringValue,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw DoMoError(.toolExecution(tool: tool), "question: questions[\(index)].question is required")
            }
            guard let rawOptions = object["options"]?.arrayValue, !rawOptions.isEmpty else {
                throw DoMoError(.toolExecution(tool: tool), "question: questions[\(index)].options must not be empty")
            }

            var options: [QuestionOption] = []
            options.reserveCapacity(rawOptions.count)
            for (optionIndex, rawOption) in rawOptions.enumerated() {
                if let label = rawOption.stringValue, !label.isEmpty {
                    options.append(QuestionOption(label: label))
                    continue
                }
                guard case .object(let option) = rawOption,
                      let label = option["label"]?.stringValue,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw DoMoError(
                        .toolExecution(tool: tool),
                        "question: questions[\(index)].options[\(optionIndex)] must have a label"
                    )
                }
                options.append(
                    QuestionOption(
                        label: label,
                        description: option["description"]?.stringValue
                    )
                )
            }

            questions.append(
                QuestionPrompt(
                    header: object["header"]?.stringValue,
                    question: question,
                    options: options,
                    allowsMultiple: object["multiple"]?.boolValue ?? false
                )
            )
        }
        return questions
    }
}
