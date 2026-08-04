// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The gateway credential, chased through every surface the compiled binary
// actually writes to.
//
// Three separate leaks are pinned here, each with its own history:
//
//  1. A LiteLLM 401 body echoes the key it was handed. That body becomes
//     `AssistantMessage.errorMessage`, which print mode writes to stderr AND the
//     persistence sink writes to the session JSONL — where it stays forever, in a
//     file a user will happily paste into a bug report. The redaction itself lives
//     down in DoMoLLM/DoMoAgent; this is the end-to-end proof that it reaches the
//     user's surfaces rather than being applied to a value nobody prints.
//
//  2. `ToolContext.environment` inherits, so `bash` — a tool the model chooses to
//     call — could read `DOMOCODE_API_KEY` with a one-word command.
//
//  3. The MCP child scrub was a hardcoded three-name list, so a user who set
//     `"apiKeyEnv": "MY_GATEWAY_KEY"` (a supported, tested feature) handed that
//     key intact to every configured MCP server.
//
// Every assertion here is paired with a CONTROL that must hold: the gateway's
// prose reached the user, the transcript really was written, the tool child kept
// the rest of its environment. Without those, "the secret is absent" is equally
// true of a binary that produced no output at all.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct SecretHygieneEndToEndTests {

    // MARK: Scripted SSE

    private static let finalTextTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"done."},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

        data: [DONE]


        """#

    /// A `bash` call that prints the gateway credential if it can see it, plus a
    /// control variable that proves the rest of the environment is still inherited.
    private static func bashTurn(command: String) -> String {
        #"""
        data: {"id":"chatcmpl-0","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_bash_1","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-0","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\": \"\#(command)\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-0","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"chatcmpl-0","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":4,"total_tokens":24}}

        data: [DONE]


        """#
    }

    // MARK: 1 — the gateway's error body

    /// LiteLLM's 401 body quotes the key it received. Nothing the user can reach —
    /// stdout, stderr, or the durable transcript — may reproduce it.
    ///
    /// The needle is shaped like a real key (`sk-` followed by a long run), which
    /// is what the pattern rules key on; it is deliberately NOT the value of
    /// `DOMOCODE_API_KEY`, so a literal-registry-only implementation cannot pass
    /// this by accident.
    @Test
    func aGatewayErrorBodyNeverPutsTheKeyOnAnyUserSurface() throws {
        let leaked = "sk-leakedabcdefghij0123456789"
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: (
                status: 401,
                reason: "Unauthorized",
                body: #"""
                    {"error":{"message":"Authentication Error, invalid proxy server token passed. Received key=\#(leaked) for team default","type":"auth_error","code":"401"}}
                    """#
            )
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        // The run failed on the 401 and did not retry it (401 never clears
        // itself). The one bounded recovery diagnostic is a separate request;
        // it never replays the original turn.
        #expect(result.exitCode == 1, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 2)

        // CONTROL: the gateway's own prose DID reach the user. Without this the
        // "no secret on stderr" expectation below would also pass for a binary
        // that printed nothing at all.
        #expect(
            result.standardError.contains("Authentication Error"),
            "the gateway's message never reached stderr: \(result.standardError)"
        )
        #expect(!result.standardError.contains(leaked), "the key leaked to stderr: \(result.standardError)")
        #expect(!result.standardOutput.contains(leaked), "the key leaked to stdout: \(result.standardOutput)")

        // The durable surface. Every file the run wrote anywhere under its isolated
        // tree is checked, because the session directory is the CONFIG directory's
        // `sessions/` and a leak into any neighbouring file would be just as bad.
        let written = Self.regularFiles(under: workspace.root)
        #expect(!written.isEmpty, "the run wrote no files at all")
        var transcriptCarriedTheError = false
        for file in written {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!text.contains(leaked), "the key was persisted to \(file.lastPathComponent)")
            if file.pathExtension == "jsonl", text.contains("Authentication Error") {
                transcriptCarriedTheError = true
            }
        }
        // CONTROL: the failing turn's message really was persisted, so the loop
        // above inspected the bytes that would have carried the key.
        #expect(
            transcriptCarriedTheError,
            "no session JSONL recorded the failing turn's message; the absence check above proves nothing"
        )
    }

    /// The other half of leak 1: a key the PATTERN rules cannot possibly recognize.
    ///
    /// `sk-mock-test-key` is what ``runDomo(arguments:workspace:environment:)`` puts
    /// in `DOMOCODE_API_KEY`, and the `sk-` rule requires sixteen further run
    /// characters — this has thirteen — so no regex will ever fire on it. The only
    /// thing that can scrub it is the literal registry, which means this test fails
    /// unless the command actually hands `configuration.apiKey` to
    /// ``DoMoCore/Redaction/register(_:)`` at load time AND the error path actually
    /// consults the vault. It is the end-to-end proof of that handshake, which spans
    /// two modules that never call each other.
    @Test
    func theProcessesOwnKeyIsScrubbedEvenWhenNoPatternCouldMatchIt() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [Self.finalTextTurn],
            refuseWith: (
                status: 401,
                reason: "Unauthorized",
                body: #"""
                    {"error":{"message":"Authentication Error, invalid proxy server token passed. Received key=sk-mock-test-key for team default","type":"auth_error","code":"401"}}
                    """#
            )
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let result = try runDomo(
            arguments: ["-p", "hello", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )

        #expect(result.exitCode == 1, "stderr: \(result.standardError)")
        // CONTROL: the surrounding prose survived, so the message was not simply
        // dropped on the floor.
        #expect(
            result.standardError.contains("Authentication Error"),
            "the gateway's message never reached stderr: \(result.standardError)"
        )
        #expect(result.standardError.contains("for team default"), "stderr: \(result.standardError)")
        // The key itself, in whole or in part, is gone.
        #expect(!result.standardError.contains("mock-test-key"), "stderr: \(result.standardError)")
        #expect(!result.standardOutput.contains("mock-test-key"), "stdout: \(result.standardOutput)")

        for file in Self.regularFiles(under: workspace.root) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            #expect(!text.contains("mock-test-key"), "the key was persisted to \(file.lastPathComponent)")
        }
    }

    // MARK: 2 — the bash tool's environment

    /// A model that runs `env` must not be handed the gateway key.
    @Test
    func theBashToolCannotReadTheGatewayCredential() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                Self.bashTurn(command: "echo KEY=${DOMOCODE_API_KEY:-ABSENT} CONTROL=${DOMOCODE_CONTROL_VAR:-ABSENT}"),
                Self.finalTextTurn,
            ]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        // `--yolo`: bash resolves to `ask` under the Phase-8 baseline and headless
        // has no human to prompt, so without this the command is refused and never
        // observes any environment at all.
        let result = try runDomo(
            arguments: ["-p", "read the env", "--model", "mock-model", "--base-url", gateway.baseURL, "--yolo"],
            workspace: workspace,
            environment: ["DOMOCODE_CONTROL_VAR": "inherited"]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 2)

        let output = Self.toolResultContent(gateway.requests[1].body)
        // CONTROL: the child still inherits everything that is NOT a credential.
        // A scrub that emptied the whole environment would "pass" the leak check.
        #expect(output.contains("CONTROL=inherited"), "tool result: \(output)")
        #expect(output.contains("KEY=ABSENT"), "bash could still read DOMOCODE_API_KEY: \(output)")
        #expect(!output.contains("sk-mock-test-key"), "tool result: \(output)")
    }

    /// The same, for the variable a settings file named itself. This is the leg the
    /// hardcoded three-name scrub list missed entirely.
    @Test
    func theBashToolCannotReadACustomApiKeyEnvVariable() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: [
                Self.bashTurn(command: "echo KEY=${MY_GATEWAY_KEY:-ABSENT} CONTROL=${DOMOCODE_CONTROL_VAR:-ABSENT}"),
                Self.finalTextTurn,
            ]
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        // USER settings, so no project-trust gate is involved in what this proves.
        try """
            { "apiKeyEnv": "MY_GATEWAY_KEY" }
            """.write(
            to: workspace.configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try runDomo(
            arguments: ["-p", "read the env", "--model", "mock-model", "--base-url", gateway.baseURL, "--yolo"],
            workspace: workspace,
            environment: [
                "MY_GATEWAY_KEY": "sk-customgatewayabcdefghij0123456789",
                "DOMOCODE_CONTROL_VAR": "inherited",
            ]
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 2)

        let output = Self.toolResultContent(gateway.requests[1].body)
        #expect(output.contains("CONTROL=inherited"), "tool result: \(output)")
        #expect(output.contains("KEY=ABSENT"), "bash could read the configured apiKeyEnv variable: \(output)")
        #expect(!output.contains("sk-customgateway"), "tool result: \(output)")
    }

    // MARK: 3 — the MCP child's environment

    /// An MCP server that dumps its own environment on startup. Minimal but real
    /// stdio JSON-RPC, so the connect succeeds and the run is a normal one.
    private static func envDumpServer(dumpPath: String) -> String {
        #"""
        import sys, json, os
        with open(r"\#(dumpPath)", "w") as handle:
            handle.write("\n".join("%s=%s" % (k, v) for k, v in os.environ.items()))
        def send(o):
            sys.stdout.write(json.dumps(o)+"\n"); sys.stdout.flush()
        for line in sys.stdin:
            line=line.strip()
            if not line: continue
            m=json.loads(line); method=m.get("method"); mid=m.get("id")
            if method=="initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"envdump","version":"1"}}})
            elif method=="tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"noop","description":"No-op","inputSchema":{"type":"object","properties":{}}}]}})
            elif method=="ping":
                send({"jsonrpc":"2.0","id":mid,"result":{}})
        """#
    }

    @Test
    func anMcpServerNeverSeesTheGatewayCredentialUnderAnyName() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }

        let gateway = try MockGateway(chatCompletionBodies: [Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let dump = workspace.root.appendingPathComponent("mcp-env-dump.txt")
        let serverPath = workspace.workDirectory.appendingPathComponent("env_dump_server.py")
        try Self.envDumpServer(dumpPath: dump.path).write(to: serverPath, atomically: true, encoding: .utf8)

        try """
            {
              "apiKeyEnv": "MY_GATEWAY_KEY",
              "mcpServers": { "envdump": { "command": ["/usr/bin/python3", "\(serverPath.path)"] } }
            }
            """.write(
            to: workspace.configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = try runDomo(
            arguments: ["-p", "hi", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            environment: ["MY_GATEWAY_KEY": "sk-customgatewayabcdefghij0123456789"]
        )
        #expect(result.exitCode == 0, "stderr: \(result.standardError)")

        // CONTROL: the server really was spawned and really did dump a plausible
        // environment. Both halves matter — an unspawned server trivially "leaks
        // nothing", and so does an empty file.
        let dumped = (try? String(contentsOf: dump, encoding: .utf8)) ?? ""
        #expect(
            !dumped.isEmpty,
            "the MCP server never started, so it proved nothing. stderr: \(result.standardError)"
        )
        #expect(dumped.contains("PATH="), "the dump is not an environment: \(dumped.prefix(200))")

        #expect(
            !dumped.contains("MY_GATEWAY_KEY"),
            "the configured apiKeyEnv variable reached the MCP child"
        )
        #expect(!dumped.contains("sk-customgateway"), "the gateway key reached the MCP child")
        #expect(!dumped.contains("DOMOCODE_API_KEY"), "the built-in credential variable reached the MCP child")
    }

    // MARK: Helpers

    /// Every regular file under `root`, recursively.
    private static func regularFiles(under root: URL) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile { files.append(url) }
        }
        return files
    }

    /// The content of the first tool-role message in a chat-completions request
    /// body — the tool RESULT fed back to the model, as distinct from the tool-call
    /// arguments the assistant message echoes (which contain the command text and
    /// would make a naive substring check pass for free).
    private static func toolResultContent(_ body: String) -> String {
        guard let json = try? JSONValue(parsing: body), let messages = json["messages"]?.arrayValue
        else { return "" }
        for message in messages where message["role"]?.stringValue == "tool" {
            return message["content"]?.stringValue ?? ""
        }
        return ""
    }
}
