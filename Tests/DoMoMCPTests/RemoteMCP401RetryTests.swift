// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The 401 contract at the MCP client: exactly one forced refresh and one
// byte-identical replay per request, the server's WWW-Authenticate challenge
// handed through to the provider, a second refusal surfacing as the typed
// `unauthorized` (never a loop), and 403 failing straight through — a scope
// problem is not cured by a fresher token, so the provider must not even be
// asked. The stub server records every authorization header in arrival
// order, so presence, absence, and *sequence* are all first-class evidence.

import DoMoMCP
import Foundation
import Hummingbird
import NIOCore
import Testing

/// A minimal streamable-HTTP MCP endpoint: answers initialize and accepts
/// notifications, refusing any request whose bearer the policy closure
/// rejects. Records the authorization header of every request, nil included.
private func mcpStubRouter(
    authorizations: Recorder<String?>,
    accepts: @escaping @Sendable (String?) -> Bool,
    refusalStatus: HTTPResponse.Status = .unauthorized
) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)
    router.post("/mcp") { request, _ -> Response in
        let authorization = request.headers[.authorization]
        authorizations.append(authorization)
        guard accepts(authorization) else {
            var headers = HTTPFields()
            headers[.wwwAuthenticate] =
                #"Bearer resource_metadata="https://mcp.example.invalid/.well-known/oauth-protected-resource""#
            return Response(status: refusalStatus, headers: headers)
        }
        let buffer = try await request.body.collect(upTo: 1 << 20)
        let object = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))
        let message = object as? [String: Any] ?? [:]
        guard let id = message["id"] else {
            return Response(status: .accepted)
        }
        let result: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "0"],
            ],
        ]
        return jsonResponse(.ok, result)
    }
    return router
}

private func remoteConfig(endpoint: String) -> MCPServerConfig {
    MCPServerConfig(
        command: [],
        timeout: 10_000,
        url: endpoint,
        transport: .streamableHTTP,
        allowPrivateNetwork: true
    )
}

@Suite("Remote MCP 401 refresh-and-replay", .serialized)
struct RemoteMCP401RetryTests {

    @Test("A 401 triggers one forced refresh and one replay, then flows on")
    func refreshOnceAndReplay() async throws {
        let authorizations = Recorder<String?>()
        let router = mcpStubRouter(
            authorizations: authorizations,
            accepts: { $0 == "Bearer token-new" }
        )
        let server = try await TestHTTPServer.start(router: router)
        defer { server.stop() }

        let providerCalls = Recorder<String>()
        let current = ValueBox<String>()
        current.set("token-old")
        let client = MCPClient(
            serverName: "stub",
            config: remoteConfig(endpoint: "\(server.baseURL)/mcp"),
            workspaceDirectory: NSTemporaryDirectory(),
            tokenProvider: { forceRefresh, rejectedToken, challenge in
                if forceRefresh {
                    // The exact token that just 401'd must be handed back.
                    providerCalls.append("force:\(rejectedToken ?? "nil"):\(challenge ?? "")")
                    current.set("token-new")
                } else {
                    providerCalls.append("plain")
                }
                return current.value
            }
        )
        try await client.connect()
        await client.shutdown()

        let forced = providerCalls.values.filter { $0.hasPrefix("force:") }
        #expect(forced.count == 1, "one 401 means exactly one forced refresh")
        #expect(
            forced.first?.contains("resource_metadata") == true,
            "the server's challenge must reach the provider for discovery"
        )
        #expect(
            forced.first?.contains("force:token-old:") == true,
            "the provider must be told exactly which token was rejected"
        )
        // Wire evidence: rejected old token, replayed with the new one, and
        // every later request (the initialized notification) stayed new.
        #expect(authorizations.values.first == "Bearer token-old")
        #expect(authorizations.values.dropFirst().allSatisfy { $0 == "Bearer token-new" })
        #expect(authorizations.count >= 3, "initialize, its replay, and the notification")
    }

    @Test("A second 401 after refresh surfaces as unauthorized, not a loop")
    func secondRefusalIsTyped() async throws {
        let authorizations = Recorder<String?>()
        let router = mcpStubRouter(authorizations: authorizations, accepts: { _ in false })
        let server = try await TestHTTPServer.start(router: router)
        defer { server.stop() }

        let client = MCPClient(
            serverName: "stub",
            config: remoteConfig(endpoint: "\(server.baseURL)/mcp"),
            workspaceDirectory: NSTemporaryDirectory(),
            tokenProvider: { _, _, _ in "token-still-bad" }
        )
        do {
            try await client.connect()
            Issue.record("connect must fail when the credential is never accepted")
        } catch MCPClient.MCPError.unauthorized {
            // The typed case is the contract.
        }
        await client.shutdown()
        #expect(authorizations.count == 2, "first attempt plus exactly one replay, never more")
    }

    @Test("A 403 fails straight through without consulting the provider")
    func forbiddenDoesNotRefresh() async throws {
        let authorizations = Recorder<String?>()
        let router = mcpStubRouter(
            authorizations: authorizations,
            accepts: { _ in false },
            refusalStatus: .forbidden
        )
        let server = try await TestHTTPServer.start(router: router)
        defer { server.stop() }

        let providerCalls = Recorder<String>()
        let client = MCPClient(
            serverName: "stub",
            config: remoteConfig(endpoint: "\(server.baseURL)/mcp"),
            workspaceDirectory: NSTemporaryDirectory(),
            tokenProvider: { forceRefresh, _, _ in
                providerCalls.append(forceRefresh ? "force" : "plain")
                return "token-scoped-wrong"
            }
        )
        do {
            try await client.connect()
            Issue.record("connect must fail on 403")
        } catch MCPClient.MCPError.unauthorized {
            // Typed, same family as 401 — but reached without a retry.
        }
        await client.shutdown()
        #expect(!providerCalls.values.contains("force"), "a scope problem must not trigger refresh")
        #expect(authorizations.count == 1, "no replay on 403")
    }

    @Test("Without a token provider a 401 is still terminal and quiet")
    func staticTokenPathUnchanged() async throws {
        let authorizations = Recorder<String?>()
        let router = mcpStubRouter(authorizations: authorizations, accepts: { _ in false })
        let server = try await TestHTTPServer.start(router: router)
        defer { server.stop() }

        let client = MCPClient(
            serverName: "stub",
            config: remoteConfig(endpoint: "\(server.baseURL)/mcp"),
            workspaceDirectory: NSTemporaryDirectory(),
            bearerToken: "static-token-000010"
        )
        do {
            try await client.connect()
            Issue.record("connect must fail")
        } catch MCPClient.MCPError.unauthorized {
            // Statically credentialed clients get the typed error too; they
            // simply have nothing to refresh with.
        }
        await client.shutdown()
        #expect(authorizations.count == 1, "no provider, no replay")
    }
}
