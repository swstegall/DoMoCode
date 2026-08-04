// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import DoMoTermIO
import Synchronization
import SystemPackage

/// The action set for the stateful `interactive_terminal` tool.
public enum InteractiveTerminalAction: String, Sendable, Hashable {
    case start
    case read
    case write
    case resize
    case stop
}

/// A request passed from the JSON-facing tool to a surface-owned provider.
public struct InteractiveTerminalRequest: Sendable, Hashable {
    public let action: InteractiveTerminalAction
    public let id: String?
    public let command: String?
    public let input: String?
    public let size: PTYSize?
    public let workingDirectory: String
    public let environment: PTYEnvironment
    public let sandbox: ProcessSandbox?

    public init(
        action: InteractiveTerminalAction,
        id: String? = nil,
        command: String? = nil,
        input: String? = nil,
        size: PTYSize? = nil,
        workingDirectory: String,
        environment: PTYEnvironment,
        sandbox: ProcessSandbox? = nil
    ) {
        self.action = action
        self.id = id
        self.command = command
        self.input = input
        self.size = size
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.sandbox = sandbox
    }
}

/// The bounded, model-visible projection of one interactive terminal call.
public struct InteractiveTerminalResult: Sendable, Hashable {
    public let id: String?
    public let state: PTYProcessState?
    public let screen: String

    public init(id: String? = nil, state: PTYProcessState? = nil, screen: String = "") {
        self.id = id
        self.state = state
        self.screen = screen
    }
}

/// Surface capability for `interactive_terminal`.
///
/// Print mode and remote server sessions intentionally leave this nil. The tool
/// then returns a model-visible refusal instead of starting a child whose stdin
/// can never receive a user's keystrokes. The inline CLI installs the PTY-backed
/// provider below and additionally routes the live terminal's input to it.
public protocol InteractiveTerminalProvider: Sendable {
    func execute(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult
}

/// A synchronous input handoff used by the inline coordinator.
///
/// The TUI's input callback is synchronous and main-actor isolated, while the PTY
/// service is an actor. This box keeps the hot path nonblocking: it snapshots a
/// handler under a mutex and the handler schedules the actor hop.
public final class InteractiveTerminalInputRouter: @unchecked Sendable {
    private let handler = Mutex<(@Sendable ([UInt8]) -> Void)?>(nil)

    public init() {}

