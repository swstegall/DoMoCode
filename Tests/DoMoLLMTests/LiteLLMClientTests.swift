// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import HTTPTypes
import Synchronization
import Testing

import DoMoLLM

// MARK: - Fixtures

private func sseFrame(_ payload: String) -> [UInt8] {
    Array("data: \(payload)\n\n".utf8)
}

private let doneFrame = Array("data: [DONE]\n\n".utf8)

private let testContext = Context(systemPrompt: "You are helpful.", messages: [.user("hi")])

/// A realistic streamed completion with a two-byte and a four-byte scalar in the
/// content, terminated by `[DONE]`.
private let streamPayloads: [String] = [
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":"Héllo 🌍"},"finish_reason":null}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}"#,
]

private var fullStreamBytes: [UInt8] {
    var bytes: [UInt8] = []
    for payload in streamPayloads { bytes += sseFrame(payload) }
    bytes += doneFrame
    return bytes
}

// MARK: - Test doubles

private struct StubResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var chunks: [[UInt8]]
}

/// Observations a test wants to make about how the transport was driven.
private final class TransportRecorder: Sendable {
    private struct State {
        var executeCount = 0
        var deliveredChunks = 0
        var terminated = false
        var lastRequest: HTTPRequest?
        var lastBody: [UInt8]?
    }
    private let state = Mutex(State())

    func recordExecute(_ request: HTTPRequest, body: [UInt8]?) {
        state.withLock {
            $0.executeCount += 1
            $0.lastRequest = request
            $0.lastBody = body
        }
    }
    func recordDelivered() { state.withLock { $0.deliveredChunks += 1 } }
    func recordTerminated() { state.withLock { $0.terminated = true } }

    var executeCount: Int { state.withLock { $0.executeCount } }
    var deliveredChunks: Int { state.withLock { $0.deliveredChunks } }
    var terminated: Bool { state.withLock { $0.terminated } }
    var lastRequest: HTTPRequest? { state.withLock { $0.lastRequest } }
    var lastBody: [UInt8]? { state.withLock { $0.lastBody } }
}

/// Replays recorded responses. The head is committed immediately; body chunks are
/// yielded one at a time, optionally with a delay so cancellation has a window.
/// The queue is consumed one response per call and its last element is reused,
/// which is how a "fail then succeed" and an "always fail" fixture are both
/// expressed.
private final class StubTransport: StreamingTransport {
    private let responses: Mutex<[StubResponse]>
    let recorder: TransportRecorder
    private let perChunkDelay: Duration?

    init(
        _ responses: [StubResponse],
        recorder: TransportRecorder = TransportRecorder(),
        perChunkDelay: Duration? = nil
    ) {
        self.responses = Mutex(responses)
        self.recorder = recorder
        self.perChunkDelay = perChunkDelay
    }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        recorder.recordExecute(request, body: body)
        let response = responses.withLock { queue -> StubResponse in
            let first = queue.first ?? StubResponse(status: 200, headers: [], chunks: [])
            if queue.count > 1 { queue.removeFirst() }
            return first
        }

        var head = HTTPResponse(status: .init(code: response.status))
        for (name, value) in response.headers {
            guard let fieldName = HTTPField.Name(name) else { continue }
            head.headerFields.append(HTTPField(name: fieldName, value: value))
        }

        let chunks = response.chunks
        let delay = perChunkDelay
        let recorder = self.recorder
        let stream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            let pump = Task {
                do {
                    for chunk in chunks {
                        try Task.checkCancellation()
                        if let delay { try await Task.sleep(for: delay) }
                        continuation.yield(chunk)
                        recorder.recordDelivered()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                recorder.recordTerminated()
            }
        }
        return StreamingResponse(head: head, body: stream)
    }
}

private final class SleepRecorder: Sendable {
    private let delays = Mutex<[Duration]>([])
    func record(_ delay: Duration) { delays.withLock { $0.append(delay) } }
    var count: Int { delays.withLock { $0.count } }
    var recorded: [Duration] { delays.withLock { $0 } }
}

