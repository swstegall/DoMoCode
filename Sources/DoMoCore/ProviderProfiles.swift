// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// The kind of external boundary an adapter owns. Keeping this in the core
/// contract lets the CLI, server, and diagnostics describe an adapter without
/// importing its implementation module.
public enum AdapterKind: String, Sendable, Codable, Hashable, CaseIterable {
    case provider
    case mcp
    case acp
    case backend
    case browser
    case notebook
    case remoteSearch
    case extensionProvider
    case theme
    case other
}

/// Source and license metadata for an adapter. This is deliberately metadata,
/// never executable configuration, and is safe to show in `adapters doctor`.
public struct AdapterSourceMetadata: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case builtIn
        case upstream
        case project
        case user
        case unknown
    }

    public var kind: Kind
    public var license: String?
    public var attribution: String?
    public var url: String?

    public init(
        kind: Kind = .unknown,
        license: String? = nil,
        attribution: String? = nil,
        url: String? = nil
    ) {
        self.kind = kind
        self.license = license
        self.attribution = attribution
        self.url = url
    }

    public static let builtInMIT = AdapterSourceMetadata(kind: .builtIn, license: "MIT")
}

/// A reference to a secret, not the secret itself. Provider profiles can be
/// persisted and inspected because this value contains only the lookup name.
public struct ProviderCredentialReference: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case environment
        case keychain
        case externalProcess
        case none
    }

    public var name: String
    public var kind: Kind
    public var required: Bool

    public init(name: String, kind: Kind = .environment, required: Bool = true) {
        self.name = name
        self.kind = kind
        self.required = required
    }

    public static let none = ProviderCredentialReference(name: "", kind: .none, required: false)
}

/// Accounting and spend behavior declared by a provider profile. Rates remain
/// optional: an unknown cost is rendered as unknown rather than guessed.
public struct ProviderUsagePolicy: Sendable, Codable, Hashable {
    public var reportsTokenUsage: Bool
    public var reportsCost: Bool
    public var currency: String?
    public var maximumCostPerRequest: Decimal?

    public init(
        reportsTokenUsage: Bool = true,
        reportsCost: Bool = false,
        currency: String? = "USD",
        maximumCostPerRequest: Decimal? = nil
    ) {
        self.reportsTokenUsage = reportsTokenUsage
        self.reportsCost = reportsCost
        self.currency = currency
        self.maximumCostPerRequest = maximumCostPerRequest
    }
}

/// Cache controls are a provider capability, not a permission grant. The
/// adapter may ignore an unsupported control but must expose that fact in its
/// descriptor instead of silently claiming cache semantics.
public struct ProviderCachePolicy: Sendable, Codable, Hashable {
    public var supportsPromptCaching: Bool
    public var supportsReadCache: Bool
    public var supportsWriteCache: Bool
    public var defaultTTLSeconds: Int?

    public init(
        supportsPromptCaching: Bool = false,
        supportsReadCache: Bool = false,
        supportsWriteCache: Bool = false,
        defaultTTLSeconds: Int? = nil
    ) {
        self.supportsPromptCaching = supportsPromptCaching
        self.supportsReadCache = supportsReadCache
        self.supportsWriteCache = supportsWriteCache
        self.defaultTTLSeconds = defaultTTLSeconds
    }
}

/// Provider-specific classification hints. The common `DoMoError` taxonomy
/// remains authoritative; these lists only let an adapter recognize a vendor's
/// body wording before it hands the failure to the shared retry/fallback path.
public struct ProviderErrorPolicy: Sendable, Codable, Hashable {
    public var transientStatusCodes: [Int]
    public var notFoundStatusCodes: [Int]
    public var quotaMarkers: [String]
    public var transientMarkers: [String]

