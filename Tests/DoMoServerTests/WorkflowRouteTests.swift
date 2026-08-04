// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct WorkflowRouteTests {
    private static let token = "workflow-route-token"

    @Test("workflow routes expose the durable definition and latest run snapshot")
    func workflowRoutes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-workflow-route-(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let workflowDirectory = root.appendingPathComponent("workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try WorkflowStore.create(directory: FilePath(workflowDirectory.path))
        try store.append(definition: .standard)
        let run = WorkflowRunRecord(
            id: "run-1",
            workflowID: WorkflowDefinition.standard.id,
            createdAt: "2026-08-04T00:00:00Z",
            stageIDs: WorkflowDefinition.standard.stages.map(\.id),
            status: .running
        )
        try store.append(run: run)

        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(sessions.path),
            cwd: cwd.path,
            workflowStore: store
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

        var definitionsRequest = HTTPClientRequest(url: "http://127.0.0.1:\(port)/workflows")
        definitionsRequest.method = .GET
        definitionsRequest.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let definitionsResponse = try await http.execute(definitionsRequest, timeout: .seconds(10))
        var definitionsBuffer = try await definitionsResponse.body.collect(upTo: 1 << 20)
        let definitionsData = Data(definitionsBuffer.readBytes(length: definitionsBuffer.readableBytes) ?? [])
        #expect(definitionsResponse.status.code == 200)
        #expect(try JSONDecoder().decode([WorkflowDefinition].self, from: definitionsData) == [.standard])

        var runsRequest = HTTPClientRequest(url: "http://127.0.0.1:\(port)/workflow/standard/runs")
        runsRequest.method = .GET
        runsRequest.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        let runsResponse = try await http.execute(runsRequest, timeout: .seconds(10))
        var runsBuffer = try await runsResponse.body.collect(upTo: 1 << 20)
        let runsData = Data(runsBuffer.readBytes(length: runsBuffer.readableBytes) ?? [])
        #expect(runsResponse.status.code == 200)
        #expect(try JSONDecoder().decode([WorkflowRunRecord].self, from: runsData) == [run])

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }
}
