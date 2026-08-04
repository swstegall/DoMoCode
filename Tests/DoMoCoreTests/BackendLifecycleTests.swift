// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Backend lifecycle", .serialized)
struct BackendLifecycleTests {
    @Test("registry negotiates capabilities and exposes truthful lifecycle events")
    func lifecycleAndEvents() async throws {
        let backend = FixtureBackend(
            descriptor: BackendDescriptor(
                id: "local",
                displayName: "Local fixture",
                kind: .localProcess,
                capabilities: ["pty", "workspace-write"],
                requiresIsolation: true
            )
        )
        let registry = BackendRegistry()
        try await registry.register(backend)
        #expect(try await registry.state(for: "local") == .stopped)

        try await registry.start(
            id: "local",
            request: BackendStartRequest(requiredCapabilities: ["pty"])
        )
        #expect(try await registry.state(for: "local") == .healthy)
        let result = try await registry.execute(
            id: "local",
            request: BackendRequest(operation: "echo", input: "hello")
        )
        #expect(result.status == .succeeded)

        try await registry.pause(id: "local")
        #expect(try await registry.state(for: "local") == .paused)
        await #expect(throws: BackendRegistryError.invalidTransition(
            backendID: "local",
            state: .paused
        )) {
            _ = try await registry.execute(
                id: "local",
                request: BackendRequest(operation: "echo")
            )
        }

        try await registry.resume(id: "local")
        try await registry.stop(id: "local")
        #expect(try await registry.state(for: "local") == .stopped)

        let events = await registry.stateEvents()
        #expect(events.map(\.state) == [
            .stopped, .starting, .healthy, .paused, .starting, .healthy, .stopped,
        ])
        #expect(await registry.stateEvents(after: events[2].sequence).map(\.state) == [
            .paused, .starting, .healthy, .stopped,
        ])
    }

    @Test("registry refuses missing capabilities and unisolated health")
    func admissionRefusal() async throws {
        let backend = FixtureBackend(
            descriptor: BackendDescriptor(
                id: "remote",
                displayName: "Unisolated fixture",
                kind: .remoteWorker,
                capabilities: ["network"],
                requiresIsolation: true
            ),
            isolationEstablished: false
        )
        let registry = BackendRegistry()
        try await registry.register(backend)

        await #expect(throws: BackendRegistryError.missingCapability(
            backendID: "remote",
            capability: "pty"
        )) {
            try await registry.start(
                id: "remote",
                request: BackendStartRequest(requiredCapabilities: ["pty"])
            )
        }
        await #expect(throws: BackendRegistryError.isolationUnavailable("remote")) {
            try await registry.start(id: "remote")
        }
        #expect(try await registry.state(for: "remote") == .failed)
    }
}

private actor FixtureBackend: DoMoManagedBackend {
    nonisolated let backendDescriptor: BackendDescriptor
    nonisolated let descriptor: AdapterDescriptor
    private let isolationEstablished: Bool
    private var state: BackendLifecycleState = .stopped

    init(descriptor: BackendDescriptor, isolationEstablished: Bool = true) {
        self.backendDescriptor = descriptor
        self.descriptor = descriptor.adapterDescriptor
        self.isolationEstablished = isolationEstablished
    }

    func start() async throws {
        state = .healthy
    }

    func start(request: BackendStartRequest) async throws {
        state = .healthy
    }

    func stop() async {
        state = .stopped
    }

    func health() async -> BackendHealth {
        BackendHealth(
            state: state,
            message: state == .healthy ? "Fixture ready" : "Fixture (state.rawValue)",
            authenticated: true,
            isolationEstablished: isolationEstablished,
            capabilities: backendDescriptor.capabilities
        )
    }

    func execute(_ request: BackendRequest) async throws -> BackendResult {
        BackendResult(status: .succeeded, output: request.input)
    }

    func cancel(operationID: String) async {}
}
