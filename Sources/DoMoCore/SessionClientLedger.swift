// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

/// The role a client currently holds for one session.
public enum SessionClientRole: String, Codable, Sendable, Hashable, CaseIterable {
    /// The client may mirror state but cannot answer prompts or mutate the turn.
    case observer
    /// The client currently owns session mutations and permission answers.
    case authority
}

/// A durable snapshot of one client attachment. The record is a lease-shaped
/// presence value, not a network connection: an in-process manager marks old
/// attachments inactive on restart so a dead client can never retain authority.
public struct SessionClientAttachment: Codable, Sendable, Hashable {
    public let clientID: String
    public let sessionID: String
    public let owner: String
    public var role: SessionClientRole
    public var active: Bool
    public let attachedAt: String
    public var updatedAt: String
    /// The last global session event sequence the client has durably consumed.
    public var eventCursor: Int

    public init(
        clientID: String,
        sessionID: String,
        owner: String,
        role: SessionClientRole = .observer,
        active: Bool = true,
        attachedAt: String,
        updatedAt: String? = nil,
        eventCursor: Int = 0
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.owner = owner
        self.role = role
        self.active = active
        self.attachedAt = attachedAt
        self.updatedAt = updatedAt ?? attachedAt
        self.eventCursor = max(0, eventCursor)
    }
}

public enum SessionClientEventKind: String, Codable, Sendable, Hashable {
    case attached
    case detached
    case authorityClaimed
    case authorityReleased
    case authorityTransferred
    case cursorAdvanced
}

/// An append-only mirror event. Clients may resume from `sequence` after a
/// dropped SSE frame, then fold the latest attachment snapshot from the event.
public struct SessionClientEvent: Codable, Sendable, Hashable {
    public let sequence: Int
    public let timestamp: String
    public let kind: SessionClientEventKind
    public let attachment: SessionClientAttachment
    public let previousAuthorityClientID: String?

    public init(
        sequence: Int,
        timestamp: String,
        kind: SessionClientEventKind,
        attachment: SessionClientAttachment,
        previousAuthorityClientID: String? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.attachment = attachment
        self.previousAuthorityClientID = previousAuthorityClientID
    }
}

public struct SessionClientJournalEntry: Codable, Sendable, Hashable {
    public let event: SessionClientEvent
    public let attachment: SessionClientAttachment

    public init(event: SessionClientEvent, attachment: SessionClientAttachment) {
        self.event = event
        self.attachment = attachment
    }
}

/// Append-only storage for client presence and mirror cursors.
public struct SessionClientStore: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    public init(path: FilePath, permissions: FilePermissions = .ownerReadWrite) {
        self.path = path
        self.permissions = permissions
    }

    public static func create(
        directory: FilePath,
        fileName: String = "session-clients.jsonl",
        permissions: FilePermissions = .ownerReadWrite
    ) throws -> SessionClientStore {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let store = SessionClientStore(path: directory.appending(fileName), permissions: permissions)
        if !FileManager.default.fileExists(atPath: store.path.string) {
            try JSONLinesFileWriter(path: store.path, permissions: permissions)
                .replaceContents(with: [SessionClientJournalEntry]())
        }
        return store
    }

    public func append(_ entry: SessionClientJournalEntry) throws {
        try JSONLinesFileWriter(path: path, permissions: permissions).append(entry)
    }

    public func records() throws -> [SessionClientJournalEntry] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        return try JSONLines.decode(
            SessionClientJournalEntry.self,
            contentsOf: path,
            options: .strict
        )
    }

    public func latest() throws -> [String: SessionClientAttachment] {
        var result: [String: SessionClientAttachment] = [:]
        for row in try records() {
            result[SessionClientManager.key(sessionID: row.attachment.sessionID, clientID: row.attachment.clientID)] = row.attachment
        }
        return result
    }

    public func events(
        after sequence: Int = 0,
        sessionID: String? = nil
    ) throws -> [SessionClientEvent] {
        try records()
            .map(\.event)
            .filter { row in
                row.sequence > sequence && (sessionID == nil || row.attachment.sessionID == sessionID)
            }
            .sorted { $0.sequence < $1.sequence }
    }

    public func export(
        sessionID: String,
        clientID: String? = nil
    ) throws -> [SessionClientJournalEntry] {
        try records().filter { row in
            row.attachment.sessionID == sessionID
                && (clientID == nil || row.attachment.clientID == clientID)
        }
    }
}

public enum SessionClientError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case notFound(sessionID: String, clientID: String)
    case ownershipDenied(clientID: String)
    case authorityHeld(clientID: String)
    case authorityRequired(sessionID: String)
    case invalidCursor(Int)
}

