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
        ///
        /// Ten, because the failure this exists for — "the provider is busy" —
        /// is one that clears on its own, and giving up after three tries turns
        /// a provider's bad ninety seconds into a failed turn the user has to
        /// retype. The cost of ten is bounded from three directions: the delay
        /// ceiling (``maxRetryDelay``), the total sleep budget
        /// (``retryDelayBudget``), and the far lower ``maxPreConnectRetries``
        /// for the case where the gateway never answered at all.
        public var maxRetries: Int

        /// First backoff delay; each further attempt doubles it before jitter.
        public var baseRetryDelay: Duration

        /// Backoff ceiling. Also caps a server-supplied `retry-after`, so a
        /// hostile or mistaken header cannot freeze the client on a long sleep.
        public var maxRetryDelay: Duration

        /// Retry budget for a failure that happened *before* any response head
        /// arrived.
        ///
        /// Deliberately far lower than ``maxRetries``, and the reason raising
        /// ``maxRetries`` to ten does not change what a dead gateway costs. A
        /// pre-connect failure is a different animal from a busy provider: there
        /// is no evidence anything is listening, each attempt burns a whole
        /// connect timeout (`AsyncHTTPClientTransport.defaultConnectTimeout`, 10
        /// seconds) *before* its backoff, and the actionable answer — "is the
        /// gateway running?" — is one the user can act on immediately and cannot
        /// see until the budget is spent. One retry is exactly enough to cover
        /// the case that does heal on its own: a proxy mid-restart, or a DNS
        /// blip. An operator who disagrees has this knob; the important part is
        /// that it is now explicit rather than an implicit `min(maxRetries, 1)`,
        /// so nobody raises `maxRetries` and silently changes it.
        public var maxPreConnectRetries: Int

        /// Total time one call may spend *asleep* between attempts. Retrying
        /// stops when the next delay would push past it, even with attempts
        /// left. `nil` disables the budget.
        ///
        /// This bounds the case a count alone cannot: a server that answers
        /// every attempt with `Retry-After: 60` costs ten minutes on attempts
        /// alone. Note it charges *scheduled sleep*, not wall clock — a run
        /// whose requests each burn a long `DOMOCODE_TIMEOUT_MS` is not bounded
        /// by it. That is deliberate: scheduled sleep is deterministic under the
        /// injected ``sleep``, so the budget is testable without a clock.
        public var retryDelayBudget: Duration?

        /// The jitter multiplier applied to a *computed* backoff, never to a
        /// server-supplied `retry-after` — the server named a time, and second
        /// -guessing it is how a client turns a polite throttle into a stampede.
        /// The result is clamped into `0...1`, so a hostile or buggy generator
        /// cannot produce a negative or an unbounded delay.
        ///
        /// Injectable so a schedule test can be exact and instantaneous.
        ///
        /// The default draws from ``defaultJitterRange`` (`0.5...1.0`, "half
        /// jitter"), not AWS's "full jitter" `0...1`. Full jitter exists to
        /// de-correlate a *fleet* of clients; this is one interactive CLI, which
        /// has no herd to spread, and full jitter's near-zero draws would let it
        /// hammer a provider that just said it was overloaded. Set
        /// `jitter = { Double.random(in: 0...1) }` for full jitter.
        public var jitter: @Sendable () -> Double

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
            maxRetries: Int = 10,
            baseRetryDelay: Duration = .seconds(1),
            maxRetryDelay: Duration = .seconds(60),
            maxPreConnectRetries: Int = 1,
            retryDelayBudget: Duration? = .seconds(300),
            jitter: @escaping @Sendable () -> Double = { Double.random(in: Configuration.defaultJitterRange) },
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
            self.maxPreConnectRetries = maxPreConnectRetries
            self.retryDelayBudget = retryDelayBudget
            self.jitter = jitter
            self.timeout = timeout
            self.sleep = sleep
        }

        /// The multiplier range the default ``jitter`` draws from.
        public static let defaultJitterRange: ClosedRange<Double> = 0.5...1.0

        /// The floor a server-supplied delay is raised to.
        ///
        /// Small enough to preserve the millisecond precision `retry-after-ms`
        /// exists for, large enough that `Retry-After: 0` — which
        /// ``DoMoCore/DoMoError/parseRetryAfter(retryAfter:retryAfterMilliseconds:now:)``
        /// also produces for a negative or a stale HTTP-date — cannot become a
        /// zero-delay hot loop of ten immediate requests.
        public static let minimumRetryAfter = Duration.milliseconds(100)

        /// The delay before retry `attempt` (1-based).
        ///
        /// A server-supplied `retryAfter` wins and is *not* jittered, but is
        /// clamped into `[minimumRetryAfter, maxRetryDelay]` — it is
        /// attacker-influenced text, so neither end of it is trusted. Otherwise
        /// the schedule is `min(baseRetryDelay * 2^(attempt-1), maxRetryDelay)`
        /// scaled by `jitter`.
        ///
        /// Pure and public so the whole table is testable without a transport,
        /// a clock, or a sleep.
        public func retryDelay(attempt: Int, retryAfter: Duration?, jitter: Double) -> Duration {
            if let retryAfter {
                return min(max(retryAfter, Self.minimumRetryAfter), maxRetryDelay)
            }
            // `1 << shift` is the doubling; the saturation at 30 keeps the shift
            // itself from overflowing on an absurd attempt number, and the cap
            // makes anything past ~7 attempts moot anyway.
            let shift = min(max(0, attempt - 1), 30)
            let capped = min(baseRetryDelay * Double(1 << shift), maxRetryDelay)
            // NaN loses every comparison, so a plain `min(max(j, 0), 1)` passes
            // it straight through — and `Duration * Double` converts through
            // `Int128`, which TRAPS on a NaN or an infinity. `jitter` is
            // injectable, so this is reachable from a caller's bug, not just
            // from ours: a non-finite multiplier reads as its sign's bound.
            let factor = jitter.isFinite ? min(max(jitter, 0), 1) : (jitter > 0 ? 1 : 0)
            return capped * factor
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
        var everConnected = false
        var spentOnRetries = Duration.zero

        while true {
            let response: StreamingResponse
            do {
                response = try await transport.execute(
                    request: request,
                    body: body,
                    timeout: configuration.timeout
                )
                everConnected = true
            } catch let error where DoMoError.isCancellation(error) {
                finishAborted(assembly, continuation)
                return
            } catch {
                let classified = Self.classifyTransport(error)
                // A failure before we ever reached the gateway is different from a
                // reconnect after a stream that was working and dropped. The
                // latter is a transient blip on a proven-good endpoint and earns
                // the full retry budget. The former usually means the gateway is
                // down, unreachable, or misconfigured — it rarely clears on
                // immediate retry, and each attempt costs a whole connect timeout,
                // so it keeps its own, much smaller budget.
                //
                // DECISION (retry-to-ten): the pre-connect cap STAYS. The
                // feature asked for is "retry a busy provider ten times", and a
                // busy provider answers — it is an HTTP status, and it goes down
                // the path below, not this one. Down here there is no evidence
                // anything is listening at all, ten attempts would cost ~110
                // seconds of dead connects *on top of* five minutes of backoff,
                // and the thing the user needs to see ("is the gateway
                // running?") is only shown once the budget is spent. Staring at
                // a dead gateway for ten backoffs is the real cost this avoids;
                // the transient DNS blip it has to survive is covered by the one
                // retry, and by `everConnected`, which hands the FULL budget to
                // any endpoint that has answered even once — including with a
                // 503. See ``Configuration/maxPreConnectRetries``.
                let cap = everConnected
                    ? configuration.maxRetries
                    : min(configuration.maxRetries, configuration.maxPreConnectRetries)
                if classified.isRetryable, attempt < cap,
                    let delay = nextRetryDelay(
                        attempt: attempt + 1, retryAfter: classified.retryAfter, spent: &spentOnRetries)
                {
                    attempt += 1
                    continuation.yield(
                        .retrying(
                            RetryNotice(
                                attempt: attempt,
                                maxAttempts: cap,
                                delay: delay,
                                reason: RetryNotice.reason(for: classified),
                                message: DoMoError.truncating(classified.message, to: Self.retryNoticeMessageCap)
                            )))
                    guard await sleepForRetry(delay) else {
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
                // A `Retry-After` on a 503 or an Anthropic 529 is as binding as
                // one on a 429, but `DoMoError` only carries the header for
                // `.rateLimit`, so read the head directly rather than silently
                // falling back to a guess the server already corrected.
                let serverDelay = error.retryAfter ?? Self.retryAfter(from: response.head)
                if error.isRetryable, attempt < configuration.maxRetries,
                    let delay = nextRetryDelay(
                        attempt: attempt + 1, retryAfter: serverDelay, spent: &spentOnRetries)
                {
                    attempt += 1
                    continuation.yield(
                        .retrying(
                            RetryNotice(
                                attempt: attempt,
                                maxAttempts: configuration.maxRetries,
                                delay: delay,
                                reason: RetryNotice.reason(for: error),
                                message: DoMoError.truncating(error.message, to: Self.retryNoticeMessageCap)
                            )))
                    guard await sleepForRetry(delay) else {
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
    ///
    /// `onRetry` is the non-streaming twin of ``AssemblyEvent/retrying(_:)``:
    /// there is no event stream here to carry a retry notice, so a caller that
    /// wants to report one passes a callback.
    @concurrent
    public func complete(
        model: String,
        context: Context,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        toolChoice: WireToolChoice? = nil,
        rates: ModelCostRates? = nil,
        onResponse: (@Sendable (ResponseMetadata) -> Void)? = nil,
        onRetry: (@Sendable (RetryNotice) -> Void)? = nil
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
        var everConnected = false
        var spentOnRetries = Duration.zero
        while true {
            let response: StreamingResponse
            do {
                response = try await transport.execute(
                    request: built.request,
                    body: built.body,
                    timeout: configuration.timeout
                )
                everConnected = true
            } catch let error where DoMoError.isCancellation(error) {
                throw DoMoError(.cancelled, "Request was aborted", cause: error)
            } catch {
                let classified = Self.classifyTransport(error)
                // Same asymmetry as the streaming path, and here for the same
                // reason: before this, `complete` had no pre-connect cap at all,
                // so raising `maxRetries` to ten would have made a dead gateway
                // cost eleven full connect timeouts on this path alone.
                let cap = everConnected
                    ? configuration.maxRetries
                    : min(configuration.maxRetries, configuration.maxPreConnectRetries)
                if classified.isRetryable, attempt < cap,
                    let delay = nextRetryDelay(
                        attempt: attempt + 1, retryAfter: classified.retryAfter, spent: &spentOnRetries)
                {
                    attempt += 1
                    onRetry?(
                        RetryNotice(
                            attempt: attempt,
                            maxAttempts: cap,
                            delay: delay,
                            reason: RetryNotice.reason(for: classified),
                            message: DoMoError.truncating(classified.message, to: Self.retryNoticeMessageCap)
                        ))
                    guard await sleepForRetry(delay) else {
                        throw DoMoError(.cancelled, "Request was aborted")
                    }
                    continue
                }
                throw classified
            }

            let status = response.head.status.code
            let bodyText = await Self.collectBody(response.body, cap: Self.responseBodyByteCap)
            if !(200..<300).contains(status) {
                let error = Self.classify(status: status, head: response.head, body: bodyText)
                let serverDelay = error.retryAfter ?? Self.retryAfter(from: response.head)
                if error.isRetryable, attempt < configuration.maxRetries,
                    let delay = nextRetryDelay(
                        attempt: attempt + 1, retryAfter: serverDelay, spent: &spentOnRetries)
                {
                    attempt += 1
                    onRetry?(
                        RetryNotice(
                            attempt: attempt,
                            maxAttempts: configuration.maxRetries,
                            delay: delay,
                            reason: RetryNotice.reason(for: error),
                            message: DoMoError.truncating(error.message, to: Self.retryNoticeMessageCap)
                        ))
                    guard await sleepForRetry(delay) else {
                        // Cancellation mid-backoff leaves as `.cancelled`, not as
                        // a raw `CancellationError`, matching the transport arm
                        // above so callers only have one shape to recognize.
                        throw DoMoError(.cancelled, "Request was aborted")
                    }
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

    /// The delay for `attempt`, or `nil` when the sleep budget is spent — in
    /// which case the caller must stop retrying and report the error it holds.
    ///
    /// Charging `spent` here, rather than checking it at the call site, is what
    /// keeps the two retry sites (and the two entry points) from disagreeing
    /// about how much of the budget a skipped or an early-returned attempt used.
    /// A delay that would push past the budget is *not* charged and *not*
    /// truncated to fit: a half-length backoff is worse than no backoff, and
    /// spending the budget on a shortened wait just fails a step later.
    private func nextRetryDelay(attempt: Int, retryAfter: Duration?, spent: inout Duration) -> Duration? {
        let delay = configuration.retryDelay(
            attempt: attempt,
            retryAfter: retryAfter,
            jitter: configuration.jitter()
        )
        if let budget = configuration.retryDelayBudget, spent + delay > budget { return nil }
        spent += delay
        return delay
    }

    /// Sleeps `delay`, returning `false` if the sleep was interrupted so the
    /// caller can terminate as aborted.
    ///
    /// Cancellation must win here, and it does: the default sleeper is
    /// `Task.sleep(for:)`, which throws `CancellationError` the moment the task
    /// is cancelled rather than at the end of the interval, so aborting a turn
    /// during a sixty-second backoff returns immediately instead of waiting the
    /// delay out. An injected sleeper that swallows cancellation would break
    /// that; the `throws` in ``Configuration/sleep``'s type is the contract.
    private func sleepForRetry(_ delay: Duration) async -> Bool {
        do {
            try await configuration.sleep(delay)
            return true
        } catch {
            return false
        }
    }

    /// The cap on the provider's own words carried in a ``RetryNotice``. A
    /// status line, not a log: one line's worth.
    static let retryNoticeMessageCap = 200

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
        // Additions beyond pi's list. These matter because LiteLLM wraps an
        // upstream 5xx in its own `400 litellm.APIError` often enough that the
        // status alone is not sufficient: `isRetryableBody` is what decides
        // retryability for a non-429 status (see `classify`), so a busy
        // provider whose overload arrives as a 400 is only caught by wording.
        #"\bbusy\b"#,  // "The server is busy", "model is busy"
        #"\bcapacity\b"#,  // "at capacity", "insufficient capacity"
        #"temporarily unavailable"#,
        #"please try again"#,  // Anthropic/Vertex "Please try again later."
        #"try again (?:later|shortly|in a (?:moment|few|little))"#,
        #"529"#,  // an upstream Anthropic 529 wrapped in a LiteLLM 400
        #"no healthy (?:upstream|deployment)"#,  // LiteLLM router
        #"all deployments? (?:are )?(?:rate limited|unhealthy|failed)"#,  // LiteLLM router
        // Deliberately NOT here: a bare `try again`. It would fire on a
        // genuinely malformed request ("check your parameters and try again")
        // and spend the whole ten-retry budget on a 400 that will never
        // succeed. The alternations above only match server-state wording.
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
