// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoGit
import DoMoServer
import Foundation
import Synchronization
import SystemPackage
import Testing

private final class RecordingDiffSource: DiffSource, @unchecked Sendable {
    let value: GitDiff
    let headValue: String?
    private let calls = Mutex<[String]>([])

    init(value: GitDiff, head: String? = "head-sha") {
        self.value = value
        self.headValue = head
    }

    var recordedCalls: [String] { calls.withLock { $0 } }

    func head(at _: FilePath) async throws(DoMoError) -> String? {
        calls.withLock { $0.append("head") }
        return headValue
    }

    func diff(
        from base: String,
        at _: FilePath,
        includeUntracked _: Bool
    ) async throws(DoMoError) -> GitDiff {
        calls.withLock { $0.append("diff:\(base)") }
        return value
    }

    func workingTreeDiff(at _: FilePath, includeUntracked _: Bool) async throws(DoMoError) -> GitDiff {
        calls.withLock { $0.append("working-tree") }
        return value
    }

    func restore(path: String, from base: String, at _: FilePath) async throws(DoMoError) {
        calls.withLock { $0.append("restore:\(path):\(base)") }
    }
}

@Suite(.serialized)
struct DiffSourceTests {
    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-diff-source-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func value() -> GitDiff {
        GitDiff(
            base: "head-sha",
            branch: "main",
            files: [GitDiffFile(path: "Sources/App.swift", status: .modified)],
            patch: "patch"
        )
    }

    @Test("server diff and restore routes use the configured DiffSource")
    func runtimeUsesDiffSource() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let source = RecordingDiffSource(value: value())
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            maxTurns: 1,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            diffSource: source
        ))

        let session = try await runtime.createSession()
        let working = try await runtime.diff(sessionID: session.id)
        #expect(working.patch == "patch")
        let explicit = try await runtime.diff(sessionID: session.id, base: "other-base")
        #expect(explicit.patch == "patch")
        try await runtime.restoreDiffFile(sessionID: session.id, path: "Sources/App.swift")

        #expect(source.recordedCalls == ["working-tree", "diff:other-base", "head", "restore:Sources/App.swift:head-sha"])
    }
}
