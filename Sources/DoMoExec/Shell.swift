// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/harness/env/nodejs.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// Shell resolution order, the detached-session spawn, the process-group kill,
// the timeout validation bounds and the "killed processes report no exit code"
// convention are ported from `NodeExecutionEnv.exec` in
// `packages/agent/src/harness/env/nodejs.ts`, `createLocalBashOperations` in
// `packages/coding-agent/src/core/tools/bash.ts` and `killProcessTree` /
// `getShellConfig` in `packages/coding-agent/src/utils/shell.ts`.

import DoMoCore
import Foundation
import Subprocess
import SystemPackage

// MARK: - Environment

/// The environment a command runs under.
///
/// Two bases rather than one dictionary because "inherit and change three
/// variables" and "start from nothing" are different intents and the caller
/// should not have to reconstruct the parent environment to express the first.
/// Overrides carry `String?` so a key can be *removed*: pi's bash tool deletes
/// `PI_SESSION_ID` and friends before every spawn, and an override map that
/// cannot say "unset" makes that impossible to express.
public struct ShellEnvironment: Sendable, Hashable {
    public enum Base: Sendable, Hashable {
        /// Start from this process's environment.
        case inherited
        /// Start from nothing. `PATH` is then empty, so commands must be
        /// spelled absolutely or be shell builtins.
        case empty
    }

    public var base: Base
    public var overrides: [String: String?]

    public init(base: Base, overrides: [String: String?] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    /// This process's environment, unchanged.
    public static let inherit = ShellEnvironment(base: .inherited)

    /// This process's environment with `overrides` applied; a `nil` value unsets.
    public static func inherit(_ overrides: [String: String?]) -> ShellEnvironment {
        ShellEnvironment(base: .inherited, overrides: overrides)
    }

    /// Exactly these variables and nothing else.
    public static func custom(_ values: [String: String]) -> ShellEnvironment {
        ShellEnvironment(base: .empty, overrides: values.mapValues { $0 })
    }

    fileprivate var subprocessEnvironment: Subprocess.Environment {
        let mapped = Dictionary(
            uniqueKeysWithValues: overrides.map { (Subprocess.Environment.Key(stringLiteral: $0.key), $0.value) }
        )
        switch base {
        case .inherited:
            return Subprocess.Environment.inherit.updating(mapped)
        case .empty:
            return Subprocess.Environment.custom([:]).updating(mapped)
        }
    }
}

// MARK: - Input

/// What the command reads on its standard input.
public enum ShellInput: Sendable, Hashable {
    /// `/dev/null`. A command that reads stdin sees immediate end-of-file.
    case none
    case bytes([UInt8])

    public static func text(_ text: String) -> ShellInput { .bytes(Array(text.utf8)) }
}

// MARK: - Output limits

/// How much of each stream to keep.
///
/// A head *and* a tail, unlike pi, which keeps only the last 50KB. pi can
/// afford to: it spills the full output to a temp file and hands the model the
/// path. Nothing here writes to disk, so dropping the head loses the compile
/// error at the top of a 40MB build log for good. Splitting the same budget
/// keeps both ends of the interesting output.
///
/// The 50KB total is pi's `DEFAULT_MAX_BYTES`. pi's second limit — 2000 lines —
/// is deliberately not enforced at this layer: line counting belongs with the
/// formatting that renders the output, and this layer's contract is bytes.
public struct ShellOutputLimits: Sendable, Hashable {
    /// Bytes kept from the start of the stream.
    public var head: Int
    /// Bytes kept from the end of the stream.
    public var tail: Int

    public init(head: Int, tail: Int) {
        self.head = max(0, head)
        self.tail = max(0, tail)
    }

    public static let `default` = ShellOutputLimits(head: 12 * 1024, tail: 38 * 1024)
}

/// One captured stream, bounded.
///
/// Bytes rather than `String` because a command's output is not required to be
/// text — `cat` a JPEG, `git show` a binary blob — and decoding at capture time
/// would either throw away those bytes or lie about them. ``text`` does the
/// lossy decode for the common case; ``bytes`` is what actually came out.
public struct ShellStreamOutput: Sendable, Hashable {
    /// The first ``ShellOutputLimits/head`` bytes.
    public let head: [UInt8]
    /// The last ``ShellOutputLimits/tail`` bytes, excluding anything already in ``head``.
    public let tail: [UInt8]
    /// Every byte the stream produced, including the ones that were dropped.
    public let totalBytes: Int

    public init(head: [UInt8], tail: [UInt8], totalBytes: Int) {
        self.head = head
        self.tail = tail
        self.totalBytes = totalBytes
    }

