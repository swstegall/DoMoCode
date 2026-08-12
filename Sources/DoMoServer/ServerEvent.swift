// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation

// MARK: - Protocol version

/// The wire-protocol version carried on the SSE stream's opening frame.
///
/// The server and any client hand-maintain compatibility against this number —
/// there is no generated SDK (that breadth is the sibling-scale surface this
/// project bounds out). A client that does not recognize the version it is handed
/// should refuse rather than guess at a shape that may have moved.
///
/// This stays `1` across a purely *additive* frame such as ``ServerEvent/notice``.
/// The reason it can: `ServerClient.parseFrame` decodes each frame with `try?`
/// and returns `nil` on failure, so a client built before a new `type` existed
/// drops that one frame and keeps reading the stream — it does not tear the
/// connection down. Bumping this number instead would make every older client
/// refuse the whole session over a frame it never needed. Bump it when an
/// EXISTING frame's shape changes, which is the case `parseFrame` cannot absorb.
///
/// The same rule governs the REST payloads, for the same reason one level down.
/// A new **optional** field on a response body — ``DoMoServer/SessionStatus/accounting``
/// is the latest, `SessionStatus.runStartedAt` was an earlier one — is absorbed in
/// both directions by the plain `JSONDecoder` both sides use: a decoder ignores keys
/// it does not know, and the synthesized decoder reads an `Optional` property with
/// `decodeIfPresent`, so an absent key is `nil`. A new client reading an old server
/// sees `nil`; an old client reading a new server ignores the key; neither fails.
/// What is NOT covered, and what does require a bump: removing a field, renaming
/// one, changing a field's type, or adding a **non**-optional one — each of those
/// makes the older side's decode throw, and a throw on a REST payload is not a
/// dropped frame, it is a route that stopped working.
public let serverProtocolVersion = 1

// MARK: - Structured question wire values

/// One option in a server-originated structured question.
public struct ServerQuestionOption: Sendable, Hashable, Codable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One prompt in a server-originated structured question batch.
public struct ServerQuestionPrompt: Sendable, Hashable, Codable {
    public var header: String?
    public var question: String
    public var options: [ServerQuestionOption]
    public var allowsMultiple: Bool

    public init(
        header: String? = nil,
        question: String,
        options: [ServerQuestionOption],
        allowsMultiple: Bool = false
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
    }
}

/// The answer for one prompt in a structured question batch.
public struct ServerQuestionAnswer: Sendable, Hashable, Codable {
    public var selectedLabels: [String]

    public init(selectedLabels: [String]) {
        self.selectedLabels = selectedLabels
    }
}

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
    case connected(protocolVersion: Int, sessionID: String, running: Bool?)
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
    /// A completed message. For an assistant turn this is where **per-turn
    /// accounting** crosses the wire, and why there is no usage frame of its own:
    /// the whole ``DoMoLLM/Message`` is encoded, ``DoMoLLM/AssistantMessage``'s
    /// `CodingKeys` include `usage`, and that property is non-optional, so every
    /// assistant `message_end` carries the turn's ``DoMoLLM/Usage`` whether or not a
    /// consumer wants it. What a subscriber cannot reconstruct from these is the
    /// session's *cumulative* total — the turns before it attached were never on its
    /// stream — which is what ``DoMoServer/SessionStatus/accounting`` is for.
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

    /// A structured question the current tool call is waiting for. Answered
    /// out-of-band over `POST /session/{id}/question`.
    case questionRequest(id: String, sessionID: String, questions: [ServerQuestionPrompt])
    /// The pending structured question was answered or cancelled.
    case questionResolved(id: String)

    /// The number of messages waiting for the active run, plus the delivery mode
    /// the runtime will use at the next turn boundary. Additive and intentionally
    /// independent of transcript events: a client can render queue state without
    /// pretending the queued message has already been delivered.
    case queueUpdate(count: Int, mode: String)

    /// Something the run wants the user to see that is not transcript content —
    /// a retry in progress, a provider failure, a runtime error that never
    /// became a message. The wire projection of ``DoMoAgent/AgentNotice``.
    ///
    /// One case with a *struct* payload rather than a flat parameter list: this
    /// enum's `Kind`, `CodingKeys`, `encode` and `decode` are all hand-written,
    /// so each additional case costs four coordinated edits. A struct payload
    /// can grow a field without touching any of them again.
    case notice(ServerNotice)

    /// A typed child-session lifecycle event. The child id is intentionally
    /// carried on the wire so a client can open the real session rather than
    /// rendering delegation as an opaque tool transcript.
    case subagent(SubagentTaskEvent)

    /// A connected MCP server's tool catalog changed. Clients should invalidate
    /// their admin/catalog snapshots and refetch the affected server.
    case mcpChanged(server: String)

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
        case .notice(let notice):
            return .notice(ServerNotice(notice))
        case .subagent(let event):
            return .subagent(event)
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
        case .noProgress: return "no_progress"
        case .costLimitReached: return "cost_limit_reached"
        }
    }
}

/// A live session event with the monotonic cursor used by reconnecting clients.
///
/// The sequence is encoded alongside the existing event fields rather than in
/// a nested envelope. Older clients decode the same `type` and ignore this
/// additive key; newer clients can persist the cursor and ask the server to
/// replay events after it.
public struct SequencedServerEvent: Sendable, Hashable, Codable {
    public let sequence: Int
    public let event: ServerEvent

