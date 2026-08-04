// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import Foundation
import SystemPackage
import Testing

private actor WorkflowExecutionLog {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
}

private actor WorkflowStartSignal {
    private var started = false

    func markStarted() { started = true }

    func isStarted() -> Bool { started }
}

private actor WorkflowAttempts {
    private var values: [String: Int] = [:]

    func increment(_ id: String) -> Int {
        values[id, default: 0] += 1
        return values[id] ?? 0
    }

    func value(for id: String) -> Int { values[id] ?? 0 }
}

private struct TestWorkflowFailure: Error, Sendable {}

@Suite("Workflow runner", .serialized)
struct WorkflowRunnerTests {
    @Test("serial execution passes dependency outputs to the next stage")
    func serialDependencies() async throws {
        let definition = WorkflowDefinition(
            id: "serial",
            stages: [
                WorkflowStageDefinition(
                    id: "research",
                    kind: .research,
                    outputArtifact: ".domocode/evidence.json"
                ),
                WorkflowStageDefinition(id: "plan", kind: .plan, dependencies: ["research"]),
            ]
        )
        let log = WorkflowExecutionLog()
        let runner = WorkflowRunner(
            definition: definition,
            sessionID: "parent-session",
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            await log.append(request.stage.id)
            guard request.sessionID == "parent-session" else {
                return WorkflowStageResult(output: "missing parent session")
            }
            if request.stage.id == "plan" {
                guard request.dependencyOutputs["research"] == .string("evidence") else {
                    return WorkflowStageResult(output: "missing dependency")
                }
                guard request.dependencyArtifacts["research"] == ".domocode/evidence.json" else {
                    return WorkflowStageResult(output: "missing artifact")
                }
            }
            return WorkflowStageResult(output: request.stage.id == "research" ? "evidence" : "plan")
        }

        let run = try await runner.run(runID: "serial-run")
        #expect(run.status == .succeeded)
        #expect(run.output == "plan")
        #expect(run.stages.map(\.status) == [.succeeded, .succeeded])
        #expect(await log.values == ["research", "plan"])
    }

    @Test("stage evidence is propagated to dependent stages and durable records")
    func evidencePropagation() async throws {
        let definition = WorkflowDefinition(
            id: "evidence",
            stages: [
                WorkflowStageDefinition(id: "research", kind: .research),
                WorkflowStageDefinition(id: "plan", kind: .plan, dependencies: ["research"]),
            ]
        )
        let evidence = WorkflowEvidence(
            id: "research:observation",
            stageID: "research",
            source: "test-fixture",
            sessionID: "child-session",
            kind: .observed,
            untrustedData: true,
            summary: "Observed test evidence."
        )
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            if request.stage.id == "plan" {
                guard request.dependencyEvidence["research"] == [evidence] else {
                    return WorkflowStageResult(output: "missing evidence")
                }
            }
            return WorkflowStageResult(
                output: request.stage.id,
                evidence: request.stage.id == "research" ? [evidence] : []
            )
        }

