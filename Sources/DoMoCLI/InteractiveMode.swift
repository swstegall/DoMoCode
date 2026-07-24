// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The interactive REPL — what `domo` becomes when it is run with NO `-p`.
//
// This is original wiring rather than a line-for-line port of a single pi file:
// it *composes* the pieces the earlier slices ported (the `TUI`/`TerminalDriver`
// run loop, `Editor`, `Markdown`, `SelectList`, the `Autocomplete` providers, the
// `AgentHarness`, and the `DoMoToolsUI` renderers) into the live coding session pi
// grows in its `coding-agent` app shell (`app.ts` / `tui.ts` @ 9b3a2059). The shape
// is deliberately thin: every hard problem — differential rendering, key decoding,
// the agent loop, tool drawing — already lives behind a seam, so the REPL is just
// the glue that binds keystrokes to those seams and streamed ``AgentEvent``s to a
// scrolling transcript.
//
// Two facts drive the structure:
//
//   * **The whole thing is injectable.** ``InteractiveMode/run(target:input:resize:lifecycle:)``
//     takes the render target, the input byte stream, the resize stream, and the
//     terminal lifecycle as parameters, so the exact same loop that drives a live
//     TTY (real descriptors) is driven headlessly by a test (a scripted
//     ``AsyncStream`` in, a capturing ``RenderTarget`` out). There is no
//     "only on a real terminal" path in the wiring.
//
//   * **Steering is a CLI-boundary adaptation, not a harness feature.** pi injects a
//     message typed mid-run into the *current* turn via the loop's
//     `getSteeringMessages`. ``AgentHarness`` (Phase 3) does not forward that hook
//     into its ``AgentLoopConfig`` — see the report's "harness gap" — and this file
//     must not reach into another module to add it. So "steering" here is a queue at
//     the CLI: a prompt submitted while the agent is running is appended to a queue
//     and dispatched as the next ``AgentHarness/run(prompt:sink:)`` the instant the
//     current one settles. The session persists across those runs, so context still
//     accumulates; what differs from pi is that the steered text is processed after
//     the in-flight turn rather than injected into it.

import DoMoAgent
import DoMoCore
import DoMoExec
import DoMoHarness
import DoMoLLM
import DoMoTermIO
import DoMoToolsUI
import DoMoTUI
import DoMoTools
import Foundation
import Synchronization
import SystemPackage

// MARK: - Mutable transcript block

/// A transcript entry whose rendered content can be swapped in place.
///
/// A tool execution appears in the transcript the instant it *starts* — as a
/// muted "running" line — and is then replaced by its full ``ToolResultView`` when
/// it *ends*. A `Container` has no replace-at-index, and tracking shifting indices
/// is a bug farm, so each replaceable entry gets its own block whose `inner` the
/// coordinator reassigns. The block's identity in the transcript never changes;
/// only what it draws does.
@MainActor
final class MutableBlock: @MainActor Component {
    var inner: Component

    init(_ inner: Component) {
        self.inner = inner
    }

    func render(width: Int) -> [String] {
        inner.render(width: width)
    }
}

// MARK: - Status line

/// The one-line hint/affordance strip between the transcript and the editor.
///
/// It answers "what can I do right now": the idle affordances, or — while the
/// agent runs — that Escape interrupts. Always exactly one line, always clipped to
/// width, so it can never be the over-wide line the renderer treats as fatal.
@MainActor
final class StatusLine: @MainActor Component {
    var text: String = ""

    func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        return [truncateToWidth(text, width, ellipsis: "")]
    }
}

// MARK: - Prompt component

/// The focused component: the editor plus a thin input router.
///
/// It is what ``TUI`` focuses, so it is what receives every keystroke. Rather than
/// own the REPL's policy, it forwards two things to the coordinator — a submitted
/// prompt (via ``Editor/onSubmit``) and every raw key (via ``onInput``) — and lets
/// the coordinator decide routing (popup navigation, completion triggering, abort,
/// quit). It conforms to ``Focusable`` and mirrors its own focus onto the editor so
/// the editor keeps drawing its caret while the (non-capturing) completion popup is
/// up.
@MainActor
final class PromptComponent: @MainActor Focusable {
    let editor: Editor
    var onInput: ([UInt8]) -> Void = { _ in }

