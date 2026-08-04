// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// The protocol version spoken by an out-of-process extension. The transport
/// may be MCP, ACP, or another JSON-RPC adapter, but the host only admits this
/// small, versioned handshake and tool-call vocabulary.
public enum ExtensionProtocol: String, Sendable, Codable, Hashable, CaseIterable {
    case jsonRPC1 = "jsonrpc-1"
}

/// A hard resource ceiling supplied by an extension manifest and checked again
/// against the host policy before a process is started. These values are
/// limits, never requests for more host resources.
public struct ExtensionResourceLimits: Sendable, Codable, Hashable {
    public var maxRuntimeMilliseconds: Int
    public var maxOutputBytes: Int
    public var maxConcurrentRequests: Int

    public init(
        maxRuntimeMilliseconds: Int = 60_000,
        maxOutputBytes: Int = 1 << 20,
        maxConcurrentRequests: Int = 1
    ) {
        self.maxRuntimeMilliseconds = max(1, maxRuntimeMilliseconds)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func fits(within ceiling: ExtensionResourceLimits) -> Bool {
        maxRuntimeMilliseconds <= ceiling.maxRuntimeMilliseconds
            && maxOutputBytes <= ceiling.maxOutputBytes
            && maxConcurrentRequests <= ceiling.maxConcurrentRequests
    }
}

/// Data-only extension metadata. The host never interprets `arguments` as a
/// shell command: an injected transport receives the executable and argv as
/// separate fields and is responsible for starting a process without a shell.
public struct ExtensionManifest: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var version: String
    public var protocolVersion: ExtensionProtocol
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var source: AdapterSourceMetadata
    public var license: String
    public var capabilities: [String]
    public var limits: ExtensionResourceLimits

    public init(
        id: String,
        displayName: String,
        version: String,
        protocolVersion: ExtensionProtocol = .jsonRPC1,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        source: AdapterSourceMetadata,
        license: String,
        capabilities: [String] = [],
        limits: ExtensionResourceLimits = .init()
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.protocolVersion = protocolVersion
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.source = source
        self.license = license
        self.capabilities = Array(Set(capabilities)).sorted()
        self.limits = limits
    }
}

/// A user or project approval for one exact extension version and capability
/// set. Approval is deliberately separate from installation and is not inferred
/// from the manifest or from the source license.
public struct ExtensionApproval: Sendable, Codable, Hashable {
    public var extensionID: String
    public var version: String
    public var capabilities: [String]
    public var approvedAt: String

    public init(
        extensionID: String,
        version: String,
        capabilities: [String],
        approvedAt: String
    ) {
        self.extensionID = extensionID
        self.version = version
        self.capabilities = Array(Set(capabilities)).sorted()
        self.approvedAt = approvedAt
    }
}

/// Host policy is an allowlist and a ceiling. An empty capability allowlist is
/// intentional: an extension with no declared capability can still expose
/// pure computation, while every privileged capability requires an explicit
/// approval entry and a host policy grant.
public struct ExtensionHostPolicy: Sendable, Codable, Hashable {
    public var allowedLicenses: [String]
    public var allowedCapabilities: [String]
    public var limits: ExtensionResourceLimits
    public var requireApproval: Bool

    public init(
        allowedLicenses: [String] = ["MIT"],
        allowedCapabilities: [String] = [],
        limits: ExtensionResourceLimits = .init(),
        requireApproval: Bool = true
    ) {
        self.allowedLicenses = allowedLicenses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.allowedCapabilities = Array(Set(allowedCapabilities)).sorted()
        self.limits = limits
        self.requireApproval = requireApproval
    }
}

public enum ExtensionHostState: String, Sendable, Codable, Hashable, CaseIterable {
    case stopped
    case starting
    case running
    case degraded
    case failed
}

/// The JSON-RPC request/response values exchanged by a transport adapter. The
/// host owns request IDs and method names so an extension cannot smuggle an
/// arbitrary host operation through the tool-call path.
public struct ExtensionRPCRequest: Sendable, Codable, Hashable {
    public var id: String
    public var method: String
    public var params: JSONValue

