// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/api/openai-completions.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The streaming loop's shape (establish, read head, drive the assembler over
// SSE frames, honor `[DONE]`, sniff mid-stream errors under a committed 200) is
// ported from `packages/ai/src/api/openai-completions.ts`. The error-body
// classifier ports the pattern tables from `packages/ai/src/utils/overflow.ts`
// and `packages/ai/src/utils/retry.ts`; the retry/backoff shape ports
// `retryAssistantCall` from `packages/ai/src/utils/retry.ts`.

import DoMoCore
import Foundation
import HTTPTypes

// MARK: - Response metadata

/// What the initial response header block said, surfaced before the first event.
///
/// LiteLLM writes these at stream open, so they are readable without draining the
/// body. ``attemptedFallbacks`` is the one that changes behavior: a non-zero
/// value means a fallback fired and the model that answered is *not* the one
/// requested. A UI that reports the requested model in that case is lying, so
/// this rides out to the caller ahead of any content.
public struct ResponseMetadata: Sendable, Hashable {
    public var status: Int

    /// Every response header, keys lowercased. The named accessors below cover
    /// the ones with defined meaning; the rest are kept for diagnostics.
    public var headers: [String: String]

    /// `x-litellm-call-id`, for correlating with the proxy's own logs.
    public var callID: String?

    /// `x-litellm-model-id`, the concrete deployment that served the request.
    public var modelID: String?

    /// `x-litellm-attempted-fallbacks`. Greater than zero means a different model
    /// answered than was asked for.
    public var attemptedFallbacks: Int?

    /// A server-requested retry delay, if the head carried one.
    public var retryAfter: Duration?

    public init(
        status: Int,
        headers: [String: String] = [:],
        callID: String? = nil,
        modelID: String? = nil,
        attemptedFallbacks: Int? = nil,
        retryAfter: Duration? = nil
    ) {
        self.status = status
        self.headers = headers
        self.callID = callID
        self.modelID = modelID
        self.attemptedFallbacks = attemptedFallbacks
        self.retryAfter = retryAfter
    }

    /// True when a fallback fired and a different model answered.
    public var fellBack: Bool { (attemptedFallbacks ?? 0) > 0 }

    init(head: HTTPResponse) {
        var headers: [String: String] = [:]
        for field in head.headerFields {
            headers[field.name.canonicalName] = field.value
        }
        self.init(
            status: head.status.code,
            headers: headers,
            callID: head.headerValue("x-litellm-call-id"),
            modelID: head.headerValue("x-litellm-model-id"),
            attemptedFallbacks: head.headerValue("x-litellm-attempted-fallbacks").flatMap(Int.init),
            retryAfter: LiteLLMClient.retryAfter(from: head)
        )
    }
}

// MARK: - Client

/// The LiteLLM completion client.
///
/// One backend, one wire API. There is deliberately no provider parameter: model
/// breadth is the gateway's job, and the ``StreamingTransport`` seam exists for
/// test injection and an eventual `URLSession` swap, not for a second API.
public struct LiteLLMClient: Sendable {

    /// Client configuration. Everything the transport and retry loop need, and
    /// nothing that belongs to a single call.
    public struct Configuration: Sendable {
        /// Proxy base URL. LiteLLM's default port is 4000, not 8000.
        public var baseURL: String

        /// The virtual key. `nil` sends no auth header, which a local unsecured
        /// proxy accepts.
        public var apiKey: String?

        /// The auth header *name*. Operators can set `litellm_key_header_name`, so
        /// this is configurable rather than hardcoded to `Authorization`.
        public var authHeaderName: String

        /// The scheme prefix. Stays `Bearer` even when the header name changes.
        public var authScheme: String

        /// Client-side retry attempts after the initial call. `0` disables retry.
        public var maxRetries: Int

        /// First backoff delay; each further attempt doubles it before jitter.
        public var baseRetryDelay: Duration

        /// Backoff ceiling. Also caps a server-supplied `retry-after`, so a
        /// hostile or mistaken header cannot freeze the client on a long sleep.
        public var maxRetryDelay: Duration

        /// Overall per-request deadline. `nil` uses the transport's default.
        public var timeout: Duration?