    var focused: Bool = false {
        didSet { editor.focused = focused }
    }

    init(editor: Editor) {
        self.editor = editor
    }

    var wantsKeyRelease: Bool { false }

    func render(width: Int) -> [String] {
        editor.render(width: width)
    }

    func handleInput(_ data: [UInt8]) {
        onInput(data)
    }

    func invalidate() {
        editor.invalidate()
    }
}

// MARK: - Event sink

/// Bridges the agent's ``AgentEvent`` stream onto the main-actor coordinator.
///
/// `emit` is `async` and the coordinator is main-actor-isolated, so each event
/// hops to the main actor and the run does not advance until the frame reflecting
/// it has been composed — the backpressure the ``AgentEventSink`` contract exists
/// to provide, used here to keep the transcript exactly in step with the loop.
struct InteractiveEventSink: AgentEventSink {
    let coordinator: InteractiveCoordinator

    func emit(_ event: AgentEvent) async {
        await coordinator.handle(event)
    }
}

// MARK: - Coordinator

/// Owns every piece of live REPL state and every decision the loop makes.
///
/// One main-actor object so the transcript, the editor, the completion popup, the
/// steering queue, and the in-flight run task are all touched from one isolation
/// domain with no locks. It is handed the already-built ``TUI``, ``TerminalDriver``
/// and ``AgentHarness`` and wires the editor/prompt callbacks to its own methods in
/// ``install()``.
@MainActor
final class InteractiveCoordinator {
    // Injected collaborators.
    private let tui: TUI
    private let driver: TerminalDriver
    private let quit: QuitSignal
    private let harness: AgentHarness
    private let provider: any AutocompleteProvider
    private let toolRendererRegistry: ToolRendererRegistry
    private let toolTheme: ToolRenderTheme
    private let homeDirectory: String?
    private let keybindings: Keybindings

    // Owned UI.
    private let transcript = Container()
    private let statusLine = StatusLine()
    private let editor: Editor
    private let prompt: PromptComponent

    // Prompt delivery: idle submissions flow through a stream the agent loop
    // awaits; submissions made while the agent runs are queued as steering (see
    // the file header) and drained before the loop next parks on the stream.
    private let submissions: AsyncStream<String>
    private let submissionsContinuation: AsyncStream<String>.Continuation
    private var steeringQueue: [String] = []

    // Run state.
    private var running = false
    private var currentRunTask: Task<RunStopReason, Never>?

    // Streaming assistant turn.
    private var currentAssistant: Markdown?
    private var assistantBuffer = ""

    // Tool executions, keyed by tool-call id so start/end line up regardless of
    // interleaving.
    private var toolBlocks: [String: MutableBlock] = [:]
    private var toolArgs: [String: JSONValue] = [:]

    // Completion popup.
    private var popupHandle: OverlayHandle?
    private var popupList: SelectList?
    private var popupItems: [AutocompleteItem] = []
    private var popupPrefix = ""
    /// Monotonic token so a superseded async suggestion lookup abandons its result
    /// rather than clobbering a newer keystroke's popup. A ``Mutex`` because the
    /// cancellation signal reads it from the (`Sendable`) provider closure that may
    /// run off the main actor, while the main actor bumps it on each keystroke.
    private let completionSeq = Mutex<Int>(0)

    private let idleStatus = "  @ file · / command · enter to send · esc to interrupt"
    private let runningStatus = "  ⋯ working — esc to interrupt"

    init(
        tui: TUI,
        driver: TerminalDriver,
        quit: QuitSignal,
        harness: AgentHarness,
        provider: any AutocompleteProvider,
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme,
        homeDirectory: String?,
        terminalRows: @escaping () -> Int,
        keybindings: Keybindings = Keybindings()
    ) {
        self.tui = tui
        self.driver = driver
        self.quit = quit
        self.harness = harness
        self.provider = provider
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
        self.homeDirectory = homeDirectory
        self.keybindings = keybindings

        self.editor = Editor(
            keybindings: keybindings,
            paddingX: 1,
            rows: terminalRows
        )
        self.prompt = PromptComponent(editor: editor)

        (submissions, submissionsContinuation) = AsyncStream.makeStream()
    }

