// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM

/// Replays tool results from a recorded message trajectory.
///
/// Calls are addressed by their persisted tool-call id, not by array position
/// or tool name. That matters when a model emits several calls to the same
/// tool, and it makes a replay fail closed when a branched run changes an id,
/// name, or argument object. Each recorded call can be consumed once.
public actor ReplayToolExecutor: ToolExecutor {
    /// One request/result pair from the recorded trajectory.
    public struct RecordedCall: Sendable, Hashable {
        public let call: ToolCallBlock
        public let result: ToolResultBlock

        public init(call: ToolCallBlock, result: ToolResultBlock) {
            self.call = call
            self.result = result
        }
    }

    private let calls: [String: RecordedCall]
    private let order: [String]
    private var consumed: Set<String> = []

    /// Builds an executor from assistant tool calls and their persisted results.
    ///
    /// The input is expected to be a lossless trajectory projection: normal
    /// `tool` messages are accepted, as are embedded `toolResult` blocks on
    /// user or assistant messages. A result must follow its call, every call
    /// must have exactly one result, and the recorded tool name must agree.
    public init(messages: [Message]) throws(DoMoError) {
        var requests: [String: ToolCallBlock] = [:]
        var results: [String: ToolResultBlock] = [:]
        var order: [String] = []

        for message in messages {
            switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    if case .toolCall(let call) = block {
                        guard !call.id.isEmpty else {
                            throw Self.configurationError("A recorded tool call has an empty id.")
                        }
                        guard requests[call.id] == nil else {
                            throw Self.configurationError(
                                "Recorded tool-call id \"\(call.id)\" appears more than once."
                            )
                        }
                        requests[call.id] = call
                        order.append(call.id)
                    }
                    if case .toolResult(let result) = block {
                        try Self.record(
                            result,
                            requests: requests,
                            results: &results
                        )
                    }
                }
            case .user(let user):
                for block in user.content {
                    if case .toolResult(let result) = block {
                        try Self.record(
                            result,
                            requests: requests,
                            results: &results
                        )
                    }
                }
            case .tool(let result):
                try Self.record(
                    result,
                    requests: requests,
                    results: &results
                )
            case .system:
                continue
            }
        }

        for id in order where results[id] == nil {
            guard let call = requests[id] else { continue }
            throw Self.configurationError(
                "Recorded tool call \"\(id)\" (\(call.name)) has no result."
            )
        }

        self.calls = Dictionary(
            uniqueKeysWithValues: order.compactMap { id in
                guard let call = requests[id], let result = results[id] else { return nil }
                return (id, RecordedCall(call: call, result: result))
            }
        )
        self.order = order
    }

    /// Returns the recorded calls in their original request order.
    public func recordedCalls() -> [RecordedCall] {
        order.compactMap { calls[$0] }
    }

    /// The number of calls available in this trajectory.
    public func recordedCallCount() -> Int { order.count }

    /// The ids of calls not consumed by a replay run.
    public func remainingCallIDs() -> [String] {
        order.filter { !consumed.contains($0) }
    }

    /// Whether every recorded call has been consumed.
    public func isExhausted() -> Bool { remainingCallIDs().isEmpty }

    /// Replays the entire recorded stream in request order.
    ///
    /// The command-line replay surface uses this as a deterministic validation
    /// pass before it creates a branch. Embedders that are driving an agent loop
    /// call ``execute(_:)`` as each assistant tool call arrives instead.
    public func replayAll() throws(DoMoError) -> [AgentToolResult] {
        var replayed: [AgentToolResult] = []
        replayed.reserveCapacity(order.count)
        for id in order {
            guard let recorded = calls[id] else {
                throw Self.configurationError("Replay record disappeared for tool-call id \"\(id)\".")
            }
            replayed.append(try consume(recorded, requested: recorded.call))
        }
        return replayed
    }

    /// Returns the recorded result for one call, consuming that id exactly once.
    public func execute(_ toolCall: ToolCallBlock) throws(DoMoError) -> AgentToolResult {
        guard let recorded = calls[toolCall.id] else {
            throw DoMoError(
                .toolExecution(tool: toolCall.name),
                "Replay has no recorded tool call with id \"\(toolCall.id)\"."
            )
        }
        return try consume(recorded, requested: toolCall)
    }

    /// Allows an embedding to replay the same trajectory from the beginning.
    public func reset() { consumed.removeAll(keepingCapacity: true) }

    private func consume(
        _ recorded: RecordedCall,
        requested: ToolCallBlock
    ) throws(DoMoError) -> AgentToolResult {
        let id = recorded.call.id
        guard !consumed.contains(id) else {
            throw DoMoError(
                .toolExecution(tool: requested.name),
                "Replay tool call \"\(id)\" was requested more than once."
            )
        }
        guard requested.name == recorded.call.name else {
            throw DoMoError(
                .toolExecution(tool: requested.name),
                "Replay tool call \"\(id)\" changed name from \"\(recorded.call.name)\" to \"\(requested.name)\"."
            )
        }
        guard requested.arguments == recorded.call.arguments else {
            throw DoMoError(
                .toolExecution(tool: requested.name),
                "Replay tool call \"\(id)\" changed its arguments."
            )
        }
        consumed.insert(id)
        return AgentToolResult(
            output: recorded.result.output,
            isError: recorded.result.isError,
            images: recorded.result.images
        )
    }

    private static func record(
        _ result: ToolResultBlock,
        requests: [String: ToolCallBlock],
        results: inout [String: ToolResultBlock]
    ) throws(DoMoError) {
        guard !result.toolCallID.isEmpty else {
            throw configurationError("A recorded tool result has an empty tool-call id.")
        }
        guard let request = requests[result.toolCallID] else {
            throw configurationError(
                "Recorded tool result \"\(result.toolCallID)\" has no preceding tool call."
            )
        }
        guard results[result.toolCallID] == nil else {
            throw configurationError(
                "Recorded tool-call id \"\(result.toolCallID)\" has more than one result."
            )
        }
        guard request.name == result.toolName else {
            throw configurationError(
                "Recorded tool result \"\(result.toolCallID)\" names \"\(result.toolName)\", expected \"\(request.name)\"."
            )
        }
        results[result.toolCallID] = result
    }

    private static func configurationError(_ message: String) -> DoMoError {
        DoMoError(.configuration, message)
    }
}
