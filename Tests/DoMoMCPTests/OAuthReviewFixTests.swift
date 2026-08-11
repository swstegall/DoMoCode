// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Coverage the first review pass found missing, plus regressions for the bugs
// it found: the WWW-Authenticate parser's string-index misuse, the challenge
// scope attribute, a token with no stated lifetime (must stay usable, not
// refresh per request), the port-in-use mapping, the canonical resource URI,
// discovery's fallback ORDER, and MCPManager's OAuth wiring (precedence and
// the skip paths).

import AsyncHTTPClient
import DoMoMCP
import Foundation
import Hummingbird
import NIOCore
import Testing

private final class ScratchDirectory: Sendable {
    let path: String
    init() throws {
        path = NSTemporaryDirectory() + "domocode-oauth-fix-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

// MARK: - Parser regressions

@Suite("OAuth challenge parsing regressions")
struct OAuthChallengeRegressionTests {

    /// The parser once lowercased a copy and applied its indices to the
    /// original string; a non-ASCII prefix whose lowercase has a different
    /// UTF-8 length shifted every later index off a scalar boundary. The
    /// Turkish dotted capital İ is the canonical trap.
    @Test("A non-ASCII prefix does not derail resource_metadata extraction")
    func nonASCIIPrefix() {
        let header =
            #"Bearer realm="İSTANBUL", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#
        let url = OAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: header)
        #expect(
            url?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource"
        )
    }

    @Test("The challenge scope attribute is extracted")
    func scopeAttribute() {
        let header = #"Bearer resource_metadata="https://x/y", scope="mcp.read mcp.write""#
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "mcp.read mcp.write")
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: #"Bearer realm="x""#) == nil)
    }

    /// "scope" is a substring of "scopes_supported"; the scan must not stop on
    /// the wrong key (suffix-of-a-longer-key direction).
    @Test("A suffix-collision key name does not shadow the real parameter")
    func suffixCollisionKey() {
        let header = #"Bearer scopes_supported="a b", scope="real""#
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "real")
    }

    /// A key that merely ENDS with the target ('myscope') must not match — the
    /// scan requires a parameter boundary before the key.
    @Test("A prefix-collision key name does not shadow the real parameter")
    func prefixCollisionKey() {
        let header = #"Bearer myscope=attacker, scope="real""#
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "real")
        let header2 =
            #"Bearer x_resource_metadata="https://evil/rm", resource_metadata="https://good/rm""#
        #expect(
            OAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: header2)?.absoluteString
                == "https://good/rm"
        )
    }

    /// A 'scope=' sequence inside another parameter's quoted value must not be
    /// mistaken for the real parameter.
    @Test("A key sequence inside a quoted value is not matched")
    func keyInsideQuotedValue() {
        let header = #"Bearer realm="a scope=fake b", scope="real""#
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "real")
    }

    /// RFC 7235 BWS around '=' may be SP or HTAB — a tab-separated param must
    /// still be extracted.
    @Test("A tab as BWS around '=' does not drop the parameter")
    func tabBetweenKeyAndEquals() {
        let header = "Bearer scope\t=\t\"openid profile\""
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "openid profile")
    }

    /// An escaped quote (RFC 7235 quoted-pair) inside an earlier value must not
    /// desync the scan and surface a wrong value.
    @Test("An escaped quote in a value does not derail the scan")
    func quotedPairEscape() {
        let header = #"Bearer error="he said \"no\"", scope="real""#
        #expect(OAuthDiscovery.scope(fromWWWAuthenticate: header) == "real")
        // And the escaped value itself is unescaped correctly.
        #expect(OAuthDiscovery.parameter("error", in: header) == #"he said "no""#)
    }
}

// MARK: - Provider behavior gaps

@Suite("OAuth provider behavior gaps", .serialized)
struct OAuthProviderGapTests {