    public func install(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    public func clear() {
        handler.withLock { $0 = nil }
    }

    @discardableResult
    public func route(_ bytes: [UInt8]) -> Bool {
        let sink = handler.withLock { $0 }
        guard let sink else { return false }
        sink(bytes)
        return true
    }
}

/// A PTY-backed inline provider. It keeps one VT screen per terminal id and
/// exposes the latest screen rather than unbounded raw output to the model.
public actor PTYInteractiveTerminalProvider: InteractiveTerminalProvider {
    public typealias ScreenHandler = @Sendable (String, String, Bool) async -> Void

    private final class Session {
        let id: String
        var screen: VTScreen
        var outputWasDropped = false
        var streamTask: Task<Void, Never>?

        init(id: String, size: PTYSize) {
            self.id = id
            self.screen = VTScreen(columns: size.columns, rows: size.rows)
        }
    }

    private let service: PTYService
    public let inputRouter: InteractiveTerminalInputRouter
    private var screenHandler: ScreenHandler?
    private var sessions: [String: Session] = [:]
    private var activeID: String?

    public init(
        service: PTYService = PTYService(),
        inputRouter: InteractiveTerminalInputRouter = InteractiveTerminalInputRouter()
    ) {
        self.service = service
        self.inputRouter = inputRouter
    }

    /// Install the inline UI callback once the coordinator exists.
    public func setScreenHandler(_ handler: ScreenHandler?) {
        screenHandler = handler
    }

    public func execute(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        switch request.action {
        case .start:
            return try await start(request)
        case .read:
            return try await read(request)
        case .write:
            return try await write(request)
        case .resize:
            return try await resize(request)
        case .stop:
            return try await stop(request)
        }
    }

    /// Called by the inline input router. Returning false lets the normal editor
    /// reclaim input after the child exits.
    public func writeActive(_ bytes: [UInt8]) async -> Bool {
        guard let activeID else { return false }
        return await service.write(sessionID: activeID, bytes: bytes)
    }

    public func shutdown() async {
        inputRouter.clear()
        activeID = nil
        await service.shutdown()
    }

    private static func shellEnvironment(_ environment: PTYEnvironment) -> ShellEnvironment {
        ShellEnvironment(
            base: environment.base == .inherited ? .inherited : .empty,
            overrides: environment.overrides
        )
    }

    private static func ptyEnvironment(_ environment: ShellEnvironment) -> PTYEnvironment {
        PTYEnvironment(
            base: environment.base == .inherited ? .inherited : .empty,
            overrides: environment.overrides
        )
    }

    private func start(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        guard let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { throw InteractiveTerminalProviderError.missingCommand }

        let size = request.size ?? .fallback
        let rawCommand = ["/bin/bash", "-lc", command]
        let plan = try request.sandbox?.plan(
            role: .pty,
            command: rawCommand,
            workingDirectory: FilePath(request.workingDirectory),
            environment: Self.shellEnvironment(request.environment)
        )
        let id = try await service.start(.init(
            command: plan.map { [$0.executable.string] + $0.arguments } ?? rawCommand,
            workingDirectory: plan?.workingDirectory.string ?? request.workingDirectory,
            environment: plan.map { Self.ptyEnvironment($0.environment) } ?? request.environment,
            size: size
        ))
        let attachment = try await service.beginAttach(sessionID: id)
        let session = Session(id: id, size: size)
        sessions[id] = session
        activeID = id
        inputRouter.install { [weak self] bytes in
            Task { [weak self] in _ = await self?.writeActive(bytes) }
        }

        for event in attachment.replay { apply(event, to: session) }
        let stream = try await service.activate(sessionID: id, attachmentID: attachment.id)
        session.streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.apply(event, toSessionID: id)
            }
        }
        await publish(session)
        return try await result(for: id)
    }

    private func read(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        guard let id = request.id, let session = sessions[id] else {
            throw InteractiveTerminalProviderError.missingSession
        }
        await publish(session)
        return try await result(for: id)
    }

    private func write(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        guard let id = request.id, sessions[id] != nil else {
            throw InteractiveTerminalProviderError.missingSession
        }
        guard let input = request.input else { throw InteractiveTerminalProviderError.missingInput }
        guard await service.write(sessionID: id, bytes: Array(input.utf8)) else {
            throw InteractiveTerminalProviderError.notRunning
        }
        return try await result(for: id)
    }

    private func resize(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        guard let id = request.id, sessions[id] != nil, let size = request.size else {
            throw InteractiveTerminalProviderError.missingSession
        }
        guard await service.resize(sessionID: id, size: size) else {
            throw InteractiveTerminalProviderError.notRunning
        }
        return try await result(for: id)
    }

    private func stop(_ request: InteractiveTerminalRequest) async throws -> InteractiveTerminalResult {
        guard let id = request.id, sessions[id] != nil else {
            throw InteractiveTerminalProviderError.missingSession
        }
        guard await service.stop(sessionID: id) else {
            throw InteractiveTerminalProviderError.notRunning
        }
        if activeID == id {
            activeID = nil
            inputRouter.clear()
        }
        return try await result(for: id)
    }

    private func result(for id: String) async throws -> InteractiveTerminalResult {
        guard let session = sessions[id], let snapshot = await service.snapshot(sessionID: id) else {
            throw InteractiveTerminalProviderError.missingSession
        }
        return InteractiveTerminalResult(id: id, state: snapshot.state, screen: renderedScreen(for: session))
    }

    private func apply(_ event: PTYEvent, to session: Session) {
        switch event {
        case .output(_, let bytes): session.screen.feed(bytes)
        case .gap:
            // A VT screen reconstructed from a suffix is not authoritative:
            // the missing prefix may have moved the cursor, changed the style,
            // or switched buffers. Start a fresh model and tell the caller why.
            session.screen = VTScreen(columns: session.screen.columns, rows: session.screen.rows)
            session.outputWasDropped = true
        case .exited: break
        }
    }

