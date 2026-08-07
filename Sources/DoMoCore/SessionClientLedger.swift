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
        // Create-if-absent with `O_EXCL`, never check-then-truncate: two
        // processes initializing the same workspace could interleave a
        // `fileExists` with the other's truncating write and erase its rows.
        // Losing the race is success — the winner's contents must stand.
        do {
            let descriptor = try FileDescriptor.open(
                store.path,
                .writeOnly,
                options: [.create, .exclusiveCreate],
                permissions: permissions
            )
            try descriptor.close()
        } catch Errno.fileExists {}
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

    /// What a coordinated read found, including whether it had to set a broken
    /// journal aside to find it.
    public struct CoordinatedLoad: Sendable {
        /// Every replayable row, in file order, with strictly increasing
        /// sequences. Empty when the journal was quarantined.
        public let rows: [SessionClientJournalEntry]
        /// Where the unreplayable journal went, and why, when this load had to
        /// start a fresh one. `nil` on the ordinary clean read.
        public let quarantined: (path: FilePath, fault: String)?
    }

    /// Reads the whole journal under the cross-process lock, quarantining it and
    /// starting fresh when it cannot be replayed.
    ///
    /// A journal that fails its strict decode or its sequence check used to fail
    /// the caller — and because nothing ever repaired the file, it failed every
    /// caller after that too, forever, 400 by 400. The file is durable workspace
    /// state, so neither a restart nor a reboot ever cleared it. Setting the bad
    /// journal aside (keeping its bytes for diagnosis) and continuing empty is
    /// strictly better on both axes: presence records are rebuilt by the very
    /// next attach, while a transcript is not.
    ///
    /// Quarantine happens *under the same lock* as the read, so two processes
    /// discovering the same broken journal set it aside once, not twice.
    ///
    /// - Parameter quarantineSuffix: A caller-supplied timestamp-shaped marker
    ///   for the quarantine file name, injectable so tests are deterministic.
    /// - Throws: The journal's own fault when the quarantine itself cannot be
    ///   performed (an unwritable directory): the original error is the
    ///   diagnosis, the rename failure is only its consequence. Also
    ///   ``SessionClientError/storeBusy`` when another process held the journal
    ///   lock for the whole wait.
    public func coordinatedLoad(quarantineSuffix: String) async throws -> CoordinatedLoad {
        try await locked {
            do {
                let rows = try records()
                try Self.checkMonotonic(rows)
                return CoordinatedLoad(rows: rows, quarantined: nil)
            } catch let fault where Self.isReplayFault(fault) {
                // Only a fault that indicts the journal's CONTENT reaches here.
                // An environmental read failure (EMFILE, EIO, a mount gone
                // read-only) says nothing about the bytes, and rename(2) can
                // succeed exactly when the read could not — quarantining on it
                // would destroy a healthy journal over a transient fault, so
                // those propagate out of `locked` untouched instead.
                let destination: FilePath
                do {
                    destination = try quarantine(suffix: quarantineSuffix)
                } catch {
                    throw fault
                }
                return CoordinatedLoad(
                    rows: [],
                    quarantined: (destination, String(describing: fault))
                )
            }
        }
    }

    /// Appends one batch of rows whose sequences are agreed with every other
    /// process appending to the same journal.
    ///
    /// The base sequence is derived from the *file* under the lock — not from
    /// the caller's in-memory counter alone. Two processes each numbering rows
    /// from their own private counter is exactly how a journal ends up with
    /// duplicate sequences, which the load-time check then rejects: a poisoned
    /// file that no crash and no corruption ever touched.
    ///
    /// One CALL is one lock acquisition and one `write(2)`: a multi-row
    /// operation (an authority transfer's release+claim pair) that took the
    /// lock once per row could persist its first row and then lose the lock —
    /// or the process — before its second, leaving a half-applied transfer on
    /// disk that no retry can honestly complete.
    ///
    /// - Parameters:
    ///   - next: The caller's in-memory next-sequence floor; the first assigned
    ///     sequence is `max(disk, next) + 1`.
    ///   - quarantineSuffix: See ``coordinatedLoad(quarantineSuffix:)``; used
    ///     when the journal must be read to find the disk sequence and cannot be.
    ///   - rows: Builds the batch once the base sequence is known (sequences are
    ///     recorded inside the rows); rows must use consecutive sequences
    ///     starting at the given base.
    public func coordinatedAppend(
        after next: Int,
        quarantineSuffix: String,
        making rows: (Int) throws -> [SessionClientJournalEntry]
    ) async throws -> (entries: [SessionClientJournalEntry], quarantined: (path: FilePath, fault: String)?) {
        try await locked {
            var quarantined: (path: FilePath, fault: String)?
            var diskNext = 0
            do {
                // O(1) on purpose: the journal is append-only and never
                // compacted, and its hottest writer is the SSE cursor path —
                // decoding the whole file per append while holding the
                // cross-process lock turns every streamed turn into quadratic
                // I/O feeding the peers' 2-second contention cliff.
                diskNext = try tailSequence()
            } catch let fault where Self.isReplayFault(fault) {
                // The journal cannot even be read to find its last sequence, so
                // it would fail the next load anyway. Quarantining *now* lets
                // this very append start the fresh journal instead of writing a
                // row that is doomed to be thrown away with the rest. As on
                // load, environmental faults propagate rather than quarantine.
                let destination: FilePath
                do {
                    destination = try quarantine(suffix: quarantineSuffix)
                } catch {
                    throw fault
                }
                quarantined = (destination, String(describing: fault))
            }
            let batch = try rows(max(diskNext, next) + 1)
            try JSONLinesFileWriter(path: path, permissions: permissions).append(contentsOf: batch)
            return (batch, quarantined)
        }
    }

    /// The last row's sequence, read from the file's tail — 0 for a missing or
    /// empty journal. Throws a replay fault when the tail is not a whole,
    /// decodable row (a torn write), which is exactly the state the next full
    /// load would reject.
    private func tailSequence() throws -> Int {
        guard FileManager.default.fileExists(atPath: path.string) else { return 0 }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end > 0 else { return 0 }
        let window = min(end, UInt64(Self.tailWindowBytes))
        try handle.seek(toOffset: end - window)
        var buffer = try handle.read(upToCount: Int(window)) ?? Data()
        if window < end {
            // The buffer may begin mid-row. Everything before its first
            // newline belongs to a row that started outside the window; only
            // what follows is trustworthy line starts.
            guard let firstNewline = buffer.firstIndex(of: 0x0A) else {
                // One row larger than the whole window: pay the full read
                // rather than misjudge a valid journal from a fragment.
                let rows = try records()
                try Self.checkMonotonic(rows)
                return rows.last?.event.sequence ?? 0
            }
            buffer = buffer[buffer.index(after: firstNewline)...]
        }
        guard let lastLine = buffer.split(separator: 0x0A, omittingEmptySubsequences: true).last else {
            return 0
        }
        do {
            return try JSONDecoder().decode(SessionClientJournalEntry.self, from: Data(lastLine)).event.sequence
        } catch {
            throw JSONLinesError(
                kind: .malformedLine,
                lineNumber: 0,
                byteOffset: Int(end) - lastLine.count,
                byteCount: lastLine.count,
                detail: "tail row: \(error)"
            )
        }
    }

    /// Large enough that the tail row is found in one read for any realistic
    /// journal row, small enough that the append path never slurps the file.
    private static let tailWindowBytes = 64 * 1024

    /// Whether an error indicts the journal's CONTENT — the only kind the
    /// quarantine may act on. Everything else is environment.
    private static func isReplayFault(_ error: any Error) -> Bool {
        error is JSONLinesError || error is SessionClientError || error is DecodingError
    }

    /// Moves the journal aside as `<name>.corrupt-<suffix>` and recreates it
    /// empty, returning where the original bytes went.
    @discardableResult
    public func quarantine(suffix: String) throws -> FilePath {
        // ISO timestamps carry colons; keep the marker filesystem-plain.
        let marker = suffix.replacingOccurrences(of: ":", with: "-")
        var destination = FilePath(path.string + ".corrupt-" + marker)
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.string) {
            attempt += 1
            destination = FilePath(path.string + ".corrupt-" + marker + "-\(attempt)")
        }
        try FileManager.default.moveItem(atPath: path.string, toPath: destination.string)
        // Best-effort: the MOVE is the quarantine. Every reader treats an
        // absent journal as empty and every writer creates on demand, so a
        // failed recreate here must not turn a completed repair into a report
        // of failure.
        try? JSONLinesFileWriter(path: path, permissions: permissions)
            .replaceContents(with: [SessionClientJournalEntry]())
        return destination
    }

    /// The journal-format invariant the loader depends on, checked where the
    /// quarantine can act on its violation.
    private static func checkMonotonic(_ rows: [SessionClientJournalEntry]) throws {
        var previous = 0
        for (index, row) in rows.enumerated() {
            guard row.event.sequence > previous else {
                throw SessionClientError.invalidRequest(
                    "Journal row \(index + 1) has sequence \(row.event.sequence) after \(previous); sequences must strictly increase."
                )
            }
            previous = row.event.sequence
        }
    }

    /// Runs `body` holding the journal's sidecar `flock(2)`.
    ///
    /// `flock` because the kernel releases it on process death — a SIGKILLed
    /// peer leaves nothing to detect or reap (see ``FileLock``). Contention past
    /// the timeout means a wedged peer, not a queue: the critical section is one
    /// small read and one small write.
    private func locked<T>(_ body: () throws -> T) async throws -> T {
        let outcome = try await FileLock.withLock(
            at: FileLock.lockPath(forDocumentAt: path.string)
        ) { try body() }
        switch outcome {
        case .ran(let value): return value
        case .contended: throw SessionClientError.storeBusy
        case .cancelled: throw CancellationError()
        }
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
    /// Another process held the journal lock for the whole wait. A retry-shaped
    /// condition, distinct from every "your request is wrong" case above.
    case storeBusy
}

