// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Darwin)
// macOS 10.15–25 exports this non-deprecated-in-practice spelling, while the
// SDK now marks the newer POSIX name as macOS 26-only. Naming the symbol here
// keeps the package's macOS 15 deployment target honest without a deprecation
// warning promoted to an error.
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func domoPosixSpawnAddChdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ directory: UnsafePointer<CChar>
) -> Int32
#endif

/// The environment base used by a PTY child.
///
/// This intentionally mirrors the two environment intents in `ShellEnvironment`
/// without making the terminal target depend on `DoMoExec`: a PTY is a lower-level
/// primitive that the shell and the server can both own.
public struct PTYEnvironment: Sendable, Hashable {
    public enum Base: Sendable, Hashable {
        case inherited
        case empty
    }

    public var base: Base
    public var overrides: [String: String?]

    public init(base: Base = .inherited, overrides: [String: String?] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    public static let inherit = PTYEnvironment()

    public static func custom(_ values: [String: String]) -> PTYEnvironment {
        PTYEnvironment(base: .empty, overrides: values.mapValues { $0 })
    }
}

/// A terminal window size passed to a PTY child.
public struct PTYSize: Sendable, Hashable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, min(columns, Int(UInt16.max)))
        self.rows = max(1, min(rows, Int(UInt16.max)))
    }

    public static let fallback = PTYSize(columns: 80, rows: 24)
}

/// Everything needed to start one interactive child.
public struct PTYLaunchConfiguration: Sendable, Hashable {
    public var command: [String]
    public var workingDirectory: String
    public var environment: PTYEnvironment
    public var size: PTYSize

    public init(
        command: [String],
        workingDirectory: String,
        environment: PTYEnvironment = .inherit,
        size: PTYSize = .fallback
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.size = size
    }
}

public enum PTYError: Error, Sendable, Equatable {
    case emptyCommand
    case invalidWorkingDirectory
    case sessionNotFound(String)
    case attachmentNotFound(String)
    case tooManyAttachments
    case forkFailed(Int32)
    case descriptorFailed(Int32)
}

public enum PTYProcessState: String, Sendable, Hashable, Codable {
    case running
    case exited
    case terminated
    case failed
}

/// The wait status exposed after the child has been reaped.
public struct PTYExitStatus: Sendable, Hashable, Codable {
    public let state: PTYProcessState
    public let code: Int32?
    public let signal: Int32?

    fileprivate init(waitStatus: Int32, terminated: Bool) {
        let signalBits = waitStatus & 0x7f
        if signalBits == 0 {
            self.state = terminated ? .terminated : .exited
            self.code = (waitStatus >> 8) & 0xff
            self.signal = nil
        } else {
            self.state = terminated ? .terminated : .failed
            self.code = nil
            self.signal = signalBits
        }
    }
}

/// One event in a PTY session.
///
/// Output carries a monotonically increasing sequence number. The number is a
/// chunk cursor, not a byte offset: clients can concatenate the bytes while the
/// server can still prove that a replay and an activation cover a continuous
/// event interval.
public enum PTYEvent: Sendable, Hashable {
    case output(sequence: UInt64, bytes: [UInt8])
    /// The retained window could not cover all output between an attachment's
    /// replay and activation. A client should resync its screen from the next
    /// retained bytes rather than silently presenting a false transcript.
    case gap(beforeSequence: UInt64)
    case exited(PTYExitStatus)
}

/// The first half of a PTY subscription.
///
/// `beginAttach()` takes a replay snapshot and reserves an activation cursor in
/// one actor turn. Bytes arriving before `activate()` are held in a bounded queue
/// keyed by `id`, which closes the replay/subscription race without pretending an
/// SSE stream can carry client input.
public struct PTYAttachment: Sendable, Hashable {
    public let id: String
    public let replay: [PTYEvent]
    public let nextSequence: UInt64
    public let droppedOutput: Bool

    fileprivate init(id: String, replay: [PTYEvent], nextSequence: UInt64, droppedOutput: Bool) {
        self.id = id
        self.replay = replay
        self.nextSequence = nextSequence
        self.droppedOutput = droppedOutput
    }
}