    public init(
        transientStatusCodes: [Int] = [408, 425, 429, 500, 502, 503, 504, 529],
        notFoundStatusCodes: [Int] = [404],
        quotaMarkers: [String] = ["insufficient_quota", "quota exceeded", "billing"],
        transientMarkers: [String] = ["overloaded", "temporarily unavailable", "try again"]
    ) {
        self.transientStatusCodes = transientStatusCodes.sorted()
        self.notFoundStatusCodes = notFoundStatusCodes.sorted()
        self.quotaMarkers = quotaMarkers
        self.transientMarkers = transientMarkers
    }
}

/// A named, inspectable provider configuration. It intentionally has no field
/// for an API-key value. The adapter receives a resolved credential separately
/// at process wiring time, while this value can be written to settings or a
/// diagnostic report safely.
public struct ProviderProfile: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var adapterID: String
    public var endpoint: String
    public var defaultModel: String?
    public var credential: ProviderCredentialReference
    public var capabilities: [String]
    public var usagePolicy: ProviderUsagePolicy
    public var cachePolicy: ProviderCachePolicy
    public var contextWindow: Int?
    public var errorPolicy: ProviderErrorPolicy
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        displayName: String,
        adapterID: String,
        endpoint: String,
        defaultModel: String? = nil,
        credential: ProviderCredentialReference = .none,
        capabilities: [String] = [],
        usagePolicy: ProviderUsagePolicy = ProviderUsagePolicy(),
        cachePolicy: ProviderCachePolicy = ProviderCachePolicy(),
        contextWindow: Int? = nil,
        errorPolicy: ProviderErrorPolicy = ProviderErrorPolicy(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.adapterID = adapterID
        self.endpoint = endpoint
        self.defaultModel = defaultModel
        self.credential = credential
        self.capabilities = capabilities
        self.usagePolicy = usagePolicy
        self.cachePolicy = cachePolicy
        self.contextWindow = contextWindow
        self.errorPolicy = errorPolicy
        self.metadata = metadata
    }

    /// A profile is safe to print because credentials are references only. The
    /// endpoint is still labeled as operator-owned metadata rather than being
    /// treated as a URL to fetch during inspection.
    public var inspectableSummary: String {
        let model = defaultModel ?? "(none)"
        let credential = credential.kind == .none ? "none" : credential.name
        return "(displayName) [(id)] · (adapterID) · model (model) · credential (credential)"
    }
}

/// Ordered fallback behavior. Automatic fallback is deliberately narrow: it
/// may react to a transient failure before any response/tool result is
/// committed, while a route change after that boundary requires approval.
public enum ProviderFallbackPermission: String, Sendable, Codable, Hashable, CaseIterable {
    case transientBeforeCommit
    case explicitApproval
}

public struct ProviderRoute: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var profileIDs: [String]
    public var permission: ProviderFallbackPermission

    public init(
        id: String,
        displayName: String,
        profileIDs: [String],
        permission: ProviderFallbackPermission = .transientBeforeCommit
    ) {
        self.id = id
        self.displayName = displayName
        self.profileIDs = profileIDs
        self.permission = permission
    }
}

public enum ProviderCircuitState: String, Sendable, Codable, Hashable, CaseIterable {
    case closed
    case open
    case halfOpen
}

public struct ProviderCircuitSnapshot: Sendable, Codable, Hashable {
    public var profileID: String
    public var state: ProviderCircuitState
    public var consecutiveFailures: Int
    public var lastFailure: String?

    public init(
        profileID: String,
        state: ProviderCircuitState = .closed,
        consecutiveFailures: Int = 0,
        lastFailure: String? = nil
    ) {
        self.profileID = profileID
        self.state = state
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.lastFailure = lastFailure
    }
}

public enum ProviderFallbackDecision: Sendable, Hashable {
    case use(profileID: String)
    case requireApproval(profileID: String, reason: String)
    case stop(reason: String)
}

