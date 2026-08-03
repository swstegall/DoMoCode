// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoExec
import DoMoHarness
import DoMoLLM
import DoMoMCP
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
            redirect the model, the proxy, and where sessions are written — domo will not use it \
            until the directory is trusted. An interactive session asks once, on the terminal, and \
            records the answer. Print mode and --serve cannot ask, so pass --trust to record trust \
            up front (in <config-dir>/trust.json, keyed by resolved path; a trusted directory also \
            trusts its subdirectories). A directory with no such project file needs no trust.

            TURN LIMIT. There is none by default, in EVERY mode — interactive, -p and --serve \
            alike. A run continues until the model produces a final answer, you abort it, or the \
            runaway guard trips (the same tool calls returning the same results, twelve turns \
            running). Set --max-turns N to cap a run instead; --max-turns 0 asks for unlimited \
            explicitly. Under -p, hitting the cap exits 2 and the runaway guard exits 3, so a \
            script can tell "I under-budgeted" from "the model is stuck".
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

    @Option(
        name: .customLong("max-turns"),
        help: ArgumentHelp(
            """
            Maximum assistant turns in one run. UNLIMITED by default — the agent keeps working \
            until it produces a final answer, is aborted, or the runaway guard trips. Pass 0 for \
            unlimited explicitly.
            """,
            valueName: "n"
        )
    )
    public var maxTurns: Int?

    /// The turn bound the runtimes actually receive.
    ///
    /// `nil` — the default, and the meaning of `--max-turns 0` — is unbounded, which
    /// is already the downstream vocabulary (``AgentLoopConfig/maxTurns``), so no new
    /// sentinel is invented. Never `0`: the loop emits `agent_start`/`turn_start`
    /// before its first bound check, so a literal 0 would settle a run with a
    /// dangling `turn_start` and no `turn_end`. Collapsing the sentinel here, once,
    /// is what keeps the four fan-out sites from each restating the rule.
    var turnLimit: Int? {
        guard let maxTurns, maxTurns > 0 else { return nil }
        return maxTurns
    }

    @Flag(
        name: .customLong("no-mouse"),
        help: """
            Never claim the mouse in the full-screen client, so the terminal's own selection and \
            scrollback keep working. Wheel scrolling inside the app is lost in exchange.
            """
    )
    public var noMouse: Bool = false

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

    @Flag(
        name: .customLong("inline"),
        help: "Use the classic inline REPL instead of the full-screen client (the default interactive mode)."
    )
    public var inline: Bool = false

    @Flag(
        name: [.customLong("yolo"), .customLong("dangerously-allow-all")],
        help: "Headless (-p) only: auto-approve every tool call that would otherwise need interactive approval. Without this, a tool needing approval is refused with a message the model can act on."
    )
    public var yolo: Bool = false

    @Option(
        name: .customLong("url"),
        help: "Attach the full-screen client to an existing `domo --serve` at this base URL (e.g. http://127.0.0.1:4100) instead of spawning a local server."
    )
    public var serverURL: String?

    @Option(
        name: .customLong("token"),
        help: "Bearer token for --url (from the server's stderr `Authorization: Bearer` line)."
    )
    public var serverToken: String?

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

        // Refuse to run an untrusted project's local settings BEFORE they are
        // parsed, not after. The gate used to run some thirty lines below
        // ``ResolvedConfiguration/load(cli:environment:workingDirectory:)``, which
        // meant an untrusted repository's `.domocode/settings.json` was already
        // decoded — and, now that settings values interpolate `{env:…}`/`{file:…}`,
        // already *acted on* — by the time the user was asked whether to trust it.
        // `InterpolationPolicy.untrusted(root:)`'s root confinement remains the
        // primary defence; this ordering is the belt to its braces, and it costs
        // nothing because ``ResolvedConfiguration/resolveConfigDirectory(environment:)``
        // is pure and reads only the environment — never a settings file — so the
        // config directory the trust store lives in is knowable without loading
        // anything. A directory with no `.domocode/settings.json` needs no trust.
        // An interactive run (no `-p`) can ASK; print mode and `--serve` cannot.
        try Self.ensureProjectTrust(
            workingDirectory: workingDirectory,
            configDirectory: ResolvedConfiguration.resolveConfigDirectory(environment: environment),
            trustFlag: trust,
            canPrompt: prompt == nil && !serve && isatty(STDIN_FILENO) == 1
        )

        let configuration = try ResolvedConfiguration.load(
            cli: CLIOverrides(baseURL: baseURL, model: model),
            environment: environment,
            workingDirectory: workingDirectory
        )

        // Teach the redaction vault this process's ACTUAL secrets, at the one
        // moment they are all known and before anything can print a diagnostic.
        Self.registerProcessSecrets(configuration)

        // Bootstrap logging to stderr *before* anything can log. The stock
        // swift-log handler writes to stdout, which would corrupt the output
        // channel; routing it to stderr is what keeps stdout clean.
        Self.bootstrapLogging(level: configuration.logLevel)

        // Resolution warnings — a setting that parsed as JSON but means nothing,
        // such as `"logLevel": "verbose"`. They go to stderr, never stdout, so
        // `-p` and `--json` stay byte-clean for a pipe. Without this the
        // resolver's diagnosis is computed and thrown away, which is the exact
        // kind of dead substrate this phase exists to remove.
        //
        // Scrubbed on the way out, like every other diagnostic. A warning QUOTES
        // the value it could not understand, and a settings value is now allowed
        // to be an interpolated `{env:…}` — so `"logLevel": "{env:MY_GATEWAY_KEY}"`
        // is a one-line typo that otherwise prints the gateway key to stderr and
        // into whatever CI log is capturing it. (The three BUILT-IN credential
        // variables cannot be reached that way at all — they are on
        // ``DoMoCore/InterpolationPolicy/deniedEnvironmentNames`` — but a key under
        // a name the operator chose is exactly the case `apiKeyEnv` exists for.)
        // This is emitted after ``registerProcessSecrets(_:)`` on purpose: the
        // vault has to know the secret before anything asks it to scrub one.
        for warning in configuration.warnings {
            Self.writeStderr("warning: \(Redaction.diagnostic(warning))\n")
        }

        guard let model = configuration.model, !model.isEmpty else {
            throw DoMoError(
                .configuration,
                "No model configured. Set --model, \(EnvName.model), or \"model\" in settings.json."
            )
        }
        // 0 is accepted and means unlimited (see ``turnLimit``); only a negative
        // budget is a usage error.
        if let maxTurns, maxTurns < 0 {
            throw DoMoError(.configuration, "--max-turns must be 0 (unlimited) or greater (got \(maxTurns)).")
        }

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

        // No `-p`: run interactively. The full-screen two-pane client is the
        // default (it drives a loopback runtime over the same HTTP/SSE surface a
        // remote one would); `--inline` selects the classic inline REPL, and
        // `--url` attaches the client to an already-running `domo --serve`. The live
        // terminal collaborators are assembled on the main actor so the
        // non-`Sendable` output target never crosses an isolation boundary.
        guard let prompt, !prompt.isEmpty else {
            if inline {
                let mode = try await InteractiveMode.make(
                    clientConfiguration: configuration.clientConfiguration,
                    model: model,
                    workingDirectory: workingDirectory.string,
                    sessionDirectory: configuration.sessionDirectory.string,
                    configDirectory: configuration.configDirectory.string,
                    homeDirectory: environment["HOME"],
                    reasoningEffort: configuration.reasoningEffort,
                    maxTurns: turnLimit,
                    sessionSource: sessionSource,
                    mcpServers: configuration.mcpServers,
                    mcpLog: { Self.writeStderr($0 + "\n") },
                    // The per-alias trio, and the reason `SurfaceWiringTests` drives
                    // this surface on a real pty. `InteractiveMode.make` defaults all
                    // three of them, so deleting them here still COMPILES while
                    // changing what every `--inline` session bills, meters and
                    // compacts on — and the REPL's own tests build their own
                    // `InteractiveMode` with arguments of their own, so nothing but a
                    // run of the real binary observes what this line hands it.
                    modelRuntime: configuration.modelRuntime(for: model),
                    modelRuntimeFor: { configuration.modelRuntime(for: $0) },
                    compaction: configuration.compaction,
                    summarizer: Self.compactionSummarizer(configuration, model: model),
                    credentialEnvNames: Self.gatewayCredentialEnvNames(configuration)
                )
                try await Self.runInteractive(
                    mode,
                    clipboardPaste: SystemClipboardPasteSource.make(environment: environment)
                )
            } else {
                try await Self.runClient(
                    configuration: configuration,
                    model: model,
                    workingDirectory: workingDirectory,
                    maxTurns: turnLimit,
                    environment: environment,
                    noMouse: noMouse,
                    serverURL: serverURL,
                    serverToken: serverToken
                )
            }
            return
        }

        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(
            at: workingDirectory,
            shell: shell,
            environment: Self.toolEnvironment(configuration)
        )
        let registry = ToolRegistry.builtin
        let client = LiteLLMClient(configuration: configuration.clientConfiguration)

        // The permission gate (Phase 8). Headless has no human to prompt, so a tool
        // that resolves to `ask` is refused with a model-visible reason unless
        // `--yolo` auto-approves it. Read-only tools run silently under the baseline.
        let homeDirectory = environment["HOME"] ?? NSHomeDirectory()
        let permissionHook = PermissionSetup.headlessHook(
            workingDirectory: workingDirectory.string,
            configDirectory: configuration.configDirectory.string,
            homeDirectory: homeDirectory,
            yolo: yolo
        )

        // Load image attachments BEFORE connecting MCP: loadImageAttachments can throw on
        // a bad `--image` path, and a throw here must not have spawned MCP servers that
        // nothing then tears down.
        let attachments = try Self.loadImageAttachments(images)

        // MCP tools (Phase 8c): connect the configured stdio servers and append their
        // tools. Torn down after the run — the servers run in their own process group,
        // so an un-shut-down server would be orphaned.
        let (mcpTools, mcpManager) = await Self.connectMCP(configuration, workingDirectory: workingDirectory)

        // Hide any MCP tool a `deny` rule blocks (Phase 8d visibility). The ruleset is the
        // same one headlessHook resolves internally (resolvedRuleset is pure over the same
        // settings files), so what is hidden matches what would be denied at call time.
        let visibleMcp = PermissionSetup.visibleMCPTools(
            mcpTools,
            ruleset: PermissionSetup.resolvedRuleset(
                workingDirectory: workingDirectory.string,
                configDirectory: configuration.configDirectory.string,
                homeDirectory: homeDirectory
            )
        )
        let promptWorkspace = try SystemPromptBuilder(
            workingDirectory: workingDirectory,
            configDirectory: configuration.configDirectory,
            toolNames: registry.names + visibleMcp.map(\.definition.name),
            projectTrusted: true
        ).build()
        let commandProcessor = PromptCommandProcessor(
            workspace: promptWorkspace,
            workingDirectory: workingDirectory,
            shell: shell,
            allowInlineShell: true
        )

        let printMode = PrintMode(
            client: client,
            registry: registry,
            toolContext: toolContext,
            workingDirectory: workingDirectory,
            mode: json ? .json : .text,
            maxTurns: turnLimit,
            channel: OutputChannel(),
            sessionSource: sessionSource,
            sessionDirectory: configuration.sessionDirectory,
            beforeToolCall: permissionHook,
            mcpTools: visibleMcp,
            modelRuntime: configuration.modelRuntime(for: model),
            compaction: configuration.compaction,
            summarizer: Self.compactionSummarizer(configuration, model: model, client: client),
            promptWorkspace: promptWorkspace,
            commandProcessor: commandProcessor,
            commandRuntimeFactory: { commandModel, effort in
                var selected = configuration.modelRuntime(for: commandModel ?? model)
                if let effort { selected.reasoningEffort = effort }
                return selected
            }
        )

        let code: Int32
        do {
            code = try await printMode.run(prompt: prompt, attachments: attachments)
        } catch {
            await mcpManager.shutdown()
            throw error
        }
        await mcpManager.shutdown()
        if code != 0 {
            throw ExitCode(code)
        }
    }

    /// Connect the configured stdio MCP servers and collect their tools. Returns the
    /// tools plus the manager the caller must `shutdown()` after the run (the servers
    /// spawn in their own process group and would otherwise be orphaned).
    static func connectMCP(
        _ configuration: ResolvedConfiguration,
        workingDirectory: FilePath
    ) async -> (tools: [any AgentTool], manager: MCPManager) {
        let manager = MCPManager()
        guard !configuration.mcpServers.isEmpty else { return ([], manager) }
        let tools = await manager.connect(
            servers: configuration.mcpServers,
            workspaceDirectory: workingDirectory.string,
            // Scrub the LLM-gateway credential variables from each MCP child's
            // environment — an untrusted server has no business reading them.
            // This used to be the hardcoded ``EnvName/apiKeyFallbacks`` triple,
            // which silently exempted the one name a user chose for themselves:
            // with `"apiKeyEnv": "MY_GATEWAY_KEY"` the key was handed intact to
            // every configured MCP server. See ``gatewayCredentialEnvNames(_:)``.
            sensitiveEnvKeys: Self.gatewayCredentialEnvNames(configuration),
            // Reserve the built-in tool names so an MCP tool can never shadow one.
            reservedNames: Set(ToolRegistry.builtin.names),
            log: { Self.writeStderr($0 + "\n") }
        )
        return (tools, manager)
    }

    // MARK: Credential hygiene

    /// Hands every secret this run resolved to the process-wide redaction vault.
    ///
    /// The pattern rules alone cannot catch a gateway key that carries no
    /// recognizable prefix, and the code that resolves a key and the code that
    /// renders a failure live in different modules and never meet — which is
    /// exactly why the vault is process-wide, and why this has to happen before
    /// anything can print a diagnostic.
    ///
    /// Every `mcpServers[*].environment` value is registered wholesale rather
    /// than only the credential-looking ones: that block exists to hand secrets
    /// to a child, and a name-based filter would miss the one a user spelled
    /// `GH_PAT`. The cost is that an innocuous value of eight characters or more
    /// (`production`) is also scrubbed out of diagnostics — the same trade
    /// ``Settings/keyCarriesCredential(_:)`` makes for that block.
    ///
    /// A named function rather than two lines inline, so the `GH_PAT` defence is
    /// something a test can call. Deleting either line used to leave the whole
    /// suite green.
    static func registerProcessSecrets(_ configuration: ResolvedConfiguration) {
        Redaction.register(configuration.apiKey)
        Redaction.registerAll(
            configuration.mcpServers.values.flatMap { server in (server.environment ?? [:]).values }
        )
    }

    /// Every environment variable name that holds THIS run's LLM-gateway
    /// credential.
    ///
    /// ``Redaction/secretEnvironmentNames`` is the fixed fallback chain
    /// (`DOMOCODE_API_KEY`, `LITELLM_API_KEY`, `OPENAI_API_KEY`). A settings file
    /// may name one more through `apiKeyEnv`, and that variable holds exactly the
    /// same secret — so a scrub list that omitted it handed the key straight to
    /// every MCP server and every `bash` command the model chose to run. The union
    /// is computed in one place because the two scrub sites that need it (MCP
    /// children, tool subprocesses) must not be able to drift apart.
    static func gatewayCredentialEnvNames(_ configuration: ResolvedConfiguration) -> Set<String> {
        var names = Redaction.secretEnvironmentNames
        if let configured = configuration.apiKeyEnvName, !configured.isEmpty {
            names.insert(configured)
        }
        return names
    }

    /// The environment a tool subprocess runs under: this process's, minus the
    /// gateway credential.
    ///
    /// ``DoMoTools/ToolContext/environment`` inherits, so before this the model
    /// could read the key with a one-word `bash` command (`env`). A `nil` override
    /// unsets the variable in the child — and it must be written with
    /// `updateValue(_:forKey:)`, because subscript-assigning `nil` to a dictionary
    /// whose values are already `Optional` REMOVES the entry instead of storing a
    /// nil under it, which would silently leave the variable inherited.
    static func toolEnvironment(_ configuration: ResolvedConfiguration) -> ShellEnvironment {
        var overrides: [String: String?] = [:]
        for name in gatewayCredentialEnvNames(configuration) {
            overrides.updateValue(nil, forKey: name)
        }
        return .inherit(overrides)
    }

    // MARK: Compaction

    /// The alias compaction should summarize with, or `nil` to leave the harness's
    /// own same-model fallback in place.
    ///
    /// `compaction.model` FIRST, then `smallModel`. Both name "the model to
    /// summarize with", and the more specific statement wins: `smallModel` is the
    /// general "use this cheaper alias for the small jobs", while
    /// `compaction.model` is about this job in particular. Reading only
    /// `smallModel` — which is what this did — made `compaction.model` a setting
    /// that parsed, merged, persisted and was asserted in tests while no
    /// production code ever read it.
    ///
    /// `smallModel` DEFAULTS to `model` (see ``ResolvedConfiguration/resolve(cli:environment:project:user:)``),
    /// so keying this on "is it non-nil" would install a CLI-built summarizer for
    /// every existing user and change a compaction path nobody asked to change.
    /// Only a genuinely different alias earns one — which is why the `!= model`
    /// guard applies to whichever of the two answered.
    static func compactionModel(_ configuration: ResolvedConfiguration, model: String) -> String? {
        let configured = configuration.compactionModel ?? configuration.smallModel
        guard let configured, !configured.isEmpty, configured != model else { return nil }
        return configured
    }

    /// The compaction summarizer for this run, or `nil` when nothing configured a
    /// distinct small model.
    ///
    /// - Parameter client: the run's own client, when there is one to share. The
    ///   inline REPL builds its client inside `InteractiveMode.make`, so that
    ///   surface passes nothing and a second client is constructed here. That is
    ///   cheap: ``DoMoLLM/AsyncHTTPClientTransport`` runs on
    ///   AsyncHTTPClient's process-wide shared `HTTPClient`, so the two clients
    ///   share one connection pool and neither owns a shutdown.
    static func compactionSummarizer(
        _ configuration: ResolvedConfiguration,
        model: String,
        client: LiteLLMClient? = nil
    ) -> Summarizer? {
        guard let small = compactionModel(configuration, model: model) else { return nil }
        return makeSummarizer(
            client: client ?? LiteLLMClient(configuration: configuration.clientConfiguration),
            model: small,
            runtime: configuration.modelRuntime(for: small)
        )
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
    private static func runInteractive(
        _ mode: InteractiveMode,
        clipboardPaste: any ClipboardPasteSource = NoClipboardPasteSource()
    ) async throws {
        let target = TerminalOutputTarget()
        let input = TerminalDriver.standardInputStream()
        let resize = TerminalSize.resizeStream()
        let lifecycle = TerminalLifecycle()
        try await mode.run(
            target: target,
            input: input,
            resize: resize,
            lifecycle: lifecycle,
            clipboardPaste: clipboardPaste
        )
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
        let (runtime, mcpManager) = try await Self.buildServerRuntime(
            configuration: configuration,
            model: model,
            workingDirectory: workingDirectory,
            maxTurns: turnLimit
        )
        let token = Self.generateToken()
        let server = DoMoServer(
            runtime: runtime,
            options: DoMoServer.Options(host: "127.0.0.1", port: port, token: token)
        )

        // The handshake line first, the redaction registration second, and in that
        // order on purpose: this line is how a `--url` client (and the end-to-end
        // test that drives one) learns the token, so registering the token before
        // writing it would only matter if this call were scrubbed — but the order
        // is pinned anyway, because the day this stderr path grows a scrub is the
        // day the handshake would silently start printing `[redacted]`.
        Self.writeStderr("Authorization: Bearer \(token)\n")
        // From here on the token is a secret like any other: a diagnostic that
        // echoes a request header must not reproduce it.
        Redaction.register(token)
        // Print the ACTUAL bound port from onReady, so `--serve --port 0` (ephemeral)
        // advertises the real port the OS assigned rather than the literal 0.
        do {
            try await server.run(onReady: { boundPort in
                Self.writeStderr("domo --serve — listening on http://127.0.0.1:\(boundPort) (loopback only)\n")
            })
        } catch {
            await mcpManager.shutdown()
            throw error
        }
        await mcpManager.shutdown()
    }

    /// Assemble the shared runtime ingredients — the sandboxed tool context, the
    /// system prompt, and the LiteLLM stream function — that both `--serve` and the
    /// in-process client spawn behind. The same wiring print mode builds.
    private static func buildServerRuntime(
        configuration: ResolvedConfiguration,
        model: String,
        workingDirectory: FilePath,
        maxTurns: Int?
    ) async throws -> (runtime: ServerRuntime, mcpManager: MCPManager) {
        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(
            at: workingDirectory,
            shell: shell,
            environment: Self.toolEnvironment(configuration)
        )
        let registry = ToolRegistry.builtin
        let client = LiteLLMClient(configuration: configuration.clientConfiguration)
        // The permission gate (Phase 8b) for the server — the same ruleset/factory/
        // persist the local surfaces use. This gates BOTH `--serve` and the loopback
        // client (both spawn through here); a tool needing approval prompts the client
        // over SSE and waits for the REST answer. Built BEFORE the tool assembly so the
        // ruleset can hide deny'd MCP tools (Phase 8d visibility).
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let permission = PermissionSetup.runtime(
            workingDirectory: workingDirectory.string,
            configDirectory: configuration.configDirectory.string,
            homeDirectory: home
        )
        // MCP tools (Phase 8c): the manager is returned so the caller tears the servers
        // down (they spawn in their own process group and would otherwise be orphaned).
        // Deny'd MCP tools are hidden from both the tool set and the system prompt.
        let (mcpTools, mcpManager) = await Self.connectMCP(configuration, workingDirectory: workingDirectory)
        let visibleMcp = PermissionSetup.visibleMCPTools(mcpTools, ruleset: permission.ruleset)
        let tools: [any AgentTool] = registry.all.map { RegistryTool(tool: $0, context: toolContext) } + visibleMcp
        let promptWorkspace = try SystemPromptBuilder(
            workingDirectory: workingDirectory,
            configDirectory: configuration.configDirectory,
            toolNames: registry.names + visibleMcp.map(\.definition.name),
            projectTrusted: true
        ).build()
        let commandProcessor = PromptCommandProcessor(
            workspace: promptWorkspace,
            workingDirectory: workingDirectory,
            shell: shell,
            allowInlineShell: true
        )
        // One resolved runtime for the alias — reasoning effort, per-alias rates and
        // the declared context window — built once and shared by the stream function
        // and the accounting the client's footer reads.
        let modelRuntime = configuration.modelRuntime(for: model)
        let streamFn = makeStreamFn(client: client, runtime: modelRuntime)
        var modelAliases = Set(configuration.modelOverrides.keys)
        modelAliases.insert(model)
        if let small = configuration.smallModel { modelAliases.insert(small) }
        let modelOptions = modelAliases.sorted().map { alias in
            let runtime = configuration.modelRuntime(for: alias)
            return ModelOption(id: alias, contextWindow: runtime.contextWindow)
        }
        let runtime = ServerRuntime(config: ServerRuntime.Config(
            systemPrompt: promptWorkspace.baseSystemPrompt,
            tools: tools,
            model: model,
            streamFn: streamFn,
            toolExecution: .sequential,
            maxTurns: maxTurns,
            sessionDirectory: configuration.sessionDirectory,
            cwd: workingDirectory.string,
            permissions: ServerRuntime.PermissionRuntime(
                ruleset: permission.ruleset,
                factory: permission.factory,
                persist: permission.persist
            ),
            // `nil` when nothing declared a window for this alias. It travels as
            // `nil` all the way to the footer, which renders "?" — never a
            // percentage of a guess.
            contextWindow: modelRuntime.contextWindow,
            compaction: configuration.compaction,
            summarizer: Self.compactionSummarizer(configuration, model: model, client: client),
            promptWorkspace: promptWorkspace,
            commandProcessor: commandProcessor,
            commandStreamFactory: { commandModel, effort in
                var selected = configuration.modelRuntime(for: commandModel ?? model)
                if let effort { selected.reasoningEffort = effort }
                return makeStreamFn(client: client, runtime: selected)
            },
            modelOptions: modelOptions,
            modelStreamFactory: { alias in
                makeStreamFn(client: client, runtime: configuration.modelRuntime(for: alias))
            },
            modelContextWindow: { alias in configuration.modelRuntime(for: alias).contextWindow }
        ))
        return (runtime, mcpManager)
    }

    // MARK: Full-screen client

    /// Run the default interactive experience — the two-pane full-screen client.
    ///
    /// Remote transport either way: with `--url` it attaches to an already-running
    /// `domo --serve`; otherwise it spawns a loopback ``DoMoServer`` on an ephemeral
    /// port (the real port comes back through `onReady`, so no port guessing) and
    /// drives that. The spawned server is torn down when the client returns. The
    /// terminal collaborators are assembled here on the main actor, exactly as the
    /// inline REPL's are.
    @MainActor
    private static func runClient(
        configuration: ResolvedConfiguration,
        model: String,
        workingDirectory: FilePath,
        maxTurns: Int?,
        environment: [String: String],
        noMouse: Bool,
        serverURL: String?,
        serverToken: String?
    ) async throws {
        let baseURL: String
        let token: String
        var serverTask: Task<Void, Never>?
        // The MCP manager for the locally-spawned server (nil under `--url`, where the
        // remote host owns its own MCP servers). Torn down when the client returns.
        var mcpManager: MCPManager?

        if let url = serverURL {
            baseURL = url
            token = serverToken ?? ""
            // `--token` is a bearer credential the operator typed on the command
            // line; a transport diagnostic that echoes the request header must not
            // reproduce it. (`register` ignores the empty string.)
            Redaction.register(token)
        } else {
            let (runtime, manager) = try await Self.buildServerRuntime(
                configuration: configuration,
                model: model,
                workingDirectory: workingDirectory,
                maxTurns: maxTurns
            )
            mcpManager = manager
            let generated = Self.generateToken()
            // Never announced anywhere (the client is in this process), but it is
            // still a bearer credential that a request-header dump would carry.
            Redaction.register(generated)
            let server = DoMoServer(
                runtime: runtime,
                options: DoMoServer.Options(host: "127.0.0.1", port: 0, token: generated)
            )
            let (ports, portContinuation) = AsyncStream.makeStream(of: Int.self)
            serverTask = Task {
                try? await server.run(onReady: { boundPort in
                    portContinuation.yield(boundPort)
                    portContinuation.finish()
                })
            }
            var boundPort = 0
            for await value in ports { boundPort = value; break }
            guard boundPort != 0 else {
                serverTask?.cancel()
                await mcpManager?.shutdown()
                throw DoMoError(.configuration, "The local runtime server did not bind a port.")
            }
            baseURL = "http://127.0.0.1:\(boundPort)"
            token = generated
        }

        let target = TerminalOutputTarget()
        let input = TerminalDriver.standardInputStream()
        let resize = TerminalSize.resizeStream()
        // The full-screen UI declares the terminal state it needs (alternate screen
        // + mouse reporting); this must not be a default-constructed lifecycle, as
        // it once was — see `fullScreenClientLifecycle`.
        //
        // `--no-mouse` is the one genuine caller choice here: a user who wants
        // their terminal's own selection and scrollback back asks for it, and the
        // app then never claims the mouse at all. It has to reach BOTH the
        // lifecycle (which decides whether the enable sequence is ever written)
        // and the app (whose `mouseOwned` is the truth an in-session toggle and
        // the status hint start from — a lifecycle that never took the mouse plus
        // an app that thinks it has it is the disagreement that would make a
        // toggle turn the mouse ON when the user asked for it off).
        let lifecycle = fullScreenClientLifecycle(enableMouse: !noMouse)
        do {
            try await runFullScreenClient(
                baseURL: baseURL,
                token: token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: lifecycle,
                // Prompt history is keyed by WORKSPACE and lands beside that
                // workspace's sessions. Under `--url` the key is the LOCAL
                // invocation directory — the remote runtime's cwd is not knowable
                // client-side — so two remote workspaces driven from the same local
                // directory share one history file.
                promptHistoryPath: PromptHistoryStore.defaultPath(
                    sessionDirectory: configuration.sessionDirectory,
                    cwd: workingDirectory.string
                ),
                // The clipboard half a terminal cannot do for itself. Resolved ONCE,
                // here, from this process's environment: DoMoClient has no
                // subprocess dependency and must not grow one so a right-click can
                // reach `pbcopy`. With no local helper this is `NoClipboardSink`,
                // which over ssh is the right answer rather than a degraded one —
                // OSC 52 is the path that reaches the clipboard that matters there.
                clipboard: SystemClipboard.makeClipboardSink(environment: environment),
                clipboardPaste: SystemClipboardPasteSource.make(environment: environment),
                // Whether an OSC 52 has to be wrapped to escape a multiplexer. Read
                // from the same environment, for the same reason: the detection is
                // about the process's own surroundings, which only the CLI can see.
                multiplexer: TerminalMultiplexer.detect(environment: environment),
                mouseOwned: !noMouse
            )
        } catch {
            serverTask?.cancel()
            await mcpManager?.shutdown()
            throw error
        }
        serverTask?.cancel()
        await mcpManager?.shutdown()
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
        trustFlag: Bool,
        canPrompt: Bool = false
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
                    + "local prompt resources will not be used. Pass --trust to override and re-trust it."
            )
        case .none:
            // Ask, when there is a human on a terminal to ask. Refusing outright made
            // every interactive session in any project holding local resources a
            // hard stop that could only be cleared by
            // re-running with a flag — for a question the user is standing right there
            // to answer. This is before raw mode and before any TUI, so a plain
            // line-read is the whole mechanism.
            if canPrompt, try Self.askToTrust(workingDirectory, store: store) {
                try store.setDecision(true, for: workingDirectory)
                return
            }
            // Deliberately does NOT record a refusal: a mistyped answer should not
            // lock the directory out permanently.
            throw DoMoError(
                .configuration,
                "Project \(workingDirectory.string) has local prompt resources that can change agent behavior, "
                    + "and this directory is not trusted. Re-run with --trust to trust it (recorded in "
                    + "\(store.path.string)), or remove the resources to run without them."
            )
        }
    }

    /// Ask on the terminal whether to trust this project. Anything but an explicit
    /// yes is a no, and EOF (stdin closed under us) is a no.
    private static func askToTrust(_ workingDirectory: FilePath, store: TrustStore) throws(DoMoError) -> Bool {
        writeStderr(
            "\nProject \(workingDirectory.string) has local prompt resources.\n"
                + "They can change agent behavior, so they are only used in directories you trust.\n"
                + "Trust this directory? [y/N] "
        )
        guard let answer = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        else {
            writeStderr("\n")
            return false
        }
        writeStderr("\n")
        return answer == "y" || answer == "yes"
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