    public static let empty = ShellStreamOutput(head: [], tail: [], totalBytes: 0)

    public var droppedBytes: Int { max(0, totalBytes - head.count - tail.count) }

    public var isTruncated: Bool { droppedBytes > 0 }

    /// The retained bytes, head then tail, with nothing inserted between them.
    ///
    /// Use this when the bytes are going to a file or a byte-oriented consumer;
    /// use ``text`` when a human or a model is going to read them.
    public var bytes: [UInt8] { head + tail }

    /// The retained bytes as UTF-8, with an explicit marker where bytes were dropped.
    ///
    /// Lossy by construction: invalid sequences become U+FFFD rather than
    /// failing, both because command output can be binary and because a
    /// truncation boundary lands mid-sequence roughly three times in four.
    public var text: String {
        guard isTruncated else {
            // Decoded as one buffer: head and tail are contiguous here, and
            // decoding them separately would split a multi-byte scalar that
            // happens to straddle the boundary into two replacement characters.
            return String(decoding: head + tail, as: UTF8.self)
        }
        return String(decoding: head, as: UTF8.self)
            + "\n[... \(droppedBytes) bytes omitted ...]\n"
            + String(decoding: tail, as: UTF8.self)
    }
}

// MARK: - Termination

/// How a command stopped.
public enum ShellTermination: Sendable, Hashable {
    case exited(Int32)
    case signaled(Int32)
}

// MARK: - Request

/// One command to run.
public struct ShellRequest: Sendable, Hashable {
    /// The command line, interpreted by the shell — pipes, redirection, globs
    /// and `&&` all work, which is the entire reason a shell is in the loop.
    public var command: String

    /// Where to run it. `nil` means this process's working directory.
    public var workingDirectory: FilePath?

    public var environment: ShellEnvironment

    public var standardInput: ShellInput

    /// Wall-clock budget. `nil` means no limit, matching pi's bash tool, whose
    /// `timeout` parameter is optional with no default.
    public var timeout: Duration?

    /// How long the process group gets between `SIGTERM` and `SIGKILL`.
    ///
    /// pi sends `SIGKILL` immediately and skips this. The grace exists so a
    /// well-behaved command can flush its output and remove its temp files;
    /// nothing is lost by it, because the kill still follows and the wait ends
    /// as soon as the process actually exits.
    public var terminationGracePeriod: Duration

    public var limits: ShellOutputLimits

    public init(
        _ command: String,
        workingDirectory: FilePath? = nil,
        environment: ShellEnvironment = .inherit,
        standardInput: ShellInput = .none,
        timeout: Duration? = nil,
        terminationGracePeriod: Duration = .seconds(2),
        limits: ShellOutputLimits = .default
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.limits = limits
    }
}

// MARK: - Result

/// What a finished command produced.
///
/// A non-zero exit is a *result*, not an error, because that is the split pi
/// draws: `ExecutionEnv.exec` returns the code and the bash tool decides that a
/// non-zero code deserves an exception. Deciding here would deny the caller the
/// output that explains the failure.
///
/// A timeout is also a result, which is a deliberate divergence: pi throws
/// `timeout:<n>` from `exec` and then reassembles the partial output in the
/// tool's catch block. Returning it keeps the partial output, the signal and
/// the elapsed time on one value instead of smuggling them through an error
/// message.
public struct ShellResult: Sendable, Hashable {
    public let termination: ShellTermination
    public let stdout: ShellStreamOutput
    public let stderr: ShellStreamOutput

    /// Whether the timeout fired and this process group was torn down.
    ///
    /// When true, ``termination`` describes the kill, not the command.
    public let timedOut: Bool

    public let duration: Duration

    /// The pid of the shell, which is also the process-group id — the spawn
    /// creates a new session, so the group contains the shell and everything it
    /// started.
    public let processIdentifier: Int32

    public init(
        termination: ShellTermination,
        stdout: ShellStreamOutput,
        stderr: ShellStreamOutput,
        timedOut: Bool,
        duration: Duration,
        processIdentifier: Int32
    ) {
        self.termination = termination
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.duration = duration
        self.processIdentifier = processIdentifier
    }

    /// The exit code, or `nil` if a signal killed the process.
    ///
    /// pi's `exitCode: number | null` — `null` is how a killed process is
    /// reported all the way up to the tool, which is why callers must handle
    /// the absence rather than see a synthesized `-1`.
    public var exitCode: Int32? {
        if case .exited(let code) = termination { return code }
        return nil
    }

    /// The signal number that killed the process, or `nil` if it exited.
    public var signal: Int32? {
        if case .signaled(let signal) = termination { return signal }
        return nil
    }