/// Serializes client presence, authority, and event cursors for a session.
///
/// This manager deliberately does not own a socket or infer liveness from a
/// dropped HTTP request. Attach/detach and authority transfer are explicit;
/// restart recovery marks every old attachment inactive before a new client can
/// become authoritative. That makes permission ownership a durable decision,
/// not whichever client happened to receive the latest SSE frame.
///
/// ## Scope of the guarantees
///
/// Authority arbitration is **per process**. The journal's cross-process lock
/// guarantees format integrity and sequence agreement — never a cross-process
/// view of who currently holds authority: each process decides from its own
/// replayed state, and a load demotes every replayed attachment precisely
/// because peer presence cannot be trusted across process boundaries. Within
/// the process, every public operation runs whole under one turn gate (below),
/// because the journal I/O these methods await made the actor reentrant — and a
/// second attach slipping in between one attach's authority *check* and its
/// *commit* is how two clients both walked away authoritative.
public actor SessionClientManager {
    private let store: SessionClientStore?
    private let now: @Sendable () -> String
    /// Told once whenever a journal that would not replay was set aside, with
    /// where it went and why. The quarantine is silent otherwise, and a silent
    /// self-repair of a durable file is the kind of thing an operator should be
    /// able to find in a log afterwards.
    private let onQuarantine: (@Sendable (FilePath, String) -> Void)?

    private var loaded = false
    private var nextSequence = 0
    private var attachments: [String: SessionClientAttachment] = [:]
    private var eventLog: [SessionClientEvent] = []

    /// The turn gate: whether an operation currently holds the actor's turn,
    /// and who is waiting for it. Actor isolation alone stopped serializing
    /// these operations the moment they grew `await`s (an actor is reentrant at
    /// every suspension), so check-decide-append-commit sequences need this to
    /// stay atomic against their siblings.
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: SessionClientStore? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
        onQuarantine: (@Sendable (FilePath, String) -> Void)? = nil
    ) {
        self.store = store
        self.now = now
        self.onQuarantine = onQuarantine
    }

    /// Runs `body` as the actor's sole in-flight operation.
    ///
    /// FIFO hand-off: a release resumes the earliest waiter with the gate still
    /// held, so ownership transfers without a gap another caller could steal.
    /// Waiting is not cancellation-interruptible — every operation is one small
    /// journal read/write bounded by ``FileLock``'s own timeout, and an
    /// unconditionally-resumed continuation is what keeps the queue drainable.
    private func serialized<T>(_ body: () async throws -> T) async throws -> T {
        if gateHeld {
            await withCheckedContinuation { gateWaiters.append($0) }
        } else {
            gateHeld = true
        }
        defer {
            if gateWaiters.isEmpty {
                gateHeld = false
            } else {
                gateWaiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    /// Attach idempotently. The first active client for a session may become
    /// authoritative; later clients are observers until the authority is
    /// explicitly transferred or released.
    public func attach(
        sessionID: String,
        clientID: String,
        owner: String,
        requestAuthority: Bool = true
    ) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
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
            if let existing,
               existing.active == attachment.active,
               existing.role == attachment.role,
               existing.eventCursor == attachment.eventCursor {
                return existing
            }
            let kind: SessionClientEventKind
            if existing == nil {
                kind = attachment.role == .authority ? .authorityClaimed : .attached
            } else if attachment.role == .authority && existing?.role != .authority {
                kind = .authorityClaimed
            } else {
                kind = .attached
            }
            _ = try await append(attachment: attachment, kind: kind)
            return attachment
        }
    }

    public func detach(sessionID: String, clientID: String, owner: String) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
            var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
            guard attachment.active else { return attachment }
            attachment.active = false
            attachment.role = .observer
            attachment.updatedAt = now()
            _ = try await append(attachment: attachment, kind: .detached)
            return attachment
        }
    }

    /// Release authority without detaching. The next explicit attach may claim
    /// it, but an already-attached observer must still be promoted explicitly.
    public func releaseAuthority(
        sessionID: String,
        clientID: String,
        owner: String
    ) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
            var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
            guard attachment.active, attachment.role == .authority else {
                throw SessionClientError.authorityRequired(sessionID: sessionID)
            }
            attachment.role = .observer
            attachment.updatedAt = now()
            _ = try await append(attachment: attachment, kind: .authorityReleased)
            return attachment
        }
    }

    /// Transfer authority atomically from the current owner to an active
    /// observer. No client can seize a prompt-answering role by reconnecting.
    public func transferAuthority(
        sessionID: String,
        fromClientID: String,
        toClientID: String,
        owner: String
    ) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
            guard fromClientID != toClientID else {
                return try requireAuthorityCore(sessionID: sessionID, clientID: fromClientID, owner: owner)
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
            // ONE batch, one lock acquisition, one write. Written as two
            // appends, a wedged peer between them persisted the release
            // without the claim: no authority on disk, and the natural retry
            // answered authorityRequired because the source was demoted.
            _ = try await append(rows: [
                (released, .authorityTransferred, source.clientID),
                (target, .authorityTransferred, source.clientID),
            ])
            return target
        }
    }

    public func heartbeat(sessionID: String, clientID: String, owner: String) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
            var attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
            guard attachment.active else {
                throw SessionClientError.notFound(sessionID: sessionID, clientID: clientID)
            }
            attachment.updatedAt = now()
            _ = try await append(attachment: attachment, kind: .attached)
            return attachment
        }
    }

    /// Advance a mirror cursor monotonically. A client may repeat the same
    /// cursor after a retry, but can never move the durable position backward.
    public func advanceCursor(
        sessionID: String,
        clientID: String,
        owner: String,
        sequence: Int
    ) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
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
            _ = try await append(attachment: attachment, kind: .cursorAdvanced)
            return attachment
        }
    }

    public func list(sessionID: String, includeInactive: Bool = false) async throws -> [SessionClientAttachment] {
        try await serialized {
            try await loadIfNeeded()
            guard !Self.isBlank(sessionID) else {
                throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
            }
            return attachments.values
                .filter { $0.sessionID == sessionID && (includeInactive || $0.active) }
                .sorted { lhs, rhs in
                    lhs.clientID == rhs.clientID ? lhs.updatedAt < rhs.updatedAt : lhs.clientID < rhs.clientID
                }
        }
    }

    public func authority(sessionID: String) async throws -> SessionClientAttachment? {
        try await serialized {
            try await loadIfNeeded()
            guard !Self.isBlank(sessionID) else {
                throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
            }
            return authority(for: sessionID)
        }
    }

    public func requireAuthority(
        sessionID: String,
        clientID: String,
        owner: String
    ) async throws -> SessionClientAttachment {
        try await serialized {
            try await loadIfNeeded()
            return try requireAuthorityCore(sessionID: sessionID, clientID: clientID, owner: owner)
        }
    }

    public func events(after sequence: Int = 0, sessionID: String? = nil) async throws -> [SessionClientEvent] {
        try await serialized {
            try await loadIfNeeded()
            guard sequence >= 0 else { throw SessionClientError.invalidCursor(sequence) }
            return eventLog.filter {
                $0.sequence > sequence && (sessionID == nil || $0.attachment.sessionID == sessionID)
            }
        }
    }

    public func export(sessionID: String, clientID: String? = nil) async throws -> [SessionClientJournalEntry] {
        try await serialized {
            try await loadIfNeeded()
            guard !Self.isBlank(sessionID) else {
                throw SessionClientError.invalidRequest("Session client sessionID must not be empty.")
            }
            // From memory, not the store: the journal on disk may be mid-append
            // or mid-quarantine in a peer process, and this was the one surface
            // still reading it outside the lock protocol. The in-memory log IS
            // the replayed journal plus everything this process appended; what
            // it lacks is only peer rows written since our load, which the
            // per-process presence model already declines to arbitrate.
            return eventLog.compactMap { event in
                guard event.attachment.sessionID == sessionID,
                      clientID == nil || event.attachment.clientID == clientID
                else { return nil }
                return SessionClientJournalEntry(event: event, attachment: event.attachment)
            }
        }
    }

    /// The authority check shared by ``requireAuthority(sessionID:clientID:owner:)``
    /// and ``transferAuthority(sessionID:fromClientID:toClientID:owner:)``'s
    /// self-transfer path — which already holds the turn gate and must not
    /// re-enter it.
    private func requireAuthorityCore(
        sessionID: String,
        clientID: String,
        owner: String
    ) throws -> SessionClientAttachment {
        let attachment = try ownedAttachment(sessionID: sessionID, clientID: clientID, owner: owner)
        guard attachment.active, attachment.role == .authority else {
            throw SessionClientError.authorityRequired(sessionID: sessionID)
        }
        return attachment
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

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        guard let store else {
            loaded = true
            return
        }
        // Into locals, committed whole: a load that threw halfway used to leave
        // the rows before the bad one in `eventLog`, and the retry appended them
        // again. With the quarantine the load no longer throws for a bad row —
        // the store sets the journal aside and answers empty — but the shape is
        // kept so a future fault cannot reintroduce the duplication.
        let load = try await store.coordinatedLoad(quarantineSuffix: now())
        var next = 0
        var replayed: [String: SessionClientAttachment] = [:]
        var log: [SessionClientEvent] = []
        for row in load.rows {
            next = row.event.sequence
            let key = Self.key(
                sessionID: row.attachment.sessionID,
                clientID: row.attachment.clientID
            )
            replayed[key] = row.attachment
            log.append(row.event)
        }
        // A process restart invalidates network presence and authority. Keep
        // the historical rows intact; the next attach records the new state.
        for key in replayed.keys {
            guard var attachment = replayed[key], attachment.active else { continue }
            attachment.active = false
            attachment.role = .observer
            replayed[key] = attachment
        }
        nextSequence = next
        attachments = replayed
        eventLog = log
        loaded = true
        if let quarantined = load.quarantined {
            onQuarantine?(quarantined.path, quarantined.fault)
        }
    }

    @discardableResult
    private func append(
        attachment: SessionClientAttachment,
        kind: SessionClientEventKind,
        previousAuthorityClientID: String? = nil
    ) async throws -> SessionClientEvent {
        try await append(rows: [(attachment, kind, previousAuthorityClientID)])[0]
    }

    /// Appends a batch as one store write — one lock acquisition, one
    /// `write(2)` — and commits it to memory only after the whole batch is
    /// durable, so a failed write can never leave memory half-mutated.
    private func append(
        rows specs: [(attachment: SessionClientAttachment, kind: SessionClientEventKind, previousAuthorityClientID: String?)]
    ) async throws -> [SessionClientEvent] {
        let events: [SessionClientEvent]
        if let store {
            // Sequences are assigned by the store under the cross-process
            // lock, so they can jump past `nextSequence + 1` when another
            // process has appended since this one loaded. That is the fix, not
            // a bug: the durable journal stays strictly monotonic no matter
            // how many processes share it.
            let result = try await store.coordinatedAppend(
                after: nextSequence,
                quarantineSuffix: now()
            ) { base in
                specs.enumerated().map { offset, spec in
                    SessionClientJournalEntry(
                        event: SessionClientEvent(
                            sequence: base + offset,
                            timestamp: spec.attachment.updatedAt,
                            kind: spec.kind,
                            attachment: spec.attachment,
                            previousAuthorityClientID: spec.previousAuthorityClientID
                        ),
                        attachment: spec.attachment
                    )
                }
            }
            events = result.entries.map(\.event)
            if let quarantined = result.quarantined {
                onQuarantine?(quarantined.path, quarantined.fault)
            }
        } else {
            events = specs.enumerated().map { offset, spec in
                SessionClientEvent(
                    sequence: nextSequence + 1 + offset,
                    timestamp: spec.attachment.updatedAt,
                    kind: spec.kind,
                    attachment: spec.attachment,
                    previousAuthorityClientID: spec.previousAuthorityClientID
                )
            }
        }
        for event in events {
            attachments[Self.key(sessionID: event.attachment.sessionID, clientID: event.attachment.clientID)] = event.attachment
            eventLog.append(event)
        }
        if let last = events.last { nextSequence = last.sequence }
        return events
    }

    fileprivate static func key(sessionID: String, clientID: String) -> String {
        "\(sessionID)\u{1f}\(clientID)"
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
