import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct JobRouteTests {
    private static let token = "job-route-token"

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private enum Method { case get, post }

    @Test("authenticated routes expose cursored job state and ownership checks")
    func jobRoutes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-job-route-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = JobManager(now: { "2026-01-01T00:00:00Z" })
        _ = try await manager.admit(JobAdmission(
            id: "job-route-1",
            correlationID: "corr-route-1",
            sessionID: "session-route",
            taskID: "task-route",
            kind: "background",
            owner: "client-a"
        ))
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            jobManager: manager
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

        let listReply = try await send(http, port: port, method: .get, path: "/jobs?owner=client-a")
        #expect(listReply.status == 200)
        let listed = try JSONDecoder().decode([JobRecord].self, from: listReply.body)
        #expect(listed.map(\.id) == ["job-route-1"])
        #expect(listed[0].state == .queued)

        let snapshotReply = try await send(http, port: port, method: .get, path: "/job/job-route-1")
        #expect(snapshotReply.status == 200)
        #expect(try JSONDecoder().decode(JobRecord.self, from: snapshotReply.body).id == "job-route-1")

        let initialEventsReply = try await send(http, port: port, method: .get, path: "/job/job-route-1/events?after=0")
        #expect(initialEventsReply.status == 200)
        #expect(try JSONDecoder().decode([JobEvent].self, from: initialEventsReply.body).map(\.kind) == [.admitted])

        let deniedReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/job/job-route-1/cancel",
            body: try JSONEncoder().encode(["owner": "client-b"])
        )
        #expect(deniedReply.status == 403)

        let cancelledReply = try await send(
            http,
            port: port,
            method: .post,
            path: "/job/job-route-1/cancel",
            body: try JSONEncoder().encode(["owner": "client-a"])
        )
        #expect(cancelledReply.status == 200)
        #expect(try JSONDecoder().decode(JobRecord.self, from: cancelledReply.body).state == .cancelled)

        let resumedEventsReply = try await send(http, port: port, method: .get, path: "/job/job-route-1/events?after=1")
        #expect(resumedEventsReply.status == 200)
        #expect(try JSONDecoder().decode([JobEvent].self, from: resumedEventsReply.body).map(\.kind) == [.cancelled])

        let exportReply = try await send(http, port: port, method: .get, path: "/job/job-route-1/export")
        #expect(exportReply.status == 200)
        #expect(try JSONDecoder().decode([JobJournalEntry].self, from: exportReply.body).count == 2)

        let recoverReply = try await send(http, port: port, method: .post, path: "/jobs/recover")
        #expect(recoverReply.status == 200)
        #expect(try JSONDecoder().decode([JobRecord].self, from: recoverReply.body).isEmpty)

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
