// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Every place the client can refuse, lose or stall a user's action, proven on the
// SCREEN of the real client.
//
// A verifier found that eleven of these behaviours could be DELETED with the full
// suite still green: the status line's reason for a disconnect, the escalation
// from a status line to a persistent row, and nine of the eleven swallow sites
// that had been "fixed". Each was written and none was watched. The reason is
// mechanical — most of them produce a four-second status-line notice, and the
// existing end-to-end harness asserts on the FINAL screen, by which time every
// transient message has lapsed. `WedgeClientDriver` polls instead, so a message
// is proven by having been shown, which is the property a transient message has.
//
// Each test here fails if its behaviour is removed. That is the bar: a row nobody
// asserts is a row that will be deleted by the next refactor and missed by nobody
// until a user hits it.

import AsyncHTTPClient
import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WedgeSurfaceTests {
    static let token = "wedge-surface-token"

    // MARK: Canned bodies

    private static let sessionRef = #"{"id":"abc123","path":"/tmp/abc123.jsonl"}"#
    private static let sessionList =
        #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/work","timestamp":"2026-01-01"}]"#

    /// SSE frames, encoded by the SAME `Codable` the server uses — a hand-written
    /// JSON literal here would be a second, drifting copy of the wire format.
    private static func sse(_ events: [ServerEvent]) -> String {
        let encoder = JSONEncoder()
        return events.map { event in
            let json = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "data: \(json)\n\n"
        }.joined()
    }

    private static let connectedIdle = sse([
        .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: false)
    ])

    /// The routes a client needs to come up healthy, with `extra` spliced in
    /// FIRST so a test can make one endpoint misbehave.
    ///
    /// Order is significant: `POST /session` matches every POST path this client
    /// makes, so anything more specific has to be written above it.
    private static func runtime(_ extra: [StubRoute] = []) throws -> ExplainingServer {
        try ExplainingServer(
            routes: extra + [
                StubRoute("GET", "/sessions", 200, "OK", sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", connectedIdle),
                StubRoute("POST", "/session", 201, "Created", sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
    }

    // MARK: Bootstrap

    @Test("A create that fails at startup says so, and says it retried")
    func createFailureIsReported() async throws {
        // A `guard … else { return }` used to leave the app with NO session: no
        // transcript, no target for a prompt, no explanation, and — because
        // bootstrap is the only caller — no way back short of restarting.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", "[]"),
                StubRoute("POST", "/session", 500, "Internal Server Error", "the session directory is not writable"),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token, watching: [
            "could not create a session — retrying",
            "Could not create a session",
            "the session directory is not writable",
            "Press 'n' in the sidebar to try again",
        ])
        _ = await client.waitForAll()
        #expect(client.missing.isEmpty, "never shown: \(client.missing)\n\(client.joined())")
        await client.quit()
    }

    @Test("A session list that will not refresh is reported, without pretending the session failed")
    func sessionListRefreshFailureIsReported() async throws {
        // The lightest of the swallow sites, and the one most likely to be dropped
        // as noise: the sidebar's CONTENT is intact, it is just missing one row.
        // A transient notice is the right weight — but silence is not.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", "[]", times: 1),
                StubRoute("GET", "/sessions", 500, "Internal Server Error", "the listing is unavailable"),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", Self.connectedIdle),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "the session list did not refresh"), "screen:\n\(client.joined())")
        await client.quit()
    }

    @Test("A history refresh that fails after a reconnect says what the pane is missing")
    func historyRefreshFailureIsReported() async throws {
        // The stream is delta-only, so everything that streamed during an outage is
        // simply absent from the pane afterwards. If the re-seed ALSO fails and
        // says nothing, the pane is quietly wrong and looks completely normal.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]", times: 1),
                StubRoute("GET", "/messages", 500, "Internal Server Error", "session file is unreadable"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                // Answers once per connect and then closes, so the client
                // reconnects and takes the re-seed path.
                StubRoute("GET", "/events", 200, "OK", Self.connectedIdle),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "history refresh failed"), "screen:\n\(client.joined())")
        await client.quit()
    }

    // MARK: A runtime that is simply gone

    @Test("An outage names its reason, escalates to a row, and does not eat what you typed")
    func outageIsNamedAndKeepsYourText() async throws {
        // Four claims, all on one outage, because they are one experience:
        //  1. the status line says WHY, not just that something is wrong;
        //  2. after the outage has genuinely lasted, it earns a row that survives
        //     scrolling — a spinner you have scrolled away from is not a report;
        //  3. a prompt sent into the outage is put BACK, not destroyed;
        //  4. and the reason it did not send is on the transcript, where it stays.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/events", 503, "Service Unavailable", "the runtime is restarting"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        // ONE row, carrying all three parts. Asserted as a row and not as three
        // separate needles because the transcript row below reports the same words:
        // a whole-screen search would stay green with the status line's reason
        // deleted, which is precisely how this behaviour came to have no coverage.
        #expect(
            await client.waitForRow(
                with: ["disconnected", "HTTP 503", "the runtime is restarting", "reconnecting"],
                timeout: .seconds(15)
            ),
            "screen:\n\(client.joined())"
        )

        client.type("do not lose me")
        try? await Task.sleep(for: .milliseconds(300))
        client.press()
        #expect(await client.wait(for: "could not send — the message was put back"), "screen:\n\(client.joined())")
        #expect(await client.wait(for: "Could not send the message"), "screen:\n\(client.joined())")
        #expect(await client.wait(for: "Your text was put back in the prompt"), "screen:\n\(client.joined())")
        // And it really is back: the text is on screen, in the prompt, afterwards.
        #expect(client.showing("do not lose me"), "screen:\n\(client.joined())")

        // The escalation is measured against the clock, not a retry counter.
        #expect(await client.wait(for: "Lost the connection to the runtime", timeout: .seconds(20)), "screen:\n\(client.joined())")
        #expect(client.showing("Reconnecting automatically; nothing you typed was lost"), "screen:\n\(client.joined())")
        #expect(client.missing.isEmpty, "never shown: \(client.missing)\n\(client.joined())")
        await client.quit()
    }

    // MARK: Refusals

    @Test("A refused prompt names both ways out")
    func busyRefusalNamesTheExits() async throws {
        // "a turn is already running" was true and useless: it named no way out,
        // and in the wedged case the run it named could never finish, so waiting —
        // the only thing it implied — was the one thing that could not work.
        let stub = try Self.runtime([
            StubRoute("POST", "/prompt", 409, "Conflict", "a turn is already running"),
        ])
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        try? await Task.sleep(for: .milliseconds(600))
        client.type("are you there")
        try? await Task.sleep(for: .milliseconds(300))
        client.press()

        #expect(await client.wait(for: "Esc aborts it"), "screen:\n\(client.joined())")
        #expect(client.showing("^G shows why"), "screen:\n\(client.joined())")
        // The message is not destroyed by the refusal.
        #expect(client.showing("are you there"), "screen:\n\(client.joined())")
        await client.quit()
    }

    @Test("An abort that does not land says so and leaves a row to act on")
    func abortFailureIsReported() async throws {
        // Esc is the user's escape hatch from exactly the stall this whole area is
        // about. An escape hatch that fails silently is worse than none.
        //
        // `/events` refuses here rather than answering-and-closing, and that is not
        // incidental: a reconnect re-seeds the transcript from history, and a
        // CLIENT-posted row is not in the session's history, so a re-seed deletes
        // it. With an event route that closes after every frame, the reconnect loop
        // spins fast enough to race the assertion — in release it wins. See the
        // finding filed alongside this work; the test isolates the claim it is
        // making rather than pretending the hazard is not there.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("POST", "/abort", 500, "Internal Server Error", "the runtime refused the abort"),
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/events", 503, "Service Unavailable", "no stream today"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        try? await Task.sleep(for: .milliseconds(800))
        client.send([0x1b])   // Escape

        #expect(await client.wait(for: "could not abort — the run may still be going"), "screen:\n\(client.joined())")
        #expect(await client.wait(for: "Could not abort the run"), "screen:\n\(client.joined())")
        #expect(client.showing("the runtime refused the abort"), "screen:\n\(client.joined())")
        await client.quit()
    }

    @Test("A pending-approval check that fails says the modal may never arrive")
    func pendingPermissionCheckFailureIsReported() async throws {
        // This GET is the ONLY recovery for a `permission_request` the bounded
        // broadcast buffer dropped. When it fails, a parked run stays unanswerable
        // and the UI keeps animating — the exact picture the user described.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 500, "Internal Server Error", "the permission map is unreadable"),
                StubRoute("GET", "/events", 200, "OK", Self.connectedIdle),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "could not check for pending approvals"), "screen:\n\(client.joined())")
        await client.quit()
    }

    @Test("An approval that does not reach the server says so before the prompt re-appears")
    func approvalFailureIsReported() async throws {
        // Without the notice, the modal simply comes back — which reads as the UI
        // having lost the answer rather than the network having lost it, and a user
        // who reads it that way answers again and again.
        let events = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: true),
            .permissionRequest(
                id: "per_1", sessionID: "abc123", permission: "bash",
                patterns: ["*"], always: [], metadata: ["command": .string("rm -rf /tmp/x")],
                disableAlways: true
            ),
        ])
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", events),
                StubRoute("POST", "/permission", 500, "Internal Server Error", "the run is gone"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "Permission required"), "screen:\n\(client.joined())")
        client.press()   // Enter answers "Allow once"
        #expect(await client.wait(for: "the approval did not reach the server"), "screen:\n\(client.joined())")
        await client.quit()
    }

    // MARK: ^G

    @Test("^G shows connection and run state, and Ctrl-C still quits with it up")
    func diagnosticsPanel() async throws {
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/events", 503, "Service Unavailable", "the runtime is restarting"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        // The key is advertised exactly where it is useful: something is wrong.
        #expect(await client.wait(for: "^G: diagnostics"), "screen:\n\(client.joined())")

        client.send([0x07])
        #expect(await client.wait(for: "Connection & run state"), "screen:\n\(client.joined())")
        let panel = client.joined()
        #expect(panel.contains("last frame"), "screen:\n\(panel)")
        #expect(panel.contains("client run state"), "screen:\n\(panel)")
        #expect(panel.contains("stream"), "screen:\n\(panel)")
        // The lever, named as what it is rather than as a second Esc.
        #expect(panel.contains("Force-clear the run"), "screen:\n\(panel)")
        #expect(panel.contains("frees the session"), "screen:\n\(panel)")
        // The server's half is unreachable on this stub, and says so rather than
        // rendering a blank the reader has to interpret.
        #expect(await client.wait(for: "unavailable"), "screen:\n\(client.joined())")

        // ^G closes it again.
        client.send([0x07])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!client.showing("Force-clear the run"), "screen:\n\(client.joined())")

        client.send([0x07])
        try? await Task.sleep(for: .milliseconds(300))
        // The regression guard: a modal that swallows ^C makes the session
        // unquittable while the status bar still advertises "^C: quit". If this
        // hangs, the suite's time limit fails the test.
        await client.quit()
    }

    @Test("^G reaches past a permission modal, which is exactly when it is wanted")
    func diagnosticsWorkWhileAModalIsUp() async throws {
        // A parked approval is one of the two states a user reads as a freeze, and
        // it is the state in which the ordinary keyboard is entirely captured. The
        // branch order is therefore semantic, not cosmetic: mouse, then Ctrl-C
        // (never moved), then ^G, then ^O, and only THEN the modal's capture. A
        // careless merge that puts ^G below the modal leaves the one key that
        // explains a parked run unreachable while a run is parked.
        let events = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: true),
            .permissionRequest(
                id: "per_9", sessionID: "abc123", permission: "bash",
                patterns: ["*"], always: [], metadata: ["command": .string("rm -rf /tmp/x")],
                disableAlways: true
            ),
        ])
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", events),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "Permission required"), "screen:\n\(client.joined())")

        client.send([0x07])
        #expect(await client.wait(for: "Connection & run state"), "screen:\n\(client.joined())")
        // The modal is still there underneath — the panel is a second overlay, not
        // a replacement, and answering the prompt is still what the user must do.
        #expect(client.showing("client prompt"), "screen:\n\(client.joined())")

        // And ^C still quits, over BOTH of them. If it does not, the suite's time
        // limit fails this test rather than hanging the run.
        await client.quit()
    }

    @Test("Force-clear from the panel recovers a session whose run can never settle")
    func forceClearRecoversAWedgedSession() async throws {
        // The user's report, end to end, against a REAL runtime: a turn that never
        // returns holds the run slot, every later prompt 409s, and no frame will
        // ever arrive to say so. Before the lever existed, the only recovery was a
        // new session.
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let parked = AsyncStream<Void>.makeStream()
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "You are a test.",
            tools: [],
            model: "test-model",
            streamFn: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                    parked.continuation.yield(())
                    // Never finishes, and never observes cancellation.
                }
            },
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
        let server = DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
        let (ports, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { portCont.yield($0); portCont.finish() }) }
        var portIterator = ports.makeAsyncIterator()
        let port = await portIterator.next() ?? 0

        let client = WedgeClient(baseURL: "http://127.0.0.1:\(port)", token: Self.token)
        try? await Task.sleep(for: .milliseconds(800))
        client.type("park forever")
        try? await Task.sleep(for: .milliseconds(200))
        client.press()

        var parkedIterator = parked.stream.makeAsyncIterator()
        _ = await parkedIterator.next()

        // A second prompt is refused, and the refusal points at ^G.
        client.type("hello?")
        try? await Task.sleep(for: .milliseconds(200))
        client.press()
        #expect(await client.wait(for: "Esc aborts it"), "screen:\n\(client.joined())")

        client.send([0x07])
        #expect(await client.wait(for: "Connection & run state"), "screen:\n\(client.joined())")
        // The server's own answer, which is what makes the panel worth opening:
        // the client is not guessing that a run is in flight.
        #expect(await client.wait(for: "server running"), "screen:\n\(client.joined())")

        client.send([0x1b, 0x5b, 0x42])   // down, onto the force-clear row
        try? await Task.sleep(for: .milliseconds(200))
        client.press()

        #expect(await client.wait(for: "the run was cleared — you can send again"), "screen:\n\(client.joined())")

        // And the session genuinely works again — a claim the notice alone does
        // not make good on.
        try? await Task.sleep(for: .milliseconds(300))
        client.type("after the clear")
        try? await Task.sleep(for: .milliseconds(200))
        client.press()
        #expect(await client.wait(for: "after the clear"), "screen:\n\(client.joined())")

        await client.quit()
        serverTask.cancel()
        _ = try? await serverTask.value
    }

    // MARK: The poll

    @Test("A client pinned on a run that already ended corrects itself, with no reconnect")
    func theClientCorrectsItsOwnRunState() async throws {
        // The wedge, staged exactly: the client is told a run is in flight and then
        // the stream dies, so `agent_end` — the ONLY edge that could put it back —
        // is never delivered and never will be. Nothing reconnects successfully, so
        // the `connected` reconcile cannot help either. The client is left refusing
        // every prompt, spinning, until it asks the server a level-triggered
        // question of its own.
        let running = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: true)
        ])
        let idleStatus = SessionStatus(
            sessionID: "abc123", running: false, pendingPermissionIDs: [],
            subscribers: 0, runStartedAt: nil
        )
        let statusJSON = String(decoding: try JSONEncoder().encode(idleStatus), as: UTF8.self)
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/status", 200, "OK", statusJSON),
                StubRoute("GET", "/events", 200, "OK", running, times: 1),
                StubRoute("GET", "/events", 503, "Service Unavailable", "the runtime went away"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "thinking…", timeout: .seconds(10)), "screen:\n\(client.joined())")
        // No reconnect ever succeeds here; the ONLY thing that can move this is the
        // poll asking the server what it actually believes.
        #expect(
            await client.wait(for: "the server says nothing is running", timeout: .seconds(20)),
            "screen:\n\(client.joined())"
        )
        #expect(!client.showing("thinking…"), "screen:\n\(client.joined())")
        await client.quit()
    }

    @Test("A session the runtime does not have live is resumed again instead of 404ing forever")
    func aDeadSessionIsRevived() async throws {
        // `/events` answering 404 means one specific thing — the runtime does not
        // have this session live — and reconnecting forever cannot fix it. Until
        // the retry existed, a session that failed to open stayed permanently inert
        // with every endpoint 404ing and nothing ever trying the resume again.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 404, "Not Found", "no such session on this runtime", times: 2),
                StubRoute("GET", "/events", 200, "OK", Self.connectedIdle),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "the session is live again", timeout: .seconds(15)), "screen:\n\(client.joined())")
        await client.quit()
    }

    // MARK: The silence figure

    @Test("A run whose stream has gone silent says how long it has been silent")
    func silenceIsReportedOnTheStatusLine() async throws {
        // The single line that would have told the user everything. "⠋ thinking…"
        // is byte-for-byte what a healthy slow turn looks like; the elapsed silence
        // is the only thing on screen that can separate them.
        let running = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: true)
        ])
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", running, times: 1),
                StubRoute("GET", "/events", 503, "Service Unavailable", "the runtime went away"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        // Nothing is claimed before the threshold: a status line that cried wolf at
        // two seconds would be turned off by everyone within a day.
        #expect(await client.wait(for: "thinking…", timeout: .seconds(10)), "screen:\n\(client.joined())")
        #expect(!client.showing("no data for"), "too early:\n\(client.joined())")

        #expect(await client.wait(for: "(no data for 2", timeout: .seconds(40)), "screen:\n\(client.joined())")
        await client.quit()
    }

    // MARK: Fixtures

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-wedge-ui-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
