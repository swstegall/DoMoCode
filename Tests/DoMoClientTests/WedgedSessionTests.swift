// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// "Occasionally the session will lose ability for your typed prompt to query
// against the model and then you have to make a new session."
//
// The client half. Every recovery path in this program used to be EDGE-triggered
// — `agent_end`, a `connected` frame, an explicit abort — and the wedge is by
// definition the state in which none of those edges will arrive. This file pins
// the level-triggered replacements: a store that can adopt the server's own view,
// a timestamp that a heartbeat advances, and a transport that declares a silent
// socket dead instead of waiting on it forever.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@testable import DoMoClient

// MARK: - The store's authoritative fold

@MainActor
@Suite("A client that missed an edge")
struct AdoptStatusTests {
    private func status(
        _ id: String = "s1",
        running: Bool,
        pending: [String] = []
    ) -> SessionStatus {
        SessionStatus(
            sessionID: id,
            running: running,
            pendingPermissionIDs: pending,
            subscribers: 1,
            runStartedAt: running ? "2026-07-28T00:00:00.000Z" : nil
        )
    }

    @Test("Adopting 'nothing is running' un-pins a run state nothing else can clear")
    func adoptUnpinsRunning() {
        // The whole bug in five lines: the client saw `agent_start`, never saw the
        // close, and `submit` then refuses every prompt for the life of the
        // session. There is no OTHER caller that can put this back.
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        #expect(store.runState == .running)

        store.adopt(status(running: false))
        #expect(store.runState == .idle)
        // A turn that is over cannot still have a tool call in flight; a spinner
        // that outlives its turn is the same lie in a different pane.
        if case .tool(_, _, _, let state, _) = store.transcript.last {
            #expect(state == .failed)
        } else {
            Issue.record("expected a tool row")
        }
    }

    @Test("A connected(running:true) after agent_end pins the client, and adopt un-pins it")
    func adoptClosesTheFinishRunWindow() {
        // The narrow, completely un-defended window: `startRun`'s task broadcasts
        // the terminal `agent_end` and only THEN hops to `finishRun`, so a
        // `connected` frame generated during that hop honestly reports
        // `running: true` AFTER the client already applied the end — and no
        // further frame is ever coming.
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.agentEnd(reason: "completed"))
        store.apply(.connected(protocolVersion: serverProtocolVersion, sessionID: "s1", running: true))
        #expect(store.runState == .running, "the frame is authoritative at the instant it is sent")

        store.adopt(status(running: false))
        #expect(store.runState == .idle)
    }

    @Test("Adopting 'running' revives a client that believes the session is idle")
    func adoptRevivesRunning() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentEnd(reason: "completed"))
        #expect(store.lastStopReason == "completed")

        store.adopt(status(running: true))
        #expect(store.runState == .running)
        // A stop reason from the previous turn must not caption the new one.
        #expect(store.lastStopReason == nil)
    }

    @Test("A snapshot for another session is ignored")
    func adoptIgnoresOtherSessions() {
        // A poll in flight across a session switch must not decide the NEW
        // session's state from the OLD session's answer.
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.adopt(status("s2", running: false))
        #expect(store.runState == .running)
    }

    @Test("Adopting drops a prompt the server no longer has parked, and cannot resurrect it")
    func adoptDropsAStaleModal() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.permissionRequest(
            id: "per_1", sessionID: "s1", permission: "bash",
            patterns: ["*"], always: [], metadata: [:], disableAlways: false
        ))
        #expect(store.pendingPermission?.id == "per_1")

        // The `permission_resolved` echo was the frame that got lost: the run moved
        // on and the client is holding a question nobody wants an answer to.
        store.adopt(status(running: true, pending: []))
        #expect(store.pendingPermission == nil)

        // And a replay of the same ask cannot bring it back.
        store.apply(.permissionRequest(
            id: "per_1", sessionID: "s1", permission: "bash",
            patterns: ["*"], always: [], metadata: [:], disableAlways: false
        ))
        #expect(store.pendingPermission == nil)
    }

    @Test("A prompt the server still has parked is left alone")
    func adoptKeepsALivePrompt() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.permissionRequest(
            id: "per_1", sessionID: "s1", permission: "bash",
            patterns: ["*"], always: [], metadata: [:], disableAlways: false
        ))
        store.adopt(status(running: true, pending: ["per_1"]))
        #expect(store.pendingPermission?.id == "per_1")
    }

    @Test("hasUnseenPermission is true only for an ask the store has neither parked nor answered")
    func unseenPermission() {
        let store = EventStore()
        store.select("s1")
        #expect(store.hasUnseenPermission(in: ["per_1"]))
        #expect(!store.hasUnseenPermission(in: []))

        store.apply(.permissionRequest(
            id: "per_1", sessionID: "s1", permission: "bash",
            patterns: ["*"], always: [], metadata: [:], disableAlways: false
        ))
        // Already on screen: asking again would re-present what is already up.
        #expect(!store.hasUnseenPermission(in: ["per_1"]))

        store.apply(.permissionResolved(id: "per_1"))
        #expect(!store.hasUnseenPermission(in: ["per_1"]), "answered ids never come back")
        #expect(store.hasUnseenPermission(in: ["per_1", "per_2"]))
    }
}

