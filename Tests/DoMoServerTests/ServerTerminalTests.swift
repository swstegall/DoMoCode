// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore
import DoMoServer
import DoMoTermIO
import Foundation
import SystemPackage
import Testing

@Suite("server-owned terminals", .serialized)
struct ServerTerminalTests {

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("domo-server-terminal-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("The runtime owns terminal ids and preserves input across replay activation")
    func terminalBelongsToSession() async throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let service = PTYService(maximumRetainedBytes: 1_024)
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            terminalService: service
        ))

        let owner = try await runtime.createSession()
        let other = try await runtime.createSession()
        let terminalID = try await runtime.startTerminal(
            sessionID: owner.id,
            configuration: PTYLaunchConfiguration(
                command: ["/bin/sh", "-c", "read line; printf 'accepted:%s' \"$line\""],
                workingDirectory: dirs.cwd.path
            )
        )
        let attachment = try await runtime.beginTerminalAttach(
            sessionID: owner.id,
            terminalID: terminalID
        )
        let stream = try await runtime.activateTerminal(
            sessionID: owner.id,
            terminalID: terminalID,
            attachmentID: attachment.id
        )
        #expect(try await runtime.writeTerminal(
            sessionID: owner.id,
            terminalID: terminalID,
            bytes: Array("from-server\n".utf8)
        ))

        var output = Self.outputBytes(attachment.replay)
        for await event in stream {
            if case .output(_, let bytes) = event { output.append(contentsOf: bytes) }
        }
        #expect(String(decoding: output, as: UTF8.self).contains("accepted:from-server"))

        await #expect(throws: ServerRuntimeError.terminalNotFound) {
            _ = try await runtime.terminalSnapshot(sessionID: other.id, terminalID: terminalID)
        }
        await runtime.shutdown()
    }

    private static func outputBytes(_ events: [PTYEvent]) -> [UInt8] {
        events.reduce(into: [UInt8]()) { result, event in
            if case .output(_, let bytes) = event { result.append(contentsOf: bytes) }
        }
    }
}
