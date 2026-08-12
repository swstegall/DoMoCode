// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The JSON-RPC 2.0 protocol layer over a persistent stdio subprocess: correlates
// responses to requests by id, answers server-originated `ping` (and `-32601`s any
// other server request, since this client declares no capabilities), runs the
// `initialize` handshake, discovers tools (paginated `tools/list`), and invokes them
// (`tools/call`) with a per-request timeout that emits `notifications/cancelled`. A
// faithful hand-rolled port of the MCP 2025-06-18 spec — no SDK.

import AsyncHTTPClient
import DoMoCore
import DoMoExec
import Foundation

/// The MCP protocol version this client speaks.
let mcpProtocolVersion = "2025-06-18"
/// Protocol revisions this client is known to interoperate with. A server that echoes
/// a version outside this set gets a warning (not a disconnect — tools/list and
/// tools/call are stable across these revisions, so proceeding is more compatible).
let knownProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
/// Cap on `tools/list` pages, a guard against a looping/malicious server.
private let maxToolListPages = 1000

/// A connected stdio MCP server: initialize, list, and call tools.
public actor MCPClient {
    /// A tool as discovered from `tools/list`.
    public struct ToolInfo: Sendable, Hashable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    /// A resource advertised by an MCP server. Kept as a small inspection value;
    /// the raw contents remain behind ``readResource(uri:)``.
    public struct ResourceInfo: Sendable, Hashable {
        public let uri: String
        public let name: String
        public let description: String?
        public let mimeType: String?
    }

    /// A URI template advertised by an MCP server.
    public struct ResourceTemplateInfo: Sendable, Hashable {
        public let uriTemplate: String
        public let name: String
        public let description: String?
        public let mimeType: String?
    }

    /// One argument accepted by an MCP prompt.
    public struct PromptArgumentInfo: Sendable, Hashable {
        public let name: String
        public let description: String?
        public let required: Bool

        public init(name: String, description: String?, required: Bool) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    /// Prompt metadata returned by `prompts/list`.
    public struct PromptInfo: Sendable, Hashable {
        public let name: String
        public let description: String?
        public let arguments: [PromptArgumentInfo]

        public init(name: String, description: String?, arguments: [PromptArgumentInfo]) {
            self.name = name
            self.description = description
            self.arguments = arguments
        }
    }

    /// The protocol-level result returned by `prompts/get`.
    public struct PromptResult: Sendable {
        public let description: String?
        public let messages: [JSONValue]

        public init(description: String?, messages: [JSONValue]) {
            self.description = description
            self.messages = messages
        }
    }

    /// A `tools/call` result, still in protocol terms (mapped to a tool result by ``McpTool``).
    public struct CallResult: Sendable {
        public let content: [JSONValue]
        public let isError: Bool
        public let structuredContent: JSONValue?
    }

    public enum MCPError: Error, Sendable {
        case protocolError(String)
        case timedOut
        case connectionClosed
        case badResponse
        case networkPolicy(String)
        /// The server rejected the credential and one refresh-and-replay did
        /// not cure it (or the response was 403, which a refresh cannot cure).
        case unauthorized(String)
    }

    /// Answers "a bearer token, please" per request. `forceRefresh` is the
    /// 401 path — the previous answer was just rejected; `rejectedToken` is
    /// the exact token the failing request carried, so the provider refreshes
    /// past it rather than past a store snapshot a sibling may already have
    /// advanced; `wwwAuthenticate` carries the server's challenge when one
    /// arrived, feeding OAuth discovery. Async and throwing because the answer
    /// may involve a token endpoint; the provider decides how much work.
    public typealias BearerTokenProvider = @Sendable (
        _ forceRefresh: Bool,
        _ rejectedToken: String?,
        _ wwwAuthenticate: String?
    ) async throws -> String?

    public let serverName: String
    private let config: MCPServerConfig
    private let workspaceDirectory: String
    private let clientVersion: String
    private let sensitiveEnvKeys: Set<String>
    private let sandbox: ProcessSandbox?
    private let log: (@Sendable (String) -> Void)?
    private let onToolsChanged: (@Sendable () async -> Void)?
    private let bearerToken: String?
    /// When set, consulted per request and preferred over `bearerToken`; the
    /// OAuth path. The static token stays for env/reference credentials.
    private let tokenProvider: BearerTokenProvider?

    private let process = PersistentProcess()
    private let http: HTTPClient
    /// Picks the `HTTPClient` for one request URL. AsyncHTTPClient carries proxy
    /// configuration on the CLIENT, not on the request, so an endpoint reached through
    /// a corporate HTTP proxy and an endpoint the standard `no_proxy` convention exempts
    /// (an intranet host, or the loopback address this program talks to itself on)
    /// cannot share one client. When this is nil every request uses `http`, which is the
    /// unproxied behaviour every existing call site already had.
    private let httpClientProvider: (@Sendable (URL) -> HTTPClient)?
    private var readerTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// The per-request timeout Task, keyed by request id, so it can be cancelled the
    /// moment the request resolves — otherwise it sleeps the full timeout holding the
    /// actor (and the child-process handle) alive, and a burst of fast calls piles up
    /// that many sleeping tasks.
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var toolsCache: [ToolInfo] = []
    private var promptsCache: [PromptInfo] = []
    private var closed = false
    /// Set once the initialize handshake + initial tools/list have completed, so a
    /// `tools/list_changed` arriving mid-handshake doesn't race a second discovery into
    /// the cache concurrently with the first.
    private var handshakeComplete = false
    private var remoteSessionID: String?
    private var capabilities: JSONValue = .object([:])

    public init(
        serverName: String,
        config: MCPServerConfig,
        workspaceDirectory: String,
        clientVersion: String = "0.1.0",
        sensitiveEnvKeys: Set<String> = [],
        sandbox: ProcessSandbox? = nil,
        log: (@Sendable (String) -> Void)? = nil,
        onToolsChanged: (@Sendable () async -> Void)? = nil,
        bearerToken: String? = nil,
        tokenProvider: BearerTokenProvider? = nil,
        http: HTTPClient = .shared,
        httpClientProvider: (@Sendable (URL) -> HTTPClient)? = nil
    ) {
        self.serverName = serverName
        self.config = config
        self.workspaceDirectory = workspaceDirectory
        self.clientVersion = clientVersion
        self.sensitiveEnvKeys = sensitiveEnvKeys
        self.sandbox = sandbox
        self.log = log
        self.onToolsChanged = onToolsChanged
        self.bearerToken = bearerToken
        self.tokenProvider = tokenProvider
        self.http = http
        self.httpClientProvider = httpClientProvider
    }

    // MARK: Connect / discover

    /// Spawn the server, complete the handshake, and discover its tools. Throws on a
    /// spawn/handshake failure so the manager can isolate this one server.
    public func connect() async throws {
        if config.isRemote {
            try await connectRemote()
            return
        }
        let cwd = config.cwd.map { resolveCwd($0) }
        try await process.start(PersistentProcess.Spawn(
            command: config.command,
            environment: config.environment ?? [:],
            workingDirectory: cwd,
            sensitiveEnvKeys: sensitiveEnvKeys,
            sandbox: sandbox
        ))
        readerTask = Task { [weak self] in await self?.readLoop() }

        let initParams: JSONValue = .object([
            "protocolVersion": .string(mcpProtocolVersion),
            "capabilities": .object([:]),   // tools-only: declare nothing
            "clientInfo": .object(["name": .string("domocode"), "version": .string(clientVersion)]),
        ])
        let initResult = try await request("initialize", params: initParams)
        capabilities = initResult["capabilities"] ?? .object([:])
        // Version is accepted leniently: tools/list + tools/call are stable across the
        // known versions, so proceeding is more compatible than disconnecting. But an
        // UNKNOWN version is worth a warning — it may mean tools behave unexpectedly.
        if let version = initResult["protocolVersion"]?.stringValue, !knownProtocolVersions.contains(version) {
            // Redacted because BOTH interpolations are attacker-influenced: the
            // version is whatever an untrusted subprocess chose to send, and the
            // server name comes from a settings.json that may itself have been
            // written by a project. `log` is wired to stderr, which is what a
            // user pastes into a bug report.
            log?(
                Redaction.diagnostic(
                    "MCP server '\(serverName)' negotiated an unrecognized protocol version "
                        + "'\(version)'; proceeding anyway."
                )
            )
        }

        try await notify("notifications/initialized", params: nil)

        // Only servers that advertise a `tools` capability have tools.
        if initResult["capabilities"]?["tools"] != nil {
            toolsCache = try await listTools()
        }
        if initResult["capabilities"]?["prompts"] != nil {
            promptsCache = try await listPrompts()
        }
        handshakeComplete = true
    }

    /// The tools discovered at connect (or after a `tools/list_changed`).
    public func tools() -> [ToolInfo] { toolsCache }

    /// The server's negotiated capability object, retained for inspection and
    /// resource/template gating by an embedding surface.
    public func serverCapabilities() -> JSONValue { capabilities }

    /// The prompts discovered at connect (or after a `prompts/list_changed`).
    public func prompts() -> [PromptInfo] { promptsCache }

    /// Fetch one prompt with its named string arguments.
    public func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> PromptResult {
        var params: [String: JSONValue] = ["name": .string(name)]
        if !arguments.isEmpty {
            params["arguments"] = .object(arguments.mapValues(JSONValue.string))
        }
        let result = try await request("prompts/get", params: .object(params))
        return PromptResult(
            description: result["description"]?.stringValue,
            messages: result["messages"]?.arrayValue ?? []
        )
    }

    /// Render the text-bearing portions of an MCP prompt into the ordinary
    /// user prompt channel. Non-text blocks remain visible as bounded markers.
    public static func renderPrompt(_ result: PromptResult) -> String {
        result.messages.compactMap { message in
            let role = message["role"]?.stringValue
            let content = renderPromptContent(message["content"])
            guard !content.isEmpty else { return nil }
            return role.map { "\($0): \(content)" } ?? content
        }.joined(separator: "\n\n")
    }

    /// List resources when the server advertises them. A server without the
    /// capability returns an empty list rather than making the catalog path fail.
    public func listResources() async throws -> [ResourceInfo] {
        guard capabilities["resources"] != nil else { return [] }
        let result = try await request("resources/list", params: nil)
        return result["resources"]?.arrayValue?.compactMap { item in
            guard let uri = item["uri"]?.stringValue,
                  let name = item["name"]?.stringValue
            else { return nil }
            return ResourceInfo(
                uri: uri,
                name: name,
                description: item["description"]?.stringValue,
                mimeType: item["mimeType"]?.stringValue
            )
        } ?? []
    }

    /// List URI templates when the server advertises them.
    public func listResourceTemplates() async throws -> [ResourceTemplateInfo] {
        guard capabilities["resources"] != nil else { return [] }
        let result = try await request("resources/templates/list", params: nil)
        return result["resourceTemplates"]?.arrayValue?.compactMap { item in
            guard let uriTemplate = item["uriTemplate"]?.stringValue,
                  let name = item["name"]?.stringValue
            else { return nil }
            return ResourceTemplateInfo(
                uriTemplate: uriTemplate,
                name: name,
                description: item["description"]?.stringValue,
                mimeType: item["mimeType"]?.stringValue
            )
        } ?? []
    }

    /// Read one resource through the same permission/catalog-owned MCP client.
    public func readResource(uri: String) async throws -> [JSONValue] {
        let result = try await request("resources/read", params: .object(["uri": .string(uri)]))
        return result["contents"]?.arrayValue ?? []
    }

    /// Lightweight health/test call for diagnostics and connection setup.
    public func health() async -> Bool {
        (try? await request("ping", params: nil)) != nil
    }

    private func listTools() async throws -> [ToolInfo] {
        var tools: [ToolInfo] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pages = 0
        repeat {
            pages += 1
            guard pages <= maxToolListPages else { throw MCPError.protocolError("tools/list exceeded \(maxToolListPages) pages") }
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params: params)
            for entry in result["tools"]?.arrayValue ?? [] {
                guard let name = entry["name"]?.stringValue else { continue }
                tools.append(ToolInfo(
                    name: name,
                    description: entry["description"]?.stringValue ?? "",
                    inputSchema: entry["inputSchema"] ?? .object([:])
                ))
            }
            let next = result["nextCursor"]?.stringValue
            if let next, !seenCursors.insert(next).inserted {
                throw MCPError.protocolError("tools/list returned a duplicate cursor")
            }
            cursor = next
        } while cursor != nil
        return tools
    }

    private func listPrompts() async throws -> [PromptInfo] {
        var prompts: [PromptInfo] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pages = 0
        repeat {
            pages += 1
            guard pages <= maxToolListPages else {
                throw MCPError.protocolError("prompts/list exceeded \(maxToolListPages) pages")
            }
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("prompts/list", params: params)
            for entry in result["prompts"]?.arrayValue ?? [] {
                guard let name = entry["name"]?.stringValue else { continue }
                let arguments = entry["arguments"]?.arrayValue?.compactMap { argument -> PromptArgumentInfo? in
                    guard let argumentName = argument["name"]?.stringValue else { return nil }
                    return PromptArgumentInfo(
                        name: argumentName,
                        description: argument["description"]?.stringValue,
                        required: argument["required"]?.boolValue ?? false
                    )
                } ?? []
                prompts.append(PromptInfo(
                    name: name,
                    description: entry["description"]?.stringValue,
                    arguments: arguments
                ))
            }
            guard let next = result["nextCursor"]?.stringValue, !next.isEmpty else { break }
            guard seenCursors.insert(next).inserted else {
                throw MCPError.protocolError("prompts/list repeated a cursor")
            }
            cursor = next
        } while true
        return prompts
    }

    // MARK: Call

    /// Invoke a tool. Returns the raw content + isError (mapped to a tool result by the
    /// caller). A protocol error (unknown tool, transport failure) throws.
    public func callTool(name: String, arguments: JSONValue) async throws -> CallResult {
        let params: JSONValue = .object(["name": .string(name), "arguments": arguments])
        let result = try await request("tools/call", params: params)
        return CallResult(
            content: result["content"]?.arrayValue ?? [],
            isError: result["isError"]?.boolValue ?? false,
            structuredContent: result["structuredContent"]
        )
    }

    // MARK: Shutdown

    /// Close stdin, terminate the child, and fail every in-flight request.
    public func shutdown() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        await process.shutdown()
        failAllPending(MCPError.connectionClosed)
    }

    // MARK: Request/response plumbing

    private func nextRequestID() -> Int { nextID += 1; return nextID }

    /// Send a request and await its response, failing on timeout with a
    /// `notifications/cancelled`. Cancellation of the caller also cancels the request.
    private func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        if closed { throw MCPError.connectionClosed }
        if config.isRemote {
            return try await requestRemote(method: method, params: params)
        }
        let id = nextRequestID()
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if let params { object["params"] = params }
        let line = try encodeLine(.object(object))
        let timeout = config.requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                let process = self.process
                // Tracked in `timeoutTasks` so it is cancelled the instant the request
                // resolves (see takePending); otherwise it sleeps the full timeout.
                timeoutTasks[id] = Task {
                    await process.send(line)
                    // The `initialize` request MUST NOT be cancelled per spec, but a
                    // hung handshake should still not block forever — time it out
                    // without emitting a cancelled notification for `initialize`.
                    try? await Task.sleep(for: timeout)
                    await self.timeout(id: id, method: method)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id, method: method, reason: "The tool call was aborted.") }
        }
    }

    /// Remove the pending continuation for `id` and cancel its timeout Task. Returns the
    /// continuation if one was still outstanding. Every resolution path (response,
    /// timeout, cancel, connection-close) goes through here, so a resolved request never
    /// leaves a task sleeping out the full timeout and pinning the actor.
    private func takePending(_ id: Int) -> CheckedContinuation<JSONValue, any Error>? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        return pending.removeValue(forKey: id)
    }

    private func notify(_ method: String, params: JSONValue?) async throws {
        if config.isRemote {
            _ = try await sendRemote(method: method, params: params, id: nil)
            return
        }
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        await process.send(try encodeLine(.object(object)))
    }

    private func encodeLine(_ value: JSONValue) throws -> [UInt8] {
        Array((try value.encodedString()).utf8)
    }

    // MARK: Remote HTTP/SSE transport

    private func connectRemote() async throws {
        _ = try remoteURL()
        let initParams: JSONValue = .object([
            "protocolVersion": .string(mcpProtocolVersion),
            "capabilities": .object([
                "resources": .object(["subscribe": .bool(false), "listChanged": .bool(true)]),
            ]),
            "clientInfo": .object(["name": .string("domocode"), "version": .string(clientVersion)]),
        ])
        let initResult = try await requestRemote(method: "initialize", params: initParams)
        capabilities = initResult["capabilities"] ?? .object([:])
        try await notify("notifications/initialized", params: nil)
        if capabilities["tools"] != nil {
            toolsCache = try await listTools()
        }
        handshakeComplete = true
    }

    private func requestRemote(method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextRequestID()
        let response = try await sendRemote(method: method, params: params, id: id)
        guard !response.body.isEmpty else { throw MCPError.badResponse }
        let messages = remoteMessages(from: response.body)
        guard let message = messages.first(where: { $0["id"]?.intValue == id }) ?? messages.first else {
            throw MCPError.badResponse
        }
        if let error = message["error"] {
            throw MCPError.protocolError(error["message"]?.stringValue ?? "remote MCP error")
        }
        return message["result"] ?? message
    }

    private func sendRemote(
        method: String,
        params: JSONValue?,
        id: Int?
    ) async throws -> (body: Data, status: UInt) {
        let url = try remoteURL()
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { object["id"] = .int(id) }
        if let params { object["params"] = params }
        let body = try JSONValue.object(object).encoded()

        // Resolved per request rather than once at init: the provider decides from the
        // URL whether this endpoint is proxied, and a client's proxy cannot be changed
        // after it is built.
        let client = httpClientProvider?(url) ?? http

        do {
            let token = try await currentBearerToken(
                forceRefresh: false, rejectedToken: nil, wwwAuthenticate: nil
            )
            var response = try await executeRemote(url: url, body: body, token: token, client: client)

            // One refresh, one replay, only when a provider exists to refresh
            // through. The body is a plain byte array, so the replay is the
            // identical request under a new credential — and a second 401
            // falls through to the typed failure rather than a loop. 403 is
            // deliberately not retried: insufficient scope is not cured by a
            // fresher token. The token that just 401'd is handed back so the
            // provider refreshes past exactly it, not past a store snapshot.
            if response.status.code == 401, tokenProvider != nil {
                let challenge = response.headers.first(name: "www-authenticate")
                // Drain the 401's body so AsyncHTTPClient can return the
                // connection to the pool instead of holding it (and the socket)
                // across the whole refresh, which may itself take seconds.
                _ = try? await response.body.collect(upTo: 64 * 1024)
                let fresh = try await currentBearerToken(
                    forceRefresh: true, rejectedToken: token, wwwAuthenticate: challenge
                )
                response = try await executeRemote(url: url, body: body, token: fresh, client: client)
            }

            guard (200..<300).contains(response.status.code) else {
                // Do not include the endpoint, request body, response body, or
                // authorization material in the surfaced error.
                if response.status.code == 401 || response.status.code == 403 {
                    throw MCPError.unauthorized(
                        "MCP server '\(serverName)' rejected the credential (HTTP \(response.status.code))"
                    )
                }
                throw MCPError.protocolError("remote MCP returned HTTP \(response.status.code)")
            }
            for header in response.headers where header.name.lowercased() == "mcp-session-id" {
                remoteSessionID = header.value
            }
            let body = try await collectRemote(response.body)
            return (body: body, status: response.status.code)
        } catch let error as MCPError {
            throw error
        } catch let error as MCPOAuthError {
            // OAuth failures carry their own safe, actionable messages
            // (interaction required, refresh rejected); collapsing them into
            // "request failed" would hide the one thing the user must do.
            throw error
        } catch {
            throw MCPError.protocolError("remote MCP request failed")
        }
    }

    /// The token for one request: the async provider when configured (the
    /// OAuth path), else the static credential resolved at connect.
    private func currentBearerToken(
        forceRefresh: Bool,
        rejectedToken: String?,
        wwwAuthenticate: String?
    ) async throws -> String? {
        if let tokenProvider {
            return try await tokenProvider(forceRefresh, rejectedToken, wwwAuthenticate)
        }
        return bearerToken
    }

    /// One POST of an already-encoded JSON-RPC body. Split from `sendRemote`
    /// so the 401 replay is the same code path as the first attempt.
    private func executeRemote(
        url: URL,
        body: Data,
        token: String?,
        client: HTTPClient
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "accept", value: "application/json, text/event-stream")
        request.headers.add(name: "content-type", value: "application/json")
        request.headers.add(name: "mcp-protocol-version", value: mcpProtocolVersion)
        if let remoteSessionID {
            request.headers.add(name: "mcp-session-id", value: remoteSessionID)
        }
        if let token, !token.isEmpty {
            request.headers.add(name: "authorization", value: "Bearer \(token)")
        }
        request.body = .bytes(Array(body))
        return try await client.execute(
            request,
            timeout: .nanoseconds(Self.nanoseconds(config.requestTimeout))
        )
    }

    private func remoteURL() throws -> URL {
        guard let rawURL = config.url, let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            throw MCPError.networkPolicy("remote MCP requires an http(s) URL")
        }
        if let allowedHosts = config.allowedHosts, !allowedHosts.isEmpty,
           !allowedHosts.contains(where: { $0.lowercased() == host.lowercased() }) {
            throw MCPError.networkPolicy("remote MCP host is not allowed")
        }
        if config.allowPrivateNetwork != true, Self.isPrivateHost(host) {
            throw MCPError.networkPolicy("remote MCP private-network access is disabled")
        }
        return url
    }

    /// Delegated to ``DoMoCore/ProxyPolicy/isPrivateAddress(_:)`` rather than
    /// matched here.
    ///
    /// What used to live at this line matched on prefixes of the host TEXT, and
    /// so recognised `::1` and `fe80:` but not `fc00::/7` — the range a private
    /// IPv6 network actually uses — nor `::ffff:10.0.0.1`, the IPv4-mapped form a
    /// dual-stack resolver hands back. Both reached the network without the
    /// opt-in this gate exists to require, which made the gate a formality for
    /// anyone who wrote the address the other way. The shared version parses the
    /// address instead of the string, and having one copy is the point: two
    /// answers to "is this private" is how the gap appeared.
    private static func isPrivateHost(_ host: String) -> Bool {
        ProxyPolicy.isPrivateAddress(host)
    }

    private func collectRemote(_ body: HTTPClientResponse.Body) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var buffer = try await body.collect(upTo: 4 << 20)
                return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
            }
            group.addTask {
                try await Task.sleep(for: self.config.requestTimeout)
                throw MCPError.timedOut
            }
            let data = try await group.next() ?? Data()
            group.cancelAll()
            return data
        }
    }

    private func remoteMessages(from data: Data) -> [JSONValue] {
        if let value = try? JSONValue(parsing: data) { return [value] }
        let text = String(decoding: data, as: UTF8.self)
        var messages: [JSONValue] = []
        var dataLines: [String] = []
        func appendPayload() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            if let value = try? JSONValue(parsing: Data(payload.utf8)) { messages.append(value) }
            dataLines.removeAll(keepingCapacity: true)
        }
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty || line == "\r" {
                appendPayload()
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if let value = try? JSONValue(parsing: Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) {
                messages.append(value)
            }
        }
        appendPayload()
        return messages
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let (seconds, secondsOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return components.seconds > 0 ? .max : .min }
        let (nanoseconds, nanosecondsOverflow) = seconds.addingReportingOverflow(components.attoseconds / 1_000_000_000)
        return nanosecondsOverflow ? (components.seconds > 0 ? .max : .min) : nanoseconds
    }

    /// The reader loop: classify every stdout line and dispatch it. When the stream
    /// ends (the child died), every pending request fails.
    private func readLoop() async {
        for await line in process.lines {
            guard let message = try? JSONValue(parsing: Data(line)) else { continue }
            dispatch(message)
        }
        // The stream ended: the child exited or crashed. Mark the client closed so a
        // subsequent request() fails fast with .connectionClosed instead of parking on a
        // continuation whose send goes into a dead pipe and only resolves at timeout.
        closed = true
        failAllPending(MCPError.connectionClosed)
    }

    private func dispatch(_ message: JSONValue) {
        let hasMethod = message["method"] != nil
        if let idValue = message["id"], !hasMethod {
            // Response to one of our requests (our ids are integers).
            guard let id = idValue.intValue, let continuation = takePending(id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: MCPError.protocolError(error["message"]?.stringValue ?? "JSON-RPC error"))
            } else {
                continuation.resume(returning: message["result"] ?? .object([:]))
            }
        } else if hasMethod {
            let method = message["method"]?.stringValue ?? ""
            if let idValue = message["id"] {
                respondToServerRequest(idValue: idValue, method: method)
            } else {
                handleNotification(method)
            }
        }
    }

    /// The only server->client request this tools-only client expects is `ping`;
    /// anything else gets a `-32601` so the server does not hang.
    private func respondToServerRequest(idValue: JSONValue, method: String) {
        let response: JSONValue
        if method == "ping" {
            response = .object(["jsonrpc": "2.0", "id": idValue, "result": .object([:])])
        } else {
            response = .object([
                "jsonrpc": "2.0", "id": idValue,
                "error": .object(["code": .int(-32601), "message": .string("Method not found")]),
            ])
        }
        if let line = try? encodeLine(response) {
            let process = self.process
            Task { await process.send(line) }
        }
    }

    private func handleNotification(_ method: String) {
        if method == "notifications/tools/list_changed" {
            Task { [weak self] in await self?.refreshTools() }
        }
        if method == "notifications/prompts/list_changed" {
            Task { [weak self] in await self?.refreshPrompts() }
        }
        // progress / message / cancelled and the rest are ignored for a tools-only client.
    }

    private func refreshTools() async {
        // Don't run before the initial discovery has installed the cache — a mid-handshake
        // list_changed would otherwise race a second listTools into `toolsCache`.
        guard handshakeComplete, !closed, let refreshed = try? await listTools() else { return }
        guard refreshed != toolsCache else { return }
        toolsCache = refreshed
        await onToolsChanged?()
    }

    private func refreshPrompts() async {
        guard handshakeComplete, !closed, let refreshed = try? await listPrompts() else { return }
        guard refreshed != promptsCache else { return }
        promptsCache = refreshed
        await onToolsChanged?()
    }

    private func timeout(id: Int, method: String) async {
        guard let continuation = takePending(id) else { return }   // already answered
        // Tell the server to stop working on it (never for `initialize`, per spec).
        if method != "initialize" {
            try? await notify("notifications/cancelled", params: .object(["requestId": .int(id), "reason": .string("timeout")]))
        }
        continuation.resume(throwing: MCPError.timedOut)
    }

    private func cancel(id: Int, method: String, reason: String) async {
        guard let continuation = takePending(id) else { return }
        if method != "initialize" {
            try? await notify("notifications/cancelled", params: .object(["requestId": .int(id), "reason": .string(reason)]))
        }
        continuation.resume(throwing: CancellationError())
    }

    private func failAllPending(_ error: any Error) {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func resolveCwd(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return workspaceDirectory + "/" + path
    }
}

private func renderPromptContent(_ content: JSONValue?) -> String {
    guard let content else { return "" }
    if let blocks = content.arrayValue {
        return blocks.map { renderPromptContent($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    if let text = content["text"]?.stringValue { return text }
    if let type = content["type"]?.stringValue { return "[\(type) content]" }
    return (try? content.encodedString()) ?? ""
}
