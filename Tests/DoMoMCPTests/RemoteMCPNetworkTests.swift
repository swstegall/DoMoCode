// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Two things this client already promises a network-gated deployment, pinned against a
// real socket so neither can regress silently:
//
//   1. A remote MCP endpoint on a private network is reached when — and only when — the
//      server entry opts in with `allowPrivateNetwork`. Both directions are asserted:
//      the opt-in completes the handshake, discovers tools and calls one; the default
//      refuses before a single byte leaves the process.
//   2. An endpoint that wants no credential works, and no credential is sent. Asserting
//      only that the handshake succeeded would pass just as well if this client had
//      offered an empty bearer, so the assertion is on the captured request: it must
//      carry no `authorization` header at all.
//
// Plus the rule that keeps both true once a corporate HTTP proxy is configured: a
// loopback endpoint is always reached directly, per the standard `no_proxy` convention,
// because a proxy cannot reach the caller's own machine and routing to it would break
// every local endpoint this program talks to.
//
// The fixture is a raw POSIX loopback listener speaking HTTP/1.1, for the same reason
// the package's other socket fixtures are: a real listening socket is the whole point,
// and a server framework would be a heavier test dependency than the code under test.

import DoMoAgent
import DoMoCore
import DoMoMCP
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `SOCK_STREAM` is an `Int32` on Darwin and an enum on Glibc; normalize it.
#if canImport(Glibc)
private let mcpStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let mcpStreamSocketType = SOCK_STREAM
#endif

/// One HTTP request the fixture received, kept in enough detail for a test to assert
/// what this client actually put on the wire — headers included, because the absence of
/// a header is exactly what one of these tests is about.
private struct RecordedMCPRequest: Sendable {
    let method: String
    let path: String
    /// Header names in arrival order, lowercased. An ARRAY rather than the dictionary
    /// below so a repeated header cannot hide behind a collapsed key.
    let headerNames: [String]
    let headers: [String: String]
    let body: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var hasAuthorization: Bool { headerNames.contains("authorization") }
}

/// A loopback HTTP/1.1 server that answers the MCP `initialize` + `tools/list` +
/// `tools/call` handshake with JSON bodies.
///
/// Every response says `Connection: close`, so each JSON-RPC message arrives on its own
/// connection and the recorded order matches the protocol order. The listener is
/// non-blocking so its accept loop observes `stop()` without a cross-thread close —
/// closing a descriptor another thread is blocked in `accept(2)` on is not reliable on
/// Darwin, and releasing the number early lets a parallel fixture inherit it.
private final class LoopbackMCPServer: @unchecked Sendable {
    let port: UInt16

    private let listenFD: Int32
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var recorded: [RecordedMCPRequest] = []
    private var stopped = false
    private var activeClientFDs: Set<Int32> = []
    private var acceptLoopFinished = false

