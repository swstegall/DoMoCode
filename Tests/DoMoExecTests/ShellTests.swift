// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage
import Testing

import DoMoExec

// MARK: - Fixtures

/// A scratch directory that removes itself.
private final class ScratchDirectory: Sendable {
    let path: FilePath
    let name: String

    init() throws {
        name = "domoexec-tests-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    func appending(_ component: String) -> FilePath {
        path.appending(component)
    }
}

/// Polls until `condition` holds, or gives up.
///
/// Process death is asynchronous even when the signal is not: `SIGKILL` returns
/// as soon as it is queued, and the pid stays visible until the kernel reaps it.
/// A single check right after teardown is a flake generator.
private func eventually(
    within limit: Duration = .seconds(5),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}

private func isRunning(pid: Int32) async throws -> Bool {
    let shell = try SubprocessShell()
    return try await shell.run("kill -0 \(pid) 2>/dev/null").exitCode == 0
}

private func readPID(_ path: FilePath) -> Int32? {
    guard let text = try? String(contentsOfFile: path.string, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Basics

@Suite("Shell", .timeLimit(.minutes(2)))
struct ShellBasicsTests {
    @Test("runs a command and captures stdout")
    func capturesStandardOutput() async throws {
        let result = try await SubprocessShell().run("echo hello")
        #expect(result.isSuccess)
        #expect(result.exitCode == 0)
        #expect(result.signal == nil)
        #expect(result.timedOut == false)
        #expect(result.stdout.text == "hello\n")
        #expect(result.stderr.text.isEmpty)
        #expect(result.processIdentifier > 0)
    }

    @Test("keeps stdout and stderr apart")
    func separatesStreams() async throws {
        let result = try await SubprocessShell().run("echo out; echo err >&2")
        #expect(result.stdout.text == "out\n")
        #expect(result.stderr.text == "err\n")
    }

    @Test("interprets pipes, redirection and globs")
    func interpretsShellSyntax() async throws {
        let scratch = try ScratchDirectory()
        let shell = try SubprocessShell()

        let setup = try await shell.run(
            ShellRequest("touch one.txt two.txt three.md", workingDirectory: scratch.path)
        )
        #expect(setup.isSuccess)

        let counted = try await shell.run(
            ShellRequest("ls *.txt | wc -l | tr -d ' '", workingDirectory: scratch.path)
        )
        #expect(counted.stdout.text == "2\n")

        let redirected = try await shell.run(
            ShellRequest("echo written > out.log && cat out.log", workingDirectory: scratch.path)
        )
        #expect(redirected.stdout.text == "written\n")
    }

    @Test("reports a non-zero exit without throwing")
    func reportsNonZeroExit() async throws {
        let result = try await SubprocessShell().run("echo before; exit 3")
        #expect(result.termination == .exited(3))
        #expect(result.exitCode == 3)
        #expect(result.isSuccess == false)
        #expect(result.stdout.text == "before\n")
    }

    @Test("reports an unknown command as the shell's 127, not as a spawn failure")
    func reportsUnknownCommand() async throws {
        let result = try await SubprocessShell().run("definitely-not-a-real-command-9f3a")
        #expect(result.exitCode == 127)
        #expect(result.stderr.text.isEmpty == false)
        #expect(result.stdout.text.isEmpty)
    }

    @Test("feeds standard input")
    func feedsStandardInput() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("cat", standardInput: .text("piped through\n"))
        )
        #expect(result.isSuccess)
        #expect(result.stdout.text == "piped through\n")
    }

    @Test("gives a command with no input an immediate end-of-file")
    func closesStandardInputWhenUnset() async throws {
        let result = try await SubprocessShell().run("cat; echo done")
        #expect(result.isSuccess)
        #expect(result.stdout.text == "done\n")
    }

    @Test("runs in the requested working directory")
    func honorsWorkingDirectory() async throws {
        let scratch = try ScratchDirectory()
        let result = try await SubprocessShell().run(
            ShellRequest("pwd -P; touch marker", workingDirectory: scratch.path)
        )
        // The reported path is compared by suffix, not equality: on macOS the
        // temporary directory is reached through a `/var` -> `/private/var`
        // symlink and `pwd -P` prints the resolved form.
        #expect(result.stdout.text.trimmingCharacters(in: .newlines).hasSuffix("/" + scratch.name))
        #expect(FileManager.default.fileExists(atPath: scratch.appending("marker").string))
    }
}

// MARK: - Environment

