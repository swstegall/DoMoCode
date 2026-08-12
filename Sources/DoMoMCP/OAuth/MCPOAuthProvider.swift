// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The per-server OAuth orchestrator: everything between "the MCP client needs
// a bearer token" and "here is one that works".
//
// The order of preference is the cheap thing first, always:
//
//   1. the cached access token, while it has ≥60s to live;
//   2. a silent `refresh_token` grant, when one is stored and unexpired;
//   3. the interactive browser flow — PKCE, loopback listener, code exchange —
//      and only where the call site allows interaction. Mid-session requests
//      may never pop a browser; they fail typed (`interactionRequired`) and
//      the user re-authenticates at next startup.
//
// Concurrency discipline is one mechanism, not two: the store's per-cache-key
// flow lock. `flock` excludes two same-process tasks (each acquire opens its
// own descriptor) just as it excludes two processes, so concurrent 401s — in
// this process or a sibling `domo` — serialize on it, and each re-reads the
// store under the lock: the first does the work, the rest observe its result.
// No shared in-process coalescing task, deliberately — that would entangle one
// caller's cancellation and one caller's rejected-token with every other
// caller's, which a per-caller acquire keeps separate. Without this, two 401s
// would mean two refreshes and, on a rotating IdP, a dead refresh token.
//
// ADFS realities, verified against Microsoft's documentation, are first-class
// here rather than special-cased: `resource` goes on the authorize, exchange,
// and refresh requests (omitting it yields a token for `urn:microsoft:
// userinfo` that the MCP server rejects — an infinite-401 trap); a refresh
// response that omits `refresh_token` means KEEP the old one (ADFS does not
// rotate); `refresh_token_expires_in` is persisted so a dying refresh token
// becomes a planned re-login instead of a surprise; `invalid_grant` means the
// grant is dead — drop tokens, go interactive.

import AsyncHTTPClient
import DoMoCore
import Foundation

/// Everything the provider needs from its embedding, injectable for tests.
public struct MCPOAuthDependencies: Sendable {
    public var store: OAuthTokenStore
    public var browser: any BrowserLaunching
    /// The proxy-aware HTTP source; `MCPManager` passes its pooled clients.
    public var clientProvider: (@Sendable (URL) -> HTTPClient)?
    public var log: (@Sendable (String) -> Void)?
    /// The clock, a seam so expiry tests need no sleeping.
    public var now: @Sendable () -> Date
    /// Where the loopback TLS certificate is cached (the store's directory).
    public var certificateDirectory: String
    /// How long the browser flow may take before the agent gives up.
    public var authorizationTimeout: Duration

    public init(
        store: OAuthTokenStore,
        browser: any BrowserLaunching = SystemBrowserLauncher(),
        clientProvider: (@Sendable (URL) -> HTTPClient)? = nil,
        log: (@Sendable (String) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        certificateDirectory: String,
        authorizationTimeout: Duration = .seconds(300)
    ) {
        self.store = store
        self.browser = browser
        self.clientProvider = clientProvider
        self.log = log
        self.now = now
        self.certificateDirectory = certificateDirectory
        self.authorizationTimeout = authorizationTimeout
    }
}

/// The discovered authorization-server metadata that is safe to hand to a
/// remote SDK. It contains endpoints and capability hints only; no token,
/// client secret, verifier, or stored client credential crosses this boundary.
public struct MCPOAuthConfiguration: Sendable, Hashable, Codable {
    public let serverURL: String
    public let authorizationEndpoint: String?
    public let tokenEndpoint: String?
    public let registrationEndpoint: String?
    public let issuer: String?
    public let codeChallengeMethodsSupported: [String]?
    public let scopesSupported: [String]?
    public let clientId: String?
    public let scope: String?
    public let resource: String?
    public let redirectURI: String?
    public let cacheKey: String?

