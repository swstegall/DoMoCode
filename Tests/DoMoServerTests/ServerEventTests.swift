// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import Testing

@Suite("ServerEvent projection and codec")
struct ServerEventTests {

    private let msg = Message.user("hello")
    private let assistant = AssistantMessage(model: "m")

    @Test("The protocol version is pinned")
    func protocolVersionPinned() {
        #expect(serverProtocolVersion == 1)
    }

    @Test("Lifecycle events project to their wire markers")
    func lifecycleProjection() {
        #expect(ServerEvent.project(.agentStart) == .agentStart)
        #expect(ServerEvent.project(.agentEnd(messages: [], reason: .aborted)) == .agentEnd(reason: "aborted"))
        #expect(ServerEvent.project(.agentEnd(messages: [], reason: .maxTurnsReached))
            == .agentEnd(reason: "max_turns_reached"))
        #expect(ServerEvent.project(.turnStart) == .turnStart)
        #expect(ServerEvent.project(.turnEnd(message: assistant, toolResults: [])) == .turnEnd)
        #expect(ServerEvent.project(.messageStart(msg)) == .messageStart(msg))
        #expect(ServerEvent.project(.messageEnd(msg)) == .messageEnd(msg))
    }

    @Test("Streaming assembly deltas project to text/reasoning; snapshots drop")
    func deltaProjection() {
        #expect(
            ServerEvent.project(.messageUpdate(message: msg, assembly: .textDelta(blockIndex: 0, delta: "hi")))
                == .messageDelta(text: "hi", reasoning: nil)
        )
        #expect(
            ServerEvent.project(.messageUpdate(message: msg, assembly: .reasoningDelta(blockIndex: 0, delta: "r")))
                == .messageDelta(text: nil, reasoning: "r")
        )
        // A non-delta assembly frame (a completed snapshot) carries nothing new to
        // the wire and projects to nil.
        #expect(ServerEvent.project(.messageUpdate(message: msg, assembly: .done(assistant))) == nil)
    }

    @Test("Tool events project id/name/args and flatten the result")
    func toolProjection() {
        let start = ServerEvent.project(
            .toolExecutionStart(toolCallID: "t1", toolName: "read", arguments: JSONValueBox(.object(["path": .string("x")])))
        )
        #expect(start == .toolStart(id: "t1", name: "read", arguments: .object(["path": .string("x")])))

        let image = ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50]))
        let end = ServerEvent.project(
            .toolExecutionEnd(
                toolCallID: "t1",
                toolName: "read",
                result: AgentToolResult(output: "out", images: [image]),
                isError: false
            )
        )
        #expect(end == .toolEnd(id: "t1", name: "read", output: "out", isError: false, imageCount: 1))
    }

    // MARK: Codec

    private func roundTrip(_ event: ServerEvent) throws -> ServerEvent {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(ServerEvent.self, from: data)
    }

    @Test("Every case round-trips through JSON")
    func codecRoundTrip() throws {
        let cases: [ServerEvent] = [
            .connected(protocolVersion: serverProtocolVersion, sessionID: "s-1"),
            .heartbeat,
            .agentStart,
            .agentEnd(reason: "completed"),
            .turnStart,
            .turnEnd,
            .messageStart(msg),
            .messageDelta(text: "hi", reasoning: nil),
            .messageDelta(text: nil, reasoning: "thinking"),
            .messageEnd(msg),
            .toolStart(id: "t", name: "read", arguments: .object(["path": .string("f")])),
            .toolEnd(id: "t", name: "read", output: "o", isError: true, imageCount: 2),
        ]
        for event in cases {
            #expect(try roundTrip(event) == event, "did not round-trip: \(event)")
        }
    }

    @Test("The wire carries a stable snake_case type discriminator and version")
    func wireShape() throws {
        let connected = try JSONValue(parsing: try JSONEncoder().encode(
            ServerEvent.connected(protocolVersion: 1, sessionID: "s-1")))
        #expect(connected["type"]?.stringValue == "connected")
        #expect(connected["protocolVersion"]?.intValue == 1)
        #expect(connected["sessionId"]?.stringValue == "s-1")

        let start = try JSONValue(parsing: try JSONEncoder().encode(ServerEvent.messageStart(msg)))
        #expect(start["type"]?.stringValue == "message_start")

        let toolEnd = try JSONValue(parsing: try JSONEncoder().encode(
            ServerEvent.toolEnd(id: "t", name: "read", output: "o", isError: false, imageCount: 0)))
        #expect(toolEnd["type"]?.stringValue == "tool_end")
        #expect(toolEnd["isError"]?.boolValue == false)
    }
}
