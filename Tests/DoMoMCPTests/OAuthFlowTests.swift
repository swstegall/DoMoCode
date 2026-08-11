// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The OAuth machinery against real sockets: the loopback listener's state
// discipline (a wrong-state probe answers 400 and the flow KEEPS waiting),
// its TLS variant under the generated self-signed certificate, and the
// provider end to end — a scripted "browser" walks the authorize URL exactly
// as a real one would, a stub IdP validates what arrives, and the assertions
// check the wire: PKCE challenge matches verifier, resource and redirect_uri
// are byte-exact, refresh retains the old refresh token when the response
// omits one (the ADFS behavior), invalid_grant falls back to interactive,
// and concurrent demands collapse into one token request.
//
// Serialized: every test owns sockets. Ports are ephemeral (allocated by
// binding 0) — a fixed port would collide with parallel case execution.

import AsyncHTTPClient
import Crypto
import DoMoCore
import DoMoMCP
import Foundation
import Hummingbird
import NIOCore
import NIOSSL
import Testing

private final class ScratchDirectory: Sendable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "domocode-oauth-flow-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A browser that "visits" the authorize URL the way a human's would end:
/// by following the IdP's redirect back to the loopback listener with a code
/// and the flow's own state. Records every URL it was asked to open.
private struct ScriptedBrowser: BrowserLaunching {
    let opened: Recorder<String>
    var code: String = "fake-authorization-code-1"

    func open(_ url: String) async -> Bool {
        opened.append(url)
        guard
            let components = URLComponents(string: url),
            let items = components.queryItems
        else { return false }
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value }
        guard let redirect = query["redirect_uri"], let state = query["state"] else { return false }
        let callback = "\(redirect)?code=\(code)&state=\(state)"
        // Detached so `open` returns like the real launcher; the listener is
        // already bound (the provider opens the browser from onListening).
        let request = HTTPClientRequest(url: callback)
        Task { _ = try? await HTTPClient.shared.execute(request, timeout: .seconds(10)) }
        return true
    }
}

// MARK: - Listener

@Suite("OAuth loopback listener", .serialized)
struct OAuthLoopbackListenerTests {

    @Test("A state-matched callback completes the flow and answers the browser")
    func happyPath() async throws {
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:0/callback")
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        let outcome = try await withThrowingTaskGroup(of: OAuthCallbackOutcome?.self) { group in
            group.addTask {
                try await OAuthLoopbackListener.capture(
                    endpoint: endpoint,
                    expectedState: "state-abc",
                    tlsIdentity: nil,
                    timeout: .seconds(10),
                    onListening: { port in continuation.yield(port) }
                )
            }
            group.addTask {
                var iterator = ports.makeAsyncIterator()
                guard let port = await iterator.next() else { return nil }
                let url = "http://127.0.0.1:\(port)/callback?code=code-123&state=state-abc"
                let response = try await HTTPClient.shared.execute(
                    HTTPClientRequest(url: url), timeout: .seconds(10)
                )
                #expect(response.status == .ok, "the browser must get a success page")
                return nil
            }
            var captured: OAuthCallbackOutcome?
            for try await value in group {
                if let value { captured = value; group.cancelAll() }
            }
            return captured
        }
        #expect(outcome?.code == "code-123")
        #expect(outcome?.error == nil)
    }

    @Test("A wrong-state probe is answered 400 and does not end the flow")
    func stateMismatchKeepsWaiting() async throws {
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:0/callback")
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        let outcome = try await withThrowingTaskGroup(of: OAuthCallbackOutcome?.self) { group in
            group.addTask {
                try await OAuthLoopbackListener.capture(
                    endpoint: endpoint,
                    expectedState: "state-genuine",
                    tlsIdentity: nil,
                    timeout: .seconds(10),
                    onListening: { port in continuation.yield(port) }
                )
            }
            group.addTask {
                var iterator = ports.makeAsyncIterator()
                guard let port = await iterator.next() else { return nil }
                // The CSRF probe: attacker-chosen state. Must be rejected AND
                // must not complete or kill the wait.
                let probe = try await HTTPClient.shared.execute(
                    HTTPClientRequest(
                        url: "http://127.0.0.1:\(port)/callback?code=evil&state=state-forged"
                    ),
                    timeout: .seconds(10)
                )
                #expect(probe.status == .badRequest)
                // The genuine callback still lands afterwards.
                let genuine = try await HTTPClient.shared.execute(
                    HTTPClientRequest(
                        url: "http://127.0.0.1:\(port)/callback?code=good&state=state-genuine"
                    ),
                    timeout: .seconds(10)
                )
                #expect(genuine.status == .ok)
                return nil
            }
            var captured: OAuthCallbackOutcome?
            for try await value in group {
                if let value { captured = value; group.cancelAll() }
            }
            return captured
        }
        #expect(outcome?.code == "good", "only the state-matched callback may win")
    }

