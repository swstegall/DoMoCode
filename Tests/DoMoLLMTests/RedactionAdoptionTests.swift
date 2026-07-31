// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The gateway's own words must never carry a credential out of this client.
//
// LiteLLM's 401 body echoes back a prefix of the API key it was handed. That
// body becomes `DoMoError.message`, which the agent loop assigns to
// `AssistantMessage.errorMessage`, which is appended to the session JSONL and
// never rewritten — and re-emitted over SSE, printed by `-p --json`, and drawn
// by both interactive surfaces. These tests pin the doors that text comes
// through (a non-2xx body, a mid-stream error frame under a committed 200, a
// transport failure quoted into a retry notice, a base URL with inline
// userinfo) and, just as importantly, pin what redaction must NOT do to text
// that carries no secret.
//
// Everything here drives the public `streamCompletion` through a stub transport
// rather than reaching for the internal classifier, so each assertion is about
// something a consumer can actually observe.

import DoMoCore
import Foundation
import HTTPTypes
import Testing

import DoMoLLM

// MARK: - Fixtures

/// An `sk-proj-` shaped key: the prefix plus enough run characters to clear the
/// pattern rule's sixteen-character minimum.
private let fakeKey = "sk-proj-a1b2c3d4e5f6g7h8i9j0klmn"

/// A secret with no recognizable shape at all — the case only the literal
/// registry can catch. Spelled uniquely to this file so registering it in the
/// process-wide vault cannot perturb another suite.
private let registeredSecret = "zqx-domolredaction-literal-77413"

private let redactionContext = Context(systemPrompt: "s", messages: [.user("hi")])

private func sse(_ payload: String) -> [UInt8] { Array("data: \(payload)\n\n".utf8) }

// MARK: - Test doubles

/// Replays one canned HTTP response for every attempt.
private final class CannedTransport: StreamingTransport {
    private let status: Int
    private let chunks: [[UInt8]]

    init(status: Int, chunks: [[UInt8]] = []) {
        self.status = status
        self.chunks = chunks
    }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        let head = HTTPResponse(status: .init(code: status))
        let chunks = self.chunks
        let stream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return StreamingResponse(head: head, body: stream)
    }
}

/// A foreign (non-`DoMoError`) transport failure whose `String(describing:)`
/// carries an endpoint — the shape AsyncHTTPClient's own errors have.
private struct GatewayFault: Error {
    let endpoint: String
}

/// Fails every attempt. With a `DoMoError` that is the shape
/// `classifyTransport` returns untouched, so the display sites are the only
/// ones that can scrub it; with a `GatewayFault` it is the shape
/// `classifyTransport` stringifies and scrubs itself.
private final class FailingTransport: StreamingTransport {
    private let error: any Error

    init(_ error: DoMoError) { self.error = error }
    init(fault: GatewayFault) { self.error = fault }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        throw error
    }
}

private func redactionClient(
    _ transport: any StreamingTransport,
    baseURL: String = "http://localhost:4000/v1",
    maxRetries: Int = 0
) -> LiteLLMClient {
    var configuration = LiteLLMClient.Configuration(
        baseURL: baseURL,
        apiKey: "sk-test",
        maxRetries: maxRetries
    )
    configuration.sleep = { _ in }
    return LiteLLMClient(configuration: configuration, transport: transport)
}

