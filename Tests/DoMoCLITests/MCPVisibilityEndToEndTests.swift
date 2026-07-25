// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 8d, through the compiled binary: an MCP tool a `permission` deny rule blocks is
// HIDDEN from the model — it appears in neither the system-prompt tool list nor the
// advertised `tools` array sent to the gateway. Skipped where /usr/bin/python3 is absent.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct MCPVisibilityEndToEndTests {
    private static let plainTurn = #"""
        data: {"id":"c","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":null}]}

        data: {"id":"c","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"c","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}

        data: [DONE]


        """#

    private static let fixture = #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o)+"\n"); sys.stdout.flush()
        for line in sys.stdin:
            line=line.strip()
            if not line: continue
            m=json.loads(line); method=m.get("method"); mid=m.get("id")
            if method=="initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"f","version":"1"}}})
            elif method=="tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[
                    {"name":"echo","description":"Echo","inputSchema":{"type":"object","properties":{}}},
                    {"name":"danger","description":"Dangerous","inputSchema":{"type":"object","properties":{}}}]}})
            elif method=="ping":
                send({"jsonrpc":"2.0","id":mid,"result":{}})
        """#

    @Test
    func deniedMcpToolIsHiddenFromTheModel() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }

        let gateway = try MockGateway(chatCompletionBodies: [Self.plainTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let serverPath = workspace.workDirectory.appendingPathComponent("mcp_server.py")
        try Self.fixture.write(to: serverPath, atomically: true, encoding: .utf8)

        // USER settings (no project trust needed): configure the server and deny one tool.
        let settings = """
            {
              "mcpServers": { "fixture": { "command": ["/usr/bin/python3", "\(serverPath.path)"] } },
              "permission": { "fixture_danger": "deny" }
            }
            """
        try settings.write(
            to: workspace.configDirectory.appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8
        )

        let result = try runDomo(
            arguments: ["-p", "hi", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        let body = try #require(gateway.requests.first?.body)
        #expect(body.contains("fixture_echo"), "the allowed MCP tool should reach the model")
        #expect(!body.contains("fixture_danger"), "the deny'd MCP tool must be hidden from the model")
    }
}
