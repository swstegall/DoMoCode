// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The read-model fold — pure logic, no network. Feeds ServerEvents and REST
// history in and asserts the resulting transcript, exactly as the two-pane UI
// would read it. Public API only.

import DoMoClient
import DoMoCore
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Testing

@MainActor
@Suite("Client event store")
struct EventStoreTests {
    private func assistant(_ text: String, model: String = "m") -> Message {
        .assistant(AssistantMessage(content: [.text(text)], model: model))
    }

    @Test("Seeding history lays down user/assistant/tool items and drops system")
    func seedHistory() {
        let store = EventStore()
        store.seed([
            .system("you are a helper"),
            .user("hi"),
            assistant("hello"),
            .tool(ToolResultBlock(toolCallID: "c1", toolName: "bash", output: "ok")),
        ])
        #expect(store.transcript == [
            .user("hi"),
            .assistant("hello"),
            .tool(name: "bash", detail: "", output: "ok", state: .succeeded, imageCount: 0),
        ])
    }

    @Test("A streaming assistant turn accumulates deltas then finalizes")
    func streamingAssistant() {
        let store = EventStore()
        store.apply(.agentStart)
        #expect(store.runState == .running)
        store.apply(.messageStart(.assistant(AssistantMessage(model: "m"))))
        store.apply(.messageDelta(text: "Hel", reasoning: nil))
        store.apply(.messageDelta(text: "lo", reasoning: nil))
        #expect(store.transcript == [.assistant("Hello")])   // grew in place
        store.apply(.messageEnd(assistant("Hello")))
        store.apply(.agentEnd(reason: "completed"))
        #expect(store.transcript == [.assistant("Hello")])
        #expect(store.runState == .idle)
        #expect(store.lastStopReason == "completed")
    }

    // MARK: Permission fold (Phase 8b)

    private func askEvent(id: String = "per_1", session: String = "s") -> ServerEvent {
        .permissionRequest(
            id: id, sessionID: session, permission: "bash",
            patterns: ["rm -rf /"], always: ["rm *"],
            metadata: ["command": .string("rm -rf /")], disableAlways: false
        )
    }

    @Test("A permission_request becomes the pending prompt; permission_resolved clears it")
    func permissionFold() {
        let store = EventStore()
        store.select("s")
        store.apply(askEvent())
        #expect(store.pendingPermission?.id == "per_1")
        #expect(store.pendingPermission?.permission == "bash")
        #expect(store.pendingPermission?.metadata["command"]?.stringValue == "rm -rf /")
        // A resolve for a different id does not clear it.
        store.apply(.permissionResolved(id: "per_other"))
        #expect(store.pendingPermission?.id == "per_1")
        // The matching resolve clears it.
        store.apply(.permissionResolved(id: "per_1"))
        #expect(store.pendingPermission == nil)
    }

    @Test("agent_end and clearPendingPermission both drop a dangling prompt")
    func permissionClears() {
        let store = EventStore()
        store.select("s")
        store.apply(askEvent())
        store.apply(.agentEnd(reason: "aborted"))
        #expect(store.pendingPermission == nil)   // a finished turn can't still be waiting

        store.apply(askEvent(id: "per_2"))
        store.clearPendingPermission()
        #expect(store.pendingPermission == nil)
    }

    @Test("Switching sessions drops a prompt belonging to the session being left")
    func permissionPerSession() {
        let store = EventStore()
        store.select("a")
        store.apply(askEvent(session: "a"))
        #expect(store.pendingPermission != nil)
        store.select("b")   // clearTranscript nils the pending prompt
        #expect(store.pendingPermission == nil)
    }

    @Test("A prompt for a non-selected session is dropped (no cross-session modal)")
    func permissionSessionGuard() {
        let store = EventStore()
        store.select("a")
        store.apply(askEvent(session: "b"))   // a late frame from a session being left
        #expect(store.pendingPermission == nil)
        store.apply(askEvent(session: "a"))   // the selected session's prompt does show
        #expect(store.pendingPermission?.id == "per_1")
    }

    @Test("A prompt whose id was already resolved this session is not resurrected by the GET reconcile")
    func permissionResolvedSuppression() {
        let store = EventStore()
        store.select("a")
        store.apply(.permissionResolved(id: "per_1"))    // resolve raced ahead of the GET
        store.apply(askEvent(id: "per_1", session: "a")) // the stale GET-reconciled request
        #expect(store.pendingPermission == nil)          // suppressed, not resurrected
        // A fresh id in the same session still works.
        store.apply(askEvent(id: "per_2", session: "a"))
        #expect(store.pendingPermission?.id == "per_2")
    }

    @Test("A queue_update shows the accepted count and selecting a session clears it")
    func queueUpdate() {
        let store = EventStore()
        store.select("a")
        store.apply(.queueUpdate(count: 3, mode: "one-at-a-time"))
        #expect(store.queuedMessageCount == 3)
        #expect(store.steeringMode == "one-at-a-time")

        store.apply(.queueUpdate(count: 0, mode: "all"))
        #expect(store.queuedMessageCount == 0)
        #expect(store.steeringMode == "all")
        store.select("b")
        #expect(store.queuedMessageCount == 0)
        #expect(store.steeringMode == nil)
    }

    @Test("status adoption reconciles queue state without requiring an SSE frame")
    func queueStatusAdoption() {
        let store = EventStore()
        store.select("a")
        store.adopt(SessionStatus(
            sessionID: "a",
            running: true,
            pendingPermissionIDs: [],
            subscribers: 1,
            runStartedAt: nil,
            queuedMessageCount: 2,
            steeringMode: "all"
        ))
        #expect(store.queuedMessageCount == 2)
        #expect(store.steeringMode == "all")
    }

    @Test("A tool call fills its result in place, not as a duplicate row")
    func toolCallInPlace() {
        let store = EventStore()
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        #expect(store.transcript == [.tool(name: "bash", detail: "", output: "", state: .running, imageCount: 0)])
        store.apply(.toolEnd(id: "t1", name: "bash", output: "done", isError: false, imageCount: 0))
        #expect(store.transcript == [.tool(name: "bash", detail: "", output: "done", state: .succeeded, imageCount: 0)])
    }

    @Test("Tool-result messages and system messages never double-count a tool row")
    func toolMessageIgnored() {
        let store = EventStore()
        store.apply(.toolStart(id: "t1", name: "read", arguments: .object([:])))
        store.apply(.toolEnd(id: "t1", name: "read", output: "contents", isError: false, imageCount: 1))
        // The runtime also emits the tool result as a `tool`-role message — it must
        // NOT add a second row.
        store.apply(.messageStart(.tool(ToolResultBlock(toolCallID: "t1", toolName: "read", output: "contents"))))
        store.apply(.messageEnd(.tool(ToolResultBlock(toolCallID: "t1", toolName: "read", output: "contents"))))
        #expect(store.transcript == [.tool(name: "read", detail: "", output: "contents", state: .succeeded, imageCount: 1)])
    }

    @Test("Reasoning deltas accumulate into their own item")
    func reasoningStream() {
        let store = EventStore()
        store.apply(.messageStart(.assistant(AssistantMessage(model: "m"))))
        store.apply(.messageDelta(text: nil, reasoning: "think"))
        store.apply(.messageDelta(text: nil, reasoning: "ing"))
        store.apply(.messageDelta(text: "answer", reasoning: nil))
        // No row is reserved at message_start, so items appear in natural arrival
        // order: the reasoning that streamed first, then the answer it produced.
        #expect(store.transcript == [.reasoning("thinking"), .assistant("answer")])
    }

    @Test("A tool-call-only assistant turn leaves no empty row")
    func toolCallOnlyTurnNoEmptyRow() {
        let store = EventStore()
        store.apply(.agentStart)
        store.apply(.messageStart(.assistant(AssistantMessage(model: "m"))))
        store.apply(.messageEnd(.assistant(AssistantMessage(content: [], model: "m"))))   // empty text
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        store.apply(.toolEnd(id: "t1", name: "bash", output: "ok", isError: false, imageCount: 0))
        store.apply(.agentEnd(reason: "completed"))
        #expect(store.transcript == [.tool(name: "bash", detail: "", output: "ok", state: .succeeded, imageCount: 0)])
    }

    @Test("An aborted turn before any output leaves no empty row")
    func abortedTurnNoEmptyRow() {
        let store = EventStore()
        store.apply(.agentStart)
        store.apply(.messageStart(.assistant(AssistantMessage(model: "m"))))
        store.apply(.agentEnd(reason: "aborted"))
        #expect(store.transcript.isEmpty)
        #expect(store.lastStopReason == "aborted")
    }

    @Test("An errored turn records the stop reason and returns to idle")
    func erroredTurn() {
        let store = EventStore()
        store.apply(.agentStart)
        store.apply(.agentEnd(reason: "errored"))
        #expect(store.runState == .idle)
        #expect(store.lastStopReason == "errored")
    }

    @Test("Selecting a session clears the transcript")
    func selectClears() {
        let store = EventStore()
        store.seed([.user("old")])
        store.select("s2")
        #expect(store.selectedSessionID == "s2")
        #expect(store.transcript.isEmpty)
    }

    @Test("setSessions populates the sidebar list")
    func sidebarList() {
        let store = EventStore()
        store.setSessions([
            SessionSummary(id: "a", path: "/a", cwd: "/w", timestamp: "t1"),
            SessionSummary(id: "b", path: "/b", cwd: "/w", timestamp: "t2"),
        ])
        #expect(store.sessions.map(\.id) == ["a", "b"])
    }

    @Test("onChange fires on every mutation")
    func onChangeFires() {
        let store = EventStore()
        var count = 0
        store.onChange = { count += 1 }
        store.apply(.agentStart)
        store.apply(.messageDelta(text: "x", reasoning: nil))
        store.setSessions([])
        #expect(count == 3)
    }
}