    // MARK: Installation

    /// Wire callbacks and mount the component tree. Called once, before the driver
    /// starts, so the first frame already shows the (empty) editor.
    func install() {
        editor.onSubmit = { [weak self] text in self?.handleSubmit(text) }
        prompt.onInput = { [weak self] data in self?.handleKey(data) }

        tui.addChild(transcript)
        tui.addChild(statusLine)
        tui.addChild(prompt)
        tui.setFocus(prompt)
        statusLine.text = idleStatus
    }

    /// Flush a frame through the driver's synchronous seam. A no-op before the
    /// driver's `run` is active (there is no ``TUI`` bound yet), which is exactly
    /// when nothing needs painting.
    private func render() {
        driver.render()
    }

    // MARK: Input routing

    /// The REPL's whole key policy, applied to one framed key.
    ///
    /// With the completion popup up, navigation/confirm/cancel keys drive the popup
    /// and every other key falls through to the editor (so typing narrows the
    /// matches). With no popup, Tab opens file completion, Escape interrupts a
    /// running agent, Ctrl+C is the layered clear/interrupt/quit, and everything
    /// else edits — after which a fresh suggestion lookup decides whether a popup
    /// should appear.
    private func handleKey(_ data: [UInt8]) {
        let kb = keybindings

        if popupList != nil {
            if kb.matches(data, .selectUp) || kb.matches(data, .selectDown) {
                popupList?.handleInput(data)
                render()
                return
            }
            if kb.matches(data, .inputTab) || kb.matches(data, .selectConfirm) {
                applyCompletion()
                return
            }
            if kb.matches(data, .selectCancel) {
                closePopup()
                render()
                return
            }
            // Any other key edits the buffer and re-queries the popup below.
        } else {
            if kb.matches(data, .inputTab) {
                refreshCompletion(force: true)
                return
            }
            if matchesKey(data, Key.escape) {
                if running { abortRun() }
                return
            }
            if kb.matches(data, .inputCopy) {
                handleInterrupt()
                return
            }
        }

        editor.handleInput(data)
        refreshCompletion(force: false)
        render()
    }

    /// Ctrl+C, layered like pi's: dismiss a popup, else interrupt a run, else clear
    /// a non-empty editor, else quit.
    private func handleInterrupt() {
        if popupList != nil {
            closePopup()
            render()
            return
        }
        if running {
            abortRun()
            return
        }
        if !editor.getText().isEmpty {
            editor.setText("")
            render()
            return
        }
        quit.quit()
    }

    /// Cancel the in-flight run. The loop settles it as ``RunStopReason/aborted``
    /// and returns a clean transcript — no throw — so ``runOne(_:)`` simply resumes
    /// past its `await` and marks the turn interrupted.
    private func abortRun() {
        currentRunTask?.cancel()
    }

    // MARK: Submit + slash commands

    /// Handle a submitted line: run the small slash-command set inline, otherwise
    /// echo the user turn and dispatch it (or queue it as steering when busy).
    private func handleSubmit(_ text: String) {
        closePopup()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editor.addToHistory(trimmed)

        switch trimmed {
        case "/exit", "/quit":
            quit.quit()
            return
        case "/clear":
            transcript.clear()
            currentAssistant = nil
            assistantBuffer = ""
            toolBlocks.removeAll()
            toolArgs.removeAll()
            render()
            return
        default:
            break
        }

        appendUser(trimmed)
        render()

        if running {
            steeringQueue.append(trimmed)
        } else {
            submissionsContinuation.yield(trimmed)
        }
    }

    // MARK: Completion popup

