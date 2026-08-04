// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

@Suite("Provider profiles and adapter registry")
struct ProviderProfilesTests {
    @Test("profiles round-trip without a credential value")
    func profileRoundTrip() throws {
        let profile = ProviderProfile(
            id: "primary",
            displayName: "Primary gateway",
            adapterID: "litellm",
            endpoint: "http://localhost:4000/v1",
            defaultModel: "model",
            credential: ProviderCredentialReference(name: "DOMOCODE_API_KEY"),
            capabilities: ["tools", "streaming"],
            usagePolicy: ProviderUsagePolicy(reportsCost: true),
            cachePolicy: ProviderCachePolicy(supportsPromptCaching: true),
            contextWindow: 128_000,
            metadata: ["owner": "test"]
        )
        let data = try JSONEncoder().encode(profile)
        let copy = try JSONDecoder().decode(ProviderProfile.self, from: data)

        #expect(copy == profile)
        #expect(String(decoding: data, as: UTF8.self).contains("DOMOCODE_API_KEY"))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-value"))
    }

    @Test("fallback never replays a committed response without approval")
    func fallbackCommitBoundary() {
        let route = ProviderRoute(id: "route", displayName: "Route", profileIDs: ["one", "two"])

        let beforeCommit = ProviderFallbackRouter.decision(
            route: route,
            currentProfileID: "one",
            failureIsTransient: true,
            responseCommitted: false,
            approved: false
        )
        #expect(beforeCommit == .use(profileID: "two"))

        let afterCommit = ProviderFallbackRouter.decision(
            route: route,
            currentProfileID: "one",
            failureIsTransient: true,
            responseCommitted: true,
            approved: false
        )
        #expect(afterCommit == .requireApproval(
            profileID: "two",
            reason: "A provider switch after response or tool output requires approval"
        ))
    }

    @Test("registry preserves insertion order and reports unhealthchecked adapters honestly")
    func registryLifecycle() async throws {
        let registry = AdapterRegistry()
        try await registry.register(TestAdapter(id: "first"))
        try await registry.register(TestAdapter(id: "second"))
        #expect(await registry.descriptors().map(\.id) == ["first", "second"])

        let reports = await registry.doctor()
        #expect(reports.map(\.health.status) == [.unknown, .unknown])
        await #expect(throws: AdapterRegistryError.self) {
            try await registry.register(TestAdapter(id: "first"))
        }
    }

    @Test("circuit breaker opens after transient failures and permits one probe")
    func circuitBreaker() async {
        let breaker = ProviderCircuitBreaker(failureThreshold: 2)
        _ = await breaker.recordFailure(profileID: "gateway", reason: "503", transient: true)
        #expect(await breaker.canAttempt(profileID: "gateway"))
        let open = await breaker.recordFailure(profileID: "gateway", reason: "503", transient: true)
        #expect(open.state == .open)
        #expect(await breaker.canAttempt(profileID: "gateway") == false)
        #expect(await breaker.beginProbe(profileID: "gateway"))
        #expect(await breaker.beginProbe(profileID: "gateway") == false)
        _ = await breaker.recordSuccess(profileID: "gateway")
        #expect(await breaker.snapshot(for: "gateway").state == .closed)
    }

    @Test("fallback controller advances before commit and requires approval afterward")
    func fallbackController() async {
        let controller = ProviderFallbackController(
            route: ProviderRoute(id: "route", displayName: "Route", profileIDs: ["one", "two", "three"]),
            breaker: ProviderCircuitBreaker(failureThreshold: 2)
        )
        #expect(await controller.start() == .use(profileID: "one"))
        #expect(await controller.recordFailure(reason: "503", transient: true) == .use(profileID: "two"))

        await controller.markResponseCommitted()
        let pending = await controller.recordFailure(reason: "503", transient: true)
        #expect(pending == .requireApproval(
            profileID: "three",
            reason: "A provider switch after response or tool output requires approval"
        ))
        let waiting = await controller.snapshot()
        #expect(waiting.currentProfileID == "two")
        #expect(waiting.pendingApprovalProfileID == "three")

        #expect(await controller.approvePendingFallback() == .use(profileID: "three"))
        let finished = await controller.snapshot()
        #expect(finished.attemptedProfileIDs == ["one", "two", "three"])
    }

    @Test("fallback controller skips an open circuit without replaying it")
    func fallbackControllerSkipsOpenCircuit() async {
        let breaker = ProviderCircuitBreaker(failureThreshold: 1)
        _ = await breaker.recordFailure(profileID: "one", reason: "503", transient: true)
        let controller = ProviderFallbackController(
            route: ProviderRoute(id: "route", displayName: "Route", profileIDs: ["one", "two"]),
            breaker: breaker
        )
        #expect(await controller.start() == .use(profileID: "two"))
        #expect((await controller.snapshot()).attemptedProfileIDs == ["two"])
    }

    @Test("route validation rejects duplicates and missing profiles")
    func routeValidation() {
        let profile = ProviderProfile(
            id: "one",
            displayName: "One",
            adapterID: "litellm",
            endpoint: "http://localhost"
        )
        let profiles = ["one": profile]
        #expect(throws: ProviderRouteValidationError.self) {
            try ProviderRouteValidator.validate(
                ProviderRoute(id: "bad", displayName: "Bad", profileIDs: ["one", "one"]),
                profiles: profiles
            )
        }
        #expect(throws: ProviderRouteValidationError.self) {
            try ProviderRouteValidator.validate(
                ProviderRoute(id: "bad", displayName: "Bad", profileIDs: ["missing"]),
                profiles: profiles
            )
        }
    }
}

private struct TestAdapter: DoMoAdapter {
    let descriptor: AdapterDescriptor

    init(id: String) {
        descriptor = AdapterDescriptor(id: id, displayName: id, kind: .provider)
    }

    func start() async throws {}
    func stop() async {}
}
