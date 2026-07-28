// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// THE USER'S BUG: "occasionally the session will lose the ability for your typed
// prompt to query against the model and then you have to make a new session."
//
// Mechanically: `ServerRuntime.startRun` refuses while `session.runTask != nil`,
// and the ONLY thing that nils that slot is the run task itself reaching
// `finishRun`. `abort(sessionID:)` merely *cancels* — it returns without waiting
// and never touches the slot. So a run parked on anything that cannot observe
// cancellation holds the session for the life of the process, and every later
// prompt 409s forever, with no agent_end ever broadcast so the client sits on
// "thinking…".
//
// `wedgedRunHoldsTheSlotForever` reproduces that end of it exactly.
// `forceClearFreesAWedgedSlot` proves the new lever gets the session back.
// `stalledModelStreamEndsTheRunAndTheSessionRecovers` covers the dominant cause —
// a gateway that sends a head and then stalls — from the transport all the way
// out to "the next prompt is accepted".

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Foundation
import HTTPTypes
import JSONSchema
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct ServerRuntimeForceClearTests {

    // MARK: - Fixtures

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-forceclear-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A tool that suspends on a plain `withCheckedContinuation` and is therefore
    /// **uncancellable** — cancelling the run task cannot unwind it.
    ///
    /// This is not a contrivance for the test's benefit: it is the general shape
    /// of everything that produced the reported wedge (a stalled-but-open socket
    /// read before the transport's idle guard existed, a subprocess that ignores
    /// SIGTERM, an MCP server that stops answering). The point of `forceClearRun`
    /// is that it must not depend on the run being able to notice anything.
    private final class ParkingTool: AgentTool, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var definition: ToolDefinition {
            ToolDefinition(name: "park", description: "parks until released", parameters: JSONSchema())
        }

        func execute(_ arguments: DoMoCore.JSONValue) async throws(DoMoError) -> AgentToolResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters.append(continuation)
                lock.unlock()
            }
            return AgentToolResult(output: "released")
        }

        var parkedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }

        /// Release the OLDEST parked call, so a test can settle run A while run B
        /// stays parked.
        func releaseOne() {
            lock.lock()
            let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            waiter?.resume()
        }

        func releaseAll() {
            lock.lock()
            let all = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in all { waiter.resume() }
        }
    }

    /// Turn N emits a `park` tool call for every index in `toolCallTurns`, and a
    /// final text turn otherwise. Deterministic per invocation count, so a test can
    /// arrange exactly which runs park and which complete.
    private static func streamFn(toolCallTurns: Set<Int>) -> AgentStreamFn {
        let calls = Mutex(0)
        return { _ in
            let n = calls.withLock { value in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if toolCallTurns.contains(n) {
                    let call = ToolCallBlock(id: "call_park_\(n)", name: "park", arguments: .object([:]))
                    continuation.yield(.done(AssistantMessage(
                        content: [.toolCall(call)], model: "test-model", stopReason: .toolUse
                    )))
                } else {
                    continuation.yield(.done(AssistantMessage(
                        content: [.text("done \(n)")], model: "test-model", stopReason: .stop
                    )))
                }
                continuation.finish()
            }
        }
    }

    private func makeRuntime(
        _ dirs: Dirs,
        tools: [any AgentTool],
        streamFn: @escaping AgentStreamFn,
        permissions: ServerRuntime.PermissionRuntime? = nil
    ) -> ServerRuntime {
        ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: tools,
            model: "test-model",
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: 10,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            permissions: permissions
        ))
    }

    /// The first broadcast event matching `predicate`, or nil if none arrives in
    /// `within`. On timeout the reader is cancelled, which also unsubscribes — so a
    /// test asserting on `subscriberCount` afterwards is asserting on the success
    /// path only, which is what it wants.
    private func firstEvent(
        _ subscription: BroadcastEventSink.Subscription,
        within: Duration = .seconds(3),
        matching predicate: @escaping @Sendable (ServerEvent) -> Bool
    ) async -> ServerEvent? {
        let reader = Task { () -> ServerEvent? in
            for await event in subscription.events where predicate(event) { return event }
            return nil
        }
        let timer = Task {
            try? await Task.sleep(for: within)
            reader.cancel()
        }
        let found = await reader.value
        timer.cancel()
        return found
    }

    /// Poll `condition` up to `within`. Returns whether it ever held.
    private func eventually(
        _ within: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = Duration.zero
        while waited < within {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        return await condition()
    }

    // MARK: - The bug

    @Test("A run that cannot observe cancellation holds the slot forever, and abort does not free it")
    func wedgedRunHoldsTheSlotForever() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        let runtime = makeRuntime(dirs, tools: [tool], streamFn: Self.streamFn(toolCallTurns: [1]))

        let session = try await runtime.createSession()
        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        #expect(await eventually { tool.parkedCount == 1 }, "the run never reached the parking tool")

        // The slot is held.
        #expect(await runtime.isRunning(sessionID: session.id))
        await #expect(throws: ServerRuntimeError.sessionBusy) {
            try await runtime.startRun(sessionID: session.id, prompt: "again", attachments: [])
        }

        // THE GAP: abort reports it stopped something, cancels the task — and the
        // slot is still held, because the run can never reach `finishRun`.
        #expect(try await runtime.abort(sessionID: session.id) == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            await runtime.isRunning(sessionID: session.id),
            "abort freed the slot — if this ever becomes true, the wedge premise changed"
        )
        await #expect(throws: ServerRuntimeError.sessionBusy) {
            try await runtime.startRun(sessionID: session.id, prompt: "still refused", attachments: [])
        }
    }

    // MARK: - The fix

    @Test("forceClearRun frees a slot held by an uncancellable run, and the session takes prompts again")
    func forceClearFreesAWedgedSlot() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        let runtime = makeRuntime(dirs, tools: [tool], streamFn: Self.streamFn(toolCallTurns: [1]))

        let session = try await runtime.createSession()
        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        #expect(await eventually { tool.parkedCount == 1 })

        #expect(try await runtime.forceClearRun(sessionID: session.id) == true, "nothing was reported as held")
        #expect(await runtime.isRunning(sessionID: session.id) == false, "the slot is still held after a force-clear")

        // The whole point: the session works again, with no new session.
        try await runtime.startRun(sessionID: session.id, prompt: "second prompt", attachments: [])
        #expect(await eventually { await runtime.isRunning(sessionID: session.id) == false },
                "the recovered session's run never settled")

        // And the second turn really produced an answer through the REBUILT harness.
        let messages = try await runtime.messages(sessionID: session.id)
        #expect(messages.contains { if case .user(let u) = $0 { u.text == "second prompt" } else { false } },
                "the second prompt did not land: \(messages.count) messages")
    }

    @Test("forceClearRun is idempotent and reports nothing held on an idle session")
    func forceClearOnIdleSessionReportsNothingHeld() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, tools: [], streamFn: Self.streamFn(toolCallTurns: []))
        let session = try await runtime.createSession()

        #expect(try await runtime.forceClearRun(sessionID: session.id) == false)
        #expect(try await runtime.forceClearRun(sessionID: session.id) == false)
        // Still usable afterwards.
        try await runtime.startRun(sessionID: session.id, prompt: "hi", attachments: [])
        #expect(await eventually { await runtime.isRunning(sessionID: session.id) == false })
    }

    @Test("forceClearRun keeps the session's sink, so live subscribers survive it")
    func forceClearKeepsTheSink() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        let runtime = makeRuntime(dirs, tools: [tool], streamFn: Self.streamFn(toolCallTurns: [1]))

        let session = try await runtime.createSession()
        let sink = try await runtime.sink(for: session.id)
        let subscription = sink.subscribe()

        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        #expect(await eventually { tool.parkedCount == 1 })

        try await runtime.forceClearRun(sessionID: session.id)

        // The SAME sink object: rebuilding the state must not orphan an attached
        // SSE response onto a sink nothing feeds.
        let after = try await runtime.sink(for: session.id)
        #expect(after === sink, "force-clear replaced the session's sink and stranded its subscribers")

        // The subscriber is told the run is over, which is the only thing that
        // un-pins a client's edge-triggered run state.
        let terminal = await firstEvent(subscription) {
            if case .agentEnd = $0 { true } else { false }
        }
        if case .agentEnd(let reason) = terminal {
            #expect(reason == "aborted", "terminal frame said \(reason)")
        } else {
            Issue.record("no agent_end reached the surviving subscriber")
        }

        // And the still-attached subscriber keeps receiving from the NEW run.
        #expect(sink.subscriberCount == 1)
    }

    @Test("forceClearRun resolves a parked permission prompt")
    func forceClearResolvesAParkedPrompt() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let ruleset = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: "/home/test")
        let factory = PermissionRequestFactory(workingDirectory: dirs.cwd.path)
        // `bash` is asked about by the baseline policy, and the tool parks so the
        // ask stays open for as long as the test needs it.
        let tool = GatedParkingTool()
        defer { tool.releaseAll() }
        let runtime = makeRuntime(
            dirs,
            tools: [tool],
            streamFn: Self.bashCallThenText(),
            permissions: .init(ruleset: ruleset, factory: factory, persist: { _ in })
        )

        let session = try await runtime.createSession()
        try await runtime.startRun(sessionID: session.id, prompt: "run it", attachments: [])
        #expect(await eventually { (try? await runtime.pendingPermissions(sessionID: session.id))?.isEmpty == false },
                "the run never parked on a permission prompt")

        let status = try await runtime.status(sessionID: session.id)
        #expect(status.running)
        #expect(status.pendingPermissionIDs.count == 1, "status did not project the parked prompt")

        try await runtime.forceClearRun(sessionID: session.id)
        #expect(try await runtime.pendingPermissions(sessionID: session.id).isEmpty,
                "a parked prompt survived the force-clear and its tool fiber is leaked")
        #expect(try await runtime.status(sessionID: session.id).running == false)
        #expect(try await runtime.status(sessionID: session.id).pendingPermissionIDs.isEmpty)
    }

    /// The `finishRun` token guard was dead code before force-clear existed (no
    /// path ever replaced a live `SessionState`). It is load-bearing now: the run
    /// that force-clear walked away from may settle at ANY later moment, and when
    /// it does it must not free a slot a different, healthy run is holding.
    @Test("The doomed run's completion hop cannot free the next run's slot")
    func forceClearTokenGuardProtectsTheNextRun() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        // Turn 1 (run A) and turn 2 (run B) both park; turns 3+ finish with text.
        let runtime = makeRuntime(dirs, tools: [tool], streamFn: Self.streamFn(toolCallTurns: [1, 2]))

        let session = try await runtime.createSession()
        try await runtime.startRun(sessionID: session.id, prompt: "A", attachments: [])
        #expect(await eventually { tool.parkedCount == 1 })

        try await runtime.forceClearRun(sessionID: session.id)
        #expect(await runtime.isRunning(sessionID: session.id) == false)

        // Run B takes the freed slot and parks in its turn.
        try await runtime.startRun(sessionID: session.id, prompt: "B", attachments: [])
        #expect(await eventually { tool.parkedCount == 2 }, "run B never reached the tool")
        #expect(await runtime.isRunning(sessionID: session.id))

        // Now let the ABANDONED run A finish. It settles, hops to `finishRun` with
        // its stale token — and must be ignored.
        tool.releaseOne()
        try await Task.sleep(for: .milliseconds(500))
        #expect(
            await runtime.isRunning(sessionID: session.id),
            "the abandoned run's completion hop cleared the live run's slot — the token guard is not working"
        )

        // Run B still settles normally on its own.
        tool.releaseOne()
        #expect(await eventually { await runtime.isRunning(sessionID: session.id) == false },
                "run B never settled")
    }

    // MARK: - status

    @Test("status reports running, the run start, parked prompt ids and subscriber count")
    func statusProjection() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let tool = ParkingTool()
        defer { tool.releaseAll() }
        let runtime = makeRuntime(dirs, tools: [tool], streamFn: Self.streamFn(toolCallTurns: [1]))

        let session = try await runtime.createSession()
        let idle = try await runtime.status(sessionID: session.id)
        #expect(idle.sessionID == session.id)
        #expect(idle.running == false)
        #expect(idle.runStartedAt == nil, "an idle session must not claim a run start")
        #expect(idle.pendingPermissionIDs.isEmpty)
        #expect(idle.subscribers == 0)

        let sink = try await runtime.sink(for: session.id)
        let subscription = sink.subscribe()
        defer { sink.unsubscribe(subscription.id) }

        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        #expect(await eventually { tool.parkedCount == 1 })

        let busy = try await runtime.status(sessionID: session.id)
        #expect(busy.running)
        #expect(busy.subscribers == 1)
        let startedAt = try #require(busy.runStartedAt, "a running session must carry a run start")
        // ISO8601 with fractional seconds, the same shape the session header uses.
        #expect(sessionTimestampParser().date(from: startedAt) != nil,
                "runStartedAt is not a parseable ISO8601 timestamp: \(startedAt)")

        // And it is cleared again once the slot frees.
        try await runtime.forceClearRun(sessionID: session.id)
        let cleared = try await runtime.status(sessionID: session.id)
        #expect(cleared.running == false)
        #expect(cleared.runStartedAt == nil)
        #expect(cleared.subscribers == 1, "the surviving subscriber must still be counted")
    }

    @Test("status and forceClearRun are not-found for an unknown session")
    func unknownSessionIsNotFound() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, tools: [], streamFn: Self.streamFn(toolCallTurns: []))
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            _ = try await runtime.status(sessionID: "nope")
        }
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            _ = try await runtime.forceClearRun(sessionID: "nope")
        }
    }

    // MARK: - The dominant root cause, end to end

    /// A transport that answers with a committed 200 and then goes quiet: the
    /// exact shape `AsyncHTTPClientTransport` faces, since `execute(_:timeout:)`
    /// bounds only time-to-response-head. `idle == nil` reproduces the pre-fix
    /// unbounded body.
    private struct StallingTransport: StreamingTransport {
        let idle: Duration?

        func execute(
            request: HTTPRequest,
            body: [UInt8]?,
            timeout: Duration?
        ) async throws -> StreamingResponse {
            var head = HTTPResponse(status: .ok)
            head.headerFields[.contentType] = "text/event-stream"
            let raw = AsyncThrowingStream<[UInt8], any Error> { continuation in
                continuation.yield(Array(#"data: {"choices":[{"delta":{"content":"hel"}}]}"#.utf8) + Array("\n\n".utf8))
                // Never finished, never failed. Still "connected".
            }
            let guarded = idle.map { idleGuarded(raw, idle: $0, overall: .seconds(60)) } ?? raw
            return StreamingResponse(head: head, body: guarded)
        }
    }

    private func stallingStreamFn(idle: Duration?) -> AgentStreamFn {
        let client = LiteLLMClient(
            configuration: .init(baseURL: "http://127.0.0.1:1/v1", maxRetries: 0),
            transport: StallingTransport(idle: idle)
        )
        return { context in client.streamCompletion(model: "test-model", context: context) }
    }

    @Test("A stalled model stream wedges the session when nothing bounds the body")
    func stalledModelStreamWedgesTheSession() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, tools: [], streamFn: stallingStreamFn(idle: nil))

        let session = try await runtime.createSession()
        try await runtime.startRun(sessionID: session.id, prompt: "hello", attachments: [])

        try await Task.sleep(for: .milliseconds(800))
        #expect(await runtime.isRunning(sessionID: session.id),
                "the unbounded stall did not wedge the run — the premise of this fix changed")
        await #expect(throws: ServerRuntimeError.sessionBusy) {
            try await runtime.startRun(sessionID: session.id, prompt: "second", attachments: [])
        }

        // …and force-clear is the way out even for this one.
        #expect(try await runtime.forceClearRun(sessionID: session.id) == true)
        try await runtime.startRun(sessionID: session.id, prompt: "after clear", attachments: [])
    }

    @Test("With the idle guard the stalled stream ends the run and the session takes the next prompt")
    func stalledModelStreamEndsTheRunAndTheSessionRecovers() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, tools: [], streamFn: stallingStreamFn(idle: .milliseconds(200)))

        let session = try await runtime.createSession()
        let sink = try await runtime.sink(for: session.id)
        let subscription = sink.subscribe()
        defer { sink.unsubscribe(subscription.id) }

        try await runtime.startRun(sessionID: session.id, prompt: "hello", attachments: [])

        // The run TERMINATES on its own — no force-clear, no abort, no new session.
        #expect(await eventually(.seconds(10)) { await runtime.isRunning(sessionID: session.id) == false },
                "the guarded stall still wedged the run")

        // And exactly one terminal frame was broadcast, so a client cannot be left
        // pinned on "thinking…".
        let terminal = await firstEvent(subscription) {
            if case .agentEnd = $0 { true } else { false }
        }
        #expect(terminal != nil, "no agent_end after the stalled stream failed")

        // THE ACTUAL USER-VISIBLE FIX: the next prompt is accepted.
        try await runtime.startRun(sessionID: session.id, prompt: "second prompt", attachments: [])
        #expect(await eventually(.seconds(10)) { await runtime.isRunning(sessionID: session.id) == false })
        let messages = try await runtime.messages(sessionID: session.id)
        #expect(messages.contains { if case .user(let u) = $0 { u.text == "second prompt" } else { false } })
    }

    // MARK: - Gated fixture

    /// Named `bash` so the baseline policy asks about it; parks so the ask stays
    /// open.
    private final class GatedParkingTool: AgentTool, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var definition: ToolDefinition {
            ToolDefinition(name: "bash", description: "bash", parameters: JSONSchema())
        }

        func execute(_ arguments: DoMoCore.JSONValue) async throws(DoMoError) -> AgentToolResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters.append(continuation)
                lock.unlock()
            }
            return AgentToolResult(output: "ran")
        }

        func releaseAll() {
            lock.lock()
            let all = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in all { waiter.resume() }
        }
    }

    private static func bashCallThenText() -> AgentStreamFn {
        let calls = Mutex(0)
        return { _ in
            let n = calls.withLock { value in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if n == 1 {
                    let call = ToolCallBlock(
                        id: "call_bash",
                        name: "bash",
                        arguments: .object(["command": .string("rm -rf /tmp/x")])
                    )
                    continuation.yield(.done(AssistantMessage(
                        content: [.toolCall(call)], model: "test-model", stopReason: .toolUse
                    )))
                } else {
                    continuation.yield(.done(AssistantMessage(
                        content: [.text("done")], model: "test-model", stopReason: .stop
                    )))
                }
                continuation.finish()
            }
        }
    }
}

/// The exact option set the session header uses, so a timestamp assertion is
/// pinned to the real format rather than to "some ISO8601-ish string".
private func sessionTimestampParser() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
