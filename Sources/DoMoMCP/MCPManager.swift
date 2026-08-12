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
import DoMoLLM
import Foundation

/// The connection state exposed by the MCP admin route.
public enum MCPServerStatus: String, Sendable, Hashable, Codable {
    case connected
    case disabled
    case failed
    case needsAuth = "needs_auth"
    case needsClientRegistration = "needs_client_registration"
}

/// A safe, non-secret summary of one configured MCP server.
public struct MCPServerStatusInfo: Sendable, Hashable, Codable {
    public let status: MCPServerStatus
    public let transport: MCPTransport
    public let toolCount: Int
    public let error: String?
    public let endpoint: String?

    public init(
        status: MCPServerStatus,
        transport: MCPTransport,
        toolCount: Int = 0,
        error: String? = nil,
        endpoint: String? = nil
    ) {
        self.status = status
        self.transport = transport
        self.toolCount = toolCount
        self.error = error
        self.endpoint = endpoint
    }
}

/// A prompt advertised by a connected MCP server and projected into the
/// server's ordinary slash-command catalog.
public struct MCPPromptDescriptor: Sendable, Hashable {
    public let server: String
    public let name: String
    public let description: String?
    public let arguments: [MCPClient.PromptArgumentInfo]
    public let commandName: String

    public init(
        server: String,
        name: String,
        description: String?,
        arguments: [MCPClient.PromptArgumentInfo]
    ) {
        self.server = server
        self.name = name
        self.description = description
        self.arguments = arguments
        self.commandName = "mcp_" + McpTool.sanitize(server) + "_" + McpTool.sanitize(name)
    }
}

