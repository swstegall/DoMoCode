import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite("Session client routes", .serialized)
struct SessionClientRouteTests {
    private static let token = "session-client-route-token"

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private struct AttachmentBody: Encodable {
        let clientID: String
        let owner: String
        let requestAuthority: Bool
    }

    private struct OwnerBody: Encodable {
        let clientID: String
        let owner: String
    }

    private struct TransferBody: Encodable {
        let fromClientID: String
        let toClientID: String
        let owner: String
    }

    private struct CursorBody: Encodable {
        let clientID: String
        let owner: String
        let sequence: Int
    }

    private enum Method { case get, post }

    @Test("mirrors clients while routing authority and cursors through durable routes")
    func routes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-session-client-route-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = SessionClientManager(now: { "2026-01-01T00:00:00Z" })
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            sessionClients: manager
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

        let created = try await send(http, port: port, method: .post, path: "/session")
        #expect(created.status == 201)
        let session = try JSONDecoder().decode(SessionRef.self, from: created.body)

        let attachedA = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/attach",
            body: try JSONEncoder().encode(AttachmentBody(
                clientID: "client-a",
                owner: "owner-a",
                requestAuthority: true
            ))
        )
        #expect(attachedA.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: attachedA.body).role == .authority)

        let attachedB = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/attach",
            body: try JSONEncoder().encode(AttachmentBody(
                clientID: "client-b",
                owner: "owner-b",
                requestAuthority: true
            ))
        )
        #expect(attachedB.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: attachedB.body).role == .observer)

        let clients = try await send(http, port: port, method: .get, path: "/session/\(session.id)/clients")
        #expect(clients.status == 200)
        #expect(try JSONDecoder().decode([SessionClientAttachment].self, from: clients.body).count == 2)

        let deniedRelease = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/authority/release",
            body: try JSONEncoder().encode(OwnerBody(clientID: "client-b", owner: "owner-b"))
        )
        #expect(deniedRelease.status == 403)

        let transferred = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/authority/transfer",
            body: try JSONEncoder().encode(TransferBody(
                fromClientID: "client-a",
                toClientID: "client-b",
                owner: "owner-a"
            ))
        )
        #expect(transferred.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: transferred.body).role == .authority)

        let authority = try await send(http, port: port, method: .get, path: "/session/\(session.id)/client/authority")
        #expect(authority.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: authority.body).clientID == "client-b")

        let observerWrite = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/prompt",
            body: Data(#"{"prompt":"observer must not write"}"#.utf8),
            clientID: "client-a",
            owner: "owner-a"
        )
        #expect(observerWrite.status == 403)

        let cursor = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/cursor",
            body: try JSONEncoder().encode(CursorBody(clientID: "client-b", owner: "owner-b", sequence: 4))
        )
        #expect(cursor.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: cursor.body).eventCursor == 4)

        let events = try await send(http, port: port, method: .get, path: "/session/\(session.id)/client/events?after=1")
        #expect(events.status == 200)
        #expect(try JSONDecoder().decode([SessionClientEvent].self, from: events.body).count == 4)

        let wrongOwner = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/detach",
            body: try JSONEncoder().encode(OwnerBody(clientID: "client-b", owner: "owner-a"))
        )
        #expect(wrongOwner.status == 403)

        let detached = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/detach",
            body: try JSONEncoder().encode(OwnerBody(clientID: "client-b", owner: "owner-b"))
        )
        #expect(detached.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: detached.body).active == false)

        let active = try await send(http, port: port, method: .get, path: "/session/\(session.id)/clients")
        #expect(try JSONDecoder().decode([SessionClientAttachment].self, from: active.body).count == 1)
        let all = try await send(http, port: port, method: .get, path: "/session/\(session.id)/clients?includeInactive=true")
        #expect(try JSONDecoder().decode([SessionClientAttachment].self, from: all.body).count == 2)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("a corrupt durable ledger heals into a 200 attach instead of a permanent empty 400")
    func corruptLedgerHealsOnAttach() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-session-client-heal-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let clients = root.appendingPathComponent("clients", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The exact on-disk state that used to turn EVERY attach — and with it
        // every open, prompt, and approval — into a bodyless 400, surviving
        // restarts, reboots, and a ~/.domocode wipe, because this file is
        // workspace-local durable state that nothing ever repaired.
        let store = try SessionClientStore.create(directory: FilePath(clients.path))
        try Data("{not json\n".utf8).write(to: URL(fileURLWithPath: store.path.string))

        let manager = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            sessionClients: manager
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

        let created = try await send(http, port: port, method: .post, path: "/session")
        #expect(created.status == 201)
        let session = try JSONDecoder().decode(SessionRef.self, from: created.body)

        let attached = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/attach",
            body: try JSONEncoder().encode(AttachmentBody(
                clientID: "client-a",
                owner: "owner-a",
                requestAuthority: true
            ))
        )
        #expect(attached.status == 200)
        #expect(try JSONDecoder().decode(SessionClientAttachment.self, from: attached.body).role == .authority)

        // The poisoned journal was set aside — bytes intact for diagnosis —
        // and the healed one replays cleanly.
        let names = try FileManager.default.contentsOfDirectory(atPath: clients.path)
        #expect(names.contains { $0.contains(".corrupt-") })
        #expect(try store.records().map(\.event.sequence) == [1])

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("an attach the ledger refuses answers with the refusal in the body, not an empty 400")
    func invalidAttachCarriesItsMessage() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-session-client-message-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            sessionClients: SessionClientManager(now: { "2026-01-01T00:00:00Z" })
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

        let created = try await send(http, port: port, method: .post, path: "/session")
        let session = try JSONDecoder().decode(SessionRef.self, from: created.body)

        let refused = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(session.id)/client/attach",
            body: try JSONEncoder().encode(AttachmentBody(
                clientID: "",
                owner: "",
                requestAuthority: true
            ))
        )
        #expect(refused.status == 400)
        // The message is the whole point: a 400 whose body is empty is what
        // made this failure undiagnosable from the client for weeks.
        let text = String(decoding: refused.body, as: UTF8.self)
        #expect(text.contains("must not be empty"))

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    private func send(
        _ http: HTTPClient,
        port: Int,
        method: Method,
        path: String,
        body: Data? = nil,
        clientID: String? = nil,
        owner: String? = nil
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        if let clientID {
            request.headers.add(name: "x-domocode-client-id", value: clientID)
        }
        if let owner {
            request.headers.add(name: "x-domocode-client-owner", value: owner)
        }
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
