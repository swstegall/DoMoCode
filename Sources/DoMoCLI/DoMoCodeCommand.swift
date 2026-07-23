// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoExec
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
            Phase 1: non-interactive print mode only. Give a prompt with -p and domocode runs a \
            multi-turn tool loop against the configured LiteLLM proxy and prints the model's final \
            text. Diagnostics go to stderr; stdout carries only the result (or, with --json, the \
            event stream).
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
            channel: OutputChannel()
        )

        let code = try await printMode.run(prompt: prompt)
        if code != 0 {
            throw ExitCode(code)
        }
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
