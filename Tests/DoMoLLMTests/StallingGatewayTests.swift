// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// THE USER'S BUG, END TO END, AGAINST A REAL SOCKET.
//
// A raw TCP listener plays the part of a gateway that answers with a 200 and a
// couple of SSE chunks and then simply stops talking, holding the connection
// open. That is not a hypothetical: it is what a proxy or a wedged LiteLLM does,
// and it is the shape AsyncHTTPClient has no defence against — `execute(_:timeout:)`
// bounds only time-to-response-head, and the client's read timeout defaults to nil.
//
// `stalledBodyHangsWithoutTheGuard` proves the wedge exists (the drain does not
// finish, at all, while the socket sits open). `stalledBodyFailsWithTheGuard`
// proves `AsyncHTTPClientTransport` now bounds it. Both drive the real production
// transport over a real socket — no stubs.

import DoMoCore
import Foundation
import HTTPTypes
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

import DoMoLLM

/// `SOCK_STREAM` is an `Int32` on Darwin and an enum on Glibc; normalize it.
/// The same shim already exists in five other test files — `MockGateway.swift`
/// documents it — and this was the one socket that never got it, because the
/// Linux build has not compiled the test targets since 2026-07-25.
#if canImport(Glibc)
private let stallingStreamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let stallingStreamSocketType = SOCK_STREAM
#endif

/// A listener that writes an HTTP/1.1 head plus two SSE chunks and then goes
/// silent, keeping the connection open until it is torn down.
///
/// No `Content-Length` and no `Transfer-Encoding`, so the body is defined to run
/// until the connection closes — which it never does. Exactly the "still
/// connected, saying nothing" state that a read timeout exists to catch.
private final class StallingGateway: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var accepted: [Int32] = []

    init() throws {
        let (fd, port) = try Self.bindLoopback()
        listenFD = fd
        self.port = port

        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self, !self.isStopped else { close(client); return }
                self.lock.lock()
                self.accepted.append(client)
                self.lock.unlock()
                Thread.detachNewThread { Self.serve(client) }
            }
        }
    }

    /// Bind an ephemeral loopback port and start listening. Split out of `init`
    /// so the accept thread can capture a plain fd rather than a half-built self.
    private static func bindLoopback() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, stallingStreamSocketType, 0)
        guard fd >= 0 else { throw GatewayError.setup("socket") }

        var yes: Int32 = 1
        _ = unsafe withUnsafeBytes(of: &yes) {
            unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0.baseAddress, socklen_t($0.count))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // ephemeral
        address.sin_addr.s_addr = unsafe inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw GatewayError.setup("bind") }
        guard listen(fd, 8) == 0 else { close(fd); throw GatewayError.setup("listen") }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = unsafe withUnsafeMutablePointer(to: &actual) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                unsafe withUnsafeMutablePointer(to: &length) { unsafe getsockname(fd, rebound, $0) }
            }
        }
        guard named == 0 else { close(fd); throw GatewayError.setup("getsockname") }
        return (fd, Int(UInt16(bigEndian: actual.sin_port)))
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Read the request head, answer with a committed 200 and two frames, then
    /// hold the socket open and say nothing more.
    private static func serve(_ client: Int32) {
        var scratch = [UInt8](repeating: 0, count: 4096)
        _ = unsafe scratch.withUnsafeMutableBytes { unsafe read(client, $0.baseAddress, $0.count) }

        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-cache\r
            \r

            """
        let payload = Array(head.utf8)
            + Array("data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n".utf8)
            + Array("data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n".utf8)
        _ = unsafe payload.withUnsafeBytes { unsafe write(client, $0.baseAddress, $0.count) }
        // And now: nothing. No more bytes, no FIN, forever.
    }

    func shutDown() {
        lock.lock()
        stopped = true
        let clients = accepted
        accepted.removeAll()
        lock.unlock()
        for client in clients { close(client) }
        close(listenFD)
    }

    enum GatewayError: Error { case setup(String) }
}

@Suite("A gateway that sends a head and then stalls", .serialized)
struct StallingGatewayTests {

    private func request(port: Int) -> HTTPRequest {
        var request = HTTPRequest(
            method: .post,
            scheme: "http",
            authority: "127.0.0.1:\(port)",
            path: "/v1/chat/completions"
        )
        request.headerFields[.contentType] = "application/json"
        return request
    }

    /// THE BUG. With the idle window effectively disabled, draining the body of a
    /// stalled-but-open response makes no progress at all — not an error, not a
    /// completion, nothing. That is what held `harness.run` open forever and, with
    /// it, the session's only run slot.
    @Test("Without an idle bound, a stalled body never finishes and never fails")
    func stalledBodyHangsWithoutTheGuard() async throws {
        let gateway = try StallingGateway()
        defer { gateway.shutDown() }

        // A 60s idle window stands in for the pre-fix `nil` read timeout: far
        // longer than this test, so the drain has nothing to end it.
        let transport = AsyncHTTPClientTransport(connectTimeout: .seconds(5), idleTimeout: .seconds(60))
        let response = try await transport.execute(
            request: request(port: gateway.port),
            body: Array(#"{"model":"m","messages":[],"stream":true}"#.utf8),
            timeout: .seconds(600)
        )
        #expect(response.head.status.code == 200, "the head must commit — the hang happens AFTER it")

        // NOTE the shape: a flag, not `await drain.value`. Awaiting a task that
        // never returns is exactly the hang under test, and `Task.value` does not
        // abandon its await just because the awaiting task was cancelled.
        let settled = OneShotFlag()
        let drain = Task {
            do {
                for try await _ in response.body {}
            } catch {}
            settled.fire()
        }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!settled.isSet, "the stalled stream ended on its own — the wedge is not being reproduced")

        // And prove the escape hatch the transport documents still works over a
        // real socket: dropping the consumer must tear the request down promptly,
        // rather than leaving it pinned until the (here, 60s) idle window.
        drain.cancel()
        var waited = Duration.zero
        while !settled.isSet, waited < .seconds(5) {
            try await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        #expect(settled.isSet, "cancelling the consumer did not abort the stalled request")
    }

    /// THE FIX. Same gateway, same real transport, a sane idle window: the stream
    /// fails loudly and quickly, so the turn ends, the loop emits its close, the
    /// run slot frees, and the next prompt is accepted.
    @Test("With the idle bound, a stalled body fails fast with a retryable transport error")
    func stalledBodyFailsWithTheGuard() async throws {
        let gateway = try StallingGateway()
        defer { gateway.shutDown() }

        let transport = AsyncHTTPClientTransport(connectTimeout: .seconds(5), idleTimeout: .milliseconds(300))
        let response = try await transport.execute(
            request: request(port: gateway.port),
            body: Array(#"{"model":"m","messages":[],"stream":true}"#.utf8),
            timeout: .seconds(600)
        )
        #expect(response.head.status.code == 200)

        var delivered = 0
        let start = ContinuousClock.now
        var thrown: (any Error)?
        do {
            for try await _ in response.body { delivered += 1 }
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - start

        let error = try #require(thrown as? DoMoError, "the stalled body did not fail: \(String(describing: thrown))")
        #expect(error.kind == .transport)
        #expect(error.description.lowercased().contains("timed out"), "message was \(error.description)")
        #expect(delivered > 0, "the bytes the gateway DID send must reach the consumer")
        #expect(elapsed < .seconds(5), "took \(elapsed) — the idle window did not bound it")
    }
}

/// A `Sendable` one-shot flag, for observing a task that may never finish
/// without ever awaiting it.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func fire() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
