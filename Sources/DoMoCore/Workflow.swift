// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// The kind of work performed by one workflow stage. The values are policy
/// labels; execution remains owned by the runtime that schedules the stage.
public enum WorkflowStageKind: String, Sendable, Codable, Hashable, CaseIterable {
    case ask
    case debug
    case review
    case research
    case plan
    case execute
    case synthesize
}

public enum WorkflowToolPolicyMode: String, Sendable, Codable, Hashable, CaseIterable {
    case readOnly
    case approvedMutations
    case full
}

/// A stage's tool policy is explicit and serializable. ``allowedTools`` is an
/// optional narrowing list; it never grants a permission that the host policy
/// would otherwise deny.
public struct WorkflowToolPolicy: Sendable, Codable, Hashable {
    public var mode: WorkflowToolPolicyMode
    public var allowedTools: [String]

    public init(
        mode: WorkflowToolPolicyMode,
        allowedTools: [String] = []
    ) {
        self.mode = mode
        self.allowedTools = Array(Set(allowedTools)).sorted()
    }

    public static let readOnly = WorkflowToolPolicy(mode: .readOnly)
}

public struct WorkflowBudget: Sendable, Codable, Hashable {
    public var maxTokens: Int?
    public var maxCostUSD: Double?
    public var wallClockSeconds: Double?

    public init(
        maxTokens: Int? = nil,
        maxCostUSD: Double? = nil,
        wallClockSeconds: Double? = nil
    ) {
        self.maxTokens = maxTokens
        self.maxCostUSD = maxCostUSD
        self.wallClockSeconds = wallClockSeconds
    }
}

public enum WorkflowApprovalBoundary: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    case beforeStage
    case beforeMutation
    case beforeSynthesis
}

public enum WorkflowCancellationPolicy: String, Sendable, Codable, Hashable, CaseIterable {
    case stopDependents
    case continueIndependent
    case checkpointAndStop
}

public enum WorkflowExecutionMode: String, Sendable, Codable, Hashable, CaseIterable {
    case serial
    case parallel
}

/// One node in a workflow sequence or DAG. Dependencies refer to other stage
/// ids in the same definition and are validated before a run can be scheduled.
public struct WorkflowStageDefinition: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var kind: WorkflowStageKind
    public var dependencies: [String]
    public var toolPolicy: WorkflowToolPolicy
    public var model: String?
    public var profile: String?
    public var contextInputs: [String]
    public var outputArtifact: String?
    public var budget: WorkflowBudget
    public var timeoutSeconds: Double?
    public var cancellationPolicy: WorkflowCancellationPolicy
    public var approvalBoundary: WorkflowApprovalBoundary
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        displayName: String? = nil,
        kind: WorkflowStageKind,
        dependencies: [String] = [],
        toolPolicy: WorkflowToolPolicy = .readOnly,
        model: String? = nil,
        profile: String? = nil,
        contextInputs: [String] = [],
        outputArtifact: String? = nil,
        budget: WorkflowBudget = WorkflowBudget(),
        timeoutSeconds: Double? = nil,
        cancellationPolicy: WorkflowCancellationPolicy = .stopDependents,
        approvalBoundary: WorkflowApprovalBoundary = .none,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.kind = kind
        var uniqueDependencies: [String] = []
        var seenDependencies: Set<String> = []
        for dependency in dependencies where seenDependencies.insert(dependency).inserted {
            uniqueDependencies.append(dependency)
        }
        self.dependencies = uniqueDependencies
        self.toolPolicy = toolPolicy
        self.model = model
        self.profile = profile
        self.contextInputs = contextInputs
        self.outputArtifact = outputArtifact
        self.budget = budget
        self.timeoutSeconds = timeoutSeconds
        self.cancellationPolicy = cancellationPolicy
        self.approvalBoundary = approvalBoundary
        self.metadata = metadata
    }
}

