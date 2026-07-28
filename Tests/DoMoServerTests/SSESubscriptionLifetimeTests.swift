// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `sink.subscribe()` used to run when the SSE Response was CONSTRUCTED, while the
// `defer { sink.unsubscribe(...) }` that undoes it lives inside the
// `ResponseBody { writer in ... }` closure. Any response whose writer is never
// invoked therefore leaked a registration and a 512-slot buffer for the life of
// the process — and poisoned `subscriberCount`, which is the natural diagnostic
// for exactly the class of bug this whole area is about.
//
// `@testable` reaches `eventStream` directly, because "build the response and
// never drive it" is the precise condition and there is no way to stage it
// reliably over a socket.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation
import SystemPackage
import Testing

@testable import DoMoServer

@Suite(.serialized)
struct SSESubscriptionLifetimeTests {

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-sse-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeServer(_ dirs: Dirs) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(runtime: runtime, options: .init(host: "127.0.0.1", port: 0, token: "t", heartbeatSeconds: 3600))
    }

    @Test("An SSE response whose body is never written leaves no subscriber behind")
    func unwrittenEventStreamDoesNotLeak() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs)
        let session = try await server.runtime.createSession()
        let sink = try await server.runtime.sink(for: session.id)

        #expect(sink.subscriberCount == 0)

        // Build the response — and never drive its writer, which is what happens
        // when the connection dies between routing and body streaming.
        let response = server.eventStream(sessionID: session.id, sink: sink)
        #expect(
            sink.subscriberCount == 0,
            "constructing the SSE response registered a subscriber that nothing will ever unregister"
        )

        // Ten of them, to make the leak unmistakable if it ever comes back.
        var responses = [response]
        for _ in 0..<9 { responses.append(server.eventStream(sessionID: session.id, sink: sink)) }
        #expect(sink.subscriberCount == 0, "\(sink.subscriberCount) subscribers leaked from 10 undriven responses")

        withExtendedLifetime(responses) {}
    }

    @Test("Subscriber accounting stays honest across subscribe and unsubscribe")
    func subscriberCountIsAccurate() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs)
        let session = try await server.runtime.createSession()
        let sink = try await server.runtime.sink(for: session.id)

        let first = sink.subscribe()
        let second = sink.subscribe()
        #expect(sink.subscriberCount == 2)
        #expect(try await server.runtime.status(sessionID: session.id).subscribers == 2,
                "status must project the real subscriber count — it is the diagnostic")

        sink.unsubscribe(first.id)
        #expect(sink.subscriberCount == 1)
        sink.unsubscribe(second.id)
        #expect(sink.subscriberCount == 0)
        // Unsubscribing twice is a no-op, not a crash or a negative count.
        sink.unsubscribe(second.id)
        #expect(sink.subscriberCount == 0)
        #expect(try await server.runtime.status(sessionID: session.id).subscribers == 0)
    }
}
