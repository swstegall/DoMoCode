// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM

// MARK: - Protocol version

/// The wire-protocol version carried on the SSE stream's opening frame.
///
/// The server and any client hand-maintain compatibility against this number —
/// there is no generated SDK (that breadth is the sibling-scale surface this
/// project bounds out). A client that does not recognize the version it is handed
/// should refuse rather than guess at a shape that may have moved.
public let serverProtocolVersion = 1

// MARK: - ServerEvent

/// One frame on the `GET /session/{id}/events` stream.
///
/// This is a *projection* of ``DoMoAgent/AgentEvent``, not the event enum itself.
/// Two reasons the internal enum is not put on the wire directly. First,
/// `AgentEvent.messageUpdate` carries an ``DoMoLLM/AssemblyEvent`` whose snapshot
/// payloads are not `Codable` and have no business crossing a socket — a consumer
/// wants the *delta text*, which is what ``messageDelta`` carries, exactly as
/// `PrintEventSink` already flattens it. Second, a wire vocabulary the client
/// decodes should be free to move independently of the runtime's internal event
/// shape; coupling them makes every internal refactor a breaking protocol change.
///
/// ``connected`` and ``heartbeat`` are server-originated and have no `AgentEvent`
/// source; every other case is produced by ``project(_:)``.
public enum ServerEvent: Sendable, Hashable {
    /// The opening frame, sent once when a client attaches. Carries the protocol
    /// version so a client verifies compatibility before reading anything else.
    case connected(protocolVersion: Int, sessionID: String)
    /// A periodic keep-alive so a proxy or a client read-timeout does not tear
    /// down an idle-but-live stream between turns.
    case heartbeat

    case agentStart
    case agentEnd(reason: String)
    case turnStart
    case turnEnd
    case messageStart(Message)
    /// A streaming assistant delta — text or reasoning, whichever this frame
    /// carried. The snapshot-bearing assembly cases are intentionally dropped.
    case messageDelta(text: String?, reasoning: String?)
    case messageEnd(Message)
    case toolStart(id: String, name: String, arguments: JSONValue)
    case toolEnd(id: String, name: String, output: String, isError: Bool, imageCount: Int)

    /// Projects one runtime event onto the wire, or `nil` when the event carries
    /// nothing a client needs (an assembly frame that is neither a text nor a
    /// reasoning delta — a snapshot boundary the client reconstructs from the
    /// deltas it already has).
    public static func project(_ event: AgentEvent) -> ServerEvent? {
        switch event {
        case .agentStart:
            return .agentStart
        case .agentEnd(_, let reason):
            return .agentEnd(reason: reasonString(reason))
        case .turnStart:
            return .turnStart
        case .turnEnd:
            return .turnEnd
        case .messageStart(let message):
            return .messageStart(message)
        case .messageUpdate(_, let assembly):
            switch assembly {
            case .textDelta(_, let delta):
                return .messageDelta(text: delta, reasoning: nil)
            case .reasoningDelta(_, let delta):
                return .messageDelta(text: nil, reasoning: delta)
            default:
                return nil
            }
        case .messageEnd(let message):
            return .messageEnd(message)
        case .toolExecutionStart(let id, let name, let arguments):
            return .toolStart(id: id, name: name, arguments: arguments.value)
        case .toolExecutionEnd(let id, let name, let result, let isError):
            return .toolEnd(
                id: id,
                name: name,
                output: result.output,
                isError: isError,
                imageCount: result.images.count
            )
        }
    }

    /// The stable snake_case spelling of a stop reason, so the wire does not
    /// depend on Swift's case names (which the client cannot see).
    private static func reasonString(_ reason: RunStopReason) -> String {
        switch reason {
        case .completed: return "completed"
        case .errored: return "errored"
        case .aborted: return "aborted"
        case .maxTurnsReached: return "max_turns_reached"
        case .stoppedByHook: return "stopped_by_hook"
        case .terminatedByTool: return "terminated_by_tool"
        }
    }
}

// MARK: - Codable

extension ServerEvent: Codable {
    /// The stable `type` discriminator each frame leads with.
    private enum Kind: String, Codable {
        case connected
        case heartbeat
        case agentStart = "agent_start"
        case agentEnd = "agent_end"
        case turnStart = "turn_start"
        case turnEnd = "turn_end"
        case messageStart = "message_start"
        case messageDelta = "message_delta"
        case messageEnd = "message_end"
        case toolStart = "tool_start"
        case toolEnd = "tool_end"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case sessionID = "sessionId"
        case reason
        case message
        case text
        case reasoning
        case id
        case name
        case arguments
        case output
        case isError
        case imageCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .connected:
            self = .connected(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionID: try container.decode(String.self, forKey: .sessionID)
            )
        case .heartbeat:
            self = .heartbeat
        case .agentStart:
            self = .agentStart
        case .agentEnd:
            self = .agentEnd(reason: try container.decode(String.self, forKey: .reason))
        case .turnStart:
            self = .turnStart
        case .turnEnd:
            self = .turnEnd
        case .messageStart:
            self = .messageStart(try container.decode(Message.self, forKey: .message))
        case .messageDelta:
            self = .messageDelta(
                text: try container.decodeIfPresent(String.self, forKey: .text),
                reasoning: try container.decodeIfPresent(String.self, forKey: .reasoning)
            )
        case .messageEnd:
            self = .messageEnd(try container.decode(Message.self, forKey: .message))
        case .toolStart:
            self = .toolStart(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                arguments: try container.decode(JSONValue.self, forKey: .arguments)
            )
        case .toolEnd:
            self = .toolEnd(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                output: try container.decode(String.self, forKey: .output),
                isError: try container.decode(Bool.self, forKey: .isError),
                imageCount: try container.decode(Int.self, forKey: .imageCount)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected(let protocolVersion, let sessionID):
            try container.encode(Kind.connected, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(sessionID, forKey: .sessionID)
        case .heartbeat:
            try container.encode(Kind.heartbeat, forKey: .type)
        case .agentStart:
            try container.encode(Kind.agentStart, forKey: .type)
        case .agentEnd(let reason):
            try container.encode(Kind.agentEnd, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .turnStart:
            try container.encode(Kind.turnStart, forKey: .type)
        case .turnEnd:
            try container.encode(Kind.turnEnd, forKey: .type)
        case .messageStart(let message):
            try container.encode(Kind.messageStart, forKey: .type)
            try container.encode(message, forKey: .message)
        case .messageDelta(let text, let reasoning):
            try container.encode(Kind.messageDelta, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(reasoning, forKey: .reasoning)
        case .messageEnd(let message):
            try container.encode(Kind.messageEnd, forKey: .type)
            try container.encode(message, forKey: .message)
        case .toolStart(let id, let name, let arguments):
            try container.encode(Kind.toolStart, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .toolEnd(let id, let name, let output, let isError, let imageCount):
            try container.encode(Kind.toolEnd, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(output, forKey: .output)
            try container.encode(isError, forKey: .isError)
            try container.encode(imageCount, forKey: .imageCount)
        }
    }
}
