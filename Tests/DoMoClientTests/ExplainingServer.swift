// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A loopback HTTP server that answers canned statuses and bodies, route by route.
//
// It exists for two things the real `DoMoServer` cannot demonstrate. First, its
// errors carry an EMPTY body (`HTTPError(.notFound)` and friends have no
// message), so nothing in the package could show the difference between "a 500
// happened" and "a 502 happened, and here is the proxy's explanation" — which is
// exactly the difference `ServerClientError.unexpectedStatus.body` exists to
// preserve, and a reverse proxy in front of a real runtime is precisely the
// thing that answers with a status AND a sentence. Second, a real runtime cannot
// be made to list a session and then refuse to resume it, which is the state the
// client used to enter silently and then refuse every prompt from.
//
// Raw POSIX sockets, following `DoMoCLITests/HangingGateway`: a full HTTP
// implementation is not needed to answer canned responses, and test targets
// build without strict memory safety.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Glibc)
private let explainingStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let explainingStreamSocketType = SOCK_STREAM
#endif

struct ExplainingServerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One canned answer, matched on the request line's method and path prefix.
///
/// A prefix rather than an exact path because session ids are generated: the
/// interesting routes are `/session/<id>/messages` and `/session/<id>/events`,
/// and a test wants to talk about them without knowing the id.
struct StubRoute: Sendable {
    let method: String
    let pathContains: String
    let status: Int
    let reason: String
    let body: String
    /// How many times this route may answer before it is skipped and matching
    /// falls through to whatever comes after it. `nil` is unlimited.
    ///
    /// Needed because several of the client's error paths only exist on the
    /// SECOND call to the same endpoint: the session-list refresh that follows a
    /// create, and the history re-seed that follows a reconnect, both go back to a
    /// route that had to succeed the first time for the client to reach them at all.
    let times: Int?

    init(
        _ method: String,
        _ pathContains: String,
        _ status: Int,
        _ reason: String,
        _ body: String,
        times: Int? = nil
    ) {
        self.method = method
        self.pathContains = pathContains
        self.status = status
        self.reason = reason
        self.body = body
        self.times = times
    }
}

final class ExplainingServer: @unchecked Sendable {
    let port: UInt16

    private let listenFD: Int32
    private let routes: [StubRoute]
    private let fallback: StubRoute
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?
    /// How many times each route has answered, so a `times`-limited route retires.
    private var used: [Int]
    /// See ``requests()``.
    private var requestLog: [(method: String, path: String, body: String)] = []

    /// Answer everything the same way.
    convenience init(status: Int, reason: String, body: String) throws {
        try self.init(routes: [], fallback: StubRoute("", "", status, reason, body))
    }

    /// Answer the first matching route, else the fallback. Matched in order, so
    /// a specific route is written before a general one.
    init(routes: [StubRoute], fallback: StubRoute) throws {
        self.routes = routes
        self.fallback = fallback
        self.used = Array(repeating: 0, count: routes.count)

        let fd = socket(AF_INET, explainingStreamSocketType, 0)
        guard fd >= 0 else { throw ExplainingServerError("socket() failed: \(errno)") }

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
            throw ExplainingServerError("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ExplainingServerError("listen() failed: \(errno)")
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
            throw ExplainingServerError("getsockname() failed: \(errno)")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func start() {
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "explaining-server"
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
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = drainRequest(fd) else { return }
        record(request)
        writeAll(fd, Self.encode(claimRoute(for: request.line)))
    }

    /// Every request this server has answered, in arrival order.
    ///
    /// The request LINE alone cannot prove which session a client targeted when
    /// the target travels in the body — `POST /session {"resume": …}` looks
    /// identical for every session — and an assertion that only reads the
    /// stub's own canned response id back is a test of the stub.
    func requests() -> [(method: String, path: String, body: String)] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    private func record(_ request: (line: String, body: String)) {
        let parts = request.line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        lock.lock()
        defer { lock.unlock() }
        requestLog.append((
            method: parts.count > 0 ? String(parts[0]) : "",
            path: parts.count > 1 ? String(parts[1]) : "",
            body: request.body
        ))
    }

    /// The route that answers this request line, consuming one of its `times`
    /// budget. Under the lock: the accept loop is one thread today, but the counter
    /// is the only mutable state here and a test that spawns a second is one line
    /// away.
    private func claimRoute(for requestLine: String) -> StubRoute {
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        lock.lock()
        defer { lock.unlock() }
        for (index, route) in routes.enumerated() {
            guard route.method == method, path.contains(route.pathContains) else { continue }
            if let times = route.times, used[index] >= times { continue }
            used[index] += 1
            return route
        }
        return fallback
    }

    /// The canned answer for one request line ("GET /sessions HTTP/1.1"), ignoring
    /// any `times` budget — the stateless form, for a caller with a fixed table.
    static func response(for requestLine: String, routes: [StubRoute], fallback: StubRoute) -> [UInt8] {
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        return encode(routes.first { $0.method == method && path.contains($0.pathContains) } ?? fallback)
    }

    /// One route as HTTP/1.1 response bytes.
    static func encode(_ route: StubRoute) -> [UInt8] {
        let bodyBytes = Array(route.body.utf8)
        let head = [
            "HTTP/1.1 \(route.status) \(route.reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(bodyBytes.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Array(head.utf8) + bodyBytes
    }

    /// Read one whole request — headers and, when `Content-Length` says so, the
    /// body — returning the request line and the body text.
    private func drainRequest(_ fd: Int32) -> (line: String, body: String)? {
        var buffer: [UInt8] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Int?
        var contentLength = 0
        while true {
            if headerEnd == nil, let end = Self.doubleCRLFEnd(buffer) {
                headerEnd = end
                contentLength = Self.contentLength(inHead: String(decoding: buffer[..<end], as: UTF8.self))
            }
            if let end = headerEnd, buffer.count >= end + contentLength {
                let head = String(decoding: buffer[..<end], as: UTF8.self)
                let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let body = String(decoding: buffer[end..<(end + contentLength)], as: UTF8.self)
                return (line, body)
            }
            let count = unsafe scratch.withUnsafeMutableBytes { raw in
                unsafe recv(fd, raw.baseAddress, raw.count, 0)
            }
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: scratch[..<count])
            if buffer.count > 1 << 20 { return nil }
        }
    }

    private static func contentLength(inHead head: String) -> Int {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
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

    /// The index just past the header terminator, or `nil` while incomplete.
    private static func doubleCRLFEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i + 4
        }
        return nil
    }
}
