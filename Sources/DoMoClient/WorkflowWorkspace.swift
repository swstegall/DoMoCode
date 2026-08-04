// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTermIO
import DoMoTUI

/// The value shown for one agent in the workflow workspace. The runtime can
/// replace these values as a run emits stage/agent updates; the view never needs
/// to know whether the source was SSE, a local runner, or a replayed snapshot.
struct WorkflowWorkspaceAgent: Sendable, Hashable {
    let id: String
    let title: String
    let status: WorkflowStageRunStatus
    let content: String

    init(
        id: String,
        title: String? = nil,
        status: WorkflowStageRunStatus = .pending,
        content: String = ""
    ) {
        self.id = id
        self.title = title ?? id
        self.status = status
        self.content = content
    }
}

/// The value shown for one workflow phase in the left navigation pane.
struct WorkflowWorkspacePhase: Sendable, Hashable {
    let id: String
    let title: String
    let status: WorkflowStageRunStatus
    let summary: String
    let agents: [WorkflowWorkspaceAgent]

    init(
        id: String,
        title: String? = nil,
        status: WorkflowStageRunStatus = .pending,
        summary: String = "",
        agents: [WorkflowWorkspaceAgent] = []
    ) {
        self.id = id
        self.title = title ?? id
        self.status = status
        self.summary = summary
        self.agents = agents
    }
}

/// A focused, full-screen workflow navigator.
///
/// The ordinary client remains a session/sidebar/transcript view. This object is
/// mounted as a separate root when a workflow command is selected, matching the
/// Claude-Code-like interaction target: phases occupy the left pane; Enter drills
/// into a phase; agents then occupy that same left pane; Enter on an agent exposes
/// its live content on the right. Escape walks back one level, and Escape from the
/// phase list exits the workspace.
@MainActor
final class WorkflowWorkspaceController: Focusable {
    enum NavigationLevel: Equatable {
        case phases
        case agents
        case agentContent
    }

    var focused = false

    private(set) var phases: [WorkflowWorkspacePhase]
    private(set) var level: NavigationLevel = .phases
    private(set) var phaseIndex = 0
    private(set) var agentIndex = 0

    /// Called after a value or navigation change so the owning surface can repaint.
    var onChange: (() -> Void)?
    /// Called when Escape is pressed from the top-level phase list.
    var onExit: (() -> Void)?

    private let keybindings = Keybindings()

    init(phases: [WorkflowWorkspacePhase]) {
        self.phases = phases
    }

    var selectedPhase: WorkflowWorkspacePhase? {
        guard phases.indices.contains(phaseIndex) else { return nil }
        return phases[phaseIndex]
    }

    var selectedAgent: WorkflowWorkspaceAgent? {
        guard let phase = selectedPhase, phase.agents.indices.contains(agentIndex) else { return nil }
        return phase.agents[agentIndex]
    }

    /// Replace the value snapshot while keeping the user's current location when
    /// possible. This is the seam for live workflow/run updates.
    func setPhases(_ phases: [WorkflowWorkspacePhase]) {
        self.phases = phases
        phaseIndex = min(phaseIndex, max(0, phases.count - 1))
        let agentCount = selectedPhase?.agents.count ?? 0
        agentIndex = min(agentIndex, max(0, agentCount - 1))
        onChange?()
    }

    /// Select a phase before mounting the workspace, used by `/research`,
    /// `/plan`, `/execute`, and `/synthesize` shortcuts.
    func selectPhase(id: String) {
        guard let index = phases.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            return
        }
        phaseIndex = index
        agentIndex = 0
    }

    /// Build the dedicated two-pane root for the current terminal width.
    func layout(width: Int) -> any LayoutNode {
        let leftWidth: Int
        if width <= 0 {
            leftWidth = 0
        } else {
            leftWidth = min(width, min(36, max(18, width / 4)))
        }

        let navigation = WorkflowNavigationPane(controller: self)
        let content = WorkflowContentPane(controller: self)
        var children: [any LayoutNode] = [Fixed(.absolute(leftWidth), navigation.layout)]
        if leftWidth < width {
            children.append(Fixed(.absolute(1), WorkflowDividerPane().layout))
        }
        children.append(Flexible(1, content.layout))
        return Row(children)
    }

    func render(width: Int) -> [String] {
        WorkflowContentPane(controller: self).render(width: width)
    }

    func handleInput(_ data: [UInt8]) {
        if keybindings.matches(data, .selectUp) || data == [0x6b] {
            moveSelection(by: -1)
        } else if keybindings.matches(data, .selectDown) || data == [0x6a] {
            moveSelection(by: 1)
        } else if keybindings.matches(data, .selectConfirm) {
            confirmSelection()
        } else if keybindings.matches(data, .selectCancel) {
            navigateBack()
        }
    }

    private func moveSelection(by delta: Int) {
        switch level {
        case .phases:
            phaseIndex = movedIndex(phaseIndex, delta: delta, count: phases.count)
        case .agents, .agentContent:
            agentIndex = movedIndex(agentIndex, delta: delta, count: selectedPhase?.agents.count ?? 0)
        }
        onChange?()
    }

    private func confirmSelection() {
        switch level {
        case .phases:
            guard selectedPhase != nil else { return }
            agentIndex = 0
            level = .agents
        case .agents:
            guard selectedAgent != nil else { return }
            level = .agentContent
        case .agentContent:
            // Enter is intentionally idempotent here. A live agent may continue
            // streaming while its content remains selected; re-entering must not
            // start a second task or move the user away from the transcript.
            break
        }
        onChange?()
    }

    private func navigateBack() {
        switch level {
        case .phases:
            onExit?()
        case .agents:
            level = .phases
            onChange?()
        case .agentContent:
            level = .agents
            onChange?()
        }
    }

    private func movedIndex(_ current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, current + delta), count - 1)
    }
}

