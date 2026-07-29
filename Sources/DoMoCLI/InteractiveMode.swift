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
import DoMoCore
import DoMoExec
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

// MARK: - Steering box

/// The `Sendable` seam that carries a mid-run submission into the running agent.
///
/// One `Mutex`-guarded queue shared across an isolation boundary: the harness's
/// ``AgentHarness/Configuration/getSteeringMessages`` closure ``drain()``s it from
/// the agent loop (which polls at each turn boundary, off the main actor), while a
/// submit-while-running ``append(_:)``s to it on the main actor. There is no async
/// work under the lock, so a `Mutex` is the right tool — never a lock across an
/// `await`.
///
/// ``drain()`` reads-and-clears in one critical section, which is what makes the
/// race benign: a message appended concurrently with a poll is either wholly
/// returned by that poll (injected into the current turn) or wholly retained for
/// the next — it can be neither split nor processed twice.
final class SteeringBox: Sendable {
    private let messages = Mutex<[Message]>([])

    /// Enqueue a message for the running agent's next turn.
    func append(_ message: Message) {
        messages.withLock { $0.append(message) }
    }

    /// Atomically take everything queued and clear the box.
    func drain() -> [Message] {
        messages.withLock { queued in
            let taken = queued
            queued.removeAll()
            return taken
        }
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

    /// Images dropped onto the prompt and not yet sent.
    ///
    /// Held here rather than inside the editor because the editor's document is
    /// TEXT — a drop consumes the path it typed and leaves nothing behind, so
    /// something outside the document has to remember the bytes until the next
    /// submit. Cleared by `handleSubmit` (they ride that message) and by `/clear`
    /// (a cleared session must not carry invisible attachments forward).
    private var stagedImages: [LoadedImage] = []

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
    private static let progressFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// The status line while a turn is in flight — animated, and distinct while a
    /// tool call is parked on approval, which is the state most easily mistaken for
    /// a freeze.
    private var runningStatus: String {
        let glyph = Self.progressFrames[((progressFrame % 10) + 10) % 10]
        if pendingPermission != nil {
            return "  \(glyph) waiting for your approval — choose above"
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
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme,
        homeDirectory: String?,
        steering: SteeringBox,
        fileSystem: SandboxedFileSystem? = nil,
        terminalRows: @escaping () -> Int,
        keybindings: Keybindings = Keybindings(),
        imageCapabilities: TerminalCapabilities = TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false),
        cell: CellDimensions = .default
    ) {
        self.tui = tui
        self.driver = driver
        self.quit = quit
        self.harness = harness
        self.steering = steering
        self.fileSystem = fileSystem
        self.provider = provider
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
        self.homeDirectory = homeDirectory
        self.keybindings = keybindings
        self.imageCapabilities = imageCapabilities
        self.cell = cell

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
        // Ctrl+C with a permission prompt up rejects it (and dismisses the modal).
        if permissionList != nil {
            resolvePermission(.reject(message: nil))
            render()
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
        currentRunTask?.cancel()
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
            // Attachments are invisible once their transcript lines are gone;
            // carrying them into the next message would send bytes the user has
            // no way to see are still staged.
            stagedImages = []
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
            // Steer the in-flight run: the harness's `getSteeringMessages` hook
            // drains this box at the current run's next turn boundary, so the text
            // joins the running agent rather than waiting for a fresh run. The user
            // turn is already echoed above; the loop's own `messageStart(.user)` for
            // the injected message is ignored by ``handle(_:)``, so it is not doubled.
            //
            // The message is built by hand rather than with `Message.user(_:)` so
            // the attachments ride it: the convenience builds a TEXT-ONLY message,
            // which is how a mid-run drop used to be silently discarded.
            steering.append(
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
        await withTaskCancellationHandler {
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
        var iterator = submissions.makeAsyncIterator()
        while !Task.isCancelled {
            guard let submission = await iterator.next() else { break }
            await runOne(submission)
            drainLeftoverSteering()
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
                let result = try await self.harness.run(prompt: prompt, attachments: attachments, sink: sink)
                return result.stopReason
            } catch is CancellationError {
                return .aborted
            } catch {
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
        if reason == .aborted {
            appendInterrupted()
        } else if let notice = Self.stopNotice(for: reason) {
            // A run that stopped WITHOUT finishing has to say so. Before this,
            // `.maxTurnsReached` produced no output whatsoever here — the REPL
            // simply went idle mid-task, which is indistinguishable from the model
            // deciding it was done.
            appendStopNotice(notice)
        }
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
            if case .assistant(let assistant) = message { finalizeAssistant(assistant) }
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
    /// `sgrReset` are internal to that target, and DoMoCLI does not depend on it.
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
    /// The MCP servers backing this session's MCP tools (Phase 8c), held so ``run``
    /// can tear them down on exit — they spawn in their own process group and would
    /// otherwise be orphaned. `nil` when no MCP servers are configured.
    private let mcpManager: MCPManager?

    private init(
        harness: AgentHarness,
        directoryLister: @escaping DirectoryLister,
        slashCommands: [SlashCommand],
        homeDirectory: String?,
        toolRendererRegistry: ToolRendererRegistry,
        toolTheme: ToolRenderTheme,
        steering: SteeringBox,
        prompterBox: PrompterBox,
        fileSystem: SandboxedFileSystem? = nil,
        mcpManager: MCPManager? = nil
    ) {
        self.harness = harness
        self.directoryLister = directoryLister
        self.slashCommands = slashCommands
        self.homeDirectory = homeDirectory
        self.toolRendererRegistry = toolRendererRegistry
        self.toolTheme = toolTheme
        self.steering = steering
        self.prompterBox = prompterBox
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
        mcpLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> InteractiveMode {
        let workDirectory = FilePath(workingDirectory)
        let sessionDir = FilePath(sessionDirectory)

        let client = LiteLLMClient(configuration: clientConfiguration)
        let shell = try SubprocessShell()
        let toolContext = try await ToolContext.rooted(at: workDirectory, shell: shell)
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
                // Scrub the LLM-gateway credential variables from each MCP child's env.
                sensitiveEnvKeys: Set(EnvName.apiKeyFallbacks),
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

        let streamFn: AgentStreamFn = { context in
            client.streamCompletion(
                model: model,
                context: context,
                reasoningEffort: reasoningEffort,
                onResponse: { _ in }
            )
        }

        // The steering seam: the loop drains this box for mid-run submissions at
        // each turn boundary, and the coordinator appends to it. Built here so the
        // harness Configuration and the coordinator share the one instance.
        let steering = SteeringBox()

        let prompterBox = PrompterBox()
        let engine = PermissionEngine(
            ruleset: permission.ruleset,
            prompt: { await prompterBox.prompt($0) },
            persist: permission.persist
        )
        let gate = permissionHook(engine: engine, factory: permission.factory, sessionID: "interactive")

        let configuration = AgentHarness.Configuration(
            systemPrompt: PrintMode.systemPrompt(
                workingDirectory: workDirectory,
                toolNames: registry.names + visibleMcp.map(\.definition.name)
            ),
            tools: tools,
            model: model,
            streamFn: streamFn,
            // Sequential keeps tool-start/tool-result transcript order equal to the
            // model's own call order, which is what a reader expects to watch.
            toolExecution: .sequential,
            maxTurns: maxTurns,
            getSteeringMessages: { steering.drain() },
            beforeToolCall: gate
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
            slashCommands: defaultSlashCommands,
            homeDirectory: homeDirectory,
            toolRendererRegistry: .builtin,
            toolTheme: toolTheme,
            steering: steering,
            prompterBox: prompterBox,
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
        cell: CellDimensions? = nil
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
            toolRendererRegistry: toolRendererRegistry,
            toolTheme: toolTheme,
            homeDirectory: homeDirectory,
            steering: steering,
            fileSystem: fileSystem,
            terminalRows: { target.rows },
            imageCapabilities: resolvedCapabilities,
            cell: resolvedCell
        )
        coordinator.install()
        // Now that the approval UI exists, point the engine's prompter at it. Until
        // this runs (it cannot fire before the first frame), the box refuses.
        prompterBox.set { await coordinator.showPermissionPrompt($0) }

        await driver.run(tui, quit: quit, background: {
            await coordinator.agentLoop()
        })

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
