// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The write+read transport to a `domo --serve` runtime. Thin on purpose: it speaks
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
import DoMoGit
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Foundation
import Synchronization

// MARK: - Errors

public enum ServerClientError: Error, Sendable, Equatable {
    /// A response arrived with a status the endpoint's contract does not use.
    ///
    /// `body` is the readable head of what the server said about it (a couple
    /// of KiB — enough for a proxy's explanation, bounded because it ends up in
    /// a transcript), or `nil` when there was nothing to read. Without it a 500
    /// is indistinguishable from a 502 that carried a real explanation, and the
    /// user is told only that a number happened.
    case unexpectedStatus(UInt, path: String, body: String?)

    /// A REST call whose body never completed within the request timeout.
    ///
    /// `HTTPClient.execute(_:timeout:)`'s deadline covers only time-to-response-
    /// HEAD — the deadline task is cancelled the instant the head lands — so the
    /// `collect(upTo:)` that follows it is unbounded. A proxy that answers with
    /// headers and then stalls therefore hangs `abort`, `sendPrompt` and every
    /// other control call forever, which is precisely the case where the user's
    /// last escape hatch silently does nothing.
    case timedOut(path: String)

    /// An SSE stream that delivered nothing — not even a heartbeat — for the
    /// stream idle timeout. A half-open socket throws nothing on its own: the
    /// read simply never returns, which is exactly the wedged-session symptom.
    case streamIdle(path: String)
}

// MARK: - Idle watchdog state

/// The instant an SSE stream last showed a sign of life, shared between the task
/// reading the socket and the task watching for silence.
///
/// A reference box around a `Mutex` rather than a bare `Mutex`, because a `Mutex`
/// is non-copyable and therefore cannot be captured by two sibling child tasks;
/// and a lock rather than an actor, because the watchdog's whole job is to answer
/// while something else is stuck — queueing it behind the reader's isolation
/// would be a watchdog that hangs exactly when it is needed.
private final class ActivityStamp: Sendable {
    private let instant: Mutex<ContinuousClock.Instant>

    init(_ now: ContinuousClock.Instant) { instant = Mutex(now) }

    func touch(_ now: ContinuousClock.Instant) { instant.withLock { $0 = now } }

    func silence(at now: ContinuousClock.Instant) -> Duration { now - instant.withLock { $0 } }
}

// MARK: - Client

/// A client for one `domo --serve` runtime, identified by its base URL and bearer
/// token. `Sendable` — it holds only value config and a shared ``HTTPClient`` the
/// caller owns and shuts down.
public struct ServerClient: Sendable {
    public let baseURL: String
    private let token: String
    private let http: HTTPClient
    private let streamIdleTimeout: Duration
    private let requestTimeout: Duration

    /// How long an SSE stream may deliver NOTHING — not even a heartbeat — before
    /// it is declared dead.
    ///
    /// 2.5× the server's 15 s heartbeat (`DoMoServer.Options.heartbeatSeconds`),
    /// so an ordinary scheduling hiccup cannot trip it but a socket that has gone
    /// half-open cannot hide behind it either. This is the only thing that turns a
    /// dead-but-not-closed connection into an error: the read never returns, so
    /// nothing else in the stack ever notices.
    public static let streamIdleTimeout: Duration = .seconds(40)

    /// The deadline on a REST call, covering the body as well as the head.
    public static let requestTimeout: Duration = .seconds(30)