@MainActor
private final class WorkflowNavigationPane: Component {
    let controller: WorkflowWorkspaceController

    init(controller: WorkflowWorkspaceController) {
        self.controller = controller
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines = [truncateToWidth(
            "\u{1b}[1m" + (controller.level == .phases ? "Phases" : "Agents") + sgrReset,
            width,
            ellipsis: ""
        )]

        if controller.level == .phases {
            lines.append(truncateToWidth(dim("Enter open · Esc close"), width, ellipsis: ""))
            lines.append(String(repeating: "─", count: width))
            if controller.phases.isEmpty {
                lines.append(truncateToWidth(dim("  (none)"), width, ellipsis: ""))
            } else {
                for (index, phase) in controller.phases.enumerated() {
                    lines.append(row(
                        marker: index == controller.phaseIndex ? "›" : " ",
                        status: phase.status,
                        title: phase.title,
                        selected: index == controller.phaseIndex,
                        width: width
                    ))
                }
            }
        } else {
            let phaseTitle = controller.selectedPhase?.title ?? "phase"
            lines.append(truncateToWidth(dim("Phase: " + sanitizeUntrustedText(phaseTitle)), width, ellipsis: ""))
            lines.append(truncateToWidth(dim("↑/↓ choose · Enter open · Esc back"), width, ellipsis: ""))
            lines.append(String(repeating: "─", count: width))
            let agents = controller.selectedPhase?.agents ?? []
            if agents.isEmpty {
                lines.append(truncateToWidth(dim("  (waiting for agents…)"), width, ellipsis: ""))
            } else {
                for (index, agent) in agents.enumerated() {
                    lines.append(row(
                        marker: index == controller.agentIndex ? "›" : " ",
                        status: agent.status,
                        title: agent.title,
                        selected: index == controller.agentIndex,
                        width: width
                    ))
                }
            }
        }
        return lines
    }

    private func row(
        marker: String,
        status: WorkflowStageRunStatus,
        title: String,
        selected: Bool,
        width: Int
    ) -> String {
        let value = "(marker) (WorkflowStatusGlyph.value(for: status)) (sanitizeUntrustedText(title))"
        let clipped = truncateToWidth(value, width, ellipsis: "", pad: true)
        return selected && controller.focused ? inverse(clipped) : clipped
    }
}

@MainActor
private final class WorkflowContentPane: Component {
    let controller: WorkflowWorkspaceController

    init(controller: WorkflowWorkspaceController) {
        self.controller = controller
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        let phase = controller.selectedPhase
        var lines: [String] = []
        switch controller.level {
        case .phases:
            lines.append(truncateToWidth("\u{1b}[1mWorkflow workspace\u{1b}[0m", width, ellipsis: ""))
            lines.append(truncateToWidth(dim("Select a phase to inspect its agents."), width, ellipsis: ""))
            if let phase {
                appendPhase(phase, to: &lines, width: width)
            }
        case .agents:
            lines.append(truncateToWidth(
                "\u{1b}[1m" + sanitizeUntrustedText(phase?.title ?? "Workflow phase") + sgrReset,
                width,
                ellipsis: ""
            ))
            lines.append(truncateToWidth(dim("Select an agent to follow its running content."), width, ellipsis: ""))
            if let phase {
                appendPhase(phase, to: &lines, width: width)
            }
        case .agentContent:
            guard let agent = controller.selectedAgent else {
                return [truncateToWidth(dim("Agent is no longer available."), width, ellipsis: "")]
            }
            lines.append(truncateToWidth(
                "\u{1b}[1m" + sanitizeUntrustedText(agent.title) + sgrReset
                    + "  " + WorkflowStatusGlyph.value(for: agent.status),
                width,
                ellipsis: ""
            ))
            lines.append(truncateToWidth(
                dim("Phase: " + sanitizeUntrustedText(phase?.title ?? "unknown") + " · Esc back"),
                width,
                ellipsis: ""
            ))
            lines.append(String(repeating: "─", count: width))
            let content = sanitizeUntrustedText(agent.content)
            if content.isEmpty {
                lines.append(truncateToWidth(dim("Waiting for agent output…"), width, ellipsis: ""))
            } else {
                lines.append(contentsOf: wrapToWidth(content, width: width).map {
                    truncateToWidth($0, width, ellipsis: "")
                })
            }
        }
        return lines
    }

    private func appendPhase(
        _ phase: WorkflowWorkspacePhase,
        to lines: inout [String],
        width: Int
    ) {
        lines.append(truncateToWidth(
            "status: (WorkflowStatusGlyph.value(for: phase.status)) (phase.status.rawValue)",
            width,
            ellipsis: ""
        ))
        let summary = sanitizeUntrustedText(phase.summary)
        if !summary.isEmpty {
            lines.append(contentsOf: wrapToWidth(summary, width: width).map {
                truncateToWidth($0, width, ellipsis: "")
            })
        }
    }
}

@MainActor
private final class WorkflowDividerPane: Component {
    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return ["│"]
    }
}

private enum WorkflowStatusGlyph {
    static func value(for status: WorkflowStageRunStatus) -> String {
        switch status {
        case .pending: return "·"
        case .ready: return "◇"
        case .waitingForApproval: return "⏳"
        case .running: return "●"
        case .succeeded: return "✓"
        case .failed: return "✗"
        case .cancelled: return "×"
        case .skipped: return "–"
        }
    }
}