@Suite("Shell environment", .timeLimit(.minutes(2)))
struct ShellEnvironmentTests {
    @Test("overrides an inherited variable")
    func overridesInheritedVariable() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("echo \"$HOME|$DOMO_TEST_VAR\"", environment: .inherit(["DOMO_TEST_VAR": "set"]))
        )
        let fields = result.stdout.text.trimmingCharacters(in: .newlines).split(separator: "|")
        #expect(fields.count == 2)
        #expect(fields.last == "set")
        #expect(fields.first?.isEmpty == false)
    }

    @Test("unsets an inherited variable")
    func unsetsInheritedVariable() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("echo \"[${HOME-unset}]\"", environment: .inherit(["HOME": nil]))
        )
        #expect(result.stdout.text == "[unset]\n")
    }

    @Test("starts from nothing when the environment is custom")
    func startsFromEmptyEnvironment() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("echo \"[${HOME-unset}][$ONLY]\"", environment: .custom(["ONLY": "value"]))
        )
        #expect(result.stdout.text == "[unset][value]\n")
    }
}

// MARK: - Output bounding

@Suite("Shell output bounding", .timeLimit(.minutes(2)))
struct ShellOutputTests {
    @Test("bounds gigabyte-scale output to head and tail")
    func boundsHugeOutput() async throws {
        let limits = ShellOutputLimits(head: 4 * 1024, tail: 4 * 1024)
        let total = 8 * 1024 * 1024
        let result = try await SubprocessShell().run(
            ShellRequest(
                "dd if=/dev/zero bs=1048576 count=8 2>/dev/null | tr '\\0' 'a'",
                limits: limits
            )
        )

        #expect(result.isSuccess)
        #expect(result.stdout.totalBytes == total)
        #expect(result.stdout.head.count == limits.head)
        #expect(result.stdout.tail.count == limits.tail)
        #expect(result.stdout.isTruncated)
        #expect(result.stdout.droppedBytes == total - limits.head - limits.tail)
        #expect(result.stdout.head.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(result.stdout.tail.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(result.stdout.text.contains("bytes omitted"))
        #expect(result.isTruncated)
    }

    @Test("keeps the head, keeps the tail, and says what it dropped")
    func splitsHeadAndTail() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("printf abcdefghij", limits: ShellOutputLimits(head: 3, tail: 3))
        )
        #expect(result.stdout.head == Array("abc".utf8))
        #expect(result.stdout.tail == Array("hij".utf8))
        #expect(result.stdout.totalBytes == 10)
        #expect(result.stdout.droppedBytes == 4)
        #expect(result.stdout.text == "abc\n[... 4 bytes omitted ...]\nhij")
    }

    @Test("inserts no marker when everything fits")
    func keepsShortOutputIntact() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("printf abcdefghij", limits: ShellOutputLimits(head: 5, tail: 5))
        )
        #expect(result.stdout.isTruncated == false)
        #expect(result.stdout.bytes == Array("abcdefghij".utf8))
        #expect(result.stdout.text == "abcdefghij")
    }

    @Test("survives non-UTF-8 bytes")
    func survivesInvalidUTF8() async throws {
        let result = try await SubprocessShell().run("printf '\\377\\376abc'")
        #expect(result.isSuccess)
        #expect(result.stdout.bytes == [0xFF, 0xFE, 0x61, 0x62, 0x63])
        #expect(result.stdout.totalBytes == 5)
        #expect(result.stdout.text.hasSuffix("abc"))
        #expect(result.stdout.text.contains("\u{FFFD}"))
    }

    @Test("survives a NUL byte in the middle of output")
    func survivesNulBytes() async throws {
        let result = try await SubprocessShell().run("printf 'a\\000b'")
        #expect(result.stdout.bytes == [0x61, 0x00, 0x62])
    }
}

// MARK: - Timeouts, cancellation, process groups