/// A durable workflow definition. Validation is deliberately a value-level
/// operation so callers can show all issues in an editor before persisting it.
public struct WorkflowDefinition: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var version: Int
    public var executionMode: WorkflowExecutionMode
    public var stages: [WorkflowStageDefinition]
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        displayName: String? = nil,
        version: Int = 1,
        executionMode: WorkflowExecutionMode = .serial,
        stages: [WorkflowStageDefinition],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.version = version
        self.executionMode = executionMode
        self.stages = stages
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case version
        case executionMode
        case stages
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        version = try container.decode(Int.self, forKey: .version)
        // Records written before persisted scheduling existed were serial.
        executionMode = try container.decodeIfPresent(
            WorkflowExecutionMode.self,
            forKey: .executionMode
        ) ?? .serial
        stages = try container.decode([WorkflowStageDefinition].self, forKey: .stages)
        metadata = try container.decode([String: JSONValue].self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(version, forKey: .version)
        try container.encode(executionMode, forKey: .executionMode)
        try container.encode(stages, forKey: .stages)
        try container.encode(metadata, forKey: .metadata)
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("workflow id must not be empty")
        }
        if stages.isEmpty {
            issues.append("workflow must contain at least one stage")
        }
        var seen: Set<String> = []
        for stage in stages {
            let stageID = stage.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if stageID.isEmpty {
                issues.append("stage id must not be empty")
            } else if !seen.insert(stageID).inserted {
                issues.append("duplicate stage id: \(stage.id)")
            }
            if let maxTokens = stage.budget.maxTokens, maxTokens <= 0 {
                issues.append("stage \(stage.id) maxTokens must be positive")
            }
            if let maxCost = stage.budget.maxCostUSD, !maxCost.isFinite || maxCost < 0 {
                issues.append("stage \(stage.id) maxCostUSD must be finite and not negative")
            }
            if let wallClock = stage.budget.wallClockSeconds, !wallClock.isFinite || wallClock <= 0 {
                issues.append("stage \(stage.id) wallClockSeconds must be finite and positive")
            }
            if let timeout = stage.timeoutSeconds, !timeout.isFinite || timeout <= 0 {
                issues.append("stage \(stage.id) timeoutSeconds must be finite and positive")
            }
        }

        let ids = Set(stages.map(\.id))
        for stage in stages {
            for dependency in stage.dependencies where !ids.contains(dependency) {
                issues.append("stage \(stage.id) depends on unknown stage: \(dependency)")
            }
        }

        var visiting: Set<String> = []
        var visited: Set<String> = []
        var cycleMessages: Set<String> = []
        let byID = Dictionary(stages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func visit(_ id: String) {
            guard !visited.contains(id) else { return }
            guard visiting.insert(id).inserted else {
                cycleMessages.insert("workflow contains a dependency cycle at stage: \(id)")
                return
            }
            for dependency in byID[id]?.dependencies ?? [] where byID[dependency] != nil {
                visit(dependency)
            }
            visiting.remove(id)
            visited.insert(id)
        }
        for stage in stages { visit(stage.id) }
        issues.append(contentsOf: cycleMessages.sorted())
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }

    /// The built-in workflow exposed by a fresh runtime. It is deliberately a
    /// value rather than executable policy: a host may persist, edit, or replace
    /// it before a run is admitted.
    public static let standard = WorkflowDefinition(
        id: "standard",
        displayName: "Research → Plan → Execute → Synthesize",
        executionMode: .serial,
        stages: [
            WorkflowStageDefinition(
                id: "research",
                displayName: "Research",
                kind: .research,
                toolPolicy: .readOnly,
                profile: "ask",
                contextInputs: ["prompt"],
                outputArtifact: ".domocode/evidence/standard.json",
                budget: WorkflowBudget(wallClockSeconds: 900),
                cancellationPolicy: .continueIndependent
            ),
            WorkflowStageDefinition(
                id: "plan",
                displayName: "Plan",
                kind: .plan,
                dependencies: ["research"],
                toolPolicy: .readOnly,
                profile: "plan",
                contextInputs: ["prompt", "research"],
                outputArtifact: ".domocode/plans/standard.md",
                budget: WorkflowBudget(wallClockSeconds: 900),
                approvalBoundary: .beforeStage
            ),
            WorkflowStageDefinition(
                id: "execute",
                displayName: "Execute",
                kind: .execute,
                dependencies: ["plan"],
                toolPolicy: WorkflowToolPolicy(mode: .approvedMutations),
                profile: "build",
                contextInputs: ["prompt", "plan"],
                budget: WorkflowBudget(wallClockSeconds: 1_800),
                cancellationPolicy: .checkpointAndStop,
                approvalBoundary: .beforeMutation
            ),
            WorkflowStageDefinition(
                id: "synthesize",
                displayName: "Synthesize",
                kind: .synthesize,
                dependencies: ["execute"],
                toolPolicy: .readOnly,
                profile: "review",
                contextInputs: ["prompt", "research", "plan", "execute"],
                budget: WorkflowBudget(wallClockSeconds: 600),
                approvalBoundary: .beforeSynthesis
            ),
        ],
        metadata: ["source": "builtin"]
    )
}

