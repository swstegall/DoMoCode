// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A minimal OpenAI-compatible HTTP/1.1 + SSE server for driving the real
// `domocode` binary end to end. Raw POSIX sockets on purpose: it needs a real
// listening socket the compiled binary connects to over the loopback, and
// pulling in a full server framework (or NIO, which is only a transitive
// dependency here) to answer a handful of fixed requests would be a heavier
// test dependency than the thing under test. This is the DoMoTermIO rationale
// applied to a test helper — POSIX by design — which is why the DoMoCLITests
// target is built without `.strictMemorySafety()`.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// `SOCK_STREAM` is an `Int32` on Darwin and an enum on Glibc; normalize it.
#if canImport(Glibc)
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let streamSocketType = SOCK_STREAM
#endif

/// One parsed HTTP request the gateway received. Enough to route on and to let a
/// test assert what the binary actually sent.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let body: String
}

/// A loopback HTTP/1.1 server that answers OpenAI-compatible requests.
///
/// Each `POST .../chat/completions` is answered with the next scripted SSE body,
/// in order, so a two-turn conversation is expressed as two bodies. Every
/// response closes its connection (`Connection: close`), which both delimits the
/// SSE stream by EOF — the LiteLLM path async-http-client streams incrementally —
/// and forces the client to open a fresh connection per turn, keeping the
/// scripted order aligned with request order.
final class MockGateway: @unchecked Sendable {

    /// The port the OS assigned. Loopback only.
    let port: UInt16

    private let listenFD: Int32
    private let chatBodies: [String]
    private let lock = NSLock()
    private var served = 0
    private var recorded: [RecordedRequest] = []
    private var stopped = false
    private var thread: Thread?

    /// - Parameter chatCompletionBodies: the SSE body for each successive
    ///   `chat/completions` request, `data:`-framed and `[DONE]`-terminated.
    init(chatCompletionBodies: [String]) throws {
        self.chatBodies = chatCompletionBodies

        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else { throw MockGatewayError("socket() failed: \(errno)") }

        var yes: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian  // ephemeral
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)  // 127.0.0.1

        let bindResult = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw MockGatewayError("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw MockGatewayError("listen() failed: \(errno)")
        }

        var bound = sockaddr_in()
        var boundSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = unsafe withUnsafeMutablePointer(to: &bound) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe getsockname(fd, generic, &boundSize)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw MockGatewayError("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    /// The base URL a client should target, including the `/v1` prefix.
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// How many requests were answered. Read after the client has finished.
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    /// The requests the gateway saw, in arrival order.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Starts accepting on a background thread. Connections are handled serially,
    /// which is all a sequential agent loop needs and keeps the counter free of
    /// its own races.
    func start() {
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "mock-gateway"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops accepting and closes the listening socket. Idempotent.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        // Closing the listening fd makes the blocking `accept` return with an
        // error, which ends the loop.
        close(listenFD)
    }

    // MARK: Accept loop

    private func acceptLoop() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }

            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // listen fd closed by stop()
            }
            handleConnection(client)
            close(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        // A read timeout keeps a misbehaving client from wedging the test.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let request = readRequest(fd) else { return }

        lock.lock()
        recorded.append(request)
        let index = served
        served += 1
        lock.unlock()

        let response: [UInt8]
        if request.method == "GET", request.path.contains("models") {
            response = Self.httpResponse(
                contentType: "application/json",
                body: Array(#"{"object":"list","data":[{"id":"mock-model","object":"model","owned_by":"openai"}]}"#.utf8)
            )
        } else {
            let body = index < chatBodies.count ? chatBodies[index] : Self.fallbackDoneBody
            response = Self.sseResponse(callID: "mock-call-\(index)", body: body)
        }
        writeAll(fd, response)
    }

    // MARK: Request reading

    private func readRequest(_ fd: Int32) -> RecordedRequest? {
        var buffer: [UInt8] = []
        var headerEnd: Int?

        // Read until the header terminator is seen.
        while headerEnd == nil {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return nil }
            buffer.append(contentsOf: chunk)
            headerEnd = Self.indexOfDoubleCRLF(buffer)
            if buffer.count > 1 << 20 { return nil }  // runaway header guard
        }
        guard let headerEnd else { return nil }

        let headerBytes = Array(buffer[..<headerEnd])
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        var contentLength = 0
        var expectsContinue = false
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("expect:"), lower.contains("100-continue") {
                expectsContinue = true
            }
        }

        // Some clients wait for a 100-continue before sending the body.
        if expectsContinue {
            writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        // Drain the body up to Content-Length.
        var bodyBytes = Array(buffer[(headerEnd + 4)...])
        while bodyBytes.count < contentLength {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            bodyBytes.append(contentsOf: chunk)
        }

        return RecordedRequest(method: method, path: path, body: String(decoding: bodyBytes, as: UTF8.self))
    }

    /// Reads one chunk (up to 64 KiB), retrying on `EINTR`. `nil` on error, empty
    /// on clean EOF.
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
        var offset = 0
        unsafe bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let sent = unsafe send(fd, base + offset, bytes.count - offset, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += sent
            }
        }
    }

    // MARK: Response building

    private static func sseResponse(callID: String, body: String) -> [UInt8] {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "x-litellm-call-id: \(callID)",
            "x-litellm-model-id: mock-deployment",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(headers.utf8) + Array(body.utf8)
    }

    private static func httpResponse(contentType: String, body: [UInt8]) -> [UInt8] {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(headers.utf8) + body
    }

    /// A well-formed but content-free terminal stream, used if more requests
    /// arrive than the test scripted.
    private static let fallbackDoneBody = """
        data: {"choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}]}

        data: [DONE]


        """

    private static func indexOfDoubleCRLF(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i
        }
        return nil
    }
}

struct MockGatewayError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