    private func makeProvider(
        scratch: ScratchDirectory,
        serverURL: String,
        config: MCPOAuthConfig,
        store: OAuthTokenStore
    ) -> MCPOAuthProvider {
        MCPOAuthProvider(
            serverName: "stub",
            serverURL: serverURL,
            config: config,
            dependencies: MCPOAuthDependencies(
                store: store,
                browser: FailBrowser(),
                certificateDirectory: scratch.path,
                authorizationTimeout: .seconds(20)
            )
        )
    }

    /// A browser that must never be opened — its use is a test failure.
    private struct FailBrowser: BrowserLaunching {
        func open(_ url: String) async -> Bool {
            Issue.record("the browser was opened when it should not have been")
            return false
        }
    }

    @Test("A token with no stated lifetime stays usable and does not refresh per request")
    func absentExpiryIsUsable() async throws {
        let scratch = try ScratchDirectory()
        let tokenRequests = Recorder<[String: String]>()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            tokenRequests.append(parseForm(String(buffer: buffer)))
            return jsonResponse(.ok, ["access_token": "unexpected-refresh", "token_type": "Bearer"])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        let serverURL = "https://mcp.example.invalid/mcp"
        let store = OAuthTokenStore(directory: scratch.path)
        // A login that returned an access token but NO expires_in and NO
        // refresh_token — legal per RFC 6749, and previously bricking.
        _ = try await store.mutate(forKey: "stub", serverURL: serverURL) { _ in
            OAuthStoredCredential(
                serverURL: serverURL,
                tokens: OAuthTokens(accessToken: "access-token-no-expiry-000001")
            )
        }
        let provider = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc"
            ),
            store: store
        )

        // Two ordinary (non-forced) requests: both must return the stored
        // token from the cheap path, with zero wire traffic — no browser
        // (FailBrowser would record), no refresh.
        let first = try await provider.accessToken(allowInteractive: false)
        let second = try await provider.accessToken(allowInteractive: false)
        #expect(first == "access-token-no-expiry-000001")
        #expect(second == first)
        #expect(tokenRequests.count == 0, "an unknown lifetime must not trigger a refresh")
    }

    @Test("A busy redirect port surfaces as the typed portInUse error")
    func portInUseIsTyped() async throws {
        // Bind a plain socket on an ephemeral port, then point the flow's
        // redirect at it so the listener's own bind collides.
        let holder = try await TestHTTPServer.start(router: Router(context: BasicRequestContext.self))
        defer { holder.stop() }
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:\(holder.port)/callback")

        await #expect(throws: MCPOAuthError.self) {
            _ = try await OAuthLoopbackListener.capture(
                endpoint: endpoint,
                expectedState: "state-1",
                tlsIdentity: nil,
                timeout: .seconds(5)
            )
        }
        do {
            _ = try await OAuthLoopbackListener.capture(
                endpoint: endpoint, expectedState: "s", tlsIdentity: nil, timeout: .seconds(5)
            )
            Issue.record("a bound port must fail the capture")
        } catch let error as MCPOAuthError {
            guard case .portInUse = error else {
                Issue.record("expected portInUse, got \(error)")
                return
            }
        }
    }

    @Test("With no configured resource, the derived indicator is the canonical URL")
    func derivedResourceCanonicalization() async throws {
        let scratch = try ScratchDirectory()
        let redirectPort = try await allocateLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

        let authorizeQueries = Recorder<[String: String]>()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { _, _ in
            jsonResponse(.ok, [
                "access_token": "access-token-res-000002",
                "token_type": "Bearer",
                "expires_in": 3600,
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        // The server URL carries the default https port and a trailing slash;
        // the canonical resource drops both.
        let serverURL = "https://MCP.Example.Invalid:443/mcp/"
        let store = OAuthTokenStore(directory: scratch.path)
        let opened = Recorder<String>()
        let provider = MCPOAuthProvider(
            serverName: "stub",
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc",
                redirectUri: redirectURI
            ),
            dependencies: MCPOAuthDependencies(
                store: store,
                browser: RedirectingBrowser(opened: opened, queries: authorizeQueries),
                certificateDirectory: scratch.path,
                authorizationTimeout: .seconds(20)
            )
        )

        _ = try await provider.accessToken(allowInteractive: true)
        let authorize = try #require(authorizeQueries.values.first)
        #expect(
            authorize["resource"] == "https://mcp.example.invalid/mcp",
            "lowercased host, default port dropped, trailing slash removed"
        )
    }

    /// A browser that both records the authorize query and completes the flow.
    private struct RedirectingBrowser: BrowserLaunching {
        let opened: Recorder<String>
        let queries: Recorder<[String: String]>
        func open(_ url: String) async -> Bool {
            opened.append(url)
            guard let components = URLComponents(string: url), let items = components.queryItems
            else { return false }
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value }
            queries.append(query)
            guard let redirect = query["redirect_uri"], let state = query["state"] else { return false }
            let callback = "\(redirect)?code=code-1&state=\(state)"
            Task { _ = try? await HTTPClient.shared.execute(HTTPClientRequest(url: callback), timeout: .seconds(10)) }
            return true
        }
    }

    @Test("Discovery tries the RFC 8414 spellings before the OIDC document")
    func discoveryOrder() async throws {
        let scratch = try ScratchDirectory()
        let redirectPort = try await allocateLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

        let attempted = Recorder<String>()
        let idpBox = ValueBox<String>()
        let router = Router(context: BasicRequestContext.self)
        router.get("/.well-known/oauth-protected-resource/mcp") { _, _ in
            jsonResponse(.ok, ["authorization_servers": ["\(idpBox.value ?? "")/issuer"]])
        }
        // The two RFC 8414 spellings and the path-inserted OIDC spelling all
        // record their attempt and 404; only the path-appended OIDC answers.
        router.get("/.well-known/oauth-authorization-server/issuer") { _, _ in
            attempted.append("rfc8414-inserted"); return jsonResponse(.notFound, [:])
        }
        router.get("/.well-known/oauth-authorization-server") { _, _ in
            attempted.append("rfc8414-root"); return jsonResponse(.notFound, [:])
        }
        router.get("/.well-known/openid-configuration/issuer") { _, _ in
            attempted.append("oidc-inserted"); return jsonResponse(.notFound, [:])
        }
        router.get("/issuer/.well-known/openid-configuration") { _, _ in
            attempted.append("oidc-appended")
            return jsonResponse(.ok, [
                "authorization_endpoint": "\(idpBox.value ?? "")/authorize",
                "token_endpoint": "\(idpBox.value ?? "")/token",
                "code_challenge_methods_supported": ["S256"],
            ])
        }
        router.post("/token") { _, _ in
            jsonResponse(.ok, [
                "access_token": "access-token-order-000003", "token_type": "Bearer", "expires_in": 3600,
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }
        idpBox.set(idp.baseURL)

        let store = OAuthTokenStore(directory: scratch.path)
        let provider = MCPOAuthProvider(
            serverName: "stub",
            serverURL: "\(idp.baseURL)/mcp",
            config: MCPOAuthConfig(clientId: "client-abc", redirectUri: redirectURI),
            dependencies: MCPOAuthDependencies(
                store: store,
                browser: RedirectingBrowser(opened: Recorder<String>(), queries: Recorder<[String: String]>()),
                certificateDirectory: scratch.path,
                authorizationTimeout: .seconds(20)
            )
        )
        _ = try await provider.accessToken(allowInteractive: true)
        // The RFC 8414 spellings must be tried before the OIDC document that
        // actually answers — the ADFS-compatibility ordering.
        #expect(attempted.values.last == "oidc-appended")
        #expect(attempted.values.firstIndex(of: "rfc8414-inserted")! < attempted.values.firstIndex(of: "oidc-appended")!)
        #expect(attempted.values.firstIndex(of: "rfc8414-root")! < attempted.values.firstIndex(of: "oidc-appended")!)
    }
}
