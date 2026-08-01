// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A persistent, bidirectional subprocess for the MCP stdio transport. swift-subprocess
// requires the whole session to live inside one `Subprocess.run(...) { execution in … }`
// closure (the execution handle must not escape it), so this actor owns one long-lived
// Task holding that closure and moves bytes in/out across `AsyncStream`s: outgoing lines
// are written to the child's stdin (newline-framed), incoming stdout is framed on raw
// `\n` and delivered as `lines`. Teardown closes stdin then cancels the Task, whose
// teardown sequence sends SIGTERM (grace) then SIGKILL to the child's process group.

import Foundation
import Subprocess

/// A single stdout line larger than this (before its `\n`) is treated as a protocol
/// violation and tears the stream down — a backstop against a server that floods stdout
/// with no newline (or an endless stream), which would otherwise grow the frame buffer
/// without bound. 32 MiB is far above any legitimate JSON-RPC message (a base64 image
/// result included).
private let maxLineBytes = 32 * 1024 * 1024

/// Incremental newline framer for a byte stream: feed chunks, get back the complete lines
/// they finished. Framing is on raw `0x0A` (NOT a Unicode line splitter — a JSON string may
/// legally contain U+2028/U+2029). It advances an index rather than shifting the buffer per
/// line (O(n) per chunk, not O(n^2)) and enforces `maxLineBytes` so an unterminated flood
/// can't grow the buffer without bound. Extracted from the subprocess plumbing so the tricky
/// chunk-boundary cases can be unit-tested deterministically.
struct LineFramer {
    private var buffer: [UInt8] = []
    private var lineStart = 0
    /// Set once an unterminated line exceeds the cap — the caller should tear the stream down.
    private(set) var overflowed = false
    let maxLineBytes: Int

    init(maxLineBytes: Int) { self.maxLineBytes = maxLineBytes }

    /// Append a chunk and return every complete line it completed (empty lines dropped).
    mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        buffer.append(contentsOf: bytes)
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            let line = Array(buffer[lineStart..<newline])
            if !line.isEmpty { out.append(line) }
            lineStart = newline + 1
        }
        // Compact the consumed prefix once per chunk.
        if lineStart > 0 {
            buffer.removeSubrange(..<lineStart)
            lineStart = 0
        }
        if buffer.count > maxLineBytes { overflowed = true }
        return out
    }

    /// The trailing unterminated line at end-of-stream, if any and within the cap.
    mutating func finish() -> [UInt8]? {
        defer { buffer = []; lineStart = 0 }
        guard !overflowed, !buffer.isEmpty, buffer.count <= maxLineBytes else { return nil }
        return buffer
    }
}

/// A tiny thread-safe box for the child's pid, shared (by reference) between the run Task
/// that writes it and the actor that reads it in `shutdown` — a reference type so it can
/// cross into the run closure without capturing the actor.
private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    func set(_ value: pid_t) { lock.lock(); pid = value; lock.unlock() }
    /// Cleared when the child exits, so a later `shutdown` never signals a reaped (and
    /// possibly reused) pid.
    func clear() { lock.lock(); pid = nil; lock.unlock() }
    var value: pid_t? { lock.lock(); defer { lock.unlock() }; return pid }
}

