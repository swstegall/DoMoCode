// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Shared fixtures for the OAuth suites: a router-driven loopback HTTP server
// (Hummingbird on port 0, the same machinery the production listener uses,
// so the tests exercise real sockets per this target's convention), and a
// port allocator for the one place a port must be known before it can be
// bound — the redirect URI inside an authorize URL.

import Foundation
import Hummingbird
import Logging
import NIOCore
import Synchronization
import Testing

/// A loopback Hummingbird server for stub IdP / stub MCP endpoints. Started
/// on port 0; `stop()` cancels the service. Every suite that owns one is
/// `.serialized`, per the target's socket rules.
final class TestHTTPServer: Sendable {
    let port: Int
    private let task: Task<Void, any Error>

    var baseURL: String { "http://127.0.0.1:\(port)" }

    private init(port: Int, task: Task<Void, any Error>) {
        self.port = port
        self.task = task
    }

    static func start(router: Router<BasicRequestContext>) async throws -> TestHTTPServer {
        let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
        let application = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                continuation.yield(channel.localAddress?.port ?? 0)
            },
            logger: Logger(label: "domocode.test.oauth") { _ in SwiftLogNoOpLogHandler() }
        )
        let task = Task { try await application.runService() }
        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next(), port != 0 else {
            task.cancel()
            throw TestServerError.neverBound
        }
        return TestHTTPServer(port: port, task: task)
    }

    func stop() {
        task.cancel()
    }

    enum TestServerError: Error {
        case neverBound
    }
}

/// A loopback port that was just now bindable. Bind-on-zero, note, release:
/// the tiny reuse race is accepted (and CI-tolerated) because the alternative
/// — a fixed test port — collides with parallel case execution by design.
func allocateLoopbackPort() async throws -> Int {
    let router = Router(context: BasicRequestContext.self)
    let server = try await TestHTTPServer.start(router: router)
    let port = server.port
    server.stop()
    // Give the cancellation a moment to release the bind before the caller
    // reuses the port.
    try await Task.sleep(for: .milliseconds(100))
    return port
}

/// Mutex-guarded append-only recording, the fixture convention for shared
/// mutable state across `@Sendable` route closures.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] {
        storage.withLock { $0 }
    }

    var count: Int {
        storage.withLock { $0.count }
    }
}

/// A single settable box for cross-closure handoff (the authorize URL's
/// challenge reaching the token route, and the like).
final class ValueBox<Value: Sendable>: Sendable {
    private let storage = Mutex<Value?>(nil)

    func set(_ value: Value) {
        storage.withLock { $0 = value }
    }

    var value: Value? {
        storage.withLock { $0 }
    }
}

/// A one-shot release gate: a route awaits `wait()`, the test opens it with
/// `open()`. Lets a stub hold a response open until the test has arranged the
/// concurrency it wants to observe, removing timing flakiness.
final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func open() {
        continuation.finish()
    }

    func wait() async {
        for await _ in stream {}
    }
}

/// Splits an `application/x-www-form-urlencoded` body into a dictionary,
/// decoding percent escapes the way the token endpoint would.
func parseForm(_ body: String) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let value = String(parts[1]).replacingOccurrences(of: "+", with: " ")
        fields[key] = value.removingPercentEncoding ?? value
    }
    return fields
}

/// A JSON `Response` for stub routes.
func jsonResponse(_ status: HTTPResponse.Status, _ object: [String: Any]) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}
