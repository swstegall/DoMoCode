// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// Dependency-neutral capability contracts shared by the runtime and future
/// adapters.
///
/// These protocols intentionally carry values from ``DoMoCore`` only. A
/// provider can translate ``ProviderRequest`` to LiteLLM, an ACP peer, or a
/// direct SDK; a backend can launch locally or remotely; and a theme can be
/// rendered by either terminal surface. None of those choices belong in the
/// contract that lets the rest of the application discover and compose them.

// MARK: - Adapters

/// The lifecycle shared by an external provider, execution backend, or other
/// long-lived integration.
public protocol DoMoAdapter: Sendable {
    var descriptor: AdapterDescriptor { get }

    func start() async throws
    func stop() async
}

/// Human-readable identity and capability metadata for an adapter.
public struct AdapterDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var version: String?
    public var capabilities: [String]

    public init(
        id: String,
        displayName: String,
        version: String? = nil,
        capabilities: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.capabilities = capabilities
    }
}

// MARK: - Providers

/// A model-independent message role.
public enum ProviderMessageRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// A provider request message whose content remains extensible JSON rather
/// than assuming text-only or one vendor's image representation.
public struct ProviderMessage: Sendable, Codable, Hashable {
    public var role: ProviderMessageRole
    public var content: JSONValue
    public var metadata: [String: JSONValue]

    public init(
        role: ProviderMessageRole,
        content: JSONValue,
        metadata: [String: JSONValue] = [:]
    ) {
        self.role = role
        self.content = content
        self.metadata = metadata
    }
}

/// A callable tool description as seen by a model provider.
public struct ProviderTool: Sendable, Codable, Hashable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A provider-neutral model request. Provider-specific knobs belong in
/// ``options`` and are interpreted by the adapter that understands them.
public struct ProviderRequest: Sendable, Codable, Hashable {
    public var model: String
    public var messages: [ProviderMessage]
    public var tools: [ProviderTool]
    public var options: JSONValue
    public var metadata: [String: JSONValue]

    public init(
        model: String,
        messages: [ProviderMessage],
        tools: [ProviderTool] = [],
        options: JSONValue = .object([:]),
        metadata: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.options = options
        self.metadata = metadata
    }
}

/// A provider event with a stable semantic kind and an extensible payload.
public struct ProviderEvent: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case messageStart
        case textDelta
        case reasoningDelta
        case toolCallDelta
        case usage
        case messageEnd
        case error
        case unknown
    }

    public var kind: Kind
    public var payload: JSONValue
    public var sequence: Int?

    public init(kind: Kind, payload: JSONValue = .null, sequence: Int? = nil) {
        self.kind = kind
        self.payload = payload
        self.sequence = sequence
    }
}

/// Metadata for a model exposed by a provider.
public struct ProviderModel: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    public var capabilities: [String]

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        capabilities: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.capabilities = capabilities
    }
}

/// Provider identity that does not mention a concrete transport or API.
public struct ProviderDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var capabilities: [String]

    public init(id: String, displayName: String, capabilities: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// The model seam used by the agent runtime. LiteLLM is one implementation,
/// not part of this protocol's vocabulary.
public protocol DoMoProvider: DoMoAdapter {
    var providerDescriptor: ProviderDescriptor { get }

    func listModels() async throws -> [ProviderModel]
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error>
}

// MARK: - Backends

/// An operation sent to an execution backend. The backend decides whether the
/// operation is a process, a remote job, a container action, or another form
/// of execution.
public struct BackendRequest: Sendable, Codable, Hashable {
    public var operation: String
    public var input: JSONValue
    public var metadata: [String: JSONValue]

    public init(
        operation: String,
        input: JSONValue = .null,
        metadata: [String: JSONValue] = [:]
    ) {
        self.operation = operation
        self.input = input
        self.metadata = metadata
    }
}

public enum BackendResultStatus: String, Sendable, Codable, Hashable {
    case succeeded
    case failed
    case cancelled
}

public struct BackendResult: Sendable, Codable, Hashable {
    public var status: BackendResultStatus
    public var output: JSONValue
    public var metadata: [String: JSONValue]

    public init(
        status: BackendResultStatus,
        output: JSONValue = .null,
        metadata: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.output = output
        self.metadata = metadata
    }
}

/// The execution seam. It does not assume a local filesystem, a particular
/// operating system, or a worktree implementation.
public protocol DoMoBackend: DoMoAdapter {
    func execute(_ request: BackendRequest) async throws -> BackendResult
    func cancel(operationID: String) async
}

// MARK: - Workflows

public struct WorkflowDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var stages: [String]

    public init(id: String, displayName: String, stages: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.stages = stages
    }
}

public struct WorkflowRequest: Sendable, Codable, Hashable {
    public var input: JSONValue
    public var metadata: [String: JSONValue]

