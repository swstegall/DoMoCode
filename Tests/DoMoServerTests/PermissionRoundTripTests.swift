// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 8b exit criterion, exercised for real: a live DoMoServer gated by the
// permission engine asks over SSE when a tool needs approval, and a REST answer
// decides it. A scripted stream function drives one bash tool call then a final text
// turn; the engine parks the run on the ask, the test answers over
// `POST /session/{id}/permission`, and the run unwinds. Everything but the LLM is real.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Foundation
import JSONSchema
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct PermissionRoundTripTests {
    static let token = "test-token-perm"

    /// A tool named `bash` (so the baseline policy asks) that records it actually ran.
    private struct FakeBashTool: AgentTool {
        var definition: ToolDefinition { ToolDefinition(name: "bash", description: "bash", parameters: JSONSchema()) }
        func execute(_ arguments: DoMoCore.JSONValue) async throws(DoMoError) -> AgentToolResult {
            AgentToolResult(output: "TOOL_RAN", isError: false, details: .null, images: [])
        }
    }

    /// Turn 1 requests a bash call; turn 2 (after the tool result) finishes with text.
    static func toolThenText() -> AgentStreamFn {
        let turn = Mutex(0)
        return { _ in
            let n = turn.withLock { value in value += 1; return value }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if n == 1 {
                    let call = ToolCallBlock(id: "call_bash", name: "bash", arguments: .object(["command": .string("rm -rf /tmp/x")]))
                    continuation.yield(.done(AssistantMessage(content: [.toolCall(call)], model: "test-model", stopReason: .toolUse)))
                } else {
                    continuation.yield(.done(AssistantMessage(content: [.text("done")], model: "test-model", stopReason: .stop)))
                }
                continuation.finish()
            }
        }
    }

    private struct Dirs {
        let root: URL, cwd: URL, sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("domo-perm-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeGatedServer(_ dirs: Dirs) -> DoMoServer {
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home/test")
        let factory = PermissionRequestFactory(workingDirectory: dirs.cwd.path)
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [FakeBashTool()],
            model: "test-model",
            streamFn: Self.toolThenText(),
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            permissions: ServerRuntime.PermissionRuntime(ruleset: ruleset, factory: factory, persist: { _ in })
        ))
        return DoMoServer(runtime: runtime, options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600))
    }

    @Test("Reject over REST refuses the tool; Allow-once runs it — both round-trip")
    func roundTrip() async throws {
        for (reply, shouldRun) in [("reject", false), ("once", true)] {
            let dirs = try Dirs()
            defer { dirs.cleanUp() }
            let server = makeGatedServer(dirs)
            let (portStream, portCont) = AsyncStream<Int>.makeStream()
            let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
            var portIterator = portStream.makeAsyncIterator()
            let port = await portIterator.next() ?? 0

            let http = HTTPClient(eventLoopGroupProvider: .singleton)
            do {
                let create = try await send(http, port, .post, "/session")
                let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id

                let events = try await driveAnswering(http, port, sessionID: id, prompt: "run it", reply: reply)

                // The server asked over SSE, and it was resolved.
                #expect(events.contains { if case .permissionRequest(_, _, let p, _, _, _, _) = $0 { p == "bash" } else { false } },
                        "no permission_request (reply=\(reply)); got \(events.map(kind))")
                #expect(events.contains { if case .permissionResolved = $0 { true } else { false } }, "no permission_resolved")

                // The decision is reflected in the tool result.
                let toolEnd = events.first { if case .toolEnd = $0 { true } else { false } }
                if case .toolEnd(_, _, let output, let isError, _) = toolEnd {
                    #expect((output.contains("TOOL_RAN")) == shouldRun, "reply=\(reply) output=\(output)")
                    #expect(isError == !shouldRun)
                } else {
                    Issue.record("no tool_end (reply=\(reply))")
                }
                #expect(events.contains { if case .agentEnd = $0 { true } else { false } }, "no agent_end")
            }
            try await http.shutdown()
            serverTask.cancel()
            _ = try? await serverTask.value
        }
    }

    // MARK: helpers

    private struct Reply { let status: UInt; let body: Data }
    private enum Method { case get, post }

    private func send(_ http: HTTPClient, _ port: Int, _ method: Method, _ path: String, json: [String: String]? = nil) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        if let json {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(try JSONEncoder().encode(json)))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 4 << 20)
        return Reply(status: response.status.code, body: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    }

    /// Open the SSE stream, POST the prompt on `connected`, POST the answer on the
    /// first `permission_request`, and read until `agent_end`.
    private func driveAnswering(_ http: HTTPClient, _ port: Int, sessionID: String, prompt: String, reply: String) async throws -> [ServerEvent] {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/session/\(sessionID)/events")
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let response = try await http.execute(request, timeout: .seconds(30))
        #expect(response.status.code == 200)

        var events: [ServerEvent] = []
        var text = ""
        var posted = false
        var answered = false
        for try await chunk in response.body {
            var chunk = chunk
            text += chunk.readString(length: chunk.readableBytes) ?? ""
            while let separator = text.range(of: "\n\n") {
                let frame = String(text[text.startIndex..<separator.lowerBound])
                text.removeSubrange(text.startIndex..<separator.upperBound)
                if let event = Self.parse(frame) { events.append(event) }
            }
            if !posted, events.contains(where: { if case .connected = $0 { true } else { false } }) {
                posted = true
                _ = try await send(http, port, .post, "/session/\(sessionID)/prompt", json: ["prompt": prompt])
            }
            if !answered, let requestID = events.compactMap(Self.requestID).first {
                answered = true
                _ = try await send(http, port, .post, "/session/\(sessionID)/permission", json: ["requestID": requestID, "reply": reply])
            }
            if events.contains(where: { if case .agentEnd = $0 { true } else { false } }) { break }
        }
        return events
    }

    private static func requestID(_ event: ServerEvent) -> String? {
        if case .permissionRequest(let id, _, _, _, _, _, _) = event { return id }
        return nil
    }
    private static func parse(_ frame: String) -> ServerEvent? {
        guard frame.hasPrefix("data: ") else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.dropFirst(6).utf8))
    }
}

private func kind(_ event: ServerEvent) -> String {
    switch event {
    case .connected: return "connected"
    case .permissionRequest: return "permission_request"
    case .permissionResolved: return "permission_resolved"
    case .toolStart: return "tool_start"
    case .toolEnd: return "tool_end"
    case .agentEnd: return "agent_end"
    default: return "other"
    }
}
