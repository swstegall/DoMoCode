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
        allowPrivateNetwork: Bool? = nil
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
