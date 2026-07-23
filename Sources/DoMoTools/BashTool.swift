// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/bash.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// Timeout validation bounds and messages, the non-zero-exit and timeout
// statuses, and the "(no output)" placeholder are ported from `tools/bash.ts`.
// The output windowing is delegated to DoMoExec's `Shell`, which keeps a bounded
// head+tail rather than pi's tail-only-plus-tempfile scheme — so the truncation
// footer and the description differ, deliberately.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// Runs a shell command through DoMoExec's ``Shell``.
public struct BashTool: Tool {

    public init() {}

    public let name = "bash"

    public let description = """
        Execute a bash command in the current working directory. Returns stdout and stderr. Output \
        is truncated to \(OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)) \
        (beginning and end kept, middle elided). Optionally provide a timeout in seconds.
        """

    public var parameters: JSONSchema {
        .object(
            .required("command", .string(description: "Bash command to execute")),
            .optional("timeout", .number(description: "Timeout in seconds (optional, no default timeout)"))
        )
    }

    /// pi's `MAX_TIMEOUT_MS`: Node's `setTimeout` ceiling, kept so a nonsense
    /// timeout is reported rather than silently turned into "never".
    private static let maximumTimeoutMilliseconds = 2_147_483_647.0

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let command = try args.requiredString("command")
            let timeoutSeconds = try args.optionalDouble("timeout")

            var timeout: Duration?
            if let timeoutSeconds {
                guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
                    return ToolResult.error("Invalid timeout: must be a finite number of seconds")
                }
                let milliseconds = timeoutSeconds * 1000
                guard milliseconds <= Self.maximumTimeoutMilliseconds else {
                    let maxSeconds = Self.maximumTimeoutMilliseconds / 1000
                    return ToolResult.error("Invalid timeout: maximum is \(Self.trim(maxSeconds)) seconds")
                }
                timeout = .milliseconds(Int(milliseconds.rounded()))
            }

            let result = try await context.shell.run(
                ShellRequest(
                    command,
                    workingDirectory: context.workingDirectory,
                    environment: context.environment,
                    timeout: timeout
                )
            )
            return Self.render(result, timeoutSeconds: timeoutSeconds)
        }
    }

    // MARK: Rendering

    private static func render(_ result: ShellResult, timeoutSeconds: Double?) -> ToolResult {
        // stdout then stderr. pi interleaves the two in arrival order; DoMoExec's
        // Shell keeps them separate on purpose (the ordering is a presentation
        // decision the byte layer cannot make without losing information), so the
        // tool concatenates them here.
        var body = result.stdout.text
        let errorText = result.stderr.text
        if !errorText.isEmpty {
            body = body.isEmpty ? errorText : "\(body)\n\(errorText)"
        }

        if result.isTruncated {
            body = appendStatus(
                body,
                "[Output truncated to \(OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)).]"
            )
        }

        var isError = false
        if result.timedOut {
            body = appendStatus(body, "Command timed out after \(trim(timeoutSeconds ?? 0)) seconds")
            isError = true
        } else if let code = result.exitCode, code != 0 {
            body = appendStatus(body, "Command exited with code \(code)")
            isError = true
        } else if body.isEmpty {
            body = "(no output)"
        }

        let details: JSONValue = .object([
            "exitCode": result.exitCode.map { .int(Int($0)) } ?? .null,
            "signal": result.signal.map { .int(Int($0)) } ?? .null,
            "timedOut": .bool(result.timedOut),
            "truncated": .bool(result.isTruncated),
            "durationMs": .int(milliseconds(result.duration)),
        ])
        return ToolResult(content: [.text(body)], isError: isError, details: details)
    }

    /// pi's `appendStatus`: a blank line between output and a trailing status.
    private static func appendStatus(_ text: String, _ status: String) -> String {
        text.isEmpty ? status : "\(text)\n\n\(status)"
    }

    /// Drops a redundant `.0` so a whole-second timeout reads `30`, not `30.0`.
    private static func trim(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