    public init(id: String, method: String, params: JSONValue = .null) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ExtensionRPCError: Sendable, Codable, Hashable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ExtensionRPCResponse: Sendable, Codable, Hashable {
    public var id: String
    public var result: JSONValue?
    public var error: ExtensionRPCError?

    public init(
        id: String,
        result: JSONValue? = nil,
        error: ExtensionRPCError? = nil
    ) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// The result of the only startup request the host sends. Tool declarations
/// are data and are still filtered by the host before becoming callable.
public struct ExtensionHandshake: Sendable, Codable, Hashable {
    public var protocolVersion: ExtensionProtocol
    public var descriptor: ExtensionDescriptor
    public var tools: [ToolCatalogEntry]

    public init(
        protocolVersion: ExtensionProtocol,
        descriptor: ExtensionDescriptor,
        tools: [ToolCatalogEntry] = []
    ) {
        self.protocolVersion = protocolVersion
        self.descriptor = descriptor
        self.tools = tools
    }
}

/// Process creation and JSON-RPC framing live outside the core. A concrete
/// adapter can use Foundation.Process, a PTY, MCP, ACP, or a remote worker,
/// while the host retains the same admission and permission rules in tests and
/// in production.
public protocol DoMoExtensionTransport: Sendable {
    func start(using plan: ExtensionLaunchPlan) async throws
    func stop() async
    func request(_ request: ExtensionRPCRequest) async throws -> ExtensionRPCResponse
}

/// The validated, shell-free launch description handed to a transport.
public struct ExtensionLaunchPlan: Sendable, Codable, Hashable {
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var allowedEnvironmentNames: [String]
    public var capabilities: [String]
    public var limits: ExtensionResourceLimits

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        allowedEnvironmentNames: [String] = [],
        capabilities: [String],
        limits: ExtensionResourceLimits
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.allowedEnvironmentNames = Array(Set(allowedEnvironmentNames)).sorted()
        self.capabilities = Array(Set(capabilities)).sorted()
        self.limits = limits
    }
}

public struct ExtensionHostSnapshot: Sendable, Codable, Hashable {
    public var manifest: ExtensionManifest
    public var state: ExtensionHostState
    public var tools: [ToolCatalogEntry]
    public var activeRequests: Int
    public var lastError: String?

    public init(
        manifest: ExtensionManifest,
        state: ExtensionHostState,
        tools: [ToolCatalogEntry] = [],
        activeRequests: Int = 0,
        lastError: String? = nil
    ) {
        self.manifest = manifest
        self.state = state
        self.tools = tools
        self.activeRequests = activeRequests
        self.lastError = lastError
    }
}

public enum ExtensionHostError: Error, Sendable, Equatable {
    case invalidManifest(String)
    case licenseDenied(String)
    case capabilityDenied(String)
    case notApproved(String)
    case limitsExceeded
    case invalidState(ExtensionHostState)
    case protocolMismatch(ExtensionProtocol)
    case protocolError(String)
    case duplicateTool(String)
    case unknownTool(String)
    case tooManyRequests
    case outputTooLarge
    case transport(String)
}

/// Permissioned host for one out-of-process extension. It never loads a Swift
/// module or executes an extension closure in the DoMoCode process. The
/// transport is the only object allowed to cross the process boundary.
public actor ExtensionHost {
    public let manifest: ExtensionManifest

    private let transport: any DoMoExtensionTransport
    private let policy: ExtensionHostPolicy
    private var state: ExtensionHostState = .stopped
    private var tools: [String: ToolCatalogEntry] = [:]
    private var activeRequests = 0
    private var lastError: String?

    public init(
        manifest: ExtensionManifest,
        transport: any DoMoExtensionTransport,
        policy: ExtensionHostPolicy = .init()
    ) throws(ExtensionHostError) {
        try Self.validateManifest(manifest)
        self.manifest = manifest
        self.transport = transport
        self.policy = policy
    }

    public func snapshot() -> ExtensionHostSnapshot {
        ExtensionHostSnapshot(
            manifest: manifest,
            state: state,
            tools: tools.values.sorted { $0.name < $1.name },
            activeRequests: activeRequests,
            lastError: lastError
        )
    }

    /// Validate policy and approval before starting the child. The approval is
    /// version-bound, so replacing a binary under the same ID cannot inherit a
    /// previous approval accidentally.
    public func start(approval: ExtensionApproval? = nil) async throws(ExtensionHostError) {
        guard state == .stopped || state == .failed else {
            throw .invalidState(state)
        }
        // Admission is deliberately outside the transport failure boundary:
        // an unapproved or policy-denied extension was never started and must
        // remain truthfully stopped rather than looking like a failed process.
        let plan = try admissionPlan(approval: approval)
        do {
            state = .starting
            try await transport.start(using: plan)
            let response = try await transport.request(
                ExtensionRPCRequest(id: UUIDv7.generate().description, method: "initialize")
            )
            let handshake = try handshake(from: response)
            guard handshake.protocolVersion == manifest.protocolVersion else {
                throw ExtensionHostError.protocolMismatch(handshake.protocolVersion)
            }
            var admitted: [String: ToolCatalogEntry] = [:]
            for tool in handshake.tools {
                let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw .protocolError("Extension returned a tool without a name.") }
                guard admitted[name] == nil else { throw .duplicateTool(name) }
                admitted[name] = ToolCatalogEntry(
                    name: name,
                    description: tool.description,
                    source: .extensionProvider,
                    inputSchema: tool.inputSchema,
                    permission: tool.permission == .denied ? .denied : .allowed,
                    hiddenReason: tool.hiddenReason,
                    metadata: tool.metadata
                )
            }
            tools = admitted
            state = .running
            lastError = nil
        } catch let error as ExtensionHostError {
            await transport.stop()
            state = .failed
            lastError = String(describing: error)
            throw error
        } catch {
            await transport.stop()
            state = .failed
            let message = Redaction.diagnostic(String(describing: error))
            lastError = message
            throw .transport(message)
        }
    }

