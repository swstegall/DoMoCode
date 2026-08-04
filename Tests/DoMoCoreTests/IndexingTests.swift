// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Index freshness", .serialized)
struct IndexingTests {
    @Test("watcher invalidation downgrades results until refresh completes")
    func staleResultsAreTruthful() async throws {
        let provider = FakeIndexProvider()
        let coordinator = IndexCoordinator(provider: provider)

        await coordinator.observe(ResourceReloadEvent(
            path: "/project/Sources/App.swift",
            kind: .workspace,
            observedAt: "1"
        ))
        let initial = try await coordinator.search(IndexSearchQuery(
            text: "App",
            rootPath: "/project"
        ))
        #expect(initial.freshness == .stale)
        #expect(initial.warning != nil)
        #expect(initial.usedFallback == false)

        let refresh = try await coordinator.refresh()
        #expect(refresh.freshness == .current)
        let current = try await coordinator.search(IndexSearchQuery(
            text: "App",
            rootPath: "/project"
        ))
        #expect(current.freshness == .current)
        #expect(current.warning == nil)
        #expect(await provider.refreshedPaths == ["/project/Sources/App.swift"])
    }

    @Test("ignored paths do not invalidate the index")
    func ignoredPathsRemainCurrent() async throws {
        let provider = FakeIndexProvider(initialFreshness: .current, indexedGeneration: 0)
        let coordinator = IndexCoordinator(provider: provider)
        await coordinator.setIgnoredPaths(["/project/.build"])
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.build/checkouts/Package.swift",
            kind: .workspace,
            observedAt: "2"
        ))

        let status = await coordinator.status()
        #expect(status.generation == 0)
        #expect(status.pendingPaths.isEmpty)
        let result = try await coordinator.search(IndexSearchQuery(text: "App", rootPath: "/project"))
        #expect(result.freshness == .current)
    }

    @Test("provider failure uses an explicit search-only fallback")
    func fallbackIsMarked() async throws {
        let provider = FakeIndexProvider(shouldFailSearch: true)
        let coordinator = IndexCoordinator(
            provider: provider,
            fallbackSearch: { query in
                [IndexSymbol(
                    name: query.text,
                    kind: .unknown,
                    location: IndexLocation(path: "/project/README.md", line: 0, column: 0)
                )]
            }
        )
        let result = try await coordinator.search(IndexSearchQuery(text: "readme", rootPath: "/project"))
        #expect(result.freshness == .fallback)
        #expect(result.usedFallback)
        #expect(result.warning?.contains("search-only") == true)
        #expect(result.symbols.count == 1)
    }

    @Test("invalid queries fail before reaching a provider")
    func invalidQueriesFailBeforeProvider() async throws {
        let provider = FakeIndexProvider()
        let coordinator = IndexCoordinator(provider: provider)
        await #expect(throws: IndexCoordinatorError.invalidQuery("Search text must not be empty.")) {
            _ = try await coordinator.search(IndexSearchQuery(text: " ", rootPath: "/project"))
        }
        #expect(await provider.searchCount == 0)
    }

    @Test("provider cancellation is preserved and does not use fallback search")
    func cancellationIsNotAnOutage() async throws {
        let fallbackCalls = CancellationFallbackCounter()
        let coordinator = IndexCoordinator(
            provider: CancellationIndexProvider(),
            fallbackSearch: { _ in
                await fallbackCalls.increment()
                return []
            }
        )

        await #expect(throws: IndexCoordinatorError.cancelled) {
            _ = try await coordinator.search(IndexSearchQuery(
                text: "App",
                rootPath: "/project"
            ))
        }
        #expect(await fallbackCalls.value == 0)
    }
}

private actor FakeIndexProvider: DoMoIndexProvider {
    nonisolated let descriptor = IndexProviderDescriptor(
        id: "fake",
        displayName: "Fake index",
        capabilities: ["symbols", "search"]
    )
    private let initialFreshness: IndexFreshness
    private let initialGeneration: Int
    private let shouldFailSearch: Bool
    private(set) var refreshedPaths: [String] = []
    private(set) var searchCount = 0

    init(
        initialFreshness: IndexFreshness = .current,
        indexedGeneration: Int = 1,
        shouldFailSearch: Bool = false
    ) {
        self.initialFreshness = initialFreshness
        self.initialGeneration = indexedGeneration
        self.shouldFailSearch = shouldFailSearch
    }

    func search(_ query: IndexSearchQuery) async throws -> IndexSearchResult {
        searchCount += 1
        if shouldFailSearch { throw IndexCoordinatorError.unavailable }
        return IndexSearchResult(
            symbols: [IndexSymbol(
                name: query.text,
                kind: .function,
                location: IndexLocation(path: "/project/Sources/App.swift", line: 1, column: 0)
            )],
            freshness: initialFreshness,
            indexedGeneration: initialGeneration
        )
    }

    func refresh(paths: [String]) async throws -> IndexRefreshResult {
        refreshedPaths = paths
        return IndexRefreshResult(
            paths: paths,
            indexedGeneration: 1,
            freshness: .current
        )
    }
}

private actor CancellationIndexProvider: DoMoIndexProvider {
    nonisolated let descriptor = IndexProviderDescriptor(
        id: "cancelled",
        displayName: "Cancelled index"
    )

    func search(_ query: IndexSearchQuery) async throws -> IndexSearchResult {
        throw CancellationError()
    }

    func refresh(paths: [String]) async throws -> IndexRefreshResult {
        throw CancellationError()
    }
}

private actor CancellationFallbackCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
