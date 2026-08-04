// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

public struct WorkflowStageRequest: Sendable, Hashable {
    public let workflowID: String
    public let runID: String
    public let stage: WorkflowStageDefinition
    public let input: JSONValue
    public let dependencyOutputs: [String: JSONValue]

    public init(
        workflowID: String,
        runID: String,
        stage: WorkflowStageDefinition,
        input: JSONValue,
        dependencyOutputs: [String: JSONValue]
    ) {
        self.workflowID = workflowID
        self.runID = runID
        self.stage = stage
        self.input = input
        self.dependencyOutputs = dependencyOutputs
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

public enum WorkflowRunnerError: Error, Sendable, Equatable {
    case invalidDefinition([String])
    case alreadyRunning
    case stageFailed(id: String, message: String)
    case unresolvedStages([String])
}

/// Executes a validated workflow DAG in deterministic dependency waves.
/// Persistence is injected so a server, CLI, or future remote backend can use
/// the same runner while choosing its own workflow directory.
public actor WorkflowRunner {
    public let definition: WorkflowDefinition
    public let executionMode: WorkflowExecutionMode

    private let store: WorkflowStore?
    private let executor: WorkflowStageExecutor
    private let now: @Sendable () -> String
    private var currentRun: WorkflowRunRecord?
    private var running = false
    private var cancellationRequested = false

    public init(
        definition: WorkflowDefinition,
        executionMode: WorkflowExecutionMode = .serial,
        store: WorkflowStore? = nil,
        now: @escaping @Sendable () -> String = { WorkflowStore.timestamp() },
        executor: @escaping WorkflowStageExecutor
    ) {
        self.definition = definition
        self.executionMode = executionMode
        self.store = store
        self.now = now
        self.executor = executor
    }

    public func run(
        input: JSONValue = .null,
        runID: String = UUIDv7.generate().description
    ) async throws -> WorkflowRunRecord {
        guard !running else { throw WorkflowRunnerError.alreadyRunning }
        guard definition.isValid else {
            throw WorkflowRunnerError.invalidDefinition(definition.validationIssues)
        }

        running = true
        cancellationRequested = false
        defer { running = false }

        var run = WorkflowRunRecord(
            id: runID,
            workflowID: definition.id,
            createdAt: now(),
            input: input,
            stageIDs: definition.stages.map(\.id),
            status: .running
        )
        try persist(&run)

        var outputs: [String: JSONValue] = [:]
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
            }
            try persist(&run)

            let outcomes: [StageOutcome]
            switch executionMode {
            case .serial:
                var serial: [StageOutcome] = []
                for stage in ready {
                    // A serial wave can contain several independent stages, so
                    // only expose the stage that has actually entered the
                    // executor as running. The remaining siblings stay ready.
                    _ = run.updateStage(stage.id, status: .running, timestamp: now())
                    try persist(&run)
                    serial.append(await execute(stage: stage, run: run, outputs: outputs))
                    if serial.last?.failure != nil { break }
                }
                outcomes = serial
            case .parallel:
                // All members of a parallel wave enter the executor together.
                for stage in ready {
                    _ = run.updateStage(stage.id, status: .running, timestamp: now())
                }
                try persist(&run)
                outcomes = await executeParallel(stages: ready, run: run, outputs: outputs)
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
        if var run = currentRun {
            run.cancellationRequested = true
            try persist(&run)
        }
    }

    public func snapshot() -> WorkflowRunRecord? { currentRun }

    private struct StageFailure: Sendable {
        let message: String
        let isCancellation: Bool
    }

    private struct StageOutcome: Sendable {
        let stageID: String
        let result: WorkflowStageResult?
        let failure: StageFailure?
    }

    private func execute(
        stage: WorkflowStageDefinition,
        run: WorkflowRunRecord,
        outputs: [String: JSONValue]
    ) async -> StageOutcome {
        let request = WorkflowStageRequest(
            workflowID: definition.id,
            runID: run.id,
            stage: stage,
            input: run.input,
            dependencyOutputs: stage.dependencies.reduce(into: [String: JSONValue]()) { result, dependency in
                if let output = outputs[dependency] { result[dependency] = output }
            }
        )
        do {
            return StageOutcome(stageID: stage.id, result: try await executor(request), failure: nil)
        } catch is CancellationError {
            return StageOutcome(
                stageID: stage.id,
                result: nil,
                failure: StageFailure(message: "Stage cancelled.", isCancellation: true)
            )
        } catch {
            return StageOutcome(
                stageID: stage.id,
                result: nil,
                failure: StageFailure(
                    message: Redaction.diagnostic(String(describing: error)),
                    isCancellation: false
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
}
