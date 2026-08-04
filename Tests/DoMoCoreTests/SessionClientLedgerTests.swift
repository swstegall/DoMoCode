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
}
