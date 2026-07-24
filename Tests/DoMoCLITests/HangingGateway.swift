// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A loopback SSE server that streams ONE content delta and then holds the
// connection open indefinitely, never sending `finish_reason` or `[DONE]`. It
// exists to make Escape-to-abort deterministic: while it holds, the client's
// stream is genuinely in-flight, so the abort under test cancels a real running
// turn rather than racing a fast completion. When the client aborts (the REPL
// cancelling the run task), the socket closes, the blocked `recv` returns, and the
// handler exits — so the server needs no timer to unwind. Raw POSIX sockets, the
// same rationale as `MockGateway` (and why `DoMoCLITests` builds without strict
// memory safety).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Glibc)
private let hangingStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let hangingStreamSocketType = SOCK_STREAM
#endif

final class HangingGateway: @unchecked Sendable {
    let port: UInt16

    private let listenFD: Int32
    private let firstDelta: String
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?

    /// - Parameter firstDelta: the assistant text sent in the single streamed
    ///   delta before the server goes silent.
    init(firstDelta: String) throws {
        self.firstDelta = firstDelta

        let fd = socket(AF_INET, hangingStreamSocketType, 0)
        guard fd >= 0 else { throw HangingGatewayError("socket() failed: \(errno)") }

        var yes: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)

        let bindResult = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw HangingGatewayError("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HangingGatewayError("listen() failed: \(errno)")
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
            throw HangingGatewayError("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() {
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "hanging-gateway"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }

            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handleConnection(client)
            close(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        // A generous read timeout is only a backstop; the normal exit is the client
        // aborting, which surfaces as a zero-length read below.
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard drainRequestHeaders(fd) else { return }

        let body = """
            data: {"id":"h1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\(firstDelta)"},"finish_reason":null}]}


            """
        writeAll(fd, Self.sseHeaders() + Array(body.utf8))

        // Hold the connection: block reading until the client closes (the abort).
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = unsafe scratch.withUnsafeMutableBytes { raw in
                unsafe recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    /// Read until the end of the HTTP request headers, so the client's write side
    /// is satisfied before the response streams. The body is ignored.
    private func drainRequestHeaders(_ fd: Int32) -> Bool {
        var buffer: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = unsafe scratch.withUnsafeMutableBytes { raw in
                unsafe recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return false
            }
            buffer.append(contentsOf: scratch[..<count])
            if Self.containsDoubleCRLF(buffer) { return true }
            if buffer.count > 1 << 20 { return false }
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

    private static func sseHeaders() -> [UInt8] {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "x-litellm-call-id: hang-call",
            "x-litellm-model-id: mock-deployment",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(headers.utf8)
    }

    private static func containsDoubleCRLF(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for i in 0...(bytes.count - 4) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return true
        }
        return false
    }
}

struct HangingGatewayError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
