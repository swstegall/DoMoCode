// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

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
