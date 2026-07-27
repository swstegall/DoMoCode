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
    /// version so a client verifies compatibility before reading anything else, and
    /// whether a turn is ALREADY running.
    ///
    /// `running` exists because the client's run state is otherwise write-once per
    /// attach: it learns "running" only from an `agent_start` it was present for. A
    /// client that attaches mid-turn — a session switch, a reconnect, re-opening the
    /// same session — therefore believed the session was idle for the rest of the
    /// turn, which disabled Esc/abort and made the spinner stop. Run state has to be
    /// authoritative from the side that owns it.
    case connected(protocolVersion: Int, sessionID: String, running: Bool)
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

    /// A tool call the permission engine could not resolve on policy alone: the
    /// server is asking a client to approve it. Answered out-of-band over
    /// `POST /session/{id}/permission`, correlated by `(sessionID, id)`.
    /// Server-originated like ``connected`` — it has no `AgentEvent` source and is
    /// broadcast directly by the runtime, never projected.
    case permissionRequest(
        id: String,
        sessionID: String,
        permission: String,
        patterns: [String],
        always: [String],
        metadata: [String: JSONValue],
        disableAlways: Bool
    )
    /// The pending prompt with this id was answered (by a client, or torn down when
    /// the run ended). A subscriber still showing it should dismiss it.
    case permissionResolved(id: String)

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
        case permissionRequest = "permission_request"
        case permissionResolved = "permission_resolved"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case sessionID = "sessionId"
        case running
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
        case permission
        case patterns
        case always
        case metadata
        case disableAlways
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .connected:
            self = .connected(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                // Absent from an older server's frame; "not running" is the safe
                // default, and matches the previous behaviour exactly.
                running: try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
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
        case .permissionRequest:
            self = .permissionRequest(
                id: try container.decode(String.self, forKey: .id),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                permission: try container.decode(String.self, forKey: .permission),
                patterns: try container.decode([String].self, forKey: .patterns),
                always: try container.decode([String].self, forKey: .always),
                metadata: try container.decode([String: JSONValue].self, forKey: .metadata),
                disableAlways: try container.decode(Bool.self, forKey: .disableAlways)
            )
        case .permissionResolved:
            self = .permissionResolved(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected(let protocolVersion, let sessionID, let running):
            try container.encode(Kind.connected, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(running, forKey: .running)
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
        case .permissionRequest(let id, let sessionID, let permission, let patterns, let always, let metadata, let disableAlways):
            try container.encode(Kind.permissionRequest, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(permission, forKey: .permission)
            try container.encode(patterns, forKey: .patterns)
            try container.encode(always, forKey: .always)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(disableAlways, forKey: .disableAlways)
        case .permissionResolved(let id):
            try container.encode(Kind.permissionResolved, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}
