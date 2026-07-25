// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The hand-rolled MCP client, exercised against a real fixture stdio server (a tiny
// Python script speaking MCP 2025-06-18). Nothing is stubbed: an actual subprocess is
// spawned, the initialize handshake + tools/list run, and tools are called over
// newline-delimited JSON-RPC. Skipped only where /usr/bin/python3 is absent.

import DoMoAgent
import DoMoCore
import Foundation
import Testing

@testable import DoMoMCP

@Suite("MCP client (fixture server)")
struct MCPClientTests {
    /// A minimal MCP stdio server: initialize, tools/list (echo/boom/slow), tools/call,
    /// ping. `slow` never responds (to exercise the per-request timeout).
    static let fixture = #"""
        import sys, json, os
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        for line in sys.stdin:
            line = line.strip()
            if not line: continue
            m = json.loads(line); method = m.get("method"); mid = m.get("id")
            if method == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"fixture","version":"1.0"}}})
            elif method == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[
                    {"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}},
                    {"name":"boom","description":"Errors","inputSchema":{"type":"object","properties":{}}},
                    {"name":"slow","description":"Never responds","inputSchema":{"type":"object","properties":{}}},
                    {"name":"getenv","description":"Read an env var","inputSchema":{"type":"object","properties":{"name":{"type":"string"}}}},
                    {"name":"quit","description":"Reply then exit","inputSchema":{"type":"object","properties":{}}}]}})
            elif method == "tools/call":
                p = m.get("params",{}); name = p.get("name"); args = p.get("arguments",{})
                if name == "echo":
                    send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"echo: "+str(args.get("text",""))}],"isError":False}})
                elif name == "boom":
                    send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"kaboom"}],"isError":True}})
                elif name == "slow":
                    pass
                elif name == "getenv":
                    send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":os.environ.get(args.get("name",""), "<absent>")}],"isError":False}})
                elif name == "quit":
                    send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"bye"}],"isError":False}})
                    sys.stdout.flush(); sys.exit(0)
                else:
                    send({"jsonrpc":"2.0","id":mid,"error":{"code":-32602,"message":"Unknown tool"}})
            elif method == "ping":
                send({"jsonrpc":"2.0","id":mid,"result":{}})
        """#

    private func fixtureConfig(timeoutMS: Int = 4000) throws -> (dir: URL, config: MCPServerConfig)? {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("domo-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("server.py")
        try Self.fixture.write(to: script, atomically: true, encoding: .utf8)
        return (dir, MCPServerConfig(command: ["/usr/bin/python3", script.path], timeout: timeoutMS))
    }

    private func tool(_ tools: [any AgentTool], _ name: String) -> (any AgentTool)? {
        tools.first { $0.definition.name == name }
    }

    @Test("Connect, discover namespaced tools, and call one")
    func discoverAndCall() async throws {
        guard let (dir, config) = try fixtureConfig() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = MCPManager()
        let tools = await manager.connect(servers: ["srv": config], workspaceDirectory: dir.path)
        defer { Task { await manager.shutdown() } }

        // Tools are namespaced by server and have a normalized object schema.
        #expect(Set(tools.map(\.definition.name)) == ["srv_echo", "srv_boom", "srv_slow", "srv_getenv", "srv_quit"])
        let echo = try #require(self.tool(tools, "srv_echo"))
        #expect(echo.definition.description == "Echo text")

        // A successful call maps text content to the output.
        let ok = try await echo.execute(.object(["text": .string("hi")]))
        #expect(ok.output == "echo: hi")
        #expect(!ok.isError)
    }

    @Test("A tool's isError result is surfaced as an error tool result, not a throw")
    func toolError() async throws {
        guard let (dir, config) = try fixtureConfig() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MCPManager()
        let tools = await manager.connect(servers: ["srv": config], workspaceDirectory: dir.path)
        defer { Task { await manager.shutdown() } }

        let boom = try #require(self.tool(tools, "srv_boom"))
        let result = try await boom.execute(.object([:]))
        #expect(result.isError)
        #expect(result.output == "kaboom")
    }

    @Test("A tool that never responds times out into an error result")
    func timeout() async throws {
        guard let (dir, config) = try fixtureConfig(timeoutMS: 500) else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MCPManager()
        let tools = await manager.connect(servers: ["srv": config], workspaceDirectory: dir.path)
        defer { Task { await manager.shutdown() } }

        let slow = try #require(self.tool(tools, "srv_slow"))
        let result = try await slow.execute(.object([:]))
        #expect(result.isError)   // timed out -> error result, not a hang
    }

    @Test("A server that fails to spawn is isolated, not fatal")
    func spawnFailureIsolated() async {
        let manager = MCPManager()
        let bad = MCPServerConfig(command: ["/nonexistent/definitely-not-a-real-binary-xyz"], timeout: 500)
        let tools = await manager.connect(servers: ["bad": bad], workspaceDirectory: "/tmp")
        #expect(tools.isEmpty)   // logged + skipped, no throw
        await manager.shutdown()
    }

    @Test("A disabled server is never spawned")
    func disabledSkipped() async throws {
        guard let (dir, base) = try fixtureConfig() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        var disabled = base
        disabled.enabled = false
        let manager = MCPManager()
        let tools = await manager.connect(servers: ["srv": disabled], workspaceDirectory: dir.path)
        #expect(tools.isEmpty)
        await manager.shutdown()
    }

    @Test("A server with an empty command is skipped, not a crash")
    func emptyCommandSkipped() async {
        let manager = MCPManager()
        // An empty command would trap on command[0] at spawn if it reached PersistentProcess.
        let tools = await manager.connect(servers: ["x": MCPServerConfig(command: [])], workspaceDirectory: "/tmp")
        #expect(tools.isEmpty)
        await manager.shutdown()
    }

    @Test("Sensitive env vars are scrubbed from the child; other inherited vars pass through")
    func secretsScrubbedFromChildEnv() async throws {
        guard let (dir, config) = try fixtureConfig() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        // A var present in THIS process's environment, so the child would inherit it.
        _ = unsafe setenv("DOMO_MCP_SECRET_TEST", "leaked", 1)
        defer { _ = unsafe unsetenv("DOMO_MCP_SECRET_TEST") }

        // Without scrubbing, the child inherits it.
        let m1 = MCPManager()
        let t1 = await m1.connect(servers: ["s": config], workspaceDirectory: dir.path)
        let getenv1 = try #require(self.tool(t1, "s_getenv"))
        let seen = try await getenv1.execute(.object(["name": .string("DOMO_MCP_SECRET_TEST")]))
        #expect(seen.output == "leaked")
        await m1.shutdown()

        // With the var named as sensitive, the child no longer sees it.
        let m2 = MCPManager()
        let t2 = await m2.connect(
            servers: ["s": config], workspaceDirectory: dir.path,
            sensitiveEnvKeys: ["DOMO_MCP_SECRET_TEST"]
        )
        let getenv2 = try #require(self.tool(t2, "s_getenv"))
        let scrubbed = try await getenv2.execute(.object(["name": .string("DOMO_MCP_SECRET_TEST")]))
        #expect(scrubbed.output == "<absent>")
        await m2.shutdown()
    }

    @Test("After the server exits, the next call fails fast rather than waiting out the timeout")
    func transportDeathFailsFast() async throws {
        // Long timeout: if the dead-transport path is NOT fast, the call would take ~8s.
        guard let (dir, config) = try fixtureConfig(timeoutMS: 8000) else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = MCPManager()
        let tools = await manager.connect(servers: ["srv": config], workspaceDirectory: dir.path)
        defer { Task { await manager.shutdown() } }

        // `quit` replies then exits the server, so the transport dies.
        let quit = try #require(self.tool(tools, "srv_quit"))
        _ = try await quit.execute(.object([:]))

        // Let the reader observe stdout EOF and mark the client closed.
        try await Task.sleep(for: .milliseconds(400))

        let echo = try #require(self.tool(tools, "srv_echo"))
        let start = Date()
        let result = try await echo.execute(.object(["text": .string("hi")]))
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.isError)          // transport gone -> error result
        #expect(elapsed < 4.0)           // fast-failed, nowhere near the 8s timeout
    }
}

@Suite("LineFramer")
struct LineFramerTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func strings(_ lines: [[UInt8]]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test("Multiple complete lines in one chunk")
    func multiplePerChunk() {
        var f = LineFramer(maxLineBytes: 1024)
        #expect(strings(f.feed(bytes("a\nbb\nccc\n"))) == ["a", "bb", "ccc"])
        #expect(f.finish() == nil)   // everything was newline-terminated
    }

    @Test("A line split across chunks is reassembled")
    func splitAcrossChunks() {
        var f = LineFramer(maxLineBytes: 1024)
        #expect(strings(f.feed(bytes("he"))) == [])
        #expect(strings(f.feed(bytes("ll"))) == [])
        #expect(strings(f.feed(bytes("o\nwor"))) == ["hello"])
        #expect(strings(f.feed(bytes("ld\n"))) == ["world"])
        #expect(f.finish() == nil)
    }

    @Test("Empty lines are dropped, not yielded")
    func emptyLinesDropped() {
        var f = LineFramer(maxLineBytes: 1024)
        #expect(strings(f.feed(bytes("\n\nx\n\n"))) == ["x"])
    }

    @Test("A trailing line with no newline is returned by finish()")
    func trailingUnterminated() {
        var f = LineFramer(maxLineBytes: 1024)
        #expect(strings(f.feed(bytes("done\ntail"))) == ["done"])
        #expect(f.finish().map { String(decoding: $0, as: UTF8.self) } == "tail")
    }

    @Test("A newline exactly at a chunk boundary frames cleanly")
    func newlineAtBoundary() {
        var f = LineFramer(maxLineBytes: 1024)
        #expect(strings(f.feed(bytes("line"))) == [])
        #expect(strings(f.feed(bytes("\n"))) == ["line"])
        #expect(f.finish() == nil)
    }

    @Test("Byte-by-byte feeding reassembles the same lines")
    func byteByByte() {
        var f = LineFramer(maxLineBytes: 1024)
        var out: [[UInt8]] = []
        for b in bytes("ab\nc\n") { out.append(contentsOf: f.feed([b])) }
        #expect(strings(out) == ["ab", "c"])
    }

    @Test("An unterminated line past the cap overflows and is not yielded")
    func overflow() {
        var f = LineFramer(maxLineBytes: 8)
        // 12 bytes with no newline: exceeds the 8-byte cap.
        let lines = f.feed(bytes("abcdefghijkl"))
        #expect(lines.isEmpty)
        #expect(f.overflowed)
        #expect(f.finish() == nil)   // the oversized garbage is discarded, not emitted
    }

    @Test("Complete lines before an overflow are still delivered")
    func linesThenOverflow() {
        var f = LineFramer(maxLineBytes: 8)
        let lines = f.feed(bytes("ok\n" + "abcdefghijkl"))
        #expect(strings(lines) == ["ok"])
        #expect(f.overflowed)
    }
}

@Suite("MCP tool mapping")
struct McpToolMappingTests {
    @Test("sanitize + namespacing")
    func naming() {
        #expect(McpTool.sanitize("my server!") == "my_server_")
        #expect(McpTool.namespaced(server: "gh.tools", tool: "list/prs") == "gh_tools_list_prs")
    }

    @Test("normalizeSchema forces object shape")
    func normalize() {
        let normalized = McpTool.normalizeSchema(.object(["properties": .object(["x": .object(["type": .string("string")])])]))
        #expect(normalized["type"]?.stringValue == "object")
        #expect(normalized["additionalProperties"]?.boolValue == false)
        // An absent properties defaults to {}.
        #expect(McpTool.normalizeSchema(.object([:]))["properties"]?.objectValue != nil)
    }

    @Test("normalizeSchema preserves a server's explicit additionalProperties")
    func normalizePreservesFreeForm() {
        // A free-form map tool declares additionalProperties: true — it must survive.
        let open = McpTool.normalizeSchema(.object(["type": .string("object"), "additionalProperties": .bool(true)]))
        #expect(open["additionalProperties"]?.boolValue == true)
        // A schema-typed additionalProperties is likewise not clobbered to false.
        let schemaTyped = McpTool.normalizeSchema(.object(["additionalProperties": .object(["type": .string("string")])]))
        #expect(schemaTyped["additionalProperties"]?.objectValue != nil)
    }

    @Test("uniquify de-collides duplicate tool names deterministically")
    func uniquify() {
        var used: Set<String> = []
        #expect(MCPManager.uniquify("a_b_c", into: &used) == "a_b_c")
        #expect(MCPManager.uniquify("a_b_c", into: &used) == "a_b_c_2")
        #expect(MCPManager.uniquify("a_b_c", into: &used) == "a_b_c_3")
        #expect(MCPManager.uniquify("other", into: &used) == "other")
    }

    @Test("mapResult concatenates text, decodes images, honors isError and structuredContent")
    func mapping() {
        let png = Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString()
        let ok = McpTool.mapResult(.init(
            content: [
                .object(["type": .string("text"), "text": .string("line one")]),
                .object(["type": .string("image"), "data": .string(png), "mimeType": .string("image/png")]),
                .object(["type": .string("text"), "text": .string("line two")]),
                .object(["type": .string("resource_link"), "uri": .string("file:///x")]),
            ],
            isError: false, structuredContent: nil))
        #expect(ok.output == "line one\n\nline two\n\n[resource_link content]")
        #expect(ok.images.count == 1)
        #expect(ok.images.first?.mediaType == "image/png")
        #expect(!ok.isError)

        let err = McpTool.mapResult(.init(content: [.object(["type": .string("text"), "text": .string("bad")])], isError: true, structuredContent: nil))
        #expect(err.isError)
        #expect(err.output == "bad")

        // Content-less structured result synthesizes a JSON text block.
        let structured = McpTool.mapResult(.init(content: [], isError: false, structuredContent: .object(["n": .int(1)])))
        #expect(structured.output.contains("\"n\""))
    }
}