private final class MetadataBox: Sendable {
    private let stored = Mutex<ResponseMetadata?>(nil)
    func set(_ value: ResponseMetadata) { stored.withLock { $0 = value } }
    var value: ResponseMetadata? { stored.withLock { $0 } }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

// MARK: - Helpers

private func makeClient(
    _ transport: any StreamingTransport,
    maxRetries: Int = 3,
    apiKey: String? = "sk-test",
    authHeaderName: String = "Authorization",
    sleepRecorder: SleepRecorder? = nil
) -> LiteLLMClient {
    var config = LiteLLMClient.Configuration(
        baseURL: "http://localhost:4000/v1",
        apiKey: apiKey,
        authHeaderName: authHeaderName,
        maxRetries: maxRetries
    )
    config.sleep = { duration in sleepRecorder?.record(duration) }
    return LiteLLMClient(configuration: config, transport: transport)
}

private func collect(
    _ stream: AsyncThrowingStream<AssemblyEvent, any Error>
) async -> (events: [AssemblyEvent], error: DoMoError?) {
    var events: [AssemblyEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch let error as DoMoError {
        return (events, error)
    } catch {
        return (events, DoMoError(.transport, "unexpected: \(error)"))
    }
}

// MARK: - Streaming happy path

@Suite("LiteLLMClient — streaming")
struct StreamingTests {

    @Test("A realistic stream split at every byte boundary yields the same message")
    func byteBoundaryFullStack() async {
        let bytes = fullStreamBytes
        for split in 1..<bytes.count {
            let chunks = [Array(bytes[0..<split]), Array(bytes[split...])]
            let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
            let (events, error) = await collect(
                makeClient(transport).streamCompletion(model: "gpt-4o-mini", context: testContext)
            )
            #expect(error == nil, "split at \(split) threw \(String(describing: error))")
            let message = events.last?.terminalMessage
            #expect(message?.text == "Héllo 🌍!", "split at \(split): \(String(describing: message?.text))")
            #expect(message?.stopReason == .stop)
            #expect(message?.usage.input == 10)
            #expect(message?.usage.output == 3)
        }
    }

    @Test("Delivering the stream one byte per chunk assembles the same message")
    func oneBytePerChunk() async {
        let chunks = fullStreamBytes.map { [$0] }
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
        let (events, error) = await collect(
            makeClient(transport).streamCompletion(model: "gpt-4o-mini", context: testContext)
        )
        #expect(error == nil)
        #expect(events.last?.terminalMessage?.text == "Héllo 🌍!")
        if case .done = events.last {} else { Issue.record("expected .done") }
    }

    @Test("A stream that ends after finish_reason without [DONE] still completes")
    func missingDone() async {
        let chunks = [
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#)
        ]
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
        let (events, error) = await collect(makeClient(transport).streamCompletion(model: "m", context: testContext))
        #expect(error == nil)
        #expect(events.last?.terminalMessage?.stopReason == .stop)
        #expect(events.last?.terminalMessage?.text == "done")
        if case .done = events.last {} else { Issue.record("expected .done") }
    }

    @Test("A stream that stops before its finish_reason keeps content and fails")
    func truncatedStream() async {
        let chunks = [
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#)
        ]
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
        let (events, error) = await collect(makeClient(transport).streamCompletion(model: "m", context: testContext))
        #expect(error == nil)
        let message = events.last?.terminalMessage
        #expect(message?.text == "partial")
        #expect(message?.stopReason == .error)
        #expect(message?.errorMessage == "Stream ended without finish_reason")
    }

    @Test("A mid-stream error under a committed 200 fails the turn but keeps content")
    func midStreamError() async {
        let chunks = [
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}"#),
            sseFrame(#"{"error":{"message":"litellm.RateLimitError: rate_limit_error","type":"None","code":"429"}}"#),
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}"#),
        ]
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
        let (events, error) = await collect(makeClient(transport).streamCompletion(model: "m", context: testContext))
        #expect(error == nil)
        let message = events.last?.terminalMessage
        // Content that arrived before the error is kept; the frame after it cannot
        // resurrect the turn.
        #expect(message?.text == "Hello")
        #expect(message?.stopReason == .error)
        #expect(message?.errorMessage?.contains("RateLimit") == true)
        if case .failed = events.last {} else { Issue.record("expected .failed") }
    }

    @Test("A tool-call stream assembles the accumulated call")
    func toolCallStream() async {
        let chunks = [
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}"#),
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"README.md\"}"}}]},"finish_reason":null}]}"#),
            sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            doneFrame,
        ]
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: chunks)])
        let (events, error) = await collect(makeClient(transport).streamCompletion(model: "m", context: testContext))
        #expect(error == nil)
        let message = events.last?.terminalMessage
        #expect(message?.stopReason == .toolUse)
        #expect(message?.toolCalls == [ToolCallBlock(id: "call_1", name: "read", arguments: ["path": "README.md"])])
    }
}