    public var isSuccess: Bool { !timedOut && termination == .exited(0) }

    public var isTruncated: Bool { stdout.isTruncated || stderr.isTruncated }
}

// MARK: - Shell

/// Runs a command line through a shell.
public protocol Shell: Sendable {
    /// Runs `request` to completion.
    ///
    /// Throws only when the command could not be run or was cancelled: a
    /// non-zero exit, a signal and a timeout all come back as a ``ShellResult``.
    ///
    /// Cancelling the calling task terminates the process group and throws
    /// ``DoMoError/Kind/cancelled``.
    ///
    /// `@concurrent` because this is a module seam. Under
    /// `NonisolatedNonsendingByDefault` a plain `nonisolated async func` runs on
    /// its caller's actor, and the caller here is eventually the main-actor TUI:
    /// draining two pipes and copying megabytes of output on the main actor
    /// stalls the renderer with no diagnostic. See the README, "Concurrency and
    /// isolation".
    @concurrent
    func run(_ request: ShellRequest) async throws(DoMoError) -> ShellResult
}

extension Shell {
    /// Runs `command` with defaults for everything else.
    public func run(_ command: String) async throws(DoMoError) -> ShellResult {
        try await run(ShellRequest(command))
    }
}

// MARK: - SubprocessShell

/// The swift-subprocess implementation of ``Shell``.
public struct SubprocessShell: Shell {
    /// The shell binary. Invoked as `<shell> -c <command>`.
    public let shellPath: FilePath

    /// Resolves the shell the way pi's `getShellConfig` does: an explicit path
    /// if given and present, else `/bin/bash`, else `bash` on `PATH`, else
    /// `/bin/sh`.
    ///
    /// The `PATH` scan is done in-process rather than by spawning `which`, as pi
    /// does. Spawning a subprocess to decide how to spawn subprocesses is a
    /// startup cost and a failure mode for no gain here, since the only thing pi
    /// gets from `which` is Termux and other exotic-filesystem handling that
    /// `access(2)` also covers.
    ///
    /// - Throws: ``DoMoError/Kind/configuration`` if `shellPath` was given and
    ///   does not exist. Falling back silently would run the user's command
    ///   under a shell they did not ask for, and their `shellPath` is usually
    ///   set precisely because the default shell is wrong for them.
    public init(shellPath: FilePath? = nil) throws(DoMoError) {
        if let shellPath {
            guard Self.isExecutable(shellPath) else {
                throw DoMoError(
                    .configuration,
                    "custom shell path not found: \(shellPath)"
                )
            }
            self.shellPath = shellPath
            return
        }
        self.shellPath = Self.resolveShellPath()
    }

    @concurrent
    public func run(_ request: ShellRequest) async throws(DoMoError) -> ShellResult {
        do {
            return try await execute(request)
        } catch let error as DoMoError {
            throw error
        } catch {
            throw DoMoError(
                wrapping: error,
                as: .toolExecution(tool: "shell"),
                "run `\(DoMoError.truncating(request.command, to: 120))`"
            )
        }
    }
}

// MARK: - SubprocessShell: execution

extension SubprocessShell {
    private func execute(_ request: ShellRequest) async throws -> ShellResult {
        if Task.isCancelled { throw DoMoError(.cancelled, "shell command cancelled") }

        var request = request
        request.timeout = try Self.validate(timeout: request.timeout)
        try Self.validate(workingDirectory: request.workingDirectory)

        var platformOptions = PlatformOptions()
        // Without a new session the child shares this process's group, and
        // every process-group signal below would land on the harness itself.
        platformOptions.createSession = true
        // This one covers task cancellation: swift-subprocess runs it from its
        // own cleanup handler when the enclosing task is cancelled. The timeout
        // path re-runs the same steps explicitly.
        platformOptions.teardownSequence = Self.teardownSteps(grace: request.terminationGracePeriod)

        // `.init(_:)` rather than a named `FilePath`: swift-subprocess re-exports
        // Darwin's `System.FilePath`, which is a different type from the
        // `SystemPackage.FilePath` this module's API and `DoMoError.file` speak.
        // Importing both would make every bare `FilePath` in this file
        // ambiguous, so the conversion rides on the contextual type instead.
        var configuration = Configuration(
            executable: .path(.init(shellPath.string)),
            arguments: ["-c", request.command],
            environment: request.environment.subprocessEnvironment,
            platformOptions: platformOptions
        )
        if let workingDirectory = request.workingDirectory {
            configuration.workingDirectory = .init(workingDirectory.string)
        }

        let started = ContinuousClock.now
        let outcome: (streams: DrainedStreams, status: TerminationStatus, pid: Int32)
        switch request.standardInput {
        case .none:
            let input: NoInput = .none
            outcome = try await Self.drive(configuration, input: input, request: request)
        case .bytes(let bytes):
            let input: ArrayInput = .array(bytes)
            outcome = try await Self.drive(configuration, input: input, request: request)
        }
        let duration = ContinuousClock.now - started

        // Cancellation is decided by the task's own flag, never by what came
        // back: the teardown makes the child look like an ordinary SIGKILL
        // victim, which is indistinguishable from a command the user's own
        // script killed. See `DoMoError.init(wrapping:as:_:cancelled:)`.
        if Task.isCancelled { throw DoMoError(.cancelled, "shell command cancelled") }

        let termination: ShellTermination
        switch outcome.status {
        case .exited(let code): termination = .exited(code)
        case .signaled(let signal): termination = .signaled(signal)
        }

        return ShellResult(
            termination: termination,
            stdout: outcome.streams.stdout,
            stderr: outcome.streams.stderr,
            timedOut: outcome.streams.timedOut,
            duration: duration,
            processIdentifier: outcome.pid
        )
    }

