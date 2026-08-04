// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// The non-mutating backend requirements for one execution admission.
/// Selection never starts or reconnects a backend; callers must make lifecycle
/// transitions explicit before asking for a target.
public struct BackendSelectionRequest: Sendable, Codable, Hashable {
    public var backendID: String?
    public var requiredCapabilities: [String]
    public var requireIsolation: Bool

    public init(
        backendID: String? = nil,
        requiredCapabilities: [String] = [],
        requireIsolation: Bool = true
    ) {
        self.backendID = backendID
        self.requiredCapabilities = Array(Set(requiredCapabilities)).sorted()
        self.requireIsolation = requireIsolation
    }
}

/// A backend that has passed capability, isolation, and healthy-state checks.
public struct BackendSelection: Sendable, Codable, Hashable {
    public let descriptor: BackendDescriptor
    public let health: BackendHealth

    public init(descriptor: BackendDescriptor, health: BackendHealth) {
        self.descriptor = descriptor
        self.health = health
    }
}

/// A complete execution target. Workspace allocation and backend lifecycle are
/// separate operations; this value records the pair only after both are ready.
public struct ExecutionTarget: Sendable, Codable, Hashable {
    public let backend: BackendSelection
    public let workspace: WorkspaceLease?

    public init(backend: BackendSelection, workspace: WorkspaceLease? = nil) {
        self.backend = backend
        self.workspace = workspace
    }

    public var backendID: String { backend.descriptor.id }
    public var workspaceID: String? { workspace?.id }
    public var sessionID: String? { workspace?.sessionID }
    public var rootPath: String? { workspace?.rootPath }
}

public struct ExecutionTargetRequest: Sendable, Codable, Hashable {
    public var backend: BackendSelectionRequest
    public var workspaceID: String?
    public var sessionID: String?

    public init(
        backend: BackendSelectionRequest = .init(),
        workspaceID: String? = nil,
        sessionID: String? = nil
    ) {
        self.backend = backend
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public enum ExecutionTargetError: Error, Sendable, Equatable {
    case backend(BackendRegistryError)
    case workspace(WorkspaceLeaseCoordinatorError)
    case workspaceNotActive(id: String, state: WorkspaceLeaseState)
    case workspaceSessionMismatch(workspaceID: String, expected: String, actual: String)
    case sessionRequiresWorkspace(String)
}

/// Coordinates the two independent Phase 28 selections without allowing a
/// caller to accidentally execute against a stopped backend or a workspace
/// that is still only allocated, paused, or pending promotion.
public actor ExecutionTargetCoordinator {
    private let backends: BackendRegistry
    private let workspaces: WorkspaceLeaseCoordinator

    public init(backends: BackendRegistry, workspaces: WorkspaceLeaseCoordinator) {
        self.backends = backends
        self.workspaces = workspaces
    }

    public func select(
        _ request: ExecutionTargetRequest = .init()
    ) async throws(ExecutionTargetError) -> ExecutionTarget {
        if request.workspaceID == nil, let sessionID = request.sessionID {
            throw .sessionRequiresWorkspace(sessionID)
        }

        let workspace: WorkspaceLease?
        if let workspaceID = request.workspaceID {
            do {
                workspace = try await workspaces.lease(for: workspaceID)
            } catch {
                throw .workspace(error)
            }
            guard let workspace else {
                throw .workspace(.notFound(workspaceID))
            }
            guard workspace.state == .active else {
                throw .workspaceNotActive(id: workspace.id, state: workspace.state)
            }
            if let sessionID = request.sessionID, sessionID != workspace.sessionID {
                throw .workspaceSessionMismatch(
                    workspaceID: workspace.id,
                    expected: sessionID,
                    actual: workspace.sessionID
                )
            }
        } else {
            workspace = nil
        }

        do {
            let backend = try await backends.select(request.backend)
            return ExecutionTarget(backend: backend, workspace: workspace)
        } catch {
            throw .backend(error)
        }
    }
}