// MARK: - Response metadata

@Suite("LiteLLMClient — response metadata")
struct MetadataTests {

    @Test("x-litellm headers surface on the initial response; a fallback is flagged")
    func fallbackHeaders() async {
        let headers = [
            ("x-litellm-call-id", "call-abc"),
            ("x-litellm-model-id", "deployment-7"),
            ("x-litellm-attempted-fallbacks", "2"),
        ]
        let ok = StubResponse(
            status: 200,
            headers: headers,
            chunks: [
                sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#),
                doneFrame,
            ]
        )
        let box = MetadataBox()
        let stream = makeClient(StubTransport([ok])).streamCompletion(
            model: "m",
            context: testContext,
            onResponse: { box.set($0) }
        )
        let (_, error) = await collect(stream)
        #expect(error == nil)
        let meta = box.value
        #expect(meta?.callID == "call-abc")
        #expect(meta?.modelID == "deployment-7")
        #expect(meta?.attemptedFallbacks == 2)
        #expect(meta?.fellBack == true)
    }

    @Test("No fallback header means fellBack is false")
    func noFallback() async {
        let ok = StubResponse(
            status: 200,
            headers: [("x-litellm-call-id", "c1")],
            chunks: [
                sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#),
                doneFrame,
            ]
        )
        let box = MetadataBox()
        _ = await collect(
            makeClient(StubTransport([ok])).streamCompletion(model: "m", context: testContext, onResponse: { box.set($0) })
        )
        #expect(box.value?.fellBack == false)
        #expect(box.value?.attemptedFallbacks == nil)
    }
}

// MARK: - Error classification and retry

@Suite("LiteLLMClient — errors and retry")
struct ErrorTests {

