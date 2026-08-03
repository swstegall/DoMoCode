// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

// MARK: - Todo state

/// A todo entry owned by one agent session.
public struct TodoItem: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
    }

    public enum Priority: String, Sendable, Hashable, Codable {
        case high
        case medium
        case low
    }

    public var content: String
    public var status: Status
    public var priority: Priority

    public init(
        content: String,
        status: Status = .pending,
        priority: Priority = .medium
    ) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// Session-scoped state for ``TodoWriteTool``. It deliberately lives outside
/// ``ToolContext``: todo state is conversation state, not a workspace file.
public actor TodoStore {
    private var items: [TodoItem] = []

    public init() {}

    public func replace(_ items: [TodoItem]) {
        self.items = items
    }

    public func snapshot() -> [TodoItem] {
        items
    }
}

/// Replaces the current session todo list and returns a compact checklist.
public struct TodoWriteTool: Tool {
    public let store: TodoStore

    public init(store: TodoStore = TodoStore()) {
        self.store = store
    }

    public let name = "todowrite"

    public let description = "Replace the session todo list. Keep it current while doing multi-step work."

    public var parameters: JSONSchema {
        .object(
            .required(
                "todos",
                .array(
                    of: .object(
                        .required("content", .string()),
                        .required(
                            "status",
                            .string(enumValues: ["pending", "in_progress", "completed", "cancelled"])
                        ),
                        .required("priority", .string(enumValues: ["high", "medium", "low"]))
                    )
                )
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
            guard let rawItems = try args.optionalArray("todos") else {
                throw args.fault("missing required array argument \"todos\"")
            }

            var parsed: [TodoItem] = []
            parsed.reserveCapacity(rawItems.count)
            for (index, rawItem) in rawItems.enumerated() {
                guard case .object(let object) = rawItem else {
                    throw args.fault("todos[\(index)] must be an object")
                }
                guard let content = object["content"]?.stringValue,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw args.fault("todos[\(index)].content must be a non-empty string")
                }
                guard let statusText = object["status"]?.stringValue,
                      let status = TodoItem.Status(rawValue: statusText)
                else {
                    throw args.fault(
                        "todos[\(index)].status must be pending, in_progress, completed, or cancelled"
                    )
                }
                guard let priorityText = object["priority"]?.stringValue,
                      let priority = TodoItem.Priority(rawValue: priorityText)
                else {
                    throw args.fault("todos[\(index)].priority must be high, medium, or low")
                }
                parsed.append(TodoItem(content: content, status: status, priority: priority))
            }

            await store.replace(parsed)
            let current = await store.snapshot()
            return ToolResult.text(Self.render(current), details: Self.details(current))
        }
    }

    private static func render(_ items: [TodoItem]) -> String {
        guard !items.isEmpty else { return "No todos." }
        return items.map { item in
            let marker: String
            switch item.status {
            case .pending: marker = "[ ]"
            case .inProgress: marker = "[>]"
            case .completed: marker = "[x]"
            case .cancelled: marker = "[-]"
            }
            let priority = item.priority == .medium ? "" : " (\(item.priority.rawValue))"
            return "\(marker) \(item.content)\(priority)"
        }.joined(separator: "\n")
    }

    private static func details(_ items: [TodoItem]) -> JSONValue {
        .object([
            "todos": .array(items.map { item in
                .object([
                    "content": .string(item.content),
                    "status": .string(item.status.rawValue),
                    "priority": .string(item.priority.rawValue),
                ])
            })
        ])
    }
}

// MARK: - Glob

/// The `glob` spelling used by newer agent prompts. It shares `find`'s
/// sandboxed, git-aware implementation so the two tools cannot drift on path
/// confinement or the pure-Swift fallback.
public struct GlobTool: Tool {
    public init() {}

    public let name = "glob"
    public let description = "Find files matching a glob pattern, relative to the workspace."

    public var parameters: JSONSchema {
        .object(
            .required("pattern", .string(description: "Glob pattern such as **/*.swift")),
            .optional("path", .string(description: "Directory to search (default: current directory)")),
            .optional("limit", .number(description: "Maximum number of results (default: 1000)"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            try await FindTool().execute(arguments, in: context)
        }
    }
}

// MARK: - Finish

/// Explicitly ends the current agent run after the model has completed its
/// requested work.
public struct FinishTool: Tool {
    public init() {}

    public let name = "finish"
    public let description = "Mark the task complete and stop the agent run."

    public var parameters: JSONSchema {
        .object(.optional("message", .string(description: "Short completion message")))
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let message = try args.optionalString("message") ?? "Task complete."
            return ToolResult.text(
                message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Task complete." : message,
                terminate: true
            )
        }
    }
}
