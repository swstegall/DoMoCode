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
//   * **Steering injects into the current run, pi's real semantics.** pi feeds a
//     message typed mid-run into the *current* turn via the loop's
//     `getSteeringMessages`; ``AgentHarness/Configuration`` now forwards that hook
//     into its ``AgentLoopConfig``, so the CLI plumbs it rather than faking it. A
//     ``SteeringBox`` — a `Mutex`-guarded `[Message]` — is the shared seam: the
//     harness's `getSteeringMessages` closure DRAINS it (called from the loop, off
//     the main actor), and a submit-while-running APPENDS to it (on the main actor).
//     A prompt submitted while the agent runs therefore reaches the *current* run's
//     next turn boundary, not a fresh run. Drain-and-clear is atomic under the lock,
//     so a message racing the loop's poll is either fully seen by that poll or held
//     whole for the next — never split, never lost. A message that lands after the
//     run's *last* poll (between poll and settle) stays in the box and is re-yielded
//     as the next run's prompt when the run settles, so it still carries forward
//     exactly as the old next-run queue did rather than vanishing. An idle submit,
//     as before, simply starts a new run through the submissions stream.

import DoMoAgent
import DoMoClient
import DoMoCore
import DoMoExec
import DoMoGit
import DoMoHarness
import DoMoLLM
import DoMoMCP
import DoMoPermissions
import DoMoTermGraphics
import DoMoTermIO
import DoMoToolsUI
import DoMoTUI
import DoMoTools
import Foundation
import Synchronization
import SystemPackage

// MARK: - Pending submission

/// One queued prompt, with whatever the user attached to it.
///
/// The submissions stream carried a bare `String` until images could be dropped
/// onto the prompt, at which point a bare string is a silent truncation of what
/// the user actually submitted: the drop stages BYTES, and a stream that can only
/// carry text drops them on the floor. Keeping the pair together means the two
/// places a submission can be re-queued — a fresh submit and
/// ``InteractiveMode/drainLeftoverSteering()`` — cannot disagree about what is in
/// the message.
struct PendingSubmission: Sendable {
    var text: String
    var images: [ImageBlock]

    init(text: String, images: [ImageBlock] = []) {
        self.text = text
        self.images = images
    }
}

// MARK: - Response metadata relay

/// A late-bound sink for the response headers of every LLM request this session
/// makes.
///
/// It exists for the same reason ``DoMoPermissions/PrompterBox`` does: the harness
/// — and therefore the stream function whose `onResponse` fires — is built by
/// `InteractiveMode.make`, long before `InteractiveMode.run` builds the coordinator
/// that can draw anything. Until a handler is installed the metadata is dropped,
/// which is correct: there is no transcript to write it to.
///
/// The inline REPL previously passed `onResponse: { _ in }`, so the "a fallback
/// fired and a different model answered" warning — which the README states the UI
/// must give "rather than lie" — existed on `-p` and nowhere else.
///
/// `Sendable` around a ``Mutex``: the handler is installed from the main actor and
/// invoked from the streaming client's task. The stored closure is read out of the
/// lock before it is called, so a handler that hops to the main actor never runs
/// with the lock held.
final class ResponseMetadataRelay: Sendable {
    private let handler = Mutex<(@Sendable (ResponseMetadata) -> Void)?>(nil)

    /// Install the sink (called once, when the surface's UI is ready).
    func set(_ sink: @escaping @Sendable (ResponseMetadata) -> Void) {
        handler.withLock { $0 = sink }
    }

    /// Forward one response head, or drop it when nothing is listening yet.
    func deliver(_ metadata: ResponseMetadata) {
        let sink = handler.withLock { $0 }
        sink?(metadata)
    }
}

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
///
/// ``trailing`` is the session's accounting, right-aligned against the same row.
/// It is dropped WHOLE when it does not fit rather than truncated with the left
/// side, because half of `$0.0312` is `$0.03` — a smaller number that still looks
/// like a number, which is exactly the class of quiet lie Phase 5a exists to
/// remove. Nothing on this strip is load-bearing enough to be worth showing
/// wrongly.
@MainActor
final class StatusLine: @MainActor Component {
    var text: String = ""
    /// The right-aligned accounting strip. Empty renders the row exactly as it
    /// rendered before there was one.
    var trailing: String = ""

    /// Columns of clear space kept between the hints and the accounting, so the
    /// two never read as one sentence.
    private static let gap = 2

    func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        let left = truncateToWidth(text, width, ellipsis: "")
        guard !trailing.isEmpty else { return [left] }
        let leftWidth = visibleWidth(left)
        let trailingWidth = visibleWidth(trailing)
        let padding = width - leftWidth - trailingWidth
        guard padding >= Self.gap else { return [left] }
        return [left + String(repeating: " ", count: padding) + trailing]
    }
}

// MARK: - Inline accounting strip

/// The three numbers the inline REPL reports about the session it is driving:
/// tokens used, money spent, and how full the context is.
///
/// Pure, and public, rather than a method on the coordinator: it can then be
/// exercised without a terminal, a harness or a gateway, which the `@MainActor`
/// coordinator needs all three of. That is how a formatter like this otherwise
/// ends up with no test at all.
///
/// Every number here comes from ``DoMoHarness/SessionAccounting``, which the
/// harness produces from the ONE running total it keeps. There is deliberately no
/// accumulator on this side: a second one is how `--inline` and `--serve` came to
/// be able to report different figures for the same session file.
///
/// The segment vocabulary — `tok`, `$`, `ctx N (P%)`, and `?` for "unknown" —
/// deliberately matches the full-screen client's footer, so a user who moves
/// between the two surfaces reads the same row. It remains a small inline-local
/// formatter because the two surfaces own different layout and refresh lifecycles;
/// if a third surface ever needs it, the vocabulary belongs in a module both can
/// import rather than a third copy.
public enum InlineAccountingSummary {

    /// `"tok 12.3k · $0.0031 · ctx 4.2k (2%)"`, or `""` when nothing is known yet.
    public static func text(_ accounting: SessionAccounting?) -> String {
        guard let accounting else { return "" }
        return [
            "tok " + compact(accounting.usage.totalTokens),
            cost(accounting),
            context(accounting),
        ].joined(separator: " · ")
    }

    /// What the session has spent.
    ///
    /// The exact decimal digits, not a fixed number of places: a turn that cost a
    /// third of a cent rounds to `$0.00` at two places, and "the meter reads zero"
    /// is the falsehood this phase exists to remove. Rendering the `Decimal`'s own
    /// description also keeps the number off `Double` entirely.
    ///
    /// A zero total on a session that demonstrably ran gets a trailing `?`. Two
    /// different situations produce that zero — a model nobody configured a price
    /// for, and a session file written before this phase recorded any cost at all
    /// — and neither is "it was free", so the strip marks it unknown with the same
    /// glyph the context meter uses rather than asserting either.
    static func cost(_ accounting: SessionAccounting) -> String {
        guard accounting.costTotal > 0 else {
            return accounting.turns > 0 && accounting.usage.totalTokens > 0 ? "$0.00?" : "$0.00"
        }
        return "$" + accounting.costTotal.description
    }

    /// How big the context is, and how much of the window it fills.
    ///
    /// An unknown ``DoMoHarness/SessionAccounting/contextWindow`` renders `(?)`
    /// and **never** a percentage. Compaction falls back to a 200K guess so that a
    /// session against an unrecognised model still compacts rather than growing
    /// into a provider overflow, but a percentage computed against that guess is
    /// indistinguishable on screen from one computed against the model's real
    /// window — which would replace the old lie with a new one.
    ///
    /// A context past its window reports the real figure rather than clamping at
    /// 100: it is a true state (the next turn is what compacts), and a meter
    /// pinned at 100% hides how far past it has gone. The 9999 ceiling is only so
    /// a nonsense window cannot widen the row without bound.
    static func context(_ accounting: SessionAccounting) -> String {
        let tokens = compact(accounting.contextTokens)
        guard let window = accounting.contextWindow, window > 0 else { return "ctx \(tokens) (?)" }
        return "ctx \(tokens) (\(min(9_999, accounting.contextTokens * 100 / window))%)"
    }

