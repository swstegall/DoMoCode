// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoCore
import Foundation
import HTTPTypes
import Synchronization

// MARK: - The seam

/// The HTTP transport the client streams over.
///
/// This exists for exactly two reasons, and neither is "support more providers":
/// tests inject a transport that replays recorded bytes so the whole SSE and
/// retry stack can be exercised with no socket, and an Apple-only build could
/// swap in a `URLSession` implementation. There is one wire API — LiteLLM's
/// OpenAI-compatible surface — and one production implementation,
/// ``AsyncHTTPClientTransport``.
///
/// Typed on swift-http-types so the seam speaks a currency both AsyncHTTPClient
/// and `URLSession` can be adapted to, rather than leaking either one's headers
/// type across it.
///
/// The response head arrives before the body: LiteLLM writes its
/// `x-litellm-*` correlation headers at stream open, not close, so a caller must
/// be able to read them without draining the stream first.
public protocol StreamingTransport: Sendable {
    /// Sends `request` and returns the response head plus a stream of body byte
    /// chunks. The stream must abort the underlying request when its consumer is
    /// cancelled — a leaked socket outlives the turn that opened it.
    func execute(
        request: HTTPRequest,
        body: [UInt8]?,
        timeout: Duration?
    ) async throws -> StreamingResponse
}

/// A response whose body has not necessarily arrived yet.
///
/// `body` is a concrete `AsyncThrowingStream` rather than an `AsyncSequence`
/// existential so the type crosses the seam without an associated-type dance and
/// stays trivially `Sendable`; the chunk boundaries are whatever the transport
/// produced and carry no semantic meaning, which is the whole point of driving
/// an incremental SSE parser over them.
public struct StreamingResponse: Sendable {
    public let head: HTTPResponse
    public let body: AsyncThrowingStream<[UInt8], any Error>

    public init(head: HTTPResponse, body: AsyncThrowingStream<[UInt8], any Error>) {
        self.head = head
        self.body = body
    }
}

// MARK: - Header helpers

extension HTTPResponse {
    /// A header value looked up case-insensitively, or `nil`.
    ///
    /// LiteLLM's header names are lowercase in practice, but the field name
    /// grammar is case-insensitive and a proxy in front of it need not agree, so
    /// the lookup goes through ``HTTPField/Name`` rather than string compare.
    public func headerValue(_ name: String) -> String? {
        guard let fieldName = HTTPField.Name(name) else { return nil }
        return headerFields[fieldName]
    }
}

// MARK: - Stream idle guard

/// When the guarded stream last saw a byte.
///
/// A class rather than a bare `Mutex` local because `Mutex` is non-copyable and
/// cannot be captured by the two concurrent children directly; a `Sendable` box
/// around it is the shape that crosses both closures.
private final class StreamActivity: Sendable {
    private let stamp: Mutex<ContinuousClock.Instant>

    init(_ instant: ContinuousClock.Instant) {
        stamp = Mutex(instant)
    }

    func record(_ instant: ContinuousClock.Instant) {
        stamp.withLock { $0 = instant }
    }

    var last: ContinuousClock.Instant {
        stamp.withLock { $0 }
    }
}

/// Re-emits `upstream`, failing the stream if no chunk arrives within `idle` or
/// the whole body takes longer than `overall`.
///
/// This exists because **nothing else bounds a streamed response body**.
/// `HTTPClient.execute(_:timeout:)`'s deadline covers only time-to-response-head
/// — AsyncHTTPClient cancels the deadline task in a `defer` the instant the head
/// lands — and `HTTPClient.Configuration.Timeout.read` defaults to `nil`. So a
/// gateway that writes headers and then stalls without closing the socket
/// produces a stream that never yields, never throws and never finishes. That
/// hangs the turn, which holds the server's run slot, which makes every later
/// prompt on that session 409 — the "the session stopped answering, I had to
/// make a new one" bug, exactly.
///
/// The failure message deliberately contains "timed out" so
/// `LiteLLMClient.classifyTransport` marks it retryable and the user sees a
/// transport error rather than a spinner. A loud failure beats a silent hang.
///
/// Semantics:
/// - The idle window is measured from the last chunk actually delivered, so a
///   healthy-but-slow stream is never cut off however long it runs.
/// - `overall` is measured from the moment this function was called, i.e. from
///   just after the response head arrived.
/// - Dropping the consumer terminates this stream, which cancels the pump, which
///   cancels the iteration of `upstream` — so the "abandoning the consumer aborts
///   the request" guarantee ``AsyncHTTPClientTransport`` documents survives.
///
/// Public so its tests build in release mode without `@testable`.
public func idleGuarded(
    _ upstream: AsyncThrowingStream<[UInt8], any Error>,
    idle: Duration,
    overall: Duration,
    clock: ContinuousClock = ContinuousClock()
) -> AsyncThrowingStream<[UInt8], any Error> {
    AsyncThrowingStream { continuation in
        let start = clock.now
        let activity = StreamActivity(start)
        // Poll no slower than the idle window and no faster than 10ms, so a
        // pathological `idle` of zero cannot turn this into a spin loop.
        let tick = max(.milliseconds(10), min(idle, .seconds(1)))
        let pump = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await chunk in upstream {
                            activity.record(clock.now)
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: tick)
                        if Task.isCancelled { return }
                        let now = clock.now
                        if now - activity.last >= idle {
                            continuation.finish(throwing: DoMoError(
                                .transport,
                                """
                                The model stream stalled — no data for \(idle). \
                                The connection was still open; it timed out.
                                """
                            ))
                            return
                        }
                        if now - start >= overall {
                            continuation.finish(throwing: DoMoError(
                                .transport,
                                "The model stream exceeded its \(overall) deadline and timed out."
                            ))
                            return
                        }
                    }
                }
                // Whichever child settles first decides the stream; cancel the
                // other and let the group drain, so no task outlives this scope.
                _ = await group.next()
                group.cancelAll()
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
    }
}

