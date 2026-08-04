// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// Debounced reload coordination for trusted resources and workspace files.
/// Filesystem, repository, or editor watchers feed events into this actor; the
/// actor owns coalescing, cancellation, and the rule that an active turn's
/// resource snapshot is never changed behind its back.

public enum ResourceReloadKind: String, Sendable, Codable, Hashable, CaseIterable {
    case skill
    case command
    case theme
    case tool
    case workspace
}

public struct ResourceReloadEvent: Sendable, Codable, Hashable {
    public var path: String
    public var kind: ResourceReloadKind
    public var resourceID: String?
    public var contentDigest: String?
    public var observedAt: String

    public init(
        path: String,
        kind: ResourceReloadKind,
        resourceID: String? = nil,
        contentDigest: String? = nil,
        observedAt: String
    ) {
        self.path = path
        self.kind = kind
        self.resourceID = resourceID
        self.contentDigest = contentDigest
        self.observedAt = observedAt
    }
}

public struct ResourceReloadNotice: Sendable, Codable, Hashable {
    public var generation: Int
    public var changes: [ResourceReloadEvent]
    public var requiresPrompt: Bool
    public var activeTurnID: String?

    public init(
        generation: Int,
        changes: [ResourceReloadEvent],
        requiresPrompt: Bool,
        activeTurnID: String?
    ) {
        self.generation = generation
        self.changes = changes
        self.requiresPrompt = requiresPrompt
        self.activeTurnID = activeTurnID
    }
}

public struct ResourceTurnSnapshot: Sendable, Codable, Hashable {
    public var turnID: String
    public var generation: Int
    public var resourceIDs: [String]

    public init(turnID: String, generation: Int, resourceIDs: [String]) {
        self.turnID = turnID
        self.generation = generation
        self.resourceIDs = Array(Set(resourceIDs)).sorted()
    }
}

public enum ResourceReloadError: Error, Sendable, Equatable {
    case emptyTurnID
    case turnAlreadyActive(String)
    case noActiveTurn
    case wrongTurn(String)
    case watcherAlreadyRunning
}

/// One path owned by a portable polling watcher. Platform-native adapters can
/// implement ``ResourceWatchSource`` with FSEvents, inotify, or an editor
/// bridge; this source keeps the core usable on every supported platform and
/// in installations where those APIs are unavailable.
public struct ResourceWatchPath: Sendable, Codable, Hashable {
    public var path: String
    public var kind: ResourceReloadKind
    public var resourceID: String?

    public init(
        path: String,
        kind: ResourceReloadKind,
        resourceID: String? = nil
    ) {
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.resourceID = resourceID
    }
}

/// A bounded, dependency-free watcher for trusted resource and workspace
/// paths. It records an initial snapshot, then emits only changes observed on
/// later polls. The stream owns its polling task: cancelling the consumer or
/// stopping a ``ResourceWatchSubscription`` stops the task without leaving a
/// late event that could reload a running turn.
public struct PollingResourceWatchSource: ResourceWatchSource {
    public let paths: [ResourceWatchPath]
    public let interval: Duration

    public init(
        paths: [ResourceWatchPath],
        interval: Duration = .milliseconds(250)
    ) {
        var seen = Set<ResourceWatchPath>()
        self.paths = paths.filter { !$0.path.isEmpty && seen.insert($0).inserted }
        self.interval = interval < .milliseconds(20) ? .milliseconds(20) : interval
    }

    public func events() -> AsyncStream<ResourceReloadEvent> {
        let source = self
        return AsyncStream { continuation in
            let task = Task {
                var previous = source.snapshot()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: source.interval)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }

                    let current = source.snapshot()
                    for path in source.changedPaths(from: previous, to: current) {
                        guard let watched = source.watchPath(for: path) else { continue }
                        continuation.yield(ResourceReloadEvent(
                            path: path,
                            kind: watched.kind,
                            resourceID: watched.resourceID,
                            observedAt: Self.timestamp()
                        ))
                    }
                    previous = current
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct FileStamp: Sendable, Hashable {
        let exists: Bool
        let modificationMicros: Int64
        let size: Int64
        let isDirectory: Bool
    }

    private func snapshot() -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for watched in paths {
            let root = Self.normalize(watched.path)
            guard !root.isEmpty else { continue }
            result[root] = Self.stamp(for: root)
            guard result[root]?.isDirectory == true,
                  let children = FileManager.default.subpaths(atPath: root)
            else { continue }
            for child in children {
                let path = Self.normalize(root + "/" + child)
                result[path] = Self.stamp(for: path)
            }
        }
        return result
    }

    private func changedPaths(
        from previous: [String: FileStamp],
        to current: [String: FileStamp]
    ) -> [String] {
        Set(previous.keys).union(current.keys).filter { path in
            previous[path] != current[path]
        }.sorted()
    }

    private func watchPath(for path: String) -> ResourceWatchPath? {
        paths
            .filter { watched in
                let root = Self.normalize(watched.path)
                return path == root || path.hasPrefix(root + "/")
            }
            .sorted { $0.path.count > $1.path.count }
            .first
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.path
    }

