// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// MCPManager's OAuth wiring, end to end through the real manager: an
// oauth-configured server acquires a token at connect and presents it to the
// MCP endpoint; OAuth outranks a configured static credential; and a server
// that declares oauth on a surface that provides no OAuthSetup is skipped
// rather than connected credential-less.

import DoMoMCP
import Foundation
import Hummingbird
import NIOCore
import Testing

/// A stub that serves BOTH the token endpoint and a minimal MCP endpoint, so
/// one server can stand in for the whole chain. Records the Authorization
/// header every /mcp request carried.
private func combinedRouter(
    mcpAuthorizations: Recorder<String?>,
    issue accessToken: String
) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)
    router.post("/token") { _, _ in
        jsonResponse(.ok, ["access_token": accessToken, "token_type": "Bearer", "expires_in": 3600])
    }
    router.post("/mcp") { request, _ -> Response in
        mcpAuthorizations.append(request.headers[.authorization])
        let buffer = try await request.body.collect(upTo: 1 << 20)
        let message = (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any] ?? [:]
        guard let id = message["id"] else { return Response(status: .accepted) }
        return jsonResponse(.ok, [
            "jsonrpc": "2.0", "id": id,
            "result": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "0"],
            ],
        ])
    }
    return router
}

@Suite("MCPManager OAuth wiring", .serialized)
struct MCPManagerOAuthWiringTests {

    private final class ScratchDirectory: Sendable {
        let path: String
        init() throws {
            path = NSTemporaryDirectory() + "domocode-mgr-oauth-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
    }

    private struct SilentBrowser: BrowserLaunching {
        func open(_ url: String) async -> Bool { true }
    }

    @Test("An oauth server acquires a token at connect and presents it to the MCP endpoint")
    func acquiresAndPresents() async throws {
        let scratch = try ScratchDirectory()
        let authorizations = Recorder<String?>()
        let server = try await TestHTTPServer.start(
            router: combinedRouter(mcpAuthorizations: authorizations, issue: "access-token-mgr-000001")
        )
        defer { server.stop() }

        // Pre-seed a valid token so connect needs no browser (allowInteractive
        // false), isolating the "token flows to the header" wiring.
        let store = OAuthTokenStore(directory: scratch.path + "/mcp-oauth")
        _ = try await store.mutate(forKey: "jira", serverURL: "\(server.baseURL)/mcp") { _ in
            OAuthStoredCredential(
                serverURL: "\(server.baseURL)/mcp",
                tokens: OAuthTokens(
                    accessToken: "access-token-preseeded-000009",
                    expiresAt: Date().timeIntervalSince1970 + 3600
                )
            )
        }

        let manager = MCPManager()
        let config = MCPServerConfig(
            command: [],
            url: "\(server.baseURL)/mcp",
            transport: .streamableHTTP,
            allowPrivateNetwork: true,
            oauth: MCPOAuthConfig(
                authorizationEndpoint: "\(server.baseURL)/authorize",
                tokenEndpoint: "\(server.baseURL)/token",
                clientId: "client-abc"
            )
        )
        _ = await manager.connect(
            servers: ["jira": config],
            workspaceDirectory: scratch.path,
            oauth: MCPManager.OAuthSetup(
                configDirectory: scratch.path,
                allowInteractive: false,
                browser: SilentBrowser()
            )
        )
        await manager.shutdown()

        #expect(
            authorizations.values.allSatisfy { $0 == "Bearer access-token-preseeded-000009" },
            "every MCP request must carry the OAuth token"
        )
        #expect(!authorizations.values.isEmpty, "the handshake must have reached the endpoint")
    }

    @Test("OAuth outranks a configured static bearer token")
    func oauthOutranksStatic() async throws {
        let scratch = try ScratchDirectory()
        let authorizations = Recorder<String?>()
        let server = try await TestHTTPServer.start(
            router: combinedRouter(mcpAuthorizations: authorizations, issue: "access-token-oauth-000002")
        )
        defer { server.stop() }

        let store = OAuthTokenStore(directory: scratch.path + "/mcp-oauth")
        _ = try await store.mutate(forKey: "jira", serverURL: "\(server.baseURL)/mcp") { _ in
            OAuthStoredCredential(
                serverURL: "\(server.baseURL)/mcp",
                tokens: OAuthTokens(
                    accessToken: "access-token-oauth-000002",
                    expiresAt: Date().timeIntervalSince1970 + 3600
                )
            )
        }

        let manager = MCPManager()
        // The static credential is supplied through the credentialReference
        // seam rather than a process-global env var — no shared mutable state
        // that a parallel suite could race on.
        let config = MCPServerConfig(
            command: [],
            url: "\(server.baseURL)/mcp",
            transport: .streamableHTTP,
            credentialReference: "static-cred",
            allowPrivateNetwork: true,
            oauth: MCPOAuthConfig(
                authorizationEndpoint: "\(server.baseURL)/authorize",
                tokenEndpoint: "\(server.baseURL)/token",
                clientId: "client-abc"
            )
        )
        _ = await manager.connect(
            servers: ["jira": config],
            workspaceDirectory: scratch.path,
            credentialProvider: { $0 == "static-cred" ? "static-token-should-lose" : nil },
            oauth: MCPManager.OAuthSetup(
                configDirectory: scratch.path, allowInteractive: false, browser: SilentBrowser()
            )
        )
        await manager.shutdown()

        #expect(
            authorizations.values.allSatisfy { $0 == "Bearer access-token-oauth-000002" },
            "the OAuth token wins; the static env token must never be sent"
        )
        #expect(
            !authorizations.values.contains("Bearer static-token-should-lose"),
            "the stale env token must be fully shadowed"
        )
    }

    @Test("An oauth server on a surface with no OAuth support is skipped, not connected")
    func skippedWithoutSetup() async throws {
        let scratch = try ScratchDirectory()
        let authorizations = Recorder<String?>()
        let server = try await TestHTTPServer.start(
            router: combinedRouter(mcpAuthorizations: authorizations, issue: "unused")
        )
        defer { server.stop() }

        let logs = Recorder<String>()
        let manager = MCPManager()
        let config = MCPServerConfig(
            command: [],
            url: "\(server.baseURL)/mcp",
            transport: .streamableHTTP,
            allowPrivateNetwork: true,
            oauth: MCPOAuthConfig(clientId: "client-abc")
        )
        // No `oauth:` OAuthSetup passed — the surface provides no support.
        let tools = await manager.connect(
            servers: ["jira": config],
            workspaceDirectory: scratch.path,
            log: { logs.append($0) }
        )
        await manager.shutdown()

        #expect(tools.isEmpty, "the server must be skipped, not connected credential-less")
        #expect(authorizations.values.isEmpty, "no MCP request may be made for a skipped server")
        #expect(
            logs.values.contains { $0.contains("no OAuth support") },
            "the skip must be explained in the log"
        )
    }
}
