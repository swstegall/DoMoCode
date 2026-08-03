// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import DoMoTools
import Testing

@Suite("interactive terminal tool", .serialized)
struct InteractiveTerminalToolTests {

    @Test("A headless context refuses instead of starting an unreachable child")
    func refusesWithoutInputChannel() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let result = try await InteractiveTerminalTool().execute(
            ["action": "start", "command": "printf should-not-run"],
            in: fixture.context
        )
        #expect(result.isError)
        #expect(result.text.contains("no live terminal input channel"))
    }

    @Test("The inline provider keeps a PTY session addressable across actions")
    func providerRoundTrip() async throws {
        let provider = PTYInteractiveTerminalProvider()
        let started = try await provider.execute(.init(
            action: .start,
            command: "read line; printf 'accepted:%s' \"$line\"",
            workingDirectory: "/tmp",
            environment: .inherit
        ))
        let id = try #require(started.id)
        #expect(await provider.writeActive(Array("from-user\n".utf8)))
        try await Task.sleep(for: .milliseconds(30))
        let read = try await provider.execute(.init(
            action: .read,
            id: id,
            workingDirectory: "/tmp",
            environment: .inherit
        ))
        #expect(read.screen.contains("accepted:from-user"))
        await provider.shutdown()
    }
}
