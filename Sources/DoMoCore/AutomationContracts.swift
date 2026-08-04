// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

/// The trigger declaration an automation adapter may later implement.
public enum AutomationTriggerKind: String, Sendable, Codable, Hashable, CaseIterable {
    case manual
    case cli
    case schedule
    case filesystem
    case repository
    case webhook
}

/// The source recorded for one invocation. This is intentionally more precise
/// than AutomationTriggerKind: a child-agent result and a user prompt may
/// both enter through the same automation profile, but they are not the same
/// audit event.
public enum AutomationInvocationSource: String, Sendable, Codable, Hashable, CaseIterable {
    case userPrompt
    case cli
    case scheduledTrigger
    case filesystemTrigger
    case repositoryTrigger
    case authenticatedWebhook
    case childAgentResult
}

public enum AutomationCancellationPolicy: String, Sendable, Codable, Hashable, CaseIterable {
    case cooperative
    case deadline
    case parentCancellation
}

/// Hard bounds an adapter must pass to the durable job manager. Values are
/// integers so a remote client cannot smuggle an unbounded floating-point
/// budget through a JSON number.
public struct AutomationBudget: Sendable, Codable, Hashable {
    public var maxRuntimeMilliseconds: Int
    public var maxAttempts: Int
    public var maxOutputBytes: Int
    public var maxCostMicros: Int?

    public init(
        maxRuntimeMilliseconds: Int = 300_000,
        maxAttempts: Int = 1,
        maxOutputBytes: Int = 1 << 20,
        maxCostMicros: Int? = nil
    ) {
        self.maxRuntimeMilliseconds = max(1, maxRuntimeMilliseconds)
        self.maxAttempts = max(1, maxAttempts)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.maxCostMicros = maxCostMicros.map { max(0, $0) }
    }
}

/// Secret scope contains references and environment names only. It never
/// carries credential values or permits inheriting the host environment by
/// accident.
public struct AutomationSecretScope: Sendable, Codable, Hashable {
    public var credentialReferences: [String]
    public var environmentNames: [String]
    public var allowInheritedEnvironment: Bool

    public init(
        credentialReferences: [String] = [],
        environmentNames: [String] = [],
        allowInheritedEnvironment: Bool = false
    ) {
        self.credentialReferences = credentialReferences.sorted()
        self.environmentNames = environmentNames.sorted()
        self.allowInheritedEnvironment = allowInheritedEnvironment
    }
}

/// Configuration for one trigger. Trigger-specific fields stay optional so
/// the adapter can report a typed validation error instead of decoding several
/// unrelated wire shapes.
public struct AutomationTrigger: Sendable, Codable, Hashable {
    public var kind: AutomationTriggerKind
    public var expression: String?
    public var path: String?
    public var branch: String?
    public var webhookID: String?
    public var authenticated: Bool

    public init(
        kind: AutomationTriggerKind,
        expression: String? = nil,
        path: String? = nil,
        branch: String? = nil,
        webhookID: String? = nil,
        authenticated: Bool = false
    ) {
        self.kind = kind
        self.expression = expression
        self.path = path
        self.branch = branch
        self.webhookID = webhookID
        self.authenticated = authenticated
    }
}

/// A disabled-by-default automation definition. The registry records policy;
/// a scheduler, filesystem watcher, or webhook adapter must still be explicit
/// about when it creates a job.
public struct AutomationDefinition: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var owner: String
    public var profileID: String
    public var workspaceRoot: String
    public var sandboxPolicyID: String
    public var backendID: String?
    public var providerID: String?
    public var trigger: AutomationTrigger
    public var budget: AutomationBudget
    public var secretScope: AutomationSecretScope
    public var cancellationPolicy: AutomationCancellationPolicy
    public var enabled: Bool
    public var createdAt: String
    public var updatedAt: String
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        displayName: String,
        owner: String,
        profileID: String,
        workspaceRoot: String,
        sandboxPolicyID: String,
        backendID: String? = nil,
        providerID: String? = nil,
        trigger: AutomationTrigger,
        budget: AutomationBudget = .init(),
        secretScope: AutomationSecretScope = .init(),
        cancellationPolicy: AutomationCancellationPolicy = .cooperative,
        enabled: Bool = false,
        createdAt: String,
        updatedAt: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.profileID = profileID
        self.workspaceRoot = workspaceRoot
        self.sandboxPolicyID = sandboxPolicyID
        self.backendID = backendID
        self.providerID = providerID
        self.trigger = trigger
        self.budget = budget
        self.secretScope = secretScope
        self.cancellationPolicy = cancellationPolicy
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.metadata = metadata
    }
}

