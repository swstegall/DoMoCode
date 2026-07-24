// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoCore
import Foundation
import HTTPTypes

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

    /// The default overall deadline when a caller supplies none. Ten minutes
    /// matches `DOMOCODE_TIMEOUT_MS`'s default; a streamed coding turn with large
    /// tool output legitimately runs for minutes.
    public static let defaultTimeout: Duration = .seconds(600)

    /// Bound on time-to-response-head — connect, TLS, request send, and the first
    /// response byte — separate from the overall streaming deadline above.
    ///
    /// This exists because pointing `domo` at a gateway that is not running is
    /// the single most common misconfiguration, and `HTTPClient.shared` has no
    /// connect timeout of its own: its only bound is the overall request deadline,
    /// which is 600s to accommodate a long streamed turn. Without this a dead
    /// gateway hangs for ten minutes instead of erroring. On a healthy proxy the
    /// head arrives in well under a second, so 10s is generous headroom for a slow
    /// corporate proxy rather than a limit anything real approaches.
    ///
    /// It is kept modest on purpose: the client's retry loop multiplies it, so the
    /// worst case a user waits on a host that silently eats packets is this value
    /// times the attempt count. The common misconfiguration — nothing listening on
    /// `localhost` — is refused by the OS immediately and never reaches this bound.
    public static let defaultConnectTimeout: Duration = .seconds(10)

    public init(
        client: HTTPClient = .shared,
        connectTimeout: Duration = AsyncHTTPClientTransport.defaultConnectTimeout
    ) {
        self.client = client
        self.connectTimeout = connectTimeout
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

        let stream = Self.bridge(response.body)
        return StreamingResponse(head: head, body: stream)
    }

    /// Awaits the response head, but fails with a transport error if it does not
    /// arrive within ``connectTimeout``.
    ///
    /// `client.execute` resolves as soon as the response head is available and
    /// then streams the body separately, so racing it against a sleep bounds
    /// exactly the connect-and-headers phase without touching the body budget —
    /// the returned response's body still streams under `deadline`. The losing
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
