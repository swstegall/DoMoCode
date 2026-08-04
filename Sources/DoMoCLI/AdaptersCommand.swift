// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoLLM
import Foundation

/// Adapter inventory and doctor surfaces. The commands inspect metadata and
/// configuration by default; `--probe` is the explicit opt-in that performs
/// configured provider handshakes and therefore may contact remote gateways.
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
        abstract: "Check adapter configuration and optionally probe configured providers."
    )

    @Flag(name: .customLong("json"), help: "Emit JSON instead of a table.")
    public var json = false

    @Flag(
        name: .customLong("probe"),
        help: "Perform configured provider handshakes; may contact a gateway."
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
        let probedIDs: Set<String> = ["litellm", "openai-responses"]
        for manifest in manifests() where !(probe && probedIDs.contains(manifest.descriptor.id)) {
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

            let openAIBaseURL = environment["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
            let openAIProfile = ProviderProfile(
                id: "openai-responses-default",
                displayName: "OpenAI Responses",
                adapterID: "openai-responses",
                endpoint: openAIBaseURL,
                defaultModel: environment["OPENAI_MODEL"] ?? environment["DOMOCODE_MODEL"],
                credential: ProviderCredentialReference(name: "OPENAI_API_KEY"),
                capabilities: ["responses", "streaming", "tools", "reasoning", "usage"]
            )
            try await registry.register(OpenAIResponsesProviderAdapter(
                profile: openAIProfile,
                credential: environment["OPENAI_API_KEY"]
            ))
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
        let openAIBaseURL = environment["OPENAI_BASE_URL"] ?? "https://api.openai.com/v1"
        let openAIEndpointOK = URL(string: openAIBaseURL)?.scheme != nil
        let openAICredentialPresent = environment["OPENAI_API_KEY"]?.isEmpty == false
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

        var result = [
            (
                descriptor("litellm", "LiteLLM / OpenAI-compatible Chat", .provider,
                    ["chat", "streaming", "tools", "usage", "retry", "recovery"]),
                providerHealth
            ),
            (
                descriptor("openai-responses", "OpenAI Responses", .provider,
                    ["responses", "streaming", "tools", "reasoning", "usage"]),
                AdapterHealth(
                    status: openAIEndpointOK
                        ? (openAICredentialPresent ? .healthy : .degraded)
                        : .unavailable,
                    message: openAIEndpointOK
                        ? (openAICredentialPresent
                            ? "Configuration is ready; pass --probe for a provider handshake"
                            : "Endpoint is valid; credential reference OPENAI_API_KEY is not resolved")
                        : "Configured endpoint is not a valid URL",
                    supportedEvents: [
                        "messageStart", "textDelta", "reasoningDelta", "toolCallDelta",
                        "toolResult", "usage", "retry", "messageEnd", "error", "unknown",
                    ],
                    credentialRequired: true
                )
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
                AdapterHealth(
                    status: .unsupported,
                    message: "ACP stdio boundary is available; no external agent command is configured",
                    supportedEvents: [
                        "messageStart", "textDelta", "reasoningDelta", "toolCallDelta",
                        "toolResult", "image", "plan", "task", "usage", "permission",
                        "retry", "messageEnd", "cancelled", "error", "unknown",
                    ]
                )
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
        result.append(contentsOf: optionalBackendManifests(environment: environment))
        return result
    }

    private static func optionalBackendManifests(
        environment: [String: String]
    ) -> [(descriptor: AdapterDescriptor, health: AdapterHealth)] {
        let source = AdapterSourceMetadata(
            kind: .user,
            attribution: "User-installed command speaking the DoMo backend protocol"
        )

        func manifest(
            id: String,
            name: String,
            environmentName: String
        ) -> (descriptor: AdapterDescriptor, health: AdapterHealth) {
            let configured = environment[environmentName]?.isEmpty == false
            return (
                AdapterDescriptor(
                    id: id,
                    displayName: name,
                    capabilities: ["health-handshake", "lifecycle", "workspace-write"],
                    kind: .backend,
                    source: source
                ),
                AdapterHealth(
                    status: configured ? .degraded : .unsupported,
                    message: configured
                        ? "Command configured; start must return capabilities and isolation proof"
                        : "Set \(environmentName) to enable this user-installed adapter",
                    supportedEvents: ["health", "start", "stop", "pause", "resume", "reconnect", "cleanup"],
                    credentialRequired: false
                )
            )
        }

        return [
            manifest(
                id: "docker-backend",
                name: "Docker through external command",
                environmentName: "DOMOCODE_DOCKER_BACKEND_COMMAND"
            ),
            manifest(
                id: "gondolin-backend",
                name: "Gondolin through external command",
                environmentName: "DOMOCODE_GONDOLIN_BACKEND_COMMAND"
            ),
            manifest(
                id: "openshell-backend",
                name: "OpenShell through external command",
                environmentName: "DOMOCODE_OPENSHELL_BACKEND_COMMAND"
            ),
            manifest(
                id: "remote-worker-backend",
                name: "Remote worker through external command",
                environmentName: "DOMOCODE_REMOTE_WORKER_COMMAND"
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
