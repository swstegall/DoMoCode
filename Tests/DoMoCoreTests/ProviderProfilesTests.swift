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
}

private struct TestAdapter: DoMoAdapter {
    let descriptor: AdapterDescriptor

    init(id: String) {
        descriptor = AdapterDescriptor(id: id, displayName: id, kind: .provider)
    }

    func start() async throws {}
    func stop() async {}
}