    init() throws {
        let fd = socket(AF_INET, mcpStreamSocketType, 0)
        guard fd >= 0 else { throw FixtureError("socket() failed: \(errno)") }

        var yes: Int32 = 1
        _ = unsafe withUnsafeBytes(of: &yes) {
            unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0.baseAddress, socklen_t($0.count))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian   // ephemeral
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)   // 127.0.0.1
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw FixtureError("bind() failed: \(errno)") }
        guard listen(fd, 16) == 0 else { close(fd); throw FixtureError("listen() failed: \(errno)") }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw FixtureError("fcntl() failed: \(errno)")
        }

        var named = sockaddr_in()
        var namedSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedResult = unsafe withUnsafeMutablePointer(to: &named) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe withUnsafeMutablePointer(to: &namedSize) { unsafe getsockname(fd, generic, $0) }
            }
        }
        guard namedResult == 0 else { close(fd); throw FixtureError("getsockname() failed: \(errno)") }

        self.listenFD = fd
        self.port = UInt16(bigEndian: named.sin_port)
    }

    /// The MCP endpoint URL, which is a private-network address by definition — which is
    /// what makes it the right fixture for the `allowPrivateNetwork` gate.
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    var requests: [RecordedMCPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func start() {
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "loopback-mcp"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Stops accepting and closes the listening socket. Idempotent.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let clients = activeClientFDs
        lock.unlock()
        if !alreadyStopped { _ = shutdown(listenFD, Int32(SHUT_RDWR)) }
        for client in clients { _ = shutdown(client, Int32(SHUT_RDWR)) }

        // Wait the accept loop out before releasing the descriptor number: the OS would
        // otherwise hand it to the next fixture while this thread can still touch it.
        while true {
            lifecycleLock.lock()
            let finished = acceptLoopFinished
            lifecycleLock.unlock()
            if finished { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !alreadyStopped { close(listenFD) }
    }

    // MARK: Accept loop

    private func acceptLoop() {
        defer {
            lifecycleLock.lock()
            acceptLoopFinished = true
            lifecycleLock.unlock()
        }

        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }

            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                    continue
                }
                return
            }
            // An accepted descriptor can inherit the listener's non-blocking flag on
            // Darwin; request parsing below expects to block until the bytes arrive.
            let flags = fcntl(client, F_GETFL, 0)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                close(client)
                continue
            }

            lock.lock()
            let stopping = stopped
            if !stopping { activeClientFDs.insert(client) }
            lock.unlock()
            if stopping {
                _ = shutdown(client, Int32(SHUT_RDWR))
                close(client)
                return
            }

            handleConnection(client)
            lock.lock()
            activeClientFDs.remove(client)
            lock.unlock()
            close(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        // A read timeout so a client that never finishes its request cannot wedge the
        // whole suite behind this one connection.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = unsafe withUnsafeBytes(of: &timeout) {
            unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0.baseAddress, socklen_t($0.count))
        }

        guard let request = readRequest(fd) else { return }
        lock.lock()
        recorded.append(request)
        lock.unlock()

        if let body = Self.jsonRPCResponse(for: request.body) {
            writeAll(fd, Self.response(status: "200 OK", body: Array(body.utf8)))
        } else {
            // A JSON-RPC notification has no id and no reply; the MCP HTTP binding
            // answers it with an accepted status and an empty body.
            writeAll(fd, Self.response(status: "202 Accepted", body: []))
        }
    }

    // MARK: Protocol

    /// The JSON body to answer `requestBody` with, or nil when the message carries no id
    /// — a JSON-RPC notification, which is answered with a status and no body.
    private static func jsonRPCResponse(for requestBody: String) -> String? {
        guard let message = try? JSONValue(parsing: requestBody),
              let method = message["method"]?.stringValue,
              let id = message["id"]?.intValue
        else { return nil }

        let envelope: JSONValue
        switch method {
        case "initialize":
            envelope = Self.envelope(id: id, result: .object([
                // Spelled out rather than read from the client's own constant: a fixture
                // that agreed by construction could never catch the client moving to a
                // revision this handshake was not written against.
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("loopback"), "version": .string("1")]),
            ]))
        case "tools/list":
            envelope = Self.envelope(id: id, result: .object([
                "tools": .array([
                    .object([
                        "name": .string("echo"),
                        "description": .string("Echo text"),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["text": .object(["type": .string("string")])]),
                            "required": .array([.string("text")]),
                        ]),
                    ])
                ])
            ]))
        case "tools/call":
            let text = message["params"]?["arguments"]?["text"]?.stringValue ?? ""
            envelope = Self.envelope(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("echo: " + text)])]),
                "isError": .bool(false),
            ]))
        case "ping":
            envelope = Self.envelope(id: id, result: .object([:]))
        default:
            envelope = .object([
                "jsonrpc": .string("2.0"),
                "id": .int(id),
                "error": .object(["code": .int(-32601), "message": .string("Method not found")]),
            ])
        }
        return try? envelope.encodedString()
    }

    private static func envelope(id: Int, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .int(id), "result": result])
    }

    private static func response(status: String, body: [UInt8]) -> [UInt8] {
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(head.utf8) + body
    }

    // MARK: Socket I/O

    private func readRequest(_ fd: Int32) -> RecordedMCPRequest? {
        var buffer: [UInt8] = []
        var headerEnd: Int?
        while headerEnd == nil {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return nil }
            buffer.append(contentsOf: chunk)
            headerEnd = Self.indexOfDoubleCRLF(buffer)
            if buffer.count > 1 << 20 { return nil }   // runaway header guard
        }
        guard let headerEnd else { return nil }

        let lines = String(decoding: buffer[..<headerEnd], as: UTF8.self)
            .split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")

        var headerNames: [String] = []
        var headers: [String: String] = [:]
        var contentLength = 0
        var expectsContinue = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headerNames.append(name)
            headers[name] = value
            if name == "content-length" { contentLength = Int(value) ?? 0 }
            if name == "expect", value.lowercased().contains("100-continue") { expectsContinue = true }
        }

        // Some clients hold the body back until the interim response arrives.
        if expectsContinue { writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }

        var bodyBytes = Array(buffer[(headerEnd + 4)...])
        while bodyBytes.count < contentLength {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            bodyBytes.append(contentsOf: chunk)
        }

        return RecordedMCPRequest(
            method: parts.count > 0 ? String(parts[0]) : "",
            path: parts.count > 1 ? String(parts[1]) : "",
            headerNames: headerNames,
            headers: headers,
            body: String(decoding: bodyBytes, as: UTF8.self)
        )
    }

    /// One chunk, retrying on `EINTR`. `nil` on error, empty on clean EOF.
    private func readChunk(_ fd: Int32) -> [UInt8]? {
        var scratch = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = unsafe scratch.withUnsafeMutableBytes { raw in
                unsafe recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return Array(scratch[..<count])
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var remaining = bytes
        while !remaining.isEmpty {
            let sent = unsafe remaining.withUnsafeBytes { raw in
                unsafe send(fd, raw.baseAddress, raw.count, 0)
            }
            if sent <= 0 {
                if errno == EINTR { continue }
                return
            }
            remaining.removeFirst(sent)
        }
    }

    private static func indexOfDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i
        }
        return nil
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@Suite("Remote MCP over a private network, without a credential", .serialized)
struct RemoteMCPNetworkTests {

