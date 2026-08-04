// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Workspace coordination")
struct WorkspaceCoordinationTests {
    @Test("branch names are safe, deterministic, and session-scoped")
    func branchNames() {
        let first = WorkspaceBranchNaming.branchName(
            sessionID: "session/one",
            label: "Fix: parser / edge case"
        )
        #expect(first == WorkspaceBranchNaming.branchName(
            sessionID: "session/one",
            label: "Fix: parser / edge case"
        ))
        #expect(first.hasPrefix("domo/fix-parser-edge-case-"))
        #expect(!first.contains(".."))
        #expect(!first.contains(" "))
        #expect(WorkspaceBranchNaming.branchName(sessionID: "session/two", label: "Fix: parser / edge case") != first)
    }

    @Test("write ownership detects nested paths and shared resources")
    func detectsConflicts() throws {
        let claims = [
            WorkspaceOwnershipClaim(ownerID: "research", paths: ["Sources/DoMoCore"]),
            WorkspaceOwnershipClaim(ownerID: "execute", paths: ["Sources/DoMoCore/Feature.swift"]),
            WorkspaceOwnershipClaim(ownerID: "other", resources: ["database"], access: .write),
            WorkspaceOwnershipClaim(ownerID: "reader", resources: ["database"], access: .read),
        ]
        let conflicts = try WorkspaceOwnershipPlanner.conflicts(claims)
        #expect(conflicts.count == 2)
        #expect(conflicts[0].paths == ["Sources/DoMoCore"])
        #expect(conflicts[1].resources == ["database"])
    }

    @Test("read-only siblings share a wave while competing writes are separated")
    func plansWaves() throws {
        let plans = [
            WorkspaceStagePlan(stageID: "search-a", claims: [
                WorkspaceOwnershipClaim(ownerID: "search-a", paths: ["Sources/A.swift"], access: .read),
            ]),
            WorkspaceStagePlan(stageID: "search-b", claims: [
                WorkspaceOwnershipClaim(ownerID: "search-b", paths: ["Sources/A.swift"], access: .read),
            ]),
            WorkspaceStagePlan(stageID: "edit", claims: [
                WorkspaceOwnershipClaim(ownerID: "edit", paths: ["Sources/A.swift"], access: .write),
            ]),
        ]
        #expect(try WorkspaceOwnershipPlanner.waves(plans) == [["search-a", "search-b"], ["edit"]])
    }

    @Test("invalid ownership paths fail closed")
    func invalidClaims() {
        #expect(throws: WorkspaceOwnershipError.invalidPath("../outside")) {
            try WorkspaceOwnershipPlanner.conflicts([
                WorkspaceOwnershipClaim(ownerID: "unsafe", paths: ["../outside"]),
            ])
        }
        #expect(throws: WorkspaceOwnershipError.emptyOwner) {
            try WorkspaceOwnershipPlanner.conflicts([
                WorkspaceOwnershipClaim(ownerID: " ", paths: ["safe"]),
            ])
        }
    }

    @Test("coordinator keeps leases isolated and requires explicit promotion")
    func coordinatesLeaseLifecycle() async throws {
        let provider = FixtureWorkspaceProvider()
        let coordinator = WorkspaceLeaseCoordinator(provider: provider)
        let parent = try await coordinator.allocate(
            WorkspaceLeaseRequest(
                id: "parent-lease",
                sessionID: "parent-session",
                displayName: "Parent",
                rootPath: "/tmp/domo-parent-workspace"
            ),
            claims: [WorkspaceOwnershipClaim(ownerID: "parent", paths: ["Sources/App.swift"])]
        )
        try await coordinator.activate(id: parent.id)

        await #expect(throws: WorkspaceLeaseCoordinatorError.overlappingWorkspace(parent.id)) {
            _ = try await coordinator.allocate(
                WorkspaceLeaseRequest(
                    id: "child-lease",
                    sessionID: "child-session",
                    parentSessionID: parent.sessionID,
                    displayName: "Child",
                    rootPath: "/tmp/domo-parent-workspace/child"
                )
            )
        }

        let checkpoint = try await coordinator.checkpoint(id: parent.id)
        #expect(checkpoint.leaseID == parent.id)
        #expect((try await coordinator.lease(for: parent.id)).checkpointID == checkpoint.id)

        let pending = try await coordinator.promote(WorkspacePromotionRequest(
            leaseID: parent.id,
            targetSessionID: "target-session"
        ))
        #expect(pending.status == .requiresApproval)
        #expect(try await coordinator.lease(for: parent.id).state == .promotionPending)

        let promoted = try await coordinator.promote(WorkspacePromotionRequest(
            leaseID: parent.id,
            targetSessionID: "target-session",
            approved: true
        ))
        #expect(promoted.status == .promoted)
        #expect(try await coordinator.lease(for: parent.id).state == .promoted)
        #expect(await provider.promotionCount == 1)

        try await coordinator.cleanup(id: parent.id)
        #expect(try await coordinator.lease(for: parent.id).state == .cleaned)
    }

    @Test("coordinator blocks promotion when declared ownership overlaps")
    func blocksConflictingPromotion() async throws {
        let provider = FixtureWorkspaceProvider()
        let coordinator = WorkspaceLeaseCoordinator(provider: provider)
        _ = try await coordinator.allocate(
            WorkspaceLeaseRequest(
                id: "first",
                sessionID: "first-session",
                displayName: "First",
                rootPath: "/tmp/domo-first-workspace"
            ),
            claims: [WorkspaceOwnershipClaim(ownerID: "first-agent", paths: ["Sources/Feature.swift"])]
        )
        let second = try await coordinator.allocate(
            WorkspaceLeaseRequest(
                id: "second",
                sessionID: "second-session",
                displayName: "Second",
                rootPath: "/tmp/domo-second-workspace"
            ),
            claims: [WorkspaceOwnershipClaim(ownerID: "second-agent", paths: ["Sources/Feature.swift"])]
        )
        try await coordinator.activate(id: second.id)

        let result = try await coordinator.promote(WorkspacePromotionRequest(
            leaseID: second.id,
            targetSessionID: "target-session",
            approved: true
        ))
        #expect(result.status == .conflicted)
        #expect(result.conflictingPaths == ["Sources/Feature.swift"])
        #expect(try await coordinator.lease(for: second.id).state == .conflicted)
        #expect(await provider.promotionCount == 0)
    }
}