    @Test("An IdP error lands as a typed denial, not a code")
    func errorCallback() async throws {
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:0/callback")
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        let outcome = try await withThrowingTaskGroup(of: OAuthCallbackOutcome?.self) { group in
            group.addTask {
                try await OAuthLoopbackListener.capture(
                    endpoint: endpoint,
                    expectedState: "state-1",
                    tlsIdentity: nil,
                    timeout: .seconds(10),
                    onListening: { port in continuation.yield(port) }
                )
            }
            group.addTask {
                var iterator = ports.makeAsyncIterator()
                guard let port = await iterator.next() else { return nil }
                _ = try await HTTPClient.shared.execute(
                    HTTPClientRequest(
                        url: "http://127.0.0.1:\(port)/callback?error=access_denied&state=state-1"
                    ),
                    timeout: .seconds(10)
                )
                return nil
            }
            var captured: OAuthCallbackOutcome?
            for try await value in group {
                if let value { captured = value; group.cancelAll() }
            }
            return captured
        }
        #expect(outcome?.code == nil)
        #expect(outcome?.error == "access_denied")
    }

    @Test("An abandoned login times out instead of hanging the agent")
    func abandonedTimesOut() async throws {
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:0/callback")
        await #expect(throws: MCPOAuthError.self) {
            _ = try await OAuthLoopbackListener.capture(
                endpoint: endpoint,
                expectedState: "state-1",
                tlsIdentity: nil,
                timeout: .milliseconds(400)
            )
        }
    }

    @Test("The TLS listener serves the self-signed identity end to end")
    func tlsVariant() async throws {
        let scratch = try ScratchDirectory()
        let identity = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        let endpoint = try OAuthRedirectEndpoint(redirectURI: "https://localhost:0/redirect")
        #expect(endpoint.useTLS)

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(tlsConfiguration: tls)
        )
        var shutdownError: (any Error)?
        do {
            let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
            let outcome = try await withThrowingTaskGroup(of: OAuthCallbackOutcome?.self) { group in
                group.addTask {
                    try await OAuthLoopbackListener.capture(
                        endpoint: endpoint,
                        expectedState: "state-tls",
                        tlsIdentity: identity,
                        timeout: .seconds(10),
                        onListening: { port in continuation.yield(port) }
                    )
                }
                group.addTask {
                    var iterator = ports.makeAsyncIterator()
                    guard let port = await iterator.next() else { return nil }
                    let response = try await client.execute(
                        HTTPClientRequest(
                            url: "https://127.0.0.1:\(port)/redirect?code=tls-code&state=state-tls"
                        ),
                        timeout: .seconds(10)
                    )
                    #expect(response.status == .ok)
                    return nil
                }
                var captured: OAuthCallbackOutcome?
                for try await value in group {
                    if let value { captured = value; group.cancelAll() }
                }
                return captured
            }
            #expect(outcome?.code == "tls-code")
        } catch {
            shutdownError = error
        }
        try await client.shutdown()
        if let shutdownError { throw shutdownError }
    }
}

// MARK: - Provider

@Suite("OAuth provider flow", .serialized)
struct OAuthProviderFlowTests {

    private func makeProvider(
        scratch: ScratchDirectory,
        serverURL: String,
        config: MCPOAuthConfig,
        browser: any BrowserLaunching,
        store: OAuthTokenStore? = nil
    ) -> (MCPOAuthProvider, OAuthTokenStore) {
        let store = store ?? OAuthTokenStore(directory: scratch.path)
        let provider = MCPOAuthProvider(
            serverName: "stub",
            serverURL: serverURL,
            config: config,
            dependencies: MCPOAuthDependencies(
                store: store,
                browser: browser,
                certificateDirectory: scratch.path,
                authorizationTimeout: .seconds(20)
            )
        )
        return (provider, store)
    }

