// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import DoMoLLM
import Foundation

/// The bounded configuration for one ACP stdio agent. The command is an argv
/// vector, never a shell string; credentials are environment references owned
/// by the caller and are not copied into this value's diagnostics.
public struct ACPClientConfiguration: Sendable {
    public var command: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var sensitiveEnvironmentKeys: Set<String>
    public var sandbox: ProcessSandbox?
    public var requestTimeout: Duration
    public var clientName: String
    public var clientVersion: String
    /// An existing ACP session to load instead of creating a new session.
    /// Loading is opt-in because the external agent owns the session history.
    public var resumeSessionID: String?
    /// Receives redacted permission-request params and returns the ACP
    /// `result` object. Returning `nil` keeps the fail-closed cancelled outcome.
    public var permissionHandler: (@Sendable (JSONValue) async -> JSONValue)?

    public init(
        command: [String],
        environment: [String: String] = [:],
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        sensitiveEnvironmentKeys: Set<String> = [],
        sandbox: ProcessSandbox? = nil,
        requestTimeout: Duration = .seconds(60),
        clientName: String = "domocode",
        clientVersion: String = "0.1.0",
        resumeSessionID: String? = nil,
        permissionHandler: (@Sendable (JSONValue) async -> JSONValue)? = nil
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sensitiveEnvironmentKeys = sensitiveEnvironmentKeys
        self.sandbox = sandbox
        self.requestTimeout = requestTimeout
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.resumeSessionID = resumeSessionID
        self.permissionHandler = permissionHandler
    }
}

public struct ACPHandshake: Sendable, Codable, Hashable {
    public var protocolVersion: Int
    public var agentCapabilities: JSONValue
    public var agentInfo: JSONValue

    public init(
        protocolVersion: Int,
        agentCapabilities: JSONValue = .object([:]),
        agentInfo: JSONValue = .object([:])
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
    }
}

public enum ACPClientError: Error, Sendable, Equatable {
    case emptyCommand
    case connectionClosed
    case timedOut
    case malformedMessage
    case protocolError(String)
    case unsupportedVersion(Int)
    case missingSessionID
    case unsupportedRequest(String)
}

/// Maps ACP's extensible `session/update` vocabulary into the provider-neutral
/// event contract. Unknown updates remain visible as `.unknown`; adding an ACP
/// extension therefore cannot make the host discard the rest of a turn.
public enum ACPEventMapper {
    public static let supportedEvents: [ProviderEvent.Kind] = [
        .messageStart, .textDelta, .reasoningDelta, .toolCallDelta,
        .toolResult, .image, .plan, .task, .usage, .permission,
        .messageEnd, .cancelled, .error, .unknown,
    ]

