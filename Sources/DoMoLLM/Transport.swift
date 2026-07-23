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

    /// The default overall deadline when a caller supplies none. Ten minutes
    /// matches `DOMOCODE_TIMEOUT_MS`'s default; a streamed coding turn with large
    /// tool output legitimately runs for minutes.
    public static let defaultTimeout: Duration = .seconds(600)

    public init(client: HTTPClient = .shared) {
        self.client = client
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
        let response = try await client.execute(clientRequest, timeout: .nanoseconds(Self.nanoseconds(deadline)))

        var head = HTTPResponse(status: .init(code: Int(response.status.code)))
        for header in response.headers {
            guard let name = HTTPField.Name(header.name) else { continue }
            head.headerFields.append(HTTPField(name: name, value: header.value))
        }

        let stream = Self.bridge(response.body)
        return StreamingResponse(head: head, body: stream)
    }

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
