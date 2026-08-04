// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// Backend lifecycle contracts are kept in the core module so a client or
/// workflow runner does not need to know whether execution is local, container
/// backed, or remote. Concrete backends still own their transport and
/// isolation implementation; the registry owns truthful state and admission.

import Foundation

public enum BackendKind: String, Sendable, Codable, Hashable, CaseIterable {
    case localProcess
    case docker
    case gondolin
    case openShell
    case remoteWorker
    case custom
}

public enum BackendLifecycleState: String, Sendable, Codable, Hashable, CaseIterable {
    case stopped
    case starting
    case healthy
    case degraded
    case paused
    case reconnecting
    case failed
    case unsupported
}

/// The capabilities a backend advertises before a workflow is admitted. Names
/// are intentionally provider-neutral (for example `pty`, `network`, and
/// `workspace-write`) and remain inspectable in a catalog.
public struct BackendDescriptor: Sendable, Codable, Hashable {
    public var id: String
    public var displayName: String
    public var kind: BackendKind
    public var capabilities: [String]
    public var requiresIsolation: Bool
    public var source: AdapterSourceMetadata

    public init(
        id: String,
        displayName: String,
        kind: BackendKind,
        capabilities: [String] = [],
        requiresIsolation: Bool = true,
        source: AdapterSourceMetadata = .builtInMIT
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.capabilities = Array(Set(capabilities)).sorted()
        self.requiresIsolation = requiresIsolation
        self.source = source
    }

    public var adapterDescriptor: AdapterDescriptor {
        AdapterDescriptor(
            id: id,
            displayName: displayName,
            capabilities: capabilities,
            kind: .backend,
            source: source
        )
    }
}

public struct BackendStartRequest: Sendable, Codable, Hashable {
    public var requiredCapabilities: [String]
    public var requireIsolation: Bool
    public var metadata: [String: JSONValue]

    public init(
        requiredCapabilities: [String] = [],
        requireIsolation: Bool = true,
        metadata: [String: JSONValue] = [:]
    ) {
        self.requiredCapabilities = Array(Set(requiredCapabilities)).sorted()
        self.requireIsolation = requireIsolation
        self.metadata = metadata
    }
}

public struct BackendHealth: Sendable, Codable, Hashable {
    public var state: BackendLifecycleState
    public var message: String
    public var authenticated: Bool
    public var isolationEstablished: Bool
    public var capabilities: [String]

    public init(
        state: BackendLifecycleState,
        message: String,
        authenticated: Bool = false,
        isolationEstablished: Bool = false,
        capabilities: [String] = []
    ) {
        self.state = state
        self.message = message
        self.authenticated = authenticated
        self.isolationEstablished = isolationEstablished
        self.capabilities = Array(Set(capabilities)).sorted()
    }
}

public struct BackendStateEvent: Sendable, Codable, Hashable {
    public var sequence: Int
    public var backendID: String
    public var state: BackendLifecycleState
    public var message: String

    public init(
        sequence: Int,
        backendID: String,
        state: BackendLifecycleState,
        message: String
    ) {
        self.sequence = sequence
        self.backendID = backendID
        self.state = state
        self.message = message
    }
}

public enum BackendRegistryError: Error, Sendable, Equatable {
    case emptyID
    case duplicateID(String)
    case notRegistered(String)
    case missingCapability(backendID: String, capability: String)
    case noEligibleBackend(requiredCapabilities: [String])
    case isolationUnavailable(String)
    case notReady(backendID: String, state: BackendLifecycleState)
    case invalidTransition(backendID: String, state: BackendLifecycleState)
    case unavailable(backendID: String, message: String)
    case lifecycleFailed(backendID: String, message: String)
}

/// A backend implementation that can be admitted to the lifecycle registry.
/// The inherited adapter `start()` remains useful to callers that do not need
/// capability negotiation; the default request-aware start forwards to it.
public protocol DoMoManagedBackend: DoMoBackend {
    var backendDescriptor: BackendDescriptor { get }

    func health() async -> BackendHealth
    func start(request: BackendStartRequest) async throws
    func pause() async throws
    func resume() async throws
    func reconnect() async throws
    func cleanup() async throws
}

public extension DoMoManagedBackend {
    func start(request: BackendStartRequest) async throws {
        try await start()
    }

    func pause() async throws {}

    func resume() async throws {
        try await start()
    }

    func reconnect() async throws {
        await stop()
        try await start()
    }

    func cleanup() async throws {
        await stop()
    }
}

