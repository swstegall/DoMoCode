// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Project trust, exercised through the compiled binary: a directory carrying a
// .domocode/settings.json is refused in non-interactive mode until --trust is
// given, after which the decision is remembered and later runs proceed silently.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct TrustEndToEndTests {

    private static let plainTurn = #"""
        data: {"id":"chatcmpl-t","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":null}]}

        data: {"id":"chatcmpl-t","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-t","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}

        data: [DONE]


        """#

    /// Writes `<workDirectory>/.domocode/settings.json`, the file that makes a
    /// project require trust.
    private func writeProjectSettings(_ workspace: Workspace) throws {
        let projectDir = workspace.workDirectory.appendingPathComponent(".domocode", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try "{}".write(to: projectDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    @Test
    func untrustedProjectIsRefusedThenTrustedWithFlagAndRemembered() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.plainTurn, Self.plainTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try writeProjectSettings(workspace)

        // 1) No trust recorded, no --trust: refuse before any model call.
        let refused = try runDomocode(
            arguments: ["-p", "hi", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(refused.exitCode != 0)
        #expect(refused.standardOutput.isEmpty)
        #expect(refused.standardError.lowercased().contains("trust"))
        #expect(gateway.requestCount == 0, "a refused run must not reach the gateway")

        // 2) --trust: the run proceeds and records the decision.
        let trusted = try runDomocode(
            arguments: ["-p", "hi", "--model", "mock-model", "--base-url", gateway.baseURL, "--trust"],
            workspace: workspace
        )
        #expect(trusted.exitCode == 0, "stderr: \(trusted.standardError)")
        #expect(gateway.requestCount == 1)

        let trustFile = workspace.configDirectory.appendingPathComponent("trust.json")
        #expect(FileManager.default.fileExists(atPath: trustFile.path), "trust.json should have been written")

        // 3) The recorded decision means a later run needs no flag.
        let remembered = try runDomocode(
            arguments: ["-p", "hi", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(remembered.exitCode == 0, "stderr: \(remembered.standardError)")
        #expect(gateway.requestCount == 2)
    }
}
