// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Session-scoped background processes for the tool suite. This deliberately
// stays in DoMoExec: it shares the shell environment and subprocess teardown
// rules with the one-shot Shell implementation, while DoMoTools only sees the
// small actor API it needs.

import DoMoCore
import Foundation
import Subprocess
import SystemPackage

/// A bounded snapshot of one background process.
public struct BackgroundProcessSnapshot: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case running
        case exited
        case terminated
        case failed
    }

    public let id: String
    public let state: State
    public let exitCode: Int32?
    public let output: String
    public let truncated: Bool

    public init(
        id: String,
        state: State,
        exitCode: Int32? = nil,
        output: String = "",
        truncated: Bool = false
    ) {
        self.id = id
        self.state = state
        self.exitCode = exitCode
        self.output = output
        self.truncated = truncated
    }
}

/// Owns background children for one tool context. The actor provides stable IDs,
/// serialized polling/writes, bounded output, and process-group teardown. A
/// context gets one manager, so a new tool call can poll a process started by an
/// earlier call without sharing children across sessions.
public actor BackgroundProcessManager {
    private static let maximumOutputBytes = 64 * 1024
    private static let terminationGrace: Duration = .seconds(2)

    private final class Job {
        let id: String
        let outgoing: AsyncStream<[UInt8]>.Continuation
        var task: Task<Void, Never>?
        var state: BackgroundProcessSnapshot.State = .running
        var exitCode: Int32?
        var output: [UInt8] = []
        var truncated = false

        init(id: String, outgoing: AsyncStream<[UInt8]>.Continuation) {
            self.id = id
            self.outgoing = outgoing
        }

        func append(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            output.append(contentsOf: bytes)
            if output.count > BackgroundProcessManager.maximumOutputBytes {
                output.removeFirst(output.count - BackgroundProcessManager.maximumOutputBytes)
                truncated = true
            }
        }

        func snapshot(clearOutput: Bool) -> BackgroundProcessSnapshot {
            let snapshot = BackgroundProcessSnapshot(
                id: id,
                state: state,
                exitCode: exitCode,
                output: String(decoding: output, as: UTF8.self),
                truncated: truncated
            )
            if clearOutput {
                output.removeAll(keepingCapacity: true)
                truncated = false
            }
            return snapshot
        }
    }

    private var jobs: [String: Job] = [:]

    public init() {}

    /// Start `command` through bash in the supplied sandbox working directory.
    /// The returned snapshot is immediately `running`; output arrives through
    /// subsequent `poll` calls.
    public func start(
        _ command: String,
        workingDirectory: FilePath,
        environment: ShellEnvironment
    ) async throws(DoMoError) -> BackgroundProcessSnapshot {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DoMoError(.toolExecution(tool: "background_process"), "command must not be empty")
        }

        let id = UUIDv7.generate().description
        let (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        let job = Job(id: id, outgoing: outgoingContinuation)
        jobs[id] = job

        let task = Task { [weak self] in
            let state: BackgroundProcessSnapshot.State
            var exitCode: Int32?
            do {
                var platformOptions = PlatformOptions()
                platformOptions.createSession = true
                platformOptions.teardownSequence = [
                    .send(
                        signal: .terminate,
                        toProcessGroup: true,
                        allowedDurationToNextStep: BackgroundProcessManager.terminationGrace
                    )
                ]
                var configuration = Subprocess.Configuration(
                    executable: .name("bash"),
                    arguments: ["-c", command],
                    environment: environment.subprocessEnvironment,
                    platformOptions: platformOptions
                )
                configuration.workingDirectory = .init(workingDirectory.string)

                let result = try await Subprocess.run(
                    configuration,
                    input: .inputWriter,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    let writerTask = Task {
                        let writer = execution.standardInputWriter
                        do {
                            for await bytes in outgoing {
                                var offset = 0
                                while offset < bytes.count {
                                    let written = try await writer.write(Array(bytes[offset...]))
                                    guard written > 0 else { break }
                                    offset += written
                                }
                            }
                        } catch {
                            // The child may close stdin while the manager is still
                            // holding the write continuation; its exit state is the
                            // useful result, not a broken-pipe diagnostic.
                        }
                        try? await writer.finish()
                    }
                    let stdoutTask = Task { [weak self] in
                        do {
                            for try await chunk in execution.standardOutput {
                                let bytes: [UInt8] = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                                await self?.append(id: id, bytes: bytes)
                            }
                        } catch {}
                    }
                    let stderrTask = Task { [weak self] in
                        do {
                            for try await chunk in execution.standardError {
                                let bytes: [UInt8] = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                                await self?.append(id: id, bytes: bytes)
                            }
                        } catch {}
                    }

                    await withTaskCancellationHandler(operation: {
                        await stdoutTask.value
                        await stderrTask.value
                        writerTask.cancel()
                        await writerTask.value
                    }, onCancel: {
                        stdoutTask.cancel()
                        stderrTask.cancel()
                        writerTask.cancel()
                    })
                }
                switch result.terminationStatus {
                case .exited(let code):
                    state = .exited
                    exitCode = code
                case .signaled:
                    state = Task.isCancelled ? .terminated : .failed
                }
            } catch is CancellationError {
                state = .terminated
            } catch {
                state = Task.isCancelled ? .terminated : .failed
                await self?.append(
                    id: id,
                    bytes: Array("background process failed: \(error)\n".utf8)
                )
            }
            await self?.finish(id: id, state: state, exitCode: exitCode)
        }
        job.task = task
        return job.snapshot(clearOutput: false)
    }

    /// Poll a process and clear the returned output window by default.
    public func poll(id: String, clearOutput: Bool = true) -> BackgroundProcessSnapshot? {
        jobs[id]?.snapshot(clearOutput: clearOutput)
    }

    /// Write UTF-8 bytes to a running process's stdin.
    @discardableResult
    public func write(id: String, input: String) -> Bool {
        guard let job = jobs[id], job.state == .running else { return false }
        job.outgoing.yield(Array(input.utf8))
        return true
    }

    /// Stop one child and wait until swift-subprocess has reaped it.
    @discardableResult
    public func stop(id: String) async -> Bool {
        guard let job = jobs[id], job.state == .running else { return false }
        job.outgoing.finish()
        job.task?.cancel()
        if let task = job.task { await task.value }
        return true
    }

    /// Stop every child owned by this session.
    public func shutdown() async {
        let runningIDs = jobs.values.filter { $0.state == .running }.map(\.id)
        for id in runningIDs {
            _ = await stop(id: id)
        }
    }

    private func append(id: String, bytes: [UInt8]) {
        jobs[id]?.append(bytes)
    }

    private func finish(id: String, state: BackgroundProcessSnapshot.State, exitCode: Int32?) {
        guard let job = jobs[id] else { return }
        job.state = state
        job.exitCode = exitCode
        job.outgoing.finish()
    }
}
