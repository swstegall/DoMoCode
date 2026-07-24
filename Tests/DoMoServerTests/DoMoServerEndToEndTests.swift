// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 6 exit criterion, exercised for real: a live DoMoServer is stood up on a
// loopback ephemeral port and driven with a real AsyncHTTPClient. The LLM is a
// scripted stream function (one assistant turn), so no mock gateway is needed —
// everything else (routing, the runtime actor, persistence, the SSE broadcast
// hub, token auth) is the real thing.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct DoMoServerEndToEndTests {

    static let token = "test-token-abc123"

    /// One assistant turn producing `text`, then stop.
    static func streamFn(_ text: String) -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(content: [.text(text)], model: "test-model", stopReason: .stop)))
                continuation.finish()
            }
        }
    }

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-server-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeServer(_ dirs: Dirs, answer: String = "hi there") -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: Self.streamFn(answer),
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    @Test("A prompt runs and streams events; REST reads and auth all hold")
    func fullFlow() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs)

        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            // Create a session.
            let create = try await send(http, port, .post, "/session")
            #expect(create.status == 201, "create status \(create.status)")
            let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id

            // Subscribe to the SSE hub, then POST the prompt, then read to agent_end.
            let events = try await driveRun(http, port, sessionID: id, prompt: "hello")
            #expect(events.contains { if case .connected = $0 { true } else { false } }, "no connected frame")
            #expect(
                events.contains {
                    if case .messageEnd(let m) = $0, case .assistant(let a) = m { a.text == "hi there" } else { false }
                },
                "no assistant message_end carrying the answer; got \(events)"
            )
            #expect(events.contains { if case .agentEnd = $0 { true } else { false } }, "no agent_end frame")

            // The transcript persisted and reads back over REST.
            let messages = try await send(http, port, .get, "/session/\(id)/messages")
            #expect(messages.status == 200)
            let transcript = try JSONDecoder().decode([Message].self, from: messages.body)
            #expect(transcript.contains { if case .user(let u) = $0 { u.text == "hello" } else { false } })
            #expect(transcript.contains { if case .assistant(let a) = $0 { a.text == "hi there" } else { false } })

            // The session is listed.
            let list = try await send(http, port, .get, "/sessions")
            #expect(list.status == 200)
            #expect(try JSONDecoder().decode([SessionSummary].self, from: list.body).contains { $0.id == id })

            // Fork mints a new id.
            let fork = try await send(http, port, .post, "/session/\(id)/fork")
            #expect(fork.status == 201)
            #expect(try JSONDecoder().decode(SessionRef.self, from: fork.body).id != id)

            // Auth: a missing token is rejected.
            let noAuth = try await send(http, port, .get, "/sessions", token: nil)
            #expect(noAuth.status == 401)

            // An unknown session is a 404.
            let missing = try await send(http, port, .get, "/session/nope/messages")
            #expect(missing.status == 404)
        }
        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    // MARK: - HTTP helpers

    private struct Reply { let status: UInt; let body: Data }

    /// A local method enum so the helper does not have to name NIOHTTP1's
    /// `HTTPMethod` — AsyncHTTPClient does not re-export it, but `.GET`/`.POST`
    /// resolve as implicit members against the request's `method` property type.
    private enum Method { case get, post }

    private func send(
        _ http: HTTPClient,
        _ port: Int,
        _ method: Method,
        _ path: String,
        json: [String: String]? = nil,
        token: String? = DoMoServerEndToEndTests.token
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        switch method {
        case .get: request.method = .GET
        case .post: request.method = .POST
        }
        if let token { request.headers.add(name: "authorization", value: "Bearer \(token)") }
        if let json {
            request.headers.add(name: "content-type", value: "application/json")
            // `[UInt8]` rather than `ByteBuffer`: AsyncHTTPClient does not re-export
            // the NIOCore type by name, but `.bytes` takes any byte collection.
            let payload = try JSONEncoder().encode(json)
            request.body = .bytes(Array(payload))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 4 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Reply(status: response.status.code, body: Data(bytes))
    }

    /// Open the SSE stream, wait for the `connected` frame, POST the prompt, then
    /// read frames until `agent_end`. Returns the decoded events in order.
    private func driveRun(
        _ http: HTTPClient,
        _ port: Int,
        sessionID: String,
        prompt: String
    ) async throws -> [ServerEvent] {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/session/\(sessionID)/events")
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let response = try await http.execute(request, timeout: .seconds(30))
        #expect(response.status.code == 200, "events status \(response.status.code)")

        var events: [ServerEvent] = []
        var text = ""
        var posted = false
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
            if events.contains(where: { if case .agentEnd = $0 { true } else { false } }) { break }
        }
        return events
    }

    private static func parse(_ frame: String) -> ServerEvent? {
        guard frame.hasPrefix("data: ") else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.dropFirst(6).utf8))
    }
}
