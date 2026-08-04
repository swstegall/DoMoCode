// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

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
        return displayName + " [" + id + "] · " + adapterID
            + " · model " + model + " · credential " + credential
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

public enum ProviderRouteValidationError: Error, Sendable, Equatable {
    case emptyRoute
    case duplicateProfile(String)
    case missingProfile(String)
}

public enum ProviderRouteValidator {
    public static func validate(
        _ route: ProviderRoute,
        profiles: [String: ProviderProfile]
    ) throws(ProviderRouteValidationError) {
        guard !route.profileIDs.isEmpty else { throw .emptyRoute }
        var seen: Set<String> = []
        for profileID in route.profileIDs {
            guard seen.insert(profileID).inserted else { throw .duplicateProfile(profileID) }
            guard profiles[profileID] != nil else { throw .missingProfile(profileID) }
        }
    }
}

/// A deterministic circuit-breaker state machine. Time and persistence belong
/// to the caller; after its cooldown it calls `beginProbe` to move an open
/// circuit into half-open. This keeps tests and replay independent of wall-clock
/// time and prevents a provider switch from silently replaying a committed turn.
public actor ProviderCircuitBreaker {
    private let failureThreshold: Int
    private var states: [String: ProviderCircuitSnapshot] = [:]

    public init(failureThreshold: Int = 3) {
        self.failureThreshold = max(1, failureThreshold)
    }

    public func snapshot(for profileID: String) -> ProviderCircuitSnapshot {
        states[profileID] ?? ProviderCircuitSnapshot(profileID: profileID)
    }

    public func canAttempt(profileID: String) -> Bool {
        snapshot(for: profileID).state != .open
    }

    /// Returns true when the caller is allowed to issue a half-open probe. An
    /// already half-open circuit rejects a second concurrent probe.
    public func beginProbe(profileID: String) -> Bool {
        var state = snapshot(for: profileID)
        switch state.state {
        case .closed:
            return true
        case .open:
            state.state = .halfOpen
            states[profileID] = state
            return true
        case .halfOpen:
            return false
        }
    }

    @discardableResult
    public func recordSuccess(profileID: String) -> ProviderCircuitSnapshot {
        let state = ProviderCircuitSnapshot(profileID: profileID)
        states[profileID] = state
        return state
    }

    @discardableResult
    public func recordFailure(
        profileID: String,
        reason: String,
        transient: Bool
    ) -> ProviderCircuitSnapshot {
        var state = snapshot(for: profileID)
        state.lastFailure = reason
        guard transient else {
            states[profileID] = state
            return state
        }
        state.consecutiveFailures = min(Int.max, state.consecutiveFailures + 1)
        if state.consecutiveFailures >= failureThreshold {
            state.state = .open
        } else {
            state.state = .closed
        }
        states[profileID] = state
        return state
    }

    public func reset(profileID: String) {
        states[profileID] = ProviderCircuitSnapshot(profileID: profileID)
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
            return .stop(reason: "Provider route does not contain " + currentProfileID)
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

/// A safe, per-turn view of fallback state. The controller never stores a
/// request or response body, so it can be persisted or shown in diagnostics
/// without replaying provider data.
public struct ProviderFallbackSessionSnapshot: Sendable, Codable, Hashable {
    public var routeID: String
    public var currentProfileID: String?
    public var responseCommitted: Bool
    public var pendingApprovalProfileID: String?
    public var attemptedProfileIDs: [String]

    public init(
        routeID: String,
        currentProfileID: String?,
        responseCommitted: Bool,
        pendingApprovalProfileID: String?,
        attemptedProfileIDs: [String]
    ) {
        self.routeID = routeID
        self.currentProfileID = currentProfileID
        self.responseCommitted = responseCommitted
        self.pendingApprovalProfileID = pendingApprovalProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
    }
}

/// Coordinates the route policy and circuit breaker for one provider turn.
///
/// This is deliberately a controller, not a retry loop: it returns a decision
/// to the caller and never replays a request. A caller marks the response
/// committed as soon as text, a tool call, or a tool result crosses its own
/// boundary; every later provider switch then requires explicit approval.
public actor ProviderFallbackController {
    private struct PendingFailure: Sendable {
        let transient: Bool
        let profileID: String
    }

    public let route: ProviderRoute
    private let breaker: ProviderCircuitBreaker
    private var currentIndex = 0
    private var responseCommitted = false
    private var attemptedProfileIDs: [String] = []
    private var pendingFailure: PendingFailure?

    public init(
        route: ProviderRoute,
        breaker: ProviderCircuitBreaker = ProviderCircuitBreaker()
    ) {
        self.route = route
        self.breaker = breaker
    }

    public func snapshot() -> ProviderFallbackSessionSnapshot {
        ProviderFallbackSessionSnapshot(
            routeID: route.id,
            currentProfileID: currentProfileID,
            responseCommitted: responseCommitted,
            pendingApprovalProfileID: pendingApprovalProfileID,
            attemptedProfileIDs: attemptedProfileIDs
        )
    }

    public var currentProfileID: String? {
        guard route.profileIDs.indices.contains(currentIndex) else { return nil }
        return route.profileIDs[currentIndex]
    }

    public var pendingApprovalProfileID: String? {
        pendingFailure?.profileID
    }

    /// Select the first provider whose circuit is currently allowed to attempt.
    /// An open circuit is not probed implicitly; call `beginProbe` after the
    /// caller's cooldown policy says a probe is appropriate.
    public func start() async -> ProviderFallbackDecision {
        guard attemptedProfileIDs.isEmpty else {
            guard let currentProfileID else { return .stop(reason: "Provider route is empty") }
            return .use(profileID: currentProfileID)
        }
        guard let index = await firstUsableIndex(from: 0) else {
            return .stop(reason: "No provider in the route is currently available")
        }
        currentIndex = index
        markAttempted(route.profileIDs[index])
        return .use(profileID: route.profileIDs[index])
    }

    public func markResponseCommitted() {
        responseCommitted = true
    }

    public func recordSuccess() async {
        guard let currentProfileID else { return }
        _ = await breaker.recordSuccess(profileID: currentProfileID)
        pendingFailure = nil
    }

    /// Move the current circuit from open to half-open for one caller-owned
    /// probe. This method does not start a request.
    public func beginProbe() async -> Bool {
        guard let currentProfileID else { return false }
        return await breaker.beginProbe(profileID: currentProfileID)
    }

    public func circuitSnapshot(for profileID: String) async -> ProviderCircuitSnapshot {
        await breaker.snapshot(for: profileID)
    }

    public func recordFailure(
        reason: String,
        transient: Bool,
        approved: Bool = false
    ) async -> ProviderFallbackDecision {
        guard let currentProfileID else { return .stop(reason: "Provider route is empty") }
        _ = await breaker.recordFailure(
            profileID: currentProfileID,
            reason: reason,
            transient: transient
        )
        return await chooseNext(transient: transient, approved: approved)
    }

    /// Approve the pending route change without invoking the failed provider
    /// again. The original failure is not recorded a second time.
    public func approvePendingFallback() async -> ProviderFallbackDecision {
        guard let pendingFailure else {
            return .stop(reason: "No provider fallback is awaiting approval")
        }
        return await chooseNext(transient: pendingFailure.transient, approved: true)
    }

    public func rejectPendingFallback() -> ProviderFallbackDecision {
        pendingFailure = nil
        return .stop(reason: "Provider fallback was not approved")
    }

    private func chooseNext(
        transient: Bool,
        approved: Bool
    ) async -> ProviderFallbackDecision {
        guard let currentProfileID else {
            pendingFailure = nil
            return .stop(reason: "Provider route is empty")
        }
        let available = await availableProfileIDs(after: currentIndex)
        guard !available.isEmpty else {
            pendingFailure = nil
            return .stop(reason: "No usable provider remains in route " + route.id)
        }

        var candidateRoute = route
        candidateRoute.profileIDs = [currentProfileID] + available
        let decision = ProviderFallbackRouter.decision(
            route: candidateRoute,
            currentProfileID: currentProfileID,
            failureIsTransient: transient,
            responseCommitted: responseCommitted,
            approved: approved
        )
        switch decision {
        case .use(let profileID):
            if let index = route.profileIDs.firstIndex(of: profileID) {
                currentIndex = index
                markAttempted(profileID)
            }
            pendingFailure = nil
        case .requireApproval(let profileID, _):
            pendingFailure = PendingFailure(transient: transient, profileID: profileID)
        case .stop:
            pendingFailure = nil
        }
        return decision
    }

    private func firstUsableIndex(from start: Int) async -> Int? {
        guard start < route.profileIDs.count else { return nil }
        for index in start..<route.profileIDs.count {
            if await breaker.canAttempt(profileID: route.profileIDs[index]) { return index }
        }
        return nil
    }

    private func availableProfileIDs(after index: Int) async -> [String] {
        guard index + 1 < route.profileIDs.count else { return [] }
        var result: [String] = []
        for profileID in route.profileIDs.dropFirst(index + 1) {
            if await breaker.canAttempt(profileID: profileID) { result.append(profileID) }
        }
        return result
    }

    private func markAttempted(_ profileID: String) {
        if !attemptedProfileIDs.contains(profileID) { attemptedProfileIDs.append(profileID) }
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
