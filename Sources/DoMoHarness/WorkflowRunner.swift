// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

public struct WorkflowStageRequest: Sendable, Hashable {
    public let workflowID: String
    public let runID: String
    public let sessionID: String?
    public let stage: WorkflowStageDefinition
    public let input: JSONValue
    public let dependencyOutputs: [String: JSONValue]
    public let dependencyArtifacts: [String: String]

    public init(
        workflowID: String,
        runID: String,
        sessionID: String? = nil,
        stage: WorkflowStageDefinition,
        input: JSONValue,
        dependencyOutputs: [String: JSONValue],
        dependencyArtifacts: [String: String] = [:]
    ) {
        self.workflowID = workflowID
        self.runID = runID
        self.sessionID = sessionID
        self.stage = stage
        self.input = input
        self.dependencyOutputs = dependencyOutputs
        self.dependencyArtifacts = dependencyArtifacts
    }
}

public struct WorkflowStageResult: Sendable, Hashable {
    public let output: JSONValue
    public let metadata: [String: JSONValue]
    public let agentIDs: [String]

    public init(
        output: JSONValue = .null,
        metadata: [String: JSONValue] = [:],
        agentIDs: [String] = []
    ) {
        self.output = output
        self.metadata = metadata
        self.agentIDs = agentIDs
    }
}

public typealias WorkflowStageExecutor = @Sendable (WorkflowStageRequest) async throws -> WorkflowStageResult

public struct WorkflowApprovalRequest: Codable, Sendable, Hashable {
    public let workflowID: String
    public let runID: String
    public let stage: WorkflowStageDefinition

    public init(workflowID: String, runID: String, stage: WorkflowStageDefinition) {
        self.workflowID = workflowID
        self.runID = runID
        self.stage = stage
    }
}

public enum WorkflowApprovalDecision: Sendable, Hashable {
    case approved
    case denied(String)
    case cancelled
    case paused
    case requiresApproval
}

public typealias WorkflowApprovalHandler = @Sendable (WorkflowApprovalRequest) async -> WorkflowApprovalDecision

public enum WorkflowRunnerError: Error, Sendable, Equatable {
    case invalidDefinition([String])
    case alreadyRunning
    case runNotFound(String)
    case notResumableRun(String)
    case stageFailed(id: String, message: String)
    case unresolvedStages([String])
}