/// Pure route selection. A caller supplies the route order and whether the
/// current turn crossed its commit boundary; this function never replays a
/// stream or tool call and never grants approval by itself.
public enum ProviderFallbackRouter {
    public static func decision(
        route: ProviderRoute,
        currentProfileID: String,
        failureIsTransient: Bool,
        responseCommitted: Bool,
        approved: Bool
    ) -> ProviderFallbackDecision {
        guard let currentIndex = route.profileIDs.firstIndex(of: currentProfileID) else {
            return .stop(reason: "Provider route does not contain (currentProfileID)")
        }
        let nextIndex = route.profileIDs.index(after: currentIndex)
        guard route.profileIDs.indices.contains(nextIndex) else {
            return .stop(reason: "Provider route is exhausted")
        }
        let next = route.profileIDs[nextIndex]
        guard !responseCommitted else {
            return approved
                ? .use(profileID: next)
                : .requireApproval(
                    profileID: next,
                    reason: "A provider switch after response or tool output requires approval"
                )
        }
        guard failureIsTransient else {
            return approved
                ? .use(profileID: next)
                : .requireApproval(
                    profileID: next,
                    reason: "This provider failure is not classified as transient"
                )
        }
        if route.permission == .explicitApproval, !approved {
            return .requireApproval(profileID: next, reason: "Provider route requires explicit approval")
        }
        return .use(profileID: next)
    }
}

public enum AdapterRegistryError: Error, Sendable, Equatable {
    case emptyID
    case duplicateID(String)
}

public enum AdapterHealthStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case healthy
    case degraded
    case unavailable
    case unsupported
    case unknown
}

public struct AdapterHealth: Sendable, Codable, Hashable {
    public var status: AdapterHealthStatus
    public var message: String
    public var supportedEvents: [String]
    public var credentialRequired: Bool

    public init(
        status: AdapterHealthStatus,
        message: String,
        supportedEvents: [String] = [],
        credentialRequired: Bool = false
    ) {
        self.status = status
        self.message = message
        self.supportedEvents = supportedEvents
        self.credentialRequired = credentialRequired
    }
}

public struct AdapterDoctorResult: Sendable, Codable, Hashable {
    public var descriptor: AdapterDescriptor
    public var health: AdapterHealth

    public init(descriptor: AdapterDescriptor, health: AdapterHealth) {
        self.descriptor = descriptor
        self.health = health
    }
}

/// Optional health surface for adapters that can perform a bounded handshake.
/// Adapters without it remain listable and are reported as unknown rather than
/// being mistaken for healthy.
public protocol DoMoAdapterHealthChecking: DoMoAdapter {
    func healthCheck() async -> AdapterHealth
}

/// A process-local registry with deterministic insertion order. It is an actor
/// because adapters are long-lived Sendable values and doctor/start/stop may be
/// called concurrently by the CLI, server, and an attached client.
public actor AdapterRegistry {
    private var adapters: [String: any DoMoAdapter] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ adapter: any DoMoAdapter) throws(AdapterRegistryError) {
        let id = adapter.descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw .emptyID }
        guard adapters[id] == nil else { throw .duplicateID(id) }
        adapters[id] = adapter
        order.append(id)
    }

    public func unregister(id: String) {
        adapters.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    public func descriptors() -> [AdapterDescriptor] {
        order.compactMap { adapters[$0]?.descriptor }
    }

    public func adapter(id: String) -> (any DoMoAdapter)? {
        adapters[id]
    }

    public func startAll() async throws {
        for id in order {
            try await adapters[id]?.start()
        }
    }

    public func stopAll() async {
        for id in order.reversed() {
            await adapters[id]?.stop()
        }
    }

    public func doctor() async -> [AdapterDoctorResult] {
        var results: [AdapterDoctorResult] = []
        for id in order {
            guard let adapter = adapters[id] else { continue }
            let health: AdapterHealth
            if let checking = adapter as? any DoMoAdapterHealthChecking {
                health = await checking.healthCheck()
            } else {
                health = AdapterHealth(
                    status: .unknown,
                    message: "Adapter does not expose a handshake or health check"
                )
            }
            results.append(AdapterDoctorResult(descriptor: adapter.descriptor, health: health))
        }
        return results
    }
}
