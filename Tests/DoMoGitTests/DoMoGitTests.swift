// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
@testable import DoMoGit
import Foundation
import Synchronization
import SystemPackage
import Testing

private final class RecordingShell: Shell {
    private let recorded = Mutex<[ShellRequest]>([])
    private let result: ShellResult

    init(result: ShellResult) {
        self.result = result
    }

    var requests: [ShellRequest] { recorded.withLock { $0 } }

    func run(_ request: ShellRequest) async throws(DoMoError) -> ShellResult {
        recorded.withLock { $0.append(request) }
        return result
    }
}

private func result(
    exit code: Int32,
    stdout: String = "",
    stderr: String = "",
    timedOut: Bool = false
) -> ShellResult {
    ShellResult(
        termination: .exited(code),
        stdout: ShellStreamOutput(head: Array(stdout.utf8), tail: [], totalBytes: stdout.utf8.count),
        stderr: ShellStreamOutput(head: Array(stderr.utf8), tail: [], totalBytes: stderr.utf8.count),
        timedOut: timedOut,
        duration: .milliseconds(1),
        processIdentifier: 4242
    )
}

@Suite("DoMoGit facade")
struct DoMoGitTests {
    @Test("HEAD uses the non-interactive Git policy and trims the commit")
    func headUsesPolicy() async throws {
        let shell = RecordingShell(result: result(exit: 0, stdout: "abc123\n"))
        let git = DoMoGit(shell: shell)

        let head = try await git.head(at: FilePath("/workspace with spaces"))

        #expect(head == "abc123")
        let request = try #require(shell.requests.first)
        #expect(request.command == "'git' '--no-optional-locks' '-c' 'core.quotepath=false' 'rev-parse' '--verify' 'HEAD'")
        #expect(request.workingDirectory == FilePath("/workspace with spaces"))
        #expect(request.environment.overrides["GIT_TERMINAL_PROMPT"] == "0")
        #expect(request.environment.overrides["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(request.environment.overrides["LC_ALL"] == "C")
    }

    @Test("an unborn or missing repository has no checkpoint")
    func missingHeadIsOptional() async throws {
        let git = DoMoGit(shell: RecordingShell(result: result(
            exit: 128,
            stderr: "fatal: not a git repository"
        )))

        #expect(try await git.head(at: FilePath("/not-a-repository")) == nil)
    }

    @Test("unexpected Git failures remain visible")
    func unexpectedFailureThrows() async {
        let git = DoMoGit(shell: RecordingShell(result: result(exit: 1, stderr: "fatal: permission denied")))

        do {
            _ = try await git.head(at: FilePath("/workspace"))
            Issue.record("expected Git failure")
        } catch let error {
            #expect(error.kind == .toolExecution(tool: "git"))
            #expect(error.message.contains("permission denied"))
        }
    }

    @Test("argument quoting keeps apostrophes inside one shell argument")
    func quotesApostrophes() {
        #expect(DoMoGit.quote("a'b") == "'a'\\''b'")
        #expect(DoMoGit.quote("") == "''")
    }
}
