// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The write+read transport to a `domo serve` runtime. Thin on purpose: it speaks
// the DoMoServer wire — the REST endpoints for control and history, and the SSE
// stream for live events — and hands decoded values back. Everything above it
// (the event store, the two-pane UI) is transport-agnostic.
//
// The request shape mirrors the server's own end-to-end test verbatim: a
// `Bearer` header on every call, `[UInt8]` bodies (AsyncHTTPClient does not
// re-export `ByteBuffer` by name), and SSE frames split on the blank line with
// the `data: ` prefix stripped before decoding a `ServerEvent`.

import AsyncHTTPClient
import DoMoHarness
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Foundation

// MARK: - Errors

public enum ServerClientError: Error, Sendable, Equatable {
    /// A response arrived with a status the endpoint's contract does not use.
    case unexpectedStatus(UInt, path: String)
}

// MARK: - Client

/// A client for one `domo serve` runtime, identified by its base URL and bearer
/// token. `Sendable` — it holds only value config and a shared ``HTTPClient`` the
/// caller owns and shuts down.
public struct ServerClient: Sendable {
    public let baseURL: String
    private let token: String
    private let http: HTTPClient

    /// - Parameters:
    ///   - baseURL: e.g. `http://127.0.0.1:4100` (no trailing slash).
    ///   - token: the bearer token the server minted (its stderr `Authorization:` line).
    ///   - http: a shared client; the caller owns its lifecycle (`shutdown()`).
    public init(baseURL: String, token: String, http: HTTPClient) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
    }

    // MARK: Request bodies (the server decodes these shapes; kept local since the
    // server's own body types are internal to DoMoServer).

    private struct CreateBody: Encodable { let resume: String? }
    private struct PromptBody: Encodable { let prompt: String; let images: [ImageBlock]? }
    private struct PermissionReplyBody: Encodable { let requestID: String; let reply: String; let message: String? }

    private enum Method: String { case get = "GET", post = "POST" }

    // MARK: REST

    /// Create a session. `resume` names an existing session *id* to reopen (a fresh
    /// session when nil). `POST /session` → 201 → ``SessionRef``.
    public func createSession(resume: String? = nil) async throws -> SessionRef {
        let body = resume.map { try? JSONEncoder().encode(CreateBody(resume: $0)) } ?? nil
        let (status, data) = try await send(.post, "/session", body: body ?? nil)
        try expect(status, 201, "/session")
        return try JSONDecoder().decode(SessionRef.self, from: data)
    }

    /// List every known session for the sidebar. `GET /sessions` → 200.
    public func listSessions() async throws -> [SessionSummary] {
        let (status, data) = try await send(.get, "/sessions")
        try expect(status, 200, "/sessions")
        return try JSONDecoder().decode([SessionSummary].self, from: data)
    }

    /// The linear root-to-leaf transcript to seed the main pane. `GET
    /// /session/{id}/messages` → 200.
    public func messages(sessionID: String) async throws -> [Message] {
        let path = "/session/\(sessionID)/messages"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path)
        return try JSONDecoder().decode([Message].self, from: data)
    }

    /// The child branches of a node, for tree navigation. `GET
    /// /session/{id}/children[?parent=]` → 200.
    public func children(sessionID: String, parent: String? = nil) async throws -> [SessionTreeEntry] {
        var path = "/session/\(sessionID)/children"
        if let parent { path += "?parent=\(parent)" }
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path)
        return try JSONDecoder().decode([SessionTreeEntry].self, from: data)
    }

    /// Submit a prompt. Fire-and-forget: the run streams over the event channel.
    /// `POST /session/{id}/prompt` → 202.
    public func sendPrompt(sessionID: String, prompt: String, images: [ImageBlock] = []) async throws {
        let path = "/session/\(sessionID)/prompt"
        let body = try JSONEncoder().encode(PromptBody(prompt: prompt, images: images.isEmpty ? nil : images))
        let (status, _) = try await send(.post, path, body: body)
        try expect(status, 202, path)
    }

    /// Abort the running turn. `POST /session/{id}/abort` → 200. Cooperative —
    /// the runtime cancels the run task.
    public func abort(sessionID: String) async throws {
        let path = "/session/\(sessionID)/abort"
        let (status, _) = try await send(.post, path)
        try expect(status, 200, path)
    }

    /// Fork the session into a new branch/file. `POST /session/{id}/fork` → 201.
    public func fork(sessionID: String) async throws -> SessionRef {
        let path = "/session/\(sessionID)/fork"
        let (status, data) = try await send(.post, path)
        try expect(status, 201, path)
        return try JSONDecoder().decode(SessionRef.self, from: data)
    }

    /// Answer a pending permission prompt the server asked over SSE. `POST
    /// /session/{id}/permission` → 200. The reply serializes to "once"/"always"/
    /// "reject" plus, on reject, the optional model-visible correction message.
    public func resolvePermission(sessionID: String, requestID: String, reply: PermissionReply) async throws {
        let path = "/session/\(sessionID)/permission"
        let replyString: String
        let message: String?
        switch reply {
        case .once: replyString = "once"; message = nil
        case .always: replyString = "always"; message = nil
        case .reject(let text): replyString = "reject"; message = text
        }
        let body = try JSONEncoder().encode(PermissionReplyBody(requestID: requestID, reply: replyString, message: message))
        let (status, _) = try await send(.post, path, body: body)
        try expect(status, 200, path)
    }

    /// The still-open permission prompts for a session, so a (re)connecting client
    /// reconciles one it missed on the SSE stream. `GET /session/{id}/permissions` →
    /// 200. Each is a `ServerEvent.permissionRequest`.
    public func pendingPermissions(sessionID: String) async throws -> [ServerEvent] {
        let path = "/session/\(sessionID)/permissions"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path)
        return try JSONDecoder().decode([ServerEvent].self, from: data)
    }

    // MARK: SSE

    /// The live event stream for a session, decoded to ``ServerEvent``s.
    ///
    /// Long-lived: the per-session hub broadcasts every turn's events until the
    /// stream is torn down, so a client opens this once for the selected session
    /// and reads continuously (heartbeats included — the consumer ignores them).
    /// Cancelling the consuming task cancels the underlying request.
    public func events(sessionID: String) -> AsyncThrowingStream<ServerEvent, Error> {
        let baseURL = baseURL
        let token = token
        let http = http
        let path = "/session/\(sessionID)/events"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = HTTPClientRequest(url: baseURL + path)
                    request.method = .GET
                    request.headers.add(name: "authorization", value: "Bearer \(token)")
                    // A long deadline for a long-lived stream; heartbeats keep it
                    // active, and the consumer cancels on teardown / session switch.
                    let response = try await http.execute(request, timeout: .hours(24))
                    guard response.status.code == 200 else {
                        throw ServerClientError.unexpectedStatus(response.status.code, path: path)
                    }
                    var decoder = SSEFrameDecoder()
                    for try await chunk in response.body {
                        var chunk = chunk
                        let bytes = chunk.readBytes(length: chunk.readableBytes) ?? []
                        for event in decoder.push(bytes) { continuation.yield(event) }
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode one SSE frame's raw bytes (`data: <json>`), or nil for a
    /// comment/blank/non-`data:` line.
    ///
    /// Takes bytes rather than a `String` so a frame is only ever decoded once it
    /// is COMPLETE: decoding each transport chunk to a `String` first (as the naive
    /// version did) replaces any multibyte UTF-8 character split across a chunk
    /// boundary with U+FFFD, silently corrupting emoji/CJK/accented assistant text.
    static func parseFrame(_ frame: [UInt8]) -> ServerEvent? {
        let prefix = Array("data: ".utf8)
        guard frame.count >= prefix.count, Array(frame.prefix(prefix.count)) == prefix else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.dropFirst(prefix.count)))
    }

    // MARK: Plumbing

    private func send(_ method: Method, _ path: String, body: Data? = nil) async throws -> (status: UInt, body: Data) {
        var request = HTTPClientRequest(url: baseURL + path)
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(token)")
        if let body {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(body))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 4 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return (response.status.code, Data(bytes))
    }

    private func expect(_ status: UInt, _ wanted: UInt, _ path: String) throws {
        guard status == wanted else { throw ServerClientError.unexpectedStatus(status, path: path) }
    }
}

// MARK: - SSE frame decoder

/// Reassembles the server's `data: <json>\n\n` frames from arbitrary transport
/// chunks. Accumulates raw bytes and splits on the blank-line separator, so a
/// frame — and any multibyte character inside it — is decoded only once whole,
/// regardless of where the network chopped the stream.
struct SSEFrameDecoder {
    private var pending: [UInt8] = []

    /// Append a chunk's bytes and return every newly-complete event.
    mutating func push(_ bytes: [UInt8]) -> [ServerEvent] {
        pending.append(contentsOf: bytes)
        var events: [ServerEvent] = []
        while let separator = Self.separatorIndex(in: pending) {
            let frame = Array(pending[..<separator])
            pending.removeSubrange(..<(separator + 2))   // drop the frame and its "\n\n"
            if let event = ServerClient.parseFrame(frame) { events.append(event) }
        }
        return events
    }

    /// The index of the first `\n\n` (start of the two newlines), or nil.
    static func separatorIndex(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var index = 0
        while index < bytes.count - 1 {
            if bytes[index] == 0x0a, bytes[index + 1] == 0x0a { return index }
            index += 1
        }
        return nil
    }
}
