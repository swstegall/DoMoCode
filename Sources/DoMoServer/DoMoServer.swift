// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoPermissions
import Foundation
import Hummingbird
import HTTPTypes
import Logging

// MARK: - Request bodies

/// `POST /session` body. Absent (empty body) means a fresh session.
/// The `POST /session/{id}/abort` result: whether a run was actually in flight.
/// A client that gets `false` knows its own run state was stale.
public struct AbortResult: Codable, Sendable, Hashable {
    public var aborted: Bool
    public init(aborted: Bool) { self.aborted = aborted }
}

/// The `POST /session/{id}/force-clear` result: whether anything was actually
/// holding the session's run slot.
///
/// Force-clear is not "abort". It walks away from a run that may never settle and
/// rebuilds the session from its file, so anything the doomed turn produced but
/// did not persist is gone. A UI must label it as freeing the session, not as
/// cancelling, or a user will reach for it as a normal stop.
public struct ForceClearResult: Codable, Sendable, Hashable {
    public var cleared: Bool
    public init(cleared: Bool) { self.cleared = cleared }
}

/// The result of an optional LLM-generated session title. `nil` means the
/// session was empty or already had an explicit name.
public struct SessionTitleResult: Codable, Sendable, Hashable {
    public var title: String?
    public init(title: String?) { self.title = title }
}

/// The result of an optional LLM-generated commit subject.
public struct CommitMessageResult: Codable, Sendable, Hashable {
    public var message: String?
    public init(message: String?) { self.message = message }
}

private struct CreateBody: Decodable {
    var resume: String?
}

/// `POST /session/{id}/prompt` body. `images` reuses ``DoMoLLM/ImageBlock``'s
/// base64 codec, so a client attaches by sending `{mediaType, data}` parts.
private struct PromptBody: Decodable {
    var prompt: String
    var images: [ImageBlock]?
}

/// `POST /session/{id}/permission` body (Phase 8b). `reply` is "once" / "always" /
/// "reject"; `message` is the optional model-visible reason carried only on reject.
private struct PermissionReplyBody: Decodable {
    var requestID: String
    var reply: String
    var message: String?
}

/// `POST /session/{id}/question` body. `answers: nil` means the client
/// cancelled the structured prompt, which the tool turns into a model-visible
/// cancellation error.
private struct QuestionReplyBody: Decodable {
    var requestID: String
    var answers: [ServerQuestionAnswer]?
}

private struct ModelBody: Decodable { var modelID: String }
private struct ModeBody: Decodable { var mode: String }
private struct RenameBody: Decodable { var name: String? }
private struct LabelBody: Decodable { var targetID: String; var label: String? }
private struct LeafBody: Decodable { var targetID: String? }
private struct DiffRevertBody: Decodable { var path: String; var base: String? }
private struct WorkflowStartBody: Decodable {
    var sessionID: String
    var input: JSONValue?
    var runID: String?
}
private struct WorkflowResumeBody: Decodable { var sessionID: String? }
private struct WorkflowApprovalBody: Decodable {
    var stageID: String
    var decision: String
    var reason: String?
}

private struct HandoffDecisionBody: Decodable {
    var owner: String
    var reason: String?
}

private struct HandoffCompleteBody: Decodable {
    var owner: String
    var target: SessionHandoffTarget?
    var metadata: [String: JSONValue]?
}

private struct JobOwnerBody: Decodable {
    var owner: String
}

private struct AutomationOwnerBody: Decodable {
    var owner: String
}

private struct SessionClientAttachmentBody: Decodable {
    var clientID: String
    var owner: String
    var requestAuthority: Bool?
}

private struct SessionClientOwnerBody: Decodable {
    var clientID: String
    var owner: String
}

private struct SessionClientTransferBody: Decodable {
    var fromClientID: String
    var toClientID: String
    var owner: String
}

private struct SessionClientCursorBody: Decodable {
    var clientID: String
    var owner: String
    var sequence: Int
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

