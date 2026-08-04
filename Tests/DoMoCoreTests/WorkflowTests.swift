// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import DoMoCore

@Suite("Workflow contracts")
struct WorkflowTests {
    @Test("the built-in workflow is a valid durable research-to-synthesis DAG")
    func standardWorkflowIsValid() throws {
        let definition = WorkflowDefinition.standard
        #expect(definition.isValid)
        #expect(definition.stages.map(\.id) == ["research", "plan", "execute", "synthesize"])
        #expect(definition.stages[0].toolPolicy.mode == .readOnly)
        #expect(definition.stages[2].approvalBoundary == .beforeMutation)
        let data = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(WorkflowDefinition.self, from: data) == definition)
    }

    @Test("a valid DAG round-trips with explicit stage policy")
    func validDAGRoundTrip() throws {
        let definition = WorkflowDefinition(
            id: "research-to-plan",
            displayName: "Research to plan",
            stages: [
                WorkflowStageDefinition(
                    id: "research",
                    kind: .research,
                    toolPolicy: .readOnly,
                    profile: "ask",
                    outputArtifact: ".domocode/evidence.json",
                    budget: WorkflowBudget(maxTokens: 4_000, maxCostUSD: 0.25, wallClockSeconds: 60),
                    approvalBoundary: .none
                ),
                WorkflowStageDefinition(
                    id: "plan",
                    kind: .plan,
                    dependencies: ["research"],
                    toolPolicy: WorkflowToolPolicy(mode: .approvedMutations, allowedTools: ["write"]),
                    profile: "plan",
                    outputArtifact: ".domocode/plans/research-to-plan.md",
                    approvalBoundary: .beforeStage
                ),
            ],
            metadata: ["owner": "test"]
        )

        #expect(definition.isValid)
        #expect(definition.validationIssues.isEmpty)
        let copy = try JSONDecoder().decode(
            WorkflowDefinition.self,
            from: JSONEncoder().encode(definition)
        )
        #expect(copy == definition)
        #expect(copy.stages[1].dependencies == ["research"])
        #expect(copy.stages[1].toolPolicy.allowedTools == ["write"])
    }

    @Test("validation catches duplicate, missing, and cyclic stage references")
    func invalidDAG() {
        let definition = WorkflowDefinition(
            id: "broken",
            stages: [
                WorkflowStageDefinition(id: "same", kind: .ask, dependencies: ["missing", "cycle"]),
                WorkflowStageDefinition(id: "same", kind: .review, dependencies: ["cycle"]),
                WorkflowStageDefinition(id: "cycle", kind: .debug, dependencies: ["same"]),
            ]
        )

        #expect(!definition.isValid)
        #expect(definition.validationIssues.contains("duplicate stage id: same"))
        #expect(definition.validationIssues.contains("stage same depends on unknown stage: missing"))
        #expect(definition.validationIssues.contains { $0.contains("dependency cycle") })
    }

    @Test("run snapshots update one stage without losing other stages")
    func runStageUpdate() {
        var run = WorkflowRunRecord(
            id: "run-1",
            workflowID: "workflow-1",
            createdAt: "2026-01-01T00:00:00Z",
            input: ["prompt": "inspect"],
            stageIDs: ["research", "plan"]
        )

        #expect(run.updateStage("research", status: .running, timestamp: "2026-01-01T00:01:00Z", agentIDs: ["agent-1"]))
        #expect(run.updateStage(
            "research",
            status: .succeeded,
            timestamp: "2026-01-01T00:02:00Z",
            output: ["evidence": "one"]
        ))
        #expect(run.stage(withID: "research")?.status == .succeeded)
        #expect(run.stage(withID: "research")?.agentIDs == ["agent-1"])
        #expect(run.stage(withID: "research")?.output["evidence"]?.stringValue == "one")
        #expect(run.stage(withID: "plan")?.status == .pending)
        #expect(!run.updateStage("unknown", status: .running, timestamp: "2026-01-01T00:03:00Z"))
    }
}