    public init(sequence: Int, event: ServerEvent) {
        self.sequence = sequence
        self.event = event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        var object = try container.decode([String: JSONValue].self)
        guard let sequence = object.removeValue(forKey: "sequence")?.intValue,
              sequence > 0
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing event sequence")
            )
        }
        self.sequence = sequence
        self.event = try JSONDecoder().decode(
            ServerEvent.self,
            from: try JSONValue.object(object).encoded()
        )
    }

    public func encode(to encoder: any Encoder) throws {
        let data = try JSONEncoder().encode(event)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        object["sequence"] = .int(sequence)
        try JSONValue.object(object).encode(to: encoder)
    }
}

// MARK: - ServerNotice

/// The wire form of ``DoMoAgent/AgentNotice``.
///
/// A separate type rather than making `AgentNotice` `Codable` directly, for the
/// reason the enum's own doc comment gives: the wire vocabulary must be free to
/// move independently of the runtime's internal shape. The one substantive
/// difference is `ttl`, which is a `Duration` in the runtime and a plain
/// millisecond count here — `Duration`'s `Codable` shape is a pair of
/// implementation-defined integer components, which is not something a
/// hand-written client should have to reproduce.
public struct ServerNotice: Sendable, Hashable, Codable {
    public enum Level: String, Sendable, Hashable, Codable { case info, warning, error }

    public var level: Level
    /// Machine-readable family. Reserved: `"retry"`, `"provider_error"`,
    /// `"runtime_error"`.
    public var code: String
    /// One line, already truncated by the producer.
    public var text: String
    /// Optional second line: the provider's own words, or the cause-chain tail.
    public var detail: String?
    /// A ``DoMoCore/DoMoError/Kind/label``, when the failing layer knew one.
    /// `DoMoError.Kind.labeled(_:)` turns it back into a kind, and answers `nil`
    /// for a label this build does not recognize.
    public var kind: String?
    /// How long the message stays relevant. `nil` means "use the consumer's
    /// default".
    public var ttlMilliseconds: Int?
    /// Typed, redacted recovery data, when this notice carries a provider
    /// diagnostic envelope.
    public var recovery: RecoveryEnvelope?

    public init(
        level: Level,
        code: String,
        text: String,
        detail: String? = nil,
        kind: String? = nil,
        ttlMilliseconds: Int? = nil,
        recovery: RecoveryEnvelope? = nil
    ) {
        self.level = level
        self.code = code
        self.text = text
        self.detail = detail
        self.kind = kind
        self.ttlMilliseconds = ttlMilliseconds
        self.recovery = recovery
    }

    /// Project a runtime notice onto the wire. Total: `AgentNotice.Level` and
    /// `ServerNotice.Level` are the same three raw values, so the `rawValue`
    /// round-trip cannot fail and does not need a fallback.
    public init(_ notice: AgentNotice) {
        self.init(
            level: Level(rawValue: notice.level.rawValue) ?? .info,
            code: notice.code,
            text: notice.text,
            detail: notice.detail,
            kind: notice.kind,
            // The single projection of a `Duration` onto a millisecond count
            // lives in `DoMoCore`; a second copy here would be a copy that can
            // drift. A TTL can be built from a `Retry-After` header, which is
            // text from the far side of a wire, so it must saturate at `Int.max`
            // ("forever", the right answer for a hostile header) rather than
            // trap and kill the server — which is exactly what that projection
            // does.
            ttlMilliseconds: notice.ttl.map(DoMoError.wholeMilliseconds),
            recovery: notice.recovery
        )
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
        case questionRequest = "question_request"
        case questionResolved = "question_resolved"
        case queueUpdate = "queue_update"
        case notice
        case subagent
        case mcpChanged = "mcp_changed"
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
        case questions
        case count
        case mode
        case notice
        case subagent
        case server
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .connected:
            self = .connected(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                // Absent from an older server's frame. Kept as `nil` rather than
                // defaulted to `false`: a client must be able to tell "the server
                // says idle" from "the server did not say", because it adopts the
                // former and must ignore the latter.
                running: try container.decodeIfPresent(Bool.self, forKey: .running)
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
        case .questionRequest:
            self = .questionRequest(
                id: try container.decode(String.self, forKey: .id),
                sessionID: try container.decode(String.self, forKey: .sessionID),
                questions: try container.decode([ServerQuestionPrompt].self, forKey: .questions)
            )
        case .questionResolved:
            self = .questionResolved(id: try container.decode(String.self, forKey: .id))
        case .queueUpdate:
            self = .queueUpdate(
                count: try container.decode(Int.self, forKey: .count),
                mode: try container.decode(String.self, forKey: .mode)
            )
        case .notice:
            self = .notice(try container.decode(ServerNotice.self, forKey: .notice))
        case .subagent:
            self = .subagent(try container.decode(SubagentTaskEvent.self, forKey: .subagent))
        case .mcpChanged:
            self = .mcpChanged(server: try container.decode(String.self, forKey: .server))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected(let protocolVersion, let sessionID, let running):
            try container.encode(Kind.connected, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encodeIfPresent(running, forKey: .running)
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
        case .questionRequest(let id, let sessionID, let questions):
            try container.encode(Kind.questionRequest, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(questions, forKey: .questions)
        case .questionResolved(let id):
            try container.encode(Kind.questionResolved, forKey: .type)
            try container.encode(id, forKey: .id)
        case .queueUpdate(let count, let mode):
            try container.encode(Kind.queueUpdate, forKey: .type)
            try container.encode(count, forKey: .count)
            try container.encode(mode, forKey: .mode)
        case .notice(let notice):
            try container.encode(Kind.notice, forKey: .type)
            try container.encode(notice, forKey: .notice)
        case .subagent(let event):
            try container.encode(Kind.subagent, forKey: .type)
            try container.encode(event, forKey: .subagent)
        case .mcpChanged(let server):
            try container.encode(Kind.mcpChanged, forKey: .type)
            try container.encode(server, forKey: .server)
        }
    }
}