    /// Runs the configuration and drains both streams concurrently.
    ///
    /// Generic over the input type because swift-subprocess 0.5 encodes the
    /// input in `Execution`'s type: `NoInput` and `ArrayInput` produce different
    /// `Execution` instantiations, so this cannot be an `any InputProtocol`.
    private static func drive<Input: InputProtocol>(
        _ configuration: Configuration,
        input: Input,
        request: ShellRequest
    ) async throws -> (streams: DrainedStreams, status: TerminationStatus, pid: Int32) {
        let limits = request.limits
        let timeout = request.timeout
        let grace = request.terminationGracePeriod

        let result = try await Subprocess.run(
            configuration,
            input: input,
            output: .sequence,
            error: .sequence
        ) { execution in
            await withTaskGroup(of: DrainOutcome.self) { group in
                group.addTask {
                    .standardOutput(await drain(execution.standardOutput, limits: limits))
                }
                group.addTask {
                    .standardError(await drain(execution.standardError, limits: limits))
                }
                if let timeout {
                    group.addTask {
                        // `Task.sleep` throws only on cancellation, which is how
                        // the timer is retired once both streams have closed.
                        do { try await Task.sleep(for: timeout) } catch { return .timerRetired }
                        await execution.teardown(using: teardownSteps(grace: grace))
                        return .timerFired
                    }
                }

                var standardOutput: ShellStreamOutput?
                var standardError: ShellStreamOutput?
                var timedOut = false
                var retiredTimer = false
                // Every task is drained to completion rather than stopping at
                // the second stream, because the timer's verdict is what makes
                // a killed process distinguishable from one the command itself
                // killed, and it can arrive either side of the last read.
                while let outcome = await group.next() {
                    switch outcome {
                    case .standardOutput(let value): standardOutput = value
                    case .standardError(let value): standardError = value
                    case .timerFired: timedOut = true
                    case .timerRetired: break
                    }
                    if !retiredTimer, standardOutput != nil, standardError != nil {
                        retiredTimer = true
                        group.cancelAll()
                    }
                }

                return DrainedStreams(
                    stdout: standardOutput ?? .empty,
                    stderr: standardError ?? .empty,
                    timedOut: timedOut
                )
            }
        }

        return (result.closureOutput, result.terminationStatus, result.processIdentifier.value)
    }

    /// Reads one stream to end-of-file into a bounded buffer.
    ///
    /// Read failures end the stream instead of propagating. Once the process
    /// group has been killed the pipe reports whatever the kernel felt like —
    /// `EIO`, a cancelled async read — and none of it is the failure the caller
    /// cares about, which is the termination status. Throwing here would turn
    /// every timeout into an exception and discard the output collected so far.
    private static func drain(
        _ stream: SubprocessOutputSequence,
        limits: ShellOutputLimits
    ) async -> ShellStreamOutput {
        var buffer = BoundedByteBuffer(limits: limits)
        do {
            for try await chunk in stream {
                // The only unsafe construct in this module. `Buffer` exposes its
                // storage as a `RawSpan` too, but every stdlib accessor that
                // turns one back into an `Array` is gated on a newer OS than
                // this package's floor.
                let bytes: [UInt8] = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                buffer.append(bytes)
            }
        } catch {
            // Deliberately ignored; see the note above.
        }
        return buffer.finish()
    }
}

// MARK: - SubprocessShell: teardown

extension SubprocessShell {
    /// `SIGTERM` to the group, a grace period, then `SIGKILL` to the group.
    ///
    /// Both steps target the *group*, not the leader. Killing only the leader
    /// leaves anything it backgrounded alive still holding the write end of the
    /// output pipe, and the read that is draining that pipe then blocks until
    /// the orphan happens to exit — the exact hang a timeout exists to prevent.
    ///
    /// swift-subprocess appends the terminal `.kill` itself and inherits
    /// `toProcessGroup` from the last explicit step, so `SIGKILL` goes to the
    /// group too.
    fileprivate static func teardownSteps(grace: Duration) -> [TeardownStep] {
        [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: grace)]
    }
}