        let run = try await runner.run(runID: "evidence-run")
        #expect(run.status == .succeeded)
        #expect(run.stage(withID: "research")?.evidence == [evidence])
        #expect(run.output == "plan")
    }

    @Test("parallel execution completes independent stages before their join")
    func parallelJoin() async throws {
        let definition = WorkflowDefinition(
            id: "parallel",
            executionMode: .parallel,
            stages: [
                WorkflowStageDefinition(id: "a", kind: .research),
                WorkflowStageDefinition(id: "b", kind: .research),
                WorkflowStageDefinition(id: "synthesize", kind: .synthesize, dependencies: ["a", "b"]),
            ]
        )
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            if request.stage.id == "synthesize" {
                guard request.dependencyOutputs.keys.sorted() == ["a", "b"] else {
                    return WorkflowStageResult(output: "missing inputs")
                }
            }
            return WorkflowStageResult(output: .string(request.stage.id))
        }

        let run = try await runner.run(runID: "parallel-run")
        #expect(run.status == .succeeded)
        #expect(run.stages.allSatisfy { $0.status == .succeeded })
        #expect(run.output == "synthesize")
    }

    @Test("cancellation persists a truthful cancelled run")
    func cancellation() async throws {
        let definition = WorkflowDefinition(
            id: "cancel",
            stages: [WorkflowStageDefinition(id: "slow", kind: .debug)]
        )
        let signal = WorkflowStartSignal()
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { _ in
            await signal.markStarted()
            try await Task.sleep(nanoseconds: 250_000_000)
            return WorkflowStageResult(output: "finished")
        }

        let task = Task { try await runner.run(runID: "cancel-run") }
        for _ in 0..<100 {
            if await signal.isStarted() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await signal.isStarted())
        #expect(await runner.snapshot()?.stage(withID: "slow")?.status == .running)
        try await runner.cancel()
        let run = try await task.value
        #expect(run.status == .cancelled)
        #expect(run.cancellationRequested)
        #expect(run.error?.contains("cancellation") == true)
    }

    @Test("continue-independent policy preserves unrelated stages and skips dependents")
    func continueIndependentPolicy() async throws {
        let definition = WorkflowDefinition(
            id: "continue-independent",
            stages: [
                WorkflowStageDefinition(
                    id: "research",
                    kind: .research,
                    cancellationPolicy: .continueIndependent
                ),
                WorkflowStageDefinition(
                    id: "plan",
                    kind: .plan,
                    dependencies: ["research"]
                ),
                WorkflowStageDefinition(id: "review", kind: .review),
            ]
        )
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            if request.stage.id == "research" {
                throw TestWorkflowFailure()
            }
            return WorkflowStageResult(output: request.stage.id)
        }

        do {
            _ = try await runner.run(runID: "continue-independent-run")
            Issue.record("expected the failed stage to remain visible in the final run")
        } catch let error as WorkflowRunnerError {
            guard case .stageFailed("research", _) = error else {
                Issue.record("unexpected runner error: \(error)")
                return
            }
        }

        let run = try #require(await runner.snapshot())
        #expect(run.status == .failed)
        #expect(run.stage(withID: "research")?.status == .failed)
        #expect(run.stage(withID: "review")?.status == .succeeded)
        #expect(run.stage(withID: "plan")?.status == .skipped)
        #expect(run.metadata["deferredFailureStageID"] == .string("research"))
    }

    @Test("pause preserves successful checkpoints and leaves later stages resumable")
    func pause() async throws {
        let definition = WorkflowDefinition(
            id: "pause",
            stages: [
                WorkflowStageDefinition(id: "research", kind: .research),
                WorkflowStageDefinition(id: "plan", kind: .plan, dependencies: ["research"]),
            ]
        )
        let signal = WorkflowStartSignal()
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            await signal.markStarted()
            try await Task.sleep(nanoseconds: 20_000_000)
            return WorkflowStageResult(output: request.stage.id)
        }

        let task = Task { try await runner.run(runID: "pause-run") }
        for _ in 0..<100 {
            if await signal.isStarted() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await signal.isStarted())
        try await runner.pause()
        let run = try await task.value
        #expect(run.status == .paused)
        #expect(!run.cancellationRequested)
        #expect(run.stage(withID: "research")?.status == .succeeded)
        #expect(run.stage(withID: "plan")?.status == .pending)
    }

    @Test("approval boundaries wait before executing a stage")
    func approvalBoundary() async throws {
        let definition = WorkflowDefinition(
            id: "approval",
            stages: [WorkflowStageDefinition(
                id: "execute",
                kind: .execute,
                approvalBoundary: .beforeMutation
            )]
        )
        let approvals = WorkflowExecutionLog()
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" },
            approvalHandler: { request in
                await approvals.append(request.stage.id)
                return .approved
            }
        ) { request in
            return WorkflowStageResult(output: "approved")
        }

        let run = try await runner.run(runID: "approval-run")
        #expect(run.status == .succeeded)
        #expect(await approvals.values == ["execute"])
    }

    @Test("stage progress is persisted before execution and completion")
    func progressMetadata() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-runner-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkflowStore.create(directory: FilePath(root.path))
        let definition = WorkflowDefinition(
            id: "progress",
            stages: [WorkflowStageDefinition(id: "research", kind: .research)]
        )
        let runner = WorkflowRunner(
            definition: definition,
            store: store,
            now: { "2026-01-01T00:00:00Z" }
        ) { _ in
            WorkflowStageResult(output: "evidence")
        }

        let run = try await runner.run(runID: "progress-run")
        #expect(run.status == .succeeded)
        #expect(run.stage(withID: "research")?.metadata["progress"] == .string("Running Research…"))
        let snapshots = try store.records().compactMap { $0.run }
        #expect(snapshots.contains { $0.stage(withID: "research")?.metadata["progress"] == .string("Queued for execution…") })
        #expect(snapshots.contains { $0.stage(withID: "research")?.metadata["progress"] == .string("Running Research…") })
    }

    @Test("missing approval handlers fail closed")
    func missingApprovalHandler() async throws {
        let definition = WorkflowDefinition(
            id: "approval-required",
            stages: [WorkflowStageDefinition(
                id: "execute",
                kind: .execute,
                approvalBoundary: .beforeMutation
            )]
        )
        let runner = WorkflowRunner(definition: definition) { _ in
            WorkflowStageResult(output: "must not run")
        }

        do {
            _ = try await runner.run(runID: "approval-required-run")
            Issue.record("expected missing approval to fail")
        } catch let error as WorkflowRunnerError {
            guard case .stageFailed("execute", let message) = error else {
                Issue.record("unexpected runner error: \(error)")
                return
            }
            #expect(message.contains("requires approval"))
        }
        #expect(await runner.snapshot()?.stage(withID: "execute")?.status == .failed)
    }

    @Test("a timed-out stage becomes a durable failure")
    func timeout() async throws {
        let definition = WorkflowDefinition(
            id: "timeout",
            stages: [WorkflowStageDefinition(
                id: "slow",
                kind: .debug,
                budget: WorkflowBudget(wallClockSeconds: 0.01)
            )]
        )
        let runner = WorkflowRunner(
            definition: definition,
            now: { "2026-01-01T00:00:00Z" }
        ) { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return WorkflowStageResult(output: "too late")
        }

        do {
            _ = try await runner.run(runID: "timeout-run")
            Issue.record("expected timeout failure")
        } catch let error as WorkflowRunnerError {
            guard case .stageFailed(let id, let message) = error else {
                Issue.record("unexpected runner error: \(error)")
                return
            }
            #expect(id == "slow")
            #expect(message.contains("timed out"))
        }
        #expect(await runner.snapshot()?.stage(withID: "slow")?.status == .failed)
    }

    @Test("resume reuses successful stage outputs without repeating them")
    func resume() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-runner-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkflowStore.create(directory: FilePath(root.path))
        let definition = WorkflowDefinition(
            id: "resume",
            stages: [
                WorkflowStageDefinition(id: "research", kind: .research),
                WorkflowStageDefinition(id: "plan", kind: .plan, dependencies: ["research"]),
            ]
        )
        let attempts = WorkflowAttempts()
        let runner = WorkflowRunner(
            definition: definition,
            store: store,
            now: { "2026-01-01T00:00:00Z" }
        ) { request in
            let attempt = await attempts.increment(request.stage.id)
            if request.stage.id == "plan", attempt == 1 { throw TestWorkflowFailure() }
            return WorkflowStageResult(output: request.stage.id == "research" ? "evidence" : "plan")
        }

        do {
            _ = try await runner.run(runID: "resume-run")
            Issue.record("expected the first plan attempt to fail")
        } catch let error as WorkflowRunnerError {
            guard case .stageFailed("plan", _) = error else {
                Issue.record("unexpected runner error: \(error)")
                return
            }
        }
        let resumed = try await runner.resume(runID: "resume-run")
        #expect(resumed.status == .succeeded)
        #expect(resumed.output == "plan")
        #expect(await attempts.value(for: "research") == 1)
        #expect(await attempts.value(for: "plan") == 2)
    }
}
