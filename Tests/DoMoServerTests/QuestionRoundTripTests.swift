// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The server-side question bridge, exercised without a TUI: a tool-context
// handler asks the broker, the runtime parks the session and exposes the request
// over the level-triggered REST route, and the answer resumes the waiter.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct QuestionRoundTripTests {
    private static let token = "test-token-question"

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-question-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private struct QuestionReply: Codable {
        var requestID: String
        var answers: [ServerQuestionAnswer]?
    }

    private struct Reply {
        var status: UInt
        var body: Data
    }

    @Test("Structured questions park and resume through the REST routes")
    func roundTrip() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let broker = QuestionBroker()
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            questionBroker: broker
        ))
        let server = DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
        let (ports, portContinuation) = AsyncStream<Int>.makeStream()
        let serverTask = Task {
            try await server.run(onReady: { port in
                portContinuation.yield(port)
                portContinuation.finish()
            })
        }
        var portIterator = ports.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let created = try await send(http, port: port, method: .post, path: "/session")
        let sessionID = try JSONDecoder().decode(SessionRef.self, from: created.body).id
        let prompts = [ServerQuestionPrompt(
            header: "Storage",
            question: "Which format?",
            options: [ServerQuestionOption(label: "JSON"), ServerQuestionOption(label: "SQLite")]
        )]

        let waiting = Task { await broker.ask(sessionID: sessionID, questions: prompts) }
        let pending = try await waitForQuestion(runtime: runtime, sessionID: sessionID)
        #expect(pending.count == 1)
        guard case .questionRequest(let requestID, let pendingSession, let pendingPrompts) = pending[0] else {
            Issue.record("runtime did not expose a question_request")
            try await http.shutdown()
            serverTask.cancel()
            _ = try? await serverTask.value
            return
        }
        #expect(pendingSession == sessionID)
        #expect(pendingPrompts == prompts)

        let reconciled = try await send(http, port: port, method: .get, path: "/session/\(sessionID)/questions")
        #expect(reconciled.status == 200)
        #expect(try JSONDecoder().decode([ServerEvent].self, from: reconciled.body)
            == pending)

        let answer = [ServerQuestionAnswer(selectedLabels: ["SQLite"])]
        let encoded = try JSONEncoder().encode(QuestionReply(requestID: requestID, answers: answer))
        let resolved = try await send(
            http,
            port: port,
            method: .post,
            path: "/session/\(sessionID)/question",
            body: encoded
        )
        #expect(resolved.status == 200)
        #expect(await waiting.value == answer)
        #expect(try await runtime.pendingQuestions(sessionID: sessionID).isEmpty)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    private func waitForQuestion(
        runtime: ServerRuntime,
        sessionID: String
    ) async throws -> [ServerEvent] {
        for _ in 0..<100 {
            let pending = try await runtime.pendingQuestions(sessionID: sessionID)
            if !pending.isEmpty { return pending }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("question was not parked")
        return []
    }

    private enum Method { case get, post }

    private func send(
        _ http: HTTPClient,
        port: Int,
        method: Method,
        path: String,
        body: Data? = nil
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = method == .get ? .GET : .POST
        request.headers.add(name: "authorization", value: "Bearer \(Self.token)")
        if let body {
            request.headers.add(name: "content-type", value: "application/json")
            request.body = .bytes(Array(body))
        }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 4 << 20)
        return Reply(
            status: response.status.code,
            body: Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        )
    }
}
