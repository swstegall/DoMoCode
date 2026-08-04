import DoMoCore
import DoMoHarness
import Testing

@Suite("Automation job coordinator", .serialized)
struct AutomationJobCoordinatorTests {
    @Test("links an audited invocation to a bounded durable job")
    func linksInvocationAndJob() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        try await registry.register(definition(enabled: true))
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(
            registry: registry,
            jobs: jobs
        )
        let invocation = AutomationInvocation(
            id: "invocation-1",
            automationID: "automation-1",
            source: .userPrompt,
            requestedBy: "owner",
            createdAt: "2026-01-01T00:00:00Z",
            input: ["answer": .string("run")]
        )

        let result = try await coordinator.execute(invocation) { context in
            try await context.reportProgress(JobProgress(fraction: 0.5), "Halfway")
            return JobResult(output: ["ok": .bool(true)])
        }

        #expect(result.invocation.jobID == result.job.id)
        #expect(result.job.state == .succeeded)
        #expect(result.job.triggerSource == .userPrompt)
        #expect(result.job.metadata["profileID"] == .string("profile"))
        #expect(try await registry.invocations(automationID: "automation-1").count == 1)
        #expect(try await jobs.events(jobID: result.job.id).map(\.kind).last == .succeeded)
    }

    @Test("applies output and runtime budgets without retrying policy failures")
    func budgetFailures() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        try await registry.register(definition(
            enabled: true,
            budget: AutomationBudget(maxRuntimeMilliseconds: 10, maxAttempts: 1, maxOutputBytes: 4)
        ))
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(registry: registry, jobs: jobs)
        let invocation = AutomationInvocation(
            id: "invocation-budget",
            automationID: "automation-1",
            source: .userPrompt,
            requestedBy: "owner",
            createdAt: "2026-01-01T00:00:00Z"
        )

        let output = try await coordinator.execute(invocation) { _ in
            JobResult(output: .string("too large"))
        }
        #expect(output.job.state == .failed)
        #expect(output.job.attempt == 1)
        #expect(output.job.error?.contains("outputBudgetExceeded") == true)

        let timeout = try await coordinator.execute(
            AutomationInvocation(
                id: "invocation-timeout",
                automationID: "automation-1",
                source: .userPrompt,
                requestedBy: "owner",
                createdAt: "2026-01-01T00:00:00Z"
            )
        ) { _ in
            try await Task.sleep(for: .milliseconds(100))
            return JobResult(output: .null)
        }
        #expect(timeout.job.state == .failed)
        #expect(timeout.job.error?.contains("runtimeBudgetExceeded") == true)
    }

    @Test("preserves trigger provenance and retries transient operation failures")
    func retryAndProvenance() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        try await registry.register(definition(
            enabled: true,
            trigger: AutomationTrigger(kind: .schedule, expression: "0 2 * * *"),
            budget: AutomationBudget(maxAttempts: 2)
        ))
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(registry: registry, jobs: jobs)
        let attempts = AttemptCounter()
        let result = try await coordinator.execute(AutomationInvocation(
            id: "invocation-schedule",
            automationID: "automation-1",
            source: .scheduledTrigger,
            requestedBy: "owner",
            createdAt: "2026-01-01T00:00:00Z"
        )) { _ in
            if await attempts.increment() == 1 {
                throw JobOperationFailure(message: "temporary overload", retryable: true)
            }
            return JobResult(output: .string("done"))
        }
        #expect(result.job.state == .succeeded)
        #expect(result.job.attempt == 2)
        #expect(result.job.triggerSource == .scheduled)
    }

    private func definition(
        enabled: Bool,
        trigger: AutomationTrigger = AutomationTrigger(kind: .manual),
        budget: AutomationBudget = AutomationBudget()
    ) -> AutomationDefinition {
        AutomationDefinition(
            id: "automation-1",
            displayName: "Automation",
            owner: "owner",
            profileID: "profile",
            workspaceRoot: "/workspace",
            sandboxPolicyID: "sandbox",
            trigger: trigger,
            budget: budget,
            enabled: enabled,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }
}

private actor AttemptCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}
