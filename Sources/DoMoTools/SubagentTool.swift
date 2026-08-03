// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

/// Delegates an exploration or implementation question to a child session.
///
/// The runtime owns child-harness creation; this tool only validates the model
/// arguments and crosses the narrow ``SubagentCoordinator`` seam. That keeps
/// the built-in tool usable by the server without coupling the tools target to
/// session persistence or HTTP concerns.
public struct TaskTool: Tool {
    public init() {}

    public let name = "task"

    public let description = "Delegate a focused task to a child agent session. Use task_id to resume an existing child; set background to true to continue while this session works."

    public let parameters: JSONSchema = .object(
        .optional(
            "prompt",
            .string(description: "The focused question or task for the child agent. Required for a new task.")
        ),
        .optional(
            "task_id",
            .string(description: "An existing task id to resume instead of creating a new child session.")
        ),
        .optional(
            "agent",
            .string(description: "Optional child agent profile, such as explore.")
        ),
        .optional(
            "background",
            .boolean(description: "Run in the background and deliver the result through the parent session queue.", default: false)
        )
    )

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let taskID = try args.optionalString("task_id") ?? UUIDv7.generate().description
            let prompt = try args.optionalString("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let agent = try args.optionalString("agent")
            let background = try args.optionalBool("background") ?? false

            guard !prompt.isEmpty || args.value("task_id") != nil else {
                return .error("task: prompt is required when starting a new task")
            }
            guard let coordinator = context.subagentCoordinator else {
                return .error("task: subagent runtime is unavailable")
            }
            guard let parentSessionID = context.sessionID else {
                return .error("task: this tool is not attached to a session")
            }

            let request = SubagentTaskRequest(
                taskID: taskID,
                parentSessionID: parentSessionID,
                prompt: prompt,
                agent: agent,
                background: background
            )
            let result = await coordinator.run(request)
            let details: JSONValue = [
                "task_id": .string(result.taskID),
                "child_session_id": result.childSessionID.map(JSONValue.string) ?? .null,
                "status": .string(result.status.rawValue),
                "output": result.output.map(JSONValue.string) ?? .null,
                "error": result.error.map(JSONValue.string) ?? .null,
            ]

            switch result.status {
            case .accepted:
                let child = result.childSessionID.map { " in child session \($0)" } ?? ""
                return .text(
                    "Subagent task \(result.taskID) started in the background\(child). Its result will arrive through the parent session queue.",
                    details: details
                )
            case .completed:
                return .text(result.output ?? "Subagent completed without output.", details: details)
            case .started:
                return .text("Subagent task \(result.taskID) started.", details: details)
            case .failed, .cancelled:
                return .error(
                    result.error ?? "Subagent task \(result.taskID) did not complete.",
                    details: details
                )
            }
        }
    }
}