    @Test("The interactive login round-trips PKCE, exchanges the code, and caches")
    func interactiveLogin() async throws {
        let scratch = try ScratchDirectory()
        let redirectPort = try await allocateLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

        let tokenRequests = Recorder<[String: String]>()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let fields = parseForm(String(buffer: buffer))
            tokenRequests.append(fields)
            guard fields["grant_type"] == "authorization_code",
                  fields["code"] == "fake-authorization-code-1"
            else { return jsonResponse(.badRequest, ["error": "invalid_grant"]) }
            return jsonResponse(.ok, [
                "access_token": "access-token-alpha-000001",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "refresh-token-alpha-000001",
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        let opened = Recorder<String>()
        let serverURL = "https://mcp.example.invalid/mcp"
        let (provider, store) = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc",
                scope: "openid profile",
                resource: "urn:example:mcp-api",
                redirectUri: redirectURI
            ),
            browser: ScriptedBrowser(opened: opened)
        )

        let token = try await provider.accessToken(allowInteractive: true)
        #expect(token == "access-token-alpha-000001")

        // The authorize URL the "browser" saw: PKCE S256, the exact redirect,
        // the resource indicator, the configured scope.
        let authorizeURL = try #require(opened.values.first.flatMap(URLComponents.init(string:)))
        var query: [String: String] = [:]
        for item in authorizeURL.queryItems ?? [] { query[item.name] = item.value }
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == "client-abc")
        #expect(query["redirect_uri"] == redirectURI)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["scope"] == "openid profile")
        #expect(query["resource"] == "urn:example:mcp-api")

        // The exchange carried the matching verifier — recomputing the
        // challenge from what the token endpoint received must reproduce what
        // the authorize URL promised.
        let exchange = try #require(tokenRequests.values.first)
        let verifier = try #require(exchange["code_verifier"])
        let recomputed = base64URL(Array(SHA256.hash(data: Data(verifier.utf8))))
        #expect(recomputed == query["code_challenge"])
        #expect(exchange["redirect_uri"] == redirectURI)
        #expect(exchange["client_id"] == "client-abc")
        #expect(exchange["resource"] == "urn:example:mcp-api")

        // Cached: a second ask answers from memory of the store, not the wire.
        let again = try await provider.accessToken(allowInteractive: false)
        #expect(again == token)
        #expect(tokenRequests.count == 1, "a fresh token must not re-hit the endpoint")

        // Persisted for the next run, bound to this server URL.
        let stored = await store.credential(forKey: "stub", serverURL: serverURL)
        #expect(stored?.tokens?.refreshToken == "refresh-token-alpha-000001")