/// Owns one long-running child process and its stdio, framing JSON-RPC lines both ways.
actor PersistentProcess {
    struct Spawn: Sendable {
        /// `command[0]` is the program (resolved via PATH if bare), the rest are argv.
        var command: [String]
        /// Extra environment overlaid on the inherited environment.
        var environment: [String: String]
        /// Working directory for the child, or nil to inherit.
        var workingDirectory: String?
        /// Environment variable names to REMOVE from the inherited environment before
        /// spawning. The MCP subprocess is untrusted code; scrubbing the harness's
        /// LLM-gateway credential names keeps a compromised server from reading them out
        /// of its own environment.
        ///
        /// The overlaid `environment` is applied AFTER these removals, so a server that
        /// legitimately re-provides one of these names still gets it — see `start`. That
        /// ordering is deliberate and it is only safe in company: it means a settings.json
        /// can hand an MCP server any value it can *write*, so the thing that must hold
        /// the line is config interpolation refusing to *resolve* a credential name.
        /// `DoMoCore.InterpolationPolicy.deniedEnvironmentNames` — seeded from
        /// `Redaction.secretEnvironmentNames` on both the trusted and the untrusted
        /// policy — is what makes `{"env": {"X": "{env:DOMOCODE_API_KEY}"}}` a hard
        /// config diagnostic rather than a laundering route straight back through this
        /// overlay. Change either mechanism and the other stops being sufficient.
        var sensitiveEnvKeys: Set<String> = []
        /// Grace between SIGTERM and SIGKILL on teardown.
        var terminationGrace: Duration = .seconds(2)
    }

    /// Complete stdout lines (each a JSON-RPC message, without the trailing `\n`).
    let lines: AsyncStream<[UInt8]>
    private let linesContinuation: AsyncStream<[UInt8]>.Continuation

    private let outgoing: AsyncStream<[UInt8]>
    private let outgoingContinuation: AsyncStream<[UInt8]>.Continuation

    private var runTask: Task<Void, Never>?

    /// The child's pid, captured once the run starts. With `createSession` the child is a
    /// session+group leader, so this is also its process-group id — `shutdown` signals the
    /// whole group by it to reap descendants (see `shutdown`). A reference box so the run
    /// Task can set it without capturing the actor. `nil` until the child is spawned.
    private let childPID = PIDBox()

    init() {
        (lines, linesContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    /// Launch the child and start pumping stdio. Returns immediately; the session runs
    /// in a retained Task. `lines` begins yielding as the child writes.
    func start(_ spawn: Spawn) {
        guard runTask == nil else { return }

        var platformOptions = PlatformOptions()
        // The child (and its descendants, e.g. `npx` -> node) get their own session, so
        // the group-targeted teardown signals never reach this harness.
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: spawn.terminationGrace)
        ]

        // Build the environment overlay: first mark each sensitive key for REMOVAL (a
        // `nil` value in `updating` unsets an inherited variable), then apply the config
        // overlay so a server that legitimately re-provides one still gets it. The order
        // is the documented contract on `Spawn.sensitiveEnvKeys`, and it is what config
        // interpolation's env denylist is protecting — do not reverse it without reading
        // that note.
        var overrides: [Subprocess.Environment.Key: String?] = [:]
        for key in spawn.sensitiveEnvKeys {
            overrides.updateValue(nil, forKey: Subprocess.Environment.Key(stringLiteral: key))
        }
        for (key, value) in spawn.environment {
            overrides.updateValue(value, forKey: Subprocess.Environment.Key(stringLiteral: key))
        }
        var configuration = Subprocess.Configuration(
            executable: .name(spawn.command[0]),
            arguments: Subprocess.Arguments(Array(spawn.command.dropFirst())),
            environment: .inherit.updating(overrides),
            platformOptions: platformOptions
        )
        if let cwd = spawn.workingDirectory {
            // `.init` picks System.FilePath contextually (Subprocess re-exports it,
            // which would otherwise clash with SystemPackage.FilePath).
            configuration.workingDirectory = .init(cwd)
        }

        // Capture only Sendable values — never `self` or the execution handle.
        let outgoing = self.outgoing
        let linesContinuation = self.linesContinuation
        let childPID = self.childPID

        runTask = Task {
            _ = try? await Subprocess.run(
                configuration,
                input: .inputWriter,
                output: .sequence,
                error: .sequence
            ) { execution in
                // Record the pid (== pgid, since createSession made the child a group
                // leader) so shutdown can signal the whole group and reap descendants.
                childPID.set(execution.processIdentifier.value)
                // Keep the three pumps concurrent, but coordinate them with an
                // AsyncStream rather than a task group. On optimized Swift 6.3
                // runtimes, tearing down a task group while Subprocess is unwinding
                // its execution closure can trip the runtime's stack-allocation
                // assertion. These are deliberately unstructured tasks so the
                // cancellation handler below can retire them explicitly.
                let (completions, completionContinuation) = AsyncStream.makeStream(of: Void.self)

                let writerTask = Task {
                    defer { completionContinuation.yield(()) }
                    let writer = execution.standardInputWriter
                    writing: for await line in outgoing {
                        var frame = line
                        frame.append(0x0A)
                        var offset = 0
                        while offset < frame.count {
                            let written = (try? await writer.write(Array(frame[offset...]))) ?? 0
                            // A write that makes no progress means the pipe is gone
                            // (child exited/EPIPE). Stop the whole writer rather than
                            // starting the next frame — otherwise a half-written frame
                            // would be spliced onto the next one as corrupt JSON.
                            if written <= 0 { break writing }
                            offset += written
                        }
                    }
                    try? await writer.finish()   // stdin EOF — most stdio servers exit
                }

                let stdoutTask = Task {
                    defer { completionContinuation.yield(()) }
                    // Reader: frame stdout into lines (see LineFramer). A line past the cap
                    // is a protocol violation — stop framing so a flood can't exhaust memory.
                    var framer = LineFramer(maxLineBytes: maxLineBytes)
                    do {
                        reading: for try await chunk in execution.standardOutput {
                            let bytes: [UInt8] = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                            for line in framer.feed(bytes) { linesContinuation.yield(line) }
                            if framer.overflowed { break reading }
                        }
                    } catch {
                        // The pipe closed on teardown; treat as end-of-stream.
                    }
                    if let last = framer.finish() { linesContinuation.yield(last) }
                    linesContinuation.finish()
                }

                let stderrTask = Task {
                    defer { completionContinuation.yield(()) }
                    // Stderr: drain and discard so a chatty server's pipe never fills
                    // (an undrained stderr pipe eventually blocks the child).
                    do {
                        for try await chunk in execution.standardError {
                            _ = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                        }
                    } catch {}
                }

                await withTaskCancellationHandler(operation: {
                    var iterator = completions.makeAsyncIterator()
                    for _ in 0..<3 { _ = await iterator.next() }
                }, onCancel: {
                    writerTask.cancel()
                    stdoutTask.cancel()
                    stderrTask.cancel()
                    completionContinuation.finish()
                })

                // The completion markers are emitted before each task returns. Awaiting
                // the task values closes that small gap and makes the execution closure
                // deterministic on both normal exit and cancellation.
                await writerTask.value
                await stdoutTask.value
                await stderrTask.value
                completionContinuation.finish()
            }
            // The child has exited (and swift-subprocess has reaped it): forget its pid so a
            // later shutdown can't signal a reaped/reused pgid.
            childPID.clear()
            linesContinuation.finish()
        }
    }

    /// Enqueue one JSON-RPC message line (without a trailing newline) for stdin.
    func send(_ line: [UInt8]) {
        outgoingContinuation.yield(line)
    }

    /// Terminate the child AND its descendants, waiting until the child is actually reaped.
    /// Idempotent: a second call (or one after the child self-exited) is a no-op.
    ///
    /// We signal the child's whole process GROUP ourselves rather than trusting
    /// swift-subprocess's teardown to do it: `runTeardownSequence` early-returns without
    /// sending its group signal the moment the child has exited — and cancelling the run
    /// Task closes stdin (the writer finishes), so a graceful server exits on EOF and the
    /// group signal is skipped, orphaning descendants (an `npx` wrapper's `node`, a forked
    /// helper). `createSession` made the child a session+group leader, so `kill(-pgid, …)`
    /// targets the child and every descendant still in its group. We send the SIGTERM while
    /// the child (the group leader) is still alive and `childPID` still holds it — so the
    /// pgid is unambiguously ours, never a reaped/reused pid (the run Task clears `childPID`
    /// when the child exits). We deliberately do NOT add a post-reap SIGKILL sweep: after
    /// `runTask.value` the pid is freed and could be reused, so signaling it then is unsafe;
    /// the trade-off is that a rare SIGTERM-ignoring GRANDCHILD of a graceful child is not
    /// force-killed (swift-subprocess still escalates the CHILD itself to SIGKILL).
    ///
    /// It MUST await `runTask.value` so the run Task's own cleanup completes and the child
    /// is reaped before returning; otherwise the harness could exit mid-teardown. Awaiting
    /// is bounded by swift-subprocess's grace for a child that ignores SIGTERM (our leading
    /// group SIGTERM usually ends it first). The child still gets stdin EOF (the writer
    /// finishes on cancel), so an EOF-respecting server can still exit within the grace.
    func shutdown() async {
        guard let task = runTask else { return }   // already shut down, or never started
        runTask = nil
        if let pgid = childPID.value { _ = kill(-pgid, SIGTERM) }
        task.cancel()
        outgoingContinuation.finish()
        await task.value
        linesContinuation.finish()
    }
}
