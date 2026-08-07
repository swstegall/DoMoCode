import DoMoCore
import Foundation
import SystemPackage
import Testing

@Suite("Session client ledger", .serialized)
struct SessionClientLedgerTests {
    @Test("the first client is authoritative and authority transfer is explicit")
    func authorityTransfer() async throws {
        let manager = SessionClientManager(now: { "2026-01-01T00:00:00Z" })
        let first = try await manager.attach(
            sessionID: "session-1",
            clientID: "client-a",
            owner: "owner-a"
        )
        #expect(first.role == .authority)

        let second = try await manager.attach(
            sessionID: "session-1",
            clientID: "client-b",
            owner: "owner-b"
        )
        #expect(second.role == .observer)
        await #expect(throws: SessionClientError.authorityRequired(sessionID: "session-1")) {
            _ = try await manager.requireAuthority(
                sessionID: "session-1",
                clientID: "client-b",
                owner: "owner-b"
            )
        }

        let transferred = try await manager.transferAuthority(
            sessionID: "session-1",
            fromClientID: "client-a",
            toClientID: "client-b",
            owner: "owner-a"
        )
        #expect(transferred.role == .authority)
        #expect(try await manager.authority(sessionID: "session-1")?.clientID == "client-b")
        await #expect(throws: SessionClientError.authorityRequired(sessionID: "session-1")) {
            _ = try await manager.requireAuthority(
                sessionID: "session-1",
                clientID: "client-a",
                owner: "owner-a"
            )
        }
    }

    @Test("cursors are monotonic, persisted, and old presence is inactive after restart")
    func persistenceAndCursor() async throws {
        let directory = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domo-session-clients-\(UUID().uuidString)", isDirectory: true)
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        let manager = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        _ = try await manager.attach(sessionID: "session-2", clientID: "client-a", owner: "owner-a")
        _ = try await manager.advanceCursor(
            sessionID: "session-2",
            clientID: "client-a",
            owner: "owner-a",
            sequence: 4
        )
        await #expect(throws: SessionClientError.invalidCursor(3)) {
            _ = try await manager.advanceCursor(
                sessionID: "session-2",
                clientID: "client-a",
                owner: "owner-a",
                sequence: 3
            )
        }
        let events = try await manager.events(after: 1, sessionID: "session-2")
        #expect(events.map(\.kind) == [.cursorAdvanced])
        #expect(events[0].attachment.eventCursor == 4)

        let reopened = SessionClientManager(store: store, now: { "2026-01-01T00:00:01Z" })
        #expect(try await reopened.authority(sessionID: "session-2") == nil)
        let inactive = try await reopened.list(sessionID: "session-2", includeInactive: true)
        #expect(inactive.count == 1)
        #expect(inactive[0].active == false)
        #expect(inactive[0].eventCursor == 4)
        let reattached = try await reopened.attach(
            sessionID: "session-2",
            clientID: "client-a",
            owner: "owner-a"
        )
        #expect(reattached.role == .authority)
        #expect(reattached.eventCursor == 4)
        #expect(try await reopened.export(sessionID: "session-2", clientID: "client-a").count == 3)
    }

    @Test("a client cannot operate another owner's attachment")
    func ownership() async throws {
        let manager = SessionClientManager(now: { "2026-01-01T00:00:00Z" })
        _ = try await manager.attach(sessionID: "session-3", clientID: "client-a", owner: "owner-a")
        await #expect(throws: SessionClientError.ownershipDenied(clientID: "client-a")) {
            _ = try await manager.detach(sessionID: "session-3", clientID: "client-a", owner: "owner-b")
        }
    }

    @Test("a journal that will not decode is quarantined, reported, and the attach succeeds")
    func corruptJournalIsQuarantined() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        try Data("{not json\n".utf8).write(to: URL(fileURLWithPath: store.path.string))

        let quarantines = QuarantineLog()
        let manager = SessionClientManager(
            store: store,
            now: { "2026-01-01T00:00:00Z" },
            onQuarantine: { path, fault in quarantines.record(path: path, fault: fault) }
        )
        // This exact call used to throw — and, because nothing repaired the
        // file, so did every one after it, forever.
        let attachment = try await manager.attach(
            sessionID: "session-q",
            clientID: "client-a",
            owner: "owner-a"
        )
        #expect(attachment.role == .authority)

        // The journal restarted clean with this attach as its first row.
        #expect(try store.records().map(\.event.sequence) == [1])

        // The original bytes were kept for diagnosis, not destroyed.
        let recorded = quarantines.entries()
        #expect(recorded.count == 1)
        let quarantined = try #require(recorded.first)
        #expect(quarantined.path.string.contains(".corrupt-"))
        let preserved = try Data(contentsOf: URL(fileURLWithPath: quarantined.path.string))
        #expect(String(decoding: preserved, as: UTF8.self) == "{not json\n")
        #expect(!quarantined.fault.isEmpty)

        // A later manager over the healed journal loads without another quarantine.
        let reopened = SessionClientManager(
            store: store,
            now: { "2026-01-01T00:00:01Z" },
            onQuarantine: { path, fault in quarantines.record(path: path, fault: fault) }
        )
        _ = try await reopened.attach(sessionID: "session-q", clientID: "client-a", owner: "owner-a")
        #expect(quarantines.entries().count == 1)
    }

    @Test("a journal with a non-monotonic sequence is quarantined rather than poisoning every attach")
    func nonMonotonicJournalIsQuarantined() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        // Two well-formed rows with the SAME sequence — exactly what two
        // pre-fix processes appending from private counters left behind.
        try store.append(Self.journalRow(sequence: 1, clientID: "client-a"))
        try store.append(Self.journalRow(sequence: 1, clientID: "client-b"))

        let quarantines = QuarantineLog()
        let manager = SessionClientManager(
            store: store,
            now: { "2026-01-01T00:00:00Z" },
            onQuarantine: { path, fault in quarantines.record(path: path, fault: fault) }
        )
        let attachment = try await manager.attach(
            sessionID: "session-m",
            clientID: "client-c",
            owner: "owner-c"
        )
        #expect(attachment.role == .authority)
        #expect(try store.records().map(\.event.sequence) == [1])
        #expect(quarantines.entries().count == 1)
        #expect(quarantines.entries().first?.fault.contains("strictly increase") == true)
    }

    @Test("two managers sharing one journal agree on sequences through the file, not their counters")
    func crossProcessSequencesStayMonotonic() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)

        let first = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        let second = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        // Load `second` while the journal is still empty, so its in-memory
        // counter is stale by the time it appends — the exact shape of two
        // `domo` processes sharing a workspace.
        _ = try await second.list(sessionID: "session-x")
        _ = try await first.attach(sessionID: "session-x", clientID: "client-a", owner: "owner-a")
        _ = try await second.attach(sessionID: "session-x", clientID: "client-b", owner: "owner-b")

        // Before the coordinated append, `second` wrote a duplicate sequence 1
        // here, and the NEXT process to load the journal threw on every call.
        #expect(try store.records().map(\.event.sequence) == [1, 2])
        let third = SessionClientManager(store: store, now: { "2026-01-01T00:00:01Z" })
        _ = try await third.list(sessionID: "session-x", includeInactive: true)
        #expect(try store.records().count == 2)
    }

    @Test("when the quarantine itself cannot happen, the journal's own fault is what surfaces")
    func quarantineFailureKeepsTheOriginalFault() async throws {
        let directory = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.string
            )
            try? FileManager.default.removeItem(atPath: directory.string)
        }
        let store = try SessionClientStore.create(directory: directory)
        // One clean attach first, so the lock sidecar exists before the
        // directory becomes read-only — the lock open itself must not be what
        // fails, or the test is about the wrong error.
        let warm = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        _ = try await warm.attach(sessionID: "session-r", clientID: "client-a", owner: "owner-a")
        try Data("{not json\n".utf8).write(to: URL(fileURLWithPath: store.path.string))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.string
        )
        // Root ignores directory modes; when the setup cannot hold, the
        // scenario is untestable rather than vacuously green.
        guard !FileManager.default.isWritableFile(atPath: directory.string) else { return }

        let manager = SessionClientManager(store: store, now: { "2026-01-01T00:00:01Z" })
        do {
            _ = try await manager.attach(sessionID: "session-r", clientID: "client-a", owner: "owner-a")
            Issue.record("an unquarantinable corrupt journal must not attach")
        } catch {
            // The decode fault is the diagnosis; the rename failure that
            // prevented the repair is only its consequence.
            #expect(error is JSONLinesError)
        }
        // The evidence was not destroyed by the failed repair attempt.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: store.path.string))
        #expect(String(decoding: bytes, as: UTF8.self) == "{not json\n")
    }

    @Test("two concurrent attaches elect exactly one authority")
    func concurrentAttachesElectOneAuthority() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        let manager = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })
        // The journal I/O awaits inside attach make the actor reentrant, so
        // without the turn gate a second attach could slip in between the
        // first's authority CHECK and its COMMIT and both walked away
        // authoritative. Several rounds, because the interleaving is a race.
        for round in 1...10 {
            let sessionID = "race-\(round)"
            async let first = manager.attach(sessionID: sessionID, clientID: "client-a", owner: "owner-a")
            async let second = manager.attach(sessionID: sessionID, clientID: "client-b", owner: "owner-b")
            let roles = [try await first.role, try await second.role]
            #expect(roles.filter { $0 == .authority }.count == 1, "round \(round): \(roles)")
            let authorities = try await manager.list(sessionID: sessionID)
                .filter { $0.role == .authority }
            #expect(authorities.count == 1, "round \(round): \(authorities)")
        }
        // And the journal the races produced replays cleanly — strictly
        // monotonic sequences, no quarantine.
        let rows = try store.records()
        #expect(rows.map(\.event.sequence) == Array(1...rows.count))
    }

    @Test("a wedged peer holding the journal lock surfaces as storeBusy, not a poisoned ledger")
    func contendedJournalLockIsStoreBusy() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        let manager = SessionClientManager(store: store, now: { "2026-01-01T00:00:00Z" })

        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        // The "peer": holds the journal's sidecar flock until told to let go —
        // longer than the ledger's own lock wait.
        let holder = Task.detached {
            _ = try await FileLock.withLock(
                at: FileLock.lockPath(forDocumentAt: store.path.string),
                timeout: .seconds(10)
            ) {
                startedCont.yield(())
                startedCont.finish()
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        await #expect(throws: SessionClientError.storeBusy) {
            _ = try await manager.attach(sessionID: "session-b", clientID: "client-a", owner: "owner-a")
        }
        releaseCont.yield(())
        releaseCont.finish()
        _ = try? await holder.value

        // The refusal was a scheduling outcome, not a verdict on the journal:
        // once the peer lets go the same attach succeeds.
        let attached = try await manager.attach(sessionID: "session-b", clientID: "client-a", owner: "owner-a")
        #expect(attached.role == .authority)
    }

    @Test("a journal corrupted after load is quarantined by the very append that trips on it")
    func appendTimeCorruptionHealsInPlace() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionClientStore.create(directory: directory)
        let quarantines = QuarantineLog()
        let manager = SessionClientManager(
            store: store,
            now: { "2026-01-01T00:00:00Z" },
            onQuarantine: { path, fault in quarantines.record(path: path, fault: fault) }
        )
        _ = try await manager.attach(sessionID: "session-a", clientID: "client-a", owner: "owner-a")
        // Corrupt the journal AFTER the manager has loaded, so the load-time
        // quarantine cannot be the one that fires.
        try Data("{not json\n".utf8).write(to: URL(fileURLWithPath: store.path.string))

        let attached = try await manager.attach(sessionID: "session-a", clientID: "client-b", owner: "owner-b")
        #expect(attached.role == .observer)
        #expect(quarantines.entries().count == 1)
        // The fresh journal's first row continues from the in-memory floor —
        // sequence 2, not 1 — so this process's own numbering never regresses.
        #expect(try store.records().map(\.event.sequence) == [2])
    }

    /// Collects quarantine reports across `@Sendable` callback hops.
    private final class QuarantineLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(path: FilePath, fault: String)] = []

        func record(path: FilePath, fault: String) {
            lock.lock()
            defer { lock.unlock() }
            log.append((path, fault))
        }

        func entries() -> [(path: FilePath, fault: String)] {
            lock.lock()
            defer { lock.unlock() }
            return log
        }
    }

    private static func temporaryDirectory() throws -> FilePath {
        let directory = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domo-session-clients-\(UUID().uuidString)", isDirectory: true)
                .path
        )
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func journalRow(sequence: Int, clientID: String) -> SessionClientJournalEntry {
        let attachment = SessionClientAttachment(
            clientID: clientID,
            sessionID: "session-m",
            owner: clientID,
            attachedAt: "2026-01-01T00:00:00Z"
        )
        return SessionClientJournalEntry(
            event: SessionClientEvent(
                sequence: sequence,
                timestamp: "2026-01-01T00:00:00Z",
                kind: .attached,
                attachment: attachment
            ),
            attachment: attachment
        )
    }
}
