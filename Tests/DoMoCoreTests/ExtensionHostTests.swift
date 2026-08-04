// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

@Suite("Permissioned extension host", .serialized)
struct ExtensionHostTests {
    @Test("an extension cannot start without exact approval")
    func approvalIsRequired() async throws {
        let transport = FakeExtensionTransport(handshake: handshake())
        let host = try ExtensionHost(manifest: manifest(), transport: transport)

        await #expect(throws: ExtensionHostError.notApproved("demo-extension")) {
            try await host.start()
        }
        #expect(await transport.started == false)
        #expect(await host.snapshot().state == .stopped)
    }

    @Test("approved tools cross only the JSON-RPC transport and stay bounded")
    func startsAndInvokesApprovedTool() async throws {
        let transport = FakeExtensionTransport(handshake: handshake())
        let host = try ExtensionHost(
            manifest: manifest(
                capabilities: ["filesystem-read"],
                limits: ExtensionResourceLimits(
                    maxRuntimeMilliseconds: 500,
                    maxOutputBytes: 512,
                    maxConcurrentRequests: 1
                )
            ),
            transport: transport,
            policy: ExtensionHostPolicy(
                allowedCapabilities: ["filesystem-read"],
                limits: ExtensionResourceLimits(
                    maxRuntimeMilliseconds: 1_000,
                    maxOutputBytes: 1_024,
                    maxConcurrentRequests: 2
                )
            )
        )
        let approval = ExtensionApproval(
            extensionID: "demo-extension",
            version: "1.0.0",
            capabilities: ["filesystem-read"],
            approvedAt: "2026-01-01T00:00:00Z"
        )

        try await host.start(approval: approval)
        let entries = try await host.catalogEntries()
        #expect(entries.map(\.name) == ["echo"])
        #expect((await transport.plan)?.executablePath == "/usr/local/bin/demo-extension")

        let result = try await host.invoke(
            toolNamed: "echo",
            arguments: .object(["value": .string("ok")])
        )
        #expect(result["value"] == .string("ok"))
        #expect(await transport.methods == ["initialize", "tools/call"])
        #expect(await host.snapshot().state == .running)

        await host.stop()
        #expect(await host.snapshot().state == .stopped)
        #expect(await transport.started == false)
    }

    @Test("license, capability, and output policy refuse unsafe boundaries")
    func policyRefusesUnsafeExtension() async throws {
        let licenseTransport = FakeExtensionTransport(handshake: handshake())
        let licenseHost = try ExtensionHost(
            manifest: manifest(license: "Apache-2.0"),
            transport: licenseTransport
        )
        await #expect(throws: ExtensionHostError.licenseDenied("Apache-2.0")) {
            try await licenseHost.start(
                approval: ExtensionApproval(
                    extensionID: "demo-extension",
                    version: "1.0.0",
                    capabilities: [],
                    approvedAt: "now"
                )
            )
        }

        let capabilityTransport = FakeExtensionTransport(handshake: handshake())
        let capabilityHost = try ExtensionHost(
            manifest: manifest(capabilities: ["network"]),
            transport: capabilityTransport,
            policy: ExtensionHostPolicy(allowedCapabilities: [])
        )
        await #expect(throws: ExtensionHostError.capabilityDenied("network")) {
            try await capabilityHost.start(
                approval: ExtensionApproval(
                    extensionID: "demo-extension",
                    version: "1.0.0",
                    capabilities: ["network"],
                    approvedAt: "now"
                )
            )
        }

        let outputTransport = FakeExtensionTransport(
            handshake: handshake(),
            result: .string(String(repeating: "x", count: 200))
        )
        let outputHost = try ExtensionHost(
            manifest: manifest(
                limits: ExtensionResourceLimits(
                    maxRuntimeMilliseconds: 1_000,
                    maxOutputBytes: 16,
                    maxConcurrentRequests: 1
                )
            ),
            transport: outputTransport,
            policy: ExtensionHostPolicy(
                limits: ExtensionResourceLimits(
                    maxRuntimeMilliseconds: 1_000,
                    maxOutputBytes: 16,
                    maxConcurrentRequests: 1
                )
            )
        )
        try await outputHost.start(
            approval: ExtensionApproval(
                extensionID: "demo-extension",
                version: "1.0.0",
                capabilities: [],
                approvedAt: "now"
            )
        )
        await #expect(throws: ExtensionHostError.outputTooLarge) {
            _ = try await outputHost.invoke(toolNamed: "echo", arguments: .null)
        }
    }

    private func manifest(
        license: String = "MIT",
        capabilities: [String] = [],
        limits: ExtensionResourceLimits = .init()
    ) -> ExtensionManifest {
        ExtensionManifest(
            id: "demo-extension",
            displayName: "Demo Extension",
            version: "1.0.0",
            executablePath: "/usr/local/bin/demo-extension",
            source: AdapterSourceMetadata(
                kind: .upstream,
                license: license,
                url: "https://github.com/example/demo-extension"
            ),
            license: license,
            capabilities: capabilities,
            limits: limits
        )
    }

    private func handshake() -> ExtensionHandshake {
        ExtensionHandshake(
            protocolVersion: .jsonRPC1,
            descriptor: ExtensionDescriptor(
                id: "demo-extension",
                displayName: "Demo Extension",
                version: "1.0.0"
            ),
            tools: [
                ToolCatalogEntry(
                    name: "echo",
                    description: "Return the supplied value.",
                    source: .adapter,
                    inputSchema: .object(["type": .string("object")]),
                    permission: .allowed
                )
            ]
        )
    }
}

private actor FakeExtensionTransport: DoMoExtensionTransport {
    let handshake: ExtensionHandshake
    let result: JSONValue
    private(set) var started = false
    private(set) var plan: ExtensionLaunchPlan?
    private(set) var methods: [String] = []

    init(handshake: ExtensionHandshake, result: JSONValue? = nil) {
        self.handshake = handshake
        self.result = result ?? .object(["value": .string("ok")])
    }

    func start(using plan: ExtensionLaunchPlan) async throws {
        self.plan = plan
        started = true
    }

    func stop() async {
        started = false
    }

    func request(_ request: ExtensionRPCRequest) async throws -> ExtensionRPCResponse {
        methods.append(request.method)
        switch request.method {
        case "initialize":
            let data = try JSONEncoder().encode(handshake)
            return ExtensionRPCResponse(id: request.id, result: try JSONValue(parsing: data))
        case "tools/call":
            if case .object(let params) = request.params,
               let arguments = params["arguments"] {
                return ExtensionRPCResponse(id: request.id, result: result == .object(["value": .string("ok")]) ? arguments : result)
            }
            return ExtensionRPCResponse(id: request.id, result: result)
        default:
            return ExtensionRPCResponse(
                id: request.id,
                error: ExtensionRPCError(code: -32601, message: "method not found")
            )
        }
    }
}
