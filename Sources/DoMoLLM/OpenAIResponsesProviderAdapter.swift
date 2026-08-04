// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import HTTPTypes

/// A hand-written OpenAI Responses adapter.
///
/// Responses is intentionally separate from the LiteLLM Chat Completions
/// adapter. The two APIs have different input items and event vocabularies;
/// keeping this translation explicit prevents a gateway compatibility shim
/// from leaking into the provider-neutral contract. Unknown SSE event types
/// are retained as `.unknown` events so a newly-added Responses event cannot
/// terminate an otherwise valid turn.
public struct OpenAIResponsesProviderAdapter: DoMoProvider, DoMoAdapterHealthChecking {
    public let profile: ProviderProfile
    private let credential: String?
    private let transport: any StreamingTransport

    public init(
        profile: ProviderProfile,
        credential: String?,
        transport: any StreamingTransport = AsyncHTTPClientTransport()
    ) {
        self.profile = profile
        self.credential = credential
        self.transport = transport
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
            throw DoMoError(.configuration, "OpenAI Responses profile has no default model")
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
            supportedEvents: Self.supportedEvents.map(\.rawValue),
            credentialRequired: profile.credential.required
        )
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let body: [UInt8]
        let httpRequest: HTTPRequest
        do {
            (httpRequest, body) = try Self.makeRequest(
                profile: profile,
                credential: credential,
                request: request
            )
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
                    var ended = false
                    var finishedToolCalls: Set<String> = []
                    for try await chunk in response.body {
                        let frames = await decoder.consume(chunk)
                        for frame in frames {
                            try Self.emit(
                                frame: frame,
                                sequence: &sequence,
                                ended: &ended,
                                finishedToolCalls: &finishedToolCalls,
                                continuation: continuation
                            )
                        }
                    }
                    for frame in await decoder.finish() {
                        try Self.emit(
                            frame: frame,
                            sequence: &sequence,
                            ended: &ended,
                            finishedToolCalls: &finishedToolCalls,
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

    private static let supportedEvents: [ProviderEvent.Kind] = [
        .messageStart, .textDelta, .reasoningDelta, .toolCallDelta,
        .toolResult, .usage, .retry, .messageEnd, .error, .unknown,
    ]

    private static func makeRequest(
        profile: ProviderProfile,
        credential: String?,
        request: ProviderRequest
    ) throws(DoMoError) -> (HTTPRequest, [UInt8]) {
        guard let endpointURL = URL(string: profile.endpoint), endpointURL.scheme != nil else {
            throw DoMoError(.configuration, "Invalid OpenAI Responses profile endpoint")
        }
        let endpoint = profile.endpoint.hasSuffix("/responses")
            ? profile.endpoint
            : profile.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/responses"
        guard let url = URL(string: endpoint) else {
            throw DoMoError(.configuration, "Invalid OpenAI Responses endpoint")
        }

        let model = request.model.isEmpty ? (profile.defaultModel ?? "") : request.model
        var object: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(request.messages.flatMap(Self.inputItems)),
            "stream": .bool(true),
        ]
        if !request.tools.isEmpty {
            object["tools"] = .array(request.tools.map { tool in
                [
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": tool.description.map(JSONValue.string) ?? .null,
                    "parameters": tool.inputSchema,
                ]
            })
        }
        if let temperature = ProviderAdapterConversion.doubleOption(request.options, keys: ["temperature"]) {
            object["temperature"] = .double(temperature)
        }
        if let maxTokens = ProviderAdapterConversion.intOption(
            request.options,
            keys: ["maxOutputTokens", "max_output_tokens", "maxTokens", "max_tokens"]
        ) {
            object["max_output_tokens"] = .int(max(1, maxTokens))
        }
        if let reasoning = ProviderAdapterConversion.stringOption(
            request.options,
            keys: ["reasoningEffort", "reasoning_effort"]
        ), !reasoning.isEmpty {
            object["reasoning"] = ["effort": .string(reasoning)]
        }
        if let toolChoice = request.options["toolChoice"] ?? request.options["tool_choice"] {
            object["tool_choice"] = toolChoice
        }

        guard let encoded = try? JSONValue.object(object).encoded() else {
            throw DoMoError(.configuration, "Could not encode OpenAI Responses request")
        }
        var httpRequest = HTTPRequest(method: .post, url: url)
        httpRequest.headerFields[.accept] = "text/event-stream"
        httpRequest.headerFields[.contentType] = "application/json"
        if let credential, !credential.isEmpty, let authorization = HTTPField.Name("authorization") {
            httpRequest.headerFields[authorization] = "Bearer \(credential)"
        }
        return (httpRequest, Array(encoded))
    }

    private static func inputItems(from message: ProviderMessage) -> [JSONValue] {
        switch message.role {
        case .tool:
            let callID = message.content["toolCallId"]?.stringValue
                ?? message.content["tool_call_id"]?.stringValue
                ?? message.metadata["toolCallId"]?.stringValue
                ?? message.metadata["tool_call_id"]?.stringValue
                ?? "provider-tool-result"
            let output = message.content["output"] ?? message.content
            return [[
                "type": .string("function_call_output"),
                "call_id": .string(ToolCallIDPolicy.wireID(callID)),
                "output": output,
            ]]
        case .system, .user, .assistant:
            let role: String
            switch message.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return [[
                "role": .string(role),
                "content": responsesContent(message.content),
            ]]
        }
    }

    private static func responsesContent(_ content: JSONValue) -> JSONValue {
        guard let blocks = content.arrayValue else { return content }
        return .array(blocks.map { block in
            guard block["type"]?.stringValue == "text" else { return block }
            var mapped = block.objectValue ?? [:]
            mapped["type"] = .string("input_text")
            return .object(mapped)
        })
    }

    private static func emit(
        frame: SSEFrame,
        sequence: inout Int,
        ended: inout Bool,
        finishedToolCalls: inout Set<String>,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) throws(DoMoError) {
        func yield(_ kind: ProviderEvent.Kind, _ payload: JSONValue = .null) {
            continuation.yield(ProviderEvent(kind: kind, payload: payload, sequence: sequence))
            sequence += 1
        }

        func responsePayload(_ payload: JSONValue) -> JSONValue {
            payload["response"] ?? payload
        }

        func toolIdentity(_ payload: JSONValue, item: JSONValue? = nil) -> String? {
            payload["call_id"]?.stringValue
                ?? payload["callId"]?.stringValue
                ?? payload["item_id"]?.stringValue
                ?? item?["call_id"]?.stringValue
                ?? item?["id"]?.stringValue
        }

        switch frame {
        case .done:
            guard !ended else { return }
            ended = true
            yield(.messageEnd, ["source": "done", "stopReason": "done"])
        case .data(let data):
            guard let payload = try? JSONValue(parsing: data) else {
                throw DoMoError(.malformedResponse, "OpenAI Responses SSE event was not valid JSON")
            }
            let type = payload["type"]?.stringValue ?? "unknown"
            switch type {
            case "response.created":
                let response = responsePayload(payload)
                yield(.messageStart, [
                    "responseId": response["id"] ?? payload["response_id"] ?? .null,
                    "model": response["model"] ?? .null,
                    "response": response,
                ])
            case "response.output_text.delta":
                yield(.textDelta, [
                    "delta": payload["delta"] ?? .string(""),
                    "outputIndex": payload["output_index"] ?? .null,
                    "contentIndex": payload["content_index"] ?? .null,
                    "itemId": payload["item_id"] ?? .null,
                ])
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                yield(.reasoningDelta, [
                    "delta": payload["delta"] ?? .string(""),
                    "outputIndex": payload["output_index"] ?? .null,
                    "contentIndex": payload["content_index"] ?? .null,
                    "itemId": payload["item_id"] ?? .null,
                ])
            case "response.output_item.added":
                let item = payload["item"] ?? .null
                if item["type"]?.stringValue == "function_call" {
                    yield(.toolCallDelta, [
                        "phase": "start",
                        "id": item["call_id"] ?? item["id"] ?? .null,
                        "name": item["name"] ?? .null,
                        "item": item,
                    ])
                } else {
                    yield(.unknown, payload)
                }
            case "response.function_call_arguments.delta":
                yield(.toolCallDelta, [
                    "phase": "delta",
                    "id": .string(toolIdentity(payload) ?? ""),
                    "delta": payload["delta"] ?? .string(""),
                    "itemId": payload["item_id"] ?? .null,
                ])
            case "response.function_call_arguments.done":
                let id = toolIdentity(payload) ?? ""
                if !id.isEmpty { finishedToolCalls.insert(id) }
                yield(.toolCallDelta, [
                    "phase": "end",
                    "id": .string(id),
                    "name": payload["name"] ?? .null,
                    "arguments": payload["arguments"] ?? .string(""),
                ])
            case "response.output_item.done":
                let item = payload["item"] ?? .null
                guard item["type"]?.stringValue == "function_call" else {
                    yield(.unknown, payload)
                    return
                }
                let id = toolIdentity(payload, item: item) ?? ""
                guard !id.isEmpty, !finishedToolCalls.contains(id) else { return }
                finishedToolCalls.insert(id)
                yield(.toolCallDelta, [
                    "phase": "end",
                    "id": .string(id),
                    "name": item["name"] ?? .null,
                    "arguments": item["arguments"] ?? .string(""),
                    "item": item,
                ])
            case "response.usage":
                yield(.usage, payload["usage"] ?? payload)
            case "response.completed", "response.incomplete":
                guard !ended else { return }
                let response = responsePayload(payload)
                if let usage = response["usage"] { yield(.usage, usage) }
                ended = true
                yield(.messageEnd, [
                    "response": response,
                    "stopReason": payload["type"]?.stringValue == "response.incomplete"
                        ? .string("incomplete")
                        : .string("completed"),
                ])
            case "response.failed", "error":
                let errorPayload = payload["error"] ?? responsePayload(payload)
                let message = errorPayload["message"]?.stringValue ?? "OpenAI Responses provider returned an error"
                yield(.error, payload)
                throw DoMoError(
                    .provider(status: nil, isRetryable: false),
                    Redaction.diagnostic(message)
                )
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
            // Preserve the response status and bounded body as the primary error.
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
        return DoMoError(.provider(status: status, isRetryable: retryable), "OpenAI Responses provider request failed")
    }
}
