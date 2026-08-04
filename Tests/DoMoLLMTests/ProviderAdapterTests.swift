// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoLLM
import Foundation
import HTTPTypes
import Synchronization
import Testing

@Suite("Provider adapters")
struct ProviderAdapterTests {
    @Test("LiteLLM adapter maps the existing assembly to provider events")
    func liteLLMNormalization() async {
        let transport = FixtureTransport(
            status: 200,
            chunks: [
                Array("data: {\"id\":\"chat-1\",\"model\":\"model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}\n\n".utf8),
                Array("data: {\"id\":\"chat-1\",\"model\":\"model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8),
            ]
        )
        let client = LiteLLMClient(
            configuration: LiteLLMClient.Configuration(baseURL: "http://localhost:4000/v1"),
            transport: transport
        )
        let adapter = LiteLLMProviderAdapter(
            profile: ProviderProfile(
                id: "gateway",
                displayName: "Gateway",
                adapterID: "litellm",
                endpoint: "http://localhost:4000/v1",
                capabilities: ["chat", "streaming"]
            ),
            client: client
        )

        var events: [ProviderEvent] = []
        do {
            for try await event in adapter.stream(ProviderRequest(
                model: "model",
                messages: [ProviderMessage(role: .user, content: "hello")]
            )) {
                events.append(event)
            }
        } catch {
            Issue.record("unexpected adapter error: \(error)")
        }
        #expect(events.map(\.kind).contains(.messageStart))
        #expect(events.map(\.kind).contains(.textDelta))
        #expect(events.map(\.kind).contains(.messageEnd))
        #expect(events.first(where: { $0.kind == .textDelta })?.payload["delta"]?.stringValue == "hello")
    }

    @Test("Anthropic adapter preserves lenient SSE event payloads and tool deltas")
    func anthropicMessagesNormalization() async throws {
        let transport = FixtureTransport(
            status: 200,
            chunks: [Array([
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\"}}\n\n",
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"lookup\"}}\n\n",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"key\\\":\\\"value\\\"}\"}}\n\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n",
                "data: {\"type\":\"message_stop\"}\n\n",
            ].joined().utf8)]
        )
        let adapter = AnthropicMessagesProviderAdapter(
            profile: ProviderProfile(
                id: "anthropic",
                displayName: "Anthropic",
                adapterID: "anthropic-messages",
                endpoint: "https://api.anthropic.com/v1",
                defaultModel: "claude-test",
                credential: ProviderCredentialReference(name: "ANTHROPIC_API_KEY"),
                capabilities: ["messages", "tools"]
            ),
            credential: "secret-value",
            transport: transport
        )

        var events: [ProviderEvent] = []
        for try await event in adapter.stream(ProviderRequest(
            model: "claude-test",
            messages: [ProviderMessage(role: .user, content: "find it")],
            tools: [ProviderTool(name: "lookup", inputSchema: ["type": "object"])]
        )) {
            events.append(event)
        }
        #expect(events.map(\.kind).contains(.messageStart))
        #expect(events.map(\.kind).contains(.toolCallDelta))
        #expect(events.map(\.kind).contains(.usage))
        #expect(events.map(\.kind).filter { $0 == .messageEnd }.count == 2)
        let bodyData = try #require(transport.lastBody)
        let body = try JSONValue(parsing: Data(bodyData))
        #expect(body["system"] == nil)
        #expect(body["tools"]?[0]?["name"]?.stringValue == "lookup")
        #expect(transport.lastRequest?.headerFields[HTTPField.Name("x-api-key")!] == "secret-value")
    }

    @Test("Anthropic adapter classifies model-not-found without a retry")
    func anthropicNotFound() async {
        let adapter = AnthropicMessagesProviderAdapter(
            profile: ProviderProfile(
                id: "anthropic",
                displayName: "Anthropic",
                adapterID: "anthropic-messages",
                endpoint: "https://api.anthropic.com/v1",
                defaultModel: "claude-test"
            ),
            credential: nil,
            transport: FixtureTransport(status: 404, chunks: [Array("model not found".utf8)])
        )
        var error: DoMoError?
        do {
            for try await _ in adapter.stream(ProviderRequest(model: "claude-test", messages: [])) {}
        } catch let thrown as DoMoError {
            error = thrown
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(error?.isRetryable == false)
        if case .provider(let status, let retryable)? = error?.kind {
            #expect(status == 404)
            #expect(retryable == false)
        } else {
            Issue.record("expected provider 404 classification")
        }
    }
}

private final class FixtureTransport: StreamingTransport {
    private let status: Int
    private let chunks: [[UInt8]]
    private let state = Mutex((request: nil as HTTPRequest?, body: nil as [UInt8]?))

    init(status: Int, chunks: [[UInt8]]) {
        self.status = status
        self.chunks = chunks
    }

    var lastRequest: HTTPRequest? { state.withLock { $0.request } }
    var lastBody: [UInt8]? { state.withLock { $0.body } }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        state.withLock {
            $0.request = request
            $0.body = body
        }
        var head = HTTPResponse(status: .init(code: status))
        if status == 404, let field = HTTPField.Name("content-type") {
            head.headerFields.append(HTTPField(name: field, value: "text/plain"))
        }
        let chunks = chunks
        return StreamingResponse(
            head: head,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }
}
