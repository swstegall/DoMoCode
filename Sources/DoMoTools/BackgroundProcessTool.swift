// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec

/// Starts and controls one session's long-running shell children. Every action
/// is permission-gated like the other model-driven tools; the process manager
/// additionally bounds the output returned by `poll` and tears children down
/// with the owning context.
public struct BackgroundProcessTool: Tool {
    public init() {}

    public let name = "background_process"
    public let description = """
        Start, poll, write to, or stop a long-running bash process. Processes are
        scoped to this session and their poll output is bounded.
        """

    public var parameters: JSONSchema {
        .object(
            .required(
                "action",
                .string(
                    description: "One of start, poll, write, or kill",
                    enumValues: ["start", "poll", "write", "kill"]
                )
            ),
            .optional("command", .string(description: "Bash command for start")),
            .optional("id", .string(description: "Process ID for poll, write, or kill")),
            .optional("input", .string(description: "UTF-8 text to write to stdin")),
            .optional("clearOutput", .boolean(description: "Clear returned output (default true)"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let action = try args.requiredString("action").lowercased()
            switch action {
            case "start":
                let command = try args.requiredString("command")
                let snapshot = try await context.backgroundProcesses.start(
                    command,
                    workingDirectory: context.workingDirectory,
                    environment: context.environment
                )
                return Self.result(snapshot, prefix: "Started background process")
            case "poll":
                let id = try args.requiredString("id")
                guard let snapshot = await context.backgroundProcesses.poll(
                    id: id,
                    clearOutput: try args.optionalBool("clearOutput") ?? true
                ) else {
                    return ToolResult.error("Unknown background process: \(id)")
                }
                return Self.result(snapshot, prefix: "Background process")
            case "write":
                let id = try args.requiredString("id")
                let input = try args.requiredString("input")
                guard await context.backgroundProcesses.write(id: id, input: input) else {
                    return ToolResult.error("Background process is not running: \(id)")
                }
                return ToolResult.text("Wrote \(input.utf8.count) bytes to background process \(id).")
            case "kill", "stop":
                let id = try args.requiredString("id")
                guard await context.backgroundProcesses.stop(id: id) else {
                    return ToolResult.error("Background process is not running: \(id)")
                }
                let snapshot = await context.backgroundProcesses.poll(id: id, clearOutput: false)
                return Self.result(snapshot, prefix: "Stopped background process")
            default:
                return ToolResult.error("Unknown background_process action: \(action)")
            }
        }
    }

    private static func result(
        _ snapshot: BackgroundProcessSnapshot?,
        prefix: String
    ) -> ToolResult {
        guard let snapshot else { return ToolResult.error("Background process no longer exists.") }
        var output = snapshot.output
        if snapshot.truncated {
            output = "[Earlier output truncated.]\n" + output
        }
        let state = snapshot.state.rawValue
        let status = snapshot.exitCode.map { "exit code \($0)" } ?? state
        let body = output.isEmpty ? "(no new output)" : output
        return ToolResult.text(
            "\(prefix) \(snapshot.id) — \(status)\n\(body)",
            details: .object([
                "id": .string(snapshot.id),
                "state": .string(state),
                "exitCode": snapshot.exitCode.map { .int(Int($0)) } ?? .null,
                "truncated": .bool(snapshot.truncated),
            ])
        )
    }
}
