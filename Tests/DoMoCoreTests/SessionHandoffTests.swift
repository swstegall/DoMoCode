import DoMoCore
import Foundation
import SystemPackage
import Testing

@Suite("Session handoff", .serialized)
struct SessionHandoffTests {
    @Test("persists provenance and resumes target-owned event cursors")
    func persistsAndResumes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try SessionHandoffStore.create(directory: directory)
        let manager = SessionHandoffManager(
            store: store,
            now: { "2026-01-01T00:00:00Z" }
        )

        let proposed = try await manager.propose(SessionHandoffRequest(
            id: "handoff-1",
            sourceSessionID: "session-source",
            sourceOwner: "client-source",
            targetOwner: "client-target",
            kind: .transfer,
            target: SessionHandoffTarget(
                sessionID: "session-target",
                workspaceID: "workspace-target",
                backendID: "backend-target",
                providerID: "provider-target"
            ),
            plan: SessionHandoffPlan(
                summary: "Continue the implementation.",
                steps: [
                    SessionHandoffPlanStep(id: "inspect", title: "Inspect the changes"),
                    SessionHandoffPlanStep(id: "verify", title: "Verify the result", dependsOn: ["inspect"]),
                ]
            ),
            artifacts: [
                SessionHandoffArtifact(
                    id: "artifact-1",
                    kind: "diff",
                    reference: "sha256:diff",
                    sourceSessionID: "session-source",
                    checksum: "sha256:diff"
                ),
            ]
        ))
        #expect(proposed.state == .proposed)
        #expect(proposed.plan?.steps.map(\.id) == ["inspect", "verify"])

        await #expect(throws: SessionHandoffError.ownershipDenied("handoff-1")) {
            _ = try await manager.accept(id: "handoff-1", owner: "client-source")
        }
        let accepted = try await manager.accept(id: "handoff-1", owner: "client-target")
        #expect(accepted.state == .accepted)

        let completed = try await manager.complete(
            id: "handoff-1",
            owner: "client-target",
            metadata: ["received": .bool(true)]
        )
        #expect(completed.state == .completed)
        #expect(completed.metadata["received"] == .bool(true))
        #expect(completed.target.backendID == "backend-target")

        let events = try await manager.events()
        #expect(events.map(\.kind) == [.proposed, .accepted, .completed])
        #expect(try await manager.events(after: 1).map(\.sequence) == [2, 3])

        let reopened = SessionHandoffManager(store: store, now: { "2026-01-01T00:00:01Z" })
        #expect(try await reopened.snapshot(id: "handoff-1") == completed)
        #expect(try await reopened.export(id: "handoff-1").count == 3)
    }

    @Test("reject and cancel are source-owned and terminal")
    func sourceOwnedResolution() async throws {
        let manager = SessionHandoffManager(now: { "2026-01-01T00:00:00Z" })
        _ = try await manager.propose(SessionHandoffRequest(
            id: "handoff-reject",
            sourceSessionID: "source",
            sourceOwner: "owner",
            targetOwner: "receiver",
            kind: .attach,
            target: SessionHandoffTarget(clientID: "receiver")
        ))

        await #expect(throws: SessionHandoffError.ownershipDenied("handoff-reject")) {
            _ = try await manager.reject(id: "handoff-reject", owner: "receiver", reason: "not now")
        }
        let rejected = try await manager.reject(id: "handoff-reject", owner: "owner", reason: "not now")
        #expect(rejected.state == .rejected)
        await #expect(throws: SessionHandoffError.invalidTransition(id: "handoff-reject", state: .rejected)) {
            _ = try await manager.cancel(id: "handoff-reject", owner: "owner")
        }

        _ = try await manager.propose(SessionHandoffRequest(
            id: "handoff-cancel",
            sourceSessionID: "source",
            sourceOwner: "owner",
            kind: .continueSession
        ))
        let cancelled = try await manager.cancel(id: "handoff-cancel", owner: "owner")
        #expect(cancelled.state == .cancelled)
    }

    @Test("rejects self-targets, duplicate plan steps, and unknown dependencies")
    func validatesRequest() async throws {
        let manager = SessionHandoffManager()
        await #expect(throws: SessionHandoffError.invalidRequest(
            "Handoff target sessionID must differ from the source."
        )) {
            _ = try await manager.propose(SessionHandoffRequest(
                id: "handoff-self",
                sourceSessionID: "same",
                sourceOwner: "owner",
                kind: .attach,
                target: SessionHandoffTarget(sessionID: "same")
            ))
        }

        await #expect(throws: SessionHandoffError.invalidRequest(
            "Handoff plan step ids must be unique."
        )) {
            _ = try await manager.propose(SessionHandoffRequest(
                id: "handoff-duplicate-step",
                sourceSessionID: "source",
                sourceOwner: "owner",
                kind: .transfer,
                plan: SessionHandoffPlan(summary: "Plan", steps: [
                    SessionHandoffPlanStep(id: "step", title: "One"),
                    SessionHandoffPlanStep(id: "step", title: "Two"),
                ])
            ))
        }

        await #expect(throws: SessionHandoffError.invalidRequest(
            "Handoff plan dependencies must name other steps."
        )) {
            _ = try await manager.propose(SessionHandoffRequest(
                id: "handoff-unknown-dependency",
                sourceSessionID: "source",
                sourceOwner: "owner",
                kind: .transfer,
                plan: SessionHandoffPlan(summary: "Plan", steps: [
                    SessionHandoffPlanStep(id: "step", title: "One", dependsOn: ["missing"]),
                ])
            ))
        }
    }

    private func temporaryDirectory() -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-handoffs-\(UUID().uuidString)", isDirectory: true)
                .path
        )
    }
}