/// Serializes client presence, authority, and event cursors for a session.
///
/// This manager deliberately does not own a socket or infer liveness from a
/// dropped HTTP request. Attach/detach and authority transfer are explicit;
/// restart recovery marks every old attachment inactive before a new client can
/// become authoritative. That makes permission ownership a durable decision,
/// not whichever client happened to receive the latest SSE frame.
public actor SessionClientManager {
    private let store: SessionClientStore?
    private let now: @Sendable () -> String

    private var loaded = false
    private var nextSequence = 0
    private var attachments: [String: SessionClientAttachment] = [:]
    private var eventLog: [SessionClientEvent] = []

    public init(
        store: SessionClientStore? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.now = now
    }

    /// Attach idempotently. The first active client for a session may become
    /// authoritative; later clients are observers until the authority is
    /// explicitly transferred or released.
    public func attach(
        sessionID: String,
        clientID: String,
        owner: String,
        requestAuthority: Bool = true
    ) throws -> SessionClientAttachment {
        try loadIfNeeded()
        try validate(sessionID: sessionID, clientID: clientID, owner: owner)
        let key = Self.key(sessionID: sessionID, clientID: clientID)
        let existing = attachments[key]
        var attachment: SessionClientAttachment
        if let existing = attachments[key] {
            guard existing.owner == owner else {
                throw SessionClientError.ownershipDenied(clientID: clientID)
            }
            attachment = existing
            attachment.active = true
            attachment.updatedAt = now()
        } else {
            attachment = SessionClientAttachment(
                clientID: clientID,
                sessionID: sessionID,
                owner: owner,
                role: .observer,
                attachedAt: now()
            )
        }

        let existingAuthority = authority(for: sessionID)
        if requestAuthority, existingAuthority == nil {
            attachment.role = .authority
        } else if attachment.role == .authority,
                  let existingAuthority,
                  existingAuthority.clientID != clientID {
            // A stale durable role can never displace a live authority.
            attachment.role = .observer
        }
        let kind: SessionClientEventKind
        if existing == nil {
            kind = attachment.role == .authority ? .authorityClaimed : .attached
        } else if attachment.role == .authority && existing?.role != .authority {
            kind = .authorityClaimed
        } else {
            kind = .attached
        }
        _ = try append(attachment: attachment, kind: kind)
        return attachment
    }

    public func detach(sessionID: String, clientID: String, owner: String) throws -> SessionClientAttachment {
        try loadIfNeeded()
        var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active else { return attachment }
        attachment.active = false
        attachment.role = .observer
        attachment.updatedAt = now()
        _ = try append(attachment: attachment, kind: .detached)
        return attachment
    }

    /// Release authority without detaching. The next explicit attach may claim
    /// it, but an already-attached observer must still be promoted explicitly.
    public func releaseAuthority(
        sessionID: String,
        clientID: String,
        owner: String
    ) throws -> SessionClientAttachment {
        try loadIfNeeded()
        var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active, attachment.role == .authority else {
            throw SessionClientError.authorityRequired(sessionID: sessionID)
        }
        attachment.role = .observer
        attachment.updatedAt = now()
        _ = try append(attachment: attachment, kind: .authorityReleased)
        return attachment
    }

    /// Transfer authority atomically from the current owner to an active
    /// observer. No client can seize a prompt-answering role by reconnecting.
    public func transferAuthority(
        sessionID: String,
        fromClientID: String,
        toClientID: String,
        owner: String
    ) throws -> SessionClientAttachment {
        try loadIfNeeded()
        guard fromClientID != toClientID else {
            return try requireAuthority(sessionID: sessionID, clientID: fromClientID, owner: owner)
        }
        let source = try ownedAttachment(sessionID: sessionID, clientID: fromClientID, owner: owner)
        guard source.active, source.role == .authority else {
            throw SessionClientError.authorityRequired(sessionID: sessionID)
        }
        var target = try attachment(sessionID: sessionID, clientID: toClientID)
        guard target.active else {
            throw SessionClientError.notFound(sessionID: sessionID, clientID: toClientID)
        }
        var released = source
        released.role = .observer
        released.updatedAt = now()
        target.role = .authority
        target.updatedAt = now()
        _ = try append(
            attachment: released,
            kind: .authorityTransferred,
            previousAuthorityClientID: source.clientID
        )
        _ = try append(
            attachment: target,
            kind: .authorityTransferred,
            previousAuthorityClientID: source.clientID
        )
        return target
    }

    public func heartbeat(sessionID: String, clientID: String, owner: String) throws -> SessionClientAttachment {
        try loadIfNeeded()
        var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active else {
            throw SessionClientError.notFound(sessionID: sessionID, clientID: clientID)
        }
        attachment.updatedAt = now()
        _ = try append(attachment: attachment, kind: .attached)
        return attachment
    }

    /// Advance a mirror cursor monotonically. A client may repeat the same
    /// cursor after a retry, but can never move the durable position backward.
    public func advanceCursor(
        sessionID: String,
        clientID: String,
        owner: String,
        sequence: Int
    ) throws -> SessionClientAttachment {
        try loadIfNeeded()
        guard sequence >= 0 else { throw SessionClientError.invalidCursor(sequence) }
        var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active else {
            throw SessionClientError.notFound(sessionID: sessionID, clientID: clientID)
        }
        guard sequence >= attachment.eventCursor else {
            throw SessionClientError.invalidCursor(sequence)
        }
        guard sequence != attachment.eventCursor else { return attachment }
        attachment.eventCursor = sequence
        attachment.updatedAt = now()
        _ = try append(attachment: attachment, kind: .cursorAdvanced)
        return attachment
    }

    public func list(sessionID: String, includeInactive: Bool = false) throws -> [SessionClientAttachment] {
        try loadIfNeeded()
        guard !Self.isBlank(sessionID) else {
            throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
        }
        return attachments.values
            .filter { $0.sessionID == sessionID && (includeInactive || $0.active) }
            .sorted { lhs, rhs in
                lhs.clientID == rhs.clientID ? lhs.updatedAt < rhs.updatedAt : lhs.clientID < rhs.clientID
            }
    }

    public func authority(sessionID: String) throws -> SessionClientAttachment? {
        try loadIfNeeded()
        guard !Self.isBlank(sessionID) else {
            throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
        }
        return authority(for: sessionID)
    }

    public func requireAuthority(
        sessionID: String,
        clientID: String,
        owner: String
    ) throws -> SessionClientAttachment {
        try loadIfNeeded()
        let attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active, attachment.role == .authority else {
            throw SessionClientError.authorityRequired(sessionID: sessionID)
        }
        return attachment
    }

    public func events(after sequence: Int = 0, sessionID: String? = nil) throws -> [SessionClientEvent] {
        try loadIfNeeded()
        guard sequence >= 0 else { throw SessionClientError.invalidCursor(sequence) }
        return eventLog.filter {
            $0.sequence > sequence && (sessionID == nil || $0.attachment.sessionID == sessionID)
        }
    }

    public func export(sessionID: String, clientID: String? = nil) throws -> [SessionClientJournalEntry] {
        try loadIfNeeded()
        guard !Self.isBlank(sessionID) else {
            throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
        }
        if let store { return try store.export(sessionID: sessionID, clientID: clientID) }
        return eventLog.compactMap { event in
            guard event.attachment.sessionID == sessionID,
                  clientID == nil || event.attachment.clientID == clientID
            else { return nil }
            return SessionClientJournalEntry(event: event, attachment: event.attachment)
        }
    }

    private func attachment(sessionID: String, clientID: String) throws -> SessionClientAttachment {
        guard let attachment = attachments[Self.key(sessionID: sessionID, clientID: clientID)] else {
            throw SessionClientError.notFound(sessionID: sessionID, clientID: clientID)
        }
        return attachment
    }

    private func ownedAttachment(
        sessionID: String,
        clientID: String,
        owner: String
    ) throws -> SessionClientAttachment {
        let attachment = try attachment(sessionID: sessionID, clientID: clientID)
        guard attachment.owner == owner else {
            throw SessionClientError.ownershipDenied(clientID: clientID)
        }
        return attachment
    }

    private func authority(for sessionID: String) -> SessionClientAttachment? {
        attachments.values.first { $0.sessionID == sessionID && $0.active && $0.role == .authority }
    }

    private func validate(sessionID: String, clientID: String, owner: String) throws {
        let fields = [("sessionID", sessionID), ("clientID", clientID), ("owner", owner)]
        for (name, value) in fields where Self.isBlank(value) {
            throw SessionClientError.invalidRequest("Session client \(name) must not be empty.")
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if let store {
            for row in try store.records() {
                guard row.event.sequence > nextSequence else {
                    throw SessionClientError.invalidCursor(row.event.sequence)
                }
                nextSequence = row.event.sequence
                let key = Self.key(
                    sessionID: row.attachment.sessionID,
                    clientID: row.attachment.clientID
                )
                attachments[key] = row.attachment
                eventLog.append(row.event)
            }
            // A process restart invalidates network presence and authority. Keep
            // the historical rows intact; the next attach records the new state.
            for key in attachments.keys {
                guard var attachment = attachments[key], attachment.active else { continue }
                attachment.active = false
                attachment.role = .observer
                attachments[key] = attachment
            }
        }
        loaded = true
    }

    @discardableResult
    private func append(
        attachment: SessionClientAttachment,
        kind: SessionClientEventKind,
        previousAuthorityClientID: String? = nil
    ) throws -> SessionClientEvent {
        nextSequence += 1
        let event = SessionClientEvent(
            sequence: nextSequence,
            timestamp: attachment.updatedAt,
            kind: kind,
            attachment: attachment,
            previousAuthorityClientID: previousAuthorityClientID
        )
        if let store {
            do {
                try store.append(SessionClientJournalEntry(event: event, attachment: attachment))
            } catch {
                nextSequence -= 1
                throw error
            }
        }
        attachments[Self.key(sessionID: attachment.sessionID, clientID: attachment.clientID)] = attachment
        eventLog.append(event)
        return event
    }

    fileprivate static func key(sessionID: String, clientID: String) -> String {
        "\(sessionID)\u{1f}\(clientID)"
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