    /// Kick off an async suggestion lookup for the cursor's current context. The
    /// lookup is cancellable by a newer keystroke (``completionSeq``); its result,
    /// if still current, either shows/refreshes the popup or dismisses it.
    private func refreshCompletion(force: Bool) {
        let lines = editor.getLines()
        let (line, col) = editor.getCursor()
        let seq = completionSeq.withLock { value -> Int in
            value += 1
            return value
        }
        let provider = self.provider

        Task { @MainActor in
            let signal = CancellationSignal { self.completionSeq.withLock { $0 } != seq }
            let suggestions = await provider.getSuggestions(
                lines: lines,
                cursorLine: line,
                cursorCol: col,
                force: force,
                signal: signal
            )
            guard self.completionSeq.withLock({ $0 }) == seq else { return }
            if let suggestions, !suggestions.items.isEmpty {
                self.showPopup(suggestions)
            } else {
                self.closePopup()
            }
            self.render()
        }
    }

    /// (Re)build the popup for a batch of suggestions. Rebuilding the list on every
    /// keystroke is cheap and sidesteps a stateful in-place update; the popup is a
    /// *non-capturing* overlay so focus (and the caret) stay on the editor while it
    /// is up.
    private func showPopup(_ suggestions: AutocompleteSuggestions) {
        closePopup()
        popupPrefix = suggestions.prefix
        popupItems = suggestions.items
        let items = suggestions.items.map {
            SelectItem(value: $0.value, label: $0.label, description: $0.description)
        }
        let maxVisible = min(8, max(1, items.count))
        let list = SelectList(items: items, maxVisible: maxVisible, keybindings: keybindings)
        popupList = list
        popupHandle = tui.showOverlay(
            list,
            options: OverlayOptions(
                width: .absolute(48),
                minWidth: 20,
                maxHeight: .absolute(maxVisible + 1),
                anchor: .bottomLeft,
                margin: OverlayMargin(bottom: 4, left: 0),
                nonCapturing: true
            )
        )
    }

    /// Apply the highlighted completion to the editor and dismiss the popup.
    ///
    /// The editor exposes no "set lines and place caret", so the applied result is
    /// written with ``Editor/setText(_:)`` (caret to end). For the common case —
    /// completing at the end of what you are typing — that is where the caret
    /// belongs anyway; drilling further into a directory is a fresh Tab away.
    private func applyCompletion() {
        guard
            let selected = popupList?.getSelectedItem(),
            let item = popupItems.first(where: { $0.value == selected.value })
        else {
            closePopup()
            render()
            return
        }
        let lines = editor.getLines()
        let (line, col) = editor.getCursor()
        if let result = provider.applyCompletion(
            lines: lines,
            cursorLine: line,
            cursorCol: col,
            item: item,
            prefix: popupPrefix
        ) {
            editor.setText(result.lines.joined(separator: "\n"))
        }
        closePopup()
        render()
    }

    private func closePopup() {
        popupHandle?.hide()
        popupHandle = nil
        popupList = nil
    }

    // MARK: Agent loop

    /// The concurrent driver of turns, run as the ``TerminalDriver``'s background
    /// job. It prefers a queued steering message, else parks on the submissions
    /// stream; a cancelled task (the session ending) breaks the loop.
    func agentLoop() async {
        var iterator = submissions.makeAsyncIterator()
        while !Task.isCancelled {
            let prompt: String
            if !steeringQueue.isEmpty {
                prompt = steeringQueue.removeFirst()
            } else if let next = await iterator.next() {
                prompt = next
            } else {
                break
            }
            await runOne(prompt)
        }
    }

