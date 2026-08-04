// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoLLM
import Foundation

/// Adapter inventory and doctor surfaces. The commands inspect metadata and
/// configuration by default; `--probe` is the explicit opt-in that performs a
/// LiteLLM `/models` handshake and therefore may contact the configured gateway.
public struct AdaptersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "adapters",
        abstract: "Inspect provider, MCP, ACP, and execution adapters.",
        subcommands: [AdaptersListCommand.self, AdaptersDoctorCommand.self],
        defaultSubcommand: AdaptersListCommand.self
    )

    public init() {}
}

public struct AdaptersListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List registered adapter kinds, capabilities, and license metadata."
    )

    @Flag(name: .customLong("json"), help: "Emit JSON instead of a table.")
    public var json = false

    public init() {}

    public func run() async throws {
        let registry = try await AdapterTooling.makeRegistry(probe: false)
        let descriptors = await registry.descriptors()
        if json {
            let data = try JSONEncoder.sorted.encode(descriptors)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for descriptor in descriptors {
            let capabilities = descriptor.capabilities.isEmpty
                ? "(none)"
                : descriptor.capabilities.joined(separator: ",")
            let license = descriptor.source.license ?? "unknown license"
            print("\(descriptor.id)\t\(descriptor.kind.rawValue)\t\(license)\t\(capabilities)")
        }
    }
}

public struct AdaptersDoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check adapter configuration and optionally probe LiteLLM."
    )

    @Flag(name: .customLong("json"), help: "Emit JSON instead of a table.")
    public var json = false

    @Flag(
        name: .customLong("probe"),
        help: "Perform a LiteLLM model-catalog handshake; may contact the configured gateway."
    )
    public var probe = false

    public init() {}

    public func run() async throws {
        let registry = try await AdapterTooling.makeRegistry(probe: probe)
        let reports = await registry.doctor()
        if json {
            let data = try JSONEncoder.sorted.encode(reports)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for report in reports {
            print("\(report.descriptor.id)\t\(report.health.status.rawValue)\t\(report.health.message)")
        }
    }
}

private enum AdapterTooling {
    private struct ManifestAdapter: DoMoAdapterHealthChecking {
        let descriptor: AdapterDescriptor
        let health: AdapterHealth

        func start() async throws {}
        func stop() async {}
        func healthCheck() async -> AdapterHealth { health }
    }

    static func makeRegistry(probe: Bool) async throws -> AdapterRegistry {
        let registry = AdapterRegistry()
        for manifest in manifests() where !(probe && manifest.descriptor.id == "litellm") {
            try await registry.register(ManifestAdapter(descriptor: manifest.descriptor, health: manifest.health))
        }
        if probe {
            let environment = ProcessInfo.processInfo.environment
            let baseURL = environment["DOMOCODE_BASE_URL"] ?? "http://localhost:4000/v1"
            let credentialName = credentialName(in: environment)
            let profile = ProviderProfile(
                id: "litellm-default",
                displayName: "LiteLLM gateway",
                adapterID: "litellm",
                endpoint: baseURL,
                defaultModel: environment["DOMOCODE_MODEL"],
                credential: ProviderCredentialReference(name: credentialName),
                capabilities: ["chat", "streaming", "tools", "usage", "retry", "recovery"]
            )
            let client = LiteLLMClient(configuration: LiteLLMClient.Configuration(
                baseURL: baseURL,
                apiKey: environment[credentialName]
            ))
            try await registry.register(LiteLLMProviderAdapter(profile: profile, client: client))
        }
        return registry
    }

    private static func credentialName(in environment: [String: String]) -> String {
        if environment["DOMOCODE_API_KEY"] != nil { return "DOMOCODE_API_KEY" }
        if environment["LITELLM_API_KEY"] != nil { return "LITELLM_API_KEY" }
        if environment["OPENAI_API_KEY"] != nil { return "OPENAI_API_KEY" }
        return "DOMOCODE_API_KEY"
    }

    private static func manifests() -> [(descriptor: AdapterDescriptor, health: AdapterHealth)] {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["DOMOCODE_BASE_URL"] ?? "http://localhost:4000/v1"
        let endpointOK = URL(string: baseURL)?.scheme != nil
        let credentialName = credentialName(in: environment)
        let credentialPresent = environment[credentialName]?.isEmpty == false
        let providerHealth = AdapterHealth(
            status: endpointOK ? (credentialPresent ? .healthy : .degraded) : .unavailable,
            message: endpointOK
                ? (credentialPresent
                    ? "Configuration is ready; pass --probe for a network handshake"
                    : "Endpoint is valid; credential reference \(credentialName) is not resolved")
                : "Configured endpoint is not a valid URL",
            supportedEvents: [
                "messageStart", "textDelta", "reasoningDelta", "toolCallDelta",
                "usage", "retry", "messageEnd", "error",
            ],
            credentialRequired: true
        )

        func descriptor(
            _ id: String,
            _ name: String,
            _ kind: AdapterKind,
            _ capabilities: [String]
        ) -> AdapterDescriptor {
            AdapterDescriptor(
                id: id,
                displayName: name,
                capabilities: capabilities,
                kind: kind,
                source: .builtInMIT
            )
        }

        return [
            (
                descriptor("litellm", "LiteLLM / OpenAI-compatible Chat", .provider,
                    ["chat", "streaming", "tools", "usage", "retry", "recovery"]),
                providerHealth
            ),
            (
                descriptor("anthropic-messages", "Anthropic Messages", .provider,
                    ["messages", "streaming", "tools", "thinking", "usage"]),
                AdapterHealth(
                    status: .unknown,
                    message: "Adapter is available; configure an Anthropic profile to use it",
                    supportedEvents: ["messageStart", "textDelta", "reasoningDelta", "toolCallDelta", "usage", "messageEnd", "error"],
                    credentialRequired: true
                )
            ),
            (
                descriptor("mcp-stdio", "MCP stdio", .mcp, ["tools", "resources", "templates"]),
                AdapterHealth(status: .healthy, message: "Runtime adapter available")
            ),
            (
                descriptor("mcp-http", "MCP HTTP/SSE", .mcp, ["tools", "resources", "templates", "reconnect"]),
                AdapterHealth(status: .healthy, message: "Runtime adapter available when configured")
            ),
            (
                descriptor("acp-stdio", "Agent Client Protocol stdio", .acp, ["lifecycle", "tasks", "permissions", "cancellation"]),
                AdapterHealth(status: .unsupported, message: "ACP transport is not configured in this installation")
            ),
            (
                descriptor("local-process-backend", "Local process backend", .backend, ["process", "pty", "sandbox"]),
                AdapterHealth(status: .healthy, message: "Runtime adapter available")
            ),
            (
                descriptor("browser-mcp", "Browser through MCP", .browser, ["navigation", "screenshots", "approvals"]),
                AdapterHealth(status: .unsupported, message: "No browser MCP server is configured")
            ),
            (
                descriptor("notebook-mcp", "Notebook through MCP", .notebook, ["kernels", "artifacts", "approvals"]),
                AdapterHealth(status: .unsupported, message: "No notebook MCP server is configured")
            ),
            (
                descriptor("remote-search-mcp", "Remote search through MCP", .remoteSearch, ["search", "citations", "redaction"]),
                AdapterHealth(status: .unsupported, message: "No remote-search MCP server is configured")
            ),
        ]
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