@Suite("Shell termination", .timeLimit(.minutes(2)))
struct ShellTerminationTests {
    @Test("a timeout kills a sleeping process")
    func timeoutKillsSleep() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest(
                "sleep 300",
                timeout: .milliseconds(300),
                terminationGracePeriod: .milliseconds(200)
            )
        )

        #expect(result.timedOut)
        #expect(result.isSuccess == false)
        // pi's contract: a killed process reports no exit code at all.
        #expect(result.exitCode == nil)
        #expect(result.signal == SIGTERM)
        #expect(result.duration < .seconds(10))
        #expect(try await isRunning(pid: result.processIdentifier) == false)
    }

    @Test("a timeout kills the whole process group, not just the leader")
    func timeoutKillsProcessGroup() async throws {
        let scratch = try ScratchDirectory()
        let pidFile = scratch.appending("child.pid")

        let result = try await SubprocessShell().run(
            ShellRequest(
                "sleep 300 & echo $! > \(pidFile.string); sleep 300",
                timeout: .milliseconds(400),
                terminationGracePeriod: .milliseconds(200)
            )
        )
        #expect(result.timedOut)

        let child = try #require(readPID(pidFile))
        #expect(child != result.processIdentifier)
        #expect(try await eventually { try await isRunning(pid: child) == false })
    }

    @Test("a backgrounded child holding the pipe open does not stall the call")
    func doesNotWaitForOrphansHoldingThePipe() async throws {
        // The orphan inherits stdout and outlives the shell by 30 seconds. If
        // the read waited for end-of-file rather than for the shell to exit,
        // this would take 30 seconds instead of milliseconds.
        let result = try await SubprocessShell().run("sleep 30 & echo started")

        #expect(result.isSuccess)
        #expect(result.stdout.text == "started\n")
        #expect(result.duration < .seconds(10))
    }

    @Test("cancelling the task terminates the process")
    func cancellationKillsTheProcess() async throws {
        let scratch = try ScratchDirectory()
        let pidFile = scratch.appending("shell.pid")

        let task = Task {
            try await SubprocessShell().run(
                ShellRequest(
                    "echo $$ > \(pidFile.string); sleep 300",
                    terminationGracePeriod: .milliseconds(200)
                )
            )
        }

        #expect(try await eventually { readPID(pidFile) != nil })
        let pid = try #require(readPID(pidFile))
        #expect(try await isRunning(pid: pid))

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to throw")
        } catch let error as DoMoError {
            #expect(error.isCancellation)
        }

        #expect(try await eventually { try await isRunning(pid: pid) == false })
    }

    @Test("a command that finishes inside its timeout is not marked as timed out")
    func fastCommandIsNotTimedOut() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest("echo quick", timeout: .seconds(30))
        )
        #expect(result.timedOut == false)
        #expect(result.isSuccess)
        #expect(result.stdout.text == "quick\n")
    }

    @Test("keeps the output a command produced before it timed out")
    func keepsPartialOutputOnTimeout() async throws {
        let result = try await SubprocessShell().run(
            ShellRequest(
                "echo partial; sleep 300",
                timeout: .milliseconds(400),
                terminationGracePeriod: .milliseconds(200)
            )
        )
        #expect(result.timedOut)
        #expect(result.stdout.text == "partial\n")
    }
}

// MARK: - Rejected requests

@Suite("Shell validation", .timeLimit(.minutes(2)))
struct ShellValidationTests {
    @Test("rejects a non-positive timeout")
    func rejectsNonPositiveTimeout() async throws {
        do {
            _ = try await SubprocessShell().run(ShellRequest("echo hi", timeout: .zero))
            Issue.record("expected a configuration error")
        } catch {
            #expect(error.kind == .configuration)
        }
    }

    @Test("rejects a timeout past the representable maximum")
    func rejectsOversizedTimeout() async throws {
        do {
            _ = try await SubprocessShell().run(ShellRequest("echo hi", timeout: .seconds(3_000_000)))
            Issue.record("expected a configuration error")
        } catch {
            #expect(error.kind == .configuration)
        }
    }

    @Test("rejects a working directory that does not exist")
    func rejectsMissingWorkingDirectory() async throws {
        let missing = FilePath("/definitely/not/here-\(UUID().uuidString)")
        do {
            _ = try await SubprocessShell().run(ShellRequest("pwd", workingDirectory: missing))
            Issue.record("expected a file error")
        } catch {
            guard case .file(let path, _) = error.kind else {
                Issue.record("expected .file, got \(error.kind)")
                return
            }
            #expect(path == missing)
        }
    }

    @Test("rejects a shell path that does not exist")
    func rejectsMissingShell() throws {
        do {
            _ = try SubprocessShell(shellPath: FilePath("/no/such/shell-\(UUID().uuidString)"))
            Issue.record("expected a configuration error")
        } catch {
            #expect(error.kind == .configuration)
        }
    }

    @Test("accepts an explicit shell path that does exist")
    func acceptsExplicitShell() async throws {
        let shell = try SubprocessShell(shellPath: FilePath("/bin/sh"))
        #expect(shell.shellPath == FilePath("/bin/sh"))
        let result = try await shell.run("echo via-sh")
        #expect(result.stdout.text == "via-sh\n")
    }
}
