// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Synchronization

/// The lifecycle state of one delegated subagent task.
public enum SubagentTaskStatus: String, Codable, Hashable, Sendable {
    case started
    case accepted
    case completed
    case failed
    case cancelled
}

/// The request sent by the `task` tool to the runtime that owns the session.
///
/// The request is deliberately independent of `DoMoHarness` and `DoMoServer`:
/// the tool target can describe delegation without depending on either the
/// session store or an HTTP transport.
public struct SubagentTaskRequest: Codable, Hashable, Sendable {
    public let taskID: String
    public let parentSessionID: String
    public let prompt: String
    public let agent: String?
    public let background: Bool

    public init(
        taskID: String,
        parentSessionID: String,
        prompt: String,
        agent: String? = nil,
        background: Bool = false
    ) {
        self.taskID = taskID
        self.parentSessionID = parentSessionID
        self.prompt = prompt
        self.agent = agent
        self.background = background
    }
}

/// The settled result returned by a delegated subagent.
public struct SubagentTaskResult: Codable, Hashable, Sendable {
    public let taskID: String
    public let childSessionID: String?
    public let status: SubagentTaskStatus
    public let output: String?
    public let error: String?

    public init(
        taskID: String,
        childSessionID: String? = nil,
        status: SubagentTaskStatus,
        output: String? = nil,
        error: String? = nil
    ) {
        self.taskID = taskID
        self.childSessionID = childSessionID
        self.status = status
        self.output = output
        self.error = error
    }

    public static func failure(
        taskID: String,
        childSessionID: String? = nil,
        _ error: String
    ) -> SubagentTaskResult {
        SubagentTaskResult(
            taskID: taskID,
            childSessionID: childSessionID,
            status: .failed,
            error: error
        )
    }
}

/// A typed delegation lifecycle event.
///
/// This is persisted as session metadata and projected through both the agent
/// and server event streams. Keeping the child session id and task id together
/// makes a result navigable and resumable rather than an opaque transcript row.
public struct SubagentTaskEvent: Codable, Hashable, Sendable {
    public let taskID: String
    public let childSessionID: String
    public let parentSessionID: String
    public let description: String
    public let status: SubagentTaskStatus
    public let output: String?
    public let error: String?
    public let depth: Int

    public init(
        taskID: String,
        childSessionID: String,
        parentSessionID: String,
        description: String,
        status: SubagentTaskStatus,
        output: String? = nil,
        error: String? = nil,
        depth: Int
    ) {
        self.taskID = taskID
        self.childSessionID = childSessionID
        self.parentSessionID = parentSessionID
        self.description = description
        self.status = status
        self.output = output
        self.error = error
        self.depth = depth
    }
}

/// The narrow bridge between the `task` tool and its owning runtime.
///
/// A coordinator is shared by the session's tool contexts. The closures are
/// installed by the server or another host after it constructs the contexts,
/// which avoids making `DoMoTools` know how a child harness is created.
public final class SubagentCoordinator: Sendable {
    public typealias Runner = @Sendable (SubagentTaskRequest) async -> SubagentTaskResult
    public typealias EventEmitter = @Sendable (SubagentTaskEvent) async -> Void

    private let runner: Mutex<Runner?>
    private let emitter: Mutex<EventEmitter?>

    public init() {
        self.runner = Mutex(nil)
        self.emitter = Mutex(nil)
    }

    public func setRunner(_ runner: Runner?) {
        self.runner.withLock { $0 = runner }
    }

    public func setEmitter(_ emitter: EventEmitter?) {
        self.emitter.withLock { $0 = emitter }
    }

    public func run(_ request: SubagentTaskRequest) async -> SubagentTaskResult {
        guard let runner = runner.withLock({ $0 }) else {
            return .failure(taskID: request.taskID, "Subagent runtime is unavailable")
        }
        return await runner(request)
    }

    public func emit(_ event: SubagentTaskEvent) async {
        guard let emitter = emitter.withLock({ $0 }) else { return }
        await emitter(event)
    }
}