private func drain(
    _ stream: AsyncThrowingStream<AssemblyEvent, any Error>
) async -> (events: [AssemblyEvent], error: DoMoError?) {
    var events: [AssemblyEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch let error as DoMoError {
        return (events, error)
    } catch {
        return (events, nil)
    }
}

private func streamOnce(_ client: LiteLLMClient) async -> (events: [AssemblyEvent], error: DoMoError?) {
    await drain(client.streamCompletion(model: "gpt-4o-mini", context: redactionContext))
}

private func retryNotices(_ events: [AssemblyEvent]) -> [RetryNotice] {
    events.compactMap { if case .retrying(let notice) = $0 { notice } else { nil } }
}

// MARK: - The 401 body

@Suite("Redaction adoption — the gateway's error body")
struct GatewayErrorBodyRedactionTests {

    @Test("A 401 whose body quotes the API key back yields a message with no key in it")
    func authenticationBodyIsRedacted() async throws {
        let body = #"{"error":{"message":"Invalid API key \#(fakeKey) provided","type":"invalid_request_error"}}"#
        let transport = CannedTransport(status: 401, chunks: [Array(body.utf8)])

        let (_, error) = await streamOnce(redactionClient(transport))
        let failure = try #require(error)

        // Classification still has to be right: redaction reads the message the
        // human sees, never the text the classifier matches on.
        #expect(failure.kind == .authentication)
        #expect(!failure.message.contains("sk-proj-"))
        #expect(!failure.message.contains(fakeKey))
        #expect(failure.message.contains(Redaction.placeholder))
        // And the diagnostic still says what happened. A redactor that ate the
        // whole sentence would satisfy every assertion above.
        #expect(failure.message.contains("Invalid API key"))
        #expect(failure.message.contains("invalid_request_error"))
    }

    @Test("A registered literal with no recognizable shape is removed from the body too")
    func registeredLiteralIsRemoved() async throws {
        Redaction.register(registeredSecret)
        let body = #"{"error":{"message":"credential \#(registeredSecret) is not valid for tenant acme"}}"#
        let transport = CannedTransport(status: 401, chunks: [Array(body.utf8)])

        let (_, error) = await streamOnce(redactionClient(transport))
        let failure = try #require(error)

        #expect(!failure.message.contains(registeredSecret))
        #expect(failure.message.contains(Redaction.placeholder))
        #expect(failure.message.contains("tenant acme"))
    }

    /// The transport branch that stringifies a FOREIGN error. AsyncHTTPClient's
    /// failures routinely carry the request URL, which is where a base URL
    /// spelled `user:password@` ends up.
    @Test("A foreign transport failure is scrubbed when it is classified")
    func foreignTransportFailureIsRedacted() async throws {
        let transport = FailingTransport(
            fault: GatewayFault(endpoint: "https://svc:\(fakeKey)@gateway.internal/v1")
        )

        // No retries, so the notice path is not involved and this isolates the
        // redaction inside `classifyTransport`.
        let (events, error) = await streamOnce(redactionClient(transport, maxRetries: 0))
        let failure = try #require(error)

        #expect(retryNotices(events).isEmpty)
        #expect(failure.kind == .transport)
        #expect(!failure.message.contains(fakeKey))
        #expect(failure.message.contains(Redaction.placeholder))
        #expect(failure.message.contains("gateway.internal"))
    }

    @Test("A body carrying no secret survives byte for byte")
    func ordinaryBodyIsUnchanged() async throws {
        // The colon and the `://` are deliberate: both are pattern-rule triggers,
        // so this text really does reach the regex engine instead of short-
        // circuiting ahead of it. A rule that over-matches fails here.
        let body = "Error code: 400 - the widget field is unknown; http://gateway.local/v1 rejected it"
        let transport = CannedTransport(status: 400, chunks: [Array(body.utf8)])

        let (_, error) = await streamOnce(redactionClient(transport))
        let failure = try #require(error)

        #expect(failure.message == body)
    }
}

// MARK: - The mid-stream error frame

@Suite("Redaction adoption — a mid-stream error frame")
struct MidStreamErrorRedactionTests {

    @Test("An error frame under a committed 200 cannot put a key in errorMessage")
    func errorFrameIsRedacted() async throws {
        let frame = #"{"error":{"message":"key \#(fakeKey) was revoked","type":"authentication_error"}}"#
        let transport = CannedTransport(status: 200, chunks: [sse(frame)])

        let (events, error) = await streamOnce(redactionClient(transport))

        #expect(error == nil)
        let terminal = try #require(events.compactMap(\.terminalMessage).last)
        #expect(terminal.stopReason == .error)
        let message = try #require(terminal.errorMessage)
        #expect(!message.contains("sk-proj-"))
        #expect(!message.contains(fakeKey))
        #expect(message.contains(Redaction.placeholder))
        #expect(message.contains("was revoked"))
        // `type` is a classifier token rather than payload, and stays legible.
        #expect(message.contains("authentication_error"))
    }

    /// `ChatCompletionChunk.decode` quotes the raw SSE payload back verbatim, so
    /// an undecodable frame is a second, quieter route from the wire into the
    /// persisted transcript — and one the agent loop cannot cover, because a
    /// `.failed` terminal is handed to it already built.
    @Test("An undecodable frame does not carry its payload's secret into errorMessage")
    func undecodableFrameIsRedacted() async throws {
        // No `"error"` key, so this is NOT sniffed as an error envelope and really
        // does reach the decoder; the truncated object then fails to decode.
        let frame = #"{"id":"x","authorization":"Bearer \#(fakeKey)","choices":"#
        let transport = CannedTransport(status: 200, chunks: [sse(frame)])

        let (events, _) = await streamOnce(redactionClient(transport))
        let terminal = try #require(events.compactMap(\.terminalMessage).last)
        let message = try #require(terminal.errorMessage)

        #expect(message.contains("Could not decode SSE chunk"))
        #expect(!message.contains(fakeKey))
        #expect(message.contains(Redaction.placeholder))
    }

    @Test("An error frame carrying no secret is passed through unchanged")
    func ordinaryErrorFrameIsUnchanged() async throws {
        let frame = #"{"error":{"message":"upstream deployment is unhealthy","type":"api_error"}}"#
        let transport = CannedTransport(status: 200, chunks: [sse(frame)])

        let (events, _) = await streamOnce(redactionClient(transport))
        let terminal = try #require(events.compactMap(\.terminalMessage).last)

        #expect(terminal.errorMessage == "upstream deployment is unhealthy (type: api_error)")
    }
}

// MARK: - The retry notice

@Suite("Redaction adoption — retry notices")
struct RetryNoticeRedactionTests {

    /// A transport failure arrives as an already-built `DoMoError`, which
    /// `classifyTransport` returns by value so its kind and cause chain survive.
    /// The notice is therefore the FIRST place that text is scrubbed — remove
    /// the redaction from `retryNoticeMessage` and this fails.
    @Test("A retry notice never quotes a credential out of a transport failure")
    func retryNoticeIsRedacted() async throws {
        let transport = FailingTransport(
            DoMoError(.transport, "connect to https://svc:\(fakeKey)@gateway.internal/v1 failed")
        )

        let (events, error) = await streamOnce(redactionClient(transport, maxRetries: 3))

        #expect(error?.kind == .transport)
        let notice = try #require(retryNotices(events).first)
        #expect(!notice.message.contains("sk-proj-"))
        #expect(!notice.message.contains(fakeKey))
        #expect(notice.message.contains(Redaction.placeholder))
        // The host is the useful half of "which endpoint refused me?" and is not
        // a secret, so the userinfo rule has to leave it readable.
        #expect(notice.message.contains("gateway.internal"))
    }

    @Test("A retry notice with nothing to hide reads exactly as the failure did")
    func ordinaryRetryNoticeIsUnchanged() async throws {
        let transport = FailingTransport(DoMoError(.transport, "connection reset by peer"))

        let (events, _) = await streamOnce(redactionClient(transport, maxRetries: 3))
        let notice = try #require(retryNotices(events).first)

        #expect(notice.message == "connection reset by peer")
    }
}

// MARK: - The non-streaming path

@Suite("Redaction adoption — complete()")
struct NonStreamingRedactionTests {

    @Test("An undecodable 200 body is quoted back without its secret")
    func undecodableResponseBodyIsRedacted() async throws {
        let body = #"<html>gateway proxy error, token \#(fakeKey) rejected</html>"#
        let transport = CannedTransport(status: 200, chunks: [Array(body.utf8)])

        var thrown: DoMoError?
        do {
            _ = try await redactionClient(transport).complete(model: "m", context: redactionContext)
        } catch let error as DoMoError {
            thrown = error
        }
        let failure = try #require(thrown)

        #expect(failure.kind == .malformedResponse)
        #expect(failure.message.contains("Could not decode completion response"))
        #expect(!failure.message.contains(fakeKey))
        #expect(failure.message.contains(Redaction.placeholder))
    }
}

// MARK: - Configuration text

@Suite("Redaction adoption — configuration diagnostics")
struct BaseURLRedactionTests {

    @Test("An unusable base URL is reported without its inline credential")
    func invalidBaseURLIsRedacted() async throws {
        // The unterminated `[` is an invalid host under RFC 3986, so `URL(string:)`
        // refuses it and `endpointURL`'s guard is the path taken. The userinfo in
        // front of it is what must not reach the message.
        let client = redactionClient(
            CannedTransport(status: 200),
            baseURL: "https://svc:\(fakeKey)@[unterminated/v1"
        )

        let (_, error) = await streamOnce(client)
        let failure = try #require(error)

        #expect(failure.kind == .configuration)
        #expect(!failure.message.contains(fakeKey))
        #expect(failure.message.contains(Redaction.placeholder))
    }
}