        /// The backoff sleeper, injectable so tests do not pay real wall-clock
        /// time. Throwing (e.g. on cancellation) aborts the retry.
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(
            baseURL: String = "http://localhost:4000/v1",
            apiKey: String? = nil,
            authHeaderName: String = "Authorization",
            authScheme: String = "Bearer",
            maxRetries: Int = 3,
            baseRetryDelay: Duration = .milliseconds(500),
            maxRetryDelay: Duration = .seconds(60),
            timeout: Duration? = nil,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.authHeaderName = authHeaderName
            self.authScheme = authScheme
            self.maxRetries = maxRetries
            self.baseRetryDelay = baseRetryDelay
            self.maxRetryDelay = maxRetryDelay
            self.timeout = timeout
            self.sleep = sleep
        }
    }

    public let configuration: Configuration
    private let transport: any StreamingTransport

    public init(
        configuration: Configuration = Configuration(),
        transport: any StreamingTransport = AsyncHTTPClientTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: Streaming completion

    /// Streams a completion as ``AssemblyEvent``s.
    ///
    /// The stream always ends in a terminal event carrying an ``AssistantMessage``
    /// — `.done` for a clean turn, `.failed` for one that ended in a way the loop
    /// must not treat as an answer, including a mid-stream error frame under a
    /// committed 200 and a body that stopped before its `finish_reason`. A
    /// *pre-stream* failure that exhausts retries — a bad status, a connection
    /// that never delivered a head — is thrown from the stream instead, because
    /// there is no partial content to preserve and the precise ``DoMoError/Kind``
    /// (authentication, context overflow, quota) must survive to the caller
    /// rather than collapse into a generic provider error.
    ///
    /// Cancelling the consuming task aborts the HTTP request through the
    /// transport's stream and yields a final aborted message; it does not leak the
    /// socket and does not retry.
    ///
    /// `onResponse` fires once, after retries resolve to a 2xx, with the initial
    /// header block — the only place ``ResponseMetadata/attemptedFallbacks`` is
    /// visible.
    public func streamCompletion(
        model: String,
        context: Context,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        toolChoice: WireToolChoice? = nil,
        rates: ModelCostRates? = nil,
        onResponse: (@Sendable (ResponseMetadata) -> Void)? = nil
    ) -> AsyncThrowingStream<AssemblyEvent, any Error> {
        let built: (request: HTTPRequest, body: [UInt8])
        do {
            built = try buildRequest(
                model: model,
                context: context,
                stream: true,
                temperature: temperature,
                maxTokens: maxTokens,
                reasoningEffort: reasoningEffort,
                toolChoice: toolChoice
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                await produceStream(
                    request: built.request,
                    body: built.body,
                    model: model,
                    rates: rates,
                    onResponse: onResponse,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent
    private func produceStream(
        request: HTTPRequest,
        body: [UInt8],
        model: String,
        rates: ModelCostRates?,
        onResponse: (@Sendable (ResponseMetadata) -> Void)?,
        continuation: AsyncThrowingStream<AssemblyEvent, any Error>.Continuation
    ) async {
        let assembly = StreamingAssembly(model: model, rates: rates)
        var attempt = 0

        while true {
            let response: StreamingResponse
            do {
                response = try await transport.execute(
                    request: request,
                    body: body,
                    timeout: configuration.timeout
                )
            } catch let error where DoMoError.isCancellation(error) {
                finishAborted(assembly, continuation)
                return
            } catch {
                let classified = Self.classifyTransport(error)
                if classified.isRetryable, attempt < configuration.maxRetries {
                    attempt += 1
                    guard await sleepBeforeRetry(attempt: attempt, retryAfter: classified.retryAfter) else {
                        finishAborted(assembly, continuation)
                        return
                    }
                    continue
                }
                continuation.finish(throwing: classified)
                return
            }

            let status = response.head.status.code
            if !(200..<300).contains(status) {
                let bodyText = await Self.collectBody(response.body, cap: Self.errorBodyByteCap)
                let error = Self.classify(status: status, head: response.head, body: bodyText)
                if error.isRetryable, attempt < configuration.maxRetries {
                    attempt += 1
                    guard await sleepBeforeRetry(attempt: attempt, retryAfter: error.retryAfter) else {
                        finishAborted(assembly, continuation)
                        return
                    }
                    continue
                }
                continuation.finish(throwing: error)
                return
            }

            // A 2xx commits us to a stream: no more retries. A failure now keeps
            // whatever content arrived rather than replaying it.
            onResponse?(ResponseMetadata(head: response.head))
            do {
                try await consumeSSE(response.body, into: assembly, continuation: continuation)
                continuation.finish()
            } catch let error where DoMoError.isCancellation(error) {
                finishAborted(assembly, continuation)
            } catch {
                for event in assembly.fail(Self.classifyTransport(error)) { continuation.yield(event) }
                continuation.finish()
            }
            return
        }
    }

    /// Drives the SSE decoder over the body and folds each frame into the
    /// assembler. `[DONE]` and body-end both close the turn through
    /// ``StreamingAssembly/finish()``; an error frame or an undecodable frame
    /// fails it in place, keeping earlier content.
    private func consumeSSE(
        _ body: AsyncThrowingStream<[UInt8], any Error>,
        into assembly: StreamingAssembly,
        continuation: AsyncThrowingStream<AssemblyEvent, any Error>.Continuation
    ) async throws {
        let decoder = SSEByteDecoder()
        var sawDone = false

        func process(_ frames: [SSEFrame]) {
            for frame in frames {
                switch frame {
                case .done:
                    sawDone = true
                case .data(let payload):
                    if let wireError = WireErrorEnvelope.sniff(sseData: payload) {
                        for event in assembly.fail(wireError) { continuation.yield(event) }
                    } else {
                        do {
                            let chunk = try ChatCompletionChunk.decode(sseData: payload)
                            for event in assembly.ingest(chunk) { continuation.yield(event) }
                        } catch {
                            for event in assembly.fail(error) { continuation.yield(event) }
                        }
                    }
                }
                if sawDone || assembly.isTerminated { break }
            }
        }

        for try await chunk in body {
            try Task.checkCancellation()
            process(await decoder.consume(chunk))
            if sawDone || assembly.isTerminated { break }
        }
        // The byte stream finishing (rather than throwing) on cancellation would
        // otherwise read as a clean end-of-stream; this makes cancellation win.
        try Task.checkCancellation()

        if !assembly.isTerminated {
            process(await decoder.finish())
        }
        if !assembly.isTerminated {
            for event in assembly.finish() { continuation.yield(event) }
        }
    }

    // MARK: Non-streaming completion

    /// Runs a completion without streaming and returns the finished message.
    ///
    /// Shares the streaming path's retry and classification. A pre-stream failure
    /// that exhausts retries is thrown; a 2xx body is assembled leniently via
    /// ``AssistantMessage/init(response:model:rates:)``, so a provider `error`
    /// inside a 200 becomes a message whose ``AssistantMessage/failure`` the
    /// caller inspects.
    @concurrent
    public func complete(
        model: String,
        context: Context,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        toolChoice: WireToolChoice? = nil,
        rates: ModelCostRates? = nil,
        onResponse: (@Sendable (ResponseMetadata) -> Void)? = nil
    ) async throws -> AssistantMessage {
        let built = try buildRequest(
            model: model,
            context: context,
            stream: false,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            toolChoice: toolChoice
        )

        var attempt = 0
        while true {
            let response: StreamingResponse
            do {
                response = try await transport.execute(
                    request: built.request,
                    body: built.body,
                    timeout: configuration.timeout
                )
            } catch let error where DoMoError.isCancellation(error) {
                throw DoMoError(.cancelled, "Request was aborted", cause: error)
            } catch {
                let classified = Self.classifyTransport(error)
                if classified.isRetryable, attempt < configuration.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, retryAfter: classified.retryAfter)
                    continue
                }
                throw classified
            }

            let status = response.head.status.code
            let bodyText = await Self.collectBody(response.body, cap: Self.responseBodyByteCap)
            if !(200..<300).contains(status) {
                let error = Self.classify(status: status, head: response.head, body: bodyText)
                if error.isRetryable, attempt < configuration.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, retryAfter: error.retryAfter)
                    continue
                }
                throw error
            }

            onResponse?(ResponseMetadata(head: response.head))
            let decoded: ChatCompletionResponse
            do {
                decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(bodyText.utf8))
            } catch {
                throw DoMoError(
                    .malformedResponse,
                    "Could not decode completion response: \(DoMoError.truncating(bodyText, to: 512))",
                    cause: error
                )
            }
            return AssistantMessage(response: decoded, model: model, rates: rates)
        }
    }

