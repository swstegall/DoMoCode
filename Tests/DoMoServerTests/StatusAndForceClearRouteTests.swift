// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The HTTP half of the wedge fix, against a live server on a loopback port:
// `GET /session/{id}/status` (so a client can ask instead of guess) and
// `POST /session/{id}/force-clear` (so a wedged slot can be freed without a new
// session). Plus the prompt route's raised body cap, which is what stops a
// dropped image attachment from 413ing.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import JSONSchema
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct StatusAndForceClearRouteTests {

    static let token = "test-token-status"

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-status-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A tool that parks uncancellably, so a run genuinely holds the slot while
    /// the HTTP assertions run.
    private final class ParkingTool: AgentTool, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var definition: ToolDefinition {
            ToolDefinition(name: "park", description: "parks until released", parameters: JSONSchema())
        }

        func execute(_ arguments: DoMoCore.JSONValue) async throws(DoMoError) -> AgentToolResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters.append(continuation)
                lock.unlock()
            }
            return AgentToolResult(output: "released")
        }

        var parkedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }

        func releaseAll() {
            lock.lock()
            let all = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in all { waiter.resume() }
        }
    }

    private static func parkThenText() -> AgentStreamFn {
        let calls = Mutex(0)
        return { _ in
            let n = calls.withLock { value in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if n == 1 {
                    let call = ToolCallBlock(id: "call_park", name: "park", arguments: .object([:]))
                    continuation.yield(.done(AssistantMessage(
                        content: [.toolCall(call)], model: "test-model", stopReason: .toolUse
                    )))
                } else {
                    continuation.yield(.done(AssistantMessage(
                        content: [.text("ok")], model: "test-model", stopReason: .stop
                    )))
                }
                continuation.finish()
            }
        }
    }

    private func makeServer(_ dirs: Dirs, tools: [any AgentTool], streamFn: @escaping AgentStreamFn) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: tools,
            model: "test-model",
            streamFn: streamFn,
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

    // MARK: - Routes

    @Test("status and force-clear round-trip over HTTP, and force-clear unwedges the session")
    func statusAndForceClearRoundTrip() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        let server = makeServer(dirs, tools: [tool], streamFn: Self.parkThenText())

        try await withServer(server) { http, port in
            let create = try await send(http, port, .post, "/session")
            let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id

            // Idle.
            let idle = try await send(http, port, .get, "/session/\(id)/status")
            #expect(idle.status == 200, "status returned \(idle.status)")
            let idleStatus = try JSONDecoder().decode(SessionStatus.self, from: idle.body)
            #expect(idleStatus.sessionID == id)
            #expect(idleStatus.running == false)
            #expect(idleStatus.runStartedAt == nil)

            // Wedge it.
            let prompt = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": "go"])
            #expect(prompt.status == 202)
            var parked = false
            for _ in 0..<250 where !parked {
                if tool.parkedCount == 1 { parked = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(parked, "the run never reached the parking tool")

            let busy = try await send(http, port, .get, "/session/\(id)/status")
            let busyStatus = try JSONDecoder().decode(SessionStatus.self, from: busy.body)
            #expect(busyStatus.running)
            #expect(busyStatus.runStartedAt != nil)

            // A second prompt is refused — the user-visible symptom.
            let refused = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": "again"])
            #expect(refused.status == 409, "expected the wedged session to 409, got \(refused.status)")

            // Force-clear frees it.
            let cleared = try await send(http, port, .post, "/session/\(id)/force-clear")
            #expect(cleared.status == 200, "force-clear returned \(cleared.status)")
            #expect(try JSONDecoder().decode(ForceClearResult.self, from: cleared.body).cleared)

            let after = try await send(http, port, .get, "/session/\(id)/status")
            #expect(try JSONDecoder().decode(SessionStatus.self, from: after.body).running == false)

            // And the session takes prompts again, with no new session.
            let recovered = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": "second"])
            #expect(recovered.status == 202, "the recovered session refused a prompt: \(recovered.status)")
        }
    }

    @Test("Both new routes 404 an unknown session and 401 without the bearer token")
    func routesAreGuarded() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, tools: [], streamFn: Self.parkThenText())

        try await withServer(server) { http, port in
            let missingStatus = try await send(http, port, .get, "/session/nope/status")
            #expect(missingStatus.status == 404, "unknown session status -> \(missingStatus.status)")
            let missingClear = try await send(http, port, .post, "/session/nope/force-clear")
            #expect(missingClear.status == 404, "unknown session force-clear -> \(missingClear.status)")

            // The auth middleware is router-wide; these routes must not have
            // escaped it. A 401 must win over the 404 an unknown id would give,
            // or the endpoint becomes a session-id oracle for any local process.
            for token in [nil, "wrong"] as [String?] {
                let noAuthStatus = try await send(http, port, .get, "/session/any/status", token: token)
                #expect(noAuthStatus.status == 401, "status with token \(token ?? "<none>") -> \(noAuthStatus.status)")
                let noAuthClear = try await send(http, port, .post, "/session/any/force-clear", token: token)
                #expect(noAuthClear.status == 401, "force-clear with token \(token ?? "<none>") -> \(noAuthClear.status)")
            }
        }
    }

    @Test("The wire protocol version is unchanged — an old client must not refuse a new server")
    func protocolVersionUnchanged() {
        #expect(serverProtocolVersion == 1)
    }

    // MARK: - Body caps

    @Test("The prompt route accepts a body over the 4 MiB default; other routes still do not")
    func promptRouteHasTheLargerCap() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, tools: [], streamFn: DoMoServerEndToEndTests.streamFn("ok"))

        try await withServer(server) { http, port in
            let create = try await send(http, port, .post, "/session")
            let id = try JSONDecoder().decode(SessionRef.self, from: create.body).id

            // ~6 MiB of payload: over the old cap, well under the new one. An image
            // attachment lands here base64-encoded, which is where the real 413 came
            // from — a dropped screenshot, silently refused.
            let big = String(repeating: "x", count: 6 << 20)
            let accepted = try await send(http, port, .post, "/session/\(id)/prompt", json: ["prompt": big])
            #expect(accepted.status == 202, "a 6 MiB prompt was refused with \(accepted.status)")

            // A control route keeps the modest default, so raising the prompt cap
            // did not raise every buffer in the server.
            let rejected = try await send(
                http, port, .post, "/session/\(id)/permission",
                json: ["requestID": "r", "reply": "once", "message": big]
            )
            #expect(rejected.status != 200, "the default body cap was raised everywhere")
            #expect((400..<500).contains(Int(rejected.status)), "expected a 4xx, got \(rejected.status)")
        }
    }

    @Test("The prompt cap is 32 MiB and the default is 4 MiB")
    func capsArePinned() {
        #expect(DoMoServer.maximumPromptBodyBytes == 32 << 20)
        #expect(DoMoServer.defaultBodyBytes == 4 << 20)
    }

    // MARK: - Helpers

    private struct Reply { let status: UInt; let body: Data }
    private enum Method { case get, post }

    private func withServer(
        _ server: DoMoServer,
        _ body: (HTTPClient, Int) async throws -> Void
    ) async throws {
        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        var thrown: (any Error)?
        do {
            try await body(http, port)
        } catch {
            thrown = error
        }
        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
        if let thrown { throw thrown }
    }

    private func send(
        _ http: HTTPClient,
        _ port: Int,
        _ method: Method,
        _ path: String,
        json: [String: String]? = nil,
        token: String? = StatusAndForceClearRouteTests.token
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        switch method {
        case .get: request.method = .GET
        case .post: request.method = .POST
        }
        if let token { request.headers.add(name: "authorization", value: "Bearer \(token)") }
        if let json {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(try JSONEncoder().encode(json)))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 64 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Reply(status: response.status.code, body: Data(bytes))
    }
}
