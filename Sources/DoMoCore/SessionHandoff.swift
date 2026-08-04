// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

/// Why a session is being handed to another client or execution boundary.
public enum SessionHandoffKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Attach a second client to the same live session.
    case attach
    /// Continue the conversation in a selected execution boundary.
    case continueSession
    /// Transfer a plan and its artifacts to a different session.
    case transfer
}

/// The durable state of a handoff request.
public enum SessionHandoffState: String, Sendable, Codable, Hashable, CaseIterable {
    case proposed
    case accepted
    case completed
    case rejected
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .cancelled:
            true
        case .proposed, .accepted:
            false
        }
    }
}

/// The destination is deliberately an opaque set of references. The handoff
/// ledger does not start a backend or allocate a workspace; it records the
/// exact boundary the receiving runtime must validate before it acts.
public struct SessionHandoffTarget: Sendable, Codable, Hashable {
    public var sessionID: String?
    public var clientID: String?
    public var workspaceID: String?
    public var backendID: String?
    public var providerID: String?

    public init(
        sessionID: String? = nil,
        clientID: String? = nil,
        workspaceID: String? = nil,
        backendID: String? = nil,
        providerID: String? = nil
    ) {
        self.sessionID = sessionID
        self.clientID = clientID
        self.workspaceID = workspaceID
        self.backendID = backendID
        self.providerID = providerID
    }

    /// True when at least one execution/client reference has been selected.
    public var isSpecified: Bool {
        [sessionID, clientID, workspaceID, backendID, providerID]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }
}

/// A reviewable artifact reference carried across a handoff. `reference` is a
/// path, URI, or content-addressed id chosen by the producer; the ledger never
/// reads it or executes it.
public struct SessionHandoffArtifact: Sendable, Codable, Hashable {
    public var id: String
    public var kind: String
    public var reference: String
    public var sourceSessionID: String
    public var checksum: String?
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        kind: String,
        reference: String,
        sourceSessionID: String,
        checksum: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.sourceSessionID = sourceSessionID
        self.checksum = checksum
        self.metadata = metadata
    }
}

/// One step in a transferred plan. Completion is an assertion from the
/// receiving session, not an instruction for this ledger to execute.
public struct SessionHandoffPlanStep: Sendable, Codable, Hashable {
    public var id: String
    public var title: String
    public var dependsOn: [String]
    public var completed: Bool

    public init(
        id: String,
        title: String,
        dependsOn: [String] = [],
        completed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.dependsOn = dependsOn
        self.completed = completed
    }
}

/// A portable plan snapshot transferred with a session handoff.
public struct SessionHandoffPlan: Sendable, Codable, Hashable {
    public var summary: String
    public var steps: [SessionHandoffPlanStep]
    public var metadata: [String: JSONValue]

    public init(
        summary: String,
        steps: [SessionHandoffPlanStep] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.summary = summary
        self.steps = steps
        self.metadata = metadata
    }
}

/// Input to the handoff ledger. The source owner is distinct from the target
/// owner so attaching a second client cannot silently grant it source control.
public struct SessionHandoffRequest: Sendable, Codable, Hashable {
    public var id: String
    public var sourceSessionID: String
    public var sourceOwner: String
    public var targetOwner: String?
    public var kind: SessionHandoffKind
    public var target: SessionHandoffTarget
    public var plan: SessionHandoffPlan?
    public var artifacts: [SessionHandoffArtifact]
    public var metadata: [String: JSONValue]

    public init(
        id: String = UUIDv7.generate().description,
        sourceSessionID: String,
        sourceOwner: String,
        targetOwner: String? = nil,
        kind: SessionHandoffKind,
        target: SessionHandoffTarget = .init(),
        plan: SessionHandoffPlan? = nil,
        artifacts: [SessionHandoffArtifact] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.sourceOwner = sourceOwner
        self.targetOwner = targetOwner
        self.kind = kind
        self.target = target
        self.plan = plan
        self.artifacts = artifacts
        self.metadata = metadata
    }
}

/// The latest durable handoff state.
public struct SessionHandoffRecord: Sendable, Codable, Hashable {
    public let id: String
    public let sourceSessionID: String
    public let sourceOwner: String
    public let targetOwner: String?
    public let kind: SessionHandoffKind
    public var target: SessionHandoffTarget
    public let plan: SessionHandoffPlan?
    public let artifacts: [SessionHandoffArtifact]
    public var state: SessionHandoffState
    public let createdAt: String
    public var updatedAt: String
    public var acceptedAt: String?
    public var completedAt: String?
    public var resolutionMessage: String?
    public var metadata: [String: JSONValue]

