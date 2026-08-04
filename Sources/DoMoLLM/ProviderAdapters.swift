// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import HTTPTypes

// MARK: - Provider-neutral conversion

enum ProviderAdapterConversion {
    static func text(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        if let text = value["text"]?.stringValue { return text }
        return (try? value.encodedString()) ?? ""
    }

    static func json<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let result = try? JSONValue(parsing: data) else {
            return .null
        }
        return result
    }

    static func stringOption(_ options: JSONValue, keys: [String]) -> String? {
        for key in keys {
            if let value = options[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    static func intOption(_ options: JSONValue, keys: [String]) -> Int? {
        for key in keys {
            if let value = options[key]?.intValue { return value }
        }
        return nil
    }

    static func doubleOption(_ options: JSONValue, keys: [String]) -> Double? {
        for key in keys {
            if let value = options[key]?.doubleValue { return value }
        }
        return nil
    }

    static func context(from request: ProviderRequest) throws(DoMoError) -> Context {
        var systemParts: [String] = []
        var messages: [Message] = []

        for message in request.messages {
            switch message.role {
            case .system:
                let text = Self.text(message.content)
                if !text.isEmpty { systemParts.append(text) }
            case .user:
                messages.append(.user(Self.text(message.content)))
            case .assistant:
                let text = Self.text(message.content)
                messages.append(.assistant(
                    AssistantMessage(
                        content: text.isEmpty ? [] : [.text(text)],
                        model: request.model
                    )
                ))
            case .tool:
                let toolCallID = message.content["toolCallId"]?.stringValue
                    ?? message.content["tool_call_id"]?.stringValue
                    ?? message.metadata["toolCallId"]?.stringValue
                    ?? message.metadata["tool_call_id"]?.stringValue
                    ?? "provider-tool-result"
                let toolName = message.content["toolName"]?.stringValue
                    ?? message.content["tool_name"]?.stringValue
                    ?? message.metadata["toolName"]?.stringValue
                    ?? "tool"
                let output = message.content["output"]?.stringValue ?? Self.text(message.content)
                let isError = message.content["isError"]?.boolValue
                    ?? message.content["is_error"]?.boolValue
                    ?? false
                messages.append(.tool(ToolResultBlock(
                    toolCallID: toolCallID,
                    toolName: toolName,
                    output: output,
                    isError: isError
                )))
            }
        }

        var tools: [ToolDefinition] = []
        tools.reserveCapacity(request.tools.count)
        for tool in request.tools {
            do {
                tools.append(ToolDefinition(
                    name: tool.name,
                    description: tool.description ?? "",
                    parameters: try JSONSchema(jsonValue: tool.inputSchema)
                ))
            } catch {
                throw DoMoError(
                    .configuration,
                    "Provider tool \(tool.name) has an invalid JSON Schema",
                    cause: error
                )
            }
        }

        return Context(
            systemPrompt: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            messages: messages,
            tools: tools
        )
    }

    static func toolChoice(from options: JSONValue) -> WireToolChoice? {
        let value = options["toolChoice"] ?? options["tool_choice"]
        guard let value else { return nil }
        guard let data = try? value.encoded(), let choice = try? JSONDecoder().decode(WireToolChoice.self, from: data) else {
            return nil
        }
        return choice
    }

    static func standardEvents(
        for event: AssemblyEvent,
        sequence: inout Int
    ) -> [ProviderEvent] {
        func make(_ kind: ProviderEvent.Kind, _ payload: JSONValue = .null) -> ProviderEvent {
            defer { sequence += 1 }
            return ProviderEvent(kind: kind, payload: payload, sequence: sequence)
        }

        switch event {
        case .start(let snapshot):
            return [make(.messageStart, [
                "model": .string(snapshot.model),
                "responseModel": snapshot.responseModel.map(JSONValue.string) ?? .null,
                "responseId": snapshot.responseID.map(JSONValue.string) ?? .null,
            ])]
        case .textDelta(let blockIndex, let delta):
            return [make(.textDelta, ["blockIndex": .int(blockIndex), "delta": .string(delta)])]
        case .reasoningDelta(let blockIndex, let delta):
            return [make(.reasoningDelta, ["blockIndex": .int(blockIndex), "delta": .string(delta)])]
        case .toolCallStart(let blockIndex, _):
            return [make(.toolCallDelta, ["phase": .string("start"), "blockIndex": .int(blockIndex)])]
        case .toolCallDelta(let blockIndex, let delta):
            return [make(.toolCallDelta, [
                "phase": .string("delta"),
                "blockIndex": .int(blockIndex),
                "delta": .string(delta),
            ])]
        case .toolCallEnd(let blockIndex, let call, _):
            return [make(.toolCallDelta, [
                "phase": .string("end"),
                "blockIndex": .int(blockIndex),
                "id": .string(call.id),
                "name": .string(call.name),
                "arguments": call.arguments,
            ])]
        case .retrying(let notice):
            return [make(.retry, [
                "attempt": .int(notice.attempt),
                "maxAttempts": .int(notice.maxAttempts),
                "delayMilliseconds": .int(DoMoError.wholeMilliseconds(notice.delay)),
                "reason": .string(notice.reason.label),
                "message": .string(notice.message),
            ])]
        case .recovery(let envelope):
            return [make(.error, ["recovery": Self.json(envelope)])]
        case .done(let message):
            return [make(.messageEnd, [
                "assistant": Self.json(message),
                "stopReason": .string(String(describing: message.stopReason)),
            ])]
        case .failed(let message):
            return [
                make(.error, [
                    "message": .string(message.errorMessage ?? "Provider request failed"),
                    "assistant": Self.json(message),
                ]),
                make(.messageEnd, [
                    "assistant": Self.json(message),
                    "stopReason": .string(String(describing: message.stopReason)),
                ]),
            ]
        case .textStart, .textEnd, .reasoningStart, .reasoningEnd:
            return []
        }
    }

    static func eventList(_ kinds: [ProviderEvent.Kind]) -> [String] {
        kinds.map(\.rawValue)
    }
}

// MARK: - LiteLLM / OpenAI-compatible Chat Completions

/// The first concrete provider adapter. The gateway-specific client remains an
/// implementation detail; callers receive the provider-neutral contract and
/// may replace it with another adapter without changing the agent loop.
public struct LiteLLMProviderAdapter: DoMoProvider, DoMoAdapterHealthChecking {
    public let profile: ProviderProfile
    private let client: LiteLLMClient

    public init(profile: ProviderProfile, client: LiteLLMClient) {
        self.profile = profile
        self.client = client
    }

    public var descriptor: AdapterDescriptor {
        AdapterDescriptor(
            id: profile.adapterID,
            displayName: profile.displayName,
            capabilities: profile.capabilities,
            kind: .provider,
            source: .builtInMIT
        )
    }

    public var providerDescriptor: ProviderDescriptor {
        ProviderDescriptor(id: profile.id, displayName: profile.displayName, capabilities: profile.capabilities)
    }

    public func start() async throws {}
    public func stop() async {}

    public func listModels() async throws -> [ProviderModel] {
        try await client.listModels().models.map { entry in
            ProviderModel(
                id: entry.id,
                displayName: entry.id,
                contextWindow: profile.contextWindow,
                capabilities: profile.capabilities
            )
        }
    }

    public func healthCheck() async -> AdapterHealth {
        do {
            _ = try await listModels()
            return AdapterHealth(
                status: .healthy,
                message: "Model catalog handshake succeeded",
                supportedEvents: ProviderAdapterConversion.eventList([
                    .messageStart, .textDelta, .reasoningDelta, .toolCallDelta,
                    .usage, .retry, .messageEnd, .error,
                ]),
                credentialRequired: profile.credential.required
            )
        } catch {
            return AdapterHealth(
                status: .unavailable,
                message: Redaction.diagnostic(String(describing: error)),
                supportedEvents: ProviderAdapterConversion.eventList([
                    .messageStart, .textDelta, .reasoningDelta, .toolCallDelta,
                    .usage, .retry, .messageEnd, .error,
                ]),
                credentialRequired: profile.credential.required
            )
        }
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let context: Context
        do {
            context = try ProviderAdapterConversion.context(from: request)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let model = request.model.isEmpty ? (profile.defaultModel ?? request.model) : request.model
        let temperature = ProviderAdapterConversion.doubleOption(request.options, keys: ["temperature"])
        let maxTokens = ProviderAdapterConversion.intOption(request.options, keys: ["maxTokens", "max_tokens"])
        let reasoningEffort = ProviderAdapterConversion.stringOption(
            request.options,
            keys: ["reasoningEffort", "reasoning_effort"]
        ).map(ReasoningEffort.init(rawValue:))
        let toolChoice = ProviderAdapterConversion.toolChoice(from: request.options)
        let upstream = client.streamCompletion(
            model: model,
            context: context,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            toolChoice: toolChoice
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sequence = 0
                    for try await event in upstream {
                        for normalized in ProviderAdapterConversion.standardEvents(
                            for: event,
                            sequence: &sequence
                        ) {
                            continuation.yield(normalized)
                        }
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

/// OpenAI-compatible Chat Completions is intentionally an alias of the
/// LiteLLM-backed implementation: LiteLLM speaks this public wire contract,
/// so the protocol does not need to know which gateway is in front of it.
public typealias OpenAICompatibleProviderAdapter = LiteLLMProviderAdapter

// MARK: - Anthropic Messages

/// A hand-written, lenient Anthropic Messages streaming adapter. It accepts
/// documented event fields while preserving unknown fields in `ProviderEvent`
/// payloads, so a provider extension does not become a decoding failure in the
/// host. Credentials are injected separately from the profile.
public struct AnthropicMessagesProviderAdapter: DoMoProvider, DoMoAdapterHealthChecking {
    public let profile: ProviderProfile
    private let credential: String?
    private let transport: any StreamingTransport
    private let defaultMaxTokens: Int

    public init(
        profile: ProviderProfile,
        credential: String?,
        transport: any StreamingTransport = AsyncHTTPClientTransport(),
        defaultMaxTokens: Int = 4096
    ) {
        self.profile = profile
        self.credential = credential
        self.transport = transport
        self.defaultMaxTokens = max(1, defaultMaxTokens)
    }

    public var descriptor: AdapterDescriptor {
        AdapterDescriptor(
            id: profile.adapterID,
            displayName: profile.displayName,
            capabilities: profile.capabilities,
            kind: .provider,
            source: .builtInMIT
        )
    }

    public var providerDescriptor: ProviderDescriptor {
        ProviderDescriptor(id: profile.id, displayName: profile.displayName, capabilities: profile.capabilities)
    }

    public func start() async throws {}
    public func stop() async {}

    public func listModels() async throws -> [ProviderModel] {
        guard let model = profile.defaultModel, !model.isEmpty else {
            throw DoMoError(.configuration, "Anthropic profile has no default model")
        }
        return [ProviderModel(
            id: model,
            displayName: model,
            contextWindow: profile.contextWindow,
            capabilities: profile.capabilities
        )]
    }

    public func healthCheck() async -> AdapterHealth {
        let endpointOK = URL(string: profile.endpoint)?.scheme != nil
        let credentialOK = !(credential?.isEmpty ?? true) || !profile.credential.required
        let status: AdapterHealthStatus = endpointOK && credentialOK ? .healthy : .unavailable
        let message: String
        if !endpointOK {
            message = "Profile endpoint is not a valid URL"
        } else if !credentialOK {
            message = "Required credential reference is not resolved"
        } else {
            message = "Configuration handshake succeeded; no billable model request was made"
        }
        return AdapterHealth(
            status: status,
            message: message,
            supportedEvents: ProviderAdapterConversion.eventList([
                .messageStart, .textDelta, .reasoningDelta, .toolCallDelta,
                .usage, .messageEnd, .error,
            ]),
            credentialRequired: profile.credential.required
        )
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let body: [UInt8]
        let httpRequest: HTTPRequest
        do {
            (httpRequest, body) = try makeRequest(for: request)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.execute(
                        request: httpRequest,
                        body: body,
                        timeout: AsyncHTTPClientTransport.defaultTimeout
                    )
                    let status = response.head.status.code
                    guard (200..<300).contains(status) else {
                        let text = await Self.collect(response.body)
                        throw Self.classify(status: status, body: text, policy: profile.errorPolicy)
                    }

                    let decoder = SSEByteDecoder()
                    var sequence = 0
                    for try await chunk in response.body {
                        let frames = await decoder.consume(chunk)
                        for frame in frames {
                            try Self.emit(
                                frame: frame,
                                sequence: &sequence,
                                continuation: continuation
                            )
                        }
                    }
                    for frame in await decoder.finish() {
                        try Self.emit(
                            frame: frame,
                            sequence: &sequence,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(for request: ProviderRequest) throws(DoMoError) -> (HTTPRequest, [UInt8]) {
        guard let baseURL = URL(string: profile.endpoint) else {
            throw DoMoError(.configuration, "Invalid Anthropic profile endpoint")
        }
        let base = profile.endpoint.hasSuffix("/messages")
            ? profile.endpoint
            : profile.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/messages"
        guard let url = URL(string: base), baseURL.scheme != nil else {
            throw DoMoError(.configuration, "Invalid Anthropic Messages endpoint")
        }

        let systemMessages = request.messages
            .filter { $0.role == .system }
            .map { ProviderAdapterConversion.text($0.content) }
            .filter { !$0.isEmpty }
        let messages = request.messages
            .filter { $0.role != .system }
            .map(Self.anthropicMessage)
        let maxTokens = ProviderAdapterConversion.intOption(
            request.options,
            keys: ["maxTokens", "max_tokens"]
        ) ?? defaultMaxTokens
        var object: [String: JSONValue] = [
            "model": .string(request.model.isEmpty ? (profile.defaultModel ?? "") : request.model),
            "max_tokens": .int(max(1, maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages),
        ]
        if !systemMessages.isEmpty { object["system"] = .string(systemMessages.joined(separator: "\n\n")) }
        if let temperature = ProviderAdapterConversion.doubleOption(request.options, keys: ["temperature"]) {
            object["temperature"] = .double(temperature)
        }
        if !request.tools.isEmpty {
            object["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": tool.description.map(JSONValue.string) ?? .null,
                    "input_schema": tool.inputSchema,
                ]
            })
        }

        guard let encoded = try? JSONValue.object(object).encoded() else {
            throw DoMoError(.configuration, "Could not encode Anthropic Messages request")
        }
        var httpRequest = HTTPRequest(method: .post, url: url)
        httpRequest.headerFields[.accept] = "text/event-stream"
        httpRequest.headerFields[.contentType] = "application/json"
        if let version = HTTPField.Name("anthropic-version") {
            httpRequest.headerFields[version] = "2023-06-01"
        }
        if let credential, !credential.isEmpty, let key = HTTPField.Name("x-api-key") {
            httpRequest.headerFields[key] = credential
        }
        return (httpRequest, Array(encoded))
    }

    private static func anthropicMessage(_ message: ProviderMessage) -> JSONValue {
        switch message.role {
        case .tool:
            let id = message.content["toolCallId"]?.stringValue
                ?? message.content["tool_call_id"]?.stringValue
                ?? message.metadata["toolCallId"]?.stringValue
                ?? "provider-tool-result"
            let output = message.content["output"] ?? message.content
            let result: JSONValue = [
                "type": .string("tool_result"),
                "tool_use_id": .string(id),
                "content": output,
                "is_error": message.content["isError"] ?? message.content["is_error"] ?? .bool(false),
            ]
            return ["role": "user", "content": [result]]
        case .user:
            return ["role": "user", "content": message.content]
        case .assistant:
            return ["role": "assistant", "content": message.content]
        case .system:
            return ["role": "user", "content": message.content]
        }
    }

    private static func emit(
        frame: SSEFrame,
        sequence: inout Int,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) throws(DoMoError) {
        func yield(_ kind: ProviderEvent.Kind, _ payload: JSONValue = .null) {
            continuation.yield(ProviderEvent(kind: kind, payload: payload, sequence: sequence))
            sequence += 1
        }

        switch frame {
        case .done:
            yield(.messageEnd, ["source": "done"])
        case .data(let data):
            guard let payload = try? JSONValue(parsing: data) else {
                throw DoMoError(.malformedResponse, "Anthropic SSE event was not valid JSON")
            }
            let type = payload["type"]?.stringValue ?? "unknown"
            switch type {
            case "message_start":
                yield(.messageStart, payload)
            case "content_block_start":
                let block = payload["content_block"] ?? .null
                let blockType = block["type"]?.stringValue ?? "unknown"
                if blockType == "tool_use" {
                    yield(.toolCallDelta, [
                        "phase": "start",
                        "index": payload["index"] ?? .null,
                        "id": block["id"] ?? .null,
                        "name": block["name"] ?? .null,
                    ])
                }
            case "content_block_delta":
                let delta = payload["delta"] ?? .null
                switch delta["type"]?.stringValue {
                case "text_delta":
                    yield(.textDelta, [
                        "index": payload["index"] ?? .null,
                        "delta": delta["text"] ?? "",
                    ])
                case "thinking_delta", "signature_delta":
                    yield(.reasoningDelta, [
                        "index": payload["index"] ?? .null,
                        "delta": delta["thinking"] ?? delta["signature"] ?? "",
                    ])
                case "input_json_delta":
                    yield(.toolCallDelta, [
                        "phase": "delta",
                        "index": payload["index"] ?? .null,
                        "delta": delta["partial_json"] ?? "",
                    ])
                default:
                    yield(.unknown, payload)
                }
            case "content_block_stop":
                yield(.toolCallDelta, [
                    "phase": "end",
                    "index": payload["index"] ?? .null,
                ])
            case "message_delta":
                if let usage = payload["usage"] { yield(.usage, usage) }
                if payload["delta"]?["stop_reason"] != nil {
                    yield(.messageEnd, payload)
                }
            case "message_stop":
                yield(.messageEnd, payload)
            case "error":
                let errorPayload = payload["error"] ?? payload
                let message = errorPayload["message"]?.stringValue ?? "Anthropic provider returned an error"
                yield(.error, payload)
                throw DoMoError(.provider(status: nil, isRetryable: false), Redaction.diagnostic(message))
            default:
                yield(.unknown, payload)
            }
        }
    }

    private static func collect(_ body: AsyncThrowingStream<[UInt8], any Error>) async -> String {
        var bytes: [UInt8] = []
        let cap = 64 * 1024
        do {
            for try await chunk in body {
                let remaining = cap - bytes.count
                if remaining <= 0 { break }
                bytes.append(contentsOf: chunk.prefix(remaining))
            }
        } catch {
            // The HTTP status and bounded bytes are more useful than replacing a
            // provider error with a body-read failure.
        }
        return Redaction.diagnostic(String(decoding: bytes, as: UTF8.self))
    }

    private static func classify(
        status: Int,
        body: String,
        policy: ProviderErrorPolicy
    ) -> DoMoError {
        let lower = body.lowercased()
        if status == 401 || status == 403 {
            return DoMoError(.authentication, "Provider authentication failed")
        }
        if status == 402 || policy.quotaMarkers.contains(where: lower.contains) {
            return DoMoError(.quotaExhausted, "Provider quota or billing limit reached")
        }
        if policy.notFoundStatusCodes.contains(status) {
            return DoMoError(.provider(status: status, isRetryable: false), "Provider model or route was not found")
        }
        if status == 429 {
            return DoMoError(.rateLimit(retryAfter: nil), "Provider rate limit exceeded")
        }
        let retryable = policy.transientStatusCodes.contains(status)
            || policy.transientMarkers.contains(where: lower.contains)
        return DoMoError(.provider(status: status, isRetryable: retryable), "Anthropic provider request failed")
    }
}
