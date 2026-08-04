// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

/// An event emitted by a concrete local adapter. It carries trigger facts,
/// never a command or credential. The dispatcher compares those facts with the
/// registered definition before it constructs an invocation.
public struct AutomationTriggerRequest: Sendable, Codable, Hashable {
    public var automationID: String
    public var kind: AutomationTriggerRequestKind
    public var requestedBy: String
    public var sessionID: String?
    public var jobID: String?
    public var createdAt: String
    public var input: JSONValue
    public var metadata: [String: JSONValue]
    public var expression: String?
    public var path: String?
    public var branch: String?
    public var webhookID: String?
    public var authenticated: Bool

    public init(
        automationID: String,
        kind: AutomationTriggerRequestKind,
        requestedBy: String,
        sessionID: String? = nil,
        jobID: String? = nil,
        createdAt: String,
        input: JSONValue = .null,
        metadata: [String: JSONValue] = [:],
        expression: String? = nil,
        path: String? = nil,
        branch: String? = nil,
        webhookID: String? = nil,
        authenticated: Bool = false
    ) {
        self.automationID = automationID
        self.kind = kind
        self.requestedBy = requestedBy
        self.sessionID = sessionID
        self.jobID = jobID
        self.createdAt = createdAt
        self.input = input
        self.metadata = metadata
        self.expression = expression
        self.path = path
        self.branch = branch
        self.webhookID = webhookID
        self.authenticated = authenticated
    }
}

public enum AutomationTriggerRequestKind: String, Sendable, Codable, Hashable, CaseIterable {
    case manual
    case cli
    case schedule
    case filesystem
    case repository
    case webhook
    case childAgentResult
}

public enum AutomationTriggerDispatchError: Error, Sendable, Equatable {
    case invalidEvent(String)
}

/// Converts concrete trigger facts into a policy-checked invocation and then
/// hands it to ``AutomationJobCoordinator``. No watcher, scheduler, webhook
/// listener, or process is started by this type; each adapter must call this
/// explicit seam with a trusted bounded operation.
public actor AutomationTriggerDispatcher {
    private let registry: AutomationRegistry
    private let coordinator: AutomationJobCoordinator

    public init(
        registry: AutomationRegistry,
        coordinator: AutomationJobCoordinator
    ) {
        self.registry = registry
        self.coordinator = coordinator
    }

    public func dispatch(
        _ request: AutomationTriggerRequest,
        operation: @escaping JobOperation
    ) async throws -> AutomationExecutionResult {
        guard let definition = try await registry.definition(id: request.automationID) else {
            throw AutomationRegistryError.notFound(request.automationID)
        }
        try validate(request, definition: definition)

        let invocation = AutomationInvocation(
            automationID: request.automationID,
            source: request.kind.invocationSource,
            requestedBy: request.requestedBy,
            sessionID: request.sessionID,
            jobID: request.jobID,
            createdAt: request.createdAt,
            input: request.input,
            metadata: invocationMetadata(request, definition: definition)
        )
        return try await coordinator.execute(invocation, operation: operation)
    }

    private func validate(
        _ request: AutomationTriggerRequest,
        definition: AutomationDefinition
    ) throws(AutomationTriggerDispatchError) {
        guard request.automationID == definition.id else {
            throw .invalidEvent("Trigger automation id does not match its definition.")
        }
        switch (definition.trigger.kind, request.kind) {
        case (.manual, .manual), (.manual, .childAgentResult), (.cli, .cli):
            return
        case (.schedule, .schedule):
            guard request.expression == definition.trigger.expression else {
                throw .invalidEvent("Schedule expression does not match the registered trigger.")
            }
        case (.filesystem, .filesystem):
            guard let configured = definition.trigger.path,
                  let observed = request.path,
                  Self.path(observed, isWithin: configured)
            else {
                throw .invalidEvent("Filesystem event is outside the registered trigger path.")
            }
        case (.repository, .repository):
            guard request.branch == definition.trigger.branch else {
                throw .invalidEvent("Repository branch does not match the registered trigger.")
            }
        case (.webhook, .webhook):
            guard request.webhookID == definition.trigger.webhookID,
                  request.authenticated,
                  definition.trigger.authenticated
            else {
                throw .invalidEvent("Webhook identity or authentication is invalid.")
            }
        default:
            throw .invalidEvent("Trigger event kind does not match the registered automation.")
        }
    }

    private func invocationMetadata(
        _ request: AutomationTriggerRequest,
        definition: AutomationDefinition
    ) -> [String: JSONValue] {
        var metadata = request.metadata
        metadata["triggerKind"] = .string(definition.trigger.kind.rawValue)
        switch request.kind {
        case .schedule:
            if let expression = request.expression { metadata["expression"] = .string(expression) }
        case .filesystem:
            if let path = request.path { metadata["path"] = .string(path) }
        case .repository:
            if let branch = request.branch { metadata["branch"] = .string(branch) }
        case .manual, .cli, .webhook, .childAgentResult:
            break
        }
        return metadata
    }

    private static func path(_ observed: String, isWithin configured: String) -> Bool {
        let observedURL = URL(fileURLWithPath: observed).standardizedFileURL
        let configuredURL = URL(fileURLWithPath: configured).standardizedFileURL
        let root = configuredURL.path.hasSuffix("/") ? configuredURL.path : configuredURL.path + "/"
        return observedURL.path == configuredURL.path || observedURL.path.hasPrefix(root)
    }
}

private extension AutomationTriggerRequestKind {
    var invocationSource: AutomationInvocationSource {
        switch self {
        case .manual: .userPrompt
        case .cli: .cli
        case .schedule: .scheduledTrigger
        case .filesystem: .filesystemTrigger
        case .repository: .repositoryTrigger
        case .webhook: .authenticatedWebhook
        case .childAgentResult: .childAgentResult
        }
    }
}