    /// 10s covers the handshake plus one tool call over the loopback; nothing here
    /// asserts how fast any of it is.
    private func remoteConfig(
        endpoint: String,
        allowPrivateNetwork: Bool?
    ) -> MCPServerConfig {
        MCPServerConfig(
            command: [],
            timeout: 10_000,
            url: endpoint,
            transport: .streamableHTTP,
            allowPrivateNetwork: allowPrivateNetwork
        )
    }

    @Test("An opted-in private-network endpoint completes the handshake and serves tools")
    func privateNetworkEndpointIsReachableWhenAllowed() async throws {
        let server = try LoopbackMCPServer()
        server.start()
        defer { server.stop() }

        let client = MCPClient(
            serverName: "intranet",
            config: remoteConfig(endpoint: server.endpoint, allowPrivateNetwork: true),
            workspaceDirectory: NSTemporaryDirectory()
        )
        try await client.connect()
        defer { Task { await client.shutdown() } }

        let tools = await client.tools()
        #expect(tools.map(\.name) == ["echo"])

        // The whole remote path, not just the handshake: a tool call travels over the
        // same HTTP transport and its result comes back.
        let result = try await client.callTool(name: "echo", arguments: .object(["text": .string("hi")]))
        #expect(!result.isError)
        #expect(result.content.first?["text"]?.stringValue == "echo: hi")

        // initialize, notifications/initialized, tools/list, tools/call — all POSTed to
        // the configured path.
        let methods = server.requests.compactMap {
            (try? JSONValue(parsing: $0.body))?["method"]?.stringValue
        }
        #expect(methods == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(server.requests.allSatisfy { $0.method == "POST" && $0.path == "/mcp" })
    }