/// Serializes lifecycle transitions and refuses execution against a stopped,
/// paused, unsupported, or failed backend. State events are append-only and
/// deterministic, so headless clients can resume from a sequence cursor.
public actor BackendRegistry {
    private struct Record: Sendable {
        let backend: any DoMoManagedBackend
        let descriptor: BackendDescriptor
        var health: BackendHealth
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var events: [BackendStateEvent] = []
    private var nextSequence = 0

    public init() {}

    public func register(_ backend: any DoMoManagedBackend) throws(BackendRegistryError) {
        let descriptor = backend.backendDescriptor
        let id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw .emptyID }
        guard records[id] == nil else { throw .duplicateID(id) }
        let normalized = BackendDescriptor(
            id: id,
            displayName: descriptor.displayName,
            kind: descriptor.kind,
            capabilities: descriptor.capabilities,
            requiresIsolation: descriptor.requiresIsolation,
            source: descriptor.source
        )
        records[id] = Record(
            backend: backend,
            descriptor: normalized,
            health: BackendHealth(
                state: .stopped,
                message: "Backend has not been started",
                capabilities: normalized.capabilities
            )
        )
        order.append(id)
        appendEvent(id: id, state: .stopped, message: "Backend registered")
    }

    public func unregister(id: String) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        do {
            try await record.backend.cleanup()
        } catch {
            throw .lifecycleFailed(backendID: id, message: Redaction.diagnostic(String(describing: error)))
        }
        records.removeValue(forKey: id)
        order.removeAll { $0 == id }
        appendEvent(id: id, state: .stopped, message: "Backend unregistered")
    }

    public func descriptors() -> [BackendDescriptor] {
        order.compactMap { records[$0]?.descriptor }
    }

    public func adapterDescriptors() -> [AdapterDescriptor] {
        order.compactMap { records[$0]?.descriptor.adapterDescriptor }
    }

    public func state(for id: String) throws(BackendRegistryError) -> BackendLifecycleState {
        guard let record = records[id] else { throw .notRegistered(id) }
        return record.health.state
    }

    /// Returns the backend's live health when running. Registry-owned paused
    /// and stopped states are returned without allowing a backend to relabel
    /// itself as healthy behind the registry's back.
    public func health(for id: String) async throws(BackendRegistryError) -> BackendHealth {
        guard let record = records[id] else { throw .notRegistered(id) }
        switch record.health.state {
        case .stopped, .paused, .unsupported, .failed:
            return record.health
        case .starting, .healthy, .degraded, .reconnecting:
            let live = await record.backend.health()
            var updated = live
            if updated.capabilities.isEmpty { updated.capabilities = record.descriptor.capabilities }
            records[id]?.health = updated
            return updated
        }
    }

    public func start(
        id: String,
        request: BackendStartRequest = BackendStartRequest()
    ) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        try checkAdmission(record.descriptor, request: request)
        guard [.stopped, .failed, .unsupported, .degraded].contains(record.health.state) else {
            throw .invalidTransition(backendID: id, state: record.health.state)
        }
        setState(id, .starting, message: "Backend starting")
        do {
            try await record.backend.start(request: request)
            let live = await record.backend.health()
            try validateHealth(id: id, descriptor: record.descriptor, health: live, request: request)
            records[id]?.health = live
            appendEvent(id: id, state: live.state, message: live.message)
        } catch let error as BackendRegistryError {
            setState(id, .failed, message: String(describing: error))
            throw error
        } catch {
            let message = Redaction.diagnostic(String(describing: error))
            setState(id, .failed, message: message)
            throw .lifecycleFailed(backendID: id, message: message)
        }
    }

    public func stop(id: String) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        guard record.health.state != .stopped else { return }
        await record.backend.stop()
        setState(id, .stopped, message: "Backend stopped")
    }

    public func pause(id: String) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        guard [.healthy, .degraded].contains(record.health.state) else {
            throw .invalidTransition(backendID: id, state: record.health.state)
        }
        do {
            try await record.backend.pause()
            var health = record.health
            health.state = .paused
            health.message = "Backend paused"
            records[id]?.health = health
            appendEvent(id: id, state: .paused, message: health.message)
        } catch {
            throw .lifecycleFailed(backendID: id, message: Redaction.diagnostic(String(describing: error)))
        }
    }

    public func resume(
        id: String,
        request: BackendStartRequest = BackendStartRequest()
    ) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        guard record.health.state == .paused else {
            throw .invalidTransition(backendID: id, state: record.health.state)
        }
        try checkAdmission(record.descriptor, request: request)
        setState(id, .starting, message: "Backend resuming")
        do {
            try await record.backend.resume()
            let live = await record.backend.health()
            try validateHealth(id: id, descriptor: record.descriptor, health: live, request: request)
            records[id]?.health = live
            appendEvent(id: id, state: live.state, message: live.message)
        } catch let error as BackendRegistryError {
            setState(id, .failed, message: String(describing: error))
            throw error
        } catch {
            let message = Redaction.diagnostic(String(describing: error))
            setState(id, .failed, message: message)
            throw .lifecycleFailed(backendID: id, message: message)
        }
    }

    public func reconnect(
        id: String,
        request: BackendStartRequest = BackendStartRequest()
    ) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        try checkAdmission(record.descriptor, request: request)
        guard record.health.state != .starting else {
            throw .invalidTransition(backendID: id, state: record.health.state)
        }
        setState(id, .reconnecting, message: "Backend reconnecting")
        do {
            try await record.backend.reconnect()
            let live = await record.backend.health()
            try validateHealth(id: id, descriptor: record.descriptor, health: live, request: request)
            records[id]?.health = live
            appendEvent(id: id, state: live.state, message: live.message)
        } catch let error as BackendRegistryError {
            setState(id, .failed, message: String(describing: error))
            throw error
        } catch {
            let message = Redaction.diagnostic(String(describing: error))
            setState(id, .failed, message: message)
            throw .lifecycleFailed(backendID: id, message: message)
        }
    }

    public func cleanup(id: String) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        do {
            try await record.backend.cleanup()
            setState(id, .stopped, message: "Backend cleaned up")
        } catch {
            let message = Redaction.diagnostic(String(describing: error))
            setState(id, .failed, message: message)
            throw .lifecycleFailed(backendID: id, message: message)
        }
    }

    public func execute(
        id: String,
        request: BackendRequest
    ) async throws(BackendRegistryError) -> BackendResult {
        guard let record = records[id] else { throw .notRegistered(id) }
        guard [.healthy, .degraded].contains(record.health.state) else {
            throw .invalidTransition(backendID: id, state: record.health.state)
        }
        guard !record.descriptor.requiresIsolation || record.health.isolationEstablished else {
            throw .isolationUnavailable(id)
        }
        do {
            return try await record.backend.execute(request)
        } catch {
            throw .lifecycleFailed(backendID: id, message: Redaction.diagnostic(String(describing: error)))
        }
    }

    public func cancel(id: String, operationID: String) async throws(BackendRegistryError) {
        guard let record = records[id] else { throw .notRegistered(id) }
        await record.backend.cancel(operationID: operationID)
    }

    /// Selects a backend that is already healthy and satisfies the requested
    /// capabilities. This is deliberately non-mutating with respect to the
    /// lifecycle: a caller must start or reconnect an adapter before selection
    /// can succeed, so an unavailable optional backend is never silently used.
    public func select(
        _ request: BackendSelectionRequest = .init()
    ) async throws(BackendRegistryError) -> BackendSelection {
        let explicitID = request.backendID
        let candidates: [String]
        if let explicitID {
            guard records[explicitID] != nil else { throw .notRegistered(explicitID) }
            candidates = [explicitID]
        } else {
            candidates = order
        }
        guard !candidates.isEmpty else {
            throw .noEligibleBackend(requiredCapabilities: request.requiredCapabilities)
        }

        for id in candidates {
            guard let record = records[id] else {
                if explicitID != nil { throw .notRegistered(id) }
                continue
            }

            var live = record.health
            if [.starting, .healthy, .degraded, .reconnecting].contains(live.state) {
                live = await record.backend.health()
                if live.capabilities.isEmpty { live.capabilities = record.descriptor.capabilities }
                records[id]?.health = live
            }
            guard [.healthy, .degraded].contains(live.state) else {
                if explicitID != nil { throw .notReady(backendID: id, state: live.state) }
                continue
            }

            let capabilities = Set(live.capabilities)
            if let missing = request.requiredCapabilities.first(where: { !capabilities.contains($0) }) {
                if explicitID != nil { throw .missingCapability(backendID: id, capability: missing) }
                continue
            }
            if (request.requireIsolation || record.descriptor.requiresIsolation),
               !live.isolationEstablished {
                if explicitID != nil { throw .isolationUnavailable(id) }
                continue
            }
            return BackendSelection(descriptor: record.descriptor, health: live)
        }

        throw .noEligibleBackend(requiredCapabilities: request.requiredCapabilities)
    }

    public func stateEvents(after sequence: Int? = nil) -> [BackendStateEvent] {
        guard let sequence else { return events }
        return events.filter { $0.sequence > sequence }
    }

    private func checkAdmission(
        _ descriptor: BackendDescriptor,
        request: BackendStartRequest
    ) throws(BackendRegistryError) {
        let available = Set(descriptor.capabilities)
        for capability in request.requiredCapabilities where !available.contains(capability) {
            throw .missingCapability(backendID: descriptor.id, capability: capability)
        }
        if request.requireIsolation && descriptor.requiresIsolation == false {
            throw .isolationUnavailable(descriptor.id)
        }
    }

    private func validateHealth(
        id: String,
        descriptor: BackendDescriptor,
        health: BackendHealth,
        request: BackendStartRequest
    ) throws(BackendRegistryError) {
        if health.state == .unsupported || health.state == .failed || health.state == .stopped {
            throw .unavailable(backendID: id, message: health.message)
        }
        if (request.requireIsolation || descriptor.requiresIsolation) && !health.isolationEstablished {
            throw .isolationUnavailable(id)
        }
    }

    private func setState(_ id: String, _ state: BackendLifecycleState, message: String) {
        guard var record = records[id] else { return }
        record.health.state = state
        record.health.message = message
        records[id] = record
        appendEvent(id: id, state: state, message: message)
    }

    private func appendEvent(id: String, state: BackendLifecycleState, message: String) {
        events.append(BackendStateEvent(
            sequence: nextSequence,
            backendID: id,
            state: state,
            message: message
        ))
        nextSequence += 1
    }
}