    public func stop() async {
        await transport.stop()
        state = .stopped
        tools = [:]
        activeRequests = 0
    }

    public func catalogEntries() throws(ExtensionHostError) -> [ToolCatalogEntry] {
        guard state == .running else { throw .invalidState(state) }
        return tools.values.sorted { $0.name < $1.name }
    }

    /// Invoke only a tool advertised by the admitted handshake. The request is
    /// bounded before it reaches the transport and the JSON result is measured
    /// before it is returned to the caller.
    public func invoke(toolNamed name: String, arguments: JSONValue) async throws(ExtensionHostError) -> JSONValue {
        guard state == .running else { throw .invalidState(state) }
        guard let tool = tools[name], tool.permission == .allowed else {
            throw .unknownTool(name)
        }
        guard activeRequests < manifest.limits.maxConcurrentRequests else {
            throw .tooManyRequests
        }

        activeRequests += 1
        defer { activeRequests -= 1 }
        let request = ExtensionRPCRequest(
            id: UUIDv7.generate().description,
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments,
            ])
        )
        do {
            let response = try await transport.request(request)
            if let error = response.error {
                throw ExtensionHostError.protocolError("(error.code): (error.message)")
            }
            guard let result = response.result else {
                throw ExtensionHostError.protocolError("Extension returned no tool result.")
            }
            let bytes = try JSONEncoder().encode(result).count
            guard bytes <= manifest.limits.maxOutputBytes else { throw .outputTooLarge }
            return result
        } catch let error as ExtensionHostError {
            throw error
        } catch {
            throw .transport(Redaction.diagnostic(String(describing: error)))
        }
    }

    private func admissionPlan(approval: ExtensionApproval?) throws(ExtensionHostError) -> ExtensionLaunchPlan {
        guard policy.allowedLicenses.contains(where: { $0.caseInsensitiveCompare(manifest.license) == .orderedSame }) else {
            throw .licenseDenied(manifest.license)
        }
        let declared = Set(manifest.capabilities)
        guard declared.isSubset(of: Set(policy.allowedCapabilities)) else {
            let denied = declared.subtracting(policy.allowedCapabilities).sorted().first ?? "unknown"
            throw .capabilityDenied(denied)
        }
        if policy.requireApproval {
            guard let approval,
                  approval.extensionID == manifest.id,
                  approval.version == manifest.version,
                  declared.isSubset(of: Set(approval.capabilities))
            else { throw .notApproved(manifest.id) }
        }
        guard manifest.limits.fits(within: policy.limits) else { throw .limitsExceeded }
        return ExtensionLaunchPlan(
            executablePath: manifest.executablePath,
            arguments: manifest.arguments,
            workingDirectory: manifest.workingDirectory,
            capabilities: manifest.capabilities,
            limits: manifest.limits
        )
    }

    private func handshake(from response: ExtensionRPCResponse) throws(ExtensionHostError) -> ExtensionHandshake {
        if let error = response.error {
            throw .protocolError("(error.code): (error.message)")
        }
        guard let result = response.result else { throw .protocolError("Extension returned no handshake.") }
        do {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(ExtensionHandshake.self, from: data)
        } catch {
            throw .protocolError("Invalid extension handshake.")
        }
    }

    private static func validateManifest(_ manifest: ExtensionManifest) throws(ExtensionHostError) {
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidManifest("Extension id must not be empty.")
        }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidManifest("Extension display name must not be empty.")
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidManifest("Extension version must not be empty.")
        }
        guard !manifest.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidManifest("Extension executable path must not be empty.")
        }
        guard manifest.executablePath.first == "/" else {
            throw .invalidManifest("Extension executable path must be absolute.")
        }
        guard manifest.source.url != nil else {
            throw .invalidManifest("Extension source URL is required.")
        }
    }
}