    public init(
        request: SessionHandoffRequest,
        createdAt: String,
        state: SessionHandoffState = .proposed,
        updatedAt: String? = nil,
        acceptedAt: String? = nil,
        completedAt: String? = nil,
        resolutionMessage: String? = nil
    ) {
        self.id = request.id
        self.sourceSessionID = request.sourceSessionID
        self.sourceOwner = request.sourceOwner
        self.targetOwner = request.targetOwner
        self.kind = request.kind
        self.target = request.target
        self.plan = request.plan
        self.artifacts = request.artifacts
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.acceptedAt = acceptedAt
        self.completedAt = completedAt
        self.resolutionMessage = resolutionMessage
        self.metadata = request.metadata
    }
}

public enum SessionHandoffEventKind: String, Sendable, Codable, Hashable {
    case proposed
    case accepted
    case completed
    case rejected
    case cancelled
}

/// An append-only, resumable event for handoff consumers.
public struct SessionHandoffEvent: Sendable, Codable, Hashable {
    public let sequence: Int
    public let handoffID: String
    public let sourceSessionID: String
    public let timestamp: String
    public let kind: SessionHandoffEventKind
    public let state: SessionHandoffState
    public let message: String?
    public let metadata: [String: JSONValue]

    public init(
        sequence: Int,
        handoffID: String,
        sourceSessionID: String,
        timestamp: String,
        kind: SessionHandoffEventKind,
        state: SessionHandoffState,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.sequence = sequence
        self.handoffID = handoffID
        self.sourceSessionID = sourceSessionID
        self.timestamp = timestamp
        self.kind = kind
        self.state = state
        self.message = message
        self.metadata = metadata
    }
}

public struct SessionHandoffJournalEntry: Sendable, Codable, Hashable {
    public let event: SessionHandoffEvent
    public let record: SessionHandoffRecord

    public init(event: SessionHandoffEvent, record: SessionHandoffRecord) {
        self.event = event
        self.record = record
    }
}

/// Append-only storage for handoff records. The manager is the serialization
/// boundary; this value type intentionally has no locking of its own.
public struct SessionHandoffStore: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    public init(path: FilePath, permissions: FilePermissions = .ownerReadWrite) {
        self.path = path
        self.permissions = permissions
    }

    public static func create(
        directory: FilePath,
        fileName: String = "session-handoffs.jsonl",
        permissions: FilePermissions = .ownerReadWrite
    ) throws -> SessionHandoffStore {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let store = SessionHandoffStore(
            path: directory.appending(fileName),
            permissions: permissions
        )
        if !FileManager.default.fileExists(atPath: store.path.string) {
            try JSONLinesFileWriter(path: store.path, permissions: permissions)
                .replaceContents(with: [SessionHandoffJournalEntry]())
        }
        return store
    }

    public func append(_ entry: SessionHandoffJournalEntry) throws {
        try JSONLinesFileWriter(path: path, permissions: permissions).append(entry)
    }

    public func records() throws -> [SessionHandoffJournalEntry] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        return try JSONLines.decode(
            SessionHandoffJournalEntry.self,
            contentsOf: path,
            options: .strict
        )
    }

    public func latest() throws -> [String: SessionHandoffRecord] {
        var result: [String: SessionHandoffRecord] = [:]
        for entry in try records() { result[entry.record.id] = entry.record }
        return result
    }

    public func events(after sequence: Int = 0, handoffID: String? = nil) throws -> [SessionHandoffEvent] {
        try records()
            .map(\.event)
            .filter { $0.sequence > sequence && (handoffID == nil || $0.handoffID == handoffID) }
            .sorted { $0.sequence < $1.sequence }
    }

    public func export(handoffID: String) throws -> [SessionHandoffJournalEntry] {
        try records().filter { $0.record.id == handoffID }
    }
}

public enum SessionHandoffError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case duplicate(String)
    case notFound(String)
    case ownershipDenied(String)
    case invalidTransition(id: String, state: SessionHandoffState)
    case invalidCursor(Int)
}

