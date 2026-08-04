// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import Testing

@testable import DoMoClient

@MainActor
@Suite("Workflow workspace")
struct WorkflowWorkspaceTests {
    private static let enter: [UInt8] = [0x0d]
    private static let down: [UInt8] = [0x1b, 0x5b, 0x42]
    private static let escape: [UInt8] = [0x1b]
    private static let approve: [UInt8] = [0x61]
    private static let deny: [UInt8] = [0x64]

    private func workspace() -> WorkflowWorkspaceController {
        WorkflowWorkspaceController(phases: [
            WorkflowWorkspacePhase(
                id: "research",
                title: "Research",
                summary: "Gather evidence.",
                agents: [
                    WorkflowWorkspaceAgent(id: "one", title: "first agent", content: "first output"),
                    WorkflowWorkspaceAgent(id: "two", title: "second agent", status: .running, content: "second output"),
                ]
            ),
            WorkflowWorkspacePhase(
                id: "plan",
                title: "Plan",
                agents: [WorkflowWorkspaceAgent(id: "planner", title: "planner")]
            ),
        ])
    }

    @Test("Enter drills from phases to agents and then to live agent content")
    func drillsThroughWorkspace() {
        let view = workspace()
        view.focused = true

        view.handleInput(Self.enter)
        #expect(view.level == .agents)
        #expect(view.selectedPhase?.id == "research")

        view.handleInput(Self.down)
        #expect(view.selectedAgent?.id == "two")
        view.handleInput(Self.enter)
        #expect(view.level == .agentContent)
        #expect(view.render(width: 40).joined(separator: "\n").contains("second output"))
    }

    @Test("Escape walks back through the panes and exits at the phase root")
    func backsOutAndExits() {
        let view = workspace()
        var exited = false
        view.onExit = { exited = true }

        view.handleInput(Self.enter)
        view.handleInput(Self.enter)
        #expect(view.level == .agentContent)
        view.handleInput(Self.escape)
        #expect(view.level == .agents)
        view.handleInput(Self.escape)
        #expect(view.level == .phases)
        view.handleInput(Self.escape)
        #expect(exited)
    }

    @Test("The dedicated root paints navigation on the left and content on the right")
    func paintsTwoPanes() {
        let view = workspace()
        var buffer = CellBuffer(width: 80, height: 12)
        view.layout(width: 80).place(
            in: Rect(x: 0, y: 0, width: 80, height: 12),
            into: &buffer
        )
        let frame = buffer.flatten().joined(separator: "\n")
        #expect(frame.contains("Phases"))
        #expect(frame.contains("Research"))
        #expect(frame.contains("Workflow workspace"))
        #expect(frame.contains("│"))
        #expect(view.render(width: 40).allSatisfy { visibleWidth($0) <= 40 })
    }

    @Test("Approval shortcuts are available only from the selected agent content")
    func approvalShortcuts() {
        let view = workspace()
        var approvals = 0
        var denials = 0
        view.onApprove = { approvals += 1 }
        view.onDeny = { denials += 1 }

        view.handleInput(Self.approve)
        view.handleInput(Self.deny)
        #expect(approvals == 0)
        #expect(denials == 0)

        view.handleInput(Self.enter)
        view.handleInput(Self.enter)
        view.handleInput(Self.approve)
        view.handleInput(Self.deny)
        #expect(approvals == 1)
        #expect(denials == 1)
    }
}
