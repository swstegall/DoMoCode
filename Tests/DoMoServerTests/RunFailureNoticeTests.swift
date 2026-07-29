// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// What a subscriber is told when a run fails.
//
// `agent_end(reason: "errored")` is a label, not a report: it is why a failed
// turn used to render as an empty pane under a three-word status line. These
// tests pin the two producers of the frame that carries the detail — the loop's
// own classified failure, and a throw the loop never saw — and, just as
// importantly, that the two never both fire for the same failure and that a
// cancellation produces neither.

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import Synchronization
import SystemPackage
import Testing

@Suite(.serialized)
struct RunFailureNoticeTests {

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-failnotice-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRuntime(_ dirs: Dirs, streamFn: @escaping AgentStreamFn) -> ServerRuntime {
        ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
    }

    /// A stream that fails the way a real gateway does: `LiteLLMClient` finishes
    /// the stream `throwing:` an already-classified `DoMoError` for every 4xx/5xx.
    private static func failing(_ error: DoMoError) -> AgentStreamFn {
        { _ in AsyncThrowingStream { $0.finish(throwing: error) } }
    }

    private static func answering(_ text: String) -> AgentStreamFn {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
                continuation.yield(.done(AssistantMessage(
                    content: [.text(text)], model: "test-model", stopReason: .stop
                )))
                continuation.finish()
            }
        }
    }

    /// Collect frames until `agent_end`, or until the deadline.
    private func collectToClose(
        _ subscription: BroadcastEventSink.Subscription,
        timeout: Duration = .seconds(5)
    ) async -> [ServerEvent] {
        let collected = Mutex<[ServerEvent]>([])
        let reader = Task {
            for await event in subscription.events {
                collected.withLock { $0.append(event) }
                if case .agentEnd = event { return }
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            reader.cancel()
        }
        _ = await reader.value
        deadline.cancel()
        return collected.withLock { $0 }
    }

    private func notices(_ events: [ServerEvent]) -> [ServerNotice] {
        events.compactMap { if case .notice(let n) = $0 { n } else { nil } }
    }

    @Test("A provider failure reaches the client as one classified notice, before the close")
    func providerFailureIsNarrated() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(
            dirs,
            streamFn: Self.failing(DoMoError(.authentication, "stream chat completions: HTTP 401: Invalid API key"))
        )
        let session = try await runtime.createSession()
        let subscription = try await runtime.sink(for: session.id).subscribe()
        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        let events = await collectToClose(subscription)

        let errorNotices = notices(events).filter { $0.level == .error }
        // EXACTLY one. The loop narrates its own settled failure; a second
        // broadcast from the runtime's success path would put the identical red
        // block on the screen twice.
        #expect(errorNotices.count == 1, "expected one error notice, got \(errorNotices.count)")
        let notice = try #require(errorNotices.first)
        #expect(notice.text.contains("Invalid API key"))
        #expect(notice.kind == "authentication")
        #expect(notice.code == "provider_error")
        // The label is the whole point: a client with only prose would have to
        // grep it. With the kind it reaches the headline and the remedy.
        #expect(
            ErrorPresentation.rows(label: notice.kind, message: notice.text).headline
                == "The gateway rejected the credential"
        )
        #expect(ErrorPresentation.rows(label: notice.kind, message: notice.text).hint != nil)

        // Ordering: the detail must arrive BEFORE the close. A client folds
        // `agent_end` into "idle", so anything after it belongs to nothing.
        let noticeIndex = try #require(events.firstIndex { if case .notice = $0 { true } else { false } })
        let closeIndex = try #require(events.firstIndex { if case .agentEnd = $0 { true } else { false } })
        #expect(noticeIndex < closeIndex)
        if case .agentEnd(let reason) = events[closeIndex] { #expect(reason == "errored") }
    }

    @Test("A run that cannot even start says why, then closes")
    func preTurnFailureIsNarrated() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, streamFn: Self.answering("fine"))
        let session = try await runtime.createSession()

        // One good turn, so the session file has a leaf to walk from.
        let warmUp = try await runtime.sink(for: session.id).subscribe()
        try await runtime.startRun(sessionID: session.id, prompt: "hello", attachments: [])
        _ = await collectToClose(warmUp)

        // Now corrupt the transcript on disk. The next turn's context build reads
        // it and throws — a failure that happens BEFORE `agent_start`, so the loop
        // never runs and cannot narrate anything itself.
        try Data("{ this is not a session entry\n".utf8)
            .write(to: URL(fileURLWithPath: session.path))

        let subscription = try await runtime.sink(for: session.id).subscribe()
        try await runtime.startRun(sessionID: session.id, prompt: "and again", attachments: [])
        let events = await collectToClose(subscription)

        let errorNotices = notices(events).filter { $0.level == .error }
        #expect(errorNotices.count == 1, "a run that could not start said nothing")
        #expect(!(errorNotices.first?.text.isEmpty ?? true))
        // Before the close, for the same reason as above.
        let noticeIndex = try #require(events.firstIndex { if case .notice = $0 { true } else { false } })
        let closeIndex = try #require(events.firstIndex { if case .agentEnd = $0 { true } else { false } })
        #expect(noticeIndex < closeIndex)
    }

    @Test("An aborted run is not narrated as a failure")
    func cancellationIsNotAnError() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        // A stream that never finishes, so the run is still in flight when it is
        // cancelled.
        let runtime = makeRuntime(dirs, streamFn: { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: "test-model")))
            }
        })
        let session = try await runtime.createSession()
        let subscription = try await runtime.sink(for: session.id).subscribe()
        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        try await Task.sleep(for: .milliseconds(200))
        _ = try await runtime.abort(sessionID: session.id)
        let events = await collectToClose(subscription)

        // An interrupt drawn in red as a failure is a bug report the user files.
        #expect(notices(events).filter { $0.level == .error }.isEmpty,
                "an abort produced an error notice")
        let close = events.last { if case .agentEnd = $0 { true } else { false } }
        if case .agentEnd(let reason)? = close { #expect(reason == "aborted") }
    }

    @Test("A successful run narrates nothing")
    func successIsSilent() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let runtime = makeRuntime(dirs, streamFn: Self.answering("all good"))
        let session = try await runtime.createSession()
        let subscription = try await runtime.sink(for: session.id).subscribe()
        try await runtime.startRun(sessionID: session.id, prompt: "go", attachments: [])
        let events = await collectToClose(subscription)
        #expect(notices(events).isEmpty)
    }
}