        // Session-client presence and authority are explicit durable records.
        // A second client can mirror a session immediately, but it cannot
        // answer a permission prompt or mutate the turn until authority is
        // transferred by the current owner.
        router.post("/session/:id/client/attach") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(SessionClientAttachmentBody.self, request)
                return try Self.json(try await self.runtime.attachClient(
                    sessionID: id,
                    clientID: body.clientID,
                    owner: body.owner,
                    requestAuthority: body.requestAuthority ?? true
                ))
            }
        }

        router.post("/session/:id/client/detach") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(SessionClientOwnerBody.self, request)
                return try Self.json(try await self.runtime.detachClient(
                    sessionID: id,
                    clientID: body.clientID,
                    owner: body.owner
                ))
            }
        }

        router.get("/session/:id/clients") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let includeInactive = request.uri.queryParameters["includeInactive"]
                    .map(String.init)
                    .map { $0.lowercased() == "true" } ?? false
                return try Self.json(try await self.runtime.sessionClients(
                    sessionID: id,
                    includeInactive: includeInactive
                ))
            }
        }

        router.get("/session/:id/client/authority") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard let authority = try await self.runtime.sessionClientAuthority(sessionID: id) else {
                    return try Self.json(Optional<SessionClientAttachment>.none)
                }
                return try Self.json(authority)
            }
        }

        router.post("/session/:id/client/authority/release") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(SessionClientOwnerBody.self, request)
                return try Self.json(try await self.runtime.releaseSessionAuthority(
                    sessionID: id,
                    clientID: body.clientID,
                    owner: body.owner
                ))
            }
        }

        router.post("/session/:id/client/authority/transfer") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(SessionClientTransferBody.self, request)
                return try Self.json(try await self.runtime.transferSessionAuthority(
                    sessionID: id,
                    fromClientID: body.fromClientID,
                    toClientID: body.toClientID,
                    owner: body.owner
                ))
            }
        }

        router.post("/session/:id/client/cursor") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(SessionClientCursorBody.self, request)
                return try Self.json(try await self.runtime.advanceSessionClientCursor(
                    sessionID: id,
                    clientID: body.clientID,
                    owner: body.owner,
                    sequence: body.sequence
                ))
            }
        }

        router.get("/session/:id/client/events") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let rawAfter = request.uri.queryParameters["after"].map(String.init)
                let after: Int
                if let rawAfter {
                    guard let parsed = Int(rawAfter), parsed >= 0 else {
                        throw HTTPError(.badRequest)
                    }
                    after = parsed
                } else {
                    after = 0
                }
                return try Self.json(try await self.runtime.sessionClientEvents(
                    after: after,
                    sessionID: id
                ))
            }
        }

        router.get("/session/:id/client/export") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let clientID = request.uri.queryParameters["clientID"].map(String.init)
                return try Self.json(try await self.runtime.sessionClientExport(
                    sessionID: id,
                    clientID: clientID
                ))
            }
        }

        router.get("/commands") { _, _ in
            try await self.mapErrors {
                try Self.json(await self.runtime.commands())
            }
        }

        router.get("/memory") { _, _ in
            try await self.mapErrors {
                try Self.json(try await self.runtime.memory())
            }
        }

        router.get("/models") { _, _ in
            try await self.mapErrors {
                try Self.json(try await self.runtime.refreshModels())
            }
        }

        // Session handoffs are durable control records. The ledger owns
        // authorization and transitions; these routes only authenticate and
        // project its level-triggered state and resumable cursor.
        router.get("/handoffs") { request, _ in
            try await self.mapErrors {
                let sourceSessionID = request.uri.queryParameters["sourceSession"]
                    .map(String.init)
                return try Self.json(try await self.runtime.handoffs(sourceSessionID: sourceSessionID))
            }
        }

        router.post("/handoff") { request, _ in
            try await self.mapErrors {
                let body = try await Self.requiredBody(SessionHandoffRequest.self, request)
                return try Self.json(try await self.runtime.proposeHandoff(body), status: .created)
            }
        }

        router.get("/handoff/:id") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard let handoff = try await self.runtime.handoff(id: id) else {
                    throw HTTPError(.notFound)
                }
                return try Self.json(handoff)
            }
        }

        router.get("/handoff/:id/events") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let rawAfter = request.uri.queryParameters["after"].map(String.init)
                let after: Int
                if let rawAfter {
                    guard let parsed = Int(rawAfter), parsed >= 0 else {
                        throw HTTPError(.badRequest)
                    }
                    after = parsed
                } else {
                    after = 0
                }
                return try Self.json(try await self.runtime.handoffEvents(after: after, handoffID: id))
            }
        }

        router.get("/handoff/:id/export") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.handoffExport(id: id))
            }
        }

        router.post("/handoff/:id/accept") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(HandoffDecisionBody.self, request)
                return try Self.json(try await self.runtime.acceptHandoff(id: id, owner: body.owner))
            }
        }

        router.post("/handoff/:id/complete") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(HandoffCompleteBody.self, request)
                return try Self.json(try await self.runtime.completeHandoff(
                    id: id,
                    owner: body.owner,
                    target: body.target,
                    metadata: body.metadata ?? [:]
                ))
            }
        }

        router.post("/handoff/:id/reject") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(HandoffDecisionBody.self, request)
                return try Self.json(try await self.runtime.rejectHandoff(
                    id: id,
                    owner: body.owner,
                    reason: body.reason ?? "Handoff rejected."
                ))
            }
        }

        router.post("/handoff/:id/cancel") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(HandoffDecisionBody.self, request)
                return try Self.json(try await self.runtime.cancelHandoff(
                    id: id,
                    owner: body.owner,
                    reason: body.reason ?? "Handoff cancelled."
                ))
            }
        }

        router.get("/jobs") { request, _ in
            try await self.mapErrors {
                let owner = request.uri.queryParameters["owner"].map(String.init)
                return try Self.json(try await self.runtime.jobs(owner: owner))
            }
        }

        router.post("/jobs/recover") { _, _ in
            try await self.mapErrors {
                try Self.json(try await self.runtime.recoverJobs())
            }
        }

        router.get("/job/:id") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard let job = try await self.runtime.job(id: id) else {
                    throw HTTPError(.notFound)
                }
                return try Self.json(job)
            }
        }

        router.get("/job/:id/events") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard try await self.runtime.job(id: id) != nil else {
                    throw HTTPError(.notFound)
                }
                let rawAfter = request.uri.queryParameters["after"].map(String.init)
                let after: Int
                if let rawAfter {
                    guard let parsed = Int(rawAfter), parsed >= 0 else {
                        throw HTTPError(.badRequest)
                    }
                    after = parsed
                } else {
                    after = 0
                }
                return try Self.json(try await self.runtime.jobEvents(after: after, jobID: id))
            }
        }

        router.get("/job/:id/export") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.jobExport(id: id))
            }
        }

        router.post("/job/:id/cancel") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(JobOwnerBody.self, request)
                return try Self.json(try await self.runtime.cancelJob(id: id, owner: body.owner))
            }
        }

        // Automation routes expose policy and audit state only. A trigger
        // adapter must perform its own authenticated admission and then hand a
        // bounded invocation to the job layer; these routes never schedule or
        // launch work on their own.
        router.get("/automations") { request, _ in
            try await self.mapErrors {
                let owner = request.uri.queryParameters["owner"].map(String.init)
                return try Self.json(try await self.runtime.automations(owner: owner))
            }
        }

        router.post("/automation") { request, _ in
            try await self.mapErrors {
                let definition = try await Self.requiredBody(AutomationDefinition.self, request)
                return try Self.json(
                    try await self.runtime.registerAutomation(definition),
                    status: .created
                )
            }
        }

        router.get("/automation/:id") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard let definition = try await self.runtime.automation(id: id) else {
                    throw HTTPError(.notFound)
                }
                return try Self.json(definition)
            }
        }

        router.post("/automation/:id/enable") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(AutomationOwnerBody.self, request)
                return try Self.json(try await self.runtime.setAutomationEnabled(
                    id: id,
                    owner: body.owner,
                    enabled: true
                ))
            }
        }

        router.post("/automation/:id/disable") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(AutomationOwnerBody.self, request)
                return try Self.json(try await self.runtime.setAutomationEnabled(
                    id: id,
                    owner: body.owner,
                    enabled: false
                ))
            }
        }

        router.post("/automation/:id/invoke") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let invocation = try await Self.requiredBody(AutomationInvocation.self, request)
                guard invocation.automationID == id else { throw HTTPError(.badRequest) }
                return try Self.json(try await self.runtime.invokeAutomation(invocation), status: .accepted)
            }
        }

        router.get("/automation/:id/events") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard try await self.runtime.automation(id: id) != nil else {
                    throw HTTPError(.notFound)
                }
                let rawAfter = request.uri.queryParameters["after"].map(String.init)
                let after: Int
                if let rawAfter {
                    guard let parsed = Int(rawAfter), parsed >= 0 else {
                        throw HTTPError(.badRequest)
                    }
                    after = parsed
                } else {
                    after = 0
                }
                return try Self.json(try await self.runtime.automationEvents(
                    after: after,
                    automationID: id
                ))
            }
        }

        router.get("/automation/:id/invocations") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                guard try await self.runtime.automation(id: id) != nil else {
                    throw HTTPError(.notFound)
                }
                return try Self.json(try await self.runtime.automationInvocations(id: id))
            }
        }

        router.get("/automation/:id/export") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.automationExport(id: id))
            }
        }

        // Workflow definitions and run snapshots are read-only projections of
        // the runtime's append-only store. The client polls these level-triggered
        // routes so a dropped event cannot leave a phase pane claiming stale work.
        router.get("/workflows") { _, _ in
            try await self.mapErrors {
                try Self.json(try await self.runtime.workflowDefinitions())
            }
        }

        router.get("/workflow/:id/runs") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.workflowRuns(workflowID: id))
            }
        }

        router.get("/workflow/:id/run/:runID") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                guard let run = try await self.runtime.workflowRun(workflowID: id, runID: runID) else {
                    throw HTTPError(.notFound)
                }
                return try Self.json(run)
            }
        }

        router.get("/workflow/:id/run/:runID/export") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                return try Self.json(try await self.runtime.workflowExport(
                    workflowID: id,
                    runID: runID
                ))
            }
        }

        router.post("/workflow/:id/run") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let body = try await Self.requiredBody(WorkflowStartBody.self, request)
                let run = try await self.runtime.startWorkflow(
                    workflowID: id,
                    sessionID: body.sessionID,
                    input: body.input ?? .null,
                    runID: body.runID
                )
                return try Self.json(run, status: .accepted)
            }
        }

        router.post("/workflow/:id/run/:runID/resume") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                let body = try await Self.optionalBody(WorkflowResumeBody.self, request)
                let run = try await self.runtime.resumeWorkflow(
                    workflowID: id,
                    runID: runID,
                    sessionID: body?.sessionID
                )
                return try Self.json(run, status: .accepted)
            }
        }

        router.post("/workflow/:id/run/:runID/cancel") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                return try Self.json(try await self.runtime.cancelWorkflow(workflowID: id, runID: runID))
            }
        }

        router.post("/workflow/:id/run/:runID/pause") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                return try Self.json(try await self.runtime.pauseWorkflow(workflowID: id, runID: runID))
            }
        }

        router.get("/workflow/:id/run/:runID/approvals") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                return try Self.json(try await self.runtime.workflowApprovals(workflowID: id, runID: runID))
            }
        }

        router.post("/workflow/:id/run/:runID/approval") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let runID = try context.parameters.require("runID")
                let body = try await Self.requiredBody(WorkflowApprovalBody.self, request)
                let decision: WorkflowApprovalDecision
                switch body.decision.lowercased() {
                case "approve", "approved":
                    decision = .approved
                case "cancel", "cancelled":
                    decision = .cancelled
                case "deny", "denied":
                    decision = .denied(body.reason ?? "Workflow stage approval denied.")
                default:
                    throw HTTPError(.badRequest)
                }
                try await self.runtime.resolveWorkflowApproval(
                    workflowID: id,
                    runID: runID,
                    stageID: body.stageID,
                    decision: decision
                )
                return Response(status: .ok)
            }
        }

        router.get("/session/:id/tools") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.toolCatalog(sessionID: id))
            }
        }

        router.get("/session/:id/messages") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.messages(sessionID: id))
            }
        }

        // The model-facing context after compaction, tool-output pruning, and
        // spill-to-disk projection. This is deliberately separate from
        // `/messages`, which remains the lossless transcript for the history pane.
        router.get("/session/:id/context") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.context(sessionID: id))
            }
        }

        router.get("/session/:id/diff") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let base = request.uri.queryParameters["base"].map(String.init)
                return try Self.json(try await self.runtime.diff(sessionID: id, base: base))
            }
        }

        router.post("/session/:id/diff/revert") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(DiffRevertBody.self, request)
                try await self.runtime.restoreDiffFile(sessionID: id, path: body.path, base: body.base)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/diff/commit-message") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let message = try await self.runtime.commitMessage(sessionID: id)
                return try Self.json(CommitMessageResult(message: message), status: .ok)
            }
        }

        // Force one checkpoint even when automatic compaction is disabled. The
        // runtime rejects this with 409 while a turn owns the session.
        router.post("/session/:id/compact") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                return try Self.json(try await self.runtime.compact(sessionID: id), status: .ok)
            }
        }

        router.get("/session/:id/children") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                let parent = request.uri.queryParameters["parent"].map(String.init)
                return try Self.json(try await self.runtime.children(sessionID: id, parent: parent))
            }
        }

        router.get("/session/:id/tree") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.tree(sessionID: id))
            }
        }

        router.get("/session/:id/timeline") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.timeline(sessionID: id))
            }
        }

        router.get("/session/:id/workspace-status") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.workspaceStatus(sessionID: id))
            }
        }

        router.post("/session/:id/undo") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                return try Self.json(try await self.runtime.undo(sessionID: id), status: .ok)
            }
        }

        router.post("/session/:id/redo") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                return try Self.json(try await self.runtime.redo(sessionID: id), status: .ok)
            }
        }

        router.post("/session/:id/model") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(ModelBody.self, request)
                try await self.runtime.changeModel(sessionID: id, modelID: body.modelID)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/mode") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(ModeBody.self, request)
                guard let mode = AgentMode(rawValue: body.mode.lowercased()) else {
                    throw HTTPError(.badRequest)
                }
                try await self.runtime.changeMode(sessionID: id, mode: mode)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/rename") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(RenameBody.self, request)
                try await self.runtime.renameSession(sessionID: id, name: body.name)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/title") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let title = try await self.runtime.autoTitle(sessionID: id)
                return try Self.json(SessionTitleResult(title: title), status: .ok)
            }
        }

        router.post("/session/:id/label") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(LabelBody.self, request)
                try await self.runtime.label(sessionID: id, targetID: body.targetID, label: body.label)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/leaf") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(LeafBody.self, request)
                try await self.runtime.moveLeaf(sessionID: id, targetID: body.targetID)
                return Response(status: .ok)
            }
        }

        router.post("/session/:id/prompt") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                // The ONLY route with the large cap: a prompt carries base64 image
                // attachments, and the 4 MiB default 413s anything over ~3 MiB raw
                // — a dropped screenshot, silently refused.
                let body = try await Self.requiredBody(
                    PromptBody.self, request, upTo: Self.maximumPromptBodyBytes
                )
                try await self.runtime.startRun(sessionID: id, prompt: body.prompt, attachments: body.images ?? [])
                return Response(status: .accepted)
            }
        }

        // Phase 9: a prompt typed while a run is active is queued for its next
        // steering boundary instead of being rejected as a second run.
        router.post("/session/:id/steer") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(
                    PromptBody.self, request, upTo: Self.maximumPromptBodyBytes
                )
                try await self.runtime.steer(sessionID: id, prompt: body.prompt, attachments: body.images ?? [])
                return Response(status: .accepted)
            }
        }

        router.post("/session/:id/abort") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let aborted = try await self.runtime.abort(sessionID: id)
                return try Self.json(AbortResult(aborted: aborted), status: .ok)
            }
        }

        // Phase 8b: answer a pending permission prompt the server asked over SSE.
        router.post("/session/:id/permission") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(PermissionReplyBody.self, request)
                let reply: PermissionReply
                switch body.reply {
                case "once": reply = .once
                case "always": reply = .always
                case "reject": reply = .reject(message: body.message)
                default: throw HTTPError(.badRequest)
                }
                try await self.runtime.resolvePermission(sessionID: id, requestID: body.requestID, reply: reply)
                return Response(status: .ok)
            }
        }

        // The still-open prompts for a session, so a (re)connecting client reconciles
        // a prompt it missed on the drop-oldest SSE stream.
        router.get("/session/:id/permissions") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.pendingPermissions(sessionID: id))
            }
        }

        // Answer a structured question raised by the `question` tool. The
        // continuation stays parked in the runtime until this route resolves it.
        router.post("/session/:id/question") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let body = try await Self.requiredBody(QuestionReplyBody.self, request)
                try await self.runtime.resolveQuestion(
                    sessionID: id,
                    requestID: body.requestID,
                    answers: body.answers
                )
                return Response(status: .ok)
            }
        }

        // The level-triggered companion to the SSE question edge. A reconnecting
        // client uses it to recover an ask that was dropped from the bounded
        // event buffer or arrived while the stream was down.
        router.get("/session/:id/questions") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.pendingQuestions(sessionID: id))
            }
        }

        // The server's authoritative view of a session. A client whose run state is
        // pinned by a missed edge polls this rather than guessing, and reads the
        // session's cumulative accounting off the same payload — the totals cannot
        // be folded from the SSE stream by a client that attached halfway through.
        //
        // This route answers even for a session whose accounting cannot be
        // computed: `ServerRuntime.status(sessionID:)` degrades that to
        // `accounting: nil` rather than throwing, precisely so a damaged session is
        // still diagnosable here. Only an unknown id is an error, and it is a 404.
        router.get("/session/:id/status") { _, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                return try Self.json(try await self.runtime.status(sessionID: id))
            }
        }

        // The escape hatch for a run that can never settle. Destructive by design:
        // see `ForceClearResult`.
        router.post("/session/:id/force-clear") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                let cleared = try await self.runtime.forceClearRun(sessionID: id)
                return try Self.json(ForceClearResult(cleared: cleared), status: .ok)
            }
        }

        router.post("/session/:id/fork") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                return try Self.json(try await self.runtime.fork(sessionID: id), status: .created)
            }
        }

        router.post("/session/:id/clone") { request, context in
            try await self.mapErrors {
                let id = try context.parameters.require("id")
                try await self.authorizeSessionClient(request, sessionID: id)
                return try Self.json(try await self.runtime.clone(sessionID: id), status: .created)
            }
        }

        router.get("/session/:id/events") { request, context in
            let id = try context.parameters.require("id")
            let sink = try await self.mapErrors { try await self.runtime.sink(for: id) }
            let after: Int
            if let rawAfter = request.uri.queryParameters["after"].map(String.init) {
                guard let parsed = Int(rawAfter), parsed >= 0 else {
                    throw HTTPError(.badRequest)
                }
                after = parsed
            } else {
                after = 0
            }
            return self.eventStream(sessionID: id, sink: sink, after: after)
        }

        return router
    }

    // MARK: SSE

    /// The `text/event-stream` response for a session: an opening `connected`
    /// frame, then every run event, with a periodic heartbeat so an idle-but-live
    /// stream is not torn down between turns.
    ///
    /// Internal rather than private so a test can build the response and *never*
    /// consume it — the exact shape of the leak fixed below.
    func eventStream(
        sessionID: String,
        sink: BroadcastEventSink,
        after sequence: Int = 0
    ) -> Response {
        let heartbeatSeconds = options.heartbeatSeconds
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"

        let body = ResponseBody { writer in
            // Subscribe INSIDE the writer closure, so the registration has exactly
            // the same lifetime as the `defer` that tears it down. Subscribing
            // outside leaked a registration and a 512-slot buffer forever for any
            // response whose writer is never invoked — and poisoned
            // `subscriberCount`, which is the natural diagnostic for this whole
            // class of bug.
            let subscription = sink.subscribe(after: sequence)
            // One ordered stream of run events plus heartbeats. Two producers feed
            // it: the subscription forwarder and the heartbeat ticker. The consumer
            // is this single writer loop, so there is no contention on the writer.
            //
            // Bounded (drop-oldest): a client that stops reading the socket suspends
            // `writer.write`, but the forwarder keeps draining the per-subscriber
            // stream into here — so this hop must carry the same cap, or the memory
            // bound BroadcastEventSink promises would be defeated by this buffer.
            let (merged, continuation) = AsyncStream<StreamFrame>.makeStream(
                bufferingPolicy: .bufferingNewest(512)
            )
            let forward = Task {
                for await event in subscription.events { continuation.yield(.event(event)) }
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
            let running = await runtime.isRunning(sessionID: sessionID)
            try await writer.write(Self.frame(
                .connected(protocolVersion: serverProtocolVersion, sessionID: sessionID, running: running)
            ))
            for await frame in merged {
                switch frame {
                case .event(let event):
                    try await writer.write(Self.frame(event))
                case .heartbeat:
                    try await writer.write(Self.frame(.heartbeat))
                }
            }
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    private enum StreamFrame: Sendable {
        case event(SequencedServerEvent)
        case heartbeat
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

    private static func frame(_ event: SequencedServerEvent) throws -> ByteBuffer {
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
            case .terminalNotFound: throw HTTPError(.notFound)
            case .sessionBusy, .sessionNotRunning: throw HTTPError(.conflict)
            case .workflowNotFound, .workflowRunNotFound, .workflowApprovalNotFound:
                throw HTTPError(.notFound)
            case .workflowRunBusy, .workflowRunNotResumable:
                throw HTTPError(.conflict)
            case .workflowSessionRequired:
                throw HTTPError(.badRequest)
            case .handoffUnavailable, .handoffNotFound:
                throw HTTPError(.notFound)
            case .handoffConflict:
                throw HTTPError(.conflict)
            case .handoffDenied:
                throw HTTPError(.forbidden)
            case .handoffInvalid:
                throw HTTPError(.badRequest)
            case .jobUnavailable, .jobNotFound:
                throw HTTPError(.notFound)
            case .jobConflict:
                throw HTTPError(.conflict)
            case .jobDenied:
                throw HTTPError(.forbidden)
            case .jobInvalid:
                throw HTTPError(.badRequest)
            case .automationUnavailable, .automationNotFound:
                throw HTTPError(.notFound)
            case .automationConflict:
                throw HTTPError(.conflict)
            case .automationDenied:
                throw HTTPError(.forbidden)
            case .automationInvalid:
                throw HTTPError(.badRequest)
            case .sessionClientsUnavailable, .sessionClientNotFound:
                throw HTTPError(.notFound)
            case .sessionClientConflict:
                throw HTTPError(.conflict)
            case .sessionClientDenied, .sessionClientAuthorityRequired:
                throw HTTPError(.forbidden)
            case .sessionClientInvalid:
                throw HTTPError(.badRequest)
            }
        }
    }

    /// The bearer token authenticates the process; these headers identify the
    /// particular mirror that is allowed to mutate a session. They are optional
    /// when the runtime has no session-client ledger, preserving older clients.
    private static func clientIdentity(_ request: Request) -> (clientID: String, owner: String)? {
        guard let clientID = request.headers[HTTPField.Name("x-domocode-client-id")!],
              let owner = request.headers[HTTPField.Name("x-domocode-client-owner")!],
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (clientID, owner)
    }

    private func authorizeSessionClient(_ request: Request, sessionID: String) async throws {
        let identity = Self.clientIdentity(request)
        try await runtime.authorizeSessionClient(
            sessionID: sessionID,
            clientID: identity?.clientID,
            owner: identity?.owner
        )
    }

    private static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// The default request-body cap. Generous for a JSON control message and small
    /// enough that a local client cannot make the server buffer arbitrarily.
    public static let defaultBodyBytes = 4 << 20

    /// The prompt route's cap, and only the prompt route's.
    ///
    /// A prompt carries image attachments base64-encoded, which costs ~4/3 of the
    /// raw bytes plus JSON escaping, so the 4 MiB default 413s a screenshot over
    /// roughly 3 MiB. The image loader's own ceiling is 10 MiB total across at most
    /// 8 images (`ImageAttachmentLimits`), so 32 MiB clears the encoded worst case
    /// with headroom and still bounds the buffer.
    public static let maximumPromptBodyBytes = 32 << 20

    private static func requiredBody<T: Decodable>(
        _ type: T.Type,
        _ request: Request,
        upTo limit: Int = DoMoServer.defaultBodyBytes
    ) async throws -> T {
        var request = request
        let buffer = try await request.collectBody(upTo: limit)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    }

    private static func optionalBody<T: Decodable>(_ type: T.Type, _ request: Request) async throws -> T? {
        var request = request
        let buffer = try await request.collectBody(upTo: Self.defaultBodyBytes)
        guard buffer.readableBytes > 0 else { return nil }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    }
}