// MARK: - AsyncHTTPClient implementation

/// The production transport.
///
/// Uses `HTTPClient.shared` by default: it is process-wide, needs no shutdown,
/// and honors `HTTP(S)_PROXY`/`NO_PROXY` from the environment, which is the
/// behavior the README promises. An injected client is accepted for callers that
/// need custom TLS or proxy configuration.
public struct AsyncHTTPClientTransport: StreamingTransport {
    private let client: HTTPClient
    private let connectTimeout: Duration
    private let idleTimeout: Duration

    /// The default value passed as `timeout:` when a caller supplies none.
    ///
    /// CORRECTION (this comment used to claim an "overall per-request deadline",
    /// which it is not): AsyncHTTPClient's `execute(_:timeout:)` deadline covers
    /// **only time-to-response-head** — it cancels its deadline task in a `defer`
    /// as soon as the head arrives — so on its own this bounds nothing about the
    /// streamed body. What actually bounds the body is ``idleGuarded(_:idle:overall:clock:)``,
    /// which this transport wraps every response body in, using this same value as
    /// its `overall` budget and ``defaultIdleTimeout`` as its silence budget.
    ///
    /// Ten minutes matches `DOMOCODE_TIMEOUT_MS`'s default; a streamed coding turn
    /// with large tool output legitimately runs for minutes.
    public static let defaultTimeout: Duration = .seconds(600)

    /// Bound on time-to-response-head — connect, TLS, request send, and the first
    /// response byte.
    ///
    /// This exists because pointing `domo` at a gateway that is not running is
    /// the single most common misconfiguration, and `HTTPClient.shared` has no
    /// connect timeout of its own.
    ///
    /// CORRECTION (this comment used to say the client's "only bound is the
    /// overall request deadline, which is 600s"): that deadline is not overall,
    /// it is head-only — which means without this value a dead gateway hangs for
    /// ten minutes, and without ``idleGuarded(_:idle:overall:clock:)`` a gateway
    /// that answers and then goes quiet hangs *forever*. On a healthy proxy the
    /// head arrives in well under a second, so 10s is generous headroom for a slow
    /// corporate proxy rather than a limit anything real approaches.
    ///
    /// It is kept modest on purpose: the client's retry loop multiplies it, so the
    /// worst case a user waits on a host that silently eats packets is this value
    /// times the attempt count. The common misconfiguration — nothing listening on
    /// `localhost` — is refused by the OS immediately and never reaches this bound.
    public static let defaultConnectTimeout: Duration = .seconds(10)

    /// How long a committed response body may deliver **nothing** before the
    /// stream is failed.
    ///
    /// Two minutes rather than something tight: a provider behind a proxy that
    /// does not forward keepalives can legitimately go quiet through a long
    /// reasoning block, and a false positive there costs the user a whole turn.
    /// Anything past two minutes of total silence on a committed stream is a
    /// wedged connection, not a slow model.
    public static let defaultIdleTimeout: Duration = .seconds(120)

    public init(
        client: HTTPClient = .shared,
        connectTimeout: Duration = AsyncHTTPClientTransport.defaultConnectTimeout,
        idleTimeout: Duration = AsyncHTTPClientTransport.defaultIdleTimeout
    ) {
        self.client = client
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
    }