    /// Run a single prompt to completion through the harness, streaming into the
    /// transcript via the sink, cancellable via ``currentRunTask``.
    private func runOne(_ prompt: String) async {
        running = true
        currentAssistant = nil
        assistantBuffer = ""
        statusLine.text = runningStatus
        render()

        let sink = InteractiveEventSink(coordinator: self)
        let task = Task { @MainActor () -> RunStopReason in
            do {
                let result = try await self.harness.run(prompt: prompt, sink: sink)
                return result.stopReason
            } catch is CancellationError {
                return .aborted
            } catch {
                self.appendError(String(describing: error))
                return .errored
            }
        }
        currentRunTask = task
        // Bridge the unstructured run task to structured cancellation: when the
        // agent loop's own task is cancelled (a quit binding fired, or stdin
        // reached EOF, so the driver cancelled its task group), propagate that to
        // the in-flight harness run. Without this the run task keeps going —
        // `Task<_, Never>.value` never throws on the awaiter's cancellation — so
        // the loop stays parked here and the driver cannot reach its terminal
        // restore until the turn finishes on its own (indefinitely if the model
        // hangs), leaving raw mode set the whole time.
        let reason = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        currentRunTask = nil

        running = false
        statusLine.text = idleStatus
        if reason == .aborted {
            appendInterrupted()
        }
        render()
    }

    // MARK: Event handling

    /// Translate one ``AgentEvent`` into a transcript mutation and repaint.
    func handle(_ event: AgentEvent) {
        switch event {
        case .messageStart(let message):
            if case .assistant = message { startAssistantBlock() }
        case .messageUpdate(_, let assembly):
            if case .textDelta(_, let delta) = assembly { appendAssistantText(delta) }
        case .messageEnd(let message):
            if case .assistant(let assistant) = message { finalizeAssistant(assistant) }
        case .toolExecutionStart(let id, let name, let arguments):
            startTool(id: id, name: name, arguments: arguments.value)
        case .toolExecutionEnd(let id, let name, let result, let isError):
            endTool(id: id, name: name, result: result, isError: isError)
        case .agentStart, .agentEnd, .turnStart, .turnEnd:
            break
        }
        render()
    }

    // MARK: Transcript mutation

    private func appendUser(_ text: String) {
        transcript.addChild(Text("❯ " + text))
    }

    private func appendInterrupted() {
        transcript.addChild(Text("  ⛔ interrupted"))
    }

    private func appendError(_ message: String) {
        transcript.addChild(Text("  ⚠ " + message))
    }

    private func startAssistantBlock() {
        let markdown = Markdown("", streaming: true)
        transcript.addChild(markdown)
        currentAssistant = markdown
        assistantBuffer = ""
    }

    private func appendAssistantText(_ delta: String) {
        assistantBuffer += delta
        currentAssistant?.setText(assistantBuffer)
    }

    private func finalizeAssistant(_ assistant: AssistantMessage) {
        let full = assistant.text
        if full.isEmpty {
            // A tool-only turn produced no prose; drop the empty block so the
            // transcript does not carry a blank assistant entry.
            if let markdown = currentAssistant { transcript.removeChild(markdown) }
        } else {
            currentAssistant?.setText(full)
        }
        currentAssistant = nil
        assistantBuffer = ""
    }

    private func startTool(id: String, name: String, arguments: JSONValue) {
        let block = MutableBlock(Text("  ⚙ \(name) …"))
        transcript.addChild(block)
        toolBlocks[id] = block
        toolArgs[id] = arguments
    }

    private func endTool(id: String, name: String, result: AgentToolResult, isError: Bool) {
        let toolResult = ToolResult(
            content: [.text(result.output)],
            isError: isError,
            details: result.details
        )
        let view = ToolResultView(
            registry: toolRendererRegistry,
            toolName: name,
            arguments: toolArgs[id] ?? .object([:]),
            result: toolResult,
            theme: toolTheme,
            homeDirectory: homeDirectory
        )
        if let block = toolBlocks[id] {
            block.inner = view
        } else {
            transcript.addChild(MutableBlock(view))
        }
    }
}

// MARK: - Interactive mode

/// The interactive REPL, constructed once and run against an injected terminal.
///
/// `Sendable` by construction: everything it stores is a value or a `Sendable`
/// reference (the harness is an actor, the directory lister a `@Sendable` closure),
/// so it crosses onto the main actor in ``run(target:input:resize:lifecycle:)``
/// without ceremony. The autocomplete *provider* is deliberately **not** stored —
/// its provider objects are main-actor UI and are built inside `run` — so this type
/// stays a plain sendable bundle of run inputs.
public struct InteractiveMode: Sendable {
    private let harness: AgentHarness
    private let directoryLister: DirectoryLister
    private let slashCommands: [SlashCommand]
    private let homeDirectory: String?
    private let toolRendererRegistry: ToolRendererRegistry
    private let toolTheme: ToolRenderTheme

