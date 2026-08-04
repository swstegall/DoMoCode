// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// Provider-neutral indexing contracts. An index is an optimization over
/// source facts, so freshness is part of every result and stale data is never
/// relabeled as current by the coordinator.

public enum IndexFreshness: String, Sendable, Codable, Hashable, CaseIterable {
    case current
    case stale
    case building
    case unavailable
    case fallback
}

public enum IndexSymbolKind: String, Sendable, Codable, Hashable, CaseIterable {
    case file
    case module
    case namespace
    case type
    case function
    case method
    case property
    case variable
    case constant
    case importDeclaration
    case unknown
}

public struct IndexProviderDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var capabilities: [String]
    public var supportsIncrementalRefresh: Bool

    public init(
        id: String,
        displayName: String,
        capabilities: [String] = [],
        supportsIncrementalRefresh: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = Array(Set(capabilities)).sorted()
        self.supportsIncrementalRefresh = supportsIncrementalRefresh
    }
}

public struct IndexLocation: Sendable, Codable, Hashable {
    public var path: String
    public var line: Int
    public var column: Int
    public var endLine: Int?
    public var endColumn: Int?

    public init(
        path: String,
        line: Int,
        column: Int,
        endLine: Int? = nil,
        endColumn: Int? = nil
    ) {
        self.path = path
        self.line = max(0, line)
        self.column = max(0, column)
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

public struct IndexSymbol: Sendable, Codable, Hashable {
    public var name: String
    public var kind: IndexSymbolKind
    public var location: IndexLocation
    public var containerName: String?
    public var detail: String?

    public init(
        name: String,
        kind: IndexSymbolKind,
        location: IndexLocation,
        containerName: String? = nil,
        detail: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
        self.detail = detail
    }
}

public struct IndexSearchQuery: Sendable, Codable, Hashable {
    public var text: String
    public var rootPath: String
    public var kinds: [IndexSymbolKind]
    public var limit: Int

    public init(
        text: String,
        rootPath: String,
        kinds: [IndexSymbolKind] = [],
        limit: Int = 100
    ) {
        self.text = text
        self.rootPath = rootPath
        self.kinds = Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
        self.limit = max(1, limit)
    }
}

public struct IndexSearchResult: Sendable, Codable, Hashable {
    public var symbols: [IndexSymbol]
    public var freshness: IndexFreshness
    public var indexedGeneration: Int
    public var usedFallback: Bool
    public var warning: String?

    public init(
        symbols: [IndexSymbol] = [],
        freshness: IndexFreshness,
        indexedGeneration: Int,
        usedFallback: Bool = false,
        warning: String? = nil
    ) {
        self.symbols = symbols
        self.freshness = freshness
        self.indexedGeneration = max(0, indexedGeneration)
        self.usedFallback = usedFallback
        self.warning = warning
    }
}

public struct IndexRefreshResult: Sendable, Codable, Hashable {
    public var paths: [String]
    public var indexedGeneration: Int
    public var freshness: IndexFreshness

    public init(paths: [String], indexedGeneration: Int, freshness: IndexFreshness) {
        self.paths = paths.sorted()
        self.indexedGeneration = max(0, indexedGeneration)
        self.freshness = freshness
    }
}

/// Index implementations are expected to use LSP, a parser/search backend, or
/// another reviewed adapter. They never own file-watcher policy; the
/// coordinator feeds bounded changed paths through `refresh(paths:)`.
public protocol DoMoIndexProvider: Sendable {
    var descriptor: IndexProviderDescriptor { get }

    func search(_ query: IndexSearchQuery) async throws -> IndexSearchResult
    func refresh(paths: [String]) async throws -> IndexRefreshResult
}

public enum IndexCoordinatorError: Error, Sendable, Equatable {
    case invalidQuery(String)
    case provider(String)
    case unavailable
    case cancelled
}

public struct IndexCoordinatorStatus: Sendable, Codable, Hashable {
    public var freshness: IndexFreshness
    public var generation: Int
    public var indexedGeneration: Int
    public var pendingPaths: [String]

    public init(
        freshness: IndexFreshness,
        generation: Int,
        indexedGeneration: Int,
        pendingPaths: [String]
    ) {
        self.freshness = freshness
        self.generation = generation
        self.indexedGeneration = indexedGeneration
        self.pendingPaths = pendingPaths.sorted()
    }
}

/// Serializes watcher invalidation and index refreshes. A text-search fallback
/// can be supplied for provider outages; its results are explicitly marked
/// `.fallback`, never `.current`.
public actor IndexCoordinator {
    private let provider: any DoMoIndexProvider
    private let fallbackSearch: (@Sendable (IndexSearchQuery) async throws -> [IndexSymbol])?
    private var ignoredPaths: Set<String> = []
    private var pendingPaths: Set<String> = []
    private var generation = 0
    private var indexedGeneration = 0
    private var freshness: IndexFreshness = .unavailable

    public init(
        provider: any DoMoIndexProvider,
        fallbackSearch: (@Sendable (IndexSearchQuery) async throws -> [IndexSymbol])? = nil
    ) {
        self.provider = provider
        self.fallbackSearch = fallbackSearch
    }

    public func status() -> IndexCoordinatorStatus {
        IndexCoordinatorStatus(
            freshness: freshness,
            generation: generation,
            indexedGeneration: indexedGeneration,
            pendingPaths: Array(pendingPaths)
        )
    }

    public func setIgnoredPaths(_ paths: [String]) {
        ignoredPaths = Set(paths.map(Self.normalizePath).filter { !$0.isEmpty })
    }

    public func observe(_ event: ResourceReloadEvent) {
        let path = Self.normalizePath(event.path)
        guard !path.isEmpty, !isIgnored(path) else { return }
        pendingPaths.insert(path)
        generation += 1
        freshness = .stale
    }

    /// Refreshes exactly the paths invalidated before the call. If another
    /// event arrives while the provider is working, the completed result is not
    /// promoted to current and the newer path remains pending.
    @discardableResult
    public func refresh() async throws(IndexCoordinatorError) -> IndexRefreshResult {
        let paths = pendingPaths.sorted()
        guard !paths.isEmpty else {
            return IndexRefreshResult(
                paths: [],
                indexedGeneration: indexedGeneration,
                freshness: freshness
            )
        }
        let requestedGeneration = generation
        freshness = .building
        do {
            let result = try await provider.refresh(paths: paths)
            if Task.isCancelled { throw IndexCoordinatorError.cancelled }
            for path in paths { pendingPaths.remove(path) }
            indexedGeneration = max(indexedGeneration, result.indexedGeneration)
            if generation == requestedGeneration {
                indexedGeneration = generation
                freshness = .current
            } else {
                freshness = .stale
            }
            return IndexRefreshResult(
                paths: paths,
                indexedGeneration: indexedGeneration,
                freshness: freshness
            )
        } catch let error as IndexCoordinatorError {
            freshness = .stale
            throw error
        } catch {
            freshness = .stale
            throw .provider(String(describing: error))
        }
    }

    /// Normalizes provider output against coordinator state. Even a provider
    /// that claims `.current` is downgraded when a watcher event is pending.
    public func search(_ query: IndexSearchQuery) async throws(IndexCoordinatorError) -> IndexSearchResult {
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidQuery("Search text must not be empty.")
        }
        guard !query.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidQuery("Search root must not be empty.")
        }

        do {
            let result = try await provider.search(query)
            return normalize(result)
        } catch {
            guard let fallbackSearch else { throw .provider(String(describing: error)) }
            do {
                let symbols = try await fallbackSearch(query)
                return IndexSearchResult(
                    symbols: Array(symbols.prefix(query.limit)),
                    freshness: .fallback,
                    indexedGeneration: indexedGeneration,
                    usedFallback: true,
                    warning: "Index provider unavailable; showing search-only results."
                )
            } catch {
                throw .provider(String(describing: error))
            }
        }
    }

    private func normalize(_ result: IndexSearchResult) -> IndexSearchResult {
        if result.freshness == .current,
           freshness == .unavailable,
           generation == 0,
           pendingPaths.isEmpty,
           result.indexedGeneration >= indexedGeneration {
            // A provider may already have a current on-disk index before the
            // coordinator receives its first watcher event. Adopt that fact
            // once; later invalidations still force the stale path below.
            freshness = .current
            indexedGeneration = result.indexedGeneration
            return result
        }
        guard result.freshness == .current,
              freshness == .current,
              pendingPaths.isEmpty
        else {
            var stale = result
            stale.freshness = freshness == .unavailable ? .unavailable : .stale
            stale.warning = stale.warning ?? "Index results may be stale; refresh before treating them as source facts."
            return stale
        }
        var current = result
        current.indexedGeneration = max(current.indexedGeneration, indexedGeneration)
        return current
    }

    private func isIgnored(_ path: String) -> Bool {
        ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func normalizePath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