/// A level-triggered session snapshot used by the tool and server adapters.
public struct PTYSnapshot: Sendable, Hashable, Codable {
    public let id: String
    public let state: PTYProcessState
    public let exitStatus: PTYExitStatus?
    public let retainedByteCount: Int
    public let retainedOutputTruncated: Bool
    public let nextSequence: UInt64

    fileprivate init(
        id: String,
        state: PTYProcessState,
        exitStatus: PTYExitStatus?,
        retainedByteCount: Int,
        retainedOutputTruncated: Bool,
        nextSequence: UInt64
    ) {
        self.id = id
        self.state = state
        self.exitStatus = exitStatus
        self.retainedByteCount = retainedByteCount
        self.retainedOutputTruncated = retainedOutputTruncated
        self.nextSequence = nextSequence
    }
}

/// Owns interactive children and their bounded output history.
///
/// The service is deliberately an actor. PTY reads happen on a dispatch source,
/// while tool calls, REST handlers, replay reservations, and subscriber
/// activation arrive on unrelated tasks. All of those paths converge here before
/// they mutate the retained ring or the attachment table.
public actor PTYService {
    public static let defaultRetainedBytes = 256 * 1024

    private struct OutputRing {
        var events: [PTYEvent] = []
        var byteCount = 0
        var truncated = false

        mutating func append(sequence: UInt64, bytes: [UInt8], capacity: Int) {
            guard !bytes.isEmpty else { return }
            let retained = bytes.count > capacity ? Array(bytes.suffix(capacity)) : bytes
            if retained.count != bytes.count { truncated = true }
            events.append(.output(sequence: sequence, bytes: retained))
            byteCount += retained.count

            while byteCount > capacity, !events.isEmpty {
                guard case .output(_, let firstBytes) = events[0] else {
                    events.removeFirst()
                    continue
                }
                let overflow = byteCount - capacity
                if firstBytes.count <= overflow {
                    events.removeFirst()
                    byteCount -= firstBytes.count
                    truncated = true
                } else {
                    events[0] = .output(
                        sequence: sequenceOf(events[0]),
                        bytes: Array(firstBytes.dropFirst(overflow))
                    )
                    byteCount -= overflow
                    truncated = true
                }
            }
        }

        private func sequenceOf(_ event: PTYEvent) -> UInt64 {
            guard case .output(let sequence, _) = event else { return 0 }
            return sequence
        }
    }

    private struct PendingAttachment {
        var events: [PTYEvent] = []
        var byteCount = 0
        var dropped = false
        var gapSequence: UInt64?
        let finishAfterReplay: Bool
    }

    private final class Job {
        let id: String
        let master: Int32
        let pid: Int32
        let capacity: Int
        var source: DispatchSourceBox?
        var reapTask: Task<Void, Never>?
        var state: PTYProcessState = .running
        var exitStatus: PTYExitStatus?
        var stopRequested = false
        var nextSequence: UInt64 = 0
        var ring = OutputRing()
        var pending: [String: PendingAttachment] = [:]
        var subscribers: [String: AsyncStream<PTYEvent>.Continuation] = [:]

        init(id: String, master: Int32, pid: Int32, capacity: Int) {
            self.id = id
            self.master = master
            self.pid = pid
            self.capacity = capacity
        }
    }

    /// C-owned launch arguments prepared before `posix_spawn`. The child must not
    /// touch Swift arrays, Foundation, or ARC: on macOS Objective-C can abort a
    /// multithreaded child that reaches a lazy runtime initializer after fork.
    private struct ChildPlan {
        let executable: UnsafeMutablePointer<CChar>
        let workingDirectory: UnsafeMutablePointer<CChar>
        let arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let argumentCount: Int
        let environmentCount: Int

        func dispose() {
            for index in 0..<argumentCount {
                if let pointer = arguments.advanced(by: index).pointee { free(pointer) }
            }
            for index in 0..<environmentCount {
                if let pointer = environment.advanced(by: index).pointee { free(pointer) }
            }
            free(executable)
            free(workingDirectory)
            arguments.deinitialize(count: argumentCount + 1)
            arguments.deallocate()
            environment.deinitialize(count: environmentCount + 1)
            environment.deallocate()
        }
    }

    private let maximumRetainedBytes: Int
    private let maximumPendingAttachments: Int
    private let readQueue: DispatchQueue
    private var jobs: [String: Job] = [:]

    public init(
        maximumRetainedBytes: Int = PTYService.defaultRetainedBytes,
        maximumPendingAttachments: Int = 32,
        readQueue: DispatchQueue = DispatchQueue(label: "domocode.pty.read")
    ) {
        self.maximumRetainedBytes = max(1, maximumRetainedBytes)
        self.maximumPendingAttachments = max(1, maximumPendingAttachments)
        self.readQueue = readQueue
    }

    /// Start one child attached to a real controlling terminal.
    public func start(_ configuration: PTYLaunchConfiguration) throws -> String {
        guard let commandName = configuration.command.first,
              !commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PTYError.emptyCommand
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: configuration.workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PTYError.invalidWorkingDirectory
        }

        let environment = Self.effectiveEnvironment(configuration.environment)
        let executable = Self.resolveExecutable(configuration.command[0], environment: environment)
        let plan = Self.makeChildPlan(
            command: configuration.command,
            executable: executable,
            workingDirectory: configuration.workingDirectory,
            environment: environment
        )

        guard let opened = Self.openPTYMaster() else {
            let failure = errno
            plan.dispose()
            throw PTYError.forkFailed(failure)
        }
        let master = opened.master
        var window = winsize()
        window.ws_col = UInt16(configuration.size.columns)
        window.ws_row = UInt16(configuration.size.rows)
        let slaveForResize = opened.slaveName.withCString { open($0, O_RDWR | O_NOCTTY) }
        guard slaveForResize >= 0,
              ioctl(slaveForResize, Self.windowSizeRequest, &window) == 0
        else {
            let failure = errno
            if slaveForResize >= 0 { _ = close(slaveForResize) }
            _ = close(master)
            plan.dispose()
            throw PTYError.descriptorFailed(failure)
        }
        _ = close(slaveForResize)

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            let failure = errno
            _ = close(master)
            plan.dispose()
            throw PTYError.descriptorFailed(failure)
        }
        defer { _ = posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            let failure = errno
            _ = close(master)
            plan.dispose()
            throw PTYError.descriptorFailed(failure)
        }
        defer { _ = posix_spawnattr_destroy(&attributes) }

        var actionResult: Int32 = 0
        opened.slaveName.withCString { slave in
            configuration.workingDirectory.withCString { directory in
                actionResult = Self.addChdir(&actions, directory)
                // Opening the slave AFTER `POSIX_SPAWN_SETSID` makes it the
                // child's controlling terminal. This avoids `forkpty`'s unsafe
                // post-fork Swift path while preserving job-control semantics.
                if actionResult == 0 {
                    actionResult = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slave, O_RDWR, 0)
                }
                if actionResult == 0 {
                    actionResult = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
                }
                if actionResult == 0 {
                    actionResult = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
                }
                if actionResult == 0 {
                    actionResult = posix_spawn_file_actions_addclose(&actions, master)
                }
            }
        }
        guard actionResult == 0 else {
            let failure = Int32(actionResult)
            _ = close(master)
            plan.dispose()
            throw PTYError.descriptorFailed(failure)
        }

        #if canImport(Darwin)
        let spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        let spawnFlags = Int16(POSIX_SPAWN_SETSID)
        #endif
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
            let failure = errno
            _ = close(master)
            plan.dispose()
            throw PTYError.descriptorFailed(failure)
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid,
            plan.executable,
            &actions,
            &attributes,
            plan.arguments,
            plan.environment
        )
        plan.dispose()
        guard spawnResult == 0, pid > 0 else {
            let failure = spawnResult == 0 ? errno : Int32(spawnResult)
            _ = close(master)
            throw PTYError.forkFailed(failure)
        }

        let childPID = Int32(pid)

        guard NonblockingFileDescriptor.makeNonblocking(master) != nil else {
            let failure = errno
            _ = kill(pid, SIGKILL)
            _ = close(master)
            _ = waitpid(pid, nil, 0)
            throw PTYError.descriptorFailed(failure)
        }

        let id = UUID().uuidString
        let job = Job(id: id, master: master, pid: childPID, capacity: maximumRetainedBytes)
        jobs[id] = job

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        source.setEventHandler { [weak self] in
            let result = Self.readAvailable(master)
            guard !result.chunks.isEmpty || result.ended else { return }
            Task { [weak self] in
                await self?.handleReadable(
                    sessionID: id,
                    chunks: result.chunks,
                    ended: result.ended
                )
            }
        }
        source.setCancelHandler {
            _ = close(master)
        }
        job.source = DispatchSourceBox(source)
        source.resume()
        return id
    }

    /// Reserve a replay cursor and return all currently retained output.
    public func beginAttach(sessionID: String) throws -> PTYAttachment {
        guard let job = jobs[sessionID] else { throw PTYError.sessionNotFound(sessionID) }
        guard job.pending.count < maximumPendingAttachments else {
            throw PTYError.tooManyAttachments
        }
        let attachmentID = UUID().uuidString
        let alreadyExited = job.exitStatus != nil
        var replay: [PTYEvent] = []
        if job.ring.truncated,
           case .output(let sequence, _) = job.ring.events.first
        {
            replay.append(.gap(beforeSequence: sequence))
        }
        replay.append(contentsOf: job.ring.events)
        if let exitStatus = job.exitStatus {
            replay.append(.exited(exitStatus))
        }
        job.pending[attachmentID] = PendingAttachment(finishAfterReplay: alreadyExited)
        return PTYAttachment(
            id: attachmentID,
            replay: replay,
            nextSequence: job.nextSequence,
            droppedOutput: job.ring.truncated
        )
    }

    /// Abandon the first half of an attach when its caller will not activate it.
    ///
    /// Reservations retain output until activation, so adapters must cancel a
    /// failed or disconnected handoff instead of leaving a pending subscription
    /// behind. The service also caps reservations defensively.
    @discardableResult
    public func cancelAttach(sessionID: String, attachmentID: String) -> Bool {
        guard let job = jobs[sessionID] else { return false }
        return job.pending.removeValue(forKey: attachmentID) != nil
    }

    /// Complete the second half of a replay-then-activate subscription.
    public func activate(sessionID: String, attachmentID: String) throws -> AsyncStream<PTYEvent> {
        guard let job = jobs[sessionID] else { throw PTYError.sessionNotFound(sessionID) }
        guard let pending = job.pending.removeValue(forKey: attachmentID) else {
            throw PTYError.attachmentNotFound(attachmentID)
        }

        let (stream, continuation) = AsyncStream<PTYEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        if pending.dropped {
            continuation.yield(.gap(beforeSequence: pending.gapSequence ?? job.nextSequence))
        }
        for event in pending.events { continuation.yield(event) }

        if pending.finishAfterReplay || job.exitStatus != nil {
            continuation.finish()
            return stream
        }

        job.subscribers[attachmentID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeSubscriber(sessionID: sessionID, subscriberID: attachmentID)
            }
        }
        return stream
    }

    /// Write bytes to the PTY's stdin.
    @discardableResult
    public func write(sessionID: String, bytes: [UInt8]) -> Bool {
        guard let job = jobs[sessionID], job.state == .running, !bytes.isEmpty else { return false }
        var offset = 0
        let result = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < raw.count {
                let written = Self.write(job.master, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR { continue }
                return false
            }
            return true
        }
        return result
    }

    /// Resize a running child and notify its process group.
    @discardableResult
    public func resize(sessionID: String, size: PTYSize) -> Bool {
        guard let job = jobs[sessionID], job.state == .running else { return false }
        var window = winsize()
        window.ws_col = UInt16(size.columns)
        window.ws_row = UInt16(size.rows)
        guard ioctl(job.master, Self.windowSizeRequest, &window) == 0 else { return false }
        _ = kill(-job.pid, SIGWINCH)
        return true
    }

    /// Ask a child and its process group to terminate.
    @discardableResult
    public func stop(sessionID: String) -> Bool {
        guard let job = jobs[sessionID], job.state == .running else { return false }
        job.stopRequested = true
        job.source?.cancel()
        job.source = nil
        Self.terminate(job.pid)
        beginReap(job)
        return true
    }

    public func snapshot(sessionID: String) -> PTYSnapshot? {
        guard let job = jobs[sessionID] else { return nil }
        return PTYSnapshot(
            id: job.id,
            state: job.state,
            exitStatus: job.exitStatus,
            retainedByteCount: job.ring.byteCount,
            retainedOutputTruncated: job.ring.truncated,
            nextSequence: job.nextSequence
        )
    }

    /// Stop every live child. Completed jobs remain inspectable until the service
    /// itself is released, which lets a final tool call report the exit status.
    public func shutdown() async {
        let running = jobs.values.filter { $0.state == .running }.map(\.id)
        for id in running { _ = stop(sessionID: id) }
        let reapTasks = jobs.values.compactMap(\.reapTask)
        for task in reapTasks { await task.value }
    }

    // MARK: Dispatch/read boundary

    private struct ReadResult: Sendable {
        var chunks: [[UInt8]] = []
        var ended = false
    }

    private static func readAvailable(_ descriptor: Int32) -> ReadResult {
        var result = ReadResult()
        while true {
            switch NonblockingFileDescriptor.read(descriptor) {
            case .bytes(let bytes): result.chunks.append(bytes)
            case .wouldBlock: return result
            case .endOfFile:
                result.ended = true
                return result
            case .error(let error):
                // A PTY commonly reports EIO instead of EOF after the slave closes.
                // Both mean there can be no more output for this session.
                result.ended = error == EIO || error == 0
                return result
            }
        }
    }

    private func handleReadable(sessionID: String, chunks: [[UInt8]], ended: Bool) {
        guard let job = jobs[sessionID], job.state == .running else { return }
        for bytes in chunks { appendOutput(bytes, to: job) }
        if ended {
            job.source?.cancel()
            job.source = nil
            beginReap(job)
        }
    }

    private func appendOutput(_ bytes: [UInt8], to job: Job) {
        guard !bytes.isEmpty, job.state == .running else { return }
        let sequence = job.nextSequence
        job.nextSequence += 1
        job.ring.append(sequence: sequence, bytes: bytes, capacity: job.capacity)
        let event = PTYEvent.output(sequence: sequence, bytes: bytes)

        for subscriber in job.subscribers.values { subscriber.yield(event) }
        for attachmentID in job.pending.keys {
            appendPending(event, byteCount: bytes.count, to: &job.pending[attachmentID]!)
        }
    }

    private func appendPending(_ event: PTYEvent, byteCount: Int, to pending: inout PendingAttachment) {
        pending.events.append(event)
        pending.byteCount += byteCount
        while pending.byteCount > maximumRetainedBytes {
            guard !pending.events.isEmpty else { break }
            guard case .output(let sequence, let bytes) = pending.events[0] else {
                pending.events.removeFirst()
                continue
            }
            let overflow = pending.byteCount - maximumRetainedBytes
            if bytes.count <= overflow {
                pending.events.removeFirst()
                pending.byteCount -= bytes.count
                pending.dropped = true
                pending.gapSequence = sequence
            } else {
                pending.events[0] = .output(
                    sequence: sequence,
                    bytes: Array(bytes.dropFirst(overflow))
                )
                pending.byteCount -= overflow
                pending.dropped = true
                pending.gapSequence = sequence
            }
        }
    }

    private func finishPending(_ event: PTYEvent, for job: Job) {
        for attachmentID in job.pending.keys {
            appendPending(event, byteCount: 0, to: &job.pending[attachmentID]!)
        }
    }

    private func removeSubscriber(sessionID: String, subscriberID: String) {
        jobs[sessionID]?.subscribers.removeValue(forKey: subscriberID)
    }

    private func beginReap(_ job: Job) {
        guard job.reapTask == nil else { return }
        let pid = job.pid
        let sessionID = job.id
        let stopRequested = job.stopRequested
        job.reapTask = Task.detached { [weak self] in
            let status = Self.waitForChild(pid, terminateIfNeeded: stopRequested)
            await self?.didReap(sessionID: sessionID, waitStatus: status)
        }
    }

    private func didReap(sessionID: String, waitStatus: Int32) {
        guard let job = jobs[sessionID], job.exitStatus == nil else { return }
        let exit = PTYExitStatus(waitStatus: waitStatus, terminated: job.stopRequested)
        job.exitStatus = exit
        job.state = exit.state
        let event = PTYEvent.exited(exit)
        for subscriber in job.subscribers.values { subscriber.yield(event); subscriber.finish() }
        job.subscribers.removeAll()
        finishPending(event, for: job)
    }

    // MARK: Child setup

    private static func effectiveEnvironment(_ environment: PTYEnvironment) -> [String: String] {
        var values = environment.base == .inherited
            ? ProcessInfo.processInfo.environment
            : [:]
        for (key, value) in environment.overrides {
            if let value { values[key] = value }
            else { values.removeValue(forKey: key) }
        }
        return values
    }

    private static func openPTYMaster() -> (master: Int32, slaveName: String)? {
        #if canImport(Darwin)
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0,
              grantpt(master) == 0,
              unlockpt(master) == 0,
              let name = ptsname(master)
        else {
            if master >= 0 { _ = close(master) }
            return nil
        }
        return (master, String(cString: name))
        #else
        let master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        var unlock: Int32 = 0
        guard ioctl(master, UInt(0x4004_5431), &unlock) == 0 else {
            _ = close(master)
            return nil
        }
        var number: Int32 = 0
        guard ioctl(master, UInt(0x8004_5430), &number) == 0 else {
            _ = close(master)
            return nil
        }
        return (master, "/dev/pts/\(number)")
        #endif
    }

    private static func addChdir(
        _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
        _ directory: UnsafePointer<CChar>
    ) -> Int32 {
        #if canImport(Darwin)
        return domoPosixSpawnAddChdir(actions, directory)
        #else
        return posix_spawn_file_actions_addchdir_np(actions, directory)
        #endif
    }

    private static func resolveExecutable(_ command: String, environment: [String: String]) -> String {
        guard !command.contains("/") else { return command }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = directory.isEmpty
                ? command
                : String(directory) + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return command
    }

    private static func makeChildPlan(
        command: [String],
        executable: String,
        workingDirectory: String,
        environment: [String: String]
    ) -> ChildPlan {
        let argumentPointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: command.count + 1
        )
        for (index, argument) in command.enumerated() {
            argumentPointers.advanced(by: index).initialize(to: strdup(argument))
        }
        argumentPointers.advanced(by: command.count).initialize(to: nil)

        let environmentPairs = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        let environmentPointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: environmentPairs.count + 1
        )
        for (index, pair) in environmentPairs.enumerated() {
            environmentPointers.advanced(by: index).initialize(to: strdup(pair))
        }
        environmentPointers.advanced(by: environmentPairs.count).initialize(to: nil)

        return ChildPlan(
            executable: strdup(executable),
            workingDirectory: strdup(workingDirectory),
            arguments: argumentPointers,
            environment: environmentPointers,
            argumentCount: command.count,
            environmentCount: environmentPairs.count
        )
    }

    private static func terminate(_ pid: Int32) {
        guard pid > 1 else { return }
        _ = kill(-pid, SIGTERM)
        _ = kill(pid, SIGTERM)
    }

    private static func write(
        _ descriptor: Int32,
        _ buffer: UnsafeRawPointer,
        _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, buffer, count)
        #else
        return Musl.write(descriptor, buffer, count)
        #endif
    }

    private static func waitForChild(_ pid: Int32, terminateIfNeeded: Bool) -> Int32 {
        var status: Int32 = 0
        var sentKill = false
        let started = Date()
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result < 0, errno != EINTR { return status }
            if terminateIfNeeded,
               !sentKill,
               Date().timeIntervalSince(started) >= 2 {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
                sentKill = true
            }
            usleep(10_000)
        }
    }

    #if canImport(Darwin)
    private static let windowSizeRequest: UInt = 0x8008_7467 // TIOCSWINSZ
    #else
    private static let windowSizeRequest: UInt = 0x5414 // TIOCSWINSZ
    #endif
}