    public init(
        serverURL: String,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        registrationEndpoint: String? = nil,
        issuer: String? = nil,
        codeChallengeMethodsSupported: [String]? = nil,
        scopesSupported: [String]? = nil,
        clientId: String? = nil,
        scope: String? = nil,
        resource: String? = nil,
        redirectURI: String? = nil,
        cacheKey: String? = nil
    ) {
        self.serverURL = serverURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.issuer = issuer
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.scopesSupported = scopesSupported
        self.clientId = clientId
        self.scope = scope
        self.resource = resource
        self.redirectURI = redirectURI
        self.cacheKey = cacheKey
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL = "serverUrl"
        case authorizationEndpoint
        case tokenEndpoint
        case registrationEndpoint
        case issuer
        case codeChallengeMethodsSupported
        case scopesSupported
        case clientId
        case scope
        case resource
        case redirectURI = "redirectUri"
        case cacheKey
    }
}

public actor MCPOAuthProvider {
    /// The loopback default used when no redirect URI is configured — the
    /// RFC 8252 plain-HTTP shape every surveyed client registers.
    public static let defaultRedirectURI = "http://127.0.0.1:27182/oauth/callback"

    /// Access tokens within this margin of expiry are refreshed proactively,
    /// so the 401-retry path stays the rare fallback it is meant to be.
    static let expiryMargin: TimeInterval = 60

    private let serverName: String
    private let serverURL: String
    private let config: MCPOAuthConfig
    private let deps: MCPOAuthDependencies
    private let transport: OAuthHTTPTransport

    /// The token-store namespace for this server.
    private let cacheKey: String

    /// Discovery is per-run: endpoints learned once are reused until restart.
    private var discovered: OAuthServerMetadata?
    private var discoveredScopeHint: String?

    public init(
        serverName: String,
        serverURL: String,
        config: MCPOAuthConfig,
        dependencies: MCPOAuthDependencies
    ) {
        self.serverName = serverName
        self.serverURL = serverURL
        self.config = config
        self.deps = dependencies
        self.transport = OAuthHTTPTransport(clientProvider: dependencies.clientProvider)
        self.cacheKey = config.cacheKey ?? serverName
    }

    // MARK: - The one public question

    /// A currently valid access token, produced as cheaply as the situation
    /// allows. `forceRefresh` marks the current token as rejected (the 401
    /// path); `rejectedToken` is the exact token the caller's request used —
    /// so a sibling that already refreshed is observed rather than clobbered;
    /// `allowInteractive` gates the browser; `wwwAuthenticate` carries the
    /// server's challenge when a 401 provided one, feeding discovery.
    ///
    /// Concurrency is handled entirely by the store's per-cache-key flow lock,
    /// not by an in-process shared task: `flock` excludes two same-process
    /// tasks (each acquire opens its own descriptor), so concurrent callers
    /// serialize there and each re-reads the store under the lock — the first
    /// does the work, the rest observe its result. This keeps every caller's
    /// cancellation and every caller's own `rejectedToken` private to that
    /// caller, which a shared coalescing task cannot.
    public func accessToken(
        forceRefresh: Bool = false,
        allowInteractive: Bool,
        wwwAuthenticate: String? = nil,
        rejectedToken: String? = nil
    ) async throws -> String {
        // Cheap path: a cached, still-usable token, taken only when the caller
        // is not forcing a refresh.
        if !forceRefresh,
            let tokens = await deps.store.credential(forKey: cacheKey, serverURL: serverURL)?.tokens,
            isUsable(tokens)
        {
            return tokens.accessToken
        }
        // The token to treat as rejected: what the caller's failing request
        // actually sent (threaded from the 401 path), not a store snapshot a
        // sibling may already have refreshed past.
        let rejected = forceRefresh ? rejectedToken : nil
        return try await acquire(
            rejectedAccessToken: rejected,
            allowInteractive: allowInteractive,
            wwwAuthenticate: wwwAuthenticate
        )
    }

    /// Return the non-secret OAuth configuration needed by a remote SDK to
    /// complete its own browser flow. Discovery is attempted when explicit
    /// endpoints are incomplete; a discovery failure still returns the safe
    /// configured block so callers can report the actionable omission.
    public func configuration() async -> MCPOAuthConfiguration {
        let discovered: OAuthServerMetadata?
        if config.authorizationEndpoint != nil, config.tokenEndpoint != nil {
            discovered = nil
        } else {
            discovered = try? await resolveEndpoints(wwwAuthenticate: nil, allowNetwork: true)
        }
        return MCPOAuthConfiguration(
            serverURL: serverURL,
            authorizationEndpoint: config.authorizationEndpoint ?? discovered?.authorizationEndpoint,
            tokenEndpoint: config.tokenEndpoint ?? discovered?.tokenEndpoint,
            registrationEndpoint: discovered?.registrationEndpoint,
            issuer: discovered?.issuer,
            codeChallengeMethodsSupported: discovered?.codeChallengeMethodsSupported,
            scopesSupported: discovered?.scopesSupported,
            clientId: config.clientId,
            scope: config.scope ?? discoveredScopeHint,
            resource: config.resource,
            redirectURI: config.redirectUri,
            cacheKey: cacheKey
        )
    }

    // MARK: - Acquisition under the cross-process lock

    private func acquire(
        rejectedAccessToken: String?,
        allowInteractive: Bool,
        wwwAuthenticate: String?
    ) async throws -> String {
        // The flow lock is scoped to this cache key, so a browser login on one
        // server never stalls a silent refresh on another. An interactive
        // caller may hold it for the full authorization timeout; a refresh-only
        // caller waits at most that long for the same server's own login.
        try await deps.store.withExclusiveFlow(key: cacheKey, timeout: deps.authorizationTimeout) {
            // Re-read now that the lock is held: a sibling process may have
            // done this work while we waited. A fresh token that is not the
            // one just rejected is that sibling's answer.
            let current = await self.deps.store.credential(
                forKey: self.cacheKey,
                serverURL: self.serverURL
            )
            if let tokens = current?.tokens,
                await self.isUsable(tokens),
                tokens.accessToken != rejectedAccessToken
            {
                return tokens.accessToken
            }

            if let tokens = current?.tokens,
                tokens.refreshToken != nil,
                await self.refreshTokenUsable(tokens)
            {
                if let refreshed = try await self.refresh(
                    previousTokens: tokens,
                    client: current?.client,
                    wwwAuthenticate: wwwAuthenticate
                ) {
                    return refreshed
                }
                // nil means invalid_grant: tokens are gone from the store and
                // the only way forward is interactive.
            }

            return try await self.interactiveFlow(
                client: current?.client,
                wwwAuthenticate: wwwAuthenticate,
                allowInteractive: allowInteractive
            )
        }
    }

    // MARK: - Refresh

    /// Runs the `refresh_token` grant. Returns the new access token, or nil
    /// when the grant is dead (`invalid_grant`) and interactive login must
    /// follow. Any other failure throws — a flaky network must not cascade
    /// into a surprise browser.
    private func refresh(
        previousTokens: OAuthTokens,
        client: OAuthClientRegistration?,
        wwwAuthenticate: String?
    ) async throws -> String? {
        guard let refreshToken = previousTokens.refreshToken else { return nil }
        let endpoints = try await resolveEndpoints(wwwAuthenticate: wwwAuthenticate, allowNetwork: true)
        guard let tokenURL = URL(string: endpoints.tokenEndpoint) else {
            throw MCPOAuthError.configuration("the token endpoint is not a valid URL")
        }
        let clientId = config.clientId ?? client?.clientId
        guard let clientId else {
            // No identity to refresh under; treat like a dead grant.
            try await deps.store.removeTokens(forKey: cacheKey, serverURL: serverURL)
            return nil
        }
        log("MCP server '\(serverName)': refreshing the OAuth access token.")
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientId),
        ]
        if let secret = client?.clientSecret { fields.append(("client_secret", secret)) }
        if let resource = effectiveResource { fields.append(("resource", resource)) }
        if let scope = config.scope { fields.append(("scope", scope)) }