    private func apply(_ event: PTYEvent, toSessionID id: String) async {
        guard let session = sessions[id] else { return }
        apply(event, to: session)
        let running: Bool
        switch event {
        case .exited: running = false
        default: running = true
        }
        if !running, activeID == id {
            activeID = nil
            inputRouter.clear()
        }
        await publish(session, running: running)
    }

    private func publish(_ session: Session, running: Bool? = nil) async {
        guard let screenHandler else { return }
        let snapshot = await service.snapshot(sessionID: session.id)
        await screenHandler(
            session.id,
            renderedScreen(for: session),
            running ?? (snapshot?.state == .running)
        )
    }

    private func renderedScreen(for session: Session) -> String {
        guard session.outputWasDropped else { return session.screen.text }
        return "[terminal output truncated; screen starts at the retained window]\n" + session.screen.text
    }
}

public enum InteractiveTerminalProviderError: Error, Sendable, Equatable {
    case missingCommand
    case missingSession
    case missingInput
    case notRunning
}

/// The JSON-facing built-in tool. The provider is the capability boundary: nil
/// means print mode, remote server, or another surface without a live input
/// channel, and therefore produces a useful refusal rather than a wedged child.
public struct InteractiveTerminalTool: Tool {
    public init() {}

    public let name = "interactive_terminal"
    public let description = "Start and control an interactive PTY program. Inline mode also routes your keyboard to it."

    public var parameters: JSONSchema {
        .object(
            .required(
                "action",
                .string(
                    description: "One of start, read, write, resize, or stop",
                    enumValues: ["start", "read", "write", "resize", "stop"]
                )
            ),
            .optional("id", .string(description: "Terminal session id")),
            .optional("command", .string(description: "Shell command for start")),
            .optional("input", .string(description: "Text to write to the PTY")),
            .optional("columns", .number(description: "Terminal width in columns")),
            .optional("rows", .number(description: "Terminal height in rows"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            guard let provider = context.interactiveTerminal else {
                return ToolResult.error(
                    "interactive_terminal is unavailable here: this surface has no live terminal input channel. "
                        + "Use a non-interactive command, or run the inline CLI for interactive programs."
                )
            }
            let args = try ArgumentReader(tool: name, arguments: arguments)
            guard let action = InteractiveTerminalAction(rawValue: (try args.requiredString("action")).lowercased()) else {
                return ToolResult.error("Unknown interactive_terminal action.")
            }
            let size: PTYSize?
            let columns = try args.optionalInt("columns")
            let rows = try args.optionalInt("rows")
            if let columns, let rows { size = PTYSize(columns: columns, rows: rows) }
            else if columns != nil || rows != nil { return ToolResult.error("columns and rows must be supplied together.") }
            else { size = nil }

            let result = try await provider.execute(.init(
                action: action,
                id: try args.optionalString("id"),
                command: try args.optionalString("command"),
                input: try args.optionalString("input"),
                size: size,
                workingDirectory: context.workingDirectory.string,
                environment: Self.ptyEnvironment(context.environment),
                sandbox: context.processSandbox
            ))
            return Self.result(result, action: action)
        }
    }

    private static func ptyEnvironment(_ environment: ShellEnvironment) -> PTYEnvironment {
        PTYEnvironment(
            base: environment.base == .inherited ? .inherited : .empty,
            overrides: environment.overrides
        )
    }

    private static func result(_ result: InteractiveTerminalResult, action: InteractiveTerminalAction) -> ToolResult {
        var lines = ["interactive terminal " + action.rawValue]
        if let id = result.id { lines[0] += " " + id }
        if let state = result.state { lines[0] += " — " + state.rawValue }
        if !result.screen.isEmpty { lines.append(result.screen) }
        return ToolResult.text(
            lines.joined(separator: "\n"),
            details: .object([
                "id": result.id.map(JSONValue.string) ?? .null,
                "state": result.state.map { .string($0.rawValue) } ?? .null,
                "screen": .string(result.screen),
            ])
        )
    }
}