/// Owns handoff state transitions and persistence. It never attaches a client,
/// starts a backend, or promotes a workspace itself; those side effects belong
/// to the runtime that accepts the record.
public actor SessionHandoffManager {
    private let store: SessionHandoffStore?
    private let now: @Sendable () -> String

    private var loaded = false
    private var nextSequence = 0
    private var recordsByID: [String: SessionHandoffRecord] = [:]
    private var eventLog: [SessionHandoffEvent] = []

    public init(
        store: SessionHandoffStore? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.now = now
    }

    public func propose(_ request: SessionHandoffRequest) throws -> SessionHandoffRecord {
        try loadIfNeeded()
        try validate(request)
        guard recordsByID[request.id] == nil else { throw SessionHandoffError.duplicate(request.id) }
        let record = SessionHandoffRecord(request: request, createdAt: now())
        _ = try append(record: record, kind: .proposed, message: "Handoff proposed.")
        return record
    }

    public func snapshot(id: String) throws -> SessionHandoffRecord? {
        try loadIfNeeded()
        return recordsByID[id]
    }

    public func list(
        sourceSessionID: String? = nil,
        state: SessionHandoffState? = nil
    ) throws -> [SessionHandoffRecord] {
        try loadIfNeeded()
        return recordsByID.values
            .filter {
                (sourceSessionID == nil || $0.sourceSessionID == sourceSessionID)
                    && (state == nil || $0.state == state)
            }
            .sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt < rhs.updatedAt
            }
    }

    public func events(after sequence: Int = 0, handoffID: String? = nil) throws -> [SessionHandoffEvent] {
        try loadIfNeeded()
        guard sequence >= 0 else { throw SessionHandoffError.invalidCursor(sequence) }
        return eventLog.filter {
            $0.sequence > sequence && (handoffID == nil || $0.handoffID == handoffID)
        }
    }

    public func accept(id: String, owner: String) throws -> SessionHandoffRecord {
        try transition(
            id: id,
            owner: owner,
            allowedStates: [.proposed],
            state: .accepted,
            kind: .accepted,
            message: "Handoff accepted."
        ) { record, timestamp in
            record.acceptedAt = timestamp
        }
    }

    public func complete(
        id: String,
        owner: String,
        target: SessionHandoffTarget? = nil,
        metadata: [String: JSONValue] = [:]
    ) throws -> SessionHandoffRecord {
        try loadIfNeeded()
        guard var record = recordsByID[id] else { throw SessionHandoffError.notFound(id) }
        try authorize(record, owner: owner, targetOperation: true)
        guard record.state == .accepted else {
            throw SessionHandoffError.invalidTransition(id: id, state: record.state)
        }
        if let target {
            try validateTarget(target, sourceSessionID: record.sourceSessionID)
            record.target = target
        }
        guard record.target.isSpecified else {
            throw SessionHandoffError.invalidRequest("A completed handoff must identify a target.")
        }
        record.state = .completed
        record.completedAt = now()
        record.updatedAt = record.completedAt ?? now()
        record.resolutionMessage = "Handoff completed."
        record.metadata.merge(metadata) { _, latest in latest }
        _ = try append(record: record, kind: .completed, message: record.resolutionMessage)
        return record
    }

    public func reject(id: String, owner: String, reason: String) throws -> SessionHandoffRecord {
        try transition(
            id: id,
            owner: owner,
            allowedStates: [.proposed, .accepted],
            state: .rejected,
            kind: .rejected,
            message: reason
        ) { record, _ in
            record.resolutionMessage = reason
        }
    }

    public func cancel(id: String, owner: String, reason: String = "Handoff cancelled.") throws -> SessionHandoffRecord {
        try transition(
            id: id,
            owner: owner,
            allowedStates: [.proposed, .accepted],
            state: .cancelled,
            kind: .cancelled,
            message: reason
        ) { record, _ in
            record.resolutionMessage = reason
        }
    }

    public func export(id: String) throws -> [SessionHandoffJournalEntry] {
        try loadIfNeeded()
        guard recordsByID[id] != nil else { throw SessionHandoffError.notFound(id) }
        if let store { return try store.export(handoffID: id) }
        return eventLog.compactMap { event in
            guard event.handoffID == id, let record = recordsByID[id] else { return nil }
            return SessionHandoffJournalEntry(event: event, record: record)
        }
    }

    private func transition(
        id: String,
        owner: String,
        allowedStates: Set<SessionHandoffState>,
        state: SessionHandoffState,
        kind: SessionHandoffEventKind,
        message: String,
        mutate: (inout SessionHandoffRecord, String) -> Void
    ) throws -> SessionHandoffRecord {
        try loadIfNeeded()
        guard var record = recordsByID[id] else { throw SessionHandoffError.notFound(id) }
        try authorize(record, owner: owner, targetOperation: state == .accepted || state == .completed)
        guard allowedStates.contains(record.state) else {
            throw SessionHandoffError.invalidTransition(id: id, state: record.state)
        }
        let timestamp = now()
        record.state = state
        record.updatedAt = timestamp
        mutate(&record, timestamp)
        _ = try append(record: record, kind: kind, message: message)
        return record
    }

    private func authorize(
        _ record: SessionHandoffRecord,
        owner: String,
        targetOperation: Bool
    ) throws {
        let expected = targetOperation ? (record.targetOwner ?? record.sourceOwner) : record.sourceOwner
        guard owner == expected else { throw SessionHandoffError.ownershipDenied(record.id) }
    }

    private func validate(_ request: SessionHandoffRequest) throws {
        let fields: [(String, String)] = [
            ("id", request.id),
            ("sourceSessionID", request.sourceSessionID),
            ("sourceOwner", request.sourceOwner),
        ]
        for (name, value) in fields where Self.isBlank(value) {
            throw SessionHandoffError.invalidRequest("Handoff \(name) must not be empty.")
        }
        if let targetOwner = request.targetOwner, Self.isBlank(targetOwner) {
            throw SessionHandoffError.invalidRequest("Handoff targetOwner must not be empty.")
        }
        try validateTarget(request.target, sourceSessionID: request.sourceSessionID)
        try validatePlan(request.plan)
        var artifactIDs: Set<String> = []
        for artifact in request.artifacts {
            guard !Self.isBlank(artifact.id), !Self.isBlank(artifact.kind), !Self.isBlank(artifact.reference) else {
                throw SessionHandoffError.invalidRequest("Handoff artifacts require id, kind, and reference.")
            }
            guard artifactIDs.insert(artifact.id).inserted else {
                throw SessionHandoffError.invalidRequest("Handoff artifact ids must be unique.")
            }
            guard !Self.isBlank(artifact.sourceSessionID) else {
                throw SessionHandoffError.invalidRequest("Handoff artifact sourceSessionID must not be empty.")
            }
        }
    }

    private func validateTarget(
        _ target: SessionHandoffTarget,
        sourceSessionID: String
    ) throws {
        if let sessionID = target.sessionID, Self.isBlank(sessionID) {
            throw SessionHandoffError.invalidRequest("Handoff target sessionID must not be empty.")
        }
        if target.sessionID == sourceSessionID {
            throw SessionHandoffError.invalidRequest("Handoff target sessionID must differ from the source.")
        }
        let values: [(String, String?)] = [
            ("clientID", target.clientID),
            ("workspaceID", target.workspaceID),
            ("backendID", target.backendID),
            ("providerID", target.providerID),
        ]
        for (name, value) in values where value.map(Self.isBlank) == true {
            throw SessionHandoffError.invalidRequest("Handoff target \(name) must not be empty.")
        }
    }

    private func validatePlan(_ plan: SessionHandoffPlan?) throws {
        guard let plan else { return }
        guard !Self.isBlank(plan.summary) else {
            throw SessionHandoffError.invalidRequest("Handoff plan summary must not be empty.")
        }
        var ids: Set<String> = []
        for step in plan.steps {
            guard !Self.isBlank(step.id), !Self.isBlank(step.title) else {
                throw SessionHandoffError.invalidRequest("Handoff plan steps require id and title.")
            }
            guard ids.insert(step.id).inserted else {
                throw SessionHandoffError.invalidRequest("Handoff plan step ids must be unique.")
            }
        }
        let stepIDs = ids
        for step in plan.steps where step.dependsOn.contains(where: { !stepIDs.contains($0) || $0 == step.id }) {
            throw SessionHandoffError.invalidRequest("Handoff plan dependencies must name other steps.")
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if let store {
            for row in try store.records() {
                guard row.event.sequence > nextSequence else {
                    throw SessionHandoffError.invalidCursor(row.event.sequence)
                }
                nextSequence = row.event.sequence
                recordsByID[row.record.id] = row.record
                eventLog.append(row.event)
            }
        }
        loaded = true
    }

    @discardableResult
    private func append(
        record: SessionHandoffRecord,
        kind: SessionHandoffEventKind,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) throws -> SessionHandoffEvent {
        nextSequence += 1
        let event = SessionHandoffEvent(
            sequence: nextSequence,
            handoffID: record.id,
            sourceSessionID: record.sourceSessionID,
            timestamp: record.updatedAt,
            kind: kind,
            state: record.state,
            message: message,
            metadata: metadata
        )
        if let store {
            do {
                try store.append(SessionHandoffJournalEntry(event: event, record: record))
            } catch {
                nextSequence -= 1
                throw error
            }
        }
        recordsByID[record.id] = record
        eventLog.append(event)
        return event
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
