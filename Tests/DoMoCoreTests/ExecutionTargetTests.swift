// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Execution target selection", .serialized)
struct ExecutionTargetTests {
    @Test("selection binds a healthy backend to an active workspace")
    func selectsReadyPair() async throws {
        let backends = BackendRegistry()
        try await backends.register(TargetBackend(
            descriptor: BackendDescriptor(
                id: "local",
                displayName: "Local",
                kind: .localProcess,
                capabilities: ["pty", "workspace-write"]
            )
        ))
        try await backends.start(id: "local")

        let workspaces = WorkspaceLeaseCoordinator(provider: TargetWorkspaceProvider())
        let lease = try await workspaces.allocate(WorkspaceLeaseRequest(
            id: "lease-1",
            sessionID: "session-1",
            displayName: "Session",
            rootPath: "/tmp/domo-target-workspace"
        ))
        try await workspaces.activate(id: lease.id)

        let coordinator = ExecutionTargetCoordinator(backends: backends, workspaces: workspaces)
        let target = try await coordinator.select(ExecutionTargetRequest(
            backend: BackendSelectionRequest(
                backendID: "local",
                requiredCapabilities: ["pty"]
            ),
            workspaceID: lease.id,
            sessionID: lease.sessionID
        ))
        #expect(target.backendID == "local")
        #expect(target.workspaceID == lease.id)
        #expect(target.sessionID == lease.sessionID)
        #expect(target.rootPath == lease.rootPath)
        #expect(target.backend.health.isolationEstablished)
    }

    @Test("selection refuses a stopped backend and a paused workspace")
    func refusesUnavailablePair() async throws {
        let backends = BackendRegistry()
        try await backends.register(TargetBackend(
            descriptor: BackendDescriptor(
                id: "remote",
                displayName: "Remote",
                kind: .remoteWorker,
                capabilities: ["workspace-write"]
            )
        ))
        let workspaces = WorkspaceLeaseCoordinator(provider: TargetWorkspaceProvider())
        let lease = try await workspaces.allocate(WorkspaceLeaseRequest(
            id: "lease-2",
            sessionID: "session-2",
            displayName: "Session",
            rootPath: "/tmp/domo-target-workspace-2"
        ))
        try await workspaces.activate(id: lease.id)
        try await workspaces.pause(id: lease.id)

        let coordinator = ExecutionTargetCoordinator(backends: backends, workspaces: workspaces)
        await #expect(throws: ExecutionTargetError.workspaceNotActive(
            id: lease.id,
            state: .paused
        )) {
            _ = try await coordinator.select(ExecutionTargetRequest(
                backend: BackendSelectionRequest(backendID: "remote"),
                workspaceID: lease.id
            ))
        }

        await #expect(throws: ExecutionTargetError.backend(
            .notReady(backendID: "remote", state: .stopped)
        )) {
            _ = try await coordinator.select(ExecutionTargetRequest(
                backend: BackendSelectionRequest(backendID: "remote")
            ))
        }
    }

    @Test("automatic selection skips an unavailable optional backend")
    func selectsFirstReadyBackend() async throws {
        let backends = BackendRegistry()
        try await backends.register(TargetBackend(
            descriptor: BackendDescriptor(
                id: "unavailable",
                displayName: "Unavailable",
                kind: .docker,
                capabilities: ["pty"]
            )
        ))
        try await backends.register(TargetBackend(
            descriptor: BackendDescriptor(
                id: "ready",
                displayName: "Ready",
                kind: .localProcess,
                capabilities: ["pty"]
            )
        ))
        try await backends.start(id: "ready")

        let workspaces = WorkspaceLeaseCoordinator(provider: TargetWorkspaceProvider())
        let coordinator = ExecutionTargetCoordinator(backends: backends, workspaces: workspaces)
        let target = try await coordinator.select(ExecutionTargetRequest(
            backend: BackendSelectionRequest(requiredCapabilities: ["pty"])
        ))
        #expect(target.backendID == "ready")
    }
}

private actor TargetBackend: DoMoManagedBackend {
    nonisolated let backendDescriptor: BackendDescriptor
    nonisolated let descriptor: AdapterDescriptor
    private var state: BackendLifecycleState = .stopped

    init(descriptor: BackendDescriptor) {
        self.backendDescriptor = descriptor
        self.descriptor = descriptor.adapterDescriptor
    }

    func start() async throws { state = .healthy }

    func stop() async { state = .stopped }

    func health() async -> BackendHealth {
        BackendHealth(
            state: state,
            message: state == .healthy ? "Ready" : "Stopped",
            authenticated: true,
            isolationEstablished: true,
            capabilities: backendDescriptor.capabilities
        )
    }

    func execute(_ request: BackendRequest) async throws -> BackendResult {
        BackendResult(status: .succeeded, output: request.input)
    }

    func cancel(operationID: String) async {}
}

private actor TargetWorkspaceProvider: WorkspaceProvider {
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
            id: "checkpoint-\(lease.id)",
            leaseID: lease.id,
            createdAt: "2026-08-03T00:00:00Z"
        )
    }

    func diff(_ lease: WorkspaceLease) async throws -> WorkspaceDiffSummary {
        WorkspaceDiffSummary(leaseID: lease.id)
    }

    func promote(_ request: WorkspacePromotionRequest) async throws -> WorkspacePromotionResult {
        WorkspacePromotionResult(
            status: .promoted,
            leaseID: request.leaseID,
            message: "Promoted"
        )
    }

    func cleanup(_ lease: WorkspaceLease) async throws {}
}