        // And the secrets are in the redaction vault the moment they exist.
        let diagnostic = Redaction.diagnostic("leaked access-token-alpha-000001 in an error")
        #expect(!diagnostic.contains("access-token-alpha-000001"))
    }

    @Test("An expired access token refreshes silently and keeps the old refresh token")
    func silentRefreshRetainsRefreshToken() async throws {
        let scratch = try ScratchDirectory()
        let tokenRequests = Recorder<[String: String]>()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let fields = parseForm(String(buffer: buffer))
            tokenRequests.append(fields)
            guard fields["grant_type"] == "refresh_token" else {
                return jsonResponse(.badRequest, ["error": "unsupported_grant_type"])
            }
            // Deliberately NO refresh_token in the response: the ADFS shape.
            return jsonResponse(.ok, [
                "access_token": "access-token-beta-000002",
                "token_type": "Bearer",
                "expires_in": 3600,
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        let serverURL = "https://mcp.example.invalid/mcp"
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "stub", serverURL: serverURL) { _ in
            OAuthStoredCredential(
                serverURL: serverURL,
                tokens: OAuthTokens(
                    accessToken: "access-token-expired-000000",
                    refreshToken: "refresh-token-keep-000009",
                    expiresAt: Date().timeIntervalSince1970 - 10
                )
            )
        }
        let (provider, _) = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc",
                resource: "urn:example:mcp-api"
            ),
            browser: ScriptedBrowser(opened: Recorder<String>()),
            store: store
        )

        // allowInteractive false: this is the mid-session path — refresh must
        // suffice with no browser.
        let token = try await provider.accessToken(allowInteractive: false)
        #expect(token == "access-token-beta-000002")

        let request = try #require(tokenRequests.values.first)
        #expect(request["refresh_token"] == "refresh-token-keep-000009")
        #expect(request["client_id"] == "client-abc")
        #expect(request["resource"] == "urn:example:mcp-api", "ADFS mints the wrong audience without it")

        let stored = await store.credential(forKey: "stub", serverURL: serverURL)
        #expect(
            stored?.tokens?.refreshToken == "refresh-token-keep-000009",
            "a response without refresh_token keeps the old one — ADFS does not rotate"
        )
    }

    @Test("A dead refresh grant falls back to the interactive flow")
    func invalidGrantFallsBackToInteractive() async throws {
        let scratch = try ScratchDirectory()
        let redirectPort = try await allocateLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

        let grants = Recorder<String>()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let fields = parseForm(String(buffer: buffer))
            grants.append(fields["grant_type"] ?? "?")
            switch fields["grant_type"] {
            case "refresh_token":
                return jsonResponse(.badRequest, [
                    "error": "invalid_grant",
                    "error_description": "MSIS9615: The refresh token has expired.",
                ])
            case "authorization_code":
                return jsonResponse(.ok, [
                    "access_token": "access-token-gamma-000003",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "refresh_token": "refresh-token-gamma-000003",
                ])
            default:
                return jsonResponse(.badRequest, ["error": "unsupported_grant_type"])
            }
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        let serverURL = "https://mcp.example.invalid/mcp"
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "stub", serverURL: serverURL) { _ in
            OAuthStoredCredential(
                serverURL: serverURL,
                tokens: OAuthTokens(
                    accessToken: "access-token-expired-000000",
                    refreshToken: "refresh-token-dead-000004",
                    expiresAt: Date().timeIntervalSince1970 - 10
                )
            )
        }
        let (provider, _) = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc",
                redirectUri: redirectURI
            ),
            browser: ScriptedBrowser(opened: Recorder<String>()),
            store: store
        )

        let token = try await provider.accessToken(allowInteractive: true)
        #expect(token == "access-token-gamma-000003")
        #expect(grants.values == ["refresh_token", "authorization_code"],
                "refresh first, then — and only then — the browser")

        let stored = await store.credential(forKey: "stub", serverURL: serverURL)
        #expect(stored?.tokens?.refreshToken == "refresh-token-gamma-000003")
    }

    @Test("Where interaction is not allowed, the failure is typed, not a hang")
    func interactionRequiredIsTyped() async throws {
        let scratch = try ScratchDirectory()
        let (provider, _) = makeProvider(
            scratch: scratch,
            serverURL: "https://mcp.example.invalid/mcp",
            config: MCPOAuthConfig(
                authorizationEndpoint: "https://idp.invalid/authorize",
                tokenEndpoint: "https://idp.invalid/token",
                clientId: "client-abc"
            ),
            browser: ScriptedBrowser(opened: Recorder<String>())
        )
        do {
            _ = try await provider.accessToken(allowInteractive: false)
            Issue.record("an interactive-only situation must not succeed silently")
        } catch let error as MCPOAuthError {
            guard case .interactionRequired = error else {
                Issue.record("expected interactionRequired, got \(error)")
                return
            }
        }
    }

    @Test("Concurrent token demands collapse into one refresh")
    func concurrentRefreshSingleFlight() async throws {
        let scratch = try ScratchDirectory()
        let tokenRequests = Recorder<[String: String]>()
        // The gate holds the refresh open until the test has both callers in
        // flight — no timing dependence. Coalescing is the per-cache-key flow
        // lock: caller 1 holds it (blocked in the stub), caller 2 blocks
        // acquiring it, and when released caller 2 re-reads the fresh token
        // and returns without a second wire call. A broken lock (or a broken
        // under-lock re-read) would send a second request that also blocks on
        // the gate, making `count` 2 after release; correct behavior keeps it
        // at 1.
        let gate = Gate()
        let router = Router(context: BasicRequestContext.self)
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            tokenRequests.append(parseForm(String(buffer: buffer)))
            await gate.wait()
            return jsonResponse(.ok, [
                "access_token": "access-token-delta-000005",
                "token_type": "Bearer",
                "expires_in": 3600,
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }

        let serverURL = "https://mcp.example.invalid/mcp"
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "stub", serverURL: serverURL) { _ in
            OAuthStoredCredential(
                serverURL: serverURL,
                tokens: OAuthTokens(
                    accessToken: "access-token-expired-000000",
                    refreshToken: "refresh-token-shared-000006",
                    expiresAt: Date().timeIntervalSince1970 - 10
                )
            )
        }
        let (provider, _) = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(
                authorizationEndpoint: "\(idp.baseURL)/authorize",
                tokenEndpoint: "\(idp.baseURL)/token",
                clientId: "client-abc"
            ),
            browser: ScriptedBrowser(opened: Recorder<String>()),
            store: store
        )

        // Two forced refreshes for the SAME rejected token: the classic double
        // 401. Both are launched, then given time to reach the coalescing
        // point while the gate holds the (single) refresh open, then released.
        let rejected = "access-token-expired-000000"
        async let first = provider.accessToken(
            forceRefresh: true, allowInteractive: false, rejectedToken: rejected
        )
        async let second = provider.accessToken(
            forceRefresh: true, allowInteractive: false, rejectedToken: rejected
        )
        try await Task.sleep(for: .milliseconds(200))
        gate.open()
        let (a, b) = try await (first, second)
        #expect(a == "access-token-delta-000005")
        #expect(a == b)
        #expect(tokenRequests.count == 1, "two 401s must not mean two refreshes")
    }

    @Test("Discovery walks metadata to registration and the full login")
    func discoveryAndDynamicRegistration() async throws {
        let scratch = try ScratchDirectory()
        let redirectPort = try await allocateLoopbackPort()
        let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"

        let registrations = Recorder<String>()
        let tokenRequests = Recorder<[String: String]>()
        let idpBox = ValueBox<String>()

        let router = Router(context: BasicRequestContext.self)
        // RFC 9728, path-inserted for a server living at /mcp.
        router.get("/.well-known/oauth-protected-resource/mcp") { _, _ in
            jsonResponse(.ok, [
                "resource": "\(idpBox.value ?? "")/mcp",
                "authorization_servers": ["\(idpBox.value ?? "")/issuer"],
                "scopes_supported": ["mcp.read"],
            ])
        }
        // The RFC 8414 spellings 404 (unrouted); only the path-appended OIDC
        // document exists — the ADFS shape — proving the fallback ladder.
        router.get("/issuer/.well-known/openid-configuration") { _, _ in
            jsonResponse(.ok, [
                "issuer": "\(idpBox.value ?? "")/issuer",
                "authorization_endpoint": "\(idpBox.value ?? "")/authorize",
                "token_endpoint": "\(idpBox.value ?? "")/token",
                "registration_endpoint": "\(idpBox.value ?? "")/register",
                "code_challenge_methods_supported": ["S256"],
            ])
        }
        router.post("/register") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            registrations.append(String(buffer: buffer))
            return jsonResponse(.created, ["client_id": "dcr-client-000007"])
        }
        router.post("/token") { request, _ in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let fields = parseForm(String(buffer: buffer))
            tokenRequests.append(fields)
            guard fields["client_id"] == "dcr-client-000007" else {
                return jsonResponse(.badRequest, ["error": "invalid_client"])
            }
            return jsonResponse(.ok, [
                "access_token": "access-token-epsilon-000008",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "refresh-token-epsilon-000008",
            ])
        }
        let idp = try await TestHTTPServer.start(router: router)
        defer { idp.stop() }
        idpBox.set(idp.baseURL)

        let serverURL = "\(idp.baseURL)/mcp"
        let (provider, store) = makeProvider(
            scratch: scratch,
            serverURL: serverURL,
            config: MCPOAuthConfig(redirectUri: redirectURI),
            browser: ScriptedBrowser(opened: Recorder<String>())
        )

        let token = try await provider.accessToken(allowInteractive: true)
        #expect(token == "access-token-epsilon-000008")
        #expect(registrations.count == 1)
        // Decoded rather than substring-matched: JSONEncoder escapes the
        // slashes in the URI, which is fine on the wire and fatal to a
        // `.contains` check.
        let registration = try #require(registrations.values.first)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(registration.utf8)) as? [String: Any]
        )
        #expect(
            decoded["redirect_uris"] as? [String] == [redirectURI],
            "DCR must register the exact redirect"
        )
        #expect(
            decoded["token_endpoint_auth_method"] as? String == "none",
            "a PKCE client is public"
        )

        let stored = await store.credential(forKey: "stub", serverURL: serverURL)
        #expect(stored?.client?.clientId == "dcr-client-000007", "the registration persists for reuse")
    }
}
