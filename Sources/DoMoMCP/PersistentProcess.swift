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
        /// spawning (overlaid `environment` still wins if it re-provides one). The MCP
        /// subprocess is untrusted code; scrubbing the harness's LLM-gateway credential
        /// names keeps a compromised server from reading them out of its own environment.
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
        // overlay so a server that legitimately re-provides one still gets it.
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

        // Capture only Sendable continuations — never `self` or the execution handle.
        let outgoing = self.outgoing
        let linesContinuation = self.linesContinuation

        runTask = Task {
            _ = try? await Subprocess.run(
                configuration,
                input: .inputWriter,
                output: .sequence,
                error: .sequence
            ) { execution in
                await withTaskGroup(of: Void.self) { group in
                    // Writer: drain outgoing lines to stdin, newline-framed.
                    group.addTask {
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

                    // Reader: frame stdout into lines (see LineFramer). A line past the cap
                    // is a protocol violation — stop framing so a flood can't exhaust memory.
                    group.addTask {
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

                    // Stderr: drain and discard so a chatty server's pipe never fills
                    // (an undrained stderr pipe eventually blocks the child).
                    group.addTask {
                        do {
                            for try await chunk in execution.standardError {
                                _ = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                            }
                        } catch {}
                    }

                    await group.waitForAll()
                }
            }
            linesContinuation.finish()
        }
    }

    /// Enqueue one JSON-RPC message line (without a trailing newline) for stdin.
    func send(_ line: [UInt8]) {
        outgoingContinuation.yield(line)
    }

    /// Close stdin and terminate the child, waiting until it is actually gone. Finishing
    /// `outgoing` lets the writer send EOF (a graceful exit for most servers); cancelling
    /// the run Task fires the teardown sequence (SIGTERM -> grace -> SIGKILL to the group).
    ///
    /// It MUST await `runTask.value`: swift-subprocess runs that teardown sequence inside
    /// the (uncancelled) run Task, and only reaches the SIGKILL escalation after the grace
    /// elapses. Returning without awaiting lets the harness exit before the grace, which
    /// abandons the teardown mid-flight and orphans a stubborn child (it is in its own
    /// session via createSession, so it survives indefinitely). Awaiting blocks until the
    /// child is reaped — bounded by the SIGTERM grace for a server that ignores stdin EOF.
    func shutdown() async {
        outgoingContinuation.finish()
        let task = runTask
        runTask = nil
        task?.cancel()
        await task?.value
        linesContinuation.finish()
    }
}
