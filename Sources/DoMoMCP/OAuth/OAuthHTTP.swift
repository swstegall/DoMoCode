// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two HTTP shapes OAuth needs — a form POST and a JSON GET — issued
// through the same per-URL client provider the MCP client uses, so token and
// metadata traffic inherits the corporate-proxy handling (and the loopback
// bypass) for free. Bodies are collected with a hard cap: these endpoints
// answer in kilobytes, and anything larger is wrong.
//
// Redirects are a caveat, not a feature: the shared clients follow up to five
// without retaining POST bodies, so a redirecting token endpoint degrades
// into a clear failure (non-2xx or unparseable JSON) rather than a silent
// GET. Real token endpoints do not redirect; building a dedicated client per
// request just to forbid it would lose the proxy configuration.

import AsyncHTTPClient
import Foundation

/// Minimal HTTP access for the OAuth flow.
package struct OAuthHTTPTransport: Sendable {
    /// The proxy-aware client source, `MCPManager`'s `httpClients.client(for:)`
    /// in production; nil falls back to the shared client.
    var clientProvider: (@Sendable (URL) -> HTTPClient)?
    var timeout: Duration = .seconds(30)

    private static let bodyLimit = 1 << 20

    func postForm(_ url: URL, fields: [(String, String)]) async throws -> (status: Int, body: Data) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/x-www-form-urlencoded")
        request.headers.add(name: "accept", value: "application/json")
        let body = Self.encodeForm(fields)
        request.body = .bytes(Array(body.utf8))
        return try await execute(request, for: url)
    }

    func getJSON(_ url: URL) async throws -> (status: Int, body: Data) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "accept", value: "application/json")
        return try await execute(request, for: url)
    }

    /// A GET whose only interesting output is the status and headers — the
    /// discovery probe reads `WWW-Authenticate`. The body is deliberately NOT
    /// collected: the probe hits the MCP endpoint itself, which may answer a
    /// GET with an unbounded SSE/streaming 200 that `collect` would wait on
    /// forever. `execute` returns once the response head arrives (bounded by
    /// `headTimeout`), and dropping the body cancels the stream.
    func getHead(_ url: URL, headTimeout: Duration = .seconds(10)) async throws -> (
        status: Int, headers: [(String, String)]
    ) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        let client = clientProvider?(url) ?? HTTPClient.shared
        let response = try await client.execute(request, timeout: .nanoseconds(Self.nanoseconds(headTimeout)))
        return (Int(response.status.code), response.headers.map { ($0.name, $0.value) })
    }

    func postJSON(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.headers.add(name: "accept", value: "application/json")
        request.body = .bytes(Array(body))
        return try await execute(request, for: url)
    }

    private func execute(
        _ request: HTTPClientRequest,
        for url: URL
    ) async throws -> (status: Int, body: Data) {
        let client = clientProvider?(url) ?? HTTPClient.shared
        let response = try await client.execute(request, timeout: .nanoseconds(Self.nanoseconds(timeout)))
        let buffer = try await response.body.collect(upTo: Self.bodyLimit)
        return (Int(response.status.code), Data(buffer.readableBytesView))
    }

    /// `application/x-www-form-urlencoded` with RFC 3986 strict escaping
    /// (space as `%20`, which every OAuth endpoint accepts).
    package static func encodeForm(_ fields: [(String, String)]) -> String {
        fields
            .map { "\(formEscape($0.0))=\(formEscape($0.1))" }
            .joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        let attos = parts.attoseconds / 1_000_000_000
        return Int64(clamping: parts.seconds * 1_000_000_000 + attos)
    }
}