// MARK: - SubprocessShell: validation

extension SubprocessShell {
    /// pi's `resolveTimeoutMs`: positive, finite, and at most `INT32_MAX`
    /// milliseconds — the ceiling is Node's `setTimeout` limit, kept because a
    /// caller that computed a nonsense timeout should be told, not silently
    /// given "never".
    private static let maximumTimeout = Duration.milliseconds(2_147_483_647)

    private static func validate(timeout: Duration?) throws(DoMoError) -> Duration? {
        guard let timeout else { return nil }
        guard timeout > .zero else {
            throw DoMoError(.configuration, "invalid timeout: must be greater than zero")
        }
        guard timeout <= maximumTimeout else {
            throw DoMoError(
                .configuration,
                "invalid timeout: maximum is \(maximumTimeout.components.seconds) seconds"
            )
        }
        return timeout
    }

    /// pi checks the working directory before spawning, because the error the
    /// OS gives for a missing `cwd` names neither the directory nor the reason.
    private static func validate(workingDirectory: FilePath?) throws(DoMoError) {
        guard let workingDirectory else { return }
        // `resourceValues` rather than `fileExists(atPath:isDirectory:)`: the
        // latter reports directory-ness through an `UnsafeMutablePointer`, which
        // is the sort of thing `.strictMemorySafety()` is switched on to catch.
        let url = URL(fileURLWithPath: workingDirectory.string)
        let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
        guard isDirectory == true else {
            throw DoMoError.file(.noSuchFileOrDirectory, path: workingDirectory, while: "enter directory")
        }
    }
}

// MARK: - SubprocessShell: shell resolution

extension SubprocessShell {
    private static func isExecutable(_ path: FilePath) -> Bool {
        FileManager.default.isExecutableFile(atPath: path.string)
    }

    private static func resolveShellPath() -> FilePath {
        let bash = FilePath("/bin/bash")
        if isExecutable(bash) { return bash }
        if let onPath = searchPath(for: "bash") { return onPath }
        return FilePath("/bin/sh")
    }

    private static func searchPath(for name: String) -> FilePath? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = FilePath(String(directory)).appending(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Bounded buffer

/// A fixed-memory window over an arbitrarily long stream.
///
/// The head fills once and never moves. The tail is an array that is allowed to
/// grow to twice its limit before being trimmed back down, which bounds memory
/// at `head + 2 * tail` while keeping the amortized cost of `append` constant —
/// trimming on every chunk would make a 5MB stream quadratic. pi's
/// `OutputAccumulator` uses the same doubling trick for the same reason.
private struct BoundedByteBuffer {
    private let limits: ShellOutputLimits
    private var head: [UInt8] = []
    private var tail: [UInt8] = []
    private var totalBytes = 0

    init(limits: ShellOutputLimits) {
        self.limits = limits
    }

    mutating func append(_ chunk: [UInt8]) {
        guard !chunk.isEmpty else { return }
        totalBytes += chunk.count

        var remainder = chunk[...]
        if head.count < limits.head {
            let take = min(limits.head - head.count, remainder.count)
            head.append(contentsOf: remainder.prefix(take))
            remainder = remainder.dropFirst(take)
        }

        guard !remainder.isEmpty, limits.tail > 0 else { return }
        tail.append(contentsOf: remainder)
        if tail.count > limits.tail * 2 {
            tail.removeFirst(tail.count - limits.tail)
        }
    }

    consuming func finish() -> ShellStreamOutput {
        if tail.count > limits.tail {
            tail.removeFirst(tail.count - limits.tail)
        }
        return ShellStreamOutput(head: head, tail: tail, totalBytes: totalBytes)
    }
}

// MARK: - Drain plumbing

private struct DrainedStreams: Sendable {
    let stdout: ShellStreamOutput
    let stderr: ShellStreamOutput
    let timedOut: Bool
}

private enum DrainOutcome: Sendable {
    case standardOutput(ShellStreamOutput)
    case standardError(ShellStreamOutput)
    case timerFired
    case timerRetired
}