/// Connects and owns the run's stdio MCP servers.
public actor MCPManager {
    public struct MCPResourceInfo: Sendable, Hashable, Codable {
        public let server: String
        public let uri: String
        public let name: String
        public let description: String?
        public let mimeType: String?

        public init(
            server: String,
            uri: String,
            name: String,
            description: String?,
            mimeType: String?
        ) {
            self.server = server
            self.uri = uri
            self.name = name
            self.description = description
            self.mimeType = mimeType
        }
    }

    public struct MCPResourceTemplateInfo: Sendable, Hashable, Codable {
        public let server: String
        public let uriTemplate: String
        public let name: String
        public let description: String?
        public let mimeType: String?

        public init(
            server: String,
            uriTemplate: String,
            name: String,
            description: String?,
            mimeType: String?
        ) {
            self.server = server
            self.uriTemplate = uriTemplate
            self.name = name
            self.description = description
            self.mimeType = mimeType
        }
    }

    public struct MCPResourceRead: Sendable, Hashable, Codable {
        public let server: String
        public let uri: String
        public let contents: [JSONValue]

        public init(server: String, uri: String, contents: [JSONValue]) {
            self.server = server
            self.uri = uri
            self.contents = contents
        }
    }

    public struct MCPServerHealth: Sendable, Hashable, Codable {
        public let server: String
        public let healthy: Bool

        public init(server: String, healthy: Bool) {
            self.server = server
            self.healthy = healthy
        }
    }

    public enum MCPManagerError: Error, Sendable, Equatable {
        case serverNotConnected(String)
    }

    private struct ServerKey: Hashable {
        let server: String
        let tool: String
    }

    private struct ConnectedServer: Sendable {
        let name: String
        let client: MCPClient
        let adapterKind: MCPAdapterKind?
        let transport: MCPTransport
        let endpoint: String?
    }

    private var servers: [ConnectedServer] = []
    private var mcpTools: [any AgentTool] = []
    private var reservedNames: Set<String> = []
    private var nameOverrides: [ServerKey: String] = [:]
    private var serverStatuses: [String: MCPServerStatusInfo] = [:]
    private var changeHandler: (@Sendable (String) async -> Void)?
    private var log: (@Sendable (String) -> Void)?

    /// The one HTTP-client factory every remote server this manager connects shares, so
    /// the whole run builds at most one proxied client instead of one per server. It is
    /// created here rather than per `connect` call because ``shutdown()`` is the single
    /// place that may tear it down, and a client still referenced by a connected server
    /// must outlive that server.
    private let httpClients: ProxiedHTTPClients

    /// - Parameter proxy: the resolved proxy settings for the run. The default owns
    ///   nothing and hands every request `HTTPClient.shared`, which is the behaviour of
    ///   every call site that does not pass one.
    public init(proxy: ProxySettings = .disabled) {
        httpClients = ProxiedHTTPClients(settings: proxy)
    }

    /// Install the server-wide notification sink used by the HTTP runtime to
    /// broadcast `mcp_changed` on every live session stream.
    public func setChangeHandler(_ handler: (@Sendable (String) async -> Void)?) {
        changeHandler = handler
    }

    /// What the embedding surface provides for `oauth`-configured servers.
    /// Absent, those servers are skipped with a log line — OAuth is opt-in for
    /// the surface exactly as it is for the config.
    public struct OAuthSetup: Sendable {
        /// The per-user config directory; tokens and the loopback certificate
        /// live in `<configDirectory>/mcp-oauth`, 0600.
        public var configDirectory: String
        /// Whether a browser flow may run *now*. True only at startup on an
        /// interactive surface; mid-session token needs are refresh-only.
        public var allowInteractive: Bool
        /// Test seam; the system browser by default.
        public var browser: (any BrowserLaunching)?
        /// How long the browser flow may take end to end.
        public var authorizationTimeout: Duration

        public init(
            configDirectory: String,
            allowInteractive: Bool = true,
            browser: (any BrowserLaunching)? = nil,
            authorizationTimeout: Duration = .seconds(300)
        ) {
            self.configDirectory = configDirectory
            self.allowInteractive = allowInteractive
            self.browser = browser
            self.authorizationTimeout = authorizationTimeout
        }
    }

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
        credentialProvider: (@Sendable (String) -> String?)? = nil,
        oauth: OAuthSetup? = nil
    ) async -> [any AgentTool] {
        self.reservedNames = reservedNames
        self.log = log
        serverStatuses.removeAll(keepingCapacity: true)
        for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
            serverStatuses[name] = MCPServerStatusInfo(
                status: config.enabled == false ? .disabled : .failed,
                transport: config.effectiveTransport,
                endpoint: Self.safeEndpoint(config.url)
            )
        }
        // One store for every oauth server this call connects; entries are
        // namespaced by cache key so servers never read each other's tokens.
        let oauthStore = oauth.map { OAuthTokenStore(directory: $0.configDirectory + "/mcp-oauth") }
        // Seed with the built-in names (forward-looking; see the doc-comment) so a
        // namespaced MCP name that ever collided with one would be renamed, not shadow it.
        for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
            if config.enabled == false { continue }
            // An empty local command would trap on `command[0]` at spawn (an
            // uncatchable index fault, not a throw the do/catch below could
            // isolate). Remote entries have no command.
            guard config.isRemote || !config.command.isEmpty else {
                updateStatus(
                    name,
                    status: .failed,
                    error: "MCP server configuration has an empty command."
                )
                log?("MCP server '\(name)' has an empty command; skipping.")
                continue
            }
            let bearerToken = config.credentialReference.flatMap { credentialProvider?($0) }
                ?? config.bearerTokenEnvironment.flatMap { ProcessInfo.processInfo.environment[$0] }

            // OAuth outranks the static paths when both are configured: the
            // block is the more explicit statement of intent, and a stale env
            // token silently shadowing a working login is the worse surprise.
            var tokenProvider: MCPClient.BearerTokenProvider?
            if let oauthConfig = config.oauth, config.isRemote {
                guard let setup = oauth, let oauthStore else {
                    updateStatus(
                        name,
                        status: .needsAuth,
                        error: "Interactive OAuth support is unavailable on this surface."
                    )
                    log?(
                        "MCP server '\(name)' has oauth configured, but this surface "
                            + "provides no OAuth support; skipping."
                    )
                    continue
                }
                guard let serverURL = config.url else {
                    // isRemote can be true via an explicit transport with no
                    // url; that is a config error, not a surface limitation.
                    updateStatus(
                        name,
                        status: .failed,
                        error: "OAuth configuration is missing a server URL."
                    )
                    log?("MCP server '\(name)' has oauth configured but no url; skipping.")
                    continue
                }
                let provider = MCPOAuthProvider(
                    serverName: name,
                    serverURL: serverURL,
                    config: oauthConfig,
                    dependencies: MCPOAuthDependencies(
                        store: oauthStore,
                        browser: setup.browser ?? SystemBrowserLauncher(),
                        clientProvider: { [httpClients] url in httpClients.client(for: url) },
                        log: log,
                        certificateDirectory: setup.configDirectory + "/mcp-oauth",
                        authorizationTimeout: setup.authorizationTimeout
                    )
                )
                // Acquire once, interactively if the surface allows, BEFORE
                // the connect-retry loop below — that loop must never be the
                // thing that opens a browser three times.
                do {
                    _ = try await provider.accessToken(allowInteractive: setup.allowInteractive)
                } catch {
                    let outcome = Self.oauthStatus(for: error)
                    updateStatus(name, status: outcome.status, error: outcome.error)
                    log?(Redaction.diagnostic("MCP server '\(name)' OAuth login failed: \(error)"))
                    continue
                }
                // Mid-session consults refresh silently and never interact;
                // an expired session surfaces as a typed error telling the
                // user to restart, not as a surprise browser window.
                tokenProvider = { forceRefresh, rejectedToken, wwwAuthenticate in
                    try await provider.accessToken(
                        forceRefresh: forceRefresh,
                        allowInteractive: false,
                        wwwAuthenticate: wwwAuthenticate,
                        rejectedToken: rejectedToken
                    )
                }
            }

            let client = MCPClient(
                serverName: name, config: config,
                workspaceDirectory: workspaceDirectory, clientVersion: clientVersion,
                sensitiveEnvKeys: sensitiveEnvKeys, sandbox: sandbox, log: log,
                onToolsChanged: { [weak self] in
                    await self?.rebuildTools(changedServer: name)
                },
                bearerToken: tokenProvider == nil ? bearerToken : nil,
                tokenProvider: tokenProvider,
                httpClientProvider: { [httpClients] url in httpClients.client(for: url) }
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
                    // A credential rejection is deterministic across an
                    // immediate retry — the same token would 401 again — and
                    // each attempt costs a real refresh grant (a rotation on a
                    // rotating IdP). An OAuth failure surfaced through the token
                    // provider (interaction required, a dead-grant re-login that
                    // cannot run, a 4xx from the token endpoint) is equally
                    // deterministic. Only the transient failures the loop exists
                    // for are worth retrying.
                    if error is MCPOAuthError { break }
                    if case MCPClient.MCPError.unauthorized = error { break }
                    guard attempt + 1 < attempts else { break }
                    let delay = Duration.milliseconds(Int64(100 * (1 << attempt)))
                    try? await Task.sleep(for: delay)
                }
            }
            if connectionError == nil {
                self.servers.append(
                    ConnectedServer(
                        name: name,
                        client: client,
                        adapterKind: config.adapterKind,
                        transport: config.effectiveTransport,
                        endpoint: Self.safeEndpoint(config.url)
                    )
                )
                await rebuildTools()
                let count = mcpTools.filter { $0.definition.name.hasPrefix(McpTool.sanitize(name) + "_") }.count
                updateStatus(name, status: .connected, toolCount: count, clearError: true)
                log?("MCP server '\(name)' connected with \(count) tool(s).")
            } else if let connectionError {
                // Redacted: a spawn failure quotes the command, and a configured
                // `environment` block is exactly where a user keeps that server's
                // token. This line goes to stderr, where it would outlive the run.
                log?(Redaction.diagnostic("MCP server '\(name)' failed to connect: \(connectionError)"))
                let outcome = Self.connectionStatus(for: connectionError)
                updateStatus(name, status: outcome.status, error: outcome.error)
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

    /// The configured MCP servers, including disabled and failed entries. The
    /// values deliberately omit credentials and full endpoint paths.
    public func statuses() -> [String: MCPServerStatusInfo] { serverStatuses }

    /// Return the connected MCP prompts as slash-command metadata.
    public func promptCommands() async -> [MCPPromptDescriptor] {
        var result: [MCPPromptDescriptor] = []
        for server in servers {
            result.append(contentsOf: await server.client.prompts().map { prompt in
                MCPPromptDescriptor(
                    server: server.name,
                    name: prompt.name,
                    description: prompt.description,
                    arguments: prompt.arguments
                )
            })
        }
        return result.sorted { $0.commandName < $1.commandName }
    }

    public func promptDescriptor(named commandName: String) async -> MCPPromptDescriptor? {
        await promptCommands().first {
            $0.commandName.caseInsensitiveCompare(commandName) == .orderedSame
        }
    }

    /// Fetch and render a prompt through its owning connected MCP client.
    public func getPrompt(
        server requestedServer: String,
        name: String,
        arguments: [String: String]
    ) async throws -> String {
        guard let server = servers.first(where: { $0.name == requestedServer }) else {
            throw MCPManagerError.serverNotConnected(requestedServer)
        }
        let result = try await server.client.getPrompt(name: name, arguments: arguments)
        let rendered = MCPClient.renderPrompt(result)
        return rendered.isEmpty ? (result.description ?? "") : rendered
    }

    /// The bridged tools belonging to one exact server. The server name is
    /// required so an adapter cannot accidentally route a call to a different
    /// MCP peer after a catalog refresh.
    public func tools(server requestedServer: String) -> [any AgentTool] {
        let prefix = McpTool.sanitize(requestedServer) + "_"
        return mcpTools.filter { $0.definition.name.hasPrefix(prefix) }
    }

    public func isConnected(server requestedServer: String) -> Bool {
        servers.contains { $0.name == requestedServer }
    }

    /// Return the explicitly declared browser/notebook/remote-search roles.
    /// Ordinary MCP servers are intentionally absent; their tools remain
    /// available through the normal MCP catalog.
    public func externalCapabilityDescriptors() -> [ExternalCapabilityDescriptor] {
        servers.compactMap { server in
            guard let kind = server.adapterKind else { return nil }
            let toolNames = tools(server: server.name).map { $0.definition.name }
            return ExternalCapabilityDescriptor(
                id: "mcp:\(server.name):\(kind.rawValue)",
                displayName: "\(kind.rawValue) via \(server.name)",
                kind: kind.externalCapabilityKind,
                transport: .mcp,
                endpoint: server.endpoint,
                toolNames: toolNames
            )
        }
    }

    /// Build adapter views over the same connected MCP clients. The views do
    /// not own the manager or shut down its servers; the run owner remains the
    /// single lifecycle authority.
    public func externalCapabilityAdapters() -> [MCPExternalCapabilityAdapter] {
        servers.compactMap { server in
            guard let kind = server.adapterKind,
                  let descriptor = externalCapabilityDescriptors().first(where: {
                      $0.id == "mcp:\(server.name):\(kind.rawValue)"
                  })
            else { return nil }
            return MCPExternalCapabilityAdapter(manager: self, descriptor: descriptor, server: server.name)
        }
    }

    /// Inspect resources from the connected servers. A broken or capability-less
    /// server contributes no entries and does not make another server disappear.
    public func resources(server requestedServer: String? = nil) async -> [MCPResourceInfo] {
        var result: [MCPResourceInfo] = []
        for server in selectedServers(requestedServer) {
            do {
                result.append(contentsOf: try await server.client.listResources().map { info in
                    MCPResourceInfo(
                        server: server.name,
                        uri: info.uri,
                        name: info.name,
                        description: info.description,
                        mimeType: info.mimeType
                    )
                })
            } catch {
                log?(Redaction.diagnostic("MCP resource listing failed for '\(server.name)': \(error)"))
            }
        }
        return result
    }

    /// Inspect URI templates from the connected servers using the same manager
    /// snapshot as tool discovery.
    public func resourceTemplates(server requestedServer: String? = nil) async -> [MCPResourceTemplateInfo] {
        var result: [MCPResourceTemplateInfo] = []
        for server in selectedServers(requestedServer) {
            do {
                result.append(contentsOf: try await server.client.listResourceTemplates().map { info in
                    MCPResourceTemplateInfo(
                        server: server.name,
                        uriTemplate: info.uriTemplate,
                        name: info.name,
                        description: info.description,
                        mimeType: info.mimeType
                    )
                })
            } catch {
                log?(Redaction.diagnostic("MCP resource-template listing failed for '\(server.name)': \(error)"))
            }
        }
        return result
    }

    /// Read one exact URI from one exact connected server. The server name is
    /// required so a resource cannot be redirected to a different adapter after
    /// the model has inspected its catalogue.
    public func readResource(server requestedServer: String, uri: String) async throws -> MCPResourceRead {
        guard let server = servers.first(where: { $0.name == requestedServer }) else {
            throw MCPManagerError.serverNotConnected(requestedServer)
        }
        let contents = try await server.client.readResource(uri: uri)
        return MCPResourceRead(server: requestedServer, uri: uri, contents: contents)
    }

    /// Ping one server or all connected servers for diagnostics.
    public func health(server requestedServer: String? = nil) async -> [MCPServerHealth] {
        await withTaskGroup(of: MCPServerHealth.self, returning: [MCPServerHealth].self) { group in
            for server in selectedServers(requestedServer) {
                group.addTask {
                    MCPServerHealth(server: server.name, healthy: await server.client.health())
                }
            }
            var result: [MCPServerHealth] = []
            for await health in group { result.append(health) }
            return result.sorted { $0.server < $1.server }
        }
    }

    private func selectedServers(_ requestedServer: String?) -> [ConnectedServer] {
        guard let requestedServer else { return servers }
        return servers.filter { $0.name == requestedServer }
    }

    /// Rebuild the bridge after one of the connected clients receives
    /// `notifications/tools/list_changed`. The current server/tool order is
    /// deterministic, and an existing `(server, raw tool)` keeps its exposed
    /// name across description/schema refreshes and remove/re-add cycles.
    private func rebuildTools(changedServer: String? = nil) async {
        var usedNames = reservedNames
        var rebuilt: [any AgentTool] = []
        var toolCounts: [String: Int] = [:]
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
                        parameters: parameters,
                        adapterKind: server.adapterKind,
                        transport: server.transport
                    )
                )
                toolCounts[server.name, default: 0] += 1
            }
        }
        mcpTools = rebuilt
        for server in servers {
            updateStatus(server.name, toolCount: toolCounts[server.name] ?? 0)
        }
        if let changedServer, let changeHandler {
            await changeHandler(changedServer)
        }
    }

    /// Tear down every connected server, then the HTTP clients they shared. Ends this
    /// manager's life: a client built for a proxied endpoint holds an event-loop group,
    /// and leaving one running keeps the process from exiting.
    public func shutdown() async {
        for server in servers { await server.client.shutdown() }
        servers.removeAll()
        mcpTools.removeAll()
        serverStatuses.removeAll()
        // After the servers, never before: a shut-down client cannot serve the requests
        // a still-connected server would make. Idempotent, because the CLI's error and
        // success paths can both reach here.
        await httpClients.shutdown()
    }

    private static func safeEndpoint(_ rawURL: String?) -> String? {
        guard let rawURL, let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host
        else { return nil }
        var endpoint = "\(scheme)://\(host)"
        if let port = url.port { endpoint += ":\(port)" }
        return endpoint
    }

    private func updateStatus(
        _ name: String,
        status: MCPServerStatus? = nil,
        toolCount: Int? = nil,
        error: String? = nil,
        clearError: Bool = false
    ) {
        guard let current = serverStatuses[name] else { return }
        serverStatuses[name] = MCPServerStatusInfo(
            status: status ?? current.status,
            transport: current.transport,
            toolCount: toolCount ?? current.toolCount,
            error: clearError ? error : error ?? current.error,
            endpoint: current.endpoint
        )
    }

    private static func connectionStatus(for error: any Error) -> (status: MCPServerStatus, error: String) {
        if let oauthError = error as? MCPOAuthError {
            return oauthStatus(for: oauthError)
        }
        if case MCPClient.MCPError.unauthorized = error {
            return (.needsAuth, "MCP server rejected its credential.")
        }
        return (.failed, "MCP server failed to connect.")
    }

    private static func oauthStatus(for error: any Error) -> (status: MCPServerStatus, error: String) {
        guard let oauthError = error as? MCPOAuthError else {
            return (.needsAuth, "MCP authorization is required.")
        }
        switch oauthError {
        case .clientRegistrationRequired:
            return (.needsClientRegistration, "OAuth client registration is required.")
        case .interactionRequired, .authorizationDenied, .timedOut, .tokenEndpoint:
            return (.needsAuth, "MCP authorization is required.")
        case .configuration, .discoveryFailed, .portInUse, .flowFailed:
            return (.failed, "MCP OAuth configuration or connection failed.")
        }
    }
}

private extension MCPAdapterKind {
    var externalCapabilityKind: ExternalCapabilityKind {
        switch self {
        case .browser: return .browser
        case .notebook: return .notebook
        case .remoteSearch: return .remoteSearch
        }
    }
}
