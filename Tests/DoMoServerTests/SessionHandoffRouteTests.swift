import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct SessionHandoffRouteTests {
    private static let token = "handoff-route-token"

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private struct CompleteBody: Encodable {
        let owner: String
        let target: SessionHandoffTarget?
        let metadata: [String: JSONValue]
    }

    private enum Method { case get, post }

    @Test("authenticated routes expose and resolve a durable session handoff")
    func handoffRoutes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-handoff-route-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SessionHandoffManager(now: { "2026-01-01T00:00:00Z" })
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            sessionHandoffs: manager
        ))
        let server = DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let serverTask = Task {
            try await server.run(onReady: { port in
                continuation.yield(port)
                continuation.finish()
            })
        }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        let http = HTTPClient(eventLoopGroupProvider: .singleton)

        let request = SessionHandoffRequest(
            id: "handoff-route-1",
            sourceSessionID: "source-session",
            sourceOwner: "source-client",
            targetOwner: "target-client",
            kind: .transfer,
            target: SessionHandoffTarget(
                sessionID: "target-session",
                workspaceID: "target-workspace"
            ),
            plan: SessionHandoffPlan(summary: "Continue the review."),
            artifacts: [SessionHandoffArtifact(
                id: "diff-1",
                kind: "diff",
                reference: "sha256:diff",
                sourceSessionID: "source-session"
            )]
        )

        let proposedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/handoff",
            body: try JSONEncoder().encode(request)
        )
        #expect(proposedReply.status == 201)
        let proposed = try JSONDecoder().decode(SessionHandoffRecord.self, from: proposedReply.body)
        #expect(proposed.state == .proposed)

        let listedReply = try await send(http, port: port, method: .get, path: "/handoffs?sourceSession=source-session")
        #expect(listedReply.status == 200)
        #expect(try JSONDecoder().decode([SessionHandoffRecord].self, from: listedReply.body) == [proposed])

        let deniedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/handoff/handoff-route-1/accept",
            body: try JSONEncoder().encode(["owner": "wrong-client"])
        )
        #expect(deniedReply.status == 403)

        let acceptedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/handoff/handoff-route-1/accept",
            body: try JSONEncoder().encode(["owner": "target-client"])
        )
        #expect(acceptedReply.status == 200)
        #expect(try JSONDecoder().decode(SessionHandoffRecord.self, from: acceptedReply.body).state == .accepted)

        let completedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/handoff/handoff-route-1/complete",
            body: try JSONEncoder().encode(CompleteBody(
                owner: "target-client",
                target: nil,
                metadata: ["received": .bool(true)]
            ))
        )
        #expect(completedReply.status == 200)
        let completed = try JSONDecoder().decode(SessionHandoffRecord.self, from: completedReply.body)
        #expect(completed.state == .completed)

        let eventsReply = try await send(http, port: port, method: .get, path: "/handoff/handoff-route-1/events?after=1")
        #expect(eventsReply.status == 200)
        #expect(try JSONDecoder().decode([SessionHandoffEvent].self, from: eventsReply.body).map(\.kind) == [.accepted, .completed])

        let exportReply = try await send(http, port: port, method: .get, path: "/handoff/handoff-route-1/export")
        #expect(exportReply.status == 200)
        #expect(try JSONDecoder().decode([SessionHandoffJournalEntry].self, from: exportReply.body).count == 3)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    private func send(
        _ http: HTTPClient,
        port: Int,
        method: Method,
        path: String,
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
        return Reply(
            status: response.status.code,
            body: Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        )
    }
}
