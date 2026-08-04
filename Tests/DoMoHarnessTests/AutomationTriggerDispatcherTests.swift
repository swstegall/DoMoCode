// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import Testing

@Suite("Automation trigger dispatcher", .serialized)
struct AutomationTriggerDispatcherTests {
    @Test("a validated filesystem event becomes a bounded durable job")
    func dispatchesFilesystemEvent() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        _ = try await registry.register(definition(trigger: AutomationTrigger(
            kind: .filesystem,
            path: "/tmp/project"
        )))
        _ = try await registry.setEnabled(id: "automation", owner: "owner", enabled: true)
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(registry: registry, jobs: jobs)
        let dispatcher = AutomationTriggerDispatcher(registry: registry, coordinator: coordinator)

        let result = try await dispatcher.dispatch(AutomationTriggerRequest(
            automationID: "automation",
            kind: .filesystem,
            requestedBy: "owner",
            createdAt: "2026-01-01T00:00:00Z",
            path: "/tmp/project/Sources/App.swift"
        )) { _ in
            JobResult(output: .string("handled"))
        }

        #expect(result.invocation.source == .filesystemTrigger)
        #expect(result.job.state == .succeeded)
        #expect(result.job.triggerSource == .filesystem)
        #expect(result.job.metadata["path"] == .string("/tmp/project/Sources/App.swift"))
    }

    @Test("a mismatched trigger is refused before job admission")
    func refusesMismatchedEvent() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        _ = try await registry.register(definition(trigger: AutomationTrigger(
            kind: .repository,
            branch: "main"
        )))
        _ = try await registry.setEnabled(id: "automation", owner: "owner", enabled: true)
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(registry: registry, jobs: jobs)
        let dispatcher = AutomationTriggerDispatcher(registry: registry, coordinator: coordinator)

        await #expect(throws: AutomationTriggerDispatchError.invalidEvent(
            "Repository branch does not match the registered trigger."
        )) {
            _ = try await dispatcher.dispatch(AutomationTriggerRequest(
                automationID: "automation",
                kind: .repository,
                requestedBy: "owner",
                createdAt: "2026-01-01T00:00:00Z",
                branch: "feature"
            )) { _ in
                Issue.record("A mismatched trigger must not run its operation")
                return JobResult(output: .null)
            }
        }
        #expect(try await jobs.list(owner: "owner").isEmpty)
    }

    @Test("webhook dispatch requires the registered identity and authentication")
    func validatesWebhook() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        _ = try await registry.register(definition(trigger: AutomationTrigger(
            kind: .webhook,
            webhookID: "hook",
            authenticated: true
        )))
        _ = try await registry.setEnabled(id: "automation", owner: "owner", enabled: true)
        let jobs = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        let coordinator = AutomationJobCoordinator(registry: registry, jobs: jobs)
        let dispatcher = AutomationTriggerDispatcher(registry: registry, coordinator: coordinator)

        await #expect(throws: AutomationTriggerDispatchError.invalidEvent(
            "Webhook identity or authentication is invalid."
        )) {
            _ = try await dispatcher.dispatch(AutomationTriggerRequest(
                automationID: "automation",
                kind: .webhook,
                requestedBy: "owner",
                createdAt: "2026-01-01T00:00:00Z",
                webhookID: "hook",
                authenticated: false
            )) { _ in
                JobResult(output: .null)
            }
        }
    }

    private func definition(trigger: AutomationTrigger) -> AutomationDefinition {
        AutomationDefinition(
            id: "automation",
            displayName: "Automation",
            owner: "owner",
            profileID: "profile",
            workspaceRoot: "/tmp/project",
            sandboxPolicyID: "sandbox",
            trigger: trigger,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }
}
