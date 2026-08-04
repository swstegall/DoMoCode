// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Dependency index freshness", .serialized)
struct DependencyIndexTests {
    @Test("incremental refresh builds reverse dependents")
    func refreshBuildsReverseGraph() async throws {
        let provider = FakeDependencyProvider()
        let coordinator = try DependencyIndexCoordinator(rootPath: "/project", provider: provider)
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/App.swift",
            kind: .workspace,
            observedAt: "1"
        ))
        #expect((try await coordinator.searchDependents(of: "/project/Library.swift")).freshness == .stale)

        try await coordinator.refresh()
        let result = try await coordinator.searchDependents(of: "/project/Library.swift")
        #expect(result.freshness == .current)
        #expect(result.sourcePaths == ["/project/App.swift"])
        #expect(await provider.refreshedPaths == ["/project/App.swift"])
    }

    @Test("ignored paths do not invalidate and fallback is labeled")
    func ignoredAndFallbackAreTruthful() async throws {
        let provider = FakeDependencyProvider()
        let coordinator = try DependencyIndexCoordinator(
            rootPath: "/project",
            provider: provider,
            fallbackSearch: { _ in ["/project/SearchOnly.swift"] }
        )
        await coordinator.setIgnoredPaths(["/project/.build"])
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.build/index.json",
            kind: .workspace,
            observedAt: "2"
        ))
        let initial = try await coordinator.searchDependents(of: "/project/Library.swift")
        #expect(initial.freshness == .fallback)
        #expect((await coordinator.status()).generation == 0)

        await coordinator.observe(ResourceReloadEvent(
            path: "/project/App.swift",
            kind: .workspace,
            observedAt: "3"
        ))
        let fallback = try await coordinator.searchDependents(of: "/project/Library.swift")
        #expect(fallback.freshness == .fallback)
        #expect(fallback.usedFallback)
        #expect(fallback.sourcePaths == ["/project/SearchOnly.swift"])
    }

    @Test("edges outside the workspace are refused")
    func filtersOutsideEdges() async throws {
        let coordinator = try DependencyIndexCoordinator(
            rootPath: "/project",
            provider: FakeDependencyProvider()
        )
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/App.swift",
            kind: .workspace,
            observedAt: "4"
        ))
        try await coordinator.refresh()
        let result = try await coordinator.searchDependents(of: "/project/Outside.swift")
        #expect(result.sourcePaths.isEmpty)
    }
}

private actor FakeDependencyProvider: DoMoDependencyIndexProvider {
    private(set) var refreshedPaths: [String] = []

    func refresh(paths: [String]) async throws -> [DependencyEdge] {
        refreshedPaths = paths
        return [
            DependencyEdge(sourcePath: "/project/App.swift", targetPath: "/project/Library.swift"),
            DependencyEdge(sourcePath: "/project/App.swift", targetPath: "/outside/Secret.swift"),
        ]
    }
}