    @Test("The same endpoint is refused, before any connection, without the opt-in")
    func privateNetworkEndpointIsRefusedByDefault() async throws {
        let server = try LoopbackMCPServer()
        server.start()
        defer { server.stop() }

        let client = MCPClient(
            serverName: "intranet",
            config: remoteConfig(endpoint: server.endpoint, allowPrivateNetwork: nil),
            workspaceDirectory: NSTemporaryDirectory()
        )
        do {
            try await client.connect()
            Issue.record("a private-network endpoint connected without the opt-in")
        } catch MCPClient.MCPError.networkPolicy(let reason) {
            #expect(reason.contains("private-network"))
        } catch {
            Issue.record("unexpected error refusing the endpoint: \(error)")
        }

        // The gate has to hold BEFORE the socket: a refusal that still contacted the
        // host would have leaked the request the policy exists to prevent.
        #expect(server.requests.isEmpty)
    }

    @Test("With no credential configured the request carries no authorization header")
    func noCredentialMeansNoAuthorizationHeader() async throws {
        let server = try LoopbackMCPServer()
        server.start()
        defer { server.stop() }

        // Neither `credentialReference` nor `bearerTokenEnvironment`, and no credential
        // provider: the endpoint is unauthenticated, which nothing here refuses.
        let manager = MCPManager()
        let tools = await manager.connect(
            servers: ["intranet": remoteConfig(endpoint: server.endpoint, allowPrivateNetwork: true)],
            workspaceDirectory: NSTemporaryDirectory()
        )
        defer { Task { await manager.shutdown() } }

        #expect(tools.map(\.definition.name) == ["intranet_echo"])

        let requests = server.requests
        #expect(!requests.isEmpty, "no request reached the endpoint, so the header assertion below is vacuous")
        // Not "the header is empty" and not "it isn't a Bearer": the header must be
        // ABSENT. A test that only asserted the handshake succeeded would pass just as
        // well if this client had sent `authorization: Bearer `.
        #expect(requests.allSatisfy { !$0.hasAuthorization })
        // Proof the capture itself works, so `hasAuthorization == false` means the header
        // was absent rather than that no headers were recorded.
        #expect(requests.allSatisfy { $0.header("content-type") == "application/json" })
    }

    @Test("A loopback endpoint is reached directly even when a proxy is configured")
    func loopbackIsNeverProxied() async throws {
        // The conventional variables, as a shell would set them. `.invalid` is reserved
        // by RFC 2606 and never resolves, so anything routed through this proxy fails.
        let settings = ProxyPolicy.fromEnvironment([
            "http_proxy": "http://proxy.invalid:8080",
            "https_proxy": "http://proxy.invalid:8080",
        ])
        #expect(settings.isConfigured, "the rest of this test is vacuous unless a proxy is configured")

        let server = try LoopbackMCPServer()
        server.start()
        defer { server.stop() }

        // The policy itself: a routable host is proxied, the loopback endpoint is not,
        // even though no `no_proxy` entry mentions it.
        let routable = try #require(URL(string: "https://mcp.example.test/mcp"))
        let loopback = try #require(URL(string: server.endpoint))
        #expect(ProxyPolicy.endpoint(for: routable, settings: settings) != nil)
        #expect(ProxyPolicy.endpoint(for: loopback, settings: settings) == nil)

        // And through the client the manager hands its servers: had the loopback been
        // proxied, this handshake would have failed trying to reach `proxy.invalid`.
        let manager = MCPManager(proxy: settings)
        let tools = await manager.connect(
            servers: ["intranet": remoteConfig(endpoint: server.endpoint, allowPrivateNetwork: true)],
            workspaceDirectory: NSTemporaryDirectory()
        )
        defer { Task { await manager.shutdown() } }

        #expect(tools.map(\.definition.name) == ["intranet_echo"])
        #expect(!server.requests.isEmpty)
    }
}
