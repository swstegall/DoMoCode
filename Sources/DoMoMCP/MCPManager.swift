// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Owns every connected MCP server for a run. `connect` spawns each enabled server,
// completes its handshake, and collects its tools as `AgentTool`s — isolating failures
// so one broken server never blocks the others or the run. The manager is held for the
// run's lifetime and `shutdown` tears every server down (closing stdin, killing the
// child). The tools it returns are appended to the built-in tool set at the build sites.

import DoMoAgent
import DoMoCore
import Foundation

/// Connects and owns the run's stdio MCP servers.
public actor MCPManager {
    private var clients: [MCPClient] = []
    private var mcpTools: [any AgentTool] = []

    public init() {}

    /// Connect every enabled server (in a stable order) and return the bridged tools.
    /// A server that fails to spawn or handshake is logged and skipped — never fatal.
    ///
    /// `sensitiveEnvKeys` are removed from each child's inherited environment (the caller
    /// passes the harness's LLM-credential variable names so an untrusted server can't
    /// read them). Tool names are de-collided across servers so two servers can never ship
    /// the same function name. `reservedNames` (the built-in tool names) seeds that set as
    /// FORWARD-LOOKING defense: today a namespaced MCP name is `sanitize(server)_sanitize(tool)`
    /// (always contains `_`) and no built-in name does, so no MCP name can currently collide
    /// with a built-in — but seeding guards a future built-in whose name contains an `_`.
    public func connect(
        servers: [String: MCPServerConfig],
        workspaceDirectory: String,
        clientVersion: String = "0.1.0",
        sensitiveEnvKeys: Set<String> = [],
        reservedNames: Set<String> = [],
        log: (@Sendable (String) -> Void)? = nil
    ) async -> [any AgentTool] {
        // Seed with the built-in names (forward-looking; see the doc-comment) so a
        // namespaced MCP name that ever collided with one would be renamed, not shadow it.
        var usedNames = reservedNames
        for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
            if config.enabled == false { continue }
            // An empty command would trap on `command[0]` at spawn (an uncatchable index
            // fault, not a throw the do/catch below could isolate) — skip it up front.
            guard !config.command.isEmpty else {
                log?("MCP server '\(name)' has an empty command; skipping.")
                continue
            }
            let client = MCPClient(
                serverName: name, config: config,
                workspaceDirectory: workspaceDirectory, clientVersion: clientVersion,
                sensitiveEnvKeys: sensitiveEnvKeys, log: log
            )
            do {
                try await client.connect()
                clients.append(client)
                var count = 0
                for info in await client.tools() {
                    // Validate the (untrusted) schema BEFORE reserving a name: a tool whose
                    // schema can't convert is dropped with a log line rather than advertised
                    // with an empty (misleading) parameter list.
                    let parameters: JSONSchema
                    do {
                        parameters = try McpTool.makeParameters(info.inputSchema)
                    } catch {
                        log?("MCP server '\(name)' tool '\(info.name)' has an unusable input schema; skipping it.")
                        continue
                    }
                    let unique = dedupedName(server: name, tool: info.name, used: &usedNames, log: log)
                    mcpTools.append(McpTool(client: client, serverName: name, info: info, nameOverride: unique, parameters: parameters))
                    count += 1
                }
                log?("MCP server '\(name)' connected with \(count) tool(s).")
            } catch {
                log?("MCP server '\(name)' failed to connect: \(error)")
                await client.shutdown()
            }
        }
        return mcpTools
    }

    /// The namespaced tool name, made unique against names already emitted this run. Two
    /// servers whose tools namespace to the same string would otherwise produce duplicate
    /// function names — which providers reject (a single bad pair breaks the whole run)
    /// and which would route a call to whichever server sorted first. On a collision a
    /// numeric suffix is appended (`name_2`, `name_3`, …) and the rename is logged.
    private func dedupedName(
        server: String, tool: String, used: inout Set<String>, log: (@Sendable (String) -> Void)?
    ) -> String {
        let base = McpTool.namespaced(server: server, tool: tool)
        let unique = MCPManager.uniquify(base, into: &used)
        if unique != base {
            log?("MCP tool name '\(base)' (server '\(server)') collides with another tool; exposing it as '\(unique)'.")
        }
        return unique
    }

    /// Return `base` if unused (recording it), else `base_2`/`base_3`/… — the first
    /// suffix that isn't already taken — recording and returning that.
    static func uniquify(_ base: String, into used: inout Set<String>) -> String {
        guard used.contains(base) else { used.insert(base); return base }
        var n = 2
        while used.contains("\(base)_\(n)") { n += 1 }
        let unique = "\(base)_\(n)"
        used.insert(unique)
        return unique
    }

    /// The bridged tools connected so far.
    public func tools() -> [any AgentTool] { mcpTools }

    /// Tear down every connected server.
    public func shutdown() async {
        for client in clients { await client.shutdown() }
        clients.removeAll()
        mcpTools.removeAll()
    }
}
