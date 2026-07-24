// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Runtime-level tests for the session-containment fixes from the adversarial
// review: resuming a live session must not stand up a second harness over the
// same file, and `resume` must not open an arbitrary on-disk path.

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct ServerRuntimeTests {

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

    private func makeRuntime(_ dirs: Dirs) -> ServerRuntime {
        ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            maxTurns: 5,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path
        ))
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
}
