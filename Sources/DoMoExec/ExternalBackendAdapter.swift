// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

/// Errors returned by a user-installed backend command. The command is kept
/// outside DoMoCode on purpose: this adapter supplies a small JSON boundary,
/// but it does not vendor Docker, Gondolin, OpenShell, or a remote-worker SDK.
public enum ExternalBackendError: Error, Sendable, Equatable {
    case emptyCommand
    case executableUnavailable(String)
    case isolationUnavailable(String)
    case notHealthy(BackendLifecycleState)
    case commandFailed(String)
    case protocolFailure(String)
    case cancelled
}

/// Configuration for one executable speaking the DoMo backend protocol.
///
/// The command receives one JSON-encoded ``BackendRequest`` on standard input
/// and must return one JSON-encoded ``BackendResult`` on standard output. The
/// `health`, `pause`, `resume`, `reconnect`, and `cleanup` operation names are
/// lifecycle messages; ordinary operation names are forwarded unchanged.
///
/// A health response must include `metadata.isolationEstablished: true` when
/// the descriptor requires isolation. This is deliberately a runtime proof,
/// not a promise in configuration, so an unavailable or misconfigured
/// user-installed backend fails closed before a workflow can select it.
public struct ExternalBackendConfiguration: Sendable, Hashable {
    public let descriptor: BackendDescriptor
    public let command: [String]
    public let workingDirectory: FilePath?
    public let environment: ShellEnvironment
    public let timeout: Duration?

    public init(
        descriptor: BackendDescriptor,
        command: [String],
        workingDirectory: FilePath? = nil,
        environment: ShellEnvironment = .inherit,
        timeout: Duration? = .seconds(30)
    ) throws(ExternalBackendError) {
        guard !command.isEmpty, command.allSatisfy({ !$0.isEmpty }) else {
            throw .emptyCommand
        }
        self.descriptor = descriptor
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
    }
}

