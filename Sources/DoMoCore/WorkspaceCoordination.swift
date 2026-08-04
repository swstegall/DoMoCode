// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

public enum WorkspaceLeaseState: String, Sendable, Codable, Hashable, CaseIterable {
    case allocated
    case active
    case paused
    case promotionPending
    case promoted
    case conflicted
    case cleaned
}

public struct WorkspaceLeaseRequest: Sendable, Codable, Hashable {
    public var id: String
    public var sessionID: String
    public var parentSessionID: String?
    public var displayName: String
    public var rootPath: String
    public var baseRevision: String?
    public var setupScript: String?

    public init(
        id: String,
        sessionID: String,
        parentSessionID: String? = nil,
        displayName: String,
        rootPath: String,
        baseRevision: String? = nil,
        setupScript: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.displayName = displayName
        self.rootPath = rootPath
        self.baseRevision = baseRevision
        self.setupScript = setupScript
    }
}

public struct WorkspaceLease: Sendable, Codable, Hashable {
    public var id: String
    public var sessionID: String
    public var parentSessionID: String?
    public var rootPath: String
    public var branchName: String
    public var baseRevision: String?
    public var checkpointID: String?
    public var state: WorkspaceLeaseState

    public init(
        id: String,
        sessionID: String,
        parentSessionID: String? = nil,
        rootPath: String,
        branchName: String,
        baseRevision: String? = nil,
        checkpointID: String? = nil,
        state: WorkspaceLeaseState = .allocated
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.rootPath = rootPath
        self.branchName = branchName
        self.baseRevision = baseRevision
        self.checkpointID = checkpointID
        self.state = state
    }
}

public struct WorkspaceCheckpoint: Sendable, Codable, Hashable {
    public var id: String
    public var leaseID: String
    public var revision: String?
    public var createdAt: String
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        leaseID: String,
        revision: String? = nil,
        createdAt: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.leaseID = leaseID
        self.revision = revision
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct WorkspaceDiffSummary: Sendable, Codable, Hashable {
    public var leaseID: String
    public var baseRevision: String?
    public var changedPaths: [String]
    public var patch: String?
    public var hasConflicts: Bool

    public init(
        leaseID: String,
        baseRevision: String? = nil,
        changedPaths: [String] = [],
        patch: String? = nil,
        hasConflicts: Bool = false
    ) {
        self.leaseID = leaseID
        self.baseRevision = baseRevision
        self.changedPaths = changedPaths.sorted()
        self.patch = patch
        self.hasConflicts = hasConflicts
    }
}

public struct WorkspacePromotionRequest: Sendable, Codable, Hashable {
    public var leaseID: String
    public var targetSessionID: String
    public var expectedBaseRevision: String?
    public var approved: Bool

    public init(
        leaseID: String,
        targetSessionID: String,
        expectedBaseRevision: String? = nil,
        approved: Bool = false
    ) {
        self.leaseID = leaseID
        self.targetSessionID = targetSessionID
        self.expectedBaseRevision = expectedBaseRevision
        self.approved = approved
    }
}

public enum WorkspacePromotionStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case promoted
    case requiresApproval
    case conflicted
    case rejected
}

public struct WorkspacePromotionResult: Sendable, Codable, Hashable {
    public var status: WorkspacePromotionStatus
    public var leaseID: String
    public var message: String
    public var resultingRevision: String?
    public var conflictingPaths: [String]

    public init(
        status: WorkspacePromotionStatus,
        leaseID: String,
        message: String,
        resultingRevision: String? = nil,
        conflictingPaths: [String] = []
    ) {
        self.status = status
        self.leaseID = leaseID
        self.message = message
        self.resultingRevision = resultingRevision
        self.conflictingPaths = conflictingPaths.sorted()
    }
}

/// A backend-specific implementation owns the actual Git worktree, remote
/// workspace, or container. The host sees only durable lease/checkpoint/diff
/// values and can therefore apply the same approval and redaction policy to
/// local and remote workspaces.
public protocol WorkspaceProvider: Sendable {
    func allocate(_ request: WorkspaceLeaseRequest) async throws -> WorkspaceLease
    func checkpoint(_ lease: WorkspaceLease) async throws -> WorkspaceCheckpoint
    func diff(_ lease: WorkspaceLease) async throws -> WorkspaceDiffSummary
    func promote(_ request: WorkspacePromotionRequest) async throws -> WorkspacePromotionResult
    func cleanup(_ lease: WorkspaceLease) async throws
}

public enum WorkspaceAccess: String, Sendable, Codable, Hashable, CaseIterable {
    case read
    case write
}