    /// A token count as `842`, `12.3k` or `1.4M`.
    ///
    /// The strip has to stay a roughly fixed handful of columns as a session
    /// grows — ``StatusLine`` drops it entirely once it stops fitting, so a count
    /// that widens by a digit every ten turns would eventually take the cost and
    /// the context meter off the screen with it.
    public static func compact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        // 999_950 and not 1_000_000: one decimal place already rounds to
        // "1000.0k" at that point, which is a unit nobody uses.
        if value < 999_950 { return tenths((value + 50) / 100, suffix: "k") }
        return tenths((value + 50_000) / 100_000, suffix: "M")
    }

    /// `count` is the value in TENTHS of the unit, so 123 renders `12.3k`.
    private static func tenths(_ count: Int, suffix: String) -> String {
        "\(count / 10).\(count % 10)\(suffix)"
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

// MARK: - Question selection

/// A question-specific selector. ``SelectList`` models one highlighted item and
/// calls back on Enter; a question with `multiple` needs a second bit of state
/// for checked rows, so that state stays local instead of changing the generic
/// command picker’s answer contract.
@MainActor
private final class InteractiveQuestionList: @MainActor Component {
    private let prompt: QuestionPrompt
    private let keybindings: Keybindings
    private var selectedIndex = 0
    private var checked: Set<Int> = []

    var onConfirm: ((QuestionAnswer) -> Void)?
    var onCancel: (() -> Void)?

    init(prompt: QuestionPrompt, keybindings: Keybindings) {
        self.prompt = prompt
        self.keybindings = keybindings
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        return prompt.options.enumerated().map { index, option in
            let active = index == selectedIndex
            let marker: String
            if prompt.allowsMultiple {
                marker = checked.contains(index) ? "→ [x] " : "  [ ] "
            } else {
                marker = active ? "→ " : "  "
            }
            let label = sanitizeUntrustedText(collapseToOneLine(option.label))
            let description = option.description.map { sanitizeUntrustedText(collapseToOneLine($0)) }
            let text: String
            if let description, !description.isEmpty {
                text = "(marker)(label) — (description)"
            } else {
                text = marker + label
            }
            return truncateToWidth(text, width, ellipsis: "")
        }
    }

    func handleInput(_ data: [UInt8]) {
        guard !prompt.options.isEmpty, !isKeyRelease(data) else { return }
        if keybindings.matches(data, .selectUp) {
            selectedIndex = selectedIndex == 0 ? prompt.options.count - 1 : selectedIndex - 1
            return
        }
        if keybindings.matches(data, .selectDown) {
            selectedIndex = selectedIndex == prompt.options.count - 1 ? 0 : selectedIndex + 1
            return
        }
        if prompt.allowsMultiple, data == [0x20] {
            if checked.contains(selectedIndex) {
                checked.remove(selectedIndex)
            } else {
                checked.insert(selectedIndex)
            }
            return
        }
        if keybindings.matches(data, .selectConfirm) {
            let indexes = prompt.allowsMultiple ? checked.sorted() : [selectedIndex]
            onConfirm?(QuestionAnswer(selectedLabels: indexes.map { prompt.options[$0].label }))
            return
        }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
        }
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
    private let commandProcessor: PromptCommandProcessor
    private let commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)?
    private let toolRendererRegistry: ToolRendererRegistry
    private let toolTheme: ToolRenderTheme
    private let homeDirectory: String?
    private let keybindings: Keybindings

    /// The terminal's inline-image capability and cell pixel size, detected once by
    /// `run` (the REPL owns the tty). A tool result's image blocks render through
    /// these; with no image protocol they degrade to a `[Image: …]` text marker.
    private let imageCapabilities: TerminalCapabilities
    private let cell: CellDimensions

    // Owned UI.
    private let transcript = Container()
    private let statusLine = StatusLine()
    private let editor: Editor
    private let prompt: PromptComponent

    // Prompt delivery: an idle submission flows through a stream the agent loop
    // awaits and starts a fresh run. A submission made while the agent runs is
    // appended to the shared ``SteeringBox`` instead, which the harness's
    // `getSteeringMessages` hook drains into the *current* run's next turn (see the
    // file header). The box is the same instance the harness ``Configuration`` was
    // built with.
    private let submissions: AsyncStream<PendingSubmission>
    private let submissionsContinuation: AsyncStream<PendingSubmission>.Continuation
    private let steering: SteeringBox
    private let questionBox: QuestionBox

    /// Images dropped onto the prompt and not yet sent.
    ///
    /// Held here rather than inside the editor because the editor's document is
    /// TEXT — a drop consumes the path it typed and leaves nothing behind, so
    /// something outside the document has to remember the bytes until the next
    /// submit. Cleared by `handleSubmit` (they ride that message) and by `/clear`
    /// (a cleared session must not carry invisible attachments forward).
    private var stagedImages: [LoadedImage] = []

    /// The local clipboard reader. The CLI supplies the subprocess-backed
    /// implementation; tests and remote callers can leave the no-op default.
    private let clipboardPaste: any ClipboardPasteSource

    // Run state.
    private var running = false
    private var currentRunTask: Task<RunStopReason, Never>?
    /// Escape is a user-visible action even if an upstream transport is slow to
    /// acknowledge cancellation. The marker is emitted once at the action site;
    /// the run still owns cleanup and settles normally in ``runOne(_:)``.
    private var abortRequested = false
    private var interruptedShown = false

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

    // Permission approval modal (Phase 8). One at a time — the loop prepares tool
    // calls sequentially, so a second prompt is never requested while one is up.
    private var permissionHandle: OverlayHandle?
    private var permissionList: SelectList?
    private var pendingPermission: CheckedContinuation<PermissionReply, Never>?
    /// Monotonic token so a superseded async suggestion lookup abandons its result
    /// rather than clobbering a newer keystroke's popup. A ``Mutex`` because the
    /// cancellation signal reads it from the (`Sendable`) provider closure that may
    /// run off the main actor, while the main actor bumps it on each keystroke.
    private let completionSeq = Mutex<Int>(0)

    private let idleStatus = "  @ file · / command · enter to send · esc to interrupt"

    /// The animation frame for the running/parked status line, advanced by
    /// ``progressTask``. The inline surface previously showed a STATIC "⋯ working"
    /// for the entire turn — through a ten-minute tool call, a model stall, or a
    /// wedged render loop — so there was nothing on screen that could distinguish
    /// "busy" from "dead".
    private var progressFrame = 0
    private var progressTask: Task<Void, Never>?
    /// The modal's row values in order, so Escape can find "Reject" without assuming
    /// a fixed layout (the "always" row is conditional).
    private var permissionItemValues: [String] = []
    /// A question batch is answered one prompt at a time. The continuation stays
    /// parked while the current selector owns input, and is resumed only after the
    /// whole batch is complete or cancelled.
    private var questionHandle: OverlayHandle?
    private var questionList: InteractiveQuestionList?
    private var pendingQuestion: CheckedContinuation<[QuestionAnswer]?, Never>?
    private var questionPrompts: [QuestionPrompt] = []
    private var questionAnswers: [QuestionAnswer] = []
    private var questionIndex = 0
    private static let progressFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// The status line while a turn is in flight — animated, and distinct while a
    /// tool call is parked on approval, which is the state most easily mistaken for
    /// a freeze.
    private var runningStatus: String {
        let glyph = Self.progressFrames[((progressFrame % 10) + 10) % 10]
        if pendingPermission != nil {
            return "  \(glyph) waiting for your approval — choose above"
        }
        if pendingQuestion != nil {
            return "  \(glyph) waiting for your answer — choose above"
        }
        return "  \(glyph) working — esc to interrupt"
    }

    /// The sandboxed filesystem, for resolving `@path` image mentions into
    /// attachments at submit time. `nil` in tests that drive the coordinator
    /// without a real tool context, which simply attach nothing.
    private let fileSystem: SandboxedFileSystem?

    init(
        tui: TUI,
        driver: TerminalDriver,
        quit: QuitSignal,
        harness: AgentHarness,
        provider: any AutocompleteProvider,
        commandProcessor: PromptCommandProcessor,
        commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)?,
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme,
        homeDirectory: String?,
        steering: SteeringBox,
        questionBox: QuestionBox,
        fileSystem: SandboxedFileSystem? = nil,
        terminalRows: @escaping () -> Int,
        keybindings: Keybindings = Keybindings(),
        imageCapabilities: TerminalCapabilities = TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false),
        cell: CellDimensions = .default,
        clipboardPaste: any ClipboardPasteSource = NoClipboardPasteSource()
    ) {
        self.tui = tui
        self.driver = driver
        self.quit = quit
        self.harness = harness
        self.steering = steering
        self.questionBox = questionBox
        self.fileSystem = fileSystem
        self.provider = provider
        self.commandProcessor = commandProcessor
        self.commandStreamFactory = commandStreamFactory
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
        self.homeDirectory = homeDirectory
        self.keybindings = keybindings
        self.imageCapabilities = imageCapabilities
        self.cell = cell
        self.clipboardPaste = clipboardPaste

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
        // The drop seam. `Editor` is the only layer that sees a WHOLE bracketed
        // paste (it buffers one across `handleInput` calls), so this is the only
        // place a dragged file can be recognised before its path is typed into the
        // document as literal text. Returning `true` swallows the paste entirely.
        editor.onPaste = { [weak self] pasted in self?.handleDroppedPaste(pasted) ?? false }
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

        // A permission prompt captures ALL input: arrows move the choice, Enter
        // confirms it, Ctrl-C rejects outright, Escape only MOVES the selection onto
        // Reject; every other key is swallowed so the editor cannot change while a
        // tool waits on a decision.
        if let list = permissionList {
            if isKeyRelease(data) { return }
            if kb.matches(data, .selectUp) || kb.matches(data, .selectDown) {
                list.handleInput(data)
                render()
            } else if kb.matches(data, .selectConfirm) {
                resolvePermission(Self.reply(for: list.getSelectedItem()?.value))
                render()
            } else if data == [0x03] {
                // Ctrl-C is an unambiguous single byte, so it can answer directly.
                // Checked BEFORE `.selectCancel`, which is bound to both Ctrl-C and
                // Escape, and Escape must not answer — see below.
                resolvePermission(.reject(message: nil))
                render()
            } else if kb.matches(data, .selectCancel) {
                // Escape SELECTS Reject; it does not answer. A terminal splits an
                // arrow key into `ESC` and `[B`, and if they land more than the
                // disambiguation window apart the lone `ESC` is delivered as a real
                // Escape — indistinguishable from a keypress here, since the tail only
                // arrives after we would already have replied. Answering on it meant a
                // cursor keystroke silently rejected the tool call. Mirrors the
                // full-screen client.
                list.setSelectedIndex(permissionItemValues.firstIndex(of: "reject") ?? 0)
                render()
            }
            return
        }

        // A structured question captures the rest of the keyboard. The selector
        // owns its arrow/checkbox state; this branch keeps the editor and popup
        // from seeing any of those bytes while the tool is suspended.
        if let list = questionList {
            if isKeyRelease(data) { return }
            list.handleInput(data)
            render()
            return
        }

        if popupList != nil {
            // A completion overlay is non-capturing: it must not steal the
            // interrupt gesture from a live agent. An asynchronous completion
            // result can arrive after submit and briefly recreate the overlay,
            // so check the running state before treating Escape as merely
            // "close popup".
            if running, matchesKey(data, Key.escape) {
                closePopup()
                abortRun()
                render()
                return
            }
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

        if kb.matches(data, .inputPasteImage) {
            pasteClipboard()
            return
        }

        editor.handleInput(data)
        refreshCompletion(force: false)
        render()
    }

    /// Read Ctrl-V from the injected local clipboard source. Images stay in the
    /// same in-memory staging queue as file drops; text is sanitized before it is
    /// appended to the editor, so clipboard control bytes can never reach the tty.
    private func pasteClipboard() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let image = await self.clipboardPaste.readImage() {
                self.stageClipboardImage(image)
                return
            }
            if let text = await self.clipboardPaste.readText() {
                let clean = Self.sanitizedForInsertion(text)
                if !clean.isEmpty {
                    let existing = self.editor.getExpandedText()
                    self.editor.setText(existing.isEmpty ? clean : existing + "\n" + clean)
                    self.refreshCompletion(force: false)
                    self.render()
                }
                return
            }
            self.appendAttachmentNotice("📋 clipboard has no readable image or text")
            self.render()
        }
    }

    private func stageClipboardImage(_ clipboardImage: ClipboardImage) {
        let data = clipboardImage.data
        let limits = ImageAttachmentLimits.default
        guard !data.isEmpty else {
            appendAttachmentNotice("📋 clipboard image is empty")
            render()
            return
        }
        guard data.count <= limits.maximumBytesPerImage else {
            appendAttachmentNotice(
                "📋 clipboard image is over the \(LoadedImage.formattedByteCount(limits.maximumBytesPerImage)) limit"
            )
            render()
            return
        }
        guard stagedImages.count < limits.maximumCount else {
            appendAttachmentNotice("📋 at most \(limits.maximumCount) images per message")
            render()
            return
        }
        let currentBytes = stagedImages.reduce(0) { $0 + $1.byteCount }
        guard currentBytes <= limits.maximumTotalBytes,
              data.count <= limits.maximumTotalBytes - currentBytes
        else {
            appendAttachmentNotice(
                "📋 clipboard image would exceed the \(LoadedImage.formattedByteCount(limits.maximumTotalBytes)) total limit"
            )
            render()
            return
        }
        guard let mediaType = FileContentProbe.imageMediaType(data) else {
            appendAttachmentNotice("📋 clipboard does not contain a supported image")
            render()
            return
        }

        let extensionName: String
        switch mediaType {
        case "image/jpeg": extensionName = "jpg"
        case "image/gif": extensionName = "gif"
        case "image/webp": extensionName = "webp"
        case "image/bmp": extensionName = "bmp"
        default: extensionName = "png"
        }
        stagedImages.append(
            LoadedImage(
                path: FilePath("/tmp/domocode-clipboard-\(UUID().uuidString).\(extensionName)"),
                displayName: "clipboard.\(extensionName)",
                mediaType: mediaType,
                data: data
            )
        )
        appendAttachmentNotice("📎 attached clipboard image")
        render()
    }

    /// Ctrl+C, layered like pi's: dismiss a popup, else interrupt a run, else clear
    /// a non-empty editor, else quit.
    private func handleInterrupt() {
        // Ctrl+C with a permission prompt up rejects it (and dismisses the modal).
        if permissionList != nil {
            resolvePermission(.reject(message: nil))
            render()
            return
        }
        if questionList != nil {
            cancelQuestionPrompt()
            return
        }
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
        guard running else { return }
        abortRequested = true
        currentRunTask?.cancel()
        if !interruptedShown {
            interruptedShown = true
            appendInterrupted()
            render()
        }
    }

    // MARK: Submit + slash commands

    /// Handle a submitted line: run the small slash-command set inline, otherwise
    /// echo the user turn and dispatch it (or queue it as steering when busy).
    private func handleSubmit(_ text: String) {
        closePopup()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A drop with no words is still a message: the images are the content.
        let staged = stagedImages
        guard !trimmed.isEmpty || !staged.isEmpty else { return }
        if !trimmed.isEmpty { editor.addToHistory(trimmed) }

        switch commandProcessor.localAction(for: trimmed) {
        case .some(.exit):
            quit.quit()
            return
        case .some(.clear):
            transcript.clear()
            currentAssistant = nil
            assistantBuffer = ""
            toolBlocks.removeAll()
            toolArgs.removeAll()
            // Attachments are invisible once their transcript lines are gone;
            // carrying them into the next message would send bytes the user has
            // no way to see are still staged.
            stagedImages = []
            render()
            return
        case .some(.compact):
            stagedImages = []
            guard !running else {
                appendStopNotice("/compact is unavailable while a turn is running")
                render()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let compacted = try await self.harness.compactNow()
                    await self.refreshAccounting()
                    self.appendStopNotice(
                        compacted
                            ? "context compacted"
                            : "nothing to compact in the current context"
                    )
                } catch {
                    self.appendError(error)
                }
                self.render()
            }
            return
        case .some(.context):
            stagedImages = []
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let messages = try await self.harness.contextMessages()
                    let accounting = try? await self.harness.accounting()
                    self.appendStopNotice(Self.contextSummary(messages: messages, accounting: accounting))
                } catch {
                    self.appendError(error)
                }
                self.render()
            }
            return
        case .some(.help):
            let names = commandProcessor.workspace.commands.commands
                .map { "/\($0.name)" }
                .joined(separator: " · ")
            appendStopNotice("commands: \(names)")
            render()
            return
        case .some(.tree):
            appendStopNotice("/tree is available in the full-screen client")
            render()
            return
        case .some(.diff), .some(.review):
            stagedImages = []
            appendStopNotice("/diff review is available in the full-screen client")
            render()
            return
        default:
            break
        }

        stagedImages = []
        if !trimmed.isEmpty { appendUser(trimmed) }
        render()

        let images = staged.map { ImageBlock(mediaType: $0.mediaType, data: $0.data) }
        if running {
            if commandProcessor.isCommand(trimmed) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        switch try await commandProcessor.resolve(trimmed) {
                        case .prompt(let rendered, _, _, _):
                            self.steering.enqueue(
                                .user(UserMessage(content: [.text(rendered)] + images.map(ContentBlock.image)))
                            )
                        case .local:
                            break
                        case .unknown(let name):
                            self.appendError(DoMoError(.configuration, "Unknown command /\(name)"))
                            self.render()
                        }
                    } catch {
                        self.appendError(error)
                        self.render()
                    }
                }
                return
            }
            // Steer the in-flight run: the harness's `getSteeringMessages` hook
            // drains this box at the current run's next turn boundary, so the text
            // joins the running agent rather than waiting for a fresh run. The user
            // turn is already echoed above; the loop's own `messageStart(.user)` for
            // the injected message is ignored by ``handle(_:)``, so it is not doubled.
            //
            // The message is built by hand rather than with `Message.user(_:)` so
            // the attachments ride it: the convenience builds a TEXT-ONLY message,
            // which is how a mid-run drop used to be silently discarded.
            steering.enqueue(
                .user(UserMessage(content: [.text(trimmed)] + images.map(ContentBlock.image)))
            )
        } else {
            submissionsContinuation.yield(PendingSubmission(text: trimmed, images: images))
        }
    }

    // MARK: Drag and drop

    /// Intercept a bracketed paste that is really a file drop.
    ///
    /// Dragging a file onto a terminal does not deliver a file — it makes the
    /// terminal *paste the path*, spelled differently by every terminal
    /// (backslash-escaped, quoted, `file://` percent-encoded, …). ``DroppedPaths``
    /// owns that grammar and returns every plausible reading; the disk decides
    /// which one was meant.
    ///
    /// Returns `true` only when the paste parses as one or more path-shaped
    /// tokens, so ordinary pasted prose and code are untouched — a paste that is
    /// not path-shaped never reaches the loader at all. The read itself happens on
    /// a detached task through `@concurrent` loaders, because a multi-megabyte
    /// image must not be read on the render loop.
    ///
    /// Resolution against ``POSIXFileSystem`` rather than the tool sandbox is
    /// deliberate and matches `--image`: a file the user physically dragged onto
    /// the window is trusted operator input, and refusing a screenshot from
    /// `~/Desktop` because the session is rooted in a project would make the
    /// gesture useless exactly when it is most wanted.
    private func handleDroppedPaste(_ pasted: String) -> Bool {
        let candidates = DroppedPaths.candidates(pasted)
        guard !candidates.isEmpty else { return false }

        let alreadyStaged = stagedImages
        Task { @MainActor [weak self] in
            let result = await ImageAttachmentLoader.resolveDrop(
                candidates: candidates,
                using: POSIXFileSystem(),
                alreadyLoaded: alreadyStaged
            )
            self?.finishDrop(result, rawText: pasted)
        }
        return true
    }

    /// Apply a resolved drop: stage what loaded, say what did not.
    ///
    /// A reading that did not resolve COMPLETELY means the paste was not a drop
    /// (or not one this surface can take), so the text goes into the document
    /// after all — the "never silently eat a path the user meant as text"
    /// guarantee. It lands at the END of the document rather than at the caret:
    /// this arrives asynchronously, by which time the caret is by definition in
    /// the middle of whatever the user has typed since, and splicing there
    /// produces mangled text.
    private func finishDrop(_ result: ImageAttachmentLoadResult, rawText: String) {
        // A cancelled batch is a gesture the user took back. Silence, not a
        // rejection notice per file.
        guard !result.wasCancelled else { return }

        if result.isCompleteSuccess {
            // Re-check identity HERE, not only against the snapshot the resolve
            // started from: two drops of the same file can be in flight at once,
            // and each would have been told it was the first.
            let staged = Set(stagedImages.map(\.path))
            let fresh = result.loaded.filter { !staged.contains($0.path) }
            stagedImages.append(contentsOf: fresh)
            for image in fresh {
                appendAttachmentNotice(
                    "📎 attached \(sanitizeUntrustedText(image.displayName)) "
                        + "(\(LoadedImage.formattedByteCount(image.byteCount)))"
                )
            }
            for duplicate in result.skippedDuplicates {
                appendAttachmentNotice(
                    "📎 \(sanitizeUntrustedText(duplicate.lastComponent?.string ?? duplicate.string))"
                        + " is already attached"
                )
            }
            render()
            return
        }

        // Not a drop we could take. Put the text back, and say why for the path
        // the user most likely meant.
        if let rejection = result.rejected.first {
            appendAttachmentNotice("📎 " + sanitizeUntrustedText(rejection.message))
        }
        let restored = Self.sanitizedForInsertion(rawText)
        if !restored.isEmpty {
            let existing = editor.getText()
            editor.setText(existing.isEmpty ? restored : existing + "\n" + restored)
        }
        render()
    }

    /// Strip everything a terminal would ACT on, keeping newlines.
    ///
    /// `Editor.handlePaste` applies exactly this filter, but `onPaste` returning
    /// `true` short-circuits it — so the one route that puts a refused drop's raw
    /// payload back into the document has to apply it itself. Line endings and
    /// tabs are folded first, the way `Editor.normalizeText` would, so a
    /// CR-separated multi-file drop keeps its line breaks.
    static func sanitizedForInsertion(_ text: String) -> String {
        var folded = text.replacingOccurrences(of: "\r\n", with: "\n")
        folded = folded.replacingOccurrences(of: "\r", with: "\n")
        folded = folded.replacingOccurrences(of: "\t", with: "    ")
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            if value == 0x0a {
                scalars.append(scalar)
                continue
            }
            if value < 0x20 || value == 0x7f || (value >= 0x80 && value <= 0x9f) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
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

    // MARK: Permission approval

    /// Show the approval modal and suspend until the user answers. This is the
    /// engine's prompter for the REPL. It runs on the main actor (the harness run is
    /// a `@MainActor` task), so it MUST NOT block: the `CheckedContinuation` frees the
    /// actor while the modal is up, and a keypress (or a cancellation) resumes it. A
    /// cancelled run — Escape while running from another path, EOF, quit — resumes it
    /// with a reject so the tool fiber never leaks.
    func showPermissionPrompt(_ request: PermissionRequest) async -> PermissionReply {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PermissionReply, Never>) in
                pendingPermission = continuation
                presentPermissionOverlay(request)
                // Say so in the status line too: the modal is centered, and a user
                // whose eyes are on the transcript otherwise sees only "working".
                statusLine.text = runningStatus
                render()
            }
        } onCancel: {
            Task { @MainActor in self.resolvePermission(.reject(message: nil)) }
        }
    }

    /// Resume the pending prompt with `reply` and tear down the modal. Idempotent —
    /// a keypress and a concurrent cancellation both call it, but only the first
    /// resumes the (single) continuation.
    private func resolvePermission(_ reply: PermissionReply) {
        guard let continuation = pendingPermission else { return }
        pendingPermission = nil
        permissionHandle?.hide()
        permissionHandle = nil
        permissionList = nil
        permissionItemValues = []
        // Put the status line back to plain "working": `runOne` only assigns it at the
        // start and end of a turn, so the approval-specific text would otherwise
        // persist for the whole remainder of the run.
        if running { statusLine.text = runningStatus }
        continuation.resume(returning: reply)
    }

    private static func reply(for value: String?) -> PermissionReply {
        switch value {
        case "once": return .once
        case "always": return .always
        default: return .reject(message: nil)
        }
    }

    private func presentPermissionOverlay(_ request: PermissionRequest) {
        var items = [SelectItem(value: "once", label: "Allow once", description: nil)]
        // Name the grant in the row itself — it is written to the user's global
        // settings.json and survives restarts — and offer it only when there is
        // something to grant.
        if !request.disableAlways, !request.always.isEmpty {
            let scope = request.always.count > 1
                ? "\(request.always[0]) +\(request.always.count - 1) more"
                : request.always[0]
            items.append(SelectItem(
                value: "always",
                label: "Always allow " + elideLeading(sanitizeUntrustedText(scope), width: 34),
                description: nil
            ))
        }
        items.append(SelectItem(value: "reject", label: "Reject", description: nil))

        let list = SelectList(items: items, maxVisible: items.count, keybindings: keybindings)
        permissionList = list
        permissionItemValues = items.map(\.value)

        let header = Self.permissionHeader(request)
        let container = Container()
        for line in header { container.addChild(Text(line, wrap: false)) }
        container.addChild(list)
        container.addChild(Text("\u{1b}[2m  ↑/↓ choose · enter confirm · esc selects Reject · ^C rejects\u{1b}[0m", wrap: false))

        // Budget the height from the rows the container ACTUALLY renders, not from a
        // count of header strings. A header string containing newlines renders as
        // several rows, so a multi-line bash command used to push the Allow/Reject
        // list straight off the bottom of the overlay — an approval prompt with no
        // visible way to approve. (The header is collapsed to one line now too; this
        // is the belt to that pair of braces.)
        let renderedRows = container.render(width: 62).count
        permissionHandle = tui.showOverlay(
            container,
            options: OverlayOptions(
                width: .absolute(64),
                minWidth: 30,
                maxHeight: .absolute(max(renderedRows, items.count + 1)),
                anchor: .center,
                nonCapturing: true
            )
        )
    }

    /// The modal's descriptive lines: what tool wants to run and on what.
    ///
    /// Collapsed to ONE line and sanitized: the value is model-controlled, so a
    /// multi-line `bash` command would otherwise grow the modal until the options fell
    /// off the screen, and a `ESC[2J` in it would erase the very prompt being answered.
    private static func permissionHeader(_ request: PermissionRequest) -> [String] {
        var lines = ["⚠ Allow \(sanitizeUntrustedText(request.permission))?"]
        let target: String? =
            request.metadata["command"]?.stringValue
            ?? request.metadata["filepath"]?.stringValue
            ?? request.patterns.first.flatMap { $0 == "*" ? nil : $0 }
        if let target, !target.isEmpty {
            lines.append("  " + truncateToWidth(sanitizeUntrustedText(collapseToOneLine(target)), 60))
        }
        return lines
    }

    // MARK: Structured questions

    /// Present a question batch without blocking the main actor. The handler is
    /// shaped like the tool's batch API, while the UI advances through prompts one
    /// by one so each answer is unambiguous.
    func showQuestionPrompt(_ prompts: [QuestionPrompt]) async -> [QuestionAnswer]? {
        guard !prompts.isEmpty else { return [] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[QuestionAnswer]?, Never>) in
                guard pendingQuestion == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingQuestion = continuation
                questionPrompts = prompts
                questionAnswers = []
                questionIndex = 0
                presentQuestionOverlay()
                statusLine.text = runningStatus
                render()
            }
        } onCancel: {
            Task { @MainActor in self.cancelQuestionPrompt() }
        }
    }

    private func presentQuestionOverlay() {
        questionHandle?.hide()
        questionHandle = nil
        questionList = nil
        guard questionIndex < questionPrompts.count else {
            finishQuestionPrompt()
            return
        }

        let prompt = questionPrompts[questionIndex]
        let list = InteractiveQuestionList(prompt: prompt, keybindings: keybindings)
        list.onConfirm = { [weak self] answer in self?.acceptQuestion(answer) }
        list.onCancel = { [weak self] in self?.cancelQuestionPrompt() }
        let title = prompt.header.map { sanitizeUntrustedText(collapseToOneLine($0)) }
            ?? "Question \(questionIndex + 1) of \(questionPrompts.count)"
        let question = sanitizeUntrustedText(collapseToOneLine(prompt.question))
        let inner = Container()
        inner.addChild(Text("? \(title)", wrap: false))
        inner.addChild(Text(truncateToWidth(question, 60, ellipsis: ""), wrap: false))
        inner.addChild(Spacer(lines: 1))
        inner.addChild(list)
        let hint = prompt.allowsMultiple
            ? "space toggle · enter confirm · esc cancel"
            : "↑/↓ choose · enter confirm · esc cancel"
        inner.addChild(Text("\u{1b}[2m\(hint)\u{1b}[0m", wrap: false))

        let rowCount = max(1, inner.render(width: 64).count)
        questionHandle = tui.showOverlay(
            inner,
            options: OverlayOptions(
                width: .absolute(64),
                minWidth: 30,
                maxHeight: .absolute(rowCount),
                anchor: .center,
                nonCapturing: true
            )
        )
        questionList = list
    }

    private func acceptQuestion(_ answer: QuestionAnswer) {
        guard pendingQuestion != nil else { return }
        questionAnswers.append(answer)
        questionIndex += 1
        if questionIndex < questionPrompts.count {
            presentQuestionOverlay()
            render()
        } else {
            finishQuestionPrompt()
        }
    }

    private func finishQuestionPrompt() {
        guard let continuation = pendingQuestion else { return }
        pendingQuestion = nil
        questionHandle?.hide()
        questionHandle = nil
        questionList = nil
        questionPrompts = []
        questionIndex = 0
        let answers = questionAnswers
        questionAnswers = []
        if running { statusLine.text = runningStatus }
        continuation.resume(returning: answers)
        render()
    }

    private func cancelQuestionPrompt() {
        guard let continuation = pendingQuestion else { return }
        pendingQuestion = nil
        questionHandle?.hide()
        questionHandle = nil
        questionList = nil
        questionPrompts = []
        questionAnswers = []
        questionIndex = 0
        if running { statusLine.text = runningStatus }
        continuation.resume(returning: nil)
        render()
    }

    // MARK: Agent loop

    /// The concurrent driver of turns, run as the ``TerminalDriver``'s background
    /// job. It parks on the submissions stream and runs each prompt to completion;
    /// a cancelled task (the session ending) breaks the loop.
    ///
    /// Mid-run submissions do not flow through here — they are steered into the
    /// current run via the ``SteeringBox``. The one thing this loop still owes the
    /// box is the settle-race tail: a message that landed *after* the just-finished
    /// run's last steering poll is still sitting in the box, so it is re-queued as
    /// the next run's prompt rather than being left to wait for an unrelated submit.
    func agentLoop() async {
        // Before parking on the first submission: a RESUMED session already has
        // tokens and a bill behind it, and a strip that only appears after the
        // first new turn would make a resumed session look free until it was
        // spent again.
        await refreshAccounting()
        render()
        var iterator = submissions.makeAsyncIterator()
        while !Task.isCancelled {
            guard let submission = await iterator.next() else { break }
            await runOne(submission)
            drainLeftoverSteering()
        }
    }

    // MARK: Accounting strip

    /// Re-read the session's totals and put them on the status line.
    ///
    /// The harness owns the only accumulator, so this is a READ — nothing here
    /// adds anything up. It is cached onto ``StatusLine/trailing`` rather than
    /// recomputed per repaint because ``AgentHarness/accounting()`` rebuilds the
    /// context to measure it and the status row repaints about ten times a second
    /// while a turn is in flight.
    ///
    /// A failure leaves the previous figures in place rather than blanking them:
    /// the numbers are a display, and a session whose path momentarily cannot be
    /// resolved still has a REPL to run. It does not silently show zeros — the
    /// last figures it actually read are the last true ones it had.
    private func refreshAccounting() async {
        guard let latest = try? await harness.accounting() else { return }
        statusLine.trailing = InlineAccountingSummary.text(latest)
    }

    /// The in-flight refresh, so a run that finishes several turns quickly queues
    /// one catch-up rather than one task per turn.
    private var accountingRefreshTask: Task<Void, Never>?

    /// Ask for a refresh from a synchronous context.
    ///
    /// ``handle(_:)`` is deliberately synchronous — it mutates the transcript and
    /// repaints in one uninterrupted main-actor step, and adding an `await` inside
    /// it would let another main-actor task interleave between the mutation and
    /// the frame. So the refresh is hopped onto its own main-actor task: the strip
    /// catches up a frame later, which is invisible beside a 10 Hz spinner.
    private func scheduleAccountingRefresh() {
        guard accountingRefreshTask == nil else { return }
        accountingRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshAccounting()
            self?.accountingRefreshTask = nil
            self?.render()
        }
    }

    /// Re-queue any steering message that arrived between the last run's final poll
    /// and its settle. The run is fully settled here (``runOne(_:)`` awaited its
    /// task to completion), so no loop is concurrently draining the box; the read is
    /// a plain main-actor step. Each leftover was appended as a `.user` message, so
    /// its text seeds a fresh run — the same "carry to the next run" the old
    /// next-run queue gave, without the message vanishing or being processed twice.
    private func drainLeftoverSteering() {
        for message in steering.drain() {
            if case .user(let user) = message {
                // Carry the IMAGES too. Re-queuing `user.text` alone silently threw
                // away any attachment a mid-run drop had put on the message, which
                // is the one place a leftover could lose content rather than just
                // arrive late.
                submissionsContinuation.yield(
                    PendingSubmission(
                        text: user.text,
                        images: user.content.compactMap {
                            if case .image(let block) = $0 { return block }
                            return nil
                        }
                    )
                )
            }
        }
    }

    /// Run a single prompt to completion through the harness, streaming into the
    /// transcript via the sink, cancellable via ``currentRunTask``.
    private func runOne(_ submission: PendingSubmission) async {
        let prompt = submission.text
        running = true
        abortRequested = false
        interruptedShown = false
        currentAssistant = nil
        assistantBuffer = ""
        statusLine.text = runningStatus
        startProgressClock()
        render()

        // Resolve any `@path` image mentions into attachments before the turn —
        // off the main actor (the read is `@concurrent`), so a large image does not
        // stall the renderer. The `@token` stays in the prompt as the reference.
        let mentioned = await Self.extractImageAttachments(from: prompt, fileSystem: fileSystem)
        // Dropped images first (the user attached them deliberately), then `@path`
        // mentions, deduplicated: dropping a file and ALSO naming it with `@` must
        // send one copy, not two.
        var attachments: [ImageBlock] = []
        var seen: Set<ImageBlock> = []
        for block in submission.images + mentioned where seen.insert(block).inserted {
            attachments.append(block)
        }

        let sink = InteractiveEventSink(coordinator: self)
        let task = Task { @MainActor () -> RunStopReason in
            do {
                let resolution = try await self.commandProcessor.resolve(prompt)
                let renderedPrompt: String
                let runOverride: AgentHarness.RunOverride?
                switch resolution {
                case .local(let action):
                    throw DoMoError(.configuration, "/\(action.rawValue) is a client-local command")
                case .unknown(let name):
                    throw DoMoError(.configuration, "Unknown command /\(name)")
                case .prompt(let rendered, let commandModel, let reasoningEffort, let systemPrompt):
                    renderedPrompt = rendered
                    let stream = self.commandStreamFactory?(commandModel, reasoningEffort)
                    runOverride = AgentHarness.RunOverride(
                        model: commandModel,
                        streamFn: stream,
                        systemPrompt: systemPrompt
                    )
                }
                let result = try await self.harness.run(
                    prompt: renderedPrompt,
                    attachments: attachments,
                    sink: sink,
                    runOverride: runOverride
                )
                return result.stopReason
            } catch is CancellationError {
                return .aborted
            } catch {
                if Task.isCancelled || DoMoError.isCancellation(error) {
                    return .aborted
                }
                self.appendError(error)
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
        stopProgressClock()
        statusLine.text = idleStatus
        // The settled run is the moment the totals are final for this turn set —
        // and the one refresh that is guaranteed to happen even if every mid-run
        // one was coalesced away.
        await refreshAccounting()
        let wasAborted = abortRequested || reason == .aborted
        if wasAborted {
            if !interruptedShown { appendInterrupted() }
        } else if let notice = Self.stopNotice(for: reason) {
            // A run that stopped WITHOUT finishing has to say so. Before this,
            // `.maxTurnsReached` produced no output whatsoever here — the REPL
            // simply went idle mid-task, which is indistinguishable from the model
            // deciding it was done.
            appendStopNotice(notice)
        }
        abortRequested = false
        interruptedShown = false
        render()
    }

    /// Advance the status-line spinner while a turn is in flight.
    ///
    /// ~10 Hz, and only the status row changes, so the differential renderer emits a
    /// single short row per tick rather than a frame. Cancelled the moment the run
    /// settles, so an idle REPL is completely silent.
    private func startProgressClock() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.running, !Task.isCancelled else { return }
                self.progressFrame &+= 1
                self.statusLine.text = self.runningStatus
                self.render()
            }
        }
    }

    private func stopProgressClock() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Resolve `@path` image mentions in a submitted line into image attachments.
    ///
    /// `@path` is the same file affordance the completion popup offers; when a
    /// mention names a readable image inside the sandbox, its bytes ride along as
    /// an attachment while the `@token` stays in the text as the model's reference.
    /// A non-image, a missing path, or a sandbox escape resolves to nothing — an
    /// `@` mention is a hint, not a promise, and a bad one must never fail the turn.
    /// Trailing sentence punctuation on a token is stripped so `@shot.png,` still
    /// resolves; duplicate mentions attach once.
    ///
    /// `@concurrent` so the reads run off the main actor: this is called from the
    /// main-actor run loop and a multi-megabyte image must not stall the renderer.
    @concurrent
    static func extractImageAttachments(
        from text: String,
        fileSystem: SandboxedFileSystem?
    ) async -> [ImageBlock] {
        guard let fileSystem else { return [] }
        var blocks: [ImageBlock] = []
        var seen: Set<String> = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            guard token.first == "@", token.count > 1 else { continue }
            var path = String(token.dropFirst())
            while let last = path.last, ".,;:!?)]}\"'".contains(last) { path.removeLast() }
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            guard let bytes = try? await fileSystem.read(FilePath(path)),
                let mediaType = FileContentProbe.imageMediaType(bytes)
            else { continue }
            blocks.append(ImageBlock(mediaType: mediaType, data: bytes))
        }
        return blocks
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
            if case .assistant(let assistant) = message {
                finalizeAssistant(assistant)
                // A turn just billed. Without this the strip would only move when
                // a whole run settled, so a long agentic run — the one where the
                // spend actually matters — would sit on stale numbers for minutes.
                scheduleAccountingRefresh()
            }
        case .toolExecutionStart(let id, let name, let arguments):
            startTool(id: id, name: name, arguments: arguments.value)
        case .toolExecutionEnd(let id, let name, let result, let isError):
            endTool(id: id, name: name, result: result, isError: isError)
        case .notice(let notice):
            appendNotice(notice)

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

    /// The SGR sequences the transcript's non-content rows use. Spelled here
    /// rather than reached for across a module boundary: `DoMoClient`'s `dim` and
    /// `sgrReset` are internal to that target and its transcript styling is not
    /// interchangeable with the inline surface's compact rows.
    private static let sgrReset = "\u{1b}[0m"
    private static func dim(_ text: String) -> String { "\u{1b}[2m" + text + sgrReset }

    /// A failure that came back as a THROW rather than as a settled run — harness
    /// construction, session persistence, a tool-context failure.
    ///
    /// Rendered through exactly the same path a settled failure takes, because to
    /// a reader they are the same event. Before this the REPL printed
    /// `String(describing:)` of whatever was caught, which for a ``DoMoError``
    /// spells out the Swift value rather than the sentence the type already knows
    /// how to write, and never carried a hint.
    private func appendError(_ error: any Error) {
        let domo = error as? DoMoError
        appendNotice(
            AgentNotice(
                level: .error,
                code: "runtime_error",
                text: DoMoError.truncating(domo?.description ?? String(describing: error)),
                kind: domo?.kind.label
            )
        )
    }

    /// Render an out-of-band notice — the REPL's whole error surface for a failure
    /// the loop SETTLED rather than threw.
    ///
    /// This is what a provider 401, a gateway 500 or a stream that died mid-answer
    /// looks like here. It matters that it exists at all: such a run produces an
    /// assistant message with empty text, which ``finalizeAssistant(_:)`` removes,
    /// so before this arm was filled in the REPL simply went idle with NOTHING on
    /// screen — indistinguishable from the model deciding it was finished.
    ///
    /// The three parts and the colours are ``ErrorPresentation``'s, the same ones
    /// the full-screen transcript draws, so the two surfaces cannot drift into two
    /// different vocabularies for the same failure. Notice text is provider- and
    /// gateway-controlled, so every part of it is sanitized before it reaches a
    /// live terminal.
    private func appendNotice(_ notice: AgentNotice) {
        let kind = notice.kind.flatMap(DoMoError.Kind.labeled)
        guard notice.level == .error else {
            // Progress chatter (a retry in flight, say), not a failure: one dim
            // line, no headline, no hint.
            let body = sanitizeUntrustedText(collapseToOneLine(notice.text))
            guard !body.isEmpty else { return }
            transcript.addChild(Text("  " + Self.dim("· " + body)))
            return
        }
        var lines = ["  \u{1b}[1;31m✗ " + sanitizeUntrustedText(ErrorPresentation.headline(for: kind)) + Self.sgrReset]
        let body = sanitizeUntrustedText(notice.text)
        if !body.isEmpty { lines.append("    \u{1b}[31m" + body + Self.sgrReset) }
        if let detail = notice.detail.map(sanitizeUntrustedText), !detail.isEmpty {
            lines.append("    \u{1b}[31m" + detail + Self.sgrReset)
        }
        if let hint = ErrorPresentation.hint(for: kind) {
            lines.append("    " + Self.dim(sanitizeUntrustedText(hint)))
        }
        transcript.addChild(Text(lines.joined(separator: "\n")))
    }

    /// A run that stopped without finishing, said out loud.
    private func appendStopNotice(_ text: String) {
        transcript.addChild(Text("  \u{1b}[33m⚠ " + text + Self.sgrReset))
    }

    /// Keep `/context` useful on a narrow terminal: show the shape and meter of
    /// the projected request without dumping its potentially large message body
    /// into the transcript.
    private static func contextSummary(messages: [Message], accounting: SessionAccounting?) -> String {
        var users = 0
        var assistants = 0
        var tools = 0
        var systems = 0
        for message in messages {
            switch message {
            case .system: systems += 1
            case .user: users += 1
            case .assistant: assistants += 1
            case .tool: tools += 1
            }
        }
        let shape = "\(messages.count) messages (system \(systems), user \(users), assistant \(assistants), tool \(tools))"
        let meter = InlineAccountingSummary.text(accounting)
        return meter.isEmpty ? "context: \(shape) · accounting unavailable" : "context: \(shape) · \(meter)"
    }

    /// Say out loud that a LiteLLM fallback fired and a different model answered.
    ///
    /// The README is explicit that a surface must report this "rather than lie",
    /// and until the stream function's `onResponse` was routed here the inline REPL
    /// had no way to know it had happened: it passed `onResponse: { _ in }`, so
    /// ``ResponseMetadata/attemptedFallbacks`` — the only signal there is — was
    /// discarded at the seam.
    ///
    /// Both names are gateway-controlled strings arriving in a response header, so
    /// both are collapsed to one line and stripped of anything a terminal would act
    /// on before they reach the screen.
    ///
    /// Said once per request that fell back, not once per session: which turn was
    /// answered by a substitute is exactly the thing a reader needs to know.
    func noteFallback(served: String, requested: String) {
        appendStopNotice(
            "request fell back — answered by "
                + sanitizeUntrustedText(collapseToOneLine(served))
                + ", not the requested model "
                + sanitizeUntrustedText(collapseToOneLine(requested))
        )
        render()
    }

    /// A drop's outcome — what attached, what did not.
    private func appendAttachmentNotice(_ text: String) {
        transcript.addChild(Text("  " + Self.dim(text)))
    }

    /// The sentence a run that stopped WITHOUT finishing owes the user, or `nil`
    /// for the endings the transcript already shows.
    ///
    /// `nil` for `.completed`/`.terminatedByTool`/`.stoppedByHook` (the model's own
    /// answer is right there), for `.aborted` (`⛔ interrupted` is already
    /// appended), and for `.errored` — that one gets a persistent `✗` row from
    /// ``appendNotice(_:)``, and a second line restating it would be noise. The two
    /// that remain are exactly the two endings that stop work with nothing to show
    /// for it, which is the defect: `.maxTurnsReached` produced NO output at all
    /// before this existed.
    static func stopNotice(for reason: RunStopReason) -> String? {
        switch reason {
        case .maxTurnsReached:
            return "stopped at the --max-turns limit — send another message to continue, "
                + "or restart without --max-turns for no limit"
        case .noProgress:
            return "stopped — the model repeated the same tool call with the same result "
                + "and made no progress"
        case .costLimitReached:
            return "stopped at the per-run cost limit — send another message to continue"
        case .completed, .terminatedByTool, .stoppedByHook, .errored, .aborted:
            return nil
        }
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

        // The text renderers never see the tool's image blocks (they carry the
        // one-row width contract); an image is a separate row whose escape the
        // differential renderer paints opaquely. Append one image view per block,
        // right after the tool result, mirroring the full-screen client's transcript.
        // Sequential tool execution keeps these ordered under their own tool.
        for image in result.images {
            transcript.addChild(
                ImageBlockView(
                    block: image,
                    imageId: allocateImageId(),
                    capabilities: imageCapabilities,
                    cell: cell
                )
            )
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
    private let commandProcessor: PromptCommandProcessor
    private let commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)?
    private let homeDirectory: String?
    private let toolRendererRegistry: ToolRendererRegistry
    private let toolTheme: ToolRenderTheme
    /// The steering seam. Built in ``make`` alongside the harness ``Configuration``
    /// whose `getSteeringMessages` drains it, then handed to the coordinator whose
    /// submit-while-running appends to it — one instance bridging both.
    private let steering: SteeringBox
    /// The sandboxed filesystem behind the tool context, carried through to the
    /// coordinator so a submitted `@path` image mention can be read and attached.
    private let fileSystem: SandboxedFileSystem?
    /// The permission engine's late-bound prompter (Phase 8). Built in ``make``
    /// alongside the harness whose `beforeToolCall` gate the engine drives, then set
    /// in ``run`` to the coordinator's approval overlay once the UI exists.
    private let prompterBox: PrompterBox
    /// The late-bound structured-question handler for the built-in question tool.
    private let questionBox: QuestionBox
    /// Children started by `background_process`; all are stopped when this
    /// interactive session returns.
    private let backgroundProcesses: BackgroundProcessManager
    /// The MCP servers backing this session's MCP tools (Phase 8c), held so ``run``
    /// can tear them down on exit — they spawn in their own process group and would
    /// otherwise be orphaned. `nil` when no MCP servers are configured.
    private let mcpManager: MCPManager?
    /// The response-header relay the session's stream function reports to. Built in
    /// ``make`` alongside that stream function, pointed at the coordinator's
    /// transcript by ``run`` once there is a transcript to write to.
    private let metadataRelay: ResponseMetadataRelay
    /// The alias this session asked for, kept so the fallback warning can name what
    /// was requested next to what actually answered.
    private let requestedModel: String

    private init(
        harness: AgentHarness,
        directoryLister: @escaping DirectoryLister,
        slashCommands: [SlashCommand],
        commandProcessor: PromptCommandProcessor,
        commandStreamFactory: (@Sendable (String?, ReasoningEffort?) -> AgentStreamFn)?,
        homeDirectory: String?,
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme,
        steering: SteeringBox,
        prompterBox: PrompterBox,
        questionBox: QuestionBox,
        backgroundProcesses: BackgroundProcessManager,
        metadataRelay: ResponseMetadataRelay,
        requestedModel: String,
        fileSystem: SandboxedFileSystem? = nil,
        mcpManager: MCPManager? = nil
    ) {
        self.harness = harness
        self.directoryLister = directoryLister
        self.slashCommands = slashCommands
        self.commandProcessor = commandProcessor
        self.commandStreamFactory = commandStreamFactory
        self.homeDirectory = homeDirectory
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
        self.steering = steering
        self.prompterBox = prompterBox
        self.questionBox = questionBox
        self.backgroundProcesses = backgroundProcesses
        self.metadataRelay = metadataRelay
        self.requestedModel = requestedModel
        self.fileSystem = fileSystem
        self.mcpManager = mcpManager
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
        configDirectory: String,
        homeDirectory: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        // Unbounded by default, matching every other surface. The old `100` was a
        // silent cap that only ever applied to callers who omitted the label — the
        // real CLI always passed its own — so it stopped nothing and surprised
        // whoever it did stop.
        maxTurns: Int? = nil,
        sessionSource: SessionSource = .new,
        toolTheme: ToolRenderTheme = .ansi,
        mcpServers: [String: MCPServerConfig] = [:],
        mcpLog: (@Sendable (String) -> Void)? = nil,
        // The resolved model, when the caller has one. Added ALONGSIDE
        // `model`/`reasoningEffort` rather than replacing them, because those two
        // are what every existing caller passes; a runtime supersedes both when
        // given, and also carries the cost rates and the context window a bare alias
        // cannot express. `nil` builds one from `model`/`reasoningEffort`, which is
        // exactly the request this surface made before.
        modelRuntime: ModelRuntime? = nil,
        modelRuntimeFor: (@Sendable (String) -> ModelRuntime)? = nil,
        compaction: CompactionSettings = .default,
        // The compaction summarizer, when a distinct small model was configured.
        // Decided by the caller (`DoMoCodeCommand.compactionSummarizer`), because
        // that is the layer that knows both aliases; `nil` keeps the harness's own.
        summarizer: Summarizer? = nil,
        // The environment variable names holding this run's gateway credential —
        // the three built-in spellings plus whatever `apiKeyEnv` named. They are
        // unset for every MCP child and every tool subprocess, so a model cannot
        // read the key back with a one-word `bash` command. Empty leaves only
        // `ToolContext`'s own built-in scrub, which is what a test that never
        // configured a credential wants.
        credentialEnvNames: Set<String> = [],
        maxCostPerRun: Decimal? = nil,
        steeringMode: QueueDeliveryMode = .oneAtATime
    ) async throws -> InteractiveMode {
        let workDirectory = FilePath(workingDirectory)
        let sessionDir = FilePath(sessionDirectory)
        let sessionStartHead: String?
        switch sessionSource {
        case .new, .fork:
            let git = try? DoMoGit()
            sessionStartHead = if let git { try? await git.head(at: workDirectory) } else { nil }
        case .resume:
            sessionStartHead = nil
        }
        // One resolved model for the whole session. A caller that supplied a runtime
        // has already applied its own precedence (an alias-level `reasoningEffort`
        // outranks the global one), so it wins outright rather than being merged
        // with the loose parameters here.
        let runtime = modelRuntime ?? ModelRuntime(model: model, reasoningEffort: reasoningEffort)

        let client = LiteLLMClient(configuration: clientConfiguration)
        let shell = try SubprocessShell()
        let questionBox = QuestionBox()
        let toolContext = try await ToolContext.rooted(
            at: workDirectory,
            shell: shell,
            environment: ToolContext.scrubbedEnvironment(alsoUnsetting: credentialEnvNames),
            questionHandler: { await questionBox.ask($0) }
        )
        let registry = ToolRegistry.builtin
        // MCP tools (Phase 8c): connect the configured stdio servers and append their
        // tools to the built-ins. The manager is held on the session and torn down in
        // ``run`` — the servers spawn in their own process group and would otherwise be
        // orphaned. `nil` manager when nothing is configured, so `run` has nothing to do.
        var mcpManager: MCPManager?
        var mcpTools: [any AgentTool] = []
        if !mcpServers.isEmpty {
            let manager = MCPManager()
            mcpTools = await manager.connect(
                servers: mcpServers,
                workspaceDirectory: workingDirectory,
                // Scrub the LLM-gateway credential variables from each MCP child's
                // env — including the one a user named through `apiKeyEnv`, which
                // the old hardcoded three-name list handed to every server.
                sensitiveEnvKeys: Redaction.secretEnvironmentNames.union(credentialEnvNames),
                // Reserve the built-in tool names so an MCP tool can't shadow one.
                reservedNames: Set(ToolRegistry.builtin.names),
                log: mcpLog ?? { _ in }
            )
            mcpManager = manager
        }

        // The permission gate (Phase 8). Built before the tool set so a `deny` rule can
        // hide the MCP tool from the model (Phase 8d visibility), not just block the call.
        // The harness is built here but the approval overlay only exists once `run` builds
        // the coordinator, so the engine drives a late-bound prompter box the coordinator
        // fills in. "Allow always" grants persist to the user settings.json.
        let permission = PermissionSetup.runtime(
            workingDirectory: workingDirectory,
            configDirectory: configDirectory,
            // Fall back to the real home, never "": a `~`/`$HOME` deny rule must not
            // expand to a bogus root and fail open when $HOME is unset.
            homeDirectory: homeDirectory ?? NSHomeDirectory()
        )
        let visibleMcp = PermissionSetup.visibleMCPTools(mcpTools, ruleset: permission.ruleset)
        let tools = registry.all.map { RegistryTool(tool: $0, context: toolContext) } + visibleMcp
        let connectedMCPManager = mcpManager
        let connectedMCPTools = mcpTools
        let toolResolver: @Sendable (String) async -> [any AgentTool] = { _ in
            let currentMcp = await connectedMCPManager?.tools() ?? connectedMCPTools
            let visible = PermissionSetup.visibleMCPTools(currentMcp, ruleset: permission.ruleset)
            return registry.all.map { RegistryTool(tool: $0, context: toolContext) } + visible
        }

        let promptWorkspace = try SystemPromptBuilder(
            workingDirectory: workDirectory,
            configDirectory: FilePath(configDirectory),
            toolNames: registry.names + visibleMcp.map(\.definition.name),
            projectTrusted: true
        ).build()
        let promptForTools: @Sendable (String, [String]) -> String = { prompt, toolNames in
            (try? SystemPromptBuilder(
                workingDirectory: workDirectory,
                configDirectory: FilePath(configDirectory),
                toolNames: toolNames,
                projectTrusted: true
            ).build().systemPrompt(for: prompt)) ?? promptWorkspace.systemPrompt(for: prompt)
        }
        let commandProcessor = PromptCommandProcessor(
            workspace: promptWorkspace,
            workingDirectory: workDirectory,
            shell: shell,
            allowInlineShell: true
        )

        // The shared factory, so this surface gets the per-alias cost rates and the
        // response-head callback that `-p` already had. The relay is the seam: the
        // coordinator that can draw a warning does not exist yet.
        let metadataRelay = ResponseMetadataRelay()
        let streamFn = makeStreamFn(
            client: client,
            runtime: runtime,
            onResponse: { metadataRelay.deliver($0) }
        )

        // The steering seam: the loop drains this box for mid-run submissions at
        // each turn boundary, and the coordinator appends to it. Built here so the
        // harness Configuration and the coordinator share the one instance.
        let steering = SteeringBox(mode: steeringMode)

        let prompterBox = PrompterBox()
        let engine = PermissionEngine(
            ruleset: permission.ruleset,
            prompt: { await prompterBox.prompt($0) },
            persist: permission.persist
        )
        let gate = permissionHook(engine: engine, factory: permission.factory, sessionID: "interactive")
        let noProgress = doomLoopHook(engine: engine, sessionID: "interactive")

        var systemPromptForPrompt: (@Sendable (String) -> String)?
        systemPromptForPrompt = { prompt in promptWorkspace.systemPrompt(for: prompt) }
        let configuration = AgentHarness.Configuration(
            systemPrompt: promptWorkspace.baseSystemPrompt,
            systemPromptForPrompt: systemPromptForPrompt,
            tools: tools,
            getTools: toolResolver,
            systemPromptForPromptAndTools: promptForTools,
            model: runtime.model,
            streamFn: streamFn,
            // A distinct small model compacts on its own request rather than through
            // `streamFn`; with none configured this is `nil` and the harness keeps
            // its built-in summarizer, unchanged.
            summarizer: summarizer,
            // Parallel execution still appends tool-result messages in source
            // order; only completion events are allowed to arrive as work ends.
            toolExecution: .parallel,
            maxTurns: maxTurns,
            // Neither was forwarded before, so the REPL compacted on the built-in
            // defaults against the 200K fallback window whatever the user configured
            // and whatever model was answering.
            compaction: compaction,
            contextWindow: runtime.contextWindow,
            getSteeringMessages: { steering.drain() },
            beforeToolCall: gate,
            onNoProgress: noProgress,
            maxCostPerRun: maxCostPerRun,
            sessionStartHead: sessionStartHead
        )

        // MCP is already connected by here; if harness construction fails, tear the
        // servers down before rethrowing — this is the one throwing call between the
        // connect above and the returned InteractiveMode (whose run() owns shutdown),
        // so a leak here would orphan the just-spawned children.
        let harness: AgentHarness
        do {
            harness = try await Self.makeHarness(
                sessionSource: sessionSource,
                workingDirectory: workDirectory,
                sessionDirectory: sessionDir,
                configuration: configuration
            )
        } catch {
            await mcpManager?.shutdown()
            throw error
        }

        let lister = Self.directoryLister(fileSystem: toolContext.fileSystem)

        return InteractiveMode(
            harness: harness,
            directoryLister: lister,
            slashCommands: promptWorkspace.commands.commands.map {
                SlashCommand(name: $0.name, description: $0.description, argumentHint: $0.argumentHint)
            },
            commandProcessor: commandProcessor,
            commandStreamFactory: { commandModel, effort in
                var selected = (modelRuntimeFor?(commandModel ?? runtime.model))
                    ?? ModelRuntime(model: commandModel ?? runtime.model)
                if let effort { selected.reasoningEffort = effort }
                return makeStreamFn(
                    client: client,
                    runtime: selected,
                    onResponse: { metadataRelay.deliver($0) }
                )
            },
            homeDirectory: homeDirectory,
            toolRendererRegistry: .builtin,
            toolTheme: toolTheme,
            steering: steering,
            prompterBox: prompterBox,
            questionBox: questionBox,
            backgroundProcesses: toolContext.backgroundProcesses,
            metadataRelay: metadataRelay,
            requestedModel: runtime.model,
            fileSystem: toolContext.fileSystem,
            mcpManager: mcpManager
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
    ///
    /// `imageCapabilities`/`cell` default to `nil`, meaning "detect from the tty" —
    /// the production path. They are injectable because detection reads the
    /// process's real environment and stdout, which a headless test drives an
    /// injected `target` around but cannot itself control; a test forces them to
    /// keep image rendering deterministic.
    @MainActor
    public func run(
        target: any RenderTarget,
        input: AsyncStream<[UInt8]>,
        resize: AsyncStream<TerminalSize>,
        lifecycle: any TerminalLifecycleControl,
        imageCapabilities: TerminalCapabilities? = nil,
        cell: CellDimensions? = nil,
        clipboardPaste: any ClipboardPasteSource = NoClipboardPasteSource()
    ) async throws {
        let quit = QuitSignal()
        let tui = TUI(target: target, showHardwareCursor: true)
        let driver = TerminalDriver(input: input, resize: resize, lifecycle: lifecycle)

        let provider = CombinedAutocompleteProvider(providers: [
            SlashCommandProvider(commands: slashCommands),
            FileCompletionProvider(lister: directoryLister),
        ])

        // Detect the tty's inline-image capability and cell pixel size once, up
        // front — the REPL owns the terminal, so this is the place that can query
        // it. With no image protocol every image degrades to a text marker. An
        // injected override (tests) short-circuits detection.
        let resolvedCapabilities = imageCapabilities ?? detectCapabilities()
        var resolvedCell = cell ?? .default
        if cell == nil, let pixel = TerminalSize.cellPixelSize() {
            resolvedCell = CellDimensions(widthPx: pixel.widthPx, heightPx: pixel.heightPx)
        }

        let coordinator = InteractiveCoordinator(
            tui: tui,
            driver: driver,
            quit: quit,
            harness: harness,
            provider: provider,
            commandProcessor: commandProcessor,
            commandStreamFactory: commandStreamFactory,
            toolRendererRegistry: toolRendererRegistry,
            toolTheme: toolTheme,
            homeDirectory: homeDirectory,
            steering: steering,
            questionBox: questionBox,
            fileSystem: fileSystem,
            terminalRows: { target.rows },
            imageCapabilities: resolvedCapabilities,
            cell: resolvedCell,
            clipboardPaste: clipboardPaste
        )
        coordinator.install()
        // Now that the approval UI exists, point the engine's prompter at it. Until
        // this runs (it cannot fire before the first frame), the box refuses.
        prompterBox.set { await coordinator.showPermissionPrompt($0) }
        questionBox.set { await coordinator.showQuestionPrompt($0) }
        // And point the response-header relay at the transcript, so a fallback the
        // gateway performed is reported instead of swallowed. The head arrives on
        // the streaming client's task, off the main actor, so the hop is explicit.
        // Only a fallback is surfaced: the rest of the head is diagnostic noise the
        // inline surface has no room for and the JSON stream already carries.
        let requested = requestedModel
        metadataRelay.set { metadata in
            guard metadata.fellBack else { return }
            let served = metadata.modelID ?? "an unknown model"
            Task { @MainActor in coordinator.noteFallback(served: served, requested: requested) }
        }

        await driver.run(tui, quit: quit, background: {
            await coordinator.agentLoop()
        })

        await backgroundProcesses.shutdown()
        // Tear the MCP servers down before reporting any terminal error — they run in
        // their own process group, so leaving them up would orphan them.
        await mcpManager?.shutdown()

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