/// A lifecycle-managed adapter for a user-installed backend command.
///
/// Each request is a fresh process. That keeps the protocol bounded and makes
/// cancellation and credential scope explicit; a backend that needs a daemon
/// can keep its own daemon behind the command. The adapter never interprets
/// backend-specific arguments or silently falls back to local execution.
public actor ExternalCommandBackend: DoMoManagedBackend {
    public nonisolated let backendDescriptor: BackendDescriptor
    public nonisolated let descriptor: AdapterDescriptor

    private let configuration: ExternalBackendConfiguration
    private let shell: SubprocessShell
    private var state: BackendLifecycleState = .stopped
    private var currentHealth: BackendHealth
    private var startRequest = BackendStartRequest()
    private var operations: [String: Task<ShellResult, Error>] = [:]

    public init(configuration: ExternalBackendConfiguration) throws(ExternalBackendError) {
        self.configuration = configuration
        self.backendDescriptor = configuration.descriptor
        self.descriptor = configuration.descriptor.adapterDescriptor
        self.shell = try Self.makeShell()
        self.currentHealth = BackendHealth(
            state: .stopped,
            message: "Backend has not completed a health handshake",
            capabilities: configuration.descriptor.capabilities
        )
    }

    public func start() async throws {
        try await start(request: BackendStartRequest())
    }

    public func start(request: BackendStartRequest) async throws {
        try ensureCommandAvailable()
        startRequest = request
        state = .starting
        currentHealth = BackendHealth(
            state: .starting,
            message: "Backend health handshake in progress",
            capabilities: backendDescriptor.capabilities
        )

        do {
            let result = try await invoke(BackendRequest(operation: "health"))
            let health = try health(from: result)
            try validate(health: health, request: request)
            currentHealth = health
            state = health.state
        } catch {
            state = .failed
            currentHealth = BackendHealth(
                state: .failed,
                message: diagnostic(error),
                capabilities: backendDescriptor.capabilities
            )
            throw error
        }
    }

    public func stop() async {
        for operation in operations.values { operation.cancel() }
        operations.removeAll()
        state = .stopped
        currentHealth = BackendHealth(
            state: .stopped,
            message: "Backend stopped",
            capabilities: backendDescriptor.capabilities
        )
    }

    public func health() async -> BackendHealth {
        currentHealth
    }

    public func pause() async throws {
        try ensureHealthy()
        _ = try await invoke(BackendRequest(operation: "pause"))
        state = .paused
        currentHealth.state = .paused
        currentHealth.message = "Backend paused"
    }

    public func resume() async throws {
        guard state == .paused else { throw ExternalBackendError.notHealthy(state) }
        _ = try await invoke(BackendRequest(operation: "resume"))
        try await start(request: startRequest)
    }

    public func reconnect() async throws {
        guard state != .starting else { throw ExternalBackendError.notHealthy(state) }
        _ = try await invoke(BackendRequest(operation: "reconnect"))
        try await start(request: startRequest)
    }

    public func cleanup() async throws {
        guard state != .stopped else { return }
        _ = try await invoke(BackendRequest(operation: "cleanup"))
        await stop()
    }

    public func execute(_ request: BackendRequest) async throws -> BackendResult {
        try ensureHealthy()
        let result = try await invoke(request)
        guard result.status != .cancelled else { throw ExternalBackendError.cancelled }
        return result
    }

    public func cancel(operationID: String) async {
        operations[operationID]?.cancel()
    }

    private func ensureHealthy() throws(ExternalBackendError) {
        guard state == .healthy || state == .degraded else {
            throw .notHealthy(state)
        }
    }

    private func ensureCommandAvailable() throws(ExternalBackendError) {
        guard let executable = configuration.command.first,
              Self.isExecutable(executable, environment: configuration.environment)
        else {
            throw .executableUnavailable(configuration.command[0])
        }
    }

    private func invoke(_ request: BackendRequest) async throws -> BackendResult {
        let operationID = request.metadata["operationID"]?.stringValue
            ?? UUIDv7.generate().description
        let input: [UInt8]
        do {
            input = Array(try JSONEncoder().encode(request)) + [0x0a]
        } catch {
            throw ExternalBackendError.protocolFailure("could not encode backend request")
        }

        let task = Task { [configuration, shell] in
            try await shell.run(ShellRequest(
                Self.commandLine(configuration.command),
                workingDirectory: configuration.workingDirectory,
                environment: configuration.environment,
                standardInput: .bytes(input),
                timeout: configuration.timeout,
                sandboxRole: .provider
            ))
        }
        operations[operationID] = task
        defer { operations.removeValue(forKey: operationID) }

        let result: ShellResult
        do {
            result = try await task.value
        } catch is CancellationError {
            throw ExternalBackendError.cancelled
        } catch let error as DoMoError where error.kind == .cancelled {
            throw ExternalBackendError.cancelled
        } catch {
            throw ExternalBackendError.commandFailed(diagnostic(error))
        }

        guard !result.timedOut else { throw ExternalBackendError.commandFailed("backend command timed out") }
        guard case .exited(let code) = result.termination, code == 0 else {
            throw ExternalBackendError.commandFailed(
                "backend command exited unsuccessfully: \(result.stderr.text)"
            )
        }
        guard !result.stdout.isTruncated else {
            throw ExternalBackendError.protocolFailure("backend response exceeded the output limit")
        }
        do {
            return try JSONDecoder().decode(BackendResult.self, from: Data(result.stdout.bytes))
        } catch {
            throw ExternalBackendError.protocolFailure("backend returned invalid JSON")
        }
    }

    private func health(from result: BackendResult) throws(ExternalBackendError) -> BackendHealth {
        guard result.status == .succeeded else {
            throw .commandFailed("backend health operation did not succeed")
        }
        let metadata = result.metadata
        let isolationEstablished = metadata["isolationEstablished"]?.boolValue == true
        let authenticated = metadata["authenticated"]?.boolValue == true
        let capabilities = metadata["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            ?? backendDescriptor.capabilities
        let state: BackendLifecycleState = metadata["degraded"]?.boolValue == true ? .degraded : .healthy
        return BackendHealth(
            state: state,
            message: metadata["message"]?.stringValue ?? "Backend health handshake succeeded",
            authenticated: authenticated,
            isolationEstablished: isolationEstablished,
            capabilities: capabilities
        )
    }

    private func validate(
        health: BackendHealth,
        request: BackendStartRequest
    ) throws(ExternalBackendError) {
        guard health.state != .failed, health.state != .unsupported, health.state != .stopped else {
            throw .commandFailed(health.message)
        }
        if request.requireIsolation || backendDescriptor.requiresIsolation,
           !health.isolationEstablished
        {
            throw .isolationUnavailable(backendDescriptor.id)
        }
        let available = Set(health.capabilities)
        if let missing = request.requiredCapabilities.first(where: { !available.contains($0) }) {
            throw .protocolFailure("backend did not advertise required capability \(missing)")
        }
    }

    private static func makeShell() throws(ExternalBackendError) -> SubprocessShell {
        do {
            return try SubprocessShell()
        } catch {
            throw .commandFailed("could not initialize the subprocess adapter")
        }
    }

    private static func commandLine(_ command: [String]) -> String {
        command.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isExecutable(_ value: String, environment: ShellEnvironment) -> Bool {
        if value.contains("/") {
            return FileManager.default.isExecutableFile(atPath: value)
        }
        let path = environment.overrides["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
        guard let path else { return false }
        return path
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { FilePath(String($0)).appending(value).string }
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func diagnostic(_ error: any Error) -> String {
        Redaction.diagnostic(String(describing: error))
    }
}
