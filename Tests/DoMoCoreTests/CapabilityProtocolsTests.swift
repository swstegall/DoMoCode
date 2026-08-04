// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

@Suite("Phase 22 capability contracts")
struct CapabilityProtocolsTests {
    @Test("provider requests and events round-trip without a transport vocabulary")
    func providerValuesRoundTrip() throws {
        let request = ProviderRequest(
            model: "neutral-model",
            messages: [
                ProviderMessage(role: .user, content: ["text": "hello"]),
            ],
            tools: [
                ProviderTool(
                    name: "lookup",
                    description: "Look something up",
                    inputSchema: ["type": "object"]
                ),
            ],
            options: ["temperature": 0.2],
            metadata: ["surface": "headless"]
        )
        let event = ProviderEvent(
            kind: .toolCallDelta,
            payload: ["name": "lookup", "arguments": ["key": "value"]],
            sequence: 4
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let requestCopy = try decoder.decode(ProviderRequest.self, from: encoder.encode(request))
        let eventCopy = try decoder.decode(ProviderEvent.self, from: encoder.encode(event))

        #expect(requestCopy == request)
        #expect(eventCopy == event)
    }

    @Test("provider and backend protocols expose independent lifecycle seams")
    func providerAndBackendSeams() async throws {
        let provider = TestProvider()
        let backend = TestBackend()

        try await provider.start()
        let models = try await provider.listModels()
        #expect(models.map(\.id) == ["model"])

        var events: [ProviderEvent] = []
        for try await event in provider.stream(
            ProviderRequest(
                model: "model",
                messages: [ProviderMessage(role: .user, content: "hello")]
            )
        ) {
            events.append(event)
        }
        #expect(events.map(\.kind) == [.messageStart, .messageEnd])

        let result = try await backend.execute(BackendRequest(operation: "inspect"))
        #expect(result.status == .succeeded)
        await backend.cancel(operationID: "unused")
        await provider.stop()
    }

    @Test("provider capability checks cover model-level requirements")
    func capabilityChecks() throws {
        let request = ProviderRequest(
            model: "vision-model",
            messages: [],
            requiredCapabilities: [.images, .longContext]
        )
        let descriptor = ProviderDescriptor(
            id: "provider",
            displayName: "Provider",
            capabilities: ["images"]
        )
        let model = ProviderModel(id: "vision-model", capabilities: ["long_context"])
        try ProviderCapabilityChecker.validate(request: request, descriptor: descriptor, model: model)

        let missing = ProviderCapabilityChecker.missing(
            required: [.images, .reasoning],
            advertised: ["images"]
        )
        #expect(missing == [.reasoning])
        #expect(throws: ProviderCapabilityError.missing(
            providerID: "provider",
            modelID: "vision-model",
            capabilities: [.reasoning]
        )) {
            try ProviderCapabilityChecker.validate(
                request: ProviderRequest(
                    model: "vision-model",
                    messages: [],
                    requiredCapabilities: [.reasoning]
                ),
                descriptor: descriptor,
                model: model
            )
        }
    }

    @Test("themes and extension registrations remain renderer-independent")
    func themeAndExtensionSeams() async throws {
        let theme = ThemeDefinition(
            id: "test",
            displayName: "Test",
            tokens: [
                "background": ThemeToken(background: .rgb(red: 1, green: 2, blue: 3)),
            ]
        )
        let themeProvider = TestThemeProvider(theme: theme)
        #expect(try await themeProvider.theme(named: "test") == theme)

        let registry = TestExtensionRegistry()
        let extensionProvider = TestExtension()
        try await extensionProvider.install(into: registry)
        #expect(await registry.names == ["extension-tool"])
    }
}

private struct TestProvider: DoMoProvider {
    let descriptor = AdapterDescriptor(id: "provider", displayName: "Provider")
    let providerDescriptor = ProviderDescriptor(id: "provider", displayName: "Provider")

    func start() async throws {}
    func stop() async {}

    func listModels() async throws -> [ProviderModel] {
        [ProviderModel(id: "model")]
    }

    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ProviderEvent(kind: .messageStart, payload: ["model": .string(request.model)]))
            continuation.yield(ProviderEvent(kind: .messageEnd))
            continuation.finish()
        }
    }
}

private struct TestBackend: DoMoBackend {
    let descriptor = AdapterDescriptor(id: "backend", displayName: "Backend")

    func start() async throws {}
    func stop() async {}

    func execute(_ request: BackendRequest) async throws -> BackendResult {
        BackendResult(status: .succeeded, output: ["operation": .string(request.operation)])
    }

    func cancel(operationID: String) async {}
}

private struct TestThemeProvider: DoMoThemeProvider {
    let theme: ThemeDefinition

    func themes() async throws -> [ThemeDefinition] { [theme] }
    func theme(named id: String) async throws -> ThemeDefinition? {
        theme.id == id ? theme : nil
    }
}

private actor TestExtensionRegistry: DoMoExtensionRegistry {
    private(set) var names: [String] = []

    func register(_ tool: ExtensionToolRegistration) async throws {
        names.append(tool.entry.name)
    }

    func unregister(toolNamed name: String) async {
        names.removeAll { $0 == name }
    }
}

private struct TestExtension: DoMoExtension {
    let descriptor = AdapterDescriptor(id: "extension", displayName: "Extension")
    let extensionDescriptor = ExtensionDescriptor(id: "extension", displayName: "Extension")

    func start() async throws {}
    func stop() async {}

    func install(into registry: any DoMoExtensionRegistry) async throws {
        try await registry.register(
            ExtensionToolRegistration(
                entry: ToolCatalogEntry(
                    name: "extension-tool",
                    source: .extensionProvider,
                    inputSchema: ["type": "object"],
                    permission: .requiresApproval
                ),
                execute: { _ in .null }
            )
        )
    }
}
