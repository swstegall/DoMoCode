// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoExec
import DoMoHarness
import DoMoLLM
import DoMoTools
import Foundation
import Logging
import SystemPackage

/// The `domocode` command-line root.
///
/// Phase 1 ships exactly one mode: non-interactive print (`-p`). The interactive
/// TUI, sessions, and the rest of the flag surface arrive in later phases; this
/// command is intentionally the thin wiring that turns resolved configuration
/// into a single ``PrintMode`` run.
///
/// Isolation note: nothing here is `@MainActor`. `AsyncParsableCommand.main()`
/// runs `run()` on the global executor, and the streaming client, tool dispatch,
/// and filesystem seams are all `@concurrent`, so the work stays off any actor —
/// which is what the README's concurrency rules ask of a headless entry point.
public struct DoMoCodeCommand: AsyncParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "domocode",
        abstract: "A terminal coding-agent harness that talks to a LiteLLM gateway.",
        discussion: """
            Non-interactive print mode. Give a prompt with -p and domocode runs a multi-turn tool \
            loop against the configured LiteLLM proxy and prints the model's final text. \
            Diagnostics go to stderr; stdout carries only the result (or, with --json, the event \
            stream).

            SESSIONS. Every run persists its transcript to a session file under the session \
            directory (DOMOCODE_SESSION_DIR, or <config-dir>/sessions). Resume a session to carry \
            its context into a new run:

              --continue         Resume the most recent session for the current directory.
              --resume <id|path> Resume a session by its id (from its file's header) or by file path.
              --session <path>   Resume the session at an explicit file path.
              --fork             Resume as above but branch into a NEW file, leaving the original \
            untouched. With no other selector, --fork forks the most recent session.

            Use at most one of --continue, --resume, or --session. An unknown id or a file that is \
            not a session is a hard error (non-zero exit).

            PROJECT TRUST. When the current directory carries a .domocode/settings.json — which can \
            redirect the model, the proxy, and where sessions are written — domocode refuses to run \
            until the directory is trusted. Print mode cannot prompt, so pass --trust once to record \
            trust (in <config-dir>/trust.json, keyed by resolved path; a trusted directory also \
            trusts its subdirectories). A directory with no such project file needs no trust.
            """
    )

    @Option(
        name: [.customShort("p"), .customLong("print")],
        help: "The prompt to run non-interactively, then exit."
    )
    public var prompt: String?

    @Option(name: .customLong("model"), help: "Public model alias as configured on the proxy.")
    public var model: String?

    @Option(name: .customLong("base-url"), help: "LiteLLM proxy base URL (default http://localhost:4000/v1).")
    public var baseURL: String?

    @Option(name: .customLong("max-turns"), help: "Maximum assistant turns before giving up (default 20).")
    public var maxTurns: Int = 20

    @Flag(name: .customLong("json"), help: "Emit a newline-delimited JSON event stream on stdout.")
    public var json: Bool = false

    @Flag(
        name: [.customShort("c"), .customLong("continue")],
        help: "Resume the most recent session for the current directory."
    )
    public var continueSession: Bool = false

    @Option(
        name: .customLong("resume"),
        help: "Resume a session by its id (from the file header) or by file path."
    )
    public var resume: String?

    @Option(name: .customLong("session"), help: "Resume the session at an explicit file path.")
    public var session: String?

    @Flag(
        name: .customLong("fork"),
        help: "Resume but branch into a new session file, leaving the original untouched."
    )
    public var fork: Bool = false

    @Flag(
        name: .customLong("trust"),
        help: "Trust the current directory's .domocode project settings and record it for future runs."
    )
    public var trust: Bool = false

    public init() {}

    /// The executable's entry point.
    ///
    /// This exists instead of a top-level `await DoMoCodeCommand.main()` because
    /// that call is ambiguous: `ParsableCommand` provides a *synchronous*
    /// `main()` and `AsyncParsableCommand` an *async* one with the identical
    /// signature, and overload resolution in a `main.swift` picks the sync one and
    /// then rejects the pointless `await`. Driving parse-then-run by hand — exactly
    /// what `AsyncParsableCommand.main()` does internally — sidesteps the ambiguity
    /// while preserving its help/version/exit-code behavior via `exit(withError:)`.
    public static func run() async {
        do {
            let parsed = try parseAsRoot()
            if var asyncCommand = parsed as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var command = parsed
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    public func run() async throws {
        do {
            try await execute()
        } catch let code as ExitCode {
            // Already the process's verdict — its message, if any, was written by
            // whoever threw it.
            throw code
        } catch let error as DoMoError {
            Self.writeStderr(error.description + "\n")
            throw ExitCode.failure
        } catch {
            Self.writeStderr(String(describing: error) + "\n")
            throw ExitCode.failure
        }
    }

    private func execute() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workingDirectory = FilePath(FileManager.default.currentDirectoryPath)

        let configuration = try ResolvedConfiguration.load(
            cli: CLIOverrides(baseURL: baseURL, model: model),
            environment: environment,
            workingDirectory: workingDirectory
        )

        // Bootstrap logging to stderr *before* anything can log. The stock
        // swift-log handler writes to stdout, which would corrupt the output
        // channel; routing it to stderr is what keeps stdout clean.
        Self.bootstrapLogging(level: configuration.logLevel)

        guard let prompt, !prompt.isEmpty else {
            throw DoMoError(.configuration, "No prompt given. Use -p \"<prompt>\" to run non-interactively.")
        }
        guard let model = configuration.model, !model.isEmpty else {
            throw DoMoError(
                .configuration,
                "No model configured. Set --model, \(EnvName.model), or \"model\" in settings.json."
            )
        }
        guard maxTurns >= 1 else {
            throw DoMoError(.configuration, "--max-turns must be at least 1 (got \(maxTurns)).")
        }

        // Refuse to run an untrusted project's local settings before any tool is
        // built — the point of the gate is that untrusted input never reaches a
        // run. A directory with no `.domocode/settings.json` needs no trust.
        try Self.ensureProjectTrust(
            workingDirectory: workingDirectory,
            configDirectory: configuration.configDirectory,
            trustFlag: trust
        )

        // Resolve which session this run attaches to before touching the model, so
        // a bad `--resume`/`--session` fails fast with a clear message.
        let sessionSource = try Self.resolveSessionSource(
            continueSession: continueSession,
            resume: resume,
            session: session,
            fork: fork,
            workingDirectory: workingDirectory,
            sessionDirectory: configuration.sessionDirectory
        )

        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(at: workingDirectory, shell: shell)
        let registry = ToolRegistry.builtin
        let client = LiteLLMClient(configuration: configuration.clientConfiguration)

        let printMode = PrintMode(
            client: client,
            model: model,
            reasoningEffort: configuration.reasoningEffort,
            registry: registry,
            toolContext: toolContext,
            workingDirectory: workingDirectory,
            mode: json ? .json : .text,
            maxTurns: maxTurns,
            channel: OutputChannel(),
            sessionSource: sessionSource,
            sessionDirectory: configuration.sessionDirectory
        )

        let code = try await printMode.run(prompt: prompt)
        if code != 0 {
            throw ExitCode(code)
        }
    }

    // MARK: Project trust

    /// Enforces project trust before a run, or records it when `--trust` is given.
    ///
    /// A directory with no trust-requiring project resources (see
    /// ``projectRequiresTrust(directory:)``) is always allowed — trust guards the
    /// *input* a repository would inject, not the act of running. Otherwise the
    /// nearest saved decision on the current-or-ancestor path decides: trusted
    /// proceeds, explicitly distrusted refuses, and no decision refuses with
    /// instructions, because non-interactive print mode has no way to prompt.
    /// `--trust` records trust for the directory (overriding a prior distrust) and
    /// proceeds — the one-shot, documented escape hatch a headless caller needs.
    static func ensureProjectTrust(
        workingDirectory: FilePath,
        configDirectory: FilePath,
        trustFlag: Bool
    ) throws(DoMoError) {
        guard projectRequiresTrust(directory: workingDirectory) else { return }
        let store = TrustStore(configDirectory: configDirectory)

        if trustFlag {
            try store.setDecision(true, for: workingDirectory)
            return
        }

        switch try store.decision(for: workingDirectory) {
        case .some(true):
            return
        case .some(false):
            throw DoMoError(
                .configuration,
                "Project \(workingDirectory.string) is marked untrusted in \(store.path.string), so its "
                    + ".domocode/settings.json will not be used. Pass --trust to override and re-trust it."
            )
        case .none:
            throw DoMoError(
                .configuration,
                "Project \(workingDirectory.string) has a .domocode/settings.json but is not trusted, and "
                    + "non-interactive print mode cannot prompt. Re-run with --trust to trust this directory "
                    + "(recorded in \(store.path.string)), or remove the file."
            )
        }
    }

    // MARK: Session resolution

    /// Resolves the session-selection flags into a ``SessionSource``.
    ///
    /// Precedence: at most one of `--session`, `--resume`, `--continue` may pick a
    /// base session (more than one is a usage error). `--fork` then decides whether
    /// the run appends to that base or branches into a new file. `--fork` with no
    /// other selector forks the most recent session — the interactive "branch from
    /// where I am" gesture, spelled for a headless caller. With nothing selected
    /// the run starts a fresh session.
    static func resolveSessionSource(
        continueSession: Bool,
        resume: String?,
        session: String?,
        fork: Bool,
        workingDirectory: FilePath,
        sessionDirectory: FilePath
    ) throws(DoMoError) -> SessionSource {
        let selectorCount = [session != nil, resume != nil, continueSession].filter { $0 }.count
        if selectorCount > 1 {
            throw DoMoError(.configuration, "Use at most one of --session, --resume, or --continue.")
        }

        let base: FilePath?
        if let session {
            base = FilePath(session)
        } else if let resume {
            base = try resolveResumeTarget(resume, workingDirectory: workingDirectory, sessionDirectory: sessionDirectory)
        } else if continueSession {
            base = try mostRecentSession(
                workingDirectory: workingDirectory,
                sessionDirectory: sessionDirectory,
                whenMissing: "No previous session found for \(workingDirectory.string) to --continue."
            )
        } else if fork {
            base = try mostRecentSession(
                workingDirectory: workingDirectory,
                sessionDirectory: sessionDirectory,
                whenMissing: "No previous session found for \(workingDirectory.string) to --fork."
            )
        } else {
            base = nil
        }

        guard let base else { return .new }
        return fork ? .fork(base) : .resume(base)
    }

    /// Resolves a `--resume` argument: an existing file path is used as-is (so a
    /// caller can name a session file directly), otherwise the value is treated as
    /// a session id and matched against this directory's session headers.
    private static func resolveResumeTarget(
        _ value: String,
        workingDirectory: FilePath,
        sessionDirectory: FilePath
    ) throws(DoMoError) -> FilePath {
        if FileManager.default.fileExists(atPath: value) {
            return FilePath(value)
        }
        let listings = (try? JSONLSessionStore.list(cwd: workingDirectory.string, sessionDirectory: sessionDirectory)) ?? []
        if let match = listings.first(where: { $0.header.id == value }) {
            return match.path
        }
        throw DoMoError(
            .configuration,
            "No session found with id or path \"\(value)\" for \(workingDirectory.string)."
        )
    }

    /// The newest session recorded for `workingDirectory`, or a
    /// ``DoMoError/Kind/configuration`` error carrying `whenMissing` if there is
    /// none. Listings are sorted oldest-first, so the last is the most recent.
    private static func mostRecentSession(
        workingDirectory: FilePath,
        sessionDirectory: FilePath,
        whenMissing: String
    ) throws(DoMoError) -> FilePath {
        let listings = (try? JSONLSessionStore.list(cwd: workingDirectory.string, sessionDirectory: sessionDirectory)) ?? []
        guard let latest = listings.last else {
            throw DoMoError(.configuration, whenMissing)
        }
        return latest.path
    }

    // MARK: Logging

    private static func bootstrapLogging(level: Logger.Level) {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }

    // MARK: stderr

    private static func writeStderr(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}