// MARK: - The silence timestamp

@MainActor
@Suite("The heartbeat the store used to throw away")
struct LastEventTests {
    @Test("A heartbeat advances lastEventAt")
    func heartbeatAdvances() async {
        // `.heartbeat` early-`return`s from `apply` before any transcript work —
        // it is the one frame with no content — so the stamp has to be taken ABOVE
        // the switch. The entire silence watchdog is built on this: heartbeats are
        // the ONLY traffic on an idle-but-live stream, so a stamp that skipped them
        // would report a healthy session as dead every fifteen seconds.
        let store = EventStore()
        store.select("s1")
        let before = store.lastEventAt
        try? await Task.sleep(for: .milliseconds(30))
        store.apply(.heartbeat)
        #expect(store.lastEventAt > before)
    }

    @Test("Every other frame advances it too")
    func ordinaryFramesAdvance() async {
        let store = EventStore()
        store.select("s1")
        let before = store.lastEventAt
        try? await Task.sleep(for: .milliseconds(30))
        store.apply(.messageDelta(text: "hello", reasoning: nil))
        #expect(store.lastEventAt > before)
    }

    @Test("A successful poll does NOT advance it — the stream's health is its own fact")
    func adoptDoesNotAdvance() async {
        // Deliberate, and load-bearing. `/status` answering proves the SERVER is
        // reachable; it says nothing about the stream, and folding the two together
        // would hide exactly the half-open socket the stamp exists to expose — the
        // poll would keep the timestamp fresh forever while no frame ever arrived.
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        let stamped = store.lastEventAt
        try? await Task.sleep(for: .milliseconds(30))
        store.adopt(SessionStatus(
            sessionID: "s1", running: true, pendingPermissionIDs: [],
            subscribers: 1, runStartedAt: nil
        ))
        #expect(store.lastEventAt == stamped)
    }

    @Test("Opening a different session starts its silence clock fresh")
    func switchingResets() async {
        let store = EventStore()
        store.select("s1")
        store.apply(.heartbeat)
        let first = store.lastEventAt
        try? await Task.sleep(for: .milliseconds(30))
        store.select("s2")
        #expect(store.lastEventAt > first, "a new session must not inherit the old one's silence")
    }
}

// MARK: - The transport