    private init(
        harness: AgentHarness,
        directoryLister: @escaping DirectoryLister,
        slashCommands: [SlashCommand],
        homeDirectory: String?,
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme
    ) {
        self.harness = harness
        self.directoryLister = directoryLister
        self.slashCommands = slashCommands
        self.homeDirectory = homeDirectory
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
    }

    /// The small, deliberately-minimal slash-command palette. Argument completion
    /// is out of scope (see ``SlashCommandProvider``); these complete by name only.
    public static let defaultSlashCommands: [SlashCommand] = [
        SlashCommand(name: "exit", description: "End the session"),
        SlashCommand(name: "clear", description: "Clear the transcript"),
    ]

    // MARK: Construction

    /// Build an interactive session: the LLM client, the sandboxed tool context,
    /// the built-in tools bound to it, the persisting harness for the chosen
    /// session, and the real ``DirectoryLister`` (sandbox- and gitignore-aware)
    /// behind `@` completion.
    ///
    /// Paths are `String` so a caller without `SystemPackage` in scope — a test,
    /// most often — can drive it. The heavy dependencies (`DoMoTools`,
    /// `DoMoExec`, `DoMoHarness`) are all constructed here, behind this factory, so
    /// the caller need not import them.
    public static func make(
        clientConfiguration: LiteLLMClient.Configuration,
        model: String,
        workingDirectory: String,
        sessionDirectory: String,
        homeDirectory: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        maxTurns: Int = 100,
        sessionSource: SessionSource = .new,
        toolTheme: ToolRenderTheme = .ansi
    ) async throws -> InteractiveMode {
        let workDirectory = FilePath(workingDirectory)
        let sessionDir = FilePath(sessionDirectory)

        let client = LiteLLMClient(configuration: clientConfiguration)
        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(at: workDirectory, shell: shell)
        let registry = ToolRegistry.builtin
        let tools = registry.all.map { RegistryTool(tool: $0, context: toolContext) }

        let streamFn: AgentStreamFn = { context in
            client.streamCompletion(
                model: model,
                context: context,
                reasoningEffort: reasoningEffort,
                onResponse: { _ in }
            )
        }

        let configuration = AgentHarness.Configuration(
            systemPrompt: PrintMode.systemPrompt(workingDirectory: workDirectory, toolNames: registry.names),
            tools: tools,
            model: model,
            streamFn: streamFn,
            // Sequential keeps tool-start/tool-result transcript order equal to the
            // model's own call order, which is what a reader expects to watch.
            toolExecution: .sequential,
            maxTurns: maxTurns
        )

        let harness = try await Self.makeHarness(
            sessionSource: sessionSource,
            workingDirectory: workDirectory,
            sessionDirectory: sessionDir,
            configuration: configuration
        )

        let lister = Self.directoryLister(fileSystem: toolContext.fileSystem)

        return InteractiveMode(
            harness: harness,
            directoryLister: lister,
            slashCommands: defaultSlashCommands,
            homeDirectory: homeDirectory,
            toolRendererRegistry: .builtin,
            toolTheme: toolTheme
        )
    }

    private static func makeHarness(
        sessionSource: SessionSource,
        workingDirectory: FilePath,
        sessionDirectory: FilePath,
        configuration: AgentHarness.Configuration
    ) async throws -> AgentHarness {
        switch sessionSource {
        case .new:
            return try AgentHarness.start(
                cwd: workingDirectory.string,
                sessionDirectory: sessionDirectory,
                configuration: configuration
            )
        case .resume(let path):
            return try AgentHarness.open(path: path, configuration: configuration)
        case .fork(let path):
            let base = try AgentHarness.open(path: path, configuration: configuration)
            return try await base.fork(sessionDirectory: sessionDirectory)
        }
    }

    // MARK: Run