/// An invocation is an audit input to the registry, not an instruction to
/// execute. jobID is optional at admission and can be filled by the caller
/// after a JobManager accepts the bounded operation.
public struct AutomationInvocation: Sendable, Codable, Hashable {
    public var id: String
    public var automationID: String
    public var source: AutomationInvocationSource
    public var requestedBy: String
    public var sessionID: String?
    public var jobID: String?
    public var createdAt: String
    public var input: JSONValue
    public var metadata: [String: JSONValue]

    public init(
        id: String = UUIDv7.generate().description,
        automationID: String,
        source: AutomationInvocationSource,
        requestedBy: String,
        sessionID: String? = nil,
        jobID: String? = nil,
        createdAt: String,
        input: JSONValue = .null,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.automationID = automationID
        self.source = source
        self.requestedBy = requestedBy
        self.sessionID = sessionID
        self.jobID = jobID
        self.createdAt = createdAt
        self.input = input
        self.metadata = metadata
    }
}

public enum AutomationAuditKind: String, Sendable, Codable, Hashable {
    case registered
    case enabled
    case disabled
    case invoked
}

public struct AutomationAuditEvent: Sendable, Codable, Hashable {
    public let sequence: Int
    public let automationID: String
    public let timestamp: String
    public let kind: AutomationAuditKind
    public let enabled: Bool
    public let invocationID: String?
    public let message: String?
    public let metadata: [String: JSONValue]

    public init(
        sequence: Int,
        automationID: String,
        timestamp: String,
        kind: AutomationAuditKind,
        enabled: Bool,
        invocationID: String? = nil,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.sequence = sequence
        self.automationID = automationID
        self.timestamp = timestamp
        self.kind = kind
        self.enabled = enabled
        self.invocationID = invocationID
        self.message = message
        self.metadata = metadata
    }
}

public struct AutomationJournalEntry: Sendable, Codable, Hashable {
    public let event: AutomationAuditEvent
    public let definition: AutomationDefinition
    public let invocation: AutomationInvocation?

    public init(
        event: AutomationAuditEvent,
        definition: AutomationDefinition,
        invocation: AutomationInvocation? = nil
    ) {
        self.event = event
        self.definition = definition
        self.invocation = invocation
    }
}

/// Append-only policy and audit storage. The registry is the concurrency
/// boundary; this value type does not pretend to coordinate multiple writers.
public struct AutomationStore: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    public init(path: FilePath, permissions: FilePermissions = .ownerReadWrite) {
        self.path = path
        self.permissions = permissions
    }

    public static func create(
        directory: FilePath,
        fileName: String = "automations.jsonl",
        permissions: FilePermissions = .ownerReadWrite
    ) throws -> AutomationStore {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let store = AutomationStore(path: directory.appending(fileName), permissions: permissions)
        if !FileManager.default.fileExists(atPath: store.path.string) {
            try JSONLinesFileWriter(path: store.path, permissions: permissions)
                .replaceContents(with: [AutomationJournalEntry]())
        }
        return store
    }

    public func append(_ entry: AutomationJournalEntry) throws {
        try JSONLinesFileWriter(path: path, permissions: permissions).append(entry)
    }

    public func records() throws -> [AutomationJournalEntry] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        return try JSONLines.decode(
            AutomationJournalEntry.self,
            contentsOf: path,
            options: .strict
        )
    }

    public func latest() throws -> [String: AutomationDefinition] {
        var result: [String: AutomationDefinition] = [:]
        for entry in try records() { result[entry.definition.id] = entry.definition }
        return result
    }

    public func events(after sequence: Int = 0, automationID: String? = nil) throws -> [AutomationAuditEvent] {
        try records()
            .map(\.event)
            .filter {
                $0.sequence > sequence
                    && (automationID == nil || $0.automationID == automationID)
            }
            .sorted { $0.sequence < $1.sequence }
    }

    public func export(automationID: String) throws -> [AutomationJournalEntry] {
        try records().filter { $0.definition.id == automationID }
    }
}

public enum AutomationRegistryError: Error, Sendable, Equatable {
    case invalidDefinition(String)
    case duplicate(String)
    case notFound(String)
    case ownershipDenied(String)
    case disabled(String)
    case triggerMismatch(automationID: String, source: AutomationInvocationSource)
    case invalidCursor(Int)
}