    @Test("401 is authentication and is not retried")
    func authError() async {
        let sleep = SleepRecorder()
        let transport = StubTransport(
            [StubResponse(status: 401, headers: [], chunks: [Array(#"{"error":{"message":"invalid api key","code":"401"}}"#.utf8)])]
        )
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 3, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        #expect(error?.kind == .authentication)
        #expect(transport.recorder.executeCount == 1)
        #expect(sleep.count == 0)
    }

    @Test("429 without quota wording is a rate limit carrying retry-after")
    func rateLimit() async {
        let sleep = SleepRecorder()
        let transport = StubTransport(
            [StubResponse(status: 429, headers: [("retry-after", "2")], chunks: [Array(#"{"error":{"message":"too many requests","code":"429"}}"#.utf8)])]
        )
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 0, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        guard case .rateLimit(let retryAfter) = error?.kind else {
            Issue.record("expected rateLimit, got \(String(describing: error?.kind))")
            return
        }
        #expect(retryAfter == .seconds(2))
        #expect(sleep.count == 0)
    }

    @Test("A retryable 429 sleeps the server-requested delay before retrying")
    func rateLimitHonorsRetryAfter() async {
        let sleep = SleepRecorder()
        let fail = StubResponse(status: 429, headers: [("retry-after", "3")], chunks: [Array(#"{"error":{"message":"slow down"}}"#.utf8)])
        let ok = StubResponse(
            status: 200,
            headers: [],
            chunks: [sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#), doneFrame]
        )
        let transport = StubTransport([fail, ok])
        let (events, error) = await collect(
            makeClient(transport, maxRetries: 3, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        #expect(error == nil)
        #expect(events.last?.terminalMessage?.text == "ok")
        #expect(sleep.recorded == [.seconds(3)])
        #expect(transport.recorder.executeCount == 2)
    }

    @Test("429 with quota wording is quotaExhausted and is not retried")
    func quotaExhausted() async {
        let sleep = SleepRecorder()
        let transport = StubTransport(
            [StubResponse(status: 429, headers: [("retry-after", "5")], chunks: [Array(#"{"error":{"message":"You exceeded insufficient_quota","code":"insufficient_quota"}}"#.utf8)])]
        )
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 3, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        #expect(error?.kind == .quotaExhausted)
        #expect(error?.isRetryable == false)
        #expect(transport.recorder.executeCount == 1)
        #expect(sleep.count == 0)
    }

    @Test("500 is a retryable provider error and retries up to the budget")
    func serverErrorRetries() async {
        let sleep = SleepRecorder()
        let transport = StubTransport(
            [StubResponse(status: 500, headers: [], chunks: [Array(#"{"error":{"message":"internal server error"}}"#.utf8)])]
        )
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 2, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        guard case .provider(let status, let isRetryable) = error?.kind else {
            Issue.record("expected provider, got \(String(describing: error?.kind))")
            return
        }
        #expect(status == 500)
        #expect(isRetryable)
        #expect(transport.recorder.executeCount == 3)  // initial + 2 retries
        #expect(sleep.count == 2)
    }

    @Test("A retryable status recovers when a later attempt succeeds")
    func retryThenSuccess() async {
        let sleep = SleepRecorder()
        let fail = StubResponse(status: 503, headers: [], chunks: [Array(#"{"error":{"message":"service unavailable"}}"#.utf8)])
        let ok = StubResponse(
            status: 200,
            headers: [],
            chunks: [sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"recovered"},"finish_reason":"stop"}]}"#), doneFrame]
        )
        let transport = StubTransport([fail, ok])
        let (events, error) = await collect(
            makeClient(transport, maxRetries: 3, sleepRecorder: sleep).streamCompletion(model: "m", context: testContext)
        )
        #expect(error == nil)
        #expect(events.last?.terminalMessage?.text == "recovered")
        #expect(transport.recorder.executeCount == 2)
        #expect(sleep.count == 1)
    }

    @Test("A 400 whose body describes context overflow is contextOverflow, not retried")
    func contextOverflow() async {
        let transport = StubTransport(
            [StubResponse(status: 400, headers: [], chunks: [Array(#"{"error":{"message":"This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens","code":"context_length_exceeded"}}"#.utf8)])]
        )
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 3).streamCompletion(model: "m", context: testContext)
        )
        #expect(error?.kind == .contextOverflow)
        #expect(error?.isRetryable == false)
        #expect(transport.recorder.executeCount == 1)
    }

    @Test("A 413 request-too-large is context overflow")
    func requestTooLarge() async {
        let transport = StubTransport(
            [StubResponse(status: 413, headers: [], chunks: [Array(#"{"error":{"type":"request_too_large","message":"Request exceeds the maximum size"}}"#.utf8)])]
        )
        let (_, error) = await collect(makeClient(transport).streamCompletion(model: "m", context: testContext))
        #expect(error?.kind == .contextOverflow)
    }

    @Test("A throttling 429 that mentions tokens is a rate limit, not overflow")
    func throttlingNotOverflow() async {
        // "too many tokens" matches an overflow pattern, but the throttling veto
        // (rate limit / too many requests) must win.
        let transport = StubTransport(
            [StubResponse(status: 429, headers: [], chunks: [Array(#"{"error":{"message":"Too many requests: too many tokens, please wait"}}"#.utf8)])]
        )
        let (_, error) = await collect(makeClient(transport, maxRetries: 0).streamCompletion(model: "m", context: testContext))
        if case .rateLimit = error?.kind {} else {
            Issue.record("expected rateLimit, got \(String(describing: error?.kind))")
        }
    }
}

// MARK: - Cancellation

@Suite("LiteLLMClient — cancellation")
struct CancellationTests {

    @Test("Cancelling the consumer aborts the request instead of leaking it")
    func cancellationAbortsRequest() async throws {
        let payloads = (0..<6).map { index in
            #"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"chunk\#(index) "},"finish_reason":null}]}"#
        }
        let chunks = payloads.map { sseFrame($0) }
        let transport = StubTransport(
            [StubResponse(status: 200, headers: [], chunks: chunks)],
            perChunkDelay: .milliseconds(30)
        )
        let received = Counter()
        let stream = makeClient(transport).streamCompletion(model: "m", context: testContext)

        let task = Task {
            for try await _ in stream { received.increment() }
        }

        var waited = 0
        while received.count < 1 && waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(received.count >= 1, "no event arrived before cancellation")

        task.cancel()
        _ = try? await task.value

        var settle = 0
        while !transport.recorder.terminated && settle < 200 {
            try await Task.sleep(for: .milliseconds(5))
            settle += 1
        }
        #expect(transport.recorder.terminated, "transport request was not aborted")
        #expect(transport.recorder.deliveredChunks < chunks.count, "the whole stream drained despite cancellation")
    }
}

// MARK: - Non-streaming

@Suite("LiteLLMClient — non-streaming")
struct NonStreamingTests {

    @Test("A non-streaming completion returns an assembled message")
    func completeReturnsMessage() async throws {
        let body = #"{"id":"resp-1","object":"chat.completion","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: [Array(body.utf8)])])
        let message = try await makeClient(transport).complete(model: "m", context: testContext)
        #expect(message.text == "answer")
        #expect(message.stopReason == .stop)
        #expect(message.usage.input == 5)
        #expect(message.usage.output == 2)
    }

    @Test("A non-streaming 401 throws authentication")
    func completeAuthError() async {
        let transport = StubTransport([StubResponse(status: 401, headers: [], chunks: [Array(#"{"error":{"message":"bad key"}}"#.utf8)])])
        do {
            _ = try await makeClient(transport, maxRetries: 0).complete(model: "m", context: testContext)
            Issue.record("expected a throw")
        } catch let error as DoMoError {
            #expect(error.kind == .authentication)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("A non-streaming retryable status recovers on a later attempt")
    func completeRetries() async throws {
        let sleep = SleepRecorder()
        let fail = StubResponse(status: 502, headers: [], chunks: [Array(#"{"error":{"message":"bad gateway"}}"#.utf8)])
        let ok = StubResponse(
            status: 200,
            headers: [],
            chunks: [Array(#"{"id":"r","model":"m","choices":[{"index":0,"message":{"content":"hi"},"finish_reason":"stop"}]}"#.utf8)]
        )
        let transport = StubTransport([fail, ok])
        let message = try await makeClient(transport, maxRetries: 3, sleepRecorder: sleep).complete(model: "m", context: testContext)
        #expect(message.text == "hi")
        #expect(transport.recorder.executeCount == 2)
        #expect(sleep.count == 1)
    }
}

// MARK: - Model catalog

@Suite("LiteLLMClient — model catalog")
struct CatalogTests {

    @Test("The catalog lists advertised ids and always permits a free-typed one")
    func listModels() async throws {
        let body = #"{"object":"list","data":[{"id":"gpt-4o","object":"model","owned_by":"openai"},{"id":"claude-sonnet-4","object":"model","owned_by":"openai"},{"not_a_model":true}]}"#
        let transport = StubTransport([StubResponse(status: 200, headers: [], chunks: [Array(body.utf8)])])
        let catalog = try await makeClient(transport).listModels()
        // The malformed row is dropped rather than sinking the list.
        #expect(catalog.ids.sorted() == ["claude-sonnet-4", "gpt-4o"])
        #expect(catalog.contains("gpt-4o"))
        #expect(!catalog.contains("o3-mini"))
        #expect(catalog.permits("o3-mini"))
    }

    @Test("A non-2xx from /models throws rather than returning an empty catalog")
    func listModelsError() async {
        let transport = StubTransport([StubResponse(status: 500, headers: [], chunks: [Array(#"{"error":{"message":"boom"}}"#.utf8)])])
        do {
            _ = try await makeClient(transport).listModels()
            Issue.record("expected a throw")
        } catch is DoMoError {
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

// MARK: - Request shape

@Suite("LiteLLMClient — request shape")
struct RequestShapeTests {

    @Test("The request targets /chat/completions with the configured auth header and SSE accept")
    func requestShape() async {
        let ok = StubResponse(
            status: 200,
            headers: [],
            chunks: [sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#), doneFrame]
        )
        let transport = StubTransport([ok])
        var config = LiteLLMClient.Configuration(
            baseURL: "http://localhost:4000/v1/",
            apiKey: "sk-xyz",
            authHeaderName: "x-litellm-api-key",
            authScheme: "Bearer"
        )
        config.sleep = { _ in }
        let client = LiteLLMClient(configuration: config, transport: transport)
        _ = await collect(client.streamCompletion(model: "m", context: testContext))

        let request = transport.recorder.lastRequest
        #expect(request?.method == .post)
        #expect(request?.url?.absoluteString == "http://localhost:4000/v1/chat/completions")
        let authName = HTTPField.Name("x-litellm-api-key")!
        #expect(request?.headerFields[authName] == "Bearer sk-xyz")
        #expect(request?.headerFields[.accept] == "text/event-stream")
        #expect(request?.headerFields[.contentType] == "application/json")
    }

    @Test("No API key sends no auth header")
    func noAuthHeader() async {
        let ok = StubResponse(
            status: 200,
            headers: [],
            chunks: [sseFrame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#), doneFrame]
        )
        let transport = StubTransport([ok])
        _ = await collect(
            makeClient(transport, apiKey: nil).streamCompletion(model: "m", context: testContext)
        )
        let authName = HTTPField.Name("Authorization")!
        #expect(transport.recorder.lastRequest?.headerFields[authName] == nil)
    }
}

// MARK: - Connection-phase retry budget

/// Throws on `execute` for the first `failures` calls, then serves `then`. A
/// throw models a connection that never produced a response head, which is the
/// case the client caps separately from a mid-stream drop.
private final class ThrowingTransport: StreamingTransport {
    private let remainingFailures: Mutex<Int>
    private let then: StubResponse
    let recorder: TransportRecorder

    init(failures: Int, then: StubResponse = StubResponse(status: 200, headers: [], chunks: []), recorder: TransportRecorder = TransportRecorder()) {
        self.remainingFailures = Mutex(failures)
        self.then = then
        self.recorder = recorder
    }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        recorder.recordExecute(request, body: body)
        let shouldFail = remainingFailures.withLock { count -> Bool in
            if count > 0 { count -= 1; return true }
            return false
        }
        if shouldFail {
            throw DoMoError(.transport, "connection refused")
        }
        let head = HTTPResponse(status: .init(code: then.status))
        return StreamingResponse(head: head, body: AsyncThrowingStream { $0.finish() })
    }
}

@Suite("LiteLLMClient — connection retry budget")
struct ConnectionRetryTests {

    /// A connection that never establishes is capped at one retry regardless of
    /// the transient-error budget, so a down gateway is not waited on four times.
    @Test("An initial-connection failure retries at most once")
    func initialConnectionCappedAtOne() async {
        let recorder = TransportRecorder()
        let transport = ThrowingTransport(failures: .max, recorder: recorder)
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 3).streamCompletion(model: "gpt-4o-mini", context: testContext)
        )
        #expect(error?.kind == .transport)
        #expect(recorder.executeCount == 2, "expected 2 attempts (initial + one retry), got \(recorder.executeCount)")
    }

    /// With retries disabled entirely, the initial connection is tried once.
    @Test("maxRetries 0 means a single connection attempt")
    func zeroRetriesSingleAttempt() async {
        let recorder = TransportRecorder()
        let transport = ThrowingTransport(failures: .max, recorder: recorder)
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 0).streamCompletion(model: "gpt-4o-mini", context: testContext)
        )
        #expect(error?.kind == .transport)
        #expect(recorder.executeCount == 1)
    }

    /// One transient connection blip before the gateway answers still recovers —
    /// the cap is one retry, and that is exactly enough for a proxy mid-restart.
    @Test("A single connection blip recovers")
    func oneBlipRecovers() async {
        let recorder = TransportRecorder()
        let transport = ThrowingTransport(failures: 1, recorder: recorder)
        let (_, error) = await collect(
            makeClient(transport, maxRetries: 3).streamCompletion(model: "gpt-4o-mini", context: testContext)
        )
        #expect(error == nil, "expected recovery, got \(String(describing: error))")
        #expect(recorder.executeCount == 2)
    }
}