    // MARK: Model catalog

    /// Lists the proxy's advertised model aliases.
    ///
    /// Not retried and tolerant of a partial or malformed list: the catalog is
    /// advisory (a wildcard-configured proxy answers non-exhaustively), and a
    /// completion never depends on a model appearing here — see
    /// ``ModelCatalog/permits(_:)``.
    @concurrent
    public func listModels() async throws -> ModelCatalog {
        let url = try endpointURL("models")
        var request = HTTPRequest(method: .get, url: url)
        applyHeaders(&request, accept: "application/json", contentType: nil)

        let response = try await transport.execute(
            request: request,
            body: nil,
            timeout: configuration.timeout
        )
        let bodyText = await Self.collectBody(response.body, cap: Self.responseBodyByteCap)
        let status = response.head.status.code
        guard (200..<300).contains(status) else {
            throw Self.classify(status: status, head: response.head, body: bodyText)
        }

        do {
            let list = try JSONDecoder().decode(ModelListResponse.self, from: Data(bodyText.utf8))
            return ModelCatalog(models: list.data)
        } catch {
            throw DoMoError(.malformedResponse, "Could not decode /models response", cause: error)
        }
    }

    // MARK: Request building

    private func buildRequest(
        model: String,
        context: Context,
        stream: Bool,
        temperature: Double?,
        maxTokens: Int?,
        reasoningEffort: ReasoningEffort?,
        toolChoice: WireToolChoice?
    ) throws -> (request: HTTPRequest, body: [UInt8]) {
        let chatRequest = ChatCompletionRequest(
            model: model,
            context: context,
            stream: stream,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            toolChoice: toolChoice
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(chatRequest)
        } catch {
            throw DoMoError(.configuration, "Could not encode request body", cause: error)
        }

        let url = try endpointURL("chat/completions")
        var request = HTTPRequest(method: .post, url: url)
        applyHeaders(
            &request,
            accept: stream ? "text/event-stream" : "application/json",
            contentType: "application/json"
        )
        return (request, Array(body))
    }