        // Honor cancellation up to the last moment before the grant is spent…
        try Task.checkCancellation()
        // …then run the grant and its persist without cancellation: a rotating
        // IdP invalidates the old refresh token the instant this POST lands, so
        // aborting between the wire and the store would strip the only usable
        // credential. The window is bounded by the token endpoint's timeout.
        let sendFields = fields
        let (status, body) = try await shieldingCancellation {
            try await self.transport.postForm(tokenURL, fields: sendFields)
        }
        if status == 200 {
            let response = try Self.decodeTokenResponse(body)
            let tokens = try await shieldingCancellation {
                try await self.persistTokens(from: response, previous: previousTokens, client: client)
            }
            return tokens.accessToken
        }
        let failure = Self.decodeTokenFailure(body)
        // A dead grant is any 4xx that decodes to invalid_grant — Auth0 answers
        // 403, others 400; keying on 400 alone wedges startup forever, retrying
        // the same dead refresh token every run. Drop it and fall to login.
        if (400..<500).contains(status), failure?.error == "invalid_grant" {
            log("MCP server '\(serverName)': the refresh token was rejected; a new login is needed.")
            try await deps.store.removeTokens(forKey: cacheKey, serverURL: serverURL)
            return nil
        }
        throw MCPOAuthError.tokenEndpoint(
            status: status,
            error: failure?.error.map(Self.sanitizeForDisplay),
            description: failure?.errorDescription.map(Self.sanitizeForDisplay)
        )
    }

    /// Runs `body` to completion even if the caller is cancelled. Used only for
    /// the token-endpoint exchange/refresh + its persist, where a partial run
    /// would burn a single-use code or a rotating refresh token. Awaiting an
    /// unstructured task's value does not propagate the caller's cancellation,
    /// which is exactly the shield wanted here (the interactive browser wait,
    /// by contrast, is deliberately left cancellable).
    private func shieldingCancellation<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task { try await body() }.value
    }

    /// Strips C0/C1 control characters from provider-controlled text before it
    /// enters an error that may be written to the terminal — an authorization
    /// server reached through an untrusted MCP server must not be able to smuggle
    /// ANSI/OSC escape sequences into the user's terminal via `error_description`.
    static func sanitizeForDisplay(_ text: String) -> String {
        let cleaned = String(
            text.unicodeScalars.filter { scalar in
                scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value))
            }
        )
        // Keep it bounded — an error_description is a sentence, not a payload.
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }

    // MARK: - Interactive flow

    private func interactiveFlow(
        client storedClient: OAuthClientRegistration?,
        wwwAuthenticate: String?,
        allowInteractive: Bool
    ) async throws -> String {
        guard allowInteractive else {
            throw MCPOAuthError.interactionRequired(
                "MCP server '\(serverName)' needs a browser login; restart domo to authenticate"
            )
        }
        let endpoints = try await resolveEndpoints(wwwAuthenticate: wwwAuthenticate, allowNetwork: true)
        guard
            let authorizeURLBase = URL(string: endpoints.authorizationEndpoint),
            let tokenURL = URL(string: endpoints.tokenEndpoint)
        else {
            throw MCPOAuthError.configuration("the authorize/token endpoints are not valid URLs")
        }

        // PKCE downgrade protection: when discovery supplied metadata, the
        // server must advertise S256, or the code_challenge is silently
        // ignored and PKCE protects nothing while appearing enabled.
        // Explicitly-configured endpoints have no metadata to check and are
        // trusted as configured.
        if let methods = endpoints.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw MCPOAuthError.discoveryFailed(
                "the authorization server does not advertise S256 PKCE support; "
                    + "DoMoCode will not proceed without it"
            )
        }

        let registration = try await resolveClient(
            stored: storedClient,
            metadata: endpoints
        )

        let redirect = try OAuthRedirectEndpoint(
            redirectURI: effectiveRedirectURI
        )
        let tlsIdentity: LoopbackTLSIdentity? =
            redirect.useTLS
            ? try SelfSignedCertificate.loopbackIdentity(
                in: deps.certificateDirectory,
                now: deps.now()
            )
            : nil

        let pkce = PKCE()
        let state = PKCE.randomState()
        let scope = config.scope ?? discoveredScopeHint

        var query: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientId),
            URLQueryItem(name: "redirect_uri", value: redirect.uri),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.challengeMethod),
        ]
        if let scope { query.append(URLQueryItem(name: "scope", value: scope)) }
        if let resource = effectiveResource {
            query.append(URLQueryItem(name: "resource", value: resource))
        }
        guard
            var components = URLComponents(url: authorizeURLBase, resolvingAgainstBaseURL: false)
        else {
            throw MCPOAuthError.configuration("the authorization endpoint is not a valid URL")
        }
        components.queryItems = (components.queryItems ?? []) + query
        guard let authorizeURL = components.url else {
            throw MCPOAuthError.configuration("could not compose the authorization URL")
        }

        // The URL is printed unconditionally and *before* anything can fail:
        // a broken `open`, a headless box, or a cert warning the user
        // dismissed too far all recover by pasting this by hand.
        if redirect.useTLS {
            log(
                "MCP server '\(serverName)': the login redirect uses a self-signed localhost "
                    + "certificate; the browser will warn once — choose to proceed."
            )
        }
        log(
            "MCP server '\(serverName)': opening the browser to log in. "
                + "If nothing opens, visit:\n  \(authorizeURL.absoluteString)"
        )

        let browser = deps.browser
        let outcome = try await OAuthLoopbackListener.capture(
            endpoint: redirect,
            expectedState: state,
            tlsIdentity: tlsIdentity,
            timeout: deps.authorizationTimeout,
            onListening: { _ in
                _ = await browser.open(authorizeURL.absoluteString)
            }
        )
        if let error = outcome.error {
            throw MCPOAuthError.authorizationDenied(
                error: Self.sanitizeForDisplay(error),
                description: outcome.errorDescription.map(Self.sanitizeForDisplay)
            )
        }
        guard let code = outcome.code else {
            throw MCPOAuthError.flowFailed("the login callback carried no authorization code")
        }

        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect.uri),
            ("client_id", registration.clientId),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = registration.clientSecret { fields.append(("client_secret", secret)) }
        if let resource = effectiveResource { fields.append(("resource", resource)) }

        // The code is single-use and expires in minutes; once exchanged, the
        // persist must complete, so shield the exchange like the refresh.
        let sendFields = fields
        let (status, body) = try await shieldingCancellation {
            try await self.transport.postForm(tokenURL, fields: sendFields)
        }
        guard status == 200 else {
            let failure = Self.decodeTokenFailure(body)
            throw MCPOAuthError.tokenEndpoint(
                status: status,
                error: failure?.error.map(Self.sanitizeForDisplay),
                description: failure?.errorDescription.map(Self.sanitizeForDisplay)
            )
        }
        let response = try Self.decodeTokenResponse(body)
        // A fresh login has no prior tokens to carry forward.
        let tokens = try await persistTokens(from: response, previous: nil, client: registration)
        let lifetime = response.expiresIn.map { "valid for \(Int($0))s" } ?? "lifetime unreported"
        log("MCP server '\(serverName)': login complete; access token \(lifetime).")
        return tokens.accessToken
    }

    // MARK: - Endpoints and client identity

    /// Explicit config wins; otherwise discovery, cached for the run.
    private func resolveEndpoints(
        wwwAuthenticate: String?,
        allowNetwork: Bool
    ) async throws -> OAuthServerMetadata {
        // Empty strings are "not configured" — matching the config validator,
        // which treats "" as absent — so a stray empty value falls through to
        // discovery rather than becoming an un-constructable endpoint URL.
        let configuredAuthorize = config.authorizationEndpoint.flatMap { $0.isEmpty ? nil : $0 }
        let configuredToken = config.tokenEndpoint.flatMap { $0.isEmpty ? nil : $0 }
        if let authorize = configuredAuthorize, let token = configuredToken {
            return OAuthServerMetadata(
                issuer: nil,
                authorizationEndpoint: authorize,
                tokenEndpoint: token,
                registrationEndpoint: nil,
                codeChallengeMethodsSupported: nil,
                scopesSupported: nil
            )
        }
        if configuredAuthorize != nil || configuredToken != nil {
            throw MCPOAuthError.configuration(
                "oauth.authorizationEndpoint and oauth.tokenEndpoint must be set together "
                    + "(or both omitted, to use discovery)"
            )
        }
        if let discovered { return discovered }
        guard allowNetwork, let url = URL(string: serverURL) else {
            throw MCPOAuthError.discoveryFailed("the server URL is not a valid URL")
        }
        // The MCP handshake order is request → 401 challenge → discover. Token
        // acquisition happens before any MCP request, so when no challenge was
        // handed in, probe the server for one: its WWW-Authenticate may point at
        // protected-resource metadata that is NOT at the default location, and
        // may name the exact scope. A probe failure is non-fatal — discovery
        // falls back to the RFC 9728 default location.
        let challenge: String?
        if let wwwAuthenticate {
            challenge = wwwAuthenticate
        } else {
            challenge = await probeChallenge(url)
        }
        let outcome = try await OAuthDiscovery.discover(
            serverURL: url,
            wwwAuthenticate: challenge,
            transport: transport
        )
        discovered = outcome.metadata
        discoveredScopeHint = outcome.scopeHint
        return outcome.metadata
    }

    /// An unauthenticated GET of the MCP server, returning its 401
    /// `WWW-Authenticate` challenge when it offers one. Best-effort: any error,
    /// or a non-401 answer, yields nil and discovery uses the default location.
    private func probeChallenge(_ url: URL) async -> String? {
        guard let (status, headers) = try? await transport.getHead(url) else { return nil }
        guard status == 401 else { return nil }
        return headers.first { $0.0.lowercased() == "www-authenticate" }?.1
    }

    /// A usable client identity: configured, previously registered (and not
    /// expired), or freshly registered where the server supports RFC 7591.
    private func resolveClient(
        stored: OAuthClientRegistration?,
        metadata: OAuthServerMetadata
    ) async throws -> OAuthClientRegistration {
        if let clientId = config.clientId {
            return OAuthClientRegistration(clientId: clientId)
        }
        if let stored, storedClientUsable(stored) {
            return stored
        }
        guard
            let registrationEndpoint = metadata.registrationEndpoint,
            let registrationURL = URL(string: registrationEndpoint)
        else {
            throw MCPOAuthError.clientRegistrationRequired(
                "the authorization server offers no dynamic registration; "
                    + "register a client for redirect URI "
                    + "'\(effectiveRedirectURI)' and set oauth.clientId"
            )
        }
        log("MCP server '\(serverName)': registering an OAuth client dynamically.")
        return try await DynamicClientRegistration.register(
            endpoint: registrationURL,
            redirectURI: effectiveRedirectURI,
            scope: config.scope ?? discoveredScopeHint,
            transport: transport
        )
    }

    private func storedClientUsable(_ client: OAuthClientRegistration) -> Bool {
        guard let expiry = client.clientSecretExpiresAt else { return true }
        return expiry > deps.now().timeIntervalSince1970
    }

    // MARK: - Token response handling

    struct TokenEndpointResponse: Decodable {
        var accessToken: String
        var tokenType: String?
        var expiresIn: Double?
        var refreshToken: String?
        var refreshTokenExpiresIn: Double?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case scope
        }
    }

    struct TokenEndpointFailure: Decodable {
        var error: String?
        var errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    static func decodeTokenResponse(_ body: Data) throws -> TokenEndpointResponse {
        guard let response = try? JSONDecoder().decode(TokenEndpointResponse.self, from: body) else {
            throw MCPOAuthError.flowFailed("the token response was not valid JSON")
        }
        // RFC 6749 §7.1: the client must not use an access token whose
        // token_type it does not understand. This client only speaks Bearer,
        // and a missing token_type is treated as Bearer (universal in
        // practice for the flows here).
        if let type = response.tokenType, type.lowercased() != "bearer" {
            throw MCPOAuthError.flowFailed(
                "the authorization server issued a '\(type)' token, but DoMoCode only supports Bearer"
            )
        }
        return response
    }

    static func decodeTokenFailure(_ body: Data) -> TokenEndpointFailure? {
        try? JSONDecoder().decode(TokenEndpointFailure.self, from: body)
    }

    /// Persists the exchange/refresh result, applying the retention rules a
    /// non-rotating IdP relies on: a response without a `refresh_token` keeps
    /// the previous token, and — since such a response also omits
    /// `refresh_token_expires_in` — keeps the previously learned refresh-token
    /// expiry too, so the login-time expiry is not erased on first refresh.
    private func persistTokens(
        from response: TokenEndpointResponse,
        previous: OAuthTokens?,
        client: OAuthClientRegistration?
    ) async throws -> OAuthTokens {
        let now = deps.now().timeIntervalSince1970
        Redaction.register(response.accessToken)
        Redaction.register(response.refreshToken)
        let refreshToken = response.refreshToken ?? previous?.refreshToken
        // The refresh token is "still the old one" when the response omitted it
        // OR echoed the same string (some non-rotating IdPs do the latter). In
        // both cases carry the known expiry forward; only a genuinely rotated
        // token gets a fresh (here, unknown) lifetime.
        let sameRefreshToken = response.refreshToken == nil || response.refreshToken == previous?.refreshToken
        let refreshExpiry =
            response.refreshTokenExpiresIn.map { now + $0 }
            ?? (sameRefreshToken ? previous?.refreshTokenExpiresAt : nil)
        let tokens = OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: response.expiresIn.map { now + $0 },
            refreshTokenExpiresAt: refreshExpiry,
            scope: response.scope ?? config.scope
        )
        _ = try await deps.store.mutate(forKey: cacheKey, serverURL: serverURL) { current in
            var entry = current ?? OAuthStoredCredential(serverURL: self.serverURL)
            entry.tokens = tokens
            if let client { entry.client = client }
            return entry
        }
        return tokens
    }

    // MARK: - Small helpers

    /// Whether a stored access token can be used without a round-trip. A token
    /// with a known expiry is usable until the margin before it; a token whose
    /// lifetime the server never stated (legal per RFC 6749 §5.1) is treated
    /// as usable, and the 401 refresh-and-replay path is what detects its
    /// actual expiry — the alternative, treating unknown as expired, refreshes
    /// (or fails) on every single request.
    private func isUsable(_ tokens: OAuthTokens) -> Bool {
        guard let expiresAt = tokens.expiresAt else { return true }
        return expiresAt - Self.expiryMargin > deps.now().timeIntervalSince1970
    }

    private func refreshTokenUsable(_ tokens: OAuthTokens) -> Bool {
        guard let expiry = tokens.refreshTokenExpiresAt else { return true }
        return expiry > deps.now().timeIntervalSince1970 + 5
    }

    /// The RFC 8707 resource indicator: configured value, else the server's
    /// canonical URI — lowercased scheme/host, no fragment, default port
    /// dropped, and no trailing slash (a bare root path removed entirely), so
    /// an audience-validating server that canonicalizes matches it.
    private var effectiveResource: String? {
        if let resource = config.resource { return resource }
        guard var components = URLComponents(string: serverURL) else { return serverURL }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url?.absoluteString ?? serverURL
    }

    /// The configured redirect URI, or the loopback default. An empty string
    /// is treated as unset (matching the config validator), so `""` falls back
    /// rather than throwing at `OAuthRedirectEndpoint`.
    private var effectiveRedirectURI: String {
        config.redirectUri.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultRedirectURI
    }

    private func log(_ message: String) {
        deps.log?(Redaction.diagnostic(message))
    }
}