    public init(input: JSONValue = .null, metadata: [String: JSONValue] = [:]) {
        self.input = input
        self.metadata = metadata
    }
}

public struct WorkflowUpdate: Sendable, Codable, Hashable {
    public var stage: String
    public var message: String?
    public var payload: JSONValue

    public init(stage: String, message: String? = nil, payload: JSONValue = .null) {
        self.stage = stage
        self.message = message
        self.payload = payload
    }
}

public struct WorkflowResult: Sendable, Codable, Hashable {
    public var output: JSONValue
    public var metadata: [String: JSONValue]

    public init(output: JSONValue = .null, metadata: [String: JSONValue] = [:]) {
        self.output = output
        self.metadata = metadata
    }
}

public typealias WorkflowUpdateSink = @Sendable (WorkflowUpdate) async -> Void

/// A composable workflow that can report progress without committing to a UI
/// or a persistence format.
public protocol DoMoWorkflow: Sendable {
    var descriptor: WorkflowDescriptor { get }

    func run(
        _ request: WorkflowRequest,
        onUpdate: WorkflowUpdateSink?
    ) async throws -> WorkflowResult
}

// MARK: - Tool catalog

public struct ToolCatalogContext: Sendable, Codable, Hashable {
    public var sessionID: String?
    public var capabilities: [String]
    public var metadata: [String: JSONValue]

    public init(
        sessionID: String? = nil,
        capabilities: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.sessionID = sessionID
        self.capabilities = capabilities
        self.metadata = metadata
    }
}

public enum ToolCatalogSource: String, Sendable, Codable, Hashable {
    case builtIn
    case mcp
    case adapter
    case extensionProvider
}

public enum ToolPermissionState: String, Sendable, Codable, Hashable {
    case allowed
    case requiresApproval
    case denied
    case unavailable
}

public struct ToolCatalogEntry: Sendable, Codable, Hashable {
    public var name: String
    public var description: String?
    public var source: ToolCatalogSource
    public var inputSchema: JSONValue
    public var permission: ToolPermissionState
    public var metadata: [String: JSONValue]

    public init(
        name: String,
        description: String? = nil,
        source: ToolCatalogSource,
        inputSchema: JSONValue,
        permission: ToolPermissionState,
        metadata: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.inputSchema = inputSchema
        self.permission = permission
        self.metadata = metadata
    }
}

/// Resolves the same currently-callable catalog that a future model turn will
/// receive. The caller supplies session context; the catalog owns resolution.
public protocol DoMoToolCatalog: Sendable {
    func entries(for context: ToolCatalogContext) async throws -> [ToolCatalogEntry]
}

// MARK: - Extensions

public struct ExtensionDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var version: String?

    public init(id: String, displayName: String, version: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.version = version
    }
}

public struct ExtensionToolRegistration: Sendable {
    public var entry: ToolCatalogEntry
    public var execute: @Sendable (JSONValue) async throws -> JSONValue

    public init(
        entry: ToolCatalogEntry,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.entry = entry
        self.execute = execute
    }
}

public protocol DoMoExtensionRegistry: Sendable {
    func register(_ tool: ExtensionToolRegistration) async throws
    func unregister(toolNamed name: String) async
}

/// An out-of-process or in-process extension can use the same lifecycle and
/// registration contract without making the core depend on a plugin runtime.
public protocol DoMoExtension: DoMoAdapter {
    var extensionDescriptor: ExtensionDescriptor { get }

    func install(into registry: any DoMoExtensionRegistry) async throws
}

// MARK: - Themes

public enum ThemeColor: Sendable, Codable, Hashable {
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
    case indexed(UInt8)
    case named(String)
    case inherit
}

public enum ThemeAttribute: String, Sendable, Codable, Hashable {
    case bold
    case dim
    case italic
    case underline
    case inverse
    case strikethrough
}

public struct ThemeToken: Sendable, Codable, Hashable {
    public var foreground: ThemeColor?
    public var background: ThemeColor?
    public var attributes: Set<ThemeAttribute>

    public init(
        foreground: ThemeColor? = nil,
        background: ThemeColor? = nil,
        attributes: Set<ThemeAttribute> = []
    ) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

public struct ThemeDefinition: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var tokens: [String: ThemeToken]

    public init(id: String, displayName: String, tokens: [String: ThemeToken] = [:]) {
        self.id = id
        self.displayName = displayName
        self.tokens = tokens
    }
}

/// Semantic theme values are independent of SGR encoding, cell buffers, and
/// either terminal renderer.
public protocol DoMoThemeProvider: Sendable {
    func themes() async throws -> [ThemeDefinition]
    func theme(named id: String) async throws -> ThemeDefinition?
}
