// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The transport, proven against a REAL in-process DoMoServer on a loopback
// ephemeral port — the same shape the CLI spawns. The LLM is a scripted stream
// function (one assistant turn), so no gateway is needed; everything else —
// routing, the runtime, persistence, the SSE hub, token auth — is the real thing
// reached through ServerClient's public API.

import AsyncHTTPClient
import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoGit
import DoMoHarness
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct ServerClientIntegrationTests {
    static let token = "client-test-token-xyz"

    private actor SnapshotScript: WorkspaceSnapshotSource {
        private let snapshots: [WorkspaceSnapshot]
        private var index = 0

        init(_ snapshots: [WorkspaceSnapshot]) {
            self.snapshots = snapshots
        }

        func availability() async -> WorkspaceSnapshotStatus { .restored }

        func track(from previousID: String?) async throws(DoMoError) -> WorkspaceSnapshot {
            guard !snapshots.isEmpty else {
                throw DoMoError(.configuration, "snapshot script is empty")
            }
            let snapshot = snapshots[min(index, snapshots.count - 1)]
            index += 1
            return WorkspaceSnapshot(id: snapshot.id, previousID: previousID, files: snapshot.files)
        }

        func restore(_ plan: WorkspaceRevertPlan) async throws(DoMoError) -> WorkspaceRestoreResult {
            WorkspaceRestoreResult(status: .restored, restoredPaths: plan.paths)
        }
    }

    /// One assistant turn producing `text`, then stop.
    static func streamFn(_ text: String) -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(content: [.text(text)], model: "test-model", stopReason: .stop)))
                continuation.finish()
            }
        }
    }

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-client-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeServer(_ dirs: Dirs, answer: String) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: Self.streamFn(answer),
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    @Test("Create, list, stream a turn, read history, and fork through ServerClient")
    func fullFlow() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, answer: "hi there")

        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)

        // Create a session and see it in the listing.
        let ref = try await client.createSession()
        let sessions = try await client.listSessions()
        #expect(sessions.contains { $0.id == ref.id })

        // Subscribe, post the prompt once connected, read until the turn ends.
        var events: [ServerEvent] = []
        var posted = false
        for try await event in client.events(sessionID: ref.id) {
            events.append(event)
            if case .connected(let version, let sessionID, _) = event {
                #expect(version == serverProtocolVersion)
                #expect(sessionID == ref.id)
                if !posted {
                    posted = true
                    try await client.sendPrompt(sessionID: ref.id, prompt: "hello")
                }
            }
            if case .agentEnd = event { break }
        }

        #expect(events.contains { if case .agentStart = $0 { true } else { false } })
        #expect(events.contains {
            if case .agentEnd(let reason) = $0 { reason == "completed" } else { false }
        })
        // The assistant text arrived, via message_end (authoritative) at least.
        let finalText: String? = events.compactMap {
            if case .messageEnd(let message) = $0, case .assistant(let a) = message { a.text } else { nil }
        }.last
        #expect(finalText == "hi there")

        // History reads back the user prompt and the assistant answer.
        let history = try await client.messages(sessionID: ref.id)
        #expect(history.contains { if case .user(let user) = $0 { user.text == "hello" } else { false } })
        #expect(history.contains { if case .assistant(let a) = $0 { a.text == "hi there" } else { false } })

        // Fork yields a new id.
        let forked = try await client.fork(sessionID: ref.id)
        #expect(forked.id != ref.id)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("workspace status, timeline, undo, redo, and clone round-trip through ServerClient")
    func workspaceHistoryFlow() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }

        var configuration = ServerRuntime.Config(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: Self.streamFn("answer"),
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        )
        configuration.workspaceSnapshotsForSession = { _ in
            SnapshotScript([
                WorkspaceSnapshot(id: "base", files: []),
                WorkspaceSnapshot(id: "one", files: ["Sources/One.swift"]),
                WorkspaceSnapshot(id: "two", files: ["Sources/One.swift", "Sources/Two.swift"]),
            ])
        }
        let server = DoMoServer(
            runtime: ServerRuntime(config: configuration),
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )

        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)
        let ref = try await client.createSession()

        #expect(try await client.workspaceStatus(sessionID: ref.id) == .restored)
        try await client.sendPrompt(sessionID: ref.id, prompt: "first")
        #expect(await waitUntilIdle(client, ref.id))
        try await client.sendPrompt(sessionID: ref.id, prompt: "second")
        #expect(await waitUntilIdle(client, ref.id))

        let timeline = try await client.timeline(sessionID: ref.id)
        #expect(timeline.contains { if case .workspaceCheckpoint = $0.payload { true } else { false } })
        #expect(timeline.count >= 3)

        let undo = try await client.undo(sessionID: ref.id)
        #expect(undo.moved)
        #expect(undo.status == .restored)
        #expect((try await client.context(sessionID: ref.id)).messages.count == 2)

        let redo = try await client.redo(sessionID: ref.id)
        #expect(redo.moved)
        #expect(redo.status == .restored)
        #expect((try await client.context(sessionID: ref.id)).messages.count == 4)

        let cloned = try await client.clone(sessionID: ref.id)
        #expect(cloned.id != ref.id)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("Context inspection and explicit compaction round-trip through the client")
    func contextAndCompactionRoundTrip() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }

        let stream: AgentStreamFn = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(
                    content: [.text("answer")],
                    model: "test-model",
                    usage: Usage(input: 40),
                    stopReason: .stop
                )))
                continuation.finish()
            }
        }
        let server = DoMoServer(
            runtime: ServerRuntime(config: .init(
                systemPrompt: "You are a test.",
                tools: [],
                model: "test-model",
                streamFn: stream,
                toolExecution: .sequential,
                maxTurns: 10,
                sessionDirectory: FilePath(dirs.sessions.path),
                cwd: dirs.cwd.path,
                compaction: CompactionSettings(enabled: false, reserveTokens: 100, keepRecentTokens: 100),
                summarizer: { _ in SummarizerResult(text: "SERVER SUMMARY") }
            )),
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )

        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)
        let ref = try await client.createSession()
        let commands = try await client.commands()
        #expect(commands.command(named: "compact")?.action == .compact)
        #expect(commands.command(named: "context")?.action == .context)

        let prompt = String(repeating: "context ", count: 100)
        try await client.sendPrompt(sessionID: ref.id, prompt: prompt + "one")
        #expect(await waitUntilIdle(client, ref.id))
        try await client.sendPrompt(sessionID: ref.id, prompt: prompt + "two")
        #expect(await waitUntilIdle(client, ref.id))

        let before = try await client.context(sessionID: ref.id)
        #expect(before.messages.count == 4, "context before compaction was (before.messages.count) messages")

        #expect(try await client.compact(sessionID: ref.id))
        let after = try await client.context(sessionID: ref.id)
        guard case .user(let summary) = after.messages.first else {
            Issue.record("context endpoint did not expose the compaction summary")
            try await http.shutdown()
            serverTask.cancel()
            _ = try? await serverTask.value
            return
        }
        #expect(summary.text.contains("SERVER SUMMARY"))
        #expect(after.accounting != nil)
        #expect(!(try await client.compact(sessionID: ref.id)))

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A session from a previous launch is dead until resumed — and resuming revives it")
    func sessionFromAPreviousLaunchMustBeResumed() async throws {
        // The regression this pins: the sidebar lists sessions from DISK, but the
        // runtime only knows the ones IT created. Every session from an earlier launch
        // was therefore inert — /events, /prompt and /abort all 404 — and because
        // bootstrap opens the most recent session, the second and every later launch
        // of `domo` came up attached to a session where nothing worked and nothing
        // said so. It looked exactly like a hang.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }

        // Launch 1: create a session, then tear the server down.
        let first = makeServer(dirs, answer: "from launch one")
        let (firstPorts, firstCont) = AsyncStream<Int>.makeStream()
        let firstTask = Task { try await first.run(onReady: { firstCont.yield($0); firstCont.finish() }) }
        var firstIterator = firstPorts.makeAsyncIterator()
        let firstPort = await firstIterator.next() ?? 0
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let sessionID = try await ServerClient(
            baseURL: "http://127.0.0.1:\(firstPort)", token: Self.token, http: http
        ).createSession().id
        firstTask.cancel()
        _ = try? await firstTask.value

        // Launch 2: a fresh runtime over the same session directory. The session is on
        // disk and listed, but the runtime has never heard of it.
        let second = makeServer(dirs, answer: "from launch two")
        let (secondPorts, secondCont) = AsyncStream<Int>.makeStream()
        let secondTask = Task { try await second.run(onReady: { secondCont.yield($0); secondCont.finish() }) }
        var secondIterator = secondPorts.makeAsyncIterator()
        let secondPort = await secondIterator.next() ?? 0
        let client = ServerClient(baseURL: "http://127.0.0.1:\(secondPort)", token: Self.token, http: http)

        #expect(try await client.listSessions().contains { $0.id == sessionID }, "listed from disk")

        // Before resuming, the live endpoints reject it.
        do {
            try await client.sendPrompt(sessionID: sessionID, prompt: "does this reach the agent?")
            Issue.record("expected an un-resumed session to be unknown to the runtime")
        } catch let ServerClientError.unexpectedStatus(status, _, _) {
            #expect(status == 404)
        }

        // Resuming makes it live, and it is idempotent (the client calls it on every
        // open, including for a session it just created).
        let resumed = try await client.createSession(resume: sessionID)
        #expect(resumed.id == sessionID)
        #expect(try await client.createSession(resume: sessionID).id == sessionID)

        // Now the whole live surface works: subscribe, prompt, and receive the turn.
        var sawEnd = false
        var posted = false
        for try await event in client.events(sessionID: sessionID) {
            if case .connected = event, !posted {
                posted = true
                try await client.sendPrompt(sessionID: sessionID, prompt: "hello again")
            }
            if case .agentEnd = event { sawEnd = true; break }
        }
        #expect(sawEnd)

        try await http.shutdown()
        secondTask.cancel()
        _ = try? await secondTask.value
    }

    @Test("A wrong bearer token is rejected with 401")
    func unauthorized() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, answer: "unused")
        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let badClient = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: "wrong-token", http: http)
        do {
            _ = try await badClient.listSessions()
            Issue.record("expected an unauthorized error")
        } catch let ServerClientError.unexpectedStatus(status, _, _) {
            #expect(status == 401)
        }

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    private func waitUntilIdle(_ client: ServerClient, _ sessionID: String) async -> Bool {
        var waited = Duration.zero
        while waited < .seconds(10) {
            if let status = try? await client.status(sessionID: sessionID), !status.running {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        return false
    }
}
