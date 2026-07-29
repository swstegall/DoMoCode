// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A loopback server that answers with response HEADERS and then stalls forever
// without closing the socket.
//
// This is the shape no real `DoMoServer` can be made to take, and it is the exact
// shape that wedges a client: `HTTPClient.execute(_:timeout:)`'s deadline covers
// only time-to-response-head — the deadline task is cancelled the moment the head
// arrives — and the client is built with no read timeout. So the `collect(upTo:)`
// that follows is unbounded, and a proxy or a runtime that dies mid-answer leaves
// every REST call parked for the life of the process, `abort` included.
//
// Raw POSIX sockets, following `ExplainingServer` next door. A real HTTP stack
// would go out of its way to prevent exactly the behaviour being staged here.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Glibc)
private let stallingStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let stallingStreamSocketType = SOCK_STREAM
#endif

struct StallingBodyServerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class StallingBodyServer: @unchecked Sendable {
    let port: UInt16

    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var open: [Int32] = []
    private var thread: Thread?

    init() throws {
        let fd = socket(AF_INET, stallingStreamSocketType, 0)
        guard fd >= 0 else { throw StallingBodyServerError("socket() failed: \(errno)") }

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
            throw StallingBodyServerError("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw StallingBodyServerError("listen() failed: \(errno)")
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
            throw StallingBodyServerError("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func start() {
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "stalling-body-server"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let sockets = open
        open = []
        lock.unlock()
        guard !alreadyStopped else { return }
        for fd in sockets { close(fd) }
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
            // Held open, never written to again, and closed only by `stop()`. The
            // client must be the one that gives up.
            lock.lock()
            if stopped {
                lock.unlock()
                close(client)
                return
            }
            open.append(client)
            lock.unlock()
            handleConnection(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard drainRequestHeaders(fd) else { return }
        // A `Content-Length` the body will never satisfy: the head completes (so
        // AsyncHTTPClient's own deadline is cancelled) and the read then blocks
        // forever.
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: 4096",
            "",
            "",
        ].joined(separator: "\r\n")
        writeAll(fd, Array(head.utf8))
    }

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

    private static func containsDoubleCRLF(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return true
        }
        return false
    }
}