    private func endpointURL(_ path: String) throws -> URL {
        var base = configuration.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(path)") else {
            throw DoMoError(.configuration, "Invalid base URL: \(configuration.baseURL)")
        }
        return url
    }

    private func applyHeaders(_ request: inout HTTPRequest, accept: String, contentType: String?) {
        if let contentType {
            request.headerFields[.contentType] = contentType
        }
        request.headerFields[.accept] = accept
        if let apiKey = configuration.apiKey, !apiKey.isEmpty,
            let name = HTTPField.Name(configuration.authHeaderName)
        {
            let value = configuration.authScheme.isEmpty
                ? apiKey
                : "\(configuration.authScheme) \(apiKey)"
            request.headerFields[name] = value
        }
    }

    // MARK: Retry timing

    /// Sleeps the backoff for `attempt`, returning `false` if the sleep was
    /// interrupted (cancellation) so the caller can terminate as aborted.
    private func sleepBeforeRetry(attempt: Int, retryAfter: Duration?) async -> Bool {
        do {
            try await backoff(attempt: attempt, retryAfter: retryAfter)
            return true
        } catch {
            return false
        }
    }

    /// Exponential backoff with jitter, or the server-requested delay when one
    /// was supplied. A `retry-after` is used as given (capped), without jitter,
    /// because the server named a specific time; only the client's own guess is
    /// jittered, to spread a thundering herd of retried requests.
    private func backoff(attempt: Int, retryAfter: Duration?) async throws {
        let delay: Duration
        if let retryAfter {
            delay = min(retryAfter, configuration.maxRetryDelay)
        } else {
            let shift = min(max(0, attempt - 1), 30)
            let scaled = configuration.baseRetryDelay * Double(1 << shift)
            let capped = min(scaled, configuration.maxRetryDelay)
            delay = capped * Double.random(in: 0.5...1.0)
        }
        try await configuration.sleep(delay)
    }

    // MARK: Body collection

    /// The cap on a non-2xx error body, in bytes. Provider error pages can be an
    /// entire HTML document; enough is read to classify and display.
    static let errorBodyByteCap = 16_384

    /// The cap on a 2xx non-streaming body. Completions are small; a runaway body
    /// is a malformed response, not a large one.
    static let responseBodyByteCap = 4_194_304

    /// Reads up to `cap` bytes of a body stream into a string, then stops.
    ///
    /// Breaking early on a bounded read leaves the stream partially consumed,
    /// which fires its termination handler and aborts the underlying request —
    /// the right thing for an oversized error page.
    private static func collectBody(_ body: AsyncThrowingStream<[UInt8], any Error>, cap: Int) async -> String {
        var bytes: [UInt8] = []
        do {
            for try await chunk in body {
                bytes.append(contentsOf: chunk)
                if bytes.count >= cap { break }
            }
        } catch {
            // A truncated error body is still worth classifying on what arrived.
        }
        if bytes.count > cap { bytes.removeLast(bytes.count - cap) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Termination helpers

    private func finishAborted(
        _ assembly: StreamingAssembly,
        _ continuation: AsyncThrowingStream<AssemblyEvent, any Error>.Continuation
    ) {
        for event in assembly.abort() { continuation.yield(event) }
        continuation.finish()
    }
}

// MARK: - Error classification

extension LiteLLMClient {
    /// Classifies a non-2xx HTTP response into the error taxonomy.
    ///
    /// The single place a status and error body become a ``DoMoError/Kind``, so
    /// the rest of the client only decides retry timing. The body is consulted
    /// because the status alone is ambiguous where it matters most: a 429 is a
    /// throttle to wait out *or* an exhausted budget to stop on, and a 400 or 413
    /// may be a context overflow that compaction fixes rather than a generic
    /// refusal. Overflow is checked first because it can arrive under several
    /// statuses and overrides them.
    static func classify(status: Int, head: HTTPResponse, body: String) -> DoMoError {
        let wireError = extractWireError(from: body)
        let matchText = wireError?.summary ?? body
        let message: String
        if let wireError {
            message = wireError.summary
        } else if !body.isEmpty {
            message = DoMoError.truncating(body)
        } else {
            message = "HTTP \(status)"
        }

        if LiteLLMErrorPatterns.isContextOverflow(matchText) {
            return DoMoError(.contextOverflow, message)
        }

        switch status {
        case 401, 403:
            return DoMoError(.authentication, message)
        case 402:
            return DoMoError(.quotaExhausted, message)
        case 429:
            if LiteLLMErrorPatterns.isQuotaLimit(matchText) {
                return DoMoError(.quotaExhausted, message)
            }
            return DoMoError(.rateLimit(retryAfter: retryAfter(from: head)), message)
        default:
            if LiteLLMErrorPatterns.isQuotaLimit(matchText) {
                return DoMoError(.quotaExhausted, message)
            }
            let retryable =
                DoMoError.isRetryableStatus(status) || LiteLLMErrorPatterns.isRetryableBody(matchText)
            return DoMoError(.provider(status: status, isRetryable: retryable), message)
        }
    }

    /// Classifies a thrown transport error. Cancellation wins; a `DoMoError`
    /// keeps its kind; anything else is transport (and therefore retryable).
    static func classifyTransport(_ error: any Error) -> DoMoError {
        if DoMoError.isCancellation(error) {
            return DoMoError(.cancelled, "Request was aborted", cause: error)
        }
        if let domo = error as? DoMoError {
            return domo
        }
        return DoMoError(.transport, DoMoError.truncating(String(describing: error)), cause: error)
    }

    /// Parses the two retry-after headers LiteLLM may send, millisecond spelling
    /// preferred, via ``DoMoError/parseRetryAfter(retryAfter:retryAfterMilliseconds:now:)``.
    static func retryAfter(from head: HTTPResponse) -> Duration? {
        DoMoError.parseRetryAfter(
            retryAfter: head.headerValue("retry-after") ?? head.headerValue("llm_provider-retry-after"),
            retryAfterMilliseconds: head.headerValue("retry-after-ms")
        )
    }

    /// Pulls a ``WireError`` out of an error body, trying the shapes LiteLLM uses:
    /// a bare `{"error": {...}}`, a full response object carrying `error`, and a
    /// top-level error object.
    static func extractWireError(from body: String) -> WireError? {
        if let error = WireErrorEnvelope.sniff(sseData: body) {
            return error
        }
        let data = Data(body.utf8)
        if let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
            let error = response.error
        {
            return error
        }
        if let error = try? JSONDecoder().decode(WireError.self, from: data),
            error.message != nil || error.type != nil || error.code != nil
        {
            return error
        }
        return nil
    }
}

// MARK: - Pattern tables

/// The provider-wording classifiers, ported verbatim from pi.
///
/// LiteLLM normalizes many upstreams but does not normalize their *prose*: an
/// exhausted budget, a transient overload, and a context overflow all arrive as
/// text, and the only way to tell a 429-to-wait-out from a 429-to-stop-on is to
/// read it. The pattern lists are pi's, joined into one alternation each exactly
/// as `buildProviderErrorPattern` does, matched case-insensitively.
enum LiteLLMErrorPatterns {
    /// `packages/ai/src/utils/overflow.ts` OVERFLOW_PATTERNS.
    static let overflow = [
        #"prompt is too long"#,
        #"request_too_large"#,
        #"input is too long for requested model"#,
        #"exceeds the context window"#,
        #"exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))"#,
        #"input token count.*exceeds the maximum"#,
        #"maximum prompt length is \d+"#,
        #"reduce the length of the messages"#,
        #"maximum context length is \d+ tokens"#,
        #"exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?"#,
        #"input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)"#,
        #"exceeds the limit of \d+"#,
        #"exceeds the available context size"#,
        #"greater than the context length"#,
        #"context window exceeds limit"#,
        #"exceeded model token limit"#,
        #"too large for model with \d+ maximum context length"#,
        #"prompt has [\d,]+ tokens?, but the configured context size is [\d,]+ tokens?"#,
        #"model_context_window_exceeded"#,
        #"prompt too long; exceeded (?:max )?context length"#,
        #"range of input length should be"#,
        #"context[_ ]length[_ ]exceeded"#,
        #"too many tokens"#,
        #"token limit exceeded"#,
        #"^4(?:00|13)\s*(?:status code)?\s*\(no body\)"#,
    ].joined(separator: "|")

    /// `packages/ai/src/utils/overflow.ts` NON_OVERFLOW_PATTERNS. Wording that
    /// looks like overflow but is really throttling; it vetoes an overflow match.
    static let nonOverflow = [
        #"^(Throttling error|Service unavailable):"#,
        #"rate limit"#,
        #"too many requests"#,
    ].joined(separator: "|")

    /// `packages/ai/src/utils/retry.ts` RETRYABLE_PROVIDER_ERROR_PATTERN.
    static let retryable = [
        #"overloaded"#, #"rate.?limit"#, #"too many requests"#,
        #"429"#, #"500"#, #"502"#, #"503"#, #"504"#, #"524"#,
        #"service.?unavailable"#, #"server.?error"#, #"internal.?error"#,
        #"provider.?returned.?error"#,
        #"network.?error"#, #"connection.?error"#, #"connection.?refused"#, #"connection.?lost"#,
        #"other side closed"#, #"fetch failed"#, #"getaddrinfo"#, #"ENOTFOUND"#, #"EAI_AGAIN"#,
        #"upstream.?connect"#, #"reset before headers"#, #"socket hang up"#,
        #"socket connection was closed"#, #"timed? out"#, #"timeout"#, #"terminated"#,
        #"websocket.?closed"#, #"websocket.?error"#,
        #"ended without"#, #"stream ended before message_stop"#,
        #"stream ended before a terminal response event"#,
        #"http2 request did not get a response"#,
        #"retry delay"#,
        #"you can retry your request"#, #"try your request again"#, #"please retry your request"#,
        #"ResourceExhausted"#,
    ].joined(separator: "|")

    /// `packages/ai/src/utils/retry.ts` NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN.
    static let quotaLimit = [
        #"GoUsageLimitError"#, #"FreeUsageLimitError"#,
        #"Monthly usage limit reached"#, #"available balance"#,
        #"insufficient_quota"#, #"out of budget"#, #"quota exceeded"#, #"billing"#,
    ].joined(separator: "|")

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Text overflow detection: an overflow phrase, unless a throttling phrase
    /// vetoes it. The usage-based cases pi also handles (silent overflow, a
    /// length-stop with zero output) need token counts and belong to the layer
    /// holding the ``AssistantMessage``, not to HTTP classification.
    static func isContextOverflow(_ text: String) -> Bool {
        !matches(text, nonOverflow) && matches(text, overflow)
    }

    static func isQuotaLimit(_ text: String) -> Bool { matches(text, quotaLimit) }

    static func isRetryableBody(_ text: String) -> Bool { matches(text, retryable) }
}