    private static func stamp(for path: String) -> FileStamp {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let values = try? url.resourceValues(forKeys: [
                  .contentModificationDateKey,
                  .fileSizeKey,
                  .isDirectoryKey,
              ])
        else {
            return FileStamp(exists: false, modificationMicros: 0, size: 0, isDirectory: false)
        }
        let modification = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileStamp(
            exists: true,
            modificationMicros: Int64(modification * 1_000_000),
            size: Int64(values.fileSize ?? 0),
            isDirectory: values.isDirectory == true
        )
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

/// A platform-specific watcher feeds facts into the shared reload boundary.
/// The source may be a DispatchSource, editor bridge, repository watcher, or a
/// remote event stream; it must not reload resources or mutate a live turn.
public protocol ResourceWatchSource: Sendable {
    func events() -> AsyncStream<ResourceReloadEvent>
}

/// Owns cancellation for one watcher subscription. Keeping this outside the
/// coordinator makes a dropped client harmless: the stream task is cancelled
/// before the source can deliver late events into a new session.
public actor ResourceWatchSubscription {
    private let source: any ResourceWatchSource
    private let coordinator: ResourceReloadCoordinator
    private var task: Task<Void, Never>?

    public init(
        source: any ResourceWatchSource,
        coordinator: ResourceReloadCoordinator
    ) {
        self.source = source
        self.coordinator = coordinator
    }

    public var isRunning: Bool { task != nil }

    public func start() throws(ResourceReloadError) {
        guard task == nil else { throw .watcherAlreadyRunning }
        let stream = source.events()
        let coordinator = self.coordinator
        task = Task {
            for await event in stream {
                guard !Task.isCancelled else { return }
                await coordinator.observe(event)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

/// A single coalescing point for every resource watcher. The callback is the
/// prompt/notice seam owned by the client; this actor never mutates a loaded
/// skill, command, theme, or tool itself.
public actor ResourceReloadCoordinator {
    public let debounceMilliseconds: Int

    private let onNotice: (@Sendable (ResourceReloadNotice) async -> Void)?
    private var pending: [String: ResourceReloadEvent] = [:]
    private var generation = 0
    private var activeTurn: ResourceTurnSnapshot?
    private var flushTask: Task<Void, Never>?

    public init(
        debounceMilliseconds: Int = 200,
        onNotice: (@Sendable (ResourceReloadNotice) async -> Void)? = nil
    ) {
        self.debounceMilliseconds = max(0, debounceMilliseconds)
        self.onNotice = onNotice
    }

    public func currentGeneration() -> Int { generation }

    public func beginTurn(
        id: String,
        resourceIDs: [String] = []
    ) throws(ResourceReloadError) -> ResourceTurnSnapshot {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTurnID }
        guard activeTurn == nil else { throw .turnAlreadyActive(activeTurn!.turnID) }
        let snapshot = ResourceTurnSnapshot(
            turnID: trimmed,
            generation: generation,
            resourceIDs: resourceIDs
        )
        activeTurn = snapshot
        return snapshot
    }

    public func endTurn(id: String) throws(ResourceReloadError) {
        guard let activeTurn else { throw .noActiveTurn }
        guard activeTurn.turnID == id else { throw .wrongTurn(id) }
        self.activeTurn = nil
    }

    /// Record the newest event for a path/kind pair. The next flush is the only
    /// point at which a generation advances, so a turn can keep reading its
    /// original snapshot while a notice is waiting for user acknowledgement.
    public func observe(_ event: ResourceReloadEvent) {
        let path = event.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        var normalized = event
        normalized.path = path
        pending[Self.key(for: normalized)] = normalized
        scheduleFlush()
    }

    /// Flush immediately, primarily for deterministic tests and for an adapter
    /// that has already performed its own debounce. Returns `nil` when there is
    /// no pending change.
    @discardableResult
    public func flush() -> ResourceReloadNotice? {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return nil }
        generation += 1
        let changes = pending.values.sorted {
            ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue)
        }
        pending = [:]

        let turn = activeTurn
        let touchesSnapshot = changes.contains { event in
            guard let turn else { return false }
            guard let resourceID = event.resourceID else { return true }
            return turn.resourceIDs.contains(resourceID)
        }
        return ResourceReloadNotice(
            generation: generation,
            changes: changes,
            requiresPrompt: touchesSnapshot,
            activeTurnID: touchesSnapshot ? turn?.turnID : nil
        )
    }

    /// Cancel a pending debounce without emitting a notice or advancing the
    /// generation. A cancelled watcher operation therefore has no visible side
    /// effect and cannot leave a late task to reload a running turn.
    public func cancelPending() {
        flushTask?.cancel()
        flushTask = nil
        pending = [:]
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = debounceMilliseconds
        flushTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            await self.emitPendingNotice()
        }
    }

    private func emitPendingNotice() async {
        guard let notice = flush() else { return }
        await onNotice?(notice)
    }

    private static func key(for event: ResourceReloadEvent) -> String {
        event.kind.rawValue + "\u{0}" + event.path
    }
}
