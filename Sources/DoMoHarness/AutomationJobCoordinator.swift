// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

/// A bounded automation invocation and its durable job result.
public struct AutomationExecutionResult: Sendable, Hashable {
    public let invocation: AutomationInvocation
    public let job: JobRecord

    public init(invocation: AutomationInvocation, job: JobRecord) {
        self.invocation = invocation
        self.job = job
    }
}

public enum AutomationJobError: Error, Sendable, Equatable {
    case runtimeBudgetExceeded(milliseconds: Int)
    case outputBudgetExceeded(bytes: Int, maximum: Int)
}

/// Bridges the policy/audit registry to the durable job manager.
///
/// This is intentionally an explicit execution seam. A scheduler, CLI command,
/// filesystem watcher, or authenticated webhook adapter must call `execute`
/// with a trusted operation; registering or enabling an automation never starts
/// a process on its own. The coordinator carries the named profile, workspace,
/// sandbox, provider/backend references, input, and bounded budget into the job
/// metadata so replay and audit consumers do not have to infer them later.
public actor AutomationJobCoordinator {
    private let registry: AutomationRegistry
    private let jobs: JobManager

    public init(
        registry: AutomationRegistry,
        jobs: JobManager
    ) {
        self.registry = registry
        self.jobs = jobs
    }

    public func execute(
        _ invocation: AutomationInvocation,
        operation: @escaping JobOperation
    ) async throws -> AutomationExecutionResult {
        guard let definition = try await registry.definition(id: invocation.automationID) else {
            throw AutomationRegistryError.notFound(invocation.automationID)
        }

        let jobID = invocation.jobID ?? UUIDv7.generate().description
        var linkedInvocation = invocation
        linkedInvocation.jobID = jobID
        var metadata: [String: JSONValue] = [
            "automationID": .string(definition.id),
            "invocationID": .string(invocation.id),
            "profileID": .string(definition.profileID),
            "workspaceRoot": .string(definition.workspaceRoot),
            "sandboxPolicyID": .string(definition.sandboxPolicyID),
            "maxRuntimeMilliseconds": .int(definition.budget.maxRuntimeMilliseconds),
            "maxOutputBytes": .int(definition.budget.maxOutputBytes),
            "input": invocation.input,
        ]
        // Preserve adapter-observed facts (for example a repository branch or
        // filesystem path) without allowing invocation metadata to replace the
        // coordinator's authoritative policy fields above.
        for (key, value) in invocation.metadata where metadata[key] == nil {
            metadata[key] = value
        }
        if let backendID = definition.backendID {
            metadata["backendID"] = .string(backendID)
        }
        if let providerID = definition.providerID {
            metadata["providerID"] = .string(providerID)
        }
        if !definition.secretScope.credentialReferences.isEmpty {
            metadata["credentialReferences"] = .array(
                definition.secretScope.credentialReferences.map(JSONValue.string)
            )
        }
        if !definition.secretScope.environmentNames.isEmpty {
            metadata["environmentNames"] = .array(
                definition.secretScope.environmentNames.map(JSONValue.string)
            )
        }

        let admission = JobAdmission(
            id: jobID,
            correlationID: invocation.id,
            sessionID: invocation.sessionID,
            kind: "automation",
            owner: definition.owner,
            retryPolicy: JobRetryPolicy(
                maxAttempts: definition.budget.maxAttempts,
                initialBackoffMilliseconds: 250,
                maximumBackoffMilliseconds: 30_000
            ),
            metadata: metadata,
            triggerSource: Self.jobTriggerSource(for: invocation.source)
        )
        _ = try await jobs.admit(admission)

        do {
            // Audit only after the durable job admission succeeds, so every
            // accepted invocation has a stable job correlation. If audit rejects
            // the request, the queued record is cancelled and remains truthful.
            let admittedInvocation = try await registry.invoke(linkedInvocation)
            let record = try await jobs.run(jobID: jobID, owner: definition.owner) { context in
                try await Self.runBounded(
                    operation: operation,
                    context: context,
                    budget: definition.budget
                )
            }
            return AutomationExecutionResult(invocation: admittedInvocation, job: record)
        } catch {
            if let record = try? await jobs.snapshot(jobID: jobID),
               !record.state.isTerminal {
                _ = try? await jobs.cancel(jobID: jobID, owner: definition.owner)
            }
            throw error
        }
    }

    private static func runBounded(
        operation: @escaping JobOperation,
        context: JobExecutionContext,
        budget: AutomationBudget
    ) async throws -> JobResult {
        let result = try await withThrowingTaskGroup(of: JobResult.self) { group in
            group.addTask {
                try await operation(context)
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(budget.maxRuntimeMilliseconds))
                throw AutomationJobError.runtimeBudgetExceeded(
                    milliseconds: budget.maxRuntimeMilliseconds
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AutomationJobError.runtimeBudgetExceeded(
                    milliseconds: budget.maxRuntimeMilliseconds
                )
            }
            return result
        }

        if let output = result.output {
            let bytes = try JSONEncoder().encode(output).count
            guard bytes <= budget.maxOutputBytes else {
                throw AutomationJobError.outputBudgetExceeded(
                    bytes: bytes,
                    maximum: budget.maxOutputBytes
                )
            }
        }
        return result
    }

    private static func jobTriggerSource(
        for source: AutomationInvocationSource
    ) -> JobTriggerSource {
        switch source {
        case .userPrompt: .userPrompt
        case .cli: .cli
        case .scheduledTrigger: .scheduled
        case .filesystemTrigger: .filesystem
        case .repositoryTrigger: .repository
        case .authenticatedWebhook: .webhook
        case .childAgentResult: .childAgentResult
        }
    }
}
