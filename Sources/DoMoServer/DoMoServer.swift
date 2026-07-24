// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation
import Hummingbird
import Logging

// MARK: - Request bodies

/// `POST /session` body. Absent (empty body) means a fresh session.
private struct CreateBody: Decodable {
    var resume: String?
}

/// `POST /session/{id}/prompt` body. `images` reuses ``DoMoLLM/ImageBlock``'s
/// base64 codec, so a client attaches by sending `{mediaType, data}` parts.
private struct PromptBody: Decodable {
    var prompt: String
    var images: [ImageBlock]?
}

// MARK: - Auth middleware

/// Rejects any request that does not present the server's bearer token.
///
/// The server binds loopback-only, but loopback is reachable by every local
/// process, so a per-session token is the actual gate. There is no login flow and
/// no OAuth — a single opaque token minted at `serve` time, exactly the
/// bearer-only posture the project keeps.
struct TokenAuthMiddleware: RouterMiddleware {
    let token: String

    // `next` is `@concurrent` to match the protocol requirement, which Hummingbird
    // declares without this package's `NonisolatedNonsendingByDefault`: an unmarked
    // async closure type would infer `nonisolated(nonsending)` and fail to conform.
    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: @concurrent (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let provided = request.headers[.authorization],
            Self.constantTimeEqual(provided, "Bearer \(token)")
        else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }

    /// Compare in constant time over the byte length, so response timing does not
    /// leak the token position-by-position. The length is allowed to short-circuit
    /// (it reveals nothing about a high-entropy secret's content), matching the
    /// stated posture that every local process is untrusted.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

// MARK: - DoMoServer

/// The headless HTTP/SSE server: a thin Hummingbird router over a ``ServerRuntime``.
///
/// Every route is a projection of state the runtime already owns. The write path
/// (`POST .../prompt`) starts a run and returns `202` immediately; the read path
/// (`GET .../events`) is the SSE hub a client subscribes to. This is the
/// single-client-first, broadcast-capable shape the roadmap fixes: one loopback
/// bind, one bearer token, and no multi-instance supervision or discovery.
public struct DoMoServer: Sendable {

    public struct Options: Sendable {
        public var host: String
        public var port: Int
        public var token: String
        public var heartbeatSeconds: Int

        public init(host: String = "127.0.0.1", port: Int = 4100, token: String, heartbeatSeconds: Int = 15) {
            self.host = host
            self.port = port
            self.token = token
            self.heartbeatSeconds = heartbeatSeconds
        }
    }

    let runtime: ServerRuntime
    let options: Options
    let logger: Logger

    public init(runtime: ServerRuntime, options: Options, logger: Logger = Logger(label: "domo.server")) {
        self.runtime = runtime
        self.options = options
        self.logger = logger
    }

    /// Build and run the server, blocking until the task is cancelled or a
    /// shutdown signal arrives. `onReady` is called once the socket is bound, with
    /// the actual port (which differs from `options.port` when 0 was requested) —
    /// the seam a test uses to learn where to connect.
    public func run(onReady: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        let router = buildRouter()
        let runtime = self.runtime
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(options.host, port: options.port)),
            onServerRunning: { channel in
                await onReady(channel.localAddress?.port ?? 0)
            },
            logger: logger
        )
        do {
            try await app.runService()
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func buildRouter() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: TokenAuthMiddleware(token: options.token))

        router.post("/session") { request, context in
            try await self.mapErrors {
                let body = try await Self.optionalBody(CreateBody.self, request)
                let ref = try await self.runtime.createSession(resume: body?.resume)
                return try Self.json(ref, status: .created)
            }
        }

        router.get("/sessions") { _, _ in
            try await self.mapErrors {
                try Self.json(try await self.runtime.listSessions())
            }
        }

        router.get("/session/:id/messages") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.messages(sessionID: id))
            }
        }

        router.get("/session/:id/children") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let parent = request.uri.queryParameters["parent"].map(String.init)
                return try Self.json(try await self.runtime.children(sessionID: id, parent: parent))
            }
        }

        router.post("/session/:id/prompt") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(PromptBody.self, request)
                try await self.runtime.startRun(sessionID: id, prompt: body.prompt, attachments: body.images ?? [])
                return Response(status: .accepted)
            }
        }

        router.post("/session/:id/abort") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.runtime.abort(sessionID: id)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/fork") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.fork(sessionID: id), status: .created)
            }
        }

        router.get("/session/:id/events") { _, context in
            let id = try context.parameters.require("id")
            let sink = try await self.mapErrors { try await self.runtime.sink(for: id) }
            return self.eventStream(sessionID: id, sink: sink)
        }

        return router
    }

    // MARK: SSE

    /// The `text/event-stream` response for a session: an opening `connected`
    /// frame, then every run event, with a periodic heartbeat so an idle-but-live
    /// stream is not torn down between turns.
    private func eventStream(sessionID: String, sink: BroadcastEventSink) -> Response {
        let subscription = sink.subscribe()
        let heartbeatSeconds = options.heartbeatSeconds
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"

        let body = ResponseBody { writer in
            // One ordered stream of run events plus heartbeats. Two producers feed
            // it: the subscription forwarder and the heartbeat ticker. The consumer
            // is this single writer loop, so there is no contention on the writer.
            //
            // Bounded (drop-oldest): a client that stops reading the socket suspends
            // `writer.write`, but the forwarder keeps draining the per-subscriber
            // stream into here — so this hop must carry the same cap, or the memory
            // bound BroadcastEventSink promises would be defeated by this buffer.
            let (merged, continuation) = AsyncStream<ServerEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(512)
            )
            let forward = Task {
                for await event in subscription.events { continuation.yield(event) }
                continuation.finish()
            }
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(heartbeatSeconds))
                    continuation.yield(.heartbeat)
                }
            }
            defer {
                sink.unsubscribe(subscription.id)
                forward.cancel()
                heartbeat.cancel()
            }
            try await writer.write(Self.frame(.connected(protocolVersion: serverProtocolVersion, sessionID: sessionID)))
            for await event in merged {
                try await writer.write(Self.frame(event))
            }
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    /// One SSE frame: `data: <json>\n\n`.
    private static func frame(_ event: ServerEvent) throws -> ByteBuffer {
        let json = try JSONEncoder().encode(event)
        var buffer = ByteBuffer()
        buffer.writeString("data: ")
        buffer.writeBytes(json)
        buffer.writeString("\n\n")
        return buffer
    }

    // MARK: Helpers

    /// Maps a ``ServerRuntimeError`` onto the status a client expects; anything
    /// else propagates for Hummingbird's default handling.
    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ServerRuntimeError {
            switch error {
            case .sessionNotFound: throw HTTPError(.notFound)
            case .sessionBusy: throw HTTPError(.conflict)
            }
        }
    }

    private static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func requiredBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T {
        var request = request
        let buffer = try await request.collectBody(upTo: 4 << 20)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    }

    private static func optionalBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        var request = request
        let buffer = try await request.collectBody(upTo: 4 << 20)
        guard buffer.readableBytes > 0 else { return nil }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    }
}