private actor FixtureWorkspaceProvider: WorkspaceProvider {
    private(set) var promotionCount = 0

    func allocate(_ request: WorkspaceLeaseRequest) async throws -> WorkspaceLease {
        WorkspaceLease(
            id: request.id,
            sessionID: request.sessionID,
            parentSessionID: request.parentSessionID,
            rootPath: request.rootPath,
            branchName: WorkspaceBranchNaming.branchName(
                sessionID: request.sessionID,
                label: request.displayName
            ),
            baseRevision: request.baseRevision
        )
    }

    func checkpoint(_ lease: WorkspaceLease) async throws -> WorkspaceCheckpoint {
        WorkspaceCheckpoint(
            id: "checkpoint-(lease.id)",
            leaseID: lease.id,
            revision: lease.baseRevision,
            createdAt: "2026-08-03T00:00:00Z"
        )
    }

    func diff(_ lease: WorkspaceLease) async throws -> WorkspaceDiffSummary {
        WorkspaceDiffSummary(leaseID: lease.id, baseRevision: lease.baseRevision)
    }

    func promote(_ request: WorkspacePromotionRequest) async throws -> WorkspacePromotionResult {
        promotionCount += 1
        return WorkspacePromotionResult(
            status: .promoted,
            leaseID: request.leaseID,
            message: "Fixture promoted"
        )
    }

    func cleanup(_ lease: WorkspaceLease) async throws {}
}