    public static func events(
        sessionID: String,
        update: JSONValue,
        sequence: inout Int
    ) -> [ProviderEvent] {
        let updateName = update["sessionUpdate"]?.stringValue ?? "unknown"

        func payload(_ extra: [String: JSONValue] = [:]) -> JSONValue {
            var object = extra
            object["sessionId"] = .string(sessionID)
            for key in ["messageId", "toolCallId", "taskId", "updateId"] {
                if let correlationID = update[key] {
                    object["correlationId"] = correlationID
                    break
                }
            }
            object["update"] = update
            return .object(object)
        }

        func make(_ kind: ProviderEvent.Kind, _ value: JSONValue) -> ProviderEvent {
            defer { sequence += 1 }
            return ProviderEvent(kind: kind, payload: value, sequence: sequence)
        }

        switch updateName {
        case "agent_message_chunk":
            let events = contentEvents(
                content: update["content"],
                sessionID: sessionID,
                update: update,
                kind: .textDelta,
                sequence: &sequence
            )
            return events.isEmpty ? [make(.unknown, payload())] : events
        case "user_message", "user_message_chunk":
            return [make(.task, payload(["role": .string("user")]))]
        case "agent_thought_chunk":
            let events = contentEvents(
                content: update["content"],
                sessionID: sessionID,
                update: update,
                kind: .reasoningDelta,
                sequence: &sequence
            )
            return events.isEmpty ? [make(.unknown, payload())] : events
        case "tool_call":
            return [make(.toolCallDelta, payload([
                "phase": .string("start"),
                "toolCallId": update["toolCallId"] ?? .null,
                "title": update["title"] ?? .null,
                "kind": update["kind"] ?? .null,
                "status": update["status"] ?? .string("pending"),
            ]))]
        case "tool_call_update":
            let status = update["status"]?.stringValue?.lowercased()
            let finished = status == "completed" || status == "failed" || status == "cancelled"
            return [make(finished ? .toolResult : .toolCallDelta, payload([
                "phase": .string("update"),
                "toolCallId": update["toolCallId"] ?? .null,
                "status": update["status"] ?? .null,
                "content": update["content"] ?? .null,
                "rawOutput": update["rawOutput"] ?? .null,
                "locations": update["locations"] ?? .null,
                "isError": .bool(status == "failed"),
            ]))]
        case "plan":
            return [make(.plan, payload(["entries": update["entries"] ?? .array([])]))]
        case "usage_update":
            return [make(.usage, payload([
                "used": update["used"] ?? .null,
                "size": update["size"] ?? .null,
                "cost": update["cost"] ?? .null,
            ]))]
        case "state_change", "current_mode_update", "session_info_update", "available_commands_update", "config_option_update":
            return [make(.task, payload())]
        case "retry", "retry_update":
            return [make(.retry, payload())]
        case "task", "task_update":
            return [make(.task, payload())]
        case "permission":
            return [make(.permission, payload(["request": update["request"] ?? .null]))]
        default:
            return [make(.unknown, payload())]
        }
    }

    public static func terminalEvent(
        sessionID: String,
        response: JSONValue,
        sequence: inout Int
    ) -> ProviderEvent {
        defer { sequence += 1 }
        let stopReason = response["stopReason"]?.stringValue ?? "unknown"
        let kind: ProviderEvent.Kind = stopReason == "cancelled" ? .cancelled : .messageEnd
        return ProviderEvent(
            kind: kind,
            payload: [
                "sessionId": .string(sessionID),
                "stopReason": .string(stopReason),
                "response": response,
            ],
            sequence: sequence
        )
    }

    private static func contentEvents(
        content: JSONValue?,
        sessionID: String,
        update: JSONValue,
        kind: ProviderEvent.Kind,
        sequence: inout Int
    ) -> [ProviderEvent] {
        guard let content else { return [] }

        let blocks: [JSONValue]
        if let array = content.arrayValue {
            blocks = array
        } else {
            blocks = [content]
        }

        var events: [ProviderEvent] = []
        for block in blocks {
            let type = block["type"]?.stringValue ?? "text"
            let payload: JSONValue = [
                "sessionId": .string(sessionID),
                "messageId": update["messageId"] ?? .null,
                "content": block,
                "delta": block["text"] ?? block["data"] ?? .null,
                "update": update,
            ]
            let eventKind: ProviderEvent.Kind
            switch type {
            case "text": eventKind = kind
            case "image": eventKind = .image
            default: eventKind = .unknown
            }
            events.append(ProviderEvent(kind: eventKind, payload: payload, sequence: sequence))
            sequence += 1
        }
        return events
    }
}

