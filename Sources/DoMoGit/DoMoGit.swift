// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// The repository boundary used by Phase 12 surfaces.
///
/// Git is intentionally reached through ``Shell`` rather than through a second
/// subprocess implementation. That gives the facade one command policy in
/// production and lets tests assert the exact invocation without creating a
/// repository or depending on the developer's Git configuration.
public struct DoMoGit: Sendable {
    public let shell: any Shell

    /// Creates a facade over an injected command runner.
    public init(shell: any Shell) {
        self.shell = shell
    }

    /// Creates the production facade using the package's standard shell.
    public init() throws(DoMoError) {
        self.shell = try SubprocessShell()
    }

    /// Returns the commit at `HEAD`, or `nil` when `cwd` is not a repository or
    /// the repository has no commits yet.
    ///
    /// A missing start HEAD is not an error for session creation: the session can
    /// still run, it simply cannot later describe a Git diff from its beginning.
    public func head(at cwd: FilePath) async throws(DoMoError) -> String? {
        let result = try await runGit(["rev-parse", "--verify", "HEAD"], at: cwd)
        guard !result.timedOut else {
            throw DoMoError(.toolExecution(tool: "git"), "git rev-parse HEAD timed out")
        }
        guard result.exitCode != 0 else {
            let value = result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        // `rev-parse --verify HEAD` uses status 128 both for a directory outside
        // a repository and for an unborn HEAD. Both mean that a session has no
        // usable checkpoint. Other failures (a killed process, for example) are
        // surfaced so the caller does not silently record a false baseline.
        if result.exitCode == 128 {
            return nil
        }
        throw Self.commandFailure(result, summary: "git rev-parse HEAD")
    }

    /// Runs a Git subcommand with the repository policy applied consistently.
    ///
    /// The current shell seam accepts a command string, so every argument is
    /// single-quoted with POSIX-safe handling. Callers must still place `--`
    /// before path lists; this helper does not turn a path into an option.
    func runGit(_ arguments: [String], at cwd: FilePath) async throws(DoMoError) -> ShellResult {
        let command = ([
            "git",
            "--no-optional-locks",
            "-c",
            "core.quotepath=false",
        ] + arguments).map(Self.quote).joined(separator: " ")
        let request = ShellRequest(
            command,
            workingDirectory: cwd,
            environment: .inherit([
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "LC_ALL": "C",
            ]),
            timeout: .seconds(30),
            limits: ShellOutputLimits(head: 256 * 1024, tail: 256 * 1024)
        )
        return try await shell.run(request)
    }

    /// Shell-quotes one argument without allowing its contents to become shell
    /// syntax. The empty string is quoted too, because an omitted argument is a
    /// different Git request from an empty one.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func commandFailure(_ result: ShellResult, summary: String) -> DoMoError {
        let code = result.exitCode.map(String.init) ?? "signal \(result.signal.map(String.init) ?? "unknown")"
        let detail = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return DoMoError(
            .toolExecution(tool: "git"),
            "\(summary) failed with \(code)\(suffix)"
        )
    }
}