/// Executes a validated workflow DAG in deterministic dependency waves.
/// Persistence is injected so a server, CLI, or future remote backend can use
/// the same runner while choosing its own workflow directory.
public actor WorkflowRunner {
    public let definition: WorkflowDefinition
    public let executionMode: WorkflowExecutionMode
    public let sessionID: String?

    private let store: WorkflowStore?
    private let executor: WorkflowStageExecutor
    private let approvalHandler: WorkflowApprovalHandler?
    private let now: @Sendable () -> String
    private var currentRun: WorkflowRunRecord?
    private var running = false
    private var cancellationRequested = false
    private var pauseRequested = false

    public init(
        definition: WorkflowDefinition,
        executionMode: WorkflowExecutionMode? = nil,
        sessionID: String? = nil,
        store: WorkflowStore? = nil,
        now: @escaping @Sendable () -> String = { WorkflowStore.timestamp() },
        approvalHandler: WorkflowApprovalHandler? = nil,
        executor: @escaping WorkflowStageExecutor
    ) {
        self.definition = definition
        self.executionMode = executionMode ?? definition.executionMode
        self.sessionID = sessionID
        self.store = store
        self.now = now
        self.approvalHandler = approvalHandler
        self.executor = executor
    }

    public func run(
        input: JSONValue = .null,
        runID: String = UUIDv7.generate().description,
        metadata: [String: JSONValue] = [:]
    ) async throws -> WorkflowRunRecord {
        guard !running else { throw WorkflowRunnerError.alreadyRunning }
        guard definition.isValid else {
            throw WorkflowRunnerError.invalidDefinition(definition.validationIssues)
        }

        let run = WorkflowRunRecord(
            id: runID,
            workflowID: definition.id,
            createdAt: now(),
            input: input,
            stageIDs: definition.stages.map(\.id),
            status: .running,
            metadata: metadata
        )
        return try await execute(initialRun: run, outputs: [:])
    }

    /// Resume a failed, cancelled, paused, or interrupted run from its latest
    /// durable snapshot. Successful stages are retained and their outputs are
    /// passed to downstream work; unfinished stages are reset to pending so a
    /// user makes the explicit decision to retry them.
    public func resume(runID: String) async throws -> WorkflowRunRecord {
        guard !running else { throw WorkflowRunnerError.alreadyRunning }
        guard definition.isValid else {
            throw WorkflowRunnerError.invalidDefinition(definition.validationIssues)
        }
        guard let store, let stored = try store.latestRun(withID: runID) else {
            throw WorkflowRunnerError.runNotFound(runID)
        }
        guard stored.workflowID == definition.id,
              [.failed, .cancelled, .paused, .running].contains(stored.status)
        else {
            throw WorkflowRunnerError.notResumableRun(runID)
        }

        let successful = Dictionary(
            uniqueKeysWithValues: stored.stages
                .filter { $0.status == .succeeded }
                .map { ($0.stageID, $0.output) }
        )
        var recovered = stored
        recovered.status = .running
        recovered.error = nil
        recovered.cancellationRequested = false
        recovered.metadata.removeValue(forKey: "pauseRequested")
        recovered.updatedAt = now()
        recovered.stages = definition.stages.map { stage in
            guard let prior = stored.stage(withID: stage.id), prior.status == .succeeded else {
                return WorkflowStageRunRecord(stageID: stage.id, metadata: stored.stage(withID: stage.id)?.metadata ?? [:])
            }
            return prior
        }
        return try await execute(initialRun: recovered, outputs: successful)
    }

    private func execute(
        initialRun: WorkflowRunRecord,
        outputs initialOutputs: [String: JSONValue]
    ) async throws -> WorkflowRunRecord {
        running = true
        cancellationRequested = false
        pauseRequested = false
        defer { running = false }

        var run = initialRun
        run.status = .running
        try persist(&run)

        var outputs = initialOutputs
        while true {
            if cancellationRequested || Task.isCancelled {
                for stage in definition.stages where run.stage(withID: stage.id)?.status == .pending || run.stage(withID: stage.id)?.status == .ready {
                    _ = run.updateStage(stage.id, status: .cancelled, timestamp: now())
                }
                run.cancellationRequested = true
                run.status = .cancelled
                run.error = "Workflow cancellation requested."
                try persist(&run)
                return run
            }
            if pauseRequested {
                for stage in definition.stages {
                    guard let record = run.stage(withID: stage.id),
                          record.status == .ready || record.status == .waitingForApproval
                    else { continue }
                    _ = run.updateStage(stage.id, status: .pending, timestamp: now())
                }
                run.status = .paused
                run.error = "Workflow pause requested."
                try persist(&run)
                return run
            }

            let pending = definition.stages.filter {
                guard let record = run.stage(withID: $0.id) else { return false }
                return record.status == .pending
            }
            if pending.isEmpty {
                run.status = .succeeded
                run.output = definition.stages.reversed()
                    .compactMap { outputs[$0.id] }
                    .first ?? .null
                try persist(&run)
                return run
            }

            let ready = pending.filter { stage in
                stage.dependencies.allSatisfy {
                    run.stage(withID: $0)?.status == .succeeded
                }
            }
            if ready.isEmpty {
                let unresolved = pending.map(\.id)
                run.status = .failed
                run.error = "No runnable stage remains; dependencies did not complete."
                try persist(&run)
                throw WorkflowRunnerError.unresolvedStages(unresolved)
            }

            for stage in ready {
                _ = run.updateStage(stage.id, status: .ready, timestamp: now())
                setProgress(stage.id, "Queued for execution…", run: &run)
            }
            try persist(&run)

            let outcomes: [StageOutcome]
            switch executionMode {
            case .serial:
                var serial: [StageOutcome] = []
                for stage in ready {
                    if stage.approvalBoundary != .none {
                        _ = run.updateStage(stage.id, status: .waitingForApproval, timestamp: now())
                        setProgress(stage.id, "Waiting for approval…", run: &run)
                        try persist(&run)
                        let decision = await approvalDecision(for: stage, runID: run.id)
                        if let failure = approvalFailure(decision, stageID: stage.id) {
                            serial.append(StageOutcome(stageID: stage.id, result: nil, failure: failure))
                            break
                        }
                        _ = run.updateStage(stage.id, status: .ready, timestamp: now())
                        setProgress(stage.id, "Approval received; starting…", run: &run)
                        try persist(&run)
                    }
                    // A serial wave can contain several independent stages, so
                    // only expose the stage that has actually entered the
                    // executor as running. The remaining siblings stay ready.
                    _ = run.updateStage(stage.id, status: .running, timestamp: now())
                    setProgress(stage.id, "Running \(stage.displayName)…", run: &run)
                    try persist(&run)
                    serial.append(await execute(stage: stage, run: run, outputs: outputs))
                    if serial.last?.failure != nil { break }
                }
                outcomes = serial
            case .parallel:
                // Approval is resolved before the wave starts. This keeps a
                // mutation boundary serial and deterministic even when the
                // approved stages themselves execute in parallel.
                var blocked: StageOutcome?
                for stage in ready where stage.approvalBoundary != .none {
                    _ = run.updateStage(stage.id, status: .waitingForApproval, timestamp: now())
                    setProgress(stage.id, "Waiting for approval…", run: &run)
                    try persist(&run)
                    let decision = await approvalDecision(for: stage, runID: run.id)
                    if let failure = approvalFailure(decision, stageID: stage.id) {
                        blocked = StageOutcome(stageID: stage.id, result: nil, failure: failure)
                        break
                    }
                    _ = run.updateStage(stage.id, status: .ready, timestamp: now())
                    setProgress(stage.id, "Approval received; starting…", run: &run)
                    try persist(&run)
                }
                if let blocked {
                    outcomes = [blocked]
                } else {
                    // All members of a parallel wave enter the executor together.
                    for stage in ready {
                        _ = run.updateStage(stage.id, status: .running, timestamp: now())
                        setProgress(stage.id, "Running \(stage.displayName)…", run: &run)
                    }
                    try persist(&run)
                    outcomes = await executeParallel(stages: ready, run: run, outputs: outputs)
                }
            }

            for outcome in outcomes {
                if let result = outcome.result {
                    outputs[outcome.stageID] = result.output
                    _ = run.updateStage(
                        outcome.stageID,
                        status: .succeeded,
                        timestamp: now(),
                        output: result.output,
                        agentIDs: result.agentIDs
                    )
                    if let index = run.stages.firstIndex(where: { $0.stageID == outcome.stageID }) {
                        run.stages[index].metadata.merge(result.metadata) { _, latest in latest }
                    }
                } else if let failure = outcome.failure {
                    if failure.isPause {
                        _ = run.updateStage(
                            outcome.stageID,
                            status: .pending,
                            timestamp: now()
                        )
                        run.status = .paused
                        run.error = failure.message
                        run.cancellationRequested = false
                        for stage in definition.stages {
                            guard let record = run.stage(withID: stage.id),
                                  record.status == .ready || record.status == .waitingForApproval
                            else { continue }
                            _ = run.updateStage(stage.id, status: .pending, timestamp: now())
                        }
                        try persist(&run)
                        return run
                    }
                    let status: WorkflowStageRunStatus = failure.isCancellation ? .cancelled : .failed
                    _ = run.updateStage(
                        outcome.stageID,
                        status: status,
                        timestamp: now(),
                        error: failure.message
                    )
                    run.status = failure.isCancellation ? .cancelled : .failed
                    run.error = failure.message
                    run.cancellationRequested = failure.isCancellation
                    if !failure.isCancellation {
                        // Sibling stages which were ready but never entered the
                        // executor cannot run safely after a failed wave. Keep
                        // their terminal state explicit for recovery and UI.
                        for stage in definition.stages {
                            guard let record = run.stage(withID: stage.id),
                                  record.status == .ready || record.status == .running
                            else { continue }
                            _ = run.updateStage(
                                stage.id,
                                status: .skipped,
                                timestamp: now(),
                                error: "Skipped after stage \(failure.message)."
                            )
                        }
                    }
                    try persist(&run)
                    if failure.isCancellation { return run }
                    throw WorkflowRunnerError.stageFailed(id: outcome.stageID, message: failure.message)
                }
            }
            try persist(&run)
        }
    }

    /// Requests cancellation at the next stage boundary. The in-flight stage is
    /// allowed to finish its own cleanup; pending and ready stages are persisted
    /// as cancelled immediately after that boundary.
    public func cancel() throws {
        guard running else { return }
        cancellationRequested = true
        pauseRequested = false
        if var run = currentRun {
            run.cancellationRequested = true
            try persist(&run)
        }
    }

    /// Pauses at the next stage boundary. Successful stages remain checkpoints;
    /// the current stage is allowed to finish, while pending and approval-bound
    /// stages remain resumable instead of being marked cancelled.
    public func pause() throws {
        guard running else { return }
        pauseRequested = true
        if var run = currentRun {
            run.metadata["pauseRequested"] = .bool(true)
            try persist(&run)
        }
    }

    public func snapshot() -> WorkflowRunRecord? { currentRun }

    private struct StageFailure: Sendable {
        let message: String
        let isCancellation: Bool
        let isPause: Bool
    }

    private struct StageTimedOut: Error, Sendable {
        let seconds: Double
    }

    private struct StageOutcome: Sendable {
        let stageID: String
        let result: WorkflowStageResult?
        let failure: StageFailure?
    }

    private func approvalDecision(
        for stage: WorkflowStageDefinition,
        runID: String
    ) async -> WorkflowApprovalDecision {
        guard let approvalHandler else { return .requiresApproval }
        return await approvalHandler(WorkflowApprovalRequest(
            workflowID: definition.id,
            runID: runID,
            stage: stage
        ))
    }

    private func approvalFailure(
        _ decision: WorkflowApprovalDecision,
        stageID: String
    ) -> StageFailure? {
        switch decision {
        case .approved:
            return nil
        case .denied(let reason):
            let safeReason = Redaction.diagnostic(reason.trimmingCharacters(in: .whitespacesAndNewlines))
            return StageFailure(
                message: safeReason.isEmpty ? "Stage \(stageID) approval denied." : safeReason,
                isCancellation: false,
                isPause: false
            )
        case .cancelled:
            return StageFailure(message: "Stage approval cancelled.", isCancellation: true, isPause: false)
        case .paused:
            return StageFailure(
                message: "Workflow paused before stage \(stageID).",
                isCancellation: false,
                isPause: true
            )
        case .requiresApproval:
            return StageFailure(
                message: "Stage \(stageID) requires approval, but no approval handler is configured.",
                isCancellation: false,
                isPause: false
            )
        }
    }

    private func execute(
        stage: WorkflowStageDefinition,
        run: WorkflowRunRecord,
        outputs: [String: JSONValue]
    ) async -> StageOutcome {
        let request = WorkflowStageRequest(
            workflowID: definition.id,
            runID: run.id,
            sessionID: sessionID,
            stage: stage,
            input: run.input,
            dependencyOutputs: stage.dependencies.reduce(into: [String: JSONValue]()) { result, dependency in
                if let output = outputs[dependency] { result[dependency] = output }
            },
            dependencyArtifacts: stage.dependencies.reduce(into: [String: String]()) { result, dependency in
                if let artifact = definition.stages.first(where: { $0.id == dependency })?.outputArtifact {
                    result[dependency] = artifact
                }
            }
        )
        do {
            let result: WorkflowStageResult
            if let seconds = stage.timeoutSeconds ?? stage.budget.wallClockSeconds {
                let executor = self.executor
                result = try await withThrowingTaskGroup(of: WorkflowStageResult.self) { group in
                    group.addTask { try await executor(request) }
                    group.addTask {
                        let boundedMilliseconds = min(
                            Double(Int.max),
                            max(0.001, seconds) * 1_000
                        )
                        let milliseconds = max(1, Int(boundedMilliseconds.rounded(.up)))
                        try await Task.sleep(for: .milliseconds(milliseconds))
                        throw StageTimedOut(seconds: seconds)
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    return first
                }
            } else {
                result = try await executor(request)
            }
            return StageOutcome(stageID: stage.id, result: result, failure: nil)
        } catch let timeout as StageTimedOut {
            return StageOutcome(
                stageID: stage.id,
                result: nil,
                failure: StageFailure(
                    message: "Stage timed out after \(timeout.seconds) seconds.",
                    isCancellation: false,
                    isPause: false
                )
            )
        } catch is CancellationError {
            return StageOutcome(
                stageID: stage.id,
                result: nil,
                failure: StageFailure(message: "Stage cancelled.", isCancellation: true, isPause: false)
            )
        } catch {
            return StageOutcome(
                stageID: stage.id,
                result: nil,
                failure: StageFailure(
                    message: Redaction.diagnostic(String(describing: error)),
                    isCancellation: false,
                    isPause: false
                )
            )
        }
    }

    private func executeParallel(
        stages: [WorkflowStageDefinition],
        run: WorkflowRunRecord,
        outputs: [String: JSONValue]
    ) async -> [StageOutcome] {
        await withTaskGroup(of: StageOutcome.self, returning: [StageOutcome].self) { group in
            for stage in stages {
                group.addTask {
                    await self.execute(stage: stage, run: run, outputs: outputs)
                }
            }
            var outcomes: [StageOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.stageID < $1.stageID }
        }
    }

    private func persist(_ run: inout WorkflowRunRecord) throws {
        currentRun = run
        try store?.append(run: run)
    }

    private func setProgress(
        _ stageID: String,
        _ message: String,
        run: inout WorkflowRunRecord
    ) {
        guard let index = run.stages.firstIndex(where: { $0.stageID == stageID }) else { return }
        run.stages[index].metadata["progress"] = .string(message)
    }
}
