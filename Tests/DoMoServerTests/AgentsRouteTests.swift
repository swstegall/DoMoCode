// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `GET /agents`, the palette's third catalogue beside `/commands` and
// `/session/{id}/tools`, against a live server on a loopback port.
//
// Two properties are load-bearing and neither is observable from
// `ServerRuntime.agents()` alone. The route must sit inside the router-wide
// bearer gate — a listing of a project's personas is not public to every local
// process that can reach loopback — and the payload must carry no persona
// system prompt: that text steers the model, only the serving process needs it,
// and a route that shipped it would put an injection surface on the socket. A
// unit test of the projection would pass while either invariant was broken.

import AsyncHTTPClient
import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoServer
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct AgentsRouteTests {

    private static let token = "agents-route-token"

    /// A string no other field of the payload could contain, so a `contains`
    /// check is evidence rather than coincidence.
    private static let secretPrompt = "SECRET-PERSONA-PROMPT-must-not-be-served"
    private static let secretSkillBody = "SECRET-SKILL-BODY-requires-explicit-opt-in"

    private static let workspace = PromptWorkspace(
        baseSystemPrompt: "base",
        commands: .builtIn,
        skills: [
            PromptSkill(
                name: "review",
                description: "Review the current changes.",
                keywords: ["diff", "review"],
                body: Self.secretSkillBody,
                source: .project,
                disableModelInvocation: true,
                toolAllowlist: ["read"],
                argumentHint: "focus"
            ),
        ],
        agents: AgentProfileRegistry(profiles: [
            AgentProfile(
                name: "auditor",
                description: "Audit the diff.",
                systemPrompt: Self.secretPrompt,
                mode: .review,
                source: .project
            ),
            AgentProfile(
                name: "scout",
                systemPrompt: Self.secretPrompt,
                mode: .plan,
                source: .user
            ),
        ])
    )

    // MARK: - Routes

    @Test("GET /agents projects the workspace personas and leaves their prompts behind")
    func agentsRouteProjectsProfiles() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, workspace: Self.workspace)

        try await withServer(server) { http, port in
            let reply = try await send(http, port, "/agents")
            #expect(reply.status == 200, "GET /agents answered \(reply.status)")

            // `AgentProfileRegistry` sorts by name, so this equality pins the
            // order as well as every projected field, including the `nil`
            // description that a profile without one must keep.
            let summaries = try JSONDecoder().decode([AgentProfileSummary].self, from: reply.body)
            #expect(summaries == [
                AgentProfileSummary(
                    name: "auditor",
                    description: "Audit the diff.",
                    mode: "review",
                    source: "project"
                ),
                AgentProfileSummary(name: "scout", mode: "plan", source: "user"),
            ])

            let text = String(decoding: reply.body, as: UTF8.self)
            #expect(!text.contains(Self.secretPrompt), "a persona system prompt reached the wire: \(text)")
            #expect(!text.contains("systemPrompt"), "the payload carries a systemPrompt key: \(text)")
            #expect(!text.contains("permissionRules"), "the payload carries permission policy: \(text)")
            #expect(!text.contains("toolAllowlist"), "the payload carries a tool allow-list: \(text)")
        }
    }

    /// A runtime built without dotfiles still resolves the built-in personas by
    /// name for delegated work, so the route reports them rather than claiming
    /// nothing is selectable — the same fallback `/commands` makes.
    @Test("A runtime with no prompt workspace answers with the built-in personas")
    func agentsRouteFallsBackToBuiltIns() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, workspace: nil)

        try await withServer(server) { http, port in
            let reply = try await send(http, port, "/agents")
            #expect(reply.status == 200, "GET /agents answered \(reply.status)")

            let summaries = try JSONDecoder().decode([AgentProfileSummary].self, from: reply.body)
            #expect(summaries.map(\.name) == AgentProfileRegistry.builtIn.profiles.map(\.name))
            #expect(summaries.contains { $0.name == "explore" && $0.mode == "plan" })
            #expect(summaries.allSatisfy { $0.source == "builtin" })

            // Two built-ins ship a non-empty prompt of their own; the fallback
            // path must strip it exactly as the workspace path does.
            let text = String(decoding: reply.body, as: UTF8.self)
            #expect(!text.contains("Inspect the workspace carefully"), "a built-in prompt reached the wire: \(text)")
        }
    }

    @Test("GET /agents is behind the bearer gate")
    func agentsRouteIsGuarded() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, workspace: Self.workspace)

        try await withServer(server) { http, port in
            for token in [nil, "wrong"] as [String?] {
                let reply = try await send(http, port, "/agents", token: token)
                #expect(reply.status == 401, "token \(token ?? "<none>") -> \(reply.status)")
                #expect(
                    !String(decoding: reply.body, as: UTF8.self).contains("auditor"),
                    "a refused request was still told the persona names"
                )
            }
        }
    }

    @Test("GET /skills omits bodies unless explicitly requested")
    func skillsRouteProjectsMetadataAndOptInBodies() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, workspace: Self.workspace)

        try await withServer(server) { http, port in
            let metadataReply = try await send(http, port, "/skills")
            #expect(metadataReply.status == 200)
            let metadata = try JSONDecoder().decode([SkillDescriptor].self, from: metadataReply.body)
            #expect(metadata == [
                SkillDescriptor(
                    name: "review",
                    description: "Review the current changes.",
                    keywords: ["diff", "review"],
                    argumentHint: "focus",
                    disableModelInvocation: true,
                    toolAllowlist: ["read"],
                    source: "project"
                ),
            ])
            let metadataText = String(decoding: metadataReply.body, as: UTF8.self)
            #expect(!metadataText.contains(Self.secretSkillBody))
            #expect(!metadataText.contains("\"body\""))

            let bodyReply = try await send(http, port, "/skills?include=body")
            #expect(bodyReply.status == 200)
            let withBody = try JSONDecoder().decode([SkillDescriptor].self, from: bodyReply.body)
            #expect(withBody.first?.body == Self.secretSkillBody)
        }
    }

    @Test("GET /skills is behind the bearer gate")
    func skillsRouteIsGuarded() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let server = makeServer(dirs, workspace: Self.workspace)

        try await withServer(server) { http, port in
            let reply = try await send(http, port, "/skills", token: "wrong")
            #expect(reply.status == 401)
            #expect(!String(decoding: reply.body, as: UTF8.self).contains("review"))
        }
    }

    // MARK: - Helpers

    private struct Dirs {
        let root: URL
        let cwd: URL
        let sessions: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("domo-agents-route-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [cwd, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private struct Reply {
        let status: UInt
        let body: Data
    }

    private func makeServer(_ dirs: Dirs, workspace: PromptWorkspace?) -> DoMoServer {
        let runtime = ServerRuntime(config: .init(
            systemPrompt: "test",
            tools: [],
            model: "test-model",
            streamFn: { _ in AsyncThrowingStream { $0.finish() } },
            toolExecution: .sequential,
            maxTurns: 1,
            sessionDirectory: FilePath(dirs.sessions.path),
            cwd: dirs.cwd.path,
            promptWorkspace: workspace
        ))
        return DoMoServer(
            runtime: runtime,
            options: .init(host: "127.0.0.1", port: 0, token: Self.token, heartbeatSeconds: 3600)
        )
    }

    private func withServer(
        _ server: DoMoServer,
        _ body: (HTTPClient, Int) async throws -> Void
    ) async throws {
        let (portStream, portCont) = AsyncStream<Int>.makeStream()
        let serverTask = Task { try await server.run(onReady: { port in portCont.yield(port); portCont.finish() }) }
        var portIterator = portStream.makeAsyncIterator()
        let port = await portIterator.next() ?? 0
        #expect(port > 0)

        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        var thrown: (any Error)?
        do {
            try await body(http, port)
        } catch {
            thrown = error
        }
        try await http.shutdown()
        serverTask.cancel()
        _ = try? await serverTask.value
        if let thrown { throw thrown }
    }

    private func send(
        _ http: HTTPClient,
        _ port: Int,
        _ path: String,
        token: String? = AgentsRouteTests.token
    ) async throws -> Reply {
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
        request.method = .GET
        if let token { request.headers.add(name: "authorization", value: "Bearer \(token)") }
        let response = try await http.execute(request, timeout: .seconds(30))
        var buffer = try await response.body.collect(upTo: 1 << 20)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        return Reply(status: response.status.code, body: Data(bytes))
    }
}