/// A hand-written ACP v1 stdio client. It owns only the process and JSON-RPC
/// lifecycle; the external agent owns login, model access, tools, and any
/// proprietary subscription protocol. Filesystem, terminal, and elicitation
/// requests are refused unless a future explicit capability handler is added.
public actor ACPClient {
    public let configuration: ACPClientConfiguration

    private let process = PersistentProcess()
    private var readerTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var activePromptID: Int?
    private var activeUpdates: AsyncStream<JSONValue>.Continuation?
    private var initialized = false
    private var closed = false
    private var sessionID: String?
    private var handshake: ACPHandshake?

    public init(configuration: ACPClientConfiguration) {
        self.configuration = configuration
    }

    public func handshakeInfo() -> ACPHandshake? { handshake }

    public func start() async throws {
        guard !configuration.command.isEmpty else { throw ACPClientError.emptyCommand }
        if initialized { return }
        guard !closed else { throw ACPClientError.connectionClosed }

        try await process.start(PersistentProcess.Spawn(
            command: configuration.command,
            environment: configuration.environment,
            workingDirectory: configuration.workingDirectory,
            sensitiveEnvKeys: configuration.sensitiveEnvironmentKeys,
            sandbox: configuration.sandbox,
            sandboxRole: .provider
        ))
        readerTask = Task { [weak self] in await self?.readLoop() }

        let result = try await request("initialize", params: [
            "protocolVersion": .int(1),
            "clientCapabilities": .object([:]),
            "clientInfo": [
                "name": .string(configuration.clientName),
                "title": .string("DoMoCode"),
                "version": .string(configuration.clientVersion),
            ],
        ])
        guard let version = result["protocolVersion"]?.intValue else {
            throw ACPClientError.protocolError("ACP initialize response omitted protocolVersion")
        }
        guard version == 1 else { throw ACPClientError.unsupportedVersion(version) }
        handshake = ACPHandshake(
            protocolVersion: version,
            agentCapabilities: result["agentCapabilities"] ?? .object([:]),
            agentInfo: result["agentInfo"] ?? .object([:])
        )

        let sessionMethod = configuration.resumeSessionID == nil ? "session/new" : "session/load"
        var sessionParams: [String: JSONValue] = [
            "cwd": .string(configuration.workingDirectory),
            "mcpServers": .array([]),
        ]
        if let resumeSessionID = configuration.resumeSessionID {
            sessionParams["sessionId"] = .string(resumeSessionID)
        }
        let session = try await request(sessionMethod, params: .object(sessionParams))
        let newSessionID = session["sessionId"]?.stringValue ?? configuration.resumeSessionID
        guard let newSessionID, !newSessionID.isEmpty else {
            throw ACPClientError.missingSessionID
        }
        sessionID = newSessionID
        initialized = true
    }

    /// Starts one ACP prompt turn. Only one prompt may be active per client;
    /// overlapping calls fail instead of interleaving updates or replaying a
    /// committed external tool call.
    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await runPrompt(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.cancelPrompt() }
            }
        }
    }

    public func cancelPrompt() async {
        guard let sessionID else { return }
        await notify("session/cancel", params: ["sessionId": .string(sessionID)])
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        initialized = false
        readerTask?.cancel()
        readerTask = nil
        activeUpdates?.finish()
        activeUpdates = nil
        failAllPending(ACPClientError.connectionClosed)
        await process.shutdown()
    }

    private func runPrompt(
        _ request: ProviderRequest,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) async throws {
        try await start()
        guard let sessionID else { throw ACPClientError.missingSessionID }
        guard activePromptID == nil else {
            throw ACPClientError.protocolError("ACP client already has an active prompt")
        }

        var updateContinuation: AsyncStream<JSONValue>.Continuation?
        let updates = AsyncStream<JSONValue>(bufferingPolicy: .bufferingNewest(512)) {
            updateContinuation = $0
        }
        guard let updateContinuation else { throw ACPClientError.protocolError("Could not create ACP update stream") }
        activeUpdates = updateContinuation

        let responseTask = Task { [self] in
            try await self.request(
                "session/prompt",
                params: [
                    "sessionId": .string(sessionID),
                    "prompt": promptBlocks(from: request),
                ],
                marksActivePrompt: true
            )
        }

        var sequence = 0
        for await update in updates {
            for event in ACPEventMapper.events(
                sessionID: sessionID,
                update: update,
                sequence: &sequence
            ) {
                continuation.yield(event)
            }
        }
        let response = try await responseTask.value
        for event in [ACPEventMapper.terminalEvent(
            sessionID: sessionID,
            response: response,
            sequence: &sequence
        )] {
            continuation.yield(event)
        }
        activeUpdates = nil
    }

    private func promptBlocks(from request: ProviderRequest) -> JSONValue {
        guard let message = request.messages.reversed().first(where: { $0.role == .user }) else {
            return .array([[
                "type": .string("text"),
                "text": .string(""),
            ]])
        }
        return contentBlocks(from: message.content)
    }

    private func contentBlocks(from content: JSONValue) -> JSONValue {
        if let text = content.stringValue {
            return .array([["type": .string("text"), "text": .string(text)]])
        }
        if let array = content.arrayValue {
            let blocks = array.map { block -> JSONValue in
                guard let type = block["type"]?.stringValue else {
                    return [
                        "type": .string("text"),
                        "text": .string((try? block.encodedString()) ?? ""),
                    ]
                }
                switch type {
                case "text", "image", "resource", "resource_link":
                    return block
                default:
                    return [
                        "type": .string("text"),
                        "text": .string((try? block.encodedString()) ?? ""),
                    ]
                }
            }
            return .array(blocks)
        }
        return [[
            "type": .string("text"),
            "text": .string((try? content.encodedString()) ?? ""),
        ]]
    }

    private func request(
        _ method: String,
        params: JSONValue?,
        marksActivePrompt: Bool = false
    ) async throws -> JSONValue {
        guard !closed else { throw ACPClientError.connectionClosed }
        let id = nextRequestID()
        if marksActivePrompt { activePromptID = id }
        defer {
            if marksActivePrompt { activePromptID = nil }
        }

        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        guard let line = try? JSONValue.object(object).encoded() else {
            throw ACPClientError.protocolError("Could not encode ACP request")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                let process = self.process
                timeoutTasks[id] = Task {
                    await process.send(Array(line))
                    do {
                        try await Task.sleep(for: configuration.requestTimeout)
                    } catch {
                        return
                    }
                    await self.timeout(id: id, method: method)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id, method: method) }
        }
    }

    private func notify(_ method: String, params: JSONValue?) async {
        guard !closed else { return }
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        guard let line = try? JSONValue.object(object).encoded() else { return }
        await process.send(Array(line))
    }

    private func respond(
        id: JSONValue,
        result: JSONValue? = nil,
        errorCode: Int? = nil,
        message: String? = nil
    ) async {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
        ]
        if let result {
            object["result"] = result
        } else {
            object["error"] = [
                "code": .int(errorCode ?? -32601),
                "message": .string(message ?? "Method not found"),
            ]
        }
        guard let line = try? JSONValue.object(object).encoded() else { return }
        await process.send(Array(line))
    }

    private func permissionResult(for params: JSONValue) async -> JSONValue {
        if let handler = configuration.permissionHandler {
            return await handler(Redaction.redact(params))
        }
        return [
            "outcome": [
                "outcome": .string("cancelled"),
            ],
        ]
    }

    private func dispatch(_ message: JSONValue) {
        if let idValue = message["id"], message["method"] == nil {
            guard let id = idValue.intValue, let continuation = takePending(id) else { return }
            if let error = message["error"] {
                let detail = Redaction.diagnostic(error["message"]?.stringValue ?? "ACP request failed")
                continuation.resume(throwing: ACPClientError.protocolError(detail))
            } else {
                if id == activePromptID { activeUpdates?.finish() }
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }

        guard let method = message["method"]?.stringValue else { return }
        if let id = message["id"] {
            if method == "session/request_permission" {
                let params = message["params"] ?? .object([:])
                activeUpdates?.yield([
                    "sessionUpdate": .string("permission"),
                    "request": Redaction.redact(params),
                ])
                Task { [self] in
                    let result = await permissionResult(for: params)
                    await respond(id: id, result: result)
                }
            } else {
                Task { await respond(id: id, errorCode: -32601, message: "Unsupported ACP client method") }
            }
        } else if method == "session/update" {
            if let params = message["params"], let update = params["update"] {
                let updateSessionID = params["sessionId"]?.stringValue ?? sessionID ?? ""
                guard !updateSessionID.isEmpty else { return }
                activeUpdates?.yield(update)
            }
        }
    }

    private func readLoop() async {
        for await line in process.lines {
            guard let message = try? JSONValue(parsing: Data(line)) else {
                failAllPending(ACPClientError.malformedMessage)
                break
            }
            dispatch(message)
        }
        if !closed {
            closed = true
            activeUpdates?.finish()
            failAllPending(ACPClientError.connectionClosed)
        }
    }

    private func nextRequestID() -> Int {
        nextID += 1
        return nextID
    }

    private func takePending(_ id: Int) -> CheckedContinuation<JSONValue, any Error>? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        return pending.removeValue(forKey: id)
    }

    private func timeout(id: Int, method: String) async {
        guard let continuation = takePending(id) else { return }
        if method != "initialize" {
            await notify("session/cancel", params: sessionID.map { ["sessionId": .string($0)] })
        }
        continuation.resume(throwing: ACPClientError.timedOut)
    }

    private func cancel(id: Int, method: String) async {
        guard let continuation = takePending(id) else { return }
        if method == "session/prompt" {
            await notify("session/cancel", params: sessionID.map { ["sessionId": .string($0)] })
        }
        continuation.resume(throwing: CancellationError())
    }

    private func failAllPending(_ error: any Error) {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}

