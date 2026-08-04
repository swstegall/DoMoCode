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
import DoMoExec
import Foundation

/// Connects and owns the run's stdio MCP servers.
public actor MCPManager {
    private struct ServerKey: Hashable {
        let server: String
        let tool: String
    }

    private struct ConnectedServer {
        let name: String
        let client: MCPClient
    }

    private var servers: [ConnectedServer] = []
    private var mcpTools: [any AgentTool] = []
    private var reservedNames: Set<String> = []
    private var nameOverrides: [ServerKey: String] = [:]
    private var log: (@Sendable (String) -> Void)?

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
        sandbox: ProcessSandbox? = nil,
        reservedNames: Set<String> = [],
        log: (@Sendable (String) -> Void)? = nil,
        credentialProvider: (@Sendable (String) -> String?)? = nil
    ) async -> [any AgentTool] {
        self.reservedNames = reservedNames
        self.log = log
        // Seed with the built-in names (forward-looking; see the doc-comment) so a
        // namespaced MCP name that ever collided with one would be renamed, not shadow it.
        for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
            if config.enabled == false { continue }
            // An empty local command would trap on `command[0]` at spawn (an
            // uncatchable index fault, not a throw the do/catch below could
            // isolate). Remote entries have no command.
            guard config.isRemote || !config.command.isEmpty else {
                log?("MCP server '\(name)' has an empty command; skipping.")
                continue
            }
            let bearerToken = config.credentialReference.flatMap { credentialProvider?($0) }
                ?? config.bearerTokenEnvironment.flatMap { ProcessInfo.processInfo.environment[$0] }
            let client = MCPClient(
                serverName: name, config: config,
                workspaceDirectory: workspaceDirectory, clientVersion: clientVersion,
                sensitiveEnvKeys: sensitiveEnvKeys, sandbox: sandbox, log: log,
                onToolsChanged: { [weak self] in
                    await self?.rebuildTools()
                },
                bearerToken: bearerToken
            )
            var connectionError: (any Error)?
            let attempts = config.isRemote ? 3 : 1
            for attempt in 0..<attempts {
                do {
                    try await client.connect()
                    connectionError = nil
                    break
                } catch {
                    connectionError = error
                    guard attempt + 1 < attempts else { break }
                    let delay = Duration.milliseconds(Int64(100 * (1 << attempt)))
                    try? await Task.sleep(for: delay)
                }
            }
            if connectionError == nil {
                self.servers.append(ConnectedServer(name: name, client: client))
                await rebuildTools()
                let count = mcpTools.filter { $0.definition.name.hasPrefix(McpTool.sanitize(name) + "_") }.count
                log?("MCP server '\(name)' connected with \(count) tool(s).")
            } else if let connectionError {
                // Redacted: a spawn failure quotes the command, and a configured
                // `environment` block is exactly where a user keeps that server's
                // token. This line goes to stderr, where it would outlive the run.
                log?(Redaction.diagnostic("MCP server '\(name)' failed to connect: \(connectionError)"))
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

    /// Rebuild the bridge after one of the connected clients receives
    /// `notifications/tools/list_changed`. The current server/tool order is
    /// deterministic, and an existing `(server, raw tool)` keeps its exposed
    /// name across description/schema refreshes and remove/re-add cycles.
    private func rebuildTools() async {
        var usedNames = reservedNames
        var rebuilt: [any AgentTool] = []
        for server in servers {
            for info in await server.client.tools() {
                let parameters: JSONSchema
                do {
                    parameters = try McpTool.makeParameters(info.inputSchema)
                } catch {
                    log?("MCP server '\(server.name)' tool '\(info.name)' has an unusable input schema; skipping it.")
                    continue
                }

                let key = ServerKey(server: server.name, tool: info.name)
                let exposedName: String
                if let previous = nameOverrides[key], !usedNames.contains(previous) {
                    exposedName = previous
                    usedNames.insert(previous)
                } else {
                    exposedName = dedupedName(
                        server: server.name,
                        tool: info.name,
                        used: &usedNames,
                        log: log
                    )
                    nameOverrides[key] = exposedName
                }
                rebuilt.append(
                    McpTool(
                        client: server.client,
                        serverName: server.name,
                        info: info,
                        nameOverride: exposedName,
                        parameters: parameters
                    )
                )
            }
        }
        mcpTools = rebuilt
    }

    /// Tear down every connected server.
    public func shutdown() async {
        for server in servers { await server.client.shutdown() }
        servers.removeAll()
        mcpTools.removeAll()
    }
}