    /// - Parameters:
    ///   - baseURL: e.g. `http://127.0.0.1:4100` (no trailing slash).
    ///   - token: the bearer token the server minted (its stderr `Authorization:` line).
    ///   - http: a shared client; the caller owns its lifecycle (`shutdown()`).
    ///   - streamIdleTimeout: the SSE silence watchdog; injectable so a test can
    ///     assert the watchdog in a fraction of a second rather than in forty.
    ///   - requestTimeout: the REST deadline, head AND body.
    public init(
        baseURL: String,
        token: String,
        http: HTTPClient,
        streamIdleTimeout: Duration = ServerClient.streamIdleTimeout,
        requestTimeout: Duration = ServerClient.requestTimeout
    ) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
        self.streamIdleTimeout = streamIdleTimeout
        self.requestTimeout = requestTimeout
    }

    // MARK: Request bodies (the server decodes these shapes; kept local since the
    // server's own body types are internal to DoMoServer).

    private struct CreateBody: Encodable { let resume: String? }
    private struct PromptBody: Encodable { let prompt: String; let images: [ImageBlock]? }
    private struct PermissionReplyBody: Encodable { let requestID: String; let reply: String; let message: String? }
    private struct QuestionReplyBody: Encodable { let requestID: String; let answers: [ServerQuestionAnswer]? }
    private struct ModelBody: Encodable { let modelID: String }
    private struct RenameBody: Encodable { let name: String? }
    private struct LabelBody: Encodable { let targetID: String; let label: String? }
    private struct LeafBody: Encodable { let targetID: String? }
    private struct DiffRevertBody: Encodable { let path: String; let base: String? }

    private enum Method: String { case get = "GET", post = "POST" }

    // MARK: REST

    /// Create a session. `resume` names an existing session *id* to reopen (a fresh
    /// session when nil). `POST /session` → 201 → ``SessionRef``.
    public func createSession(resume: String? = nil) async throws -> SessionRef {
        // `try`, not `try?`. A failed encode used to degrade a RESUME silently
        // into a NEW-session create: the caller asked to reopen a session and got
        // an empty one, with the same 201 and the same shape, and nothing said so.
        let body = try resume.map { try JSONEncoder().encode(CreateBody(resume: $0)) }
        let (status, data) = try await send(.post, "/session", body: body)
        try expect(status, 201, "/session", body: data)
        return try JSONDecoder().decode(SessionRef.self, from: data)
    }

    /// List every known session for the sidebar. `GET /sessions` → 200.
    public func listSessions() async throws -> [SessionSummary] {
        let (status, data) = try await send(.get, "/sessions")
        try expect(status, 200, "/sessions", body: data)
        return try JSONDecoder().decode([SessionSummary].self, from: data)
    }

    /// Fetch the runtime's command descriptors. Templates are not included in
    /// this response; the server expands prompt commands so a remote client never
    /// has to mirror project files or trust a local shell.
    public func commands() async throws -> CommandRegistry {
        let path = "/commands"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(CommandRegistry.self, from: data)
    }

    /// Fetch aliases available to the runtime's model picker.
    public func models() async throws -> [ModelOption] {
        let path = "/models"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([ModelOption].self, from: data)
    }

    /// The linear root-to-leaf transcript to seed the main pane. `GET
    /// /session/{id}/messages` → 200.
    public func messages(sessionID: String) async throws -> [Message] {
        let path = "/session/\(sessionID)/messages"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([Message].self, from: data)
    }

    /// Fetch the exact projected context the next model request would use. `GET
    /// /session/{id}/context` → 200. This is intentionally not the same as
    /// ``messages(sessionID:)``: the latter is the lossless transcript, while this
    /// response includes compaction and bounded tool-output projection.
    public func context(sessionID: String) async throws -> ContextSnapshot {
        let path = "/session/\(sessionID)/context"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(ContextSnapshot.self, from: data)
    }

    /// Fetch the current working-tree diff from the session's start checkpoint.
    /// Pass base to review an explicit revision instead.
    public func diff(sessionID: String, base: String? = nil) async throws -> GitDiff {
        var path = "/session/\(sessionID)/diff"
        if let base {
            path += "?base=\(Self.percentEncode(base))"
        }
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(GitDiff.self, from: data)
    }

    public func restoreDiffFile(sessionID: String, path: String, base: String? = nil) async throws {
        let route = "/session/\(sessionID)/diff/revert"
        let body = try JSONEncoder().encode(DiffRevertBody(path: path, base: base))
        let (status, data) = try await send(.post, route, body: body)
        try expect(status, 200, route, body: data)
    }

    public func commitMessage(sessionID: String) async throws -> String? {
        let path = "/session/\(sessionID)/diff/commit-message"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(CommitMessageResult.self, from: data).message
    }

    /// Force one compaction checkpoint. `POST /session/{id}/compact` → 200.
    /// The server returns `compacted: false` when the branch has no complete older
    /// history that can be summarized.
    @discardableResult
    public func compact(sessionID: String) async throws -> Bool {
        let path = "/session/\(sessionID)/compact"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(CompactionResult.self, from: data).compacted
    }

    /// The child branches of a node, for tree navigation. `GET
    /// /session/{id}/children[?parent=]` → 200.
    public func children(sessionID: String, parent: String? = nil) async throws -> [SessionTreeEntry] {
        var path = "/session/\(sessionID)/children"
        if let parent { path += "?parent=\(parent)" }
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([SessionTreeEntry].self, from: data)
    }

    /// Fetch the complete session tree for the `/tree` picker.
    public func tree(sessionID: String) async throws -> [SessionTreeEntry] {
        let path = "/session/\(sessionID)/tree"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([SessionTreeEntry].self, from: data)
    }

    /// Fetch the append-only timeline, including workspace checkpoints and
    /// undo/redo actions.
    public func timeline(sessionID: String) async throws -> [SessionTreeEntry] {
        let path = "/session/\(sessionID)/timeline"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([SessionTreeEntry].self, from: data)
    }

    /// Fetch the truthful workspace snapshot state.
    public func workspaceStatus(sessionID: String) async throws -> WorkspaceSnapshotStatus {
        let path = "/session/\(sessionID)/workspace-status"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(WorkspaceSnapshotStatus.self, from: data)
    }

    /// Undo conversation and workspace history together.
    public func undo(sessionID: String) async throws -> WorkspaceHistoryResult {
        let path = "/session/\(sessionID)/undo"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(WorkspaceHistoryResult.self, from: data)
    }

    /// Redo the most recent undo.
    public func redo(sessionID: String) async throws -> WorkspaceHistoryResult {
        let path = "/session/\(sessionID)/redo"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(WorkspaceHistoryResult.self, from: data)
    }

    public func changeModel(sessionID: String, modelID: String) async throws {
        let path = "/session/\(sessionID)/model"
        let body = try JSONEncoder().encode(ModelBody(modelID: modelID))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    public func renameSession(sessionID: String, name: String?) async throws {
        let path = "/session/\(sessionID)/rename"
        let body = try JSONEncoder().encode(RenameBody(name: name))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    /// Ask the active model for a short title when the session is unnamed.
    public func autoTitle(sessionID: String) async throws -> String? {
        let path = "/session/\(sessionID)/title"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(SessionTitleResult.self, from: data).title
    }

    public func label(sessionID: String, targetID: String, label: String?) async throws {
        let path = "/session/\(sessionID)/label"
        let body = try JSONEncoder().encode(LabelBody(targetID: targetID, label: label))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    public func moveLeaf(sessionID: String, targetID: String?) async throws {
        let path = "/session/\(sessionID)/leaf"
        let body = try JSONEncoder().encode(LeafBody(targetID: targetID))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    /// Submit a prompt. Fire-and-forget: the run streams over the event channel.
    /// `POST /session/{id}/prompt` → 202.
    public func sendPrompt(sessionID: String, prompt: String, images: [ImageBlock] = []) async throws {
        let path = "/session/\(sessionID)/prompt"
        let body = try JSONEncoder().encode(PromptBody(prompt: prompt, images: images.isEmpty ? nil : images))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 202, path, body: data)
    }

    /// Queue a prompt for the active run. `POST /session/{id}/steer` → 202.
    /// The accepted count arrives asynchronously as a `queue_update` SSE frame.
    public func sendSteer(sessionID: String, prompt: String, images: [ImageBlock] = []) async throws {
        let path = "/session/\(sessionID)/steer"
        let body = try JSONEncoder().encode(PromptBody(prompt: prompt, images: images.isEmpty ? nil : images))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 202, path, body: data)
    }

    /// Submit a prompt using the client's best current run-state knowledge. The
    /// opposite route is retried once on a 409 because the run can settle between
    /// reading local state and the HTTP request.
    public func sendPromptOrSteer(
        sessionID: String,
        prompt: String,
        images: [ImageBlock] = [],
        preferSteer: Bool
    ) async throws {
        if preferSteer {
            do {
                try await sendSteer(sessionID: sessionID, prompt: prompt, images: images)
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                try await sendPrompt(sessionID: sessionID, prompt: prompt, images: images)
            }
        } else {
            do {
                try await sendPrompt(sessionID: sessionID, prompt: prompt, images: images)
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                try await sendSteer(sessionID: sessionID, prompt: prompt, images: images)
            }
        }
    }

    /// Abort the running turn. `POST /session/{id}/abort` → 200. Cooperative —
    /// the runtime cancels the run task.
    ///
    /// - Returns: whether a run was actually in flight. `false` means there was
    ///   nothing to abort, which tells the caller its own run state is stale. An
    ///   older server that answers with no body reads as `true`, preserving the
    ///   previous fire-and-forget behaviour.
    @discardableResult
    public func abort(sessionID: String) async throws -> Bool {
        let path = "/session/\(sessionID)/abort"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        guard let result = try? JSONDecoder().decode(AbortResult.self, from: data) else { return true }
        return result.aborted
    }

    /// Fork the session into a new branch/file. `POST /session/{id}/fork` → 201.
    public func fork(sessionID: String) async throws -> SessionRef {
        let path = "/session/\(sessionID)/fork"
        let (status, data) = try await send(.post, path)
        try expect(status, 201, path, body: data)
        return try JSONDecoder().decode(SessionRef.self, from: data)
    }

    /// Clone the session into an independent file. `POST /session/{id}/clone` → 201.
    public func clone(sessionID: String) async throws -> SessionRef {
        let path = "/session/\(sessionID)/clone"
        let (status, data) = try await send(.post, path)
        try expect(status, 201, path, body: data)
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
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    /// The still-open permission prompts for a session, so a (re)connecting client
    /// reconciles one it missed on the SSE stream. `GET /session/{id}/permissions` →
    /// 200. Each is a `ServerEvent.permissionRequest`.
    public func pendingPermissions(sessionID: String) async throws -> [ServerEvent] {
        let path = "/session/\(sessionID)/permissions"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([ServerEvent].self, from: data)
    }

    /// Answer or cancel a structured question raised by the server-side
    /// `question` tool. `POST /session/{id}/question` → 200.
    public func resolveQuestion(
        sessionID: String,
        requestID: String,
        answers: [ServerQuestionAnswer]?
    ) async throws {
        let path = "/session/\(sessionID)/question"
        let body = try JSONEncoder().encode(QuestionReplyBody(requestID: requestID, answers: answers))
        let (status, data) = try await send(.post, path, body: body)
        try expect(status, 200, path, body: data)
    }

    /// The still-open structured questions for a session. `GET
    /// /session/{id}/questions` → 200.
    public func pendingQuestions(sessionID: String) async throws -> [ServerEvent] {
        let path = "/session/\(sessionID)/questions"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode([ServerEvent].self, from: data)
    }

    /// The server's authoritative view of a session. `GET /session/{id}/status` → 200.
    ///
    /// The level-triggered answer to an edge-triggered problem. Every other way the
    /// client learns run state is an edge it can miss — a frame dropped by the
    /// bounded broadcast buffer, a socket that went half-open, a run that never got
    /// to emit its close — and once it has missed one, nothing short of a reconnect
    /// ever corrects it. This can be asked at any time.
    ///
    /// **Degradation is the caller's job, deliberately.** A 404 here means either
    /// "no such session" or "this server predates the route", and the two are not
    /// distinguishable from the status line — Hummingbird answers an unrouted path
    /// and an unknown session with the same number. Swallowing it inside would
    /// therefore have to invent a `SessionStatus` for a session that may genuinely
    /// be gone, which is the same class of lie this endpoint exists to end. The
    /// poll uses `try?` and simply does not adopt; the diagnostics panel renders
    /// "unavailable". The precedent at ``abort(sessionID:)`` is about tolerating a
    /// missing *body*, not a missing route.
    public func status(sessionID: String) async throws -> SessionStatus {
        let path = "/session/\(sessionID)/status"
        let (status, data) = try await send(.get, path)
        try expect(status, 200, path, body: data)
        return try JSONDecoder().decode(SessionStatus.self, from: data)
    }

    /// Free a run slot whose task can never complete. `POST /session/{id}/force-clear`
    /// → 200. Destructive: the server walks away from the run and re-opens the
    /// session from disk, so anything the wedged turn produced but did not persist
    /// is lost.
    ///
    /// - Returns: whether anything was actually holding the session. `false` means
    ///   the lever was pulled on a session that was already free.
    @discardableResult
    public func forceClearRun(sessionID: String) async throws -> Bool {
        let path = "/session/\(sessionID)/force-clear"
        let (status, data) = try await send(.post, path)
        try expect(status, 200, path, body: data)
        // An older server that answers 200 with no body reads as "something was
        // cleared", matching `abort`'s tolerance for exactly the same shape.
        guard let result = try? JSONDecoder().decode(ForceClearResult.self, from: data) else { return true }
        return result.cleared
    }

    // MARK: SSE

    /// The live event stream for a session, decoded to ``ServerEvent``s.
    ///
    /// Long-lived: the per-session hub broadcasts every turn's events until the
    /// stream is torn down, so a client opens this once for the selected session
    /// and reads continuously (heartbeats included — the consumer ignores them).
    /// Cancelling the consuming task cancels the underlying request.
    ///
    /// **Guarded against silence.** The request's own `timeout:` bounds only the
    /// time to the response HEAD, and the client is built with no read timeout, so
    /// a socket that dies without closing — a laptop that slept, a NAT table that
    /// forgot the flow, a proxy that went away — delivers nothing and throws
    /// nothing. Nothing downstream can tell that apart from a quiet session: the
    /// consumer's `catch` never runs, the reconnect never happens, and the
    /// `connected` reconcile that recovers a missed permission prompt is never
    /// re-run. So the watchdog lives HERE rather than in the consumer: it makes the
    /// stream simply THROW, and the existing reconnect/re-seed/re-reconcile path is
    /// reused unchanged with no new state anywhere above.
    public func events(sessionID: String) -> AsyncThrowingStream<ServerEvent, Error> {
        let baseURL = baseURL
        let token = token
        let http = http
        let idle = streamIdleTimeout
        let path = "/session/\(sessionID)/events"
        return AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                // Shared between the reader and the watchdog. A `Mutex` rather than
                // an actor because the watchdog reads it once a second and must not
                // be able to queue behind the reader's own hop.
                let lastActivityAt = ActivityStamp(clock.now)
                // The reader and watchdog are independent pumps. Coordinate their
                // first completion with an AsyncStream instead of a task group: this
                // stream is commonly cancelled while the HTTP response is unwinding,
                // which is the optimized-runtime stack boundary that used to abort
                // the full-screen client.
                let (completions, completionContinuation) = AsyncStream.makeStream(of: Void.self)
                let readerTask = Task {
                    defer { completionContinuation.yield(()) }
                    do {
                        var request = HTTPClientRequest(url: baseURL + path)
                        request.method = .GET
                        request.headers.add(name: "authorization", value: "Bearer \(token)")
                        // A long deadline for a long-lived stream; heartbeats keep it
                        // active, and the consumer cancels on teardown / session switch.
                        let response = try await http.execute(request, timeout: .hours(24))
                        // The head arriving is activity: a slow connect must not
                        // be charged against the idle budget. Stamped BEFORE the
                        // status check, so the error-body read below is itself
                        // covered by the watchdog rather than being a second
                        // unbounded read on the failure path.
                        lastActivityAt.touch(clock.now)
                        guard response.status.code == 200 else {
                            // Carry what the server said. This throw site used to
                            // pass `body: nil`, so the ONE place the client tells
                            // the user why the stream is down — the status line's
                            // disconnect reason — could only ever say a number.
                            // A reverse proxy in front of the runtime is exactly
                            // the thing that answers 503 with a sentence.
                            throw ServerClientError.unexpectedStatus(
                                response.status.code,
                                path: path,
                                body: await Self.readErrorBody(response.body)
                            )
                        }
                        var decoder = SSEFrameDecoder()
                        for try await chunk in response.body {
                            lastActivityAt.touch(clock.now)
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
                let watchdogTask = Task {
                    defer { completionContinuation.yield(()) }
                    // Poll rather than schedule a one-shot: every chunk would
                    // otherwise have to cancel and re-arm a timer, on a path that
                    // runs for every delta of every turn.
                    let tick = min(idle, .seconds(1))
                    while !Task.isCancelled {
                        try? await Task.sleep(for: tick)
                        if Task.isCancelled { return }
                        if lastActivityAt.silence(at: clock.now) >= idle {
                            continuation.finish(throwing: ServerClientError.streamIdle(path: path))
                            return
                        }
                    }
                }

                await withTaskCancellationHandler(operation: {
                    var iterator = completions.makeAsyncIterator()
                    _ = await iterator.next()
                }, onCancel: {
                    readerTask.cancel()
                    watchdogTask.cancel()
                    completionContinuation.finish()
                })
                // Whichever finishes first ends the stream. Explicitly retire the
                // other task, but do not await canceled task values here: on Linux,
                // an async-http-client body reader can be parked on its connection
                // until the owning HTTPClient shuts down. The caller performs that
                // shutdown immediately after its canceled client task returns.
                readerTask.cancel()
                watchdogTask.cancel()
                completionContinuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The readable head of a failed SSE response's body, or nil when it had none
    /// (or would not produce one). Never throws: a missing explanation must not
    /// replace the status code the caller already has.
    private static func readErrorBody(_ body: HTTPClientResponse.Body) async -> String? {
        guard var buffer = try? await body.collect(upTo: errorBodyCharacterCap * 4) else { return nil }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return errorBody(Data(bytes))
    }

    /// Decode one SSE frame's raw bytes (`data: <json>`), or nil for a
    /// comment/blank/non-`data:` line.
    ///
    /// Takes bytes rather than a `String` so a frame is only ever decoded once it
    /// is COMPLETE: decoding each transport chunk to a `String` first (as the naive
    /// version did) replaces any multibyte UTF-8 character split across a chunk
    /// boundary with U+FFFD, silently corrupting emoji/CJK/accented assistant text.
    ///
    /// The `try?` is the FORWARD-COMPATIBILITY DOOR and must stay. A frame whose
    /// `type` this build does not know decodes to `nil` and is dropped, so a
    /// client older than the server it is attached to loses only the frames it
    /// could not have rendered anyway — it does not tear the stream down. That
    /// is why `serverProtocolVersion` need not move for an additive frame; see
    /// its doc comment in `DoMoServer/ServerEvent.swift`.
    static func parseFrame(_ frame: [UInt8]) -> ServerEvent? {
        let prefix = Array("data: ".utf8)
        guard frame.count >= prefix.count, Array(frame.prefix(prefix.count)) == prefix else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: Data(frame.dropFirst(prefix.count)))
    }

    // MARK: Plumbing

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func send(_ method: Method, _ path: String, body: Data? = nil) async throws -> (status: UInt, body: Data) {
        var request = HTTPClientRequest(url: baseURL + path)
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(token)")
        if let body {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(body))
        }
        let response = try await http.execute(request, timeout: .nanoseconds(Self.nanoseconds(requestTimeout)))
        return (response.status.code, try await collectWithin(requestTimeout, path: path, response.body))
    }

    /// `Duration` as whole nanoseconds, saturating rather than trapping.
    ///
    /// NIO's `TimeAmount` is an `Int64` nanosecond count and the timeout is
    /// caller-supplied, so a `Duration.seconds(Int.max)` handed in by a test (or a
    /// future config knob) must clamp to "effectively never" instead of killing the
    /// client on an overflow.
    static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        guard components.seconds < Int64.max / 1_000_000_000 else { return .max }
        guard components.seconds > Int64.min / 1_000_000_000 else { return .min }
        let (product, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return components.seconds > 0 ? .max : .min }
        let (sum, sumOverflow) = product.addingReportingOverflow(components.attoseconds / 1_000_000_000)
        return sumOverflow ? (components.seconds > 0 ? .max : .min) : sum
    }

    /// Read a response body under a deadline of our own.
    ///
    /// `execute(_:timeout:)`'s deadline is cancelled the moment the response HEAD
    /// arrives, and the client carries no read timeout, so the `collect` below is
    /// otherwise unbounded: a server that answers with headers and then stalls
    /// hangs the call forever. That is survivable for `messages`; it is not
    /// survivable for `abort`, which is the user's escape hatch from exactly the
    /// kind of stall that produces it.
    private func collectWithin(
        _ timeout: Duration,
        path: String,
        _ body: HTTPClientResponse.Body
    ) async throws -> Data {
        let (results, resultContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let bodyTask = Task {
            do {
                var buffer = try await body.collect(upTo: 4 << 20)
                resultContinuation.yield(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
                resultContinuation.finish()
            } catch {
                resultContinuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            resultContinuation.finish(throwing: ServerClientError.timedOut(path: path))
        }
        defer {
            bodyTask.cancel()
            timeoutTask.cancel()
            resultContinuation.finish()
        }

        return try await withTaskCancellationHandler(operation: {
            for try await data in results { return data }
            throw ServerClientError.timedOut(path: path)
        }, onCancel: {
            bodyTask.cancel()
            timeoutTask.cancel()
            resultContinuation.finish(throwing: CancellationError())
        })
    }

    /// How much of an error body is carried into the thrown error.
    ///
    /// A gateway or a proxy in front of the runtime can answer a 502 with an
    /// entire HTML page; this row ends up in a transcript, so the cap is a
    /// display budget, not a protocol one.
    static let errorBodyCharacterCap = 2048

    /// Assert the status the endpoint's contract promises, carrying what the
    /// server said when it is something else.
    ///
    /// `body` is the response bytes the caller already collected. Passing them
    /// is the whole point: the status number alone tells a user that a number
    /// happened, while the body is the sentence that says which credential was
    /// rejected or which path was not found.
    private func expect(_ status: UInt, _ wanted: UInt, _ path: String, body: Data? = nil) throws {
        guard status != wanted else { return }
        throw ServerClientError.unexpectedStatus(status, path: path, body: Self.errorBody(body))
    }

    /// The readable prefix of an error body, or `nil` when there is nothing to
    /// show. Decoded leniently — an error body is exactly where a server is
    /// least likely to have produced well-formed UTF-8 — and trimmed, so an
    /// empty JSON envelope does not become an empty ": " in the message.
    static func errorBody(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let text = String(decoding: data.prefix(errorBodyCharacterCap * 4), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > errorBodyCharacterCap
            ? String(text.prefix(errorBodyCharacterCap)) + "…"
            : text
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