/// Validates and journals automation policy. It deliberately stops before
/// scheduling, filesystem access, webhook handling, or process launch.
public actor AutomationRegistry {
    private let store: AutomationStore?
    private let now: @Sendable () -> String

    private var loaded = false
    private var nextSequence = 0
    private var definitions: [String: AutomationDefinition] = [:]
    private var eventsLog: [AutomationAuditEvent] = []
    private var invocationsLog: [AutomationInvocation] = []

    public init(
        store: AutomationStore? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.store = store
        self.now = now
    }

    public func register(_ definition: AutomationDefinition) throws -> AutomationDefinition {
        try loadIfNeeded()
        try validate(definition)
        guard definitions[definition.id] == nil else {
            throw AutomationRegistryError.duplicate(definition.id)
        }
        _ = try append(
            definition: definition,
            kind: .registered,
            message: "Automation registered."
        )
        return definition
    }

    public func definition(id: String) throws -> AutomationDefinition? {
        try loadIfNeeded()
        return definitions[id]
    }

    public func list(owner: String? = nil) throws -> [AutomationDefinition] {
        try loadIfNeeded()
        return definitions.values
            .filter { owner == nil || $0.owner == owner }
            .sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt < rhs.updatedAt
            }
    }

    public func setEnabled(id: String, owner: String, enabled: Bool) throws -> AutomationDefinition {
        try loadIfNeeded()
        guard var definition = definitions[id] else {
            throw AutomationRegistryError.notFound(id)
        }
        guard definition.owner == owner else {
            throw AutomationRegistryError.ownershipDenied(id)
        }
        definition.enabled = enabled
        definition.updatedAt = now()
        _ = try append(
            definition: definition,
            kind: enabled ? .enabled : .disabled,
            message: enabled ? "Automation enabled." : "Automation disabled."
        )
        return definition
    }

    public func invoke(_ invocation: AutomationInvocation) throws -> AutomationInvocation {
        try loadIfNeeded()
        guard let definition = definitions[invocation.automationID] else {
            throw AutomationRegistryError.notFound(invocation.automationID)
        }
        guard definition.owner == invocation.requestedBy else {
            throw AutomationRegistryError.ownershipDenied(definition.id)
        }
        guard definition.enabled else {
            throw AutomationRegistryError.disabled(definition.id)
        }
        try validate(invocation)
        guard sourceMatches(invocation.source, trigger: definition.trigger) else {
            throw AutomationRegistryError.triggerMismatch(
                automationID: definition.id,
                source: invocation.source
            )
        }
        _ = try append(
            definition: definition,
            kind: .invoked,
            message: "Automation invocation admitted to the audit log.",
            invocation: invocation
        )
        invocationsLog.append(invocation)
        return invocation
    }

    public func events(after sequence: Int = 0, automationID: String? = nil) throws -> [AutomationAuditEvent] {
        try loadIfNeeded()
        guard sequence >= 0 else { throw AutomationRegistryError.invalidCursor(sequence) }
        return eventsLog.filter {
            $0.sequence > sequence
                && (automationID == nil || $0.automationID == automationID)
        }
    }

    public func invocations(automationID: String? = nil) throws -> [AutomationInvocation] {
        try loadIfNeeded()
        return invocationsLog.filter {
            automationID == nil || $0.automationID == automationID
        }
    }

    public func export(id: String) throws -> [AutomationJournalEntry] {
        try loadIfNeeded()
        guard definitions[id] != nil else { throw AutomationRegistryError.notFound(id) }
        if let store { return try store.export(automationID: id) }
        return eventsLog.compactMap { event in
            guard event.automationID == id, let definition = definitions[id] else { return nil }
            let invocation = event.invocationID.flatMap { invocationID in
                invocationsLog.last { $0.id == invocationID }
            }
            return AutomationJournalEntry(
                event: event,
                definition: definition,
                invocation: invocation
            )
        }
    }

    private func validate(_ definition: AutomationDefinition) throws {
        let fields: [(String, String)] = [
            ("id", definition.id),
            ("displayName", definition.displayName),
            ("owner", definition.owner),
            ("profileID", definition.profileID),
            ("workspaceRoot", definition.workspaceRoot),
            ("sandboxPolicyID", definition.sandboxPolicyID),
            ("createdAt", definition.createdAt),
        ]
        for (name, value) in fields where Self.isBlank(value) {
            throw AutomationRegistryError.invalidDefinition("\(name) must not be empty.")
        }
        guard definition.budget.maxRuntimeMilliseconds > 0,
              definition.budget.maxAttempts > 0,
              definition.budget.maxOutputBytes > 0
        else {
            throw AutomationRegistryError.invalidDefinition("Automation budgets must be positive.")
        }
        if let maxCost = definition.budget.maxCostMicros, maxCost < 0 {
            throw AutomationRegistryError.invalidDefinition("Automation maxCostMicros must not be negative.")
        }
        try validateSecretScope(definition.secretScope)
        try validateTrigger(definition.trigger)
    }

    private func validate(_ invocation: AutomationInvocation) throws {
        let fields: [(String, String)] = [
            ("id", invocation.id),
            ("automationID", invocation.automationID),
            ("requestedBy", invocation.requestedBy),
            ("createdAt", invocation.createdAt),
        ]
        for (name, value) in fields where Self.isBlank(value) {
            throw AutomationRegistryError.invalidDefinition("Invocation \(name) must not be empty.")
        }
    }

    private func validateTrigger(_ trigger: AutomationTrigger) throws {
        switch trigger.kind {
        case .manual, .cli:
            break
        case .schedule:
            guard let expression = trigger.expression, !Self.isBlank(expression) else {
                throw AutomationRegistryError.invalidDefinition(
                    "Schedule triggers require a non-empty expression."
                )
            }
        case .filesystem:
            guard let path = trigger.path, !Self.isBlank(path), !path.contains("\0") else {
                throw AutomationRegistryError.invalidDefinition(
                    "Filesystem triggers require a safe path."
                )
            }
        case .repository:
            guard let branch = trigger.branch, !Self.isBlank(branch) else {
                throw AutomationRegistryError.invalidDefinition(
                    "Repository triggers require a branch."
                )
            }
        case .webhook:
            guard let webhookID = trigger.webhookID, !Self.isBlank(webhookID),
                  trigger.authenticated
            else {
                throw AutomationRegistryError.invalidDefinition(
                    "Webhook triggers require an authenticated webhook id."
                )
            }
        }
    }

    private func validateSecretScope(_ scope: AutomationSecretScope) throws {
        var values: Set<String> = []
        for value in scope.credentialReferences + scope.environmentNames {
            guard !Self.isBlank(value), !value.contains("="), !value.contains("\0") else {
                throw AutomationRegistryError.invalidDefinition(
                    "Secret scope contains an invalid name or a credential value."
                )
            }
            guard values.insert(value).inserted else {
                throw AutomationRegistryError.invalidDefinition(
                    "Secret scope names must be unique."
                )
            }
        }
        guard !scope.allowInheritedEnvironment else {
            throw AutomationRegistryError.invalidDefinition(
                "Automation secret scope cannot inherit the host environment."
            )
        }
    }

    private func sourceMatches(
        _ source: AutomationInvocationSource,
        trigger: AutomationTrigger
    ) -> Bool {
        switch (trigger.kind, source) {
        case (.manual, .userPrompt), (.manual, .childAgentResult), (.cli, .cli),
             (.schedule, .scheduledTrigger), (.filesystem, .filesystemTrigger),
             (.repository, .repositoryTrigger), (.webhook, .authenticatedWebhook):
            true
        default:
            false
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if let store {
            for row in try store.records() {
                guard row.event.sequence > nextSequence else {
                    throw AutomationRegistryError.invalidCursor(row.event.sequence)
                }
                nextSequence = row.event.sequence
                definitions[row.definition.id] = row.definition
                eventsLog.append(row.event)
                if let invocation = row.invocation {
                    invocationsLog.append(invocation)
                }
            }
        }
        loaded = true
    }

    @discardableResult
    private func append(
        definition: AutomationDefinition,
        kind: AutomationAuditKind,
        message: String,
        invocation: AutomationInvocation? = nil
    ) throws -> AutomationAuditEvent {
        nextSequence += 1
        let event = AutomationAuditEvent(
            sequence: nextSequence,
            automationID: definition.id,
            timestamp: definition.updatedAt,
            kind: kind,
            enabled: definition.enabled,
            invocationID: invocation?.id,
            message: message,
            metadata: [
                "triggerKind": .string(definition.trigger.kind.rawValue),
                "profileID": .string(definition.profileID),
                "sandboxPolicyID": .string(definition.sandboxPolicyID),
            ]
        )
        if let store {
            do {
                try store.append(AutomationJournalEntry(
                    event: event,
                    definition: definition,
                    invocation: invocation
                ))
            } catch {
                nextSequence -= 1
                throw error
            }
        }
        definitions[definition.id] = definition
        eventsLog.append(event)
        return event
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
