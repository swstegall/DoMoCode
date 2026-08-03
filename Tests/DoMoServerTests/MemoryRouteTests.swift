// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoMemory
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct MemoryRouteTests {
    private static let token = "memory-route-token"

    private struct Provider: ProjectMemoryProvider {
        let records: [ProjectMemoryRecord]

        func list() async throws -> [ProjectMemoryRecord] { records }

        func remember(
            kind: ProjectMemoryKind,
            title: String,
            content: String,
            sourceSessionID: String?,
            tags: [String],
            id: String?
        ) async throws -> ProjectMemoryRecord {
            ProjectMemoryRecord(
                id: id ?? "new",
                kind: kind,
                title: title,
                content: content,
                createdAt: "now",
                updatedAt: "now",
                sourceSessionID: sourceSessionID,
                tags: tags
            )
        }

        func forget(id _: String) async throws -> Bool { false }
    }

    @Test("GET /memory returns typed project memory through the authenticated server")
    func memoryRoute() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-memory-route-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expected = ProjectMemoryRecord(
            id: "decision-1",
            kind: .project,
            title: "storage",
            content: "Use the bounded project memory store.",
            createdAt: "2026-08-03T00:00:00Z",
            updatedAt: "2026-08-03T00:00:00Z",
            tags: ["decision"]
        )
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            maxTurns: 1,
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            projectMemoryProvider: Provider(records: [expected])
        ))
        let server = DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
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

        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)/memory")
        request.method = .GET
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let response = try await http.execute(request, timeout: .seconds(10))
        var buffer = try await response.body.collect(upTo: 1 << 20)
        let body = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])

        #expect(response.status.code == 200)
        #expect(try JSONDecoder().decode([ProjectMemoryRecord].self, from: body) == [expected])

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }
}
