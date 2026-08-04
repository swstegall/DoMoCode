// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

public struct DependencyEdge: Sendable, Codable, Hashable {
    public var sourcePath: String
    public var targetPath: String
    public var kind: String

    public init(sourcePath: String, targetPath: String, kind: String = "imports") {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.kind = kind
    }
}

public struct DependencySearchResult: Sendable, Codable, Hashable {
    public var targetPath: String
    public var sourcePaths: [String]
    public var edges: [DependencyEdge]
    public var freshness: IndexFreshness
    public var indexedGeneration: Int
    public var usedFallback: Bool
    public var warning: String?

    public init(
        targetPath: String,
        sourcePaths: [String] = [],
        edges: [DependencyEdge] = [],
        freshness: IndexFreshness,
        indexedGeneration: Int,
        usedFallback: Bool = false,
        warning: String? = nil
    ) {
        self.targetPath = targetPath
        self.sourcePaths = sourcePaths.sorted()
        self.edges = edges.sorted {
            ($0.sourcePath, $0.targetPath, $0.kind) < ($1.sourcePath, $1.targetPath, $1.kind)
        }
        self.freshness = freshness
        self.indexedGeneration = max(0, indexedGeneration)
        self.usedFallback = usedFallback
        self.warning = warning
    }
}

public protocol DoMoDependencyIndexProvider: Sendable {
    func refresh(paths: [String]) async throws -> [DependencyEdge]
}

public enum DependencyIndexCoordinatorError: Error, Sendable, Equatable {
    case invalidRoot(String)
    case invalidTarget(String)
    case provider(String)
    case cancelled
}

/// Maintains a bounded reverse-dependency graph while sharing the same
/// invalidation semantics as the symbol index. Provider output is filtered to
/// the workspace and a stale graph is always reported as stale or fallback.
public actor DependencyIndexCoordinator {
    private let rootPath: String
    private let provider: any DoMoDependencyIndexProvider
    private let fallbackSearch: (@Sendable (String) async throws -> [String])?
    private var ignoredPaths: Set<String> = []
    private var pendingPaths: Set<String> = []
    private var edgesBySource: [String: [DependencyEdge]] = [:]
    private var generation = 0
    private var indexedGeneration = 0
    private var freshness: IndexFreshness = .unavailable

    public init(
        rootPath: String,
        provider: any DoMoDependencyIndexProvider,
        fallbackSearch: (@Sendable (String) async throws -> [String])? = nil
    ) throws(DependencyIndexCoordinatorError) {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw .invalidRoot(rootPath)
        }
        self.rootPath = Self.normalize(trimmed)
        self.provider = provider
        self.fallbackSearch = fallbackSearch
    }

    public func observe(_ event: ResourceReloadEvent) {
        let path = Self.normalize(event.path)
        guard Self.within(path, root: rootPath), !isIgnored(path) else { return }
        pendingPaths.insert(path)
        generation += 1
        freshness = .stale
    }

    @discardableResult
    public func refresh() async throws(DependencyIndexCoordinatorError) -> IndexFreshness {
        let paths = pendingPaths.sorted()
        guard !paths.isEmpty else { return freshness }
        let requestedGeneration = generation
        freshness = .building
        do {
            let edges = try await provider.refresh(paths: paths)
            if Task.isCancelled { throw DependencyIndexCoordinatorError.cancelled }
            for path in paths { pendingPaths.remove(path) }
            for path in paths {
                edgesBySource[path] = edges
                    .filter {
                        Self.normalize($0.sourcePath) == path
                            && Self.within(Self.normalize($0.targetPath), root: rootPath)
                    }
                    .compactMap(Self.normalizedEdge)
            }
            if generation == requestedGeneration {
                indexedGeneration = generation
                freshness = .current
            } else {
                freshness = .stale
            }
            return freshness
        } catch let error as DependencyIndexCoordinatorError {
            freshness = .stale
            throw error
        } catch {
            freshness = .stale
            throw .provider(String(describing: error))
        }
    }

    public func setIgnoredPaths(_ paths: [String]) {
        ignoredPaths = Set(paths.map(Self.normalize).filter { !$0.isEmpty })
    }

    public func searchDependents(of target: String, limit: Int = 100) async throws(DependencyIndexCoordinatorError) -> DependencySearchResult {
        let normalizedTarget = Self.normalize(target)
        guard Self.within(normalizedTarget, root: rootPath) else {
            throw .invalidTarget(target)
        }
        let boundedLimit = max(1, limit)
        if let fallbackSearch, freshness != .current || !pendingPaths.isEmpty {
            do {
                let paths = try await fallbackSearch(normalizedTarget)
                return DependencySearchResult(
                    targetPath: normalizedTarget,
                    sourcePaths: Array(paths.map(Self.normalize).filter { Self.within($0, root: rootPath) }.prefix(boundedLimit)),
                    freshness: .fallback,
                    indexedGeneration: indexedGeneration,
                    usedFallback: true,
                    warning: "Dependency index is not current; showing search-only dependents."
                )
            } catch {
                throw .provider(String(describing: error))
            }
        }

        let matches = edgesBySource.values
            .flatMap { $0 }
            .filter { Self.normalize($0.targetPath) == normalizedTarget }
        let unique = Dictionary(grouping: matches, by: { Self.normalize($0.sourcePath) })
            .keys.sorted()
        return DependencySearchResult(
            targetPath: normalizedTarget,
            sourcePaths: Array(unique.prefix(boundedLimit)),
            edges: Array(matches.prefix(boundedLimit)),
            freshness: freshness,
            indexedGeneration: indexedGeneration,
            warning: freshness == .current ? nil : "Dependency results may be stale; refresh before treating them as source facts."
        )
    }

    public func status() -> IndexCoordinatorStatus {
        IndexCoordinatorStatus(
            freshness: freshness,
            generation: generation,
            indexedGeneration: indexedGeneration,
            pendingPaths: Array(pendingPaths)
        )
    }

    private func isIgnored(_ path: String) -> Bool {
        ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func normalizedEdge(_ edge: DependencyEdge) -> DependencyEdge? {
        let source = normalize(edge.sourcePath)
        let target = normalize(edge.targetPath)
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return DependencyEdge(sourcePath: source, targetPath: target, kind: edge.kind)
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.path
    }

    private static func within(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
