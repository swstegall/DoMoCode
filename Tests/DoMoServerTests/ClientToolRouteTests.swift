// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct ClientToolRouteTests {
    private static let token = "client-tool-route-token"

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-client-tool-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private struct ToolReply: Encodable {
        let requestID: String
        let output: String
        let isError: Bool
        let images: [ImageBlock]
    }

    @Test("client-defined tool requests round-trip with output and images")
    func clientToolRoundTrip() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, timeout: .seconds(1))

        try await withServer(server) { http, port in
            let sessionID = try await createSession(http, port)

            let tools = try await send(http, port, .get, "/session/\(sessionID)/tools")
            let catalog = try JSONDecoder().decode([ToolCatalogEntry].self, from: tools.body)
            let clientTool = catalog.first { $0.name == "database_query" }
            #expect(clientTool?.metadata["clientDefined"] == .bool(true))

            let events = try await drive(
                http,
                port,
                sessionID: sessionID,
                answer: { requestID in
                    _ = try await send(
                        http,
                        port,
                        .post,
                        "/session/\(sessionID)/client-tool",
                        body: try JSONEncoder().encode(ToolReply(
                            requestID: requestID,
                            output: "rows: 1",
                            isError: false,
                            images: [ImageBlock(mediaType: "image/png", data: Data([0, 1, 2]))]
                        ))
                    )
                }
            )

            guard let request = events.compactMap({ event -> (String, String, JSONValue)? in
                guard case .clientToolRequest(let id, _, let name, let arguments) = event else { return nil }
                return (id, name, arguments)
            }).first else {
                Issue.record("No client_tool_request frame was emitted: \(events)")
                return
            }
            #expect(request.1 == "database_query")
            #expect(request.2["sql"] == .string("select 1"))
            #expect(events.contains { event in
                if case .clientToolResolved(let id, let name, let isError) = event {
                    return id == request.0 && name == "database_query" && !isError
                }
                return false
            })
            #expect(events.contains { if case .toolEnd(_, "database_query", "rows: 1", false, 1) = $0 { true } else { false } })
            #expect(events.contains { if case .agentEnd = $0 { true } else { false } })
        }
    }

    @Test("client-defined tool timeout returns an error and settles the run")
    func clientToolTimeoutSettles() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, timeout: .milliseconds(20))

        try await withServer(server) { http, port in
            let sessionID = try await createSession(http, port)
            let events = try await drive(http, port, sessionID: sessionID, answer: nil)
            #expect(events.contains { if case .clientToolResolved(_, "database_query", true) = $0 { true } else { false } })
            #expect(events.contains { if case .toolEnd(_, "database_query", _, true, 0) = $0 { true } else { false } })
            #expect(events.contains { if case .agentEnd = $0 { true } else { false } })
        }
    }

    @Test("aborting a client-defined tool drains its pending continuation")
    func clientToolAbortDrains() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, timeout: .seconds(10))

        try await withServer(server) { http, port in
            let sessionID = try await createSession(http, port)
            let events = try await drive(
                http,
                port,
                sessionID: sessionID,
                answer: { _ in
                    _ = try await send(http, port, .post, "/session/\(sessionID)/abort")
                }
            )
            #expect(events.contains { if case .clientToolResolved(_, "database_query", true) = $0 { true } else { false } })
            #expect(events.contains { if case .agentEnd(reason: "aborted") = $0 { true } else { false } })
        }
    }

    private func makeServer(_ dirs: Dirs, timeout: Duration) -> DoMoServer {
        let calls = Mutex(0)
        let stream: AgentStreamFn = { _ in
            let turn = calls.withLock { value in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if turn == 1 {
                    let call = ToolCallBlock(
                        id: "call_database_query",
                        name: "database_query",
                        arguments: ["sql": "select 1"]
                    )
                    continuation.yield(.done(AssistantMessage(
                        content: [.toolCall(call)],
                        model: "test-model",
                        stopReason: .toolUse
                    )))
                } else {
                    continuation.yield(.done(AssistantMessage(
                        content: [.text("query complete")],
                        model: "test-model",
                        stopReason: .stop
                    )))
                }
                continuation.finish()
            }
        }
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: stream,
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            clientToolTimeout: timeout
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    private func createSession(_ http: HTTPClient, _ port: Int) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "clientTools": [[
                "name": "database_query",
                "description": "Run a read-only database query.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["sql": ["type": "string"]],
                    "required": ["sql"]
                ]
            ]]
        ])
        let response = try await send(http, port, .post, "/session", body: body)
        #expect(response.status == 201)
        return try JSONDecoder().decode(SessionRef.self, from: response.body).id
    }

    private func withServer(
        _ server: DoMoServer,
        _ body: (HTTPClient, Int) async throws -> Void
    ) async throws {
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let task = Task { try await server.run(onReady: { port in continuation.yield(port); continuation.finish() }) }
        var iterator = ports.makeAsyncIterator()
        let port = await iterator.next() ?? 0
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        var thrown: (any Error)?
        do { try await body(http, port) } catch { thrown = error }
        try await http.shutdown()
        task.cancel()
        _ = try? await task.value
        if let thrown { throw thrown }
    }

    private func drive(
        _ http: HTTPClient,
        _ port: Int,
        sessionID: String,
        answer: (@Sendable (String) async throws -> Void)?
    ) async throws -> [ServerEvent] {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/session/\(sessionID)/events")
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let response = try await http.execute(request, timeout: .seconds(30))
        var events: [ServerEvent] = []
        var pending = ""
        var prompted = false
        var answered = false
        var finished = false
        for try await chunk in response.body {
            var chunk = chunk
            pending += chunk.readString(length: chunk.readableBytes) ?? ""
            while let separator = pending.range(of: "\n\n") {
                let frame = String(pending[pending.startIndex..<separator.lowerBound])
                pending.removeSubrange(pending.startIndex..<separator.upperBound)
                guard frame.hasPrefix("data: "), let event = try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.dropFirst(6).utf8)) else { continue }
                events.append(event)
                if case .connected = event, !prompted {
                    prompted = true
                    _ = try await send(http, port, .post, "/session/\(sessionID)/prompt", body: JSONSerialization.data(withJSONObject: ["prompt": "query"]))
                }
                if case .clientToolRequest(let requestID, _, _, _) = event, !answered {
                    answered = true
                    if let answer { try await answer(requestID) }
                }
                if case .agentEnd = event { finished = true }
            }
            if finished { break }
        }
        return events
    }

    private enum Method { case get, post }

    private func send(
        _ http: HTTPClient,
        _ port: Int,
        _ method: Method,
        _ path: String,
        body: Data? = nil
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        if let body {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(body))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 4 << 20)
        return Reply(status: response.status.code, body: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    }
}
