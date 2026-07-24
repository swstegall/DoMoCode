// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoAgent
import DoMoCore
import DoMoExec
import DoMoHarness
import DoMoLLM
import DoMoServer
import DoMoTermIO
import DoMoTUI
import DoMoTools
import Foundation
import Logging
import SystemPackage

/// The `domo` command-line root.
///
/// Two modes: with `-p` it runs a single non-interactive ``PrintMode`` turn and
/// exits; with no `-p` it launches the interactive REPL (``InteractiveMode``).
/// Session selection and project trust are resolved once, up front, and shared by
/// both paths; the command itself is the thin wiring that turns resolved
/// configuration into whichever run the flags asked for.
///
/// Isolation note: the parse-and-dispatch surface stays off any actor —
/// `AsyncParsableCommand.main()` runs `run()` on the global executor, and the
/// streaming client, tool dispatch, and filesystem seams are all `@concurrent`.
/// The one exception is ``runInteractive(_:)``, which is `@MainActor`: the live
/// terminal target is not `Sendable`, so the REPL's collaborators are assembled
/// and driven on the main actor rather than crossing an isolation boundary.
public struct DoMoCodeCommand: AsyncParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "domo",
        abstract: "A terminal coding-agent harness that talks to a LiteLLM gateway.",
        discussion: """
            Two modes. With no -p, domo opens an INTERACTIVE session: a live transcript with \
            streaming model output, @ file completion, Escape to abort a running turn, and Enter to \
            queue a follow-up. It needs a real terminal. With -p "<prompt>" it runs a single \
            NON-INTERACTIVE turn against the configured LiteLLM proxy and prints the model's final \
            text; diagnostics go to stderr, stdout carries only the result (or, with --json, the \
            event stream).

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
            redirect the model, the proxy, and where sessions are written — domo refuses to run \
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

    @Option(
        name: .customLong("image"),
        help: "Attach an image file to the -p prompt (PNG, JPEG, GIF, WebP, BMP). Repeatable."
    )
    public var images: [String] = []

    @Flag(
        name: .customLong("serve"),
        help: "Run as a headless HTTP/SSE server (loopback only) instead of an interactive or print session."
    )
    public var serve: Bool = false

    @Option(
        name: .customLong("port"),
        help: "Port for --serve (default 4100; 0 asks the OS for an ephemeral port)."
    )
    public var port: Int = 4100

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

        // `--serve` runs the headless HTTP/SSE server and does not return until the
        // process is signalled. It manages sessions itself, so it is branched before
        // the print/interactive session-source resolution below.
        if serve {
            try await runServer(configuration: configuration, model: model, workingDirectory: workingDirectory)
            return
        }

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

        // `--image` attaches to a `-p` prompt; interactive sessions reference
        // images inline with `@path`, so an image flag with no prompt is a usage
        // error rather than a silently ignored argument.
        if !images.isEmpty, prompt?.isEmpty ?? true {
            throw DoMoError(
                .configuration,
                "--image requires -p; in an interactive session, reference an image with @path instead."
            )
        }

        // No `-p`: run the interactive REPL. The heavy dependencies (tools, the
        // sandboxed context, the harness) are built behind ``InteractiveMode/make``,
        // and the live terminal collaborators are assembled on the main actor so
        // the non-`Sendable` output target never crosses an isolation boundary.
        guard let prompt, !prompt.isEmpty else {
            let mode = try await InteractiveMode.make(
                clientConfiguration: configuration.clientConfiguration,
                model: model,
                workingDirectory: workingDirectory.string,
                sessionDirectory: configuration.sessionDirectory.string,
                homeDirectory: environment["HOME"],
                reasoningEffort: configuration.reasoningEffort,
                maxTurns: maxTurns,
                sessionSource: sessionSource
            )
            try await Self.runInteractive(mode)
            return
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
            channel: OutputChannel(),
            sessionSource: sessionSource,
            sessionDirectory: configuration.sessionDirectory
        )

        let attachments = try Self.loadImageAttachments(images)
        let code = try await printMode.run(prompt: prompt, attachments: attachments)
        if code != 0 {
            throw ExitCode(code)
        }
    }

    /// Reads each `--image` path into an ``ImageBlock``, sniffing its media type
    /// from the leading bytes rather than trusting the extension.
    ///
    /// A path that is missing, unreadable, or not a supported image is a hard,
    /// message-bearing error: a scripted caller that asked to attach an image
    /// should hear that it could not, not have the attachment silently dropped and
    /// send the model a prompt that references a picture it never received. Read
    /// through Foundation rather than the tool sandbox, because a `--image`
    /// argument is trusted operator input and may name a file outside the project.
    static func loadImageAttachments(_ paths: [String]) throws(DoMoError) -> [ImageBlock] {
        var blocks: [ImageBlock] = []
        for path in paths {
            let bytes: Data
            do {
                bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw DoMoError(
                    .file(path: FilePath(path), errno: nil),
                    "Could not read --image file \"\(path)\"",
                    cause: error
                )
            }
            guard let mediaType = FileContentProbe.imageMediaType(bytes) else {
                throw DoMoError(
                    .configuration,
                    "--image file \"\(path)\" is not a supported image (PNG, JPEG, GIF, WebP, or BMP)."
                )
            }
            blocks.append(ImageBlock(mediaType: mediaType, data: bytes))
        }
        return blocks
    }

    /// Assemble the live terminal collaborators on the main actor and run the REPL.
    ///
    /// ``TerminalOutputTarget`` is not `Sendable` (it wraps a process descriptor),
    /// so it is created here — inside the main-actor context that will use it —
    /// rather than passed across an isolation boundary. The input, resize and
    /// lifecycle seams are the live producers the injectable ``InteractiveMode/run``
    /// consumes; a test substitutes scripted ones.
    @MainActor
    private static func runInteractive(_ mode: InteractiveMode) async throws {
        let target = TerminalOutputTarget()
        let input = TerminalDriver.standardInputStream()
        let resize = TerminalSize.resizeStream()
        let lifecycle = TerminalLifecycle()
        try await mode.run(target: target, input: input, resize: resize, lifecycle: lifecycle)
    }

    // MARK: Serve

    /// Assemble the same runtime ingredients print mode builds — the LiteLLM stream
    /// function, the sandboxed tool context, the system prompt — and serve them over
    /// HTTP/SSE until the process is signalled.
    ///
    /// The bearer token is minted here and written to stderr (stdout stays clean),
    /// so a local client can read it. There is no login flow, matching the
    /// bearer-only posture; loopback-only bind plus the token is the whole gate.
    private func runServer(
        configuration: ResolvedConfiguration,
        model: String,
        workingDirectory: FilePath
    ) async throws {
        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(at: workingDirectory, shell: shell)
        let registry = ToolRegistry.builtin
        let client = LiteLLMClient(configuration: configuration.clientConfiguration)
        let tools: [any AgentTool] = registry.all.map { RegistryTool(tool: $0, context: toolContext) }
        let systemPrompt = PrintMode.systemPrompt(workingDirectory: workingDirectory, toolNames: registry.names)
        let reasoningEffort = configuration.reasoningEffort
        let streamFn: AgentStreamFn = { context in
            client.streamCompletion(model: model, context: context, reasoningEffort: reasoningEffort)
        }

        let runtime = ServerRuntime(config: ServerRuntime.Config(
            systemPrompt: systemPrompt,
            tools: tools,
            model: model,
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: maxTurns,
            sessionDirectory: configuration.sessionDirectory,
            cwd: workingDirectory.string
        ))
        let token = Self.generateToken()
        let server = DoMoServer(
            runtime: runtime,
            options: DoMoServer.Options(host: "127.0.0.1", port: port, token: token)
        )

        Self.writeStderr("domo serve — listening on http://127.0.0.1:\(port) (loopback only)\n")
        Self.writeStderr("Authorization: Bearer \(token)\n")
        try await server.run()
    }

    /// A 32-byte random bearer token, hex-encoded. Formatted by hand rather than
    /// with `String(format:)`, whose varargs initializer is `unsafe` under
    /// `.strictMemorySafety()`.
    private static func generateToken() -> String {
        let hexDigits = Array("0123456789abcdef")
        var token = ""
        token.reserveCapacity(64)
        for _ in 0..<32 {
            let byte = UInt8.random(in: UInt8.min...UInt8.max)
            token.append(hexDigits[Int(byte >> 4)])
            token.append(hexDigits[Int(byte & 0x0f)])
        }
        return token
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
