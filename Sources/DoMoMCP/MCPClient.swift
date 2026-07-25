// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The JSON-RPC 2.0 protocol layer over a persistent stdio subprocess: correlates
// responses to requests by id, answers server-originated `ping` (and `-32601`s any
// other server request, since this client declares no capabilities), runs the
// `initialize` handshake, discovers tools (paginated `tools/list`), and invokes them
// (`tools/call`) with a per-request timeout that emits `notifications/cancelled`. A
// faithful hand-rolled port of the MCP 2025-06-18 spec — no SDK.

import DoMoCore
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
    }

    public let serverName: String
    private let config: MCPServerConfig
    private let workspaceDirectory: String
    private let clientVersion: String
    private let sensitiveEnvKeys: Set<String>
    private let log: (@Sendable (String) -> Void)?

    private let process = PersistentProcess()
    private var readerTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// The per-request timeout Task, keyed by request id, so it can be cancelled the
    /// moment the request resolves — otherwise it sleeps the full timeout holding the
    /// actor (and the child-process handle) alive, and a burst of fast calls piles up
    /// that many sleeping tasks.
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var toolsCache: [ToolInfo] = []
    private var closed = false
    /// Set once the initialize handshake + initial tools/list have completed, so a
    /// `tools/list_changed` arriving mid-handshake doesn't race a second discovery into
    /// the cache concurrently with the first.
    private var handshakeComplete = false

    public init(
        serverName: String,
        config: MCPServerConfig,
        workspaceDirectory: String,
        clientVersion: String = "0.1.0",
        sensitiveEnvKeys: Set<String> = [],
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.serverName = serverName
        self.config = config
        self.workspaceDirectory = workspaceDirectory
        self.clientVersion = clientVersion
        self.sensitiveEnvKeys = sensitiveEnvKeys
        self.log = log
    }

    // MARK: Connect / discover

    /// Spawn the server, complete the handshake, and discover its tools. Throws on a
    /// spawn/handshake failure so the manager can isolate this one server.
    public func connect() async throws {
        let cwd = config.cwd.map { resolveCwd($0) }
        await process.start(PersistentProcess.Spawn(
            command: config.command,
            environment: config.environment ?? [:],
            workingDirectory: cwd,
            sensitiveEnvKeys: sensitiveEnvKeys
        ))
        readerTask = Task { [weak self] in await self?.readLoop() }

        let initParams: JSONValue = .object([
            "protocolVersion": .string(mcpProtocolVersion),
            "capabilities": .object([:]),   // tools-only: declare nothing
            "clientInfo": .object(["name": .string("domocode"), "version": .string(clientVersion)]),
        ])
        let initResult = try await request("initialize", params: initParams)
        // Version is accepted leniently: tools/list + tools/call are stable across the
        // known versions, so proceeding is more compatible than disconnecting. But an
        // UNKNOWN version is worth a warning — it may mean tools behave unexpectedly.
        if let version = initResult["protocolVersion"]?.stringValue, !knownProtocolVersions.contains(version) {
            log?("MCP server '\(serverName)' negotiated an unrecognized protocol version '\(version)'; proceeding anyway.")
        }

        try await notify("notifications/initialized", params: nil)

        // Only servers that advertise a `tools` capability have tools.
        if initResult["capabilities"]?["tools"] != nil {
            toolsCache = try await listTools()
        }
        handshakeComplete = true
    }

    /// The tools discovered at connect (or after a `tools/list_changed`).
    public func tools() -> [ToolInfo] { toolsCache }

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
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        await process.send(try encodeLine(.object(object)))
    }

    private func encodeLine(_ value: JSONValue) throws -> [UInt8] {
        Array((try value.encodedString()).utf8)
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
        // progress / message / cancelled and the rest are ignored for a tools-only client.
    }

    private func refreshTools() async {
        // Don't run before the initial discovery has installed the cache — a mid-handshake
        // list_changed would otherwise race a second listTools into `toolsCache`.
        guard handshakeComplete, !closed, let refreshed = try? await listTools() else { return }
        toolsCache = refreshed
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
