// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM
import Foundation
import Testing

@Suite("ACP provider adapter", .serialized)
struct ACPProviderTests {
    @Test("ACP updates map text, tool, plan, usage, and images without losing correlation")
    func mapsUpdates() {
        var sequence = 0
        let updates: [JSONValue] = [
            [
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("msg-1"),
                "content": ["type": .string("text"), "text": .string("hello")],
            ],
            [
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("call-1"),
                "title": .string("Inspect"),
                "status": .string("pending"),
            ],
            [
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("call-1"),
                "status": .string("completed"),
                "rawOutput": .string("done"),
            ],
            [
                "sessionUpdate": .string("plan"),
                "entries": [["content": .string("Inspect files"), "status": .string("pending")]],
            ],
            [
                "sessionUpdate": .string("usage_update"),
                "used": .int(12),
                "size": .int(100),
            ],
            [
                "sessionUpdate": .string("agent_message_chunk"),
                "content": ["type": .string("image"), "data": .string("encoded")],
            ],
        ]

        let events = updates.flatMap {
            ACPEventMapper.events(sessionID: "sess-1", update: $0, sequence: &sequence)
        }
        #expect(events.map(\.kind) == [.textDelta, .toolCallDelta, .toolResult, .plan, .usage, .image])
        #expect(events.allSatisfy { $0.payload["sessionId"] == .string("sess-1") })
        #expect(events[1].payload["toolCallId"] == .string("call-1"))
        #expect(events.map(\.sequence) == [0, 1, 2, 3, 4, 5])
    }

    @Test("ACP stdio lifecycle streams a prompt and shuts down cleanly")
    func streamsPrompt() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agent.py")
        try Self.fixture.write(to: script, atomically: true, encoding: .utf8)

        let client = ACPClient(configuration: ACPClientConfiguration(
            command: ["/usr/bin/python3", script.path],
            workingDirectory: directory.path,
            requestTimeout: .seconds(10)
        ))
        defer { Task { await client.shutdown() } }

        var events: [ProviderEvent] = []
        for try await event in await client.stream(ProviderRequest(
            model: "external-agent",
            messages: [ProviderMessage(role: .user, content: "inspect this")]
        )) {
            events.append(event)
        }

        #expect(events.map(\.kind).contains(.permission))
        #expect(events.map(\.kind).contains(.textDelta))
        #expect(events.map(\.kind).contains(.toolCallDelta))
        #expect(events.last?.kind == .messageEnd)
        #expect(events.first(where: { $0.kind == .textDelta })?.payload["delta"] == .string("ACP_REPLY"))
        #expect(events.last?.payload["stopReason"] == .string("end_turn"))
    }

    private static let fixture = #"""
        import sys, json
        def send(value):
            sys.stdout.write(json.dumps(value) + "\n")
            sys.stdout.flush()
        for line in sys.stdin:
            if not line.strip():
                continue
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            if method == "initialize":
                send({"jsonrpc":"2.0","id":request_id,"result":{
                    "protocolVersion":1,
                    "agentCapabilities":{"promptCapabilities":{}},
                    "agentInfo":{"name":"fixture","version":"1"}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0","id":request_id,"result":{"sessionId":"sess-fixture"}})
            elif method == "session/prompt":
                params = message.get("params", {})
                sid = params.get("sessionId", "sess-fixture")
                send({"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{
                    "sessionId":sid,
                    "toolCall":{"toolCallId":"call-fixture","title":"read"},
                    "options":[{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}})
                send({"jsonrpc":"2.0","method":"session/update","params":{
                    "sessionId":sid,"update":{"sessionUpdate":"tool_call","toolCallId":"call-fixture","status":"pending"}}})
                send({"jsonrpc":"2.0","method":"session/update","params":{
                    "sessionId":sid,"update":{"sessionUpdate":"agent_message_chunk","messageId":"msg-fixture","content":{"type":"text","text":"ACP_REPLY"}}}})
                send({"jsonrpc":"2.0","method":"session/update","params":{
                    "sessionId":sid,"update":{"sessionUpdate":"usage_update","used":1,"size":2}}})
                send({"jsonrpc":"2.0","id":request_id,"result":{"stopReason":"end_turn"}})
            elif method == "session/cancel":
                send({"jsonrpc":"2.0","id":request_id,"result":{}})
        """#
}
