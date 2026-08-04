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
    public var conflictingResources: [String]
    public var conflictingOwners: [String]

    public init(
        status: WorkspacePromotionStatus,
        leaseID: String,
        message: String,
        resultingRevision: String? = nil,
        conflictingPaths: [String] = [],
        conflictingResources: [String] = [],
        conflictingOwners: [String] = []
    ) {
        self.status = status
        self.leaseID = leaseID
        self.message = message
        self.resultingRevision = resultingRevision
        self.conflictingPaths = conflictingPaths.sorted()
        self.conflictingResources = conflictingResources.sorted()
        self.conflictingOwners = conflictingOwners.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case status, leaseID, message, resultingRevision, conflictingPaths
        case conflictingResources, conflictingOwners
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(WorkspacePromotionStatus.self, forKey: .status)
        leaseID = try container.decode(String.self, forKey: .leaseID)
        message = try container.decode(String.self, forKey: .message)
        resultingRevision = try container.decodeIfPresent(String.self, forKey: .resultingRevision)
        conflictingPaths = try container.decodeIfPresent([String].self, forKey: .conflictingPaths) ?? []
        conflictingResources = try container.decodeIfPresent([String].self, forKey: .conflictingResources) ?? []
        conflictingOwners = try container.decodeIfPresent([String].self, forKey: .conflictingOwners) ?? []
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

/// Errors raised by the host-owned lease coordinator. Provider errors are
/// reduced to a redacted message at this boundary so a local Git error and a
/// remote worker error have the same safe shape for clients and logs.
public enum WorkspaceLeaseCoordinatorError: Error, Sendable, Equatable {
    case emptyLeaseID
    case duplicateLease(String)
    case notFound(String)
    case parentNotFound(String)
    case invalidRootPath(String)
    case overlappingWorkspace(String)
    case invalidOwnership(WorkspaceOwnershipError)
    case invalidProviderLease(String)
    case invalidState(leaseID: String, state: WorkspaceLeaseState)
    case ownershipConflict(
        leaseID: String,
        owners: [String],
        paths: [String],
        resources: [String]
    )
    case providerFailed(leaseID: String, operation: String, message: String)
}

/// Coordinates the safety boundary around a provider-owned workspace.
///
/// Providers allocate and mutate concrete worktrees, containers, or remote
/// workspaces. This actor owns the cross-provider rules: lease identity,
/// parent/child root separation, declared ownership conflicts, explicit
/// approval before promotion, and cleanup state. A provider is never asked to
/// promote a lease that has not passed those checks.
public actor WorkspaceLeaseCoordinator {
    private struct Record: Sendable {
        var lease: WorkspaceLease
        let claims: [WorkspaceOwnershipClaim]
    }

    private let provider: any WorkspaceProvider
    private var records: [String: Record] = [:]
    private var order: [String] = []

    public init(provider: any WorkspaceProvider) {
        self.provider = provider
    }

    public func leases() -> [WorkspaceLease] {
        order.compactMap { records[$0]?.lease }
    }

    public func lease(for id: String) throws(WorkspaceLeaseCoordinatorError) -> WorkspaceLease {
        guard let record = records[id] else { throw .notFound(id) }
        return record.lease
    }

    public func claims(for id: String) throws(WorkspaceLeaseCoordinatorError) -> [WorkspaceOwnershipClaim] {
        guard let record = records[id] else { throw .notFound(id) }
        return record.claims
    }

    /// Allocates one isolated root and records its ownership claims before it
    /// can be activated. The provider result is checked against the request so
    /// an adapter cannot accidentally hand a child the parent's root.
    public func allocate(
        _ request: WorkspaceLeaseRequest,
        claims: [WorkspaceOwnershipClaim] = []
    ) async throws(WorkspaceLeaseCoordinatorError) -> WorkspaceLease {
        let id = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw .emptyLeaseID }
        guard records[id] == nil else { throw .duplicateLease(id) }

        let requestedRoot = try Self.normalizedRoot(request.rootPath)
        do {
            _ = try WorkspaceOwnershipPlanner.conflicts(claims)
        } catch let error as WorkspaceOwnershipError {
            throw .invalidOwnership(error)
        }

        if let parentSessionID = request.parentSessionID {
            guard let parent = records.values.first(where: { $0.lease.sessionID == parentSessionID }) else {
                throw .parentNotFound(parentSessionID)
            }
            guard !Self.rootsOverlap(requestedRoot, parent.lease.rootPath) else {
                throw .overlappingWorkspace(parent.lease.id)
            }
        }
        for existing in records.values where existing.lease.state != .cleaned {
            guard !Self.rootsOverlap(requestedRoot, existing.lease.rootPath) else {
                throw .overlappingWorkspace(existing.lease.id)
            }
        }

        let allocated: WorkspaceLease
        do {
            allocated = try await provider.allocate(request)
        } catch {
            throw Self.providerFailure(id: id, operation: "allocate", error: error)
        }

        let allocatedRoot: String
        do {
            allocatedRoot = try Self.normalizedRoot(allocated.rootPath)
        } catch let error as WorkspaceLeaseCoordinatorError {
            try? await provider.cleanup(allocated)
            throw error
        }
        guard allocated.id == id,
              allocated.sessionID == request.sessionID,
              allocated.parentSessionID == request.parentSessionID,
              allocated.state == .allocated
        else {
            try? await provider.cleanup(allocated)
            throw .invalidProviderLease(id)
        }
        guard allocatedRoot == requestedRoot else {
            try? await provider.cleanup(allocated)
            throw .invalidProviderLease(id)
        }
        for existing in records.values where existing.lease.state != .cleaned {
            guard !Self.rootsOverlap(allocatedRoot, existing.lease.rootPath) else {
                try? await provider.cleanup(allocated)
                throw .overlappingWorkspace(existing.lease.id)
            }
        }

        var lease = allocated
        lease.id = id
        lease.rootPath = allocatedRoot
        records[id] = Record(lease: lease, claims: claims)
        order.append(id)
        return lease
    }

    /// Activates an allocated lease or resumes a paused one. No provider
    /// operation is implied: providers own their process/container lifecycle;
    /// this state records whether the coordinator will admit workspace work.
    public func activate(id: String) throws(WorkspaceLeaseCoordinatorError) {
        guard var record = records[id] else { throw .notFound(id) }
        guard [.allocated, .paused].contains(record.lease.state) else {
            throw .invalidState(leaseID: id, state: record.lease.state)
        }
        record.lease.state = .active
        records[id] = record
    }

    public func pause(id: String) throws(WorkspaceLeaseCoordinatorError) {
        guard var record = records[id] else { throw .notFound(id) }
        guard record.lease.state == .active else {
            throw .invalidState(leaseID: id, state: record.lease.state)
        }
        record.lease.state = .paused
        records[id] = record
    }

    public func checkpoint(id: String) async throws(WorkspaceLeaseCoordinatorError) -> WorkspaceCheckpoint {
        guard let record = records[id] else { throw .notFound(id) }
        guard [.active, .paused, .promotionPending].contains(record.lease.state) else {
            throw .invalidState(leaseID: id, state: record.lease.state)
        }
        let checkpoint: WorkspaceCheckpoint
        do {
            checkpoint = try await provider.checkpoint(record.lease)
        } catch {
            throw Self.providerFailure(leaseID: id, operation: "checkpoint", error: error)
        }
        guard checkpoint.leaseID == id else {
            throw .invalidProviderLease(id)
        }
        guard var current = records[id], current.lease.state != .cleaned else {
            throw .invalidState(leaseID: id, state: .cleaned)
        }
        current.lease.checkpointID = checkpoint.id
        records[id] = current
        return checkpoint
    }

    public func diff(id: String) async throws(WorkspaceLeaseCoordinatorError) -> WorkspaceDiffSummary {
        guard let record = records[id] else { throw .notFound(id) }
        guard record.lease.state != .cleaned else {
            throw .invalidState(leaseID: id, state: .cleaned)
        }
        do {
            let summary = try await provider.diff(record.lease)
            guard summary.leaseID == id else { throw WorkspaceLeaseCoordinatorError.invalidProviderLease(id) }
            return summary
        } catch let error as WorkspaceLeaseCoordinatorError {
            throw error
        } catch {
            throw Self.providerFailure(leaseID: id, operation: "diff", error: error)
        }
    }

    /// Attempts promotion only after ownership conflicts are absent and the
    /// caller has explicitly approved it. An unapproved request is a visible
    /// pending result and never reaches the provider.
    public func promote(
        _ request: WorkspacePromotionRequest
    ) async throws(WorkspaceLeaseCoordinatorError) -> WorkspacePromotionResult {
        guard var record = records[request.leaseID] else { throw .notFound(request.leaseID) }
        guard [.active, .paused, .promotionPending].contains(record.lease.state) else {
            throw .invalidState(leaseID: request.leaseID, state: record.lease.state)
        }
        guard !request.targetSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WorkspacePromotionResult(
                status: .rejected,
                leaseID: request.leaseID,
                message: "Promotion target is required"
            )
        }

        let currentOwners = Set(record.claims.map(\.ownerID))
        let otherClaims = records.values
            .filter { $0.lease.id != request.leaseID && $0.lease.state != .cleaned }
            .flatMap(\.claims)
        let allClaims = record.claims + otherClaims
        let conflicts: [WorkspaceConflict]
        do {
            conflicts = try WorkspaceOwnershipPlanner.conflicts(allClaims).filter {
                currentOwners.contains($0.leftOwnerID) || currentOwners.contains($0.rightOwnerID)
            }
        } catch let error as WorkspaceOwnershipError {
            throw .invalidOwnership(error)
        }
        if !conflicts.isEmpty {
            let paths = Array(Set(conflicts.flatMap(\.paths))).sorted()
            let resources = Array(Set(conflicts.flatMap(\.resources))).sorted()
            let owners = Array(Set(conflicts.flatMap { [$0.leftOwnerID, $0.rightOwnerID] })).sorted()
            record.lease.state = .conflicted
            records[request.leaseID] = record
            return WorkspacePromotionResult(
                status: .conflicted,
                leaseID: request.leaseID,
                message: "Workspace ownership conflicts require review",
                conflictingPaths: paths,
                conflictingResources: resources,
                conflictingOwners: owners
            )
        }

        guard request.approved else {
            record.lease.state = .promotionPending
            records[request.leaseID] = record
            return WorkspacePromotionResult(
                status: .requiresApproval,
                leaseID: request.leaseID,
                message: "Promotion requires explicit approval"
            )
        }

        let result: WorkspacePromotionResult
        do {
            result = try await provider.promote(request)
        } catch {
            throw Self.providerFailure(leaseID: request.leaseID, operation: "promote", error: error)
        }
        guard result.leaseID == request.leaseID else {
            throw .invalidProviderLease(request.leaseID)
        }
        guard var current = records[request.leaseID] else { throw .notFound(request.leaseID) }
        switch result.status {
        case .promoted:
            current.lease.state = .promoted
        case .requiresApproval:
            current.lease.state = .promotionPending
        case .conflicted:
            current.lease.state = .conflicted
        case .rejected:
            current.lease.state = .active
        }
        records[request.leaseID] = current
        return result
    }

    public func cleanup(id: String) async throws(WorkspaceLeaseCoordinatorError) {
        guard var record = records[id] else { throw .notFound(id) }
        guard record.lease.state != .cleaned else { return }
        do {
            try await provider.cleanup(record.lease)
        } catch {
            throw Self.providerFailure(leaseID: id, operation: "cleanup", error: error)
        }
        record.lease.state = .cleaned
        records[id] = record
    }

    public func waves(
        _ plans: [WorkspaceStagePlan]
    ) throws(WorkspaceOwnershipError) -> [[String]] {
        try WorkspaceOwnershipPlanner.waves(plans)
    }

    private static func normalizedRoot(_ path: String) throws(WorkspaceLeaseCoordinatorError) -> String {
        guard !path.isEmpty, path.hasPrefix("/"), path != "/",
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw .invalidRootPath(path) }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != "/", normalized.hasPrefix("/") else { throw .invalidRootPath(path) }
        return normalized
    }

    private static func rootsOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func providerFailure(
        leaseID: String,
        operation: String,
        error: any Error
    ) -> WorkspaceLeaseCoordinatorError {
        .providerFailed(
            leaseID: leaseID,
            operation: operation,
            message: Redaction.diagnostic(String(describing: error))
        )
    }
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
        return "domo/\(safeSlug)-\(shortHash(sessionID))"
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