public enum WorkflowRunStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case pending
    case running
    case paused
    case succeeded
    case failed
    case cancelled
}

public enum WorkflowStageRunStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case pending
    case ready
    case waitingForApproval
    case running
    case succeeded
    case failed
    case cancelled
    case skipped
}

public struct WorkflowStageRunRecord: Sendable, Codable, Hashable {
    public var stageID: String
    public var status: WorkflowStageRunStatus
    public var startedAt: String?
    public var finishedAt: String?
    public var output: JSONValue
    public var error: String?
    public var agentIDs: [String]
    public var metadata: [String: JSONValue]

    public init(
        stageID: String,
        status: WorkflowStageRunStatus = .pending,
        startedAt: String? = nil,
        finishedAt: String? = nil,
        output: JSONValue = .null,
        error: String? = nil,
        agentIDs: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.stageID = stageID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.error = error
        self.agentIDs = agentIDs
        self.metadata = metadata
    }
}

public struct WorkflowRunRecord: Sendable, Codable, Hashable {
    public var id: String
    public var workflowID: String
    public var status: WorkflowRunStatus
    public var createdAt: String
    public var updatedAt: String
    public var input: JSONValue
    public var stages: [WorkflowStageRunRecord]
    public var output: JSONValue
    public var error: String?
    public var cancellationRequested: Bool
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        workflowID: String,
        createdAt: String,
        input: JSONValue = .null,
        stageIDs: [String] = [],
        status: WorkflowRunStatus = .pending,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.workflowID = workflowID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.input = input
        self.stages = stageIDs.map { WorkflowStageRunRecord(stageID: $0) }
        self.output = .null
        self.error = nil
        self.cancellationRequested = false
        self.metadata = metadata
    }

    public func stage(withID id: String) -> WorkflowStageRunRecord? {
        stages.first { $0.stageID == id }
    }

    @discardableResult
    public mutating func updateStage(
        _ stageID: String,
        status: WorkflowStageRunStatus,
        timestamp: String,
        output: JSONValue? = nil,
        error: String? = nil,
        agentIDs: [String]? = nil
    ) -> Bool {
        guard let index = stages.firstIndex(where: { $0.stageID == stageID }) else { return false }
        stages[index].status = status
        if status == .running { stages[index].startedAt = stages[index].startedAt ?? timestamp }
        if [.succeeded, .failed, .cancelled, .skipped].contains(status) {
            stages[index].finishedAt = timestamp
        }
        if let output { stages[index].output = output }
        stages[index].error = error
        if let agentIDs { stages[index].agentIDs = agentIDs }
        updatedAt = timestamp
        return true
    }
}

public enum WorkflowStoreRecordKind: String, Sendable, Codable, Hashable {
    case definition
    case runSnapshot
}

/// One append-only persistence row. A run is stored as a complete snapshot so
/// a crash between stage updates can recover the last committed state without a
/// replay-specific migration layer.
public struct WorkflowStoreRecord: Sendable, Codable, Hashable {
    public var kind: WorkflowStoreRecordKind
    public var id: String
    public var timestamp: String
    public var definition: WorkflowDefinition?
    public var run: WorkflowRunRecord?

    public init(definition: WorkflowDefinition, timestamp: String) {
        self.kind = .definition
        self.id = definition.id
        self.timestamp = timestamp
        self.definition = definition
        self.run = nil
    }

    public init(run: WorkflowRunRecord, timestamp: String) {
        self.kind = .runSnapshot
        self.id = run.id
        self.timestamp = timestamp
        self.definition = nil
        self.run = run
    }
}
