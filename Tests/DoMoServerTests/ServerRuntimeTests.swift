// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Runtime-level tests for the session-containment fixes from the adversarial
// review: resuming a live session must not stand up a second harness over the
// same file, and `resume` must not open an arbitrary on-disk path.

import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoPermissions
import DoMoServer
import Foundation
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct ServerRuntimeTests {

    private struct AskedTool: AgentTool {
        var definition: ToolDefinition {
            ToolDefinition(name: "question", description: "question", parameters: JSONSchema())
        }

        func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
            AgentToolResult(output: "approved")
        }
    }

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-runtime-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRuntime(
        _ dirs: Dirs,
        streamFn: @escaping AgentStreamFn = { _ in AsyncThrowingStream { $0.finish() } },
        maxSubagentDepth: Int = 2
    ) -> ServerRuntime {
        ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            maxSubagentDepth: maxSubagentDepth
        ))
    }

    private func textStream(_ text: String) -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(
                    content: [.text(text)],
                    model: "test-model",
                    stopReason: .stop
                )))
                continuation.finish()
            }
        }
    }

    private func askedStream() -> AgentStreamFn {
        let turns = Mutex(0)
        return { _ in
            let turn = turns.withLock { value in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                if turn == 1 {
                    continuation.yield(.done(AssistantMessage(
                        content: [.toolCall(ToolCallBlock(id: "call_question", name: "question"))],
                        model: "test-model",
                        stopReason: .toolUse
                    )))
                } else {
                    continuation.yield(.done(AssistantMessage(
                        content: [.text("child permission passed")],
                        model: "test-model",
                        stopReason: .stop
                    )))
                }
                continuation.finish()
            }
        }
    }

    @Test("Resuming a live session returns the same session, not a second harness")
    func resumeLiveReturnsSameSession() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs)

        let created = try await runtime.createSession()
        // Attach a subscriber to the live session's sink; if resume rebuilt the
        // session, the sink object would be replaced and this subscription lost.
        let sink = try await runtime.sink(for: created.id)
        let subscription = sink.subscribe()

        let resumed = try await runtime.createSession(resume: created.id)
        #expect(resumed.id == created.id)
        let sinkAfter = try await runtime.sink(for: created.id)
        #expect(sinkAfter === sink, "resume replaced the live session's sink")
        withExtendedLifetime(subscription) {}
    }

    @Test("Resume rejects an id that is not a listed session")
    func resumeUnknownIdRejected() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs)
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            _ = try await runtime.createSession(resume: "not-a-real-session-id")
        }
    }

    @Test("Resume treats a filesystem path as an id and refuses it (no arbitrary-path open)")
    func resumeArbitraryPathRefused() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs)
        // A real, readable path — but not a session id in scope, so it must be
        // rejected rather than opened and appended to.
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            _ = try await runtime.createSession(resume: "/etc/hosts")
        }
    }

    @Test("An unknown session id is a not-found error for reads and runs")
    func unknownSessionIsNotFound() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs)
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            _ = try await runtime.messages(sessionID: "nope")
        }
        await #expect(throws: ServerRuntimeError.sessionNotFound) {
            try await runtime.abort(sessionID: "nope")
        }
    }

    @Test("foreground subagents use a child session and persist lifecycle events")
    func foregroundSubagent() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, streamFn: textStream("child findings"))
        let parent = try await runtime.createSession()
        let sink = try await runtime.sink(for: parent.id)
        let subscription = sink.subscribe()
        defer { sink.unsubscribe(subscription.id) }

        let result = await runtime.runSubagent(SubagentTaskRequest(
            taskID: "task-foreground",
            parentSessionID: parent.id,
            prompt: "inspect the parser",
            agent: "explore"
        ))

        #expect(result.status == .completed)
        #expect(result.output == "child findings")
        #expect(result.childSessionID != nil)

        var iterator = subscription.events.makeAsyncIterator()
        var lifecycle: [SubagentTaskStatus] = []
        while let event = await iterator.next() {
            if case .subagent(let event) = event {
                lifecycle.append(event.status)
                if event.status == .completed { break }
            }
        }
        #expect(lifecycle == [.started, .completed])

        let parentEntries = try await runtime.tree(sessionID: parent.id)
        #expect(parentEntries.contains { entry in
            if case .subagent(let event) = entry.payload {
                return event.taskID == "task-foreground" && event.status == .completed
            }
            return false
        })

        let sessions = try await runtime.listSessions()
        let child = try #require(sessions.first { $0.id != parent.id })
        let header = try JSONLSessionStore(path: FilePath(child.path)).readHeader()
        #expect(header.parentSession == parent.path)
    }

    @Test("background results enter the parent queue and can start an idle parent")
    func backgroundSubagentStartsParent() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, streamFn: textStream("background findings"))
        let parent = try await runtime.createSession()

        let result = await runtime.runSubagent(SubagentTaskRequest(
            taskID: "task-background",
            parentSessionID: parent.id,
            prompt: "inspect the parser",
            background: true
        ))
        #expect(result.status == .accepted)

        var delivered = false
        var idle = false
        for _ in 0..<200 {
            let messages = try await runtime.messages(sessionID: parent.id)
            delivered = messages.contains { message in
                if case .user(let user) = message {
                    return user.text.contains("background findings")
                }
                return false
            }
            idle = try await runtime.status(sessionID: parent.id).running == false
            if delivered && idle { break }
            await Task.yield()
        }
        #expect(delivered)
        #expect(idle)
    }

    @Test("task_id resumes the durable child after a runtime restart")
    func taskIDResumesAfterRestart() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let first = makeRuntime(dirs, streamFn: textStream("first findings"))
        let parent = try await first.createSession()
        let firstResult = await first.runSubagent(SubagentTaskRequest(
            taskID: "task-resume",
            parentSessionID: parent.id,
            prompt: "inspect the parser",
            agent: "explore"
        ))
        let childID = try #require(firstResult.childSessionID)
        #expect(firstResult.status == .completed)

        let restarted = makeRuntime(dirs, streamFn: textStream("second findings"))
        _ = try await restarted.createSession(resume: parent.id)
        let resumed = await restarted.runSubagent(SubagentTaskRequest(
            taskID: "task-resume",
            parentSessionID: parent.id,
            prompt: "check the parser's edge cases"
        ))

        #expect(resumed.status == .completed)
        #expect(resumed.childSessionID == childID)
        #expect(resumed.output == "second findings")
        let childStatus = try await restarted.status(sessionID: childID)
        #expect(childStatus.mode == AgentMode.plan.rawValue)
        #expect(childStatus.agent == "explore")
        #expect((try await restarted.listSessions()).count == 2)
    }

    @Test("subagent depth is capped before creating a child")
    func subagentDepthCap() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, maxSubagentDepth: 0)
        let parent = try await runtime.createSession()
        let result = await runtime.runSubagent(SubagentTaskRequest(
            taskID: "task-too-deep",
            parentSessionID: parent.id,
            prompt: "inspect"
        ))
        #expect(result.status == .failed)
        #expect(result.error?.contains("depth limit") == true)
        let sessions = try await runtime.listSessions()
        #expect(sessions.count == 1)
    }

    @Test("child permission requests bubble to the parent session")
    func childPermissionBubbles() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let factory = PermissionRequestFactory(workingDirectory: dirs.cwd.path)
        let permissions = ServerRuntime.PermissionRuntime(
            ruleset: [],
            factory: factory,
            persist: { _ in },
            rulesetForMode: { mode, path in AgentModePolicy.rules(for: mode, planPath: path) }
        )
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [AskedTool()],
            model: "test-model",
            streamFn: askedStream(),
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            permissions: permissions
        ))
        let parent = try await runtime.createSession()
        let sink = try await runtime.sink(for: parent.id)
        let subscription = sink.subscribe()
        defer { sink.unsubscribe(subscription.id) }
        let runTask = Task {
            await runtime.runSubagent(SubagentTaskRequest(
                taskID: "task-permission",
                parentSessionID: parent.id,
                prompt: "ask for approval"
            ))
        }

        var iterator = subscription.events.makeAsyncIterator()
        var sawParentRoutedPrompt = false
        while let event = await iterator.next() {
            if case .permissionRequest(let id, let sessionID, let permission, _, _, _, _) = event {
                #expect(sessionID == parent.id)
                #expect(permission == "question")
                sawParentRoutedPrompt = true
                try await runtime.resolvePermission(
                    sessionID: parent.id,
                    requestID: id,
                    reply: .once
                )
                break
            }
        }
        let result = await runTask.value
        #expect(sawParentRoutedPrompt)
        #expect(result.status == .completed)
        #expect(result.output == "child permission passed")
    }
}
