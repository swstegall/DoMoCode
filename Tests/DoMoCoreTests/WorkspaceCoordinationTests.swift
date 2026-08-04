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
}