/// A time limit, because the failure mode under test is a HANG. Without the
/// watchdogs these tests do not fail, they never return — which is the bug, and
/// which a suite with no deadline would report as an infinite build.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WedgeTransportTests {
    static let token = "wedge-transport-token"

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-wedge-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A runtime whose turn never finishes and never observes cancellation — the
    /// wedge, in one closure.
    private static func parkingStreamFn(_ entered: @escaping @Sendable () -> Void) -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                entered()
                // Never finishes. `onTermination` is not set, so nothing here
                // observes the consumer going away either.
            }
        }
    }

    private func makeServer(
        _ dirs: Dirs,
        streamFn: @escaping AgentStreamFn,
        heartbeatSeconds: Int = 3600
    ) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: heartbeatSeconds)
        )
    }

    private func start(_ server: DoMoServer) async -> (Task<Void, any Error>, Int) {
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let task = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var iterator = ports.makeAsyncIterator()
        return (task, await iterator.next() ?? 0)
    }

    @Test("status and force-clear round-trip, and force-clear frees a run that can never settle")
    func statusAndForceClearRoundTrip() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let entered = AsyncStream<Void>.makeStream()
        let server = makeServer(dirs, streamFn: Self.parkingStreamFn { entered.continuation.yield(()) })
        let (serverTask, port) = await start(server)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)

        let ref = try await client.createSession()
        let idle = try await client.status(sessionID: ref.id)
        #expect(idle.running == false)
        #expect(idle.runStartedAt == nil)
        #expect(idle.pendingPermissionIDs.isEmpty)

        try await client.sendPrompt(sessionID: ref.id, prompt: "park forever")
        var enteredIterator = entered.stream.makeAsyncIterator()
        _ = await enteredIterator.next()

        let busy = try await client.status(sessionID: ref.id)
        #expect(busy.running == true)
        #expect(busy.runStartedAt != nil, "so a client can say 'running for 14m' instead of spinning")

        // The refusal the user actually reports: every later prompt 409s.
        do {
            try await client.sendPrompt(sessionID: ref.id, prompt: "and now?")
            Issue.record("expected the runtime to refuse a second turn")
        } catch let ServerClientError.unexpectedStatus(status, _, _) {
            #expect(status == 409)
        }

        #expect(try await client.forceClearRun(sessionID: ref.id) == true)
        #expect(try await client.status(sessionID: ref.id).running == false)
        // And the session works again — which is the entire point of the lever.
        try await client.sendPrompt(sessionID: ref.id, prompt: "after the clear")

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("Force-clearing a session that was not held answers 'nothing was held'")
    func forceClearIdempotent() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, streamFn: { _ in AsyncThrowingStream { $0.finish() } })
        let (serverTask, port) = await start(server)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)

        let ref = try await client.createSession()
        #expect(try await client.forceClearRun(sessionID: ref.id) == false)

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("status and force-clear on an unknown session carry the 404 and the path")
    func unknownSession() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, streamFn: { _ in AsyncThrowingStream { $0.finish() } })
        let (serverTask, port) = await start(server)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http)

        do {
            _ = try await client.status(sessionID: "nope")
            Issue.record("expected a 404")
        } catch let ServerClientError.unexpectedStatus(status, path, _) {
            #expect(status == 404)
            #expect(path == "/session/nope/status")
        }
        do {
            _ = try await client.forceClearRun(sessionID: "nope")
            Issue.record("expected a 404")
        } catch let ServerClientError.unexpectedStatus(status, path, _) {
            #expect(status == 404)
            #expect(path == "/session/nope/force-clear")
        }

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A stream that goes silent fails instead of hanging forever")
    func silentStreamFails() async throws {
        // The half-open socket, staged honestly: a real server with its heartbeat
        // turned off delivers `connected` and then NOTHING, exactly as a dead
        // connection does. Without the watchdog this loop never returns and the
        // test times out — which is the bug.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, streamFn: { _ in AsyncThrowingStream { $0.finish() } }, heartbeatSeconds: 3600)
        let (serverTask, port) = await start(server)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(
            baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http,
            streamIdleTimeout: .milliseconds(400)
        )
        let ref = try await client.createSession()

        var thrown: (any Error)?
        do {
            for try await _ in client.events(sessionID: ref.id) {}
            Issue.record("the stream ended cleanly; it should have failed on silence")
        } catch {
            thrown = error
        }
        #expect(thrown as? ServerClientError == .streamIdle(path: "/session/\(ref.id)/events"))

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A stream that keeps heartbeating is never cut off")
    func heartbeatsKeepTheStreamAlive() async throws {
        // The false-positive guard. A heartbeat carries nothing and used to be
        // discarded on arrival; if the watchdog did not count it as traffic, every
        // idle session would be declared dead on a fixed schedule.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, streamFn: { _ in AsyncThrowingStream { $0.finish() } }, heartbeatSeconds: 1)
        let (serverTask, port) = await start(server)
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(
            baseURL: "http://127.0.0.1:\(port)", token: Self.token, http: http,
            streamIdleTimeout: .milliseconds(2500)
        )
        let ref = try await client.createSession()

        var heartbeats = 0
        var failure: (any Error)?
        do {
            for try await event in client.events(sessionID: ref.id) {
                if case .heartbeat = event {
                    heartbeats += 1
                    if heartbeats >= 4 { break }
                }
            }
        } catch {
            failure = error
        }
        #expect(heartbeats >= 4, "expected the stream to survive past its idle budget")
        #expect(failure == nil, "a heartbeating stream must never trip the watchdog: \(String(describing: failure))")

        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    @Test("A REST call whose body never arrives fails with timedOut instead of hanging")
    func restBodyDeadline() async throws {
        // `execute(_:timeout:)`'s deadline is cancelled the instant the response
        // HEAD lands, and the client carries no read timeout — so the collect that
        // follows is unbounded. A stub that writes the head and then keeps the
        // socket open forever reproduces it exactly.
        let stall = try StallingBodyServer()
        stall.start()
        defer { stall.stop() }
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let client = ServerClient(
            baseURL: stall.baseURL, token: "unused", http: http,
            requestTimeout: .milliseconds(400)
        )

        var thrown: (any Error)?
        do {
            _ = try await client.listSessions()
            Issue.record("expected the unfinished body to time out")
        } catch {
            thrown = error
        }
        #expect(thrown as? ServerClientError == .timedOut(path: "/sessions"))

        try await http.shutdown()
    }

    @Test("A caller-supplied timeout that would overflow NIO's nanoseconds clamps instead of trapping")
    func nanosecondsSaturate() {
        #expect(ServerClient.nanoseconds(.seconds(30)) == 30_000_000_000)
        #expect(ServerClient.nanoseconds(.milliseconds(1)) == 1_000_000)
        #expect(ServerClient.nanoseconds(.seconds(Int64.max)) == Int64.max)
        #expect(ServerClient.nanoseconds(.seconds(-Int64.max)) == Int64.min)
    }
}