public struct WorkspaceOwnershipClaim: Sendable, Codable, Hashable {
    public var ownerID: String
    public var paths: [String]
    public var resources: [String]
    public var access: WorkspaceAccess

    public init(
        ownerID: String,
        paths: [String] = [],
        resources: [String] = [],
        access: WorkspaceAccess = .write
    ) {
        self.ownerID = ownerID
        self.paths = paths
        self.resources = resources
        self.access = access
    }
}

public struct WorkspaceConflict: Sendable, Codable, Hashable {
    public var leftOwnerID: String
    public var rightOwnerID: String
    public var paths: [String]
    public var resources: [String]

    public init(
        leftOwnerID: String,
        rightOwnerID: String,
        paths: [String] = [],
        resources: [String] = []
    ) {
        self.leftOwnerID = leftOwnerID
        self.rightOwnerID = rightOwnerID
        self.paths = paths.sorted()
        self.resources = resources.sorted()
    }
}

public enum WorkspaceOwnershipError: Error, Sendable, Equatable {
    case emptyOwner
    case invalidPath(String)
    case emptyResource
}

public struct WorkspaceStagePlan: Sendable, Codable, Hashable {
    public var stageID: String
    public var claims: [WorkspaceOwnershipClaim]

    public init(stageID: String, claims: [WorkspaceOwnershipClaim]) {
        self.stageID = stageID
        self.claims = claims
    }
}

/// Pure conflict detection and wave planning. A scheduler can use the result
/// to run non-overlapping stages in parallel and send competing work through an
/// explicit checkpoint/review/promotion boundary.
public enum WorkspaceOwnershipPlanner {
    public static func conflicts(
        _ claims: [WorkspaceOwnershipClaim]
    ) throws(WorkspaceOwnershipError) -> [WorkspaceConflict] {
        for claim in claims {
            try validate(claim)
        }

        var result: [WorkspaceConflict] = []
        for leftIndex in claims.indices {
            for rightIndex in claims.index(after: leftIndex)..<claims.endIndex {
                let left = claims[leftIndex]
                let right = claims[rightIndex]
                guard left.ownerID != right.ownerID,
                      left.access == .write || right.access == .write
                else { continue }
                let sharedPaths = overlappingPaths(left.paths, right.paths)
                let sharedResources = Set(left.resources).intersection(right.resources).sorted()
                guard !sharedPaths.isEmpty || !sharedResources.isEmpty else { continue }
                result.append(WorkspaceConflict(
                    leftOwnerID: left.ownerID,
                    rightOwnerID: right.ownerID,
                    paths: sharedPaths,
                    resources: sharedResources
                ))
            }
        }
        return result
    }

    public static func waves(
        _ plans: [WorkspaceStagePlan]
    ) throws(WorkspaceOwnershipError) -> [[String]] {
        var waves: [[WorkspaceStagePlan]] = []
        for plan in plans {
            for claim in plan.claims { try validate(claim) }
            var placed = false
            for index in waves.indices {
                let existingClaims = waves[index].flatMap(\.claims)
                let conflicts = try conflicts(existingClaims + plan.claims)
                if conflicts.isEmpty {
                    waves[index].append(plan)
                    placed = true
                    break
                }
            }
            if !placed { waves.append([plan]) }
        }
        return waves.map { $0.map(\.stageID) }
    }

    private static func validate(_ claim: WorkspaceOwnershipClaim) throws(WorkspaceOwnershipError) {
        guard !claim.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyOwner
        }
        for path in claim.paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."),
                  !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { throw .invalidPath(path) }
        }
        for resource in claim.resources {
            guard !resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !resource.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { throw .emptyResource }
        }
    }

    private static func overlappingPaths(_ left: [String], _ right: [String]) -> [String] {
        var result: Set<String> = []
        for a in left {
            for b in right {
                if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
                    result.insert(a.count <= b.count ? a : b)
                }
            }
        }
        return result.sorted()
    }
}

public enum WorkspaceBranchNaming {
    public static func branchName(sessionID: String, label: String) -> String {
        let rawSlug = label.lowercased().unicodeScalars.map { scalar -> String in
            if (scalar.value >= 0x61 && scalar.value <= 0x7a)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar.value == 0x2d
            {
                return String(scalar)
            }
            return "-"
        }.joined()
        let slug = rawSlug
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        .prefix(40)
        .description
        let safeSlug = slug.isEmpty ? "session" : slug
        return "domo/(safeSlug)-(shortHash(sessionID))"
    }

    private static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16).suffix(10).description
    }
}
