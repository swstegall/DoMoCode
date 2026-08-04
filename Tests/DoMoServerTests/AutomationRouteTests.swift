import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct AutomationRouteTests {
    private static let token = "automation-route-token"

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private enum Method { case get, post }

    @Test("authenticated routes expose audited automation policy without launching work")
    func automationRoutes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-automation-route-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            automationRegistry: registry
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

        let definition = AutomationDefinition(
            id: "automation-route-1",
            displayName: "Review changes",
            owner: "client-a",
            profileID: "review",
            workspaceRoot: cwd.path,
            sandboxPolicyID: "workspace-readonly",
            trigger: AutomationTrigger(kind: .manual),
            createdAt: "2026-01-01T00:00:00Z"
        )
        let registeredReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/automation",
            body: try JSONEncoder().encode(definition)
        )
        #expect(registeredReply.status == 201)
        #expect(try JSONDecoder().decode(AutomationDefinition.self, from: registeredReply.body).enabled == false)

        let listedReply = try await send(http, port: port, method: .get, path: "/automations?owner=client-a")
        #expect(listedReply.status == 200)
        #expect(try JSONDecoder().decode([AutomationDefinition].self, from: listedReply.body).map(\.id) == [definition.id])

        let deniedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/automation/automation-route-1/enable",
            body: try JSONEncoder().encode(["owner": "client-b"])
        )
        #expect(deniedReply.status == 403)

        let enabledReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/automation/automation-route-1/enable",
            body: try JSONEncoder().encode(["owner": "client-a"])
        )
        #expect(enabledReply.status == 200)

        let invocation = AutomationInvocation(
            id: "automation-invocation-1",
            automationID: definition.id,
            source: .userPrompt,
            requestedBy: "client-a",
            sessionID: "session-a",
            createdAt: "2026-01-01T00:00:01Z",
            input: ["prompt": "Review the diff."]
        )
        let invokedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/automation/automation-route-1/invoke",
            body: try JSONEncoder().encode(invocation)
        )
        #expect(invokedReply.status == 202)
        #expect(try JSONDecoder().decode(AutomationInvocation.self, from: invokedReply.body) == invocation)

        let eventReply = try await send(http, port: port, method: .get, path: "/automation/automation-route-1/events?after=1")
        #expect(eventReply.status == 200)
        #expect(try JSONDecoder().decode([AutomationAuditEvent].self, from: eventReply.body).map(\.kind) == [.enabled, .invoked])

        let invocationReply = try await send(http, port: port, method: .get, path: "/automation/automation-route-1/invocations")
        #expect(invocationReply.status == 200)
        #expect(try JSONDecoder().decode([AutomationInvocation].self, from: invocationReply.body) == [invocation])

        let exportReply = try await send(http, port: port, method: .get, path: "/automation/automation-route-1/export")
        #expect(exportReply.status == 200)
        #expect(try JSONDecoder().decode([AutomationJournalEntry].self, from: exportReply.body).count == 3)

        let disabledReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/automation/automation-route-1/disable",
            body: try JSONEncoder().encode(["owner": "client-a"])
        )
        #expect(disabledReply.status == 200)
        #expect(try JSONDecoder().decode(AutomationDefinition.self, from: disabledReply.body).enabled == false)

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
