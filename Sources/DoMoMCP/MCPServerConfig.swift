// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The settings.json `mcpServers` entry. Stdio remains the default; remote
// streamable HTTP/SSE entries are opt-in and carry only credential references,
// never bearer values.

/// MCP transport selected by a server entry.
public enum MCPTransport: String, Sendable, Hashable, Codable {
    case stdio
    /// MCP streamable HTTP. Responses may be JSON or an SSE response body.
    case streamableHTTP = "streamable-http"
    /// A compatibility spelling for servers that return MCP messages as SSE.
    /// The endpoint is still POSTed using the streamable HTTP message shape.
    case sse
}

/// Declares the external capability a configured MCP server supplies. The
/// server remains an ordinary MCP server; this label only gives catalogs and
/// workflow surfaces an explicit adapter role without guessing from tool names.
public enum MCPAdapterKind: String, Sendable, Hashable, Codable, CaseIterable {
    case browser
    case notebook
    case remoteSearch
}

/// Browser OAuth (authorization code + PKCE) for a remote MCP server.
///
/// Every field is optional, and what is absent is discovered rather than
/// defaulted blindly: an empty `{}` block means the full MCP authorization
/// handshake (401 → protected-resource metadata → authorization-server
/// metadata → dynamic client registration), while an enterprise IdP that
/// supports none of that — ADFS is the motivating case — spells out
/// `authorizationEndpoint`, `tokenEndpoint`, and `clientId` explicitly.
///
/// Nothing here is a secret: the client is a public OAuth client (PKCE, no
/// client secret), so the whole block is safe to persist in settings. Tokens
/// obtained through this config never touch settings.json — they live in the
/// 0600 token store under the config directory.
public struct MCPOAuthConfig: Sendable, Hashable, Codable {
    /// The OAuth authorization endpoint. Absent means discover it from the
    /// server's protected-resource / authorization-server metadata.
    public var authorizationEndpoint: String?

    /// The OAuth token endpoint. Absent means discover it alongside
    /// `authorizationEndpoint`.
    public var tokenEndpoint: String?

    /// A pre-registered public client id. Absent means register one
    /// dynamically (RFC 7591) where the authorization server allows it.
    public var clientId: String?

    /// Space-separated scope string, e.g. `"openid profile"`. Absent means
    /// whatever the server's metadata advertises (or no scope parameter).
    public var scope: String?

    /// The RFC 8707 resource indicator sent on authorize, token, and refresh
    /// requests. Defaults to the server's canonical URL. ADFS overloads the
    /// same parameter name for its relying-party identifier and silently
    /// issues a token for `urn:microsoft:userinfo` when it is omitted, so for
    /// ADFS-class servers this must match the registered identifier exactly.
    public var resource: String?

    /// The redirect URI the browser lands on, exactly as registered with the
    /// authorization server. Defaults to a plain-HTTP loopback listener
    /// (`http://127.0.0.1:27182/oauth/callback`). An `https://localhost` value
    /// makes the listener serve TLS with a generated self-signed certificate —
    /// required by registrations that refuse plain-HTTP loopback.
    public var redirectUri: String?

    /// Token-store namespace. Defaults to the server's configured name. Two
    /// entries sharing a key share stored credentials only while they also
    /// name the same `url` — a stored credential is bound to the server URL it
    /// was minted for and never handed to a different one.
    public var cacheKey: String?

    public init(
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        clientId: String? = nil,
        scope: String? = nil,
        resource: String? = nil,
        redirectUri: String? = nil,
        cacheKey: String? = nil
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientId = clientId
        self.scope = scope
        self.resource = resource
        self.redirectUri = redirectUri
        self.cacheKey = cacheKey
    }
}

/// One configured stdio-local MCP server.
public struct MCPServerConfig: Sendable, Hashable, Codable {
    /// argv — `command[0]` is the program (resolved via PATH if bare), the rest args.
    public var command: [String]
    /// Extra environment variables overlaid on the inherited environment.
    public var environment: [String: String]?
    /// Working directory for the server, relative to the workspace (or absolute).
    public var cwd: String?
    /// `false` disables the server (it is not spawned). Absent/`true` enables it.
    public var enabled: Bool?
    /// Per-request timeout in milliseconds (default 30000).
    public var timeout: Int?

    /// Remote MCP endpoint. Required for `streamableHTTP` and `sse`; absent for
    /// ordinary stdio servers.
    public var url: String?

    /// Explicit transport. An entry with a URL and no transport defaults to
    /// streamable HTTP so older settings can opt into remote MCP incrementally.
    public var transport: MCPTransport?

    /// A name understood by the embedding credential provider. This is an
    /// identifier, not the credential itself, and is safe to persist in settings.
    public var credentialReference: String?

    /// The environment-variable name from which the process may read a bearer
    /// token at launch. The variable name is persisted; its value is not.
    public var bearerTokenEnvironment: String?

    /// Exact host allow-list for remote endpoints. `nil`/empty means the host is
    /// not restricted beyond the private-network rule below.
    public var allowedHosts: [String]?

    /// Private/link-local hosts are denied by default. Tests and deliberately
    /// local deployments must opt in explicitly.
    public var allowPrivateNetwork: Bool?

    /// Optional role exposed by this MCP server. A missing role keeps the
    /// server on the ordinary MCP tool path.
    public var adapterKind: MCPAdapterKind?

    /// Browser OAuth for this server. Presence of the block — even an empty
    /// `{}` — opts the server into the interactive login flow; absence keeps
    /// today's static credential paths. Deliberately opt-in: an agent harness
    /// should never open a browser because a server happened to answer 401.
    public var oauth: MCPOAuthConfig?

    public init(
        command: [String],
        environment: [String: String]? = nil,
        cwd: String? = nil,
        enabled: Bool? = nil,
        timeout: Int? = nil,
        url: String? = nil,
        transport: MCPTransport? = nil,
        credentialReference: String? = nil,
        bearerTokenEnvironment: String? = nil,
        allowedHosts: [String]? = nil,
        allowPrivateNetwork: Bool? = nil,
        adapterKind: MCPAdapterKind? = nil,
        oauth: MCPOAuthConfig? = nil
    ) {
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.enabled = enabled
        self.timeout = timeout
        self.url = url
        self.transport = transport
        self.credentialReference = credentialReference
        self.bearerTokenEnvironment = bearerTokenEnvironment
        self.allowedHosts = allowedHosts
        self.allowPrivateNetwork = allowPrivateNetwork
        self.adapterKind = adapterKind
        self.oauth = oauth
    }

    /// The effective transport, keeping a URL-only entry ergonomic while making
    /// the local default unambiguous.
    public var effectiveTransport: MCPTransport {
        transport ?? (url == nil ? .stdio : .streamableHTTP)
    }

    public var isRemote: Bool { effectiveTransport != .stdio }

    /// The per-request timeout as a `Duration` (default 30s).
    public var requestTimeout: Duration {
        .milliseconds(timeout ?? 30_000)
    }
}