/// A DoMo provider adapter for external ACP agents such as Claude Code, Codex,
/// or Gemini CLI. The adapter deliberately reports only the normalized event
/// contract; it never reads a subscription token or attempts to imitate the
/// provider's private API.
public struct ACPProviderAdapter: DoMoProvider, DoMoAdapterHealthChecking {
    public let profile: ProviderProfile
    private let client: ACPClient

    public init(profile: ProviderProfile, configuration: ACPClientConfiguration) {
        self.profile = profile
        self.client = ACPClient(configuration: configuration)
    }

    public var descriptor: AdapterDescriptor {
        AdapterDescriptor(
            id: profile.adapterID,
            displayName: profile.displayName,
            capabilities: profile.capabilities,
            kind: .acp,
            source: .builtInMIT
        )
    }

    public var providerDescriptor: ProviderDescriptor {
        ProviderDescriptor(id: profile.id, displayName: profile.displayName, capabilities: profile.capabilities)
    }

    public func start() async throws { try await client.start() }
    public func stop() async { await client.shutdown() }

    public func listModels() async throws -> [ProviderModel] {
        guard let model = profile.defaultModel, !model.isEmpty else { return [] }
        return [ProviderModel(
            id: model,
            displayName: model,
            contextWindow: profile.contextWindow,
            capabilities: profile.capabilities
        )]
    }

    public func healthCheck() async -> AdapterHealth {
        do {
            try await client.start()
            let info = await client.handshakeInfo()
            return AdapterHealth(
                status: .healthy,
                message: "ACP v\(info?.protocolVersion ?? 1) initialize/session handshake succeeded",
                supportedEvents: ACPEventMapper.supportedEvents.map(\.rawValue),
                credentialRequired: profile.credential.required
            )
        } catch {
            return AdapterHealth(
                status: .unavailable,
                message: Redaction.diagnostic(String(describing: error)),
                supportedEvents: ACPEventMapper.supportedEvents.map(\.rawValue),
                credentialRequired: profile.credential.required
            )
        }
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        do {
            try ProviderCapabilityChecker.validate(request: request, descriptor: providerDescriptor)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = await client.stream(request)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
