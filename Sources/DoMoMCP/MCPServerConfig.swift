// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The settings.json `mcpServers` entry: one stdio-local MCP server. Everything but
// `command` is optional, so a bare `{ "command": ["npx", "-y", "some-server"] }`
// decodes cleanly. Remote/OAuth transports are intentionally not modeled.

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

    public init(
        command: [String],
        environment: [String: String]? = nil,
        cwd: String? = nil,
        enabled: Bool? = nil,
        timeout: Int? = nil
    ) {
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.enabled = enabled
        self.timeout = timeout
    }

    /// The per-request timeout as a `Duration` (default 30s).
    public var requestTimeout: Duration {
        .milliseconds(timeout ?? 30_000)
    }
}