    /// Run the interactive session against the injected terminal collaborators.
    ///
    /// Reuses the ported ``TerminalDriver`` verbatim: it binds the input byte
    /// stream, the resize stream and the lifecycle to a ``TUI`` and guarantees the
    /// terminal is restored however the session ends (quit, EOF, throw, cancel).
    /// The REPL's per-turn agent driving runs as the driver's `background` job, so
    /// keystrokes and the agent share the main actor and stream concurrently.
    ///
    /// A render error (an over-wide line escaped a component) or a startup error
    /// (the descriptor was not a terminal) recorded by the driver is surfaced here
    /// as a throw, so a caller can report *why* a session ended abnormally.
    @MainActor
    public func run(
        target: any RenderTarget,
        input: AsyncStream<[UInt8]>,
        resize: AsyncStream<TerminalSize>,
        lifecycle: any TerminalLifecycleControl
    ) async throws {
        let quit = QuitSignal()
        let tui = TUI(target: target, showHardwareCursor: true)
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        let provider = CombinedAutocompleteProvider(providers: [
            SlashCommandProvider(commands: slashCommands),
            FileCompletionProvider(lister: directoryLister),
        ])

        let coordinator = InteractiveCoordinator(
            tui: tui,
            driver: driver,
            quit: quit,
            harness: harness,
            provider: provider,
            toolRendererRegistry: toolRendererRegistry,
            toolTheme: toolTheme,
            homeDirectory: homeDirectory,
            terminalRows: { target.rows }
        )
        coordinator.install()

        await driver.run(tui, quit: quit, background: {
            await coordinator.agentLoop()
        })

        if let error = driver.startupError { throw error }
        if let error = driver.renderError { throw error }
    }

    // MARK: Directory lister

    /// A `@`-completion directory lister backed by the sandboxed filesystem and a
    /// gitignore matcher.
    ///
    /// Given a directory as the user typed it (`""`, `"src/"`), it resolves it
    /// through the sandbox (a path that escapes the root simply lists nothing, the
    /// sandbox's own refusal), lists the immediate children, and drops entries that
    /// are gitignored or in the always-ignored set. This is the real thing — no
    /// fake tree — while doing zero I/O the sandbox would not already permit.
    ///
    /// The gitignore scope is deliberately shallow: the root `.gitignore` plus the
    /// built-in `.git/`/`node_modules/` defaults. Per-directory ignore files nested
    /// deeper are not loaded here; the ``FileWalker`` does the full recursive
    /// matching and is the place to reach for when a deeper listing is wanted.
    private static func directoryLister(fileSystem: SandboxedFileSystem) -> DirectoryLister {
        let matcher = loadGitignore(root: fileSystem.workingDirectory)
        return { typed in
            let directory: FilePath = typed.isEmpty
                ? fileSystem.workingDirectory
                : fileSystem.absolutePath(FilePath(typed))
            guard let entries = try? await fileSystem.list(directory) else { return [] }

            var result: [DirectoryEntry] = []
            for entry in entries {
                let isDirectory = entry.kind == .directory
                let name = entry.name
                if name == ".git" || name == "node_modules" { continue }
                let relative = (typed.isEmpty ? "" : typed) + name
                if matcher.isIgnored(relative, isDirectory: isDirectory) { continue }
                result.append(DirectoryEntry(name: name, isDirectory: isDirectory))
            }
            return result
        }
    }

    /// Build a ``GitignoreMatcher`` from the always-ignored defaults plus the root
    /// `.gitignore`, if one exists. `Sendable`, so the lister closure that captures
    /// it stays `@Sendable`.
    private static func loadGitignore(root: FilePath) -> GitignoreMatcher {
        var matcher = GitignoreMatcher()
        matcher.push(GitignoreFile(base: "", contents: "node_modules/\n.git/\n"))
        let gitignorePath = root.appending(".gitignore")
        if let contents = try? String(contentsOfFile: gitignorePath.string, encoding: .utf8) {
            matcher.push(GitignoreFile(base: "", contents: contents))
        }
        return matcher
    }
}
