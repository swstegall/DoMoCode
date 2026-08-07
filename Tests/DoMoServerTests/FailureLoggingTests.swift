import AsyncHTTPClient
import DoMoCore
import DoMoServer
import Foundation
import Logging
import SystemPackage
import Testing

/// Pins ``FailureLoggingMiddleware``: a request that fails must leave a log
/// line, and the middleware must sit OUTSIDE the token gate so a 401 is seen
/// too. Both mutations this guards against — swapping the two `router.add`
/// lines, or deleting the registration — silently recreate the condition where
/// weeks of failing requests produced not one diagnosable line anywhere.
@Suite("Failure logging", .serialized)
struct FailureLoggingTests {
    private static let token = "failure-logging-token"

    private final class LogRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }
        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private struct RecordingLogHandler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) {
            recorder.add("\(event.level) \(event.message)")
        }
    }

    @Test("a 401 and a message-carrying 400 each leave a log line")
    func failuresAreLogged() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-failure-logging-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = LogRecorder()
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            sessionClients: SessionClientManager(now: { "2026-01-01T00:00:00Z" })
        ))
        let server = DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600),
            logger: Logger(label: "test") { _ in RecordingLogHandler(recorder: recorder) }
        )
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let serverTask = Task {
            try await server.run(onReady: { port in
                continuation.yield(port)
                continuation.finish()
            })
        }
        var iterator = ports.makeAsyncIterator()
        let port = try #require(await iterator.next())
        let http = HTTPClient(eventLoopGroupProvider: .singleton)

        // A wrong bearer token: thrown by TokenAuthMiddleware, so it reaches
        // the log only because the failure logger is registered OUTSIDE it.
        var unauthorized = HTTPClientRequest(url: "http://127.0.0.1:\(port)/sessions")
        unauthorized.headers.add(name: "authorization", value: "Bearer wrong")
        let refused = try await http.execute(unauthorized, timeout: .seconds(30))
        #expect(refused.status.code == 401)

        // A ledger refusal: the mapped 400 whose message must appear in the
        // log exactly as it appears on the wire.
        var createRequest = HTTPClientRequest(url: "http://127.0.0.1:\(port)/session")
        createRequest.method = .POST
        createRequest.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let created = try await http.execute(createRequest, timeout: .seconds(30))
        let createBuffer = try await created.body.collect(upTo: 1 << 20)
        let sessionID = try JSONDecoder()
            .decode(SessionRef.self, from: Data(createBuffer.readableBytesView)).id

        var attach = HTTPClientRequest(url: "http://127.0.0.1:\(port)/session/\(sessionID)/client/attach")
        attach.method = .POST
        attach.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        attach.headers.add(name: "content-type", value: "application/json")
        attach.body = .bytes(Array(#"{"clientID":"","owner":"","requestAuthority":true}"#.utf8))
        let rejected = try await http.execute(attach, timeout: .seconds(30))
        #expect(rejected.status.code == 400)

        let lines = recorder.snapshot()
        #expect(lines.contains { $0.contains("401") && $0.contains("/sessions") }, "log: \(lines)")
        #expect(
            lines.contains { $0.contains("400") && $0.contains("must not be empty") },
            "log: \(lines)"
        )

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }
}
