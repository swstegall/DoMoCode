import DoMoCore
import Foundation
import SystemPackage
import Testing

@Suite("Automation contracts", .serialized)
struct AutomationContractsTests {
    @Test("keeps automations disabled until explicitly enabled and journals invocation provenance")
    func enableAndInvoke() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try AutomationStore.create(directory: directory)
        let registry = AutomationRegistry(
            store: store,
            now: { "2026-01-01T00:00:00Z" }
        )
        let definition = AutomationDefinition(
            id: "automation-review",
            displayName: "Review changes",
            owner: "client-a",
            profileID: "review",
            workspaceRoot: "/workspace/project",
            sandboxPolicyID: "workspace-readonly",
            providerID: "provider-a",
            trigger: AutomationTrigger(kind: .manual),
            secretScope: AutomationSecretScope(
                credentialReferences: ["provider-a"],
                environmentNames: ["DOMOCODE_API_KEY"]
            ),
            createdAt: "2026-01-01T00:00:00Z"
        )

        let registered = try await registry.register(definition)
        #expect(!registered.enabled)
        await #expect(throws: AutomationRegistryError.disabled("automation-review")) {
            _ = try await registry.invoke(AutomationInvocation(
                id: "invocation-disabled",
                automationID: definition.id,
                source: .userPrompt,
                requestedBy: "client-a",
                createdAt: "2026-01-01T00:00:01Z"
            ))
        }

        await #expect(throws: AutomationRegistryError.ownershipDenied("automation-review")) {
            _ = try await registry.setEnabled(id: definition.id, owner: "client-b", enabled: true)
        }
        _ = try await registry.setEnabled(id: definition.id, owner: "client-a", enabled: true)
        let invocation = try await registry.invoke(AutomationInvocation(
            id: "invocation-child",
            automationID: definition.id,
            source: .childAgentResult,
            requestedBy: "client-a",
            sessionID: "session-a",
            jobID: "job-a",
            createdAt: "2026-01-01T00:00:02Z",
            input: ["result": "ready"]
        ))
        #expect(invocation.source == .childAgentResult)

        let events = try await registry.events()
        #expect(events.map(\.kind) == [.registered, .enabled, .invoked])
        #expect(events.last?.invocationID == invocation.id)
        #expect(try await registry.events(after: 1).map(\.sequence) == [2, 3])
        #expect(try await registry.invocations(automationID: definition.id) == [invocation])

        let reopened = AutomationRegistry(store: store, now: { "2026-01-01T00:00:03Z" })
        #expect(try await reopened.definition(id: definition.id)?.enabled == true)
        #expect(try await reopened.export(id: definition.id).count == 3)
    }

    @Test("requires trigger-specific configuration and an authenticated webhook")
    func validatesTriggersAndSecrets() async throws {
        let registry = AutomationRegistry()
        let base = { (trigger: AutomationTrigger, scope: AutomationSecretScope) in
            AutomationDefinition(
                id: UUID().uuidString,
                displayName: "Automation",
                owner: "owner",
                profileID: "profile",
                workspaceRoot: "/workspace",
                sandboxPolicyID: "sandbox",
                trigger: trigger,
                secretScope: scope,
                createdAt: "now"
            )
        }

        await #expect(throws: AutomationRegistryError.invalidDefinition(
            "Schedule triggers require a non-empty expression."
        )) {
            _ = try await registry.register(
                base(
                    AutomationTrigger(kind: .schedule),
                    AutomationSecretScope()
                )
            )
        }

        await #expect(throws: AutomationRegistryError.invalidDefinition(
            "Webhook triggers require an authenticated webhook id."
        )) {
            _ = try await registry.register(
                base(
                    AutomationTrigger(kind: .webhook, webhookID: "hook", authenticated: false),
                    AutomationSecretScope()
                )
            )
        }

        await #expect(throws: AutomationRegistryError.invalidDefinition(
            "Secret scope contains an invalid name or a credential value."
        )) {
            _ = try await registry.register(
                base(
                    AutomationTrigger(kind: .manual),
                    AutomationSecretScope(environmentNames: ["DOMOCODE_API_KEY=secret"])
                )
            )
        }
    }

    @Test("scheduled invocations cannot masquerade as manual or webhook events")
    func matchesTriggerSource() async throws {
        let registry = AutomationRegistry(now: { "2026-01-01T00:00:00Z" })
        let definition = AutomationDefinition(
            id: "scheduled",
            displayName: "Nightly",
            owner: "owner",
            profileID: "nightly",
            workspaceRoot: "/workspace",
            sandboxPolicyID: "sandbox",
            trigger: AutomationTrigger(kind: .schedule, expression: "0 2 * * *"),
            createdAt: "2026-01-01T00:00:00Z"
        )
        _ = try await registry.register(definition)
        _ = try await registry.setEnabled(id: definition.id, owner: definition.owner, enabled: true)

        await #expect(throws: AutomationRegistryError.triggerMismatch(
            automationID: definition.id,
            source: .userPrompt
        )) {
            _ = try await registry.invoke(AutomationInvocation(
                automationID: definition.id,
                source: .userPrompt,
                requestedBy: definition.owner,
                createdAt: "2026-01-01T00:00:01Z"
            ))
        }
        let invocation = try await registry.invoke(AutomationInvocation(
            automationID: definition.id,
            source: .scheduledTrigger,
            requestedBy: definition.owner,
            createdAt: "2026-01-01T00:00:02Z"
        ))
        #expect(invocation.source == .scheduledTrigger)
    }

    private func temporaryDirectory() -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-automations-\(UUID().uuidString)", isDirectory: true)
                .path
        )
    }
}