    public func execute(
        request: HTTPRequest,
        body: [UInt8]?,
        timeout: Duration?
    ) async throws -> StreamingResponse {
        guard let url = request.url else {
            throw DoMoError(.configuration, "Request has no resolvable URL")
        }

        var clientRequest = HTTPClientRequest(url: url.absoluteString)
        // Leading-dot and member syntax throughout, so NIO's currency types
        // (`HTTPMethod`, `ByteBuffer`, `TimeAmount`) are used without importing
        // NIOCore/NIOHTTP1 — which this target does not declare as a direct
        // dependency. They reach us only through AsyncHTTPClient's API.
        clientRequest.method = .init(rawValue: request.method.rawValue)
        for field in request.headerFields {
            clientRequest.headers.add(name: field.name.rawName, value: field.value)
        }
        if let body {
            clientRequest.body = .bytes(body)
        }

        let deadline = timeout ?? Self.defaultTimeout
        let response = try await headWithinConnectDeadline(clientRequest, deadline: deadline, host: url.host)

        var head = HTTPResponse(status: .init(code: Int(response.status.code)))
        for header in response.headers {
            guard let name = HTTPField.Name(header.name) else { continue }
            head.headerFields.append(HTTPField(name: name, value: header.value))
        }

        // `deadline` bounded the head only (see `defaultTimeout`). The body is
        // unbounded until this wrap: without it a gateway that stalls after the
        // head hangs the turn, and the session, forever.
        let stream = idleGuarded(Self.bridge(response.body), idle: idleTimeout, overall: deadline)
        return StreamingResponse(head: head, body: stream)
    }

    /// Awaits the response head, but fails with a transport error if it does not
    /// arrive within ``connectTimeout``.
    ///
    /// `client.execute` resolves as soon as the response head is available and
    /// then streams the body separately, so racing it against a sleep bounds
    /// exactly the connect-and-headers phase without touching the body budget —
    /// the returned response's body is bounded separately, by
    /// ``idleGuarded(_:idle:overall:clock:)``, because `deadline` stops applying
    /// the moment the head lands. The losing
    /// child is cancelled on exit, which is what tells AsyncHTTPClient to abandon
    /// a connection attempt that is going nowhere rather than leak it.
    ///
    /// A connection the OS refuses outright still errors on its own, faster than
    /// this deadline; the race only covers the case that actually hangs — a host
    /// that accepts the SYN, or silently drops it, and then never answers.
    private func headWithinConnectDeadline(
        _ request: HTTPClientRequest,
        deadline: Duration,
        host: String?
    ) async throws -> HTTPClientResponse {
        try await withThrowingTaskGroup(of: HTTPClientResponse.self) { group in
            group.addTask { [client] in
                try await client.execute(request, timeout: .nanoseconds(Self.nanoseconds(deadline)))
            }
            group.addTask { [connectTimeout] in
                try await Task.sleep(for: connectTimeout)
                throw ConnectDeadlineReached()
            }

            do {
                guard let response = try await group.next() else {
                    group.cancelAll()
                    throw DoMoError(.transport, "The transport produced no response")
                }
                group.cancelAll()
                return response
            } catch is ConnectDeadlineReached {
                group.cancelAll()
                let where_ = host.map { " from \($0)" } ?? ""
                throw DoMoError(
                    .transport,
                    "No response\(where_) within \(connectTimeout) — is the gateway running and reachable?"
                )
            }
        }
    }

    /// Sentinel thrown by the connect-deadline child so the group can tell a
    /// timeout apart from a real transport failure the request itself produced.
    private struct ConnectDeadlineReached: Error {}

    /// Bridges the NIO body sequence into the currency stream, wiring
    /// cancellation through so that dropping the consumer aborts the request.
    ///
    /// `onTermination` fires when the consuming task is cancelled or the stream
    /// is otherwise finished early; cancelling the pump task makes the
    /// `for try await` over `response.body` throw, which is what tells
    /// AsyncHTTPClient to tear the connection down instead of leaking it.
    private static func bridge(
        _ body: HTTPClientResponse.Body
    ) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await buffer in body {
                        continuation.yield(Array(buffer.readableBytesView))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// The deadline in whole nanoseconds, saturating rather than trapping on an
    /// absurd timeout so a misconfigured value cannot crash the request path.
    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let (scaled, overflowA) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflowA else { return .max }
        let (total, overflowB) = scaled.addingReportingOverflow(components.attoseconds / 1_000_000_000)
        return overflowB ? .max : total
    }
}
