// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two-pane full-screen client: a session sidebar and a main transcript+input
// column, driven by a `ScreenSurface`, fed by the `EventStore`, talking to a
// runtime through a `ServerClient`. It conforms to `TerminalApp` itself so it can
// layer global keys (Ctrl-C quits, Escape aborts the running turn) over the
// surface, then delegate everything else — Tab traversal, arrows, typing — to it.
// The same `TerminalDriver` that runs the inline `TUI` runs this.

import DoMoCore
import DoMoExec
import DoMoGit
import DoMoHarness
import DoMoLLM
import DoMoMemory
import DoMoPermissions
import Foundation
import DoMoServer
import DoMoTUI
import DoMoTermGraphics
import DoMoTermIO
import SystemPackage

/// Lines computed fresh on every render.
///
/// The overlay compositor re-renders its content every frame, so a component that
/// asks a closure for its rows stays true for as long as it is on screen. The
/// diagnostics panel's most useful row — how long the stream has been silent — is
/// a number that changes once a second, and a `Text` built when the panel opened
/// would be a lie one second later.
@MainActor
final class DynamicLines: @MainActor Component {
    private let lines: (Int) -> [String]

    init(_ lines: @escaping (Int) -> [String]) { self.lines = lines }

    func render(width: Int) -> [String] { lines(width) }
}

/// The remote full-screen client application.
@MainActor
public final class ClientApp {
    private let client: ServerClient
    private let store = EventStore()
    private let sidebar = SessionSidebar()
    private let transcriptView = TranscriptView()
    private let promptInput = PromptInput()
    private let statusBar = StatusBar()
    private let footerBar = FooterBar()
    private let focus = FocusRing()
    private let quit = QuitSignal()
    /// A separate root for the phase/agent workflow experience. It is deliberately
    /// not an overlay: the workflow owns the full frame until Escape walks back to
    /// the ordinary session view.
    private var workflowWorkspace: WorkflowWorkspaceController?
    private var workflowRefreshTask: Task<Void, Never>?
    private var workflowRunID: String?
    private var workflowApprovals: [WorkflowApprovalRequest] = []
    /// Command metadata is fetched from the runtime at bootstrap. The client
    /// uses local actions immediately and forwards prompt commands unchanged so
    /// the server remains the authority for template expansion.
    private var commandRegistry = CommandRegistry.builtIn
    /// The level-triggered policy mode of the selected server session. Tab changes
    /// this through the runtime; the local value is only a render cache.
    private var agentMode: AgentMode = .build

    /// The terminal's inline-image capability and cell pixel size, detected once at
    /// startup (the client owns the tty; the remote runtime has none).
    private var graphicsCapabilities = TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false)
    private var cellSize: CellDimensions = .default

    private var surface: ScreenSurface?
    private var dialogs: DialogStack?
    private var paletteHandle: ScreenOverlayHandle?
    private var sessionPickerHandle: ScreenOverlayHandle?
    private var modelPickerHandle: ScreenOverlayHandle?
    private var treePickerHandle: ScreenOverlayHandle?
    private var renameHandle: ScreenOverlayHandle?
    private var labelHandle: ScreenOverlayHandle?
    private var autocompleteHandle: ScreenOverlayHandle?
    private var autocompleteDialog: SearchableSelectDialog?
    private var paletteDialog: SearchableSelectDialog?
    private var toolCatalogHandle: ScreenOverlayHandle?
    private var toolCatalogDialog: SearchableSelectDialog?
    private var toolCatalogRefreshTask: Task<Void, Never>?
    private var sessionPickerDialog: SearchableSelectDialog?
    private var modelPickerDialog: SearchableSelectDialog?
    private var treePickerDialog: TreeDialog?
    private var renameDialog: DialogForm?
    private var labelDialog: DialogTextInput?
    private var forceClearHandle: ScreenOverlayHandle?
    private var forceClearDialog: DialogConfirm?
    private var draftEditorHandle: ScreenOverlayHandle?
    private var draftEditorDialog: DialogEditor?
    private var diffReviewHandle: ScreenOverlayHandle?
    private var diffReviewDialog: DiffReviewDialog?
    private var diffReviewSessionID: String?
    private var diffRefreshTask: Task<Void, Never>?
    private var diffRevertHandle: ScreenOverlayHandle?
    private var diffRevertDialog: DialogConfirm?
    private var theme = Theme.standard
    private var appearance: ThemeAppearance = .dark
    private var eventTask: Task<Void, Never>?
    /// User actions can outlive the input event that started them. Keep them under
    /// the app's lifetime so shutdown cancels and drains in-flight HTTP requests
    /// before `runFullScreenClient` shuts down its shared client.
    private var actionTasks: [Task<Void, Never>] = []
    /// The one background title request allowed for the selected session. It is
    /// kicked off after the first normal turn, not while the agent is still holding
    /// the server's run slot.
    private var autoTitleTask: Task<Void, Never>?
    private var observedRunSessionID: String?
    private var observedRunState: EventStore.RunState = .idle
    private var automaticTitleAttemptedSessionIDs: Set<String> = []
    /// Drives the in-flight animation. The transcript's spinner is a pure function
    /// of a frame index, so something has to advance it; this is that clock, and it
    /// only runs while there is something in flight. Its second job is diagnostic: a
    /// spinner that stops moving means the render loop itself is wedged, which a
    /// static "…" could never tell you.
    private var spinnerTask: Task<Void, Never>?

    // Permission approval modal (Phase 8b). Driven off `store.pendingPermission` via
    // `reconcilePermissionOverlay`, so every show/dismiss path funnels through one place.
    private let keybindings = Keybindings()
    private var permissionHandle: ScreenOverlayHandle?
    private var permissionList: SelectList?
    /// The terminal size the modal was laid out for, so a resize can rebuild it.
    private var permissionOverlaySize: (columns: Int, rows: Int)?
    /// The modal's row values in order, so Escape can find the "Reject" row without
    /// assuming a fixed layout (the "always" row is conditional).
    private var permissionItemValues: [String] = []
    // Structured question modal. It is a component rather than a SelectList
    // because a batch can mix single- and multiple-choice prompts and needs to
    // retain answers while advancing through them.
    private var questionHandle: ScreenOverlayHandle?
    private var questionDialog: QuestionDialog?
    private var questionOverlaySize: (columns: Int, rows: Int)?
    private var copyOptionsHandle: ScreenOverlayHandle?
    private var copyOptionsDialog: TranscriptOptionsDialog?
    /// Whether the session's event stream is currently up. Surfaced in the status
    /// line, because a dead stream is otherwise indistinguishable from a slow model.
    private var streamConnected = true
    /// The runtime's last level-triggered workspace snapshot answer. It is shown
    /// in the status row so the UI never implies that undo restored files when
    /// snapshots are disabled or unavailable.
    private var workspaceSnapshotStatus: WorkspaceSnapshotStatus = .unavailable
    /// A transient status-line message and when it lapses — the client's only error
    /// surface. Without one there is nowhere to report a refused or failed action,
    /// which is precisely why they used to be swallowed.
    private var notice: String?
    private var noticeExpiry: Date?

    /// Whether the current notice is only true while a run is in flight.
    ///
    /// A retry says what the run is *about to do*, and its dwell is the backoff —
    /// up to a minute. Abort the run, or let it finish inside that window, and the
    /// line goes on promising an attempt that will never happen, beside a status
    /// segment that already says `idle`. Every other notice is an acknowledgement
    /// of something that already happened, and stays true regardless.
    private var noticeIsRunScoped = false

    // MARK: The one shared stored-property block
    //
    // Every area that adds state to this class adds it HERE, together, declared once.
    // Four separate waves land in this file; four separate `private var` clusters is
    // how two of them end up with overlapping copies of the same fact (a prompt
    // height, a mouse-owned flag) and how the copies drift.

    /// The prompt's height in the frame MOST RECENTLY BUILT.
    ///
    /// `handleMouse` runs between frames and has to hit-test the geometry the user is
    /// actually looking at. Recomputing it there would render the editor a third time
    /// per event and — worse — could disagree with what is on screen, which is the
    /// exact failure `ClientLayout` exists to prevent.
    private var promptRows = 1
    /// Where prompt history is persisted, or nil when the client is running without
    /// a workspace to key it on.
    private let historyStore: PromptHistoryStore?
    /// Where a copy goes. `NoClipboardSink` is a real answer, not a fallback: over
    /// ssh there may genuinely be no clipboard to write to.
    private let clipboard: any ClipboardSink
    /// Where Ctrl-V reads image/text data from. The CLI owns the subprocess
    /// implementation; the client only consumes this asynchronous seam.
    private let clipboardPaste: any ClipboardPasteSource
    /// The multiplexer wrapping this terminal, which decides how an OSC 52 must be
    /// escaped to reach the outer terminal at all.
    private let multiplexer: TerminalMultiplexer
    /// Whether the app currently owns mouse reporting. Toggling it off hands
    /// drag-select back to the terminal's own selection.
    private var mouseOwned: Bool
    /// The live lifecycle's terminal-native output seam. It is optional so the
    /// client remains fully driveable with the existing headless lifecycle fakes.
    private var terminalNative: (any TerminalNativeControl)?
    /// `nil` until the terminal reports focus. A completion notification is only
    /// emitted for an explicit focus-out, never merely because no report arrived.
    private var terminalFocused: Bool?
    /// The live text selection over the painted page, and the rules for when it
    /// stops being live.
    private let selection = SelectionController()
    /// Held so F8 can reach ``TerminalLifecycleControl/setMouseReporting(_:)``
    /// mid-session. The app cannot take or release the mouse itself — the bytes
    /// belong to the lifecycle, which also owns the crash-safe restore that has to
    /// be rewritten whenever the mode changes.
    private var lifecycle: (any TerminalLifecycleControl)?
    /// Where a dropped file's bytes are read from. A `POSIXFileSystem` on purpose,
    /// not the sandboxed one: the whole gesture is "this file, the one I just
    /// dragged in", and a screenshot lives in `~/Desktop`, not in the workspace.
    /// It is a read of a file the user physically pointed at, in a process that
    /// already runs as them.
    private let fileSystem = POSIXFileSystem()
    /// Hands out ``PromptAttachment/id``s. Monotonic per session so a chip's
    /// identity is stable across renders and unambiguous across removals.
    private var attachmentCounter: UInt32 = 0
    /// Why the event stream is down, as the status line should say it. `nil` while
    /// connected. "disconnected — reconnecting…" on its own is indistinguishable
    /// from a slow model; the reason is what makes it actionable.
    private var lastStreamError: String?
    /// Whether the current outage has already produced a transcript row, so a
    /// reconnect loop that runs for an hour posts one row and not four hundred.
    /// Reset when the stream comes back.
    private var reportedStreamFailure = false
    /// How long a stream outage must last before it earns a persistent transcript row
    /// rather than just the status line.
    private static let streamOutageNoticeDelay: TimeInterval = 8
    /// Whether a `/status` poll is already in flight, so a slow server cannot make
    /// the polls stack up — the poll exists to diagnose a stall, and a stack of
    /// them queued behind the same stall is a second failure, not a diagnosis.
    private var statusPollInFlight = false
    /// When the last poll was STARTED. `.distantPast` forces one on the next tick,
    /// which is how a refused prompt turns pressing Enter into a repair action.
    private var lastStatusPollAt = Date.distantPast
    /// The ^G panel, when it is up. The HANDLE is the authority — see
    /// ``presentDiagnosticsOverlay()``.
    private var diagnosticsHandle: ScreenOverlayHandle?
    private var diagnosticsList: SelectList?
    /// The server's last answer for the panel, and the reason there isn't one.
    /// Fetched once when the panel opens; everything else on the panel is local
    /// and therefore live.
    private var diagnosticsStatus: SessionStatus?
    private var diagnosticsStatusError: String?
    /// The terminal size the panel was laid out for, so a resize can rebuild it.
    private var diagnosticsOverlaySize: (columns: Int, rows: Int)?
    /// How often the client asks the server what it actually believes, while the
    /// client believes a run is in flight.
    private static let statusPollInterval: TimeInterval = 5
    /// How long the stream must be silent before the status line says so. Longer
    /// than the server's 15 s heartbeat, so an ordinary gap between heartbeats
    /// never trips it; short enough that a user has not yet given up.
    private static let silenceThreshold: TimeInterval = 20
    /// How many times a create/resume is retried before it becomes a failure row.
    /// A single attempt is how "no session selected, forever" happened.
    private static let sessionAttempts = 3
    /// The branch last read off `.git/HEAD`, and the directory it was read for.
    ///
    /// ``DoMoCore/GitInfo/branch(forWorkingDirectory:)`` does blocking file IO —
    /// up to 128 `stat(2)`s while it walks up to the repository root, then two
    /// small reads — and the footer is rebuilt on every repaint, which means on
    /// every keystroke. Calling it uncached would put a filesystem walk on the
    /// render loop; this is the cache the function's own documentation requires
    /// of its callers.
    private var branchCache: (cwd: String, branch: String?)?
    /// The run state the branch cache was last refreshed against, so a TURN
    /// BOUNDARY — a run settling — is what invalidates it. A branch changes when
    /// the agent (or the user in another window) checks one out, and the end of a
    /// turn is the moment that has just become likely; a repaint is not.
    private var branchCacheRunState: EventStore.RunState = .idle
    /// Longest a notice may hold the status line, however long its TTL claims.
    /// Matches `DOMOCODE_RETRY_BUDGET_MS`'s default: no single backoff can exceed
    /// the whole sleep budget, so nothing legitimate is ever truncated by this.
    private static let maxNoticeDwell: Double = 300

    private static let ctrlC: [UInt8] = [0x03]
    private static let escape: [UInt8] = [0x1b]
    /// `^O` toggles expanded error/tool detail. A raw byte compare, matching the
    /// `ctrlC` precedent above and deliberately NOT a new `Keybinding`: ^O is
    /// unbound everywhere in this package, and adding a binding would mean
    /// editing a file three other areas also want.
    private static let ctrlO: [UInt8] = [0x0f]
    /// What one image drop may cost. The client's own limits rather than
    /// `.unlimited`, because a drop is a one-handed gesture: the `--image` flag is
    /// an operator naming a file deliberately, a drag is a file that happened to
    /// be under the pointer.
    private static let attachmentLimits = ImageAttachmentLimits.default
    /// `^G` opens the diagnostics panel. Same reasoning as `ctrlO`, and verified
    /// free on this path: it is in no `Keybindings.defaults`, `PromptInput` only
    /// accepts scalars ≥ 0x20, and the sidebar ignores it.
    private static let ctrlG: [UInt8] = [0x07]
    /// The command palette and the three pickers are intentionally on free
    /// control bytes so they remain available while the prompt is focused.
    private static let ctrlP: [UInt8] = [0x10]
    private static let ctrlS: [UInt8] = [0x13]
    private static let ctrlM: [UInt8] = [0x0c]
    private static let ctrlT: [UInt8] = [0x14]
    private static let ctrlE: [UInt8] = [0x05]

    public init(
        client: ServerClient,
        historyStore: PromptHistoryStore? = nil,
        clipboard: any ClipboardSink = NoClipboardSink(),
        clipboardPaste: any ClipboardPasteSource = NoClipboardPasteSource(),
        multiplexer: TerminalMultiplexer = .none,
        mouseOwned: Bool = true
    ) {
        self.client = client
        self.historyStore = historyStore
        self.clipboard = clipboard
        self.clipboardPaste = clipboardPaste
        self.multiplexer = multiplexer
        self.mouseOwned = mouseOwned
    }

    // MARK: Run

    /// Run the client against injected terminal collaborators, mirroring the inline
    /// `InteractiveMode.run`. Returns when the user quits (Ctrl-C), input ends, or
    /// the task is cancelled; the terminal is always restored by the driver.
    public func run(
        target: any RenderTarget,
        input inputStream: AsyncStream<[UInt8]>,
        resize: AsyncStream<TerminalSize>,
        lifecycle: any TerminalLifecycleControl
    ) async throws {
        focus.register(sidebar)
        focus.register(promptInput)
        // `FocusRing.register` focuses only the FIRST registration, which is the
        // sidebar — so the client came up with the caret in the wrong pane and every
        // arrow key drove the session list instead of the text you were writing. The
        // prompt is where a user starts, and now that the arrows walk prompt history
        // it is also where they are most likely to be pressed first.
        focus.setCurrent(promptInput)
        detectGraphics()

        let surface = ScreenSurface(target: target, focus: focus) { [weak self] in
            self?.buildTree(width: target.columns, height: target.rows) ?? Column([])
        }
        surface.frameBackground = theme.palette(for: appearance).background
        surface.frameBackgroundTrueColor = graphicsCapabilities.trueColor
        self.surface = surface
        self.dialogs = DialogStack(surface: surface)
        // Held for F8. The app can flip its own `mouseOwned` flag all it likes;
        // only the lifecycle can actually write `?1000l` at the terminal.
        self.lifecycle = lifecycle
        self.terminalNative = lifecycle as? any TerminalNativeControl
        self.terminalFocused = nil
        // The selection is not part of the layout tree — it is a function of where
        // the pointer has been, and the tree is rebuilt from scratch every frame —
        // so it is painted here, after the page is composed and before it is
        // diffed. `validate` runs first so a selection whose rows moved is gone
        // before it can highlight the wrong text.
        surface.decorateFrame = { [weak self] lines in
            guard let self else { return lines }
            self.selection.validate(against: lines)
            return self.selection.decorate(lines)
        }

        store.onChange = { [weak self] in
            self?.refreshSessionPicker()
            self?.observeRunStateChange()
            self?.clearNoticeIfRunSettled()
            self?.reconcilePermissionOverlay()
            self?.reconcileQuestionOverlay()
            self?.surface?.requestRender()
        }
        // An info/warning notice is transient status, not transcript. The store
        // folds error-level notices into permanent rows itself and never calls
        // this for them, so there is no double-reporting to guard against.
        //
        // Without this line the whole notice channel dead-ends: the runtime
        // emits, the server projects, the store folds — and nothing renders. A
        // retry is the only producer today, and it stayed invisible for exactly
        // that reason.
        store.onNotice = { [weak self] notice in
            self?.show(notice)
            // Child sessions are created while the parent stream is already open.
            // Refresh the disk-backed sidebar when the lifecycle event arrives so
            // the new row is immediately walkable from the client.
            if notice.code == "subagent" { self?.refreshSessions() }
        }
        promptInput.onSubmit = { [weak self] text, attachments in self?.submit(text, attachments) }
        promptInput.onPasteImage = { [weak self] in self?.pasteClipboard() }
        // Persist off the render loop. The store is an actor, so the write cannot
        // race the startup load and cannot stall the frame that just accepted the
        // keystroke.
        promptInput.onHistoryAdd = { [weak self] entry in
            guard let store = self?.historyStore else { return }
            Task { await store.append(entry) }
        }
        // The prompt parses a paste into path candidates; the app owns the
        // filesystem and answers. Split that way so the input component has no IO
        // seam of its own and stays synchronous.
        promptInput.onDrop = { [weak self] token, candidates in
            self?.resolveDrop(token: token, candidates: candidates)
        }
        // Enter while a drop is still being read is REFUSED, not queued and not
        // sent without the picture. The prompt has no status line, so it says so
        // here, and it names the thing to wait for rather than just "try again".
        promptInput.onSubmitDeferredForDrop = { [weak self] in
            self?.post(notice: "still reading the dropped file — Enter again once the 📎 chip appears")
        }
        promptInput.onAutocomplete = { [weak self] suggestions in
            self?.reconcileAutocomplete(suggestions)
        }
        promptInput.setAutocompleteProvider(makeAutocompleteProvider(commands: commandRegistry))
        promptInput.applyTheme(theme, appearance: appearance, trueColor: graphicsCapabilities.trueColor)
        statusBar.applyTheme(theme, appearance: appearance, trueColor: graphicsCapabilities.trueColor)
        footerBar.applyTheme(theme, appearance: appearance, trueColor: graphicsCapabilities.trueColor)
        sidebar.onSelect = { [weak self] id in self?.openSession(id) }
        sidebar.onNew = { [weak self] in self?.newSession() }
        sidebar.onBack = { [weak self] id in self?.openSession(id) }

        // Load sessions/history as the driver's background job — i.e. AFTER the
        // terminal is entered and the first (empty) frame is painted — so the store
        // mutations' coalesced renders never fire before the alt screen is active
        // and leak a frame onto the normal buffer. The UI comes up immediately and
        // fills in as the network responds.
        startSpinnerClock()

        let driver = TerminalDriver(input: inputStream, resize: resize, lifecycle: lifecycle)
        await driver.run(self, quit: quit, background: { [weak self] in
            await self?.bootstrap()
        })

        let tasks = actionTasks + [
            eventTask,
            spinnerTask,
            diffRefreshTask,
            toolCatalogRefreshTask,
            workflowRefreshTask,
        ].compactMap { $0 }
        // Cancellation is the hand-off to the owned HTTPClient below. Waiting for
        // every task here can deadlock on Linux when an async-http-client body
        // reader is already parked on its connection: the reader needs the
        // client's shutdown to finish, while shutdown cannot begin until this
        // method returns. The tasks are cancellation-aware, and the HTTP client is
        // the authority that closes any request still holding a connection.
        for task in tasks { task.cancel() }
        actionTasks.removeAll()
        eventTask = nil
        spinnerTask = nil
        diffRefreshTask = nil
        toolCatalogRefreshTask = nil
        workflowRefreshTask = nil

        if let error = driver.startupError { throw error }
        if let error = driver.renderError { throw error }
    }

    // MARK: Layout

    /// Detect the terminal's image protocol (env sniffing) and cell pixel size
    /// (kernel ioctl, else the 9×18 default). Runs in the client process, which
    /// owns the tty — the remote runtime has no terminal to query.
    private func detectGraphics() {
        graphicsCapabilities = detectCapabilities()
        if let pixel = TerminalSize.cellPixelSize() {
            cellSize = CellDimensions(widthPx: pixel.widthPx, heightPx: pixel.heightPx)
        }
    }

    /// Build the shared slash/`@` provider. Completion is local to the client
    /// terminal, which is the useful behavior for a remote runtime: the file the
    /// user is dragging or naming is on the machine where they are typing.
    private func makeAutocompleteProvider(commands: CommandRegistry) -> AutocompleteProvider {
        let slash = commands.commands.map {
            SlashCommand(name: $0.name, description: $0.description, argumentHint: $0.argumentHint)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return CombinedAutocompleteProvider(commands: slash) { directory in
            let home = NSHomeDirectory()
            let expanded: String
            if directory == "~" || directory.hasPrefix("~/") {
                expanded = home + String(directory.dropFirst())
            } else if directory.hasPrefix("/") {
                expanded = directory
            } else {
                expanded = URL(fileURLWithPath: cwd).appendingPathComponent(directory).path
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { return [] }
            return names.sorted().map { name in
                let path = URL(fileURLWithPath: expanded).appendingPathComponent(name).path
                let isDirectory = try? URL(fileURLWithPath: path)
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
                return DirectoryEntry(name: name, isDirectory: isDirectory == true)
            }
        }
    }

    private func buildTree(width: Int, height: Int) -> any LayoutNode {
        if let workflowWorkspace {
            return workflowWorkspace.layout(width: width)
        }
        // Refresh the views from the current store state.
        sidebar.sessions = store.sessions
        sidebar.openID = store.selectedSessionID
        transcriptView.items = store.transcript
        transcriptView.running = store.runState == .running
        statusBar.text = statusText()
        footerBar.model = footerModel()

        let mainColumnStart = ClientLayout.mainColumnStart(for: width)
        // The width the input will ACTUALLY be placed at: `Row` gives the flexible
        // main column `width - mainColumnStart`, and `Column` stretches every child to
        // the full content width. Measuring at any other width wraps differently than
        // it paints, and the editor's first/last-visual-line tests — the ones that
        // decide whether an arrow recalls history or moves the caret — are computed
        // against the last width it rendered at.
        let inputWidth = max(0, width - mainColumnStart)
        let footerRows = ClientLayout.footerRows(for: height)
        promptRows = inputWidth > 0
            ? promptInput.height(
                forWidth: inputWidth,
                maxRows: ClientLayout.promptRowCap(for: height, footerRows: footerRows)
            )
            : 1
        let layout = ClientLayout(
            width: width, height: height, promptRows: promptRows, footerRows: footerRows
        )
        // Built as an array rather than a literal because the footer row is
        // CONDITIONAL. `Fixed.measure` returns its basis unconditionally and the
        // flexible transcript is handed only what is left, so an unconditional
        // second footer row would take the transcript to nothing on a short
        // terminal — the same failure `promptRowCap` exists to prevent, arriving
        // by a different door.
        var mainChildren: [any LayoutNode] = [
            Flexible(1, TranscriptNode(view: transcriptView, capabilities: graphicsCapabilities, cell: cellSize)),
            Fixed(.absolute(ClientLayout.statusRows), statusBar.layout),
        ]
        if layout.footerRows > 0 {
            mainChildren.append(Fixed(.absolute(layout.footerRows), footerBar.layout))
        }
        mainChildren.append(Fixed(.absolute(layout.promptRows), promptInput.layout))
        var rootChildren: [any LayoutNode] = [Fixed(.absolute(layout.sidebarWidth), sidebar.layout)]
        if layout.dividerColumn != nil {
            let divider = theme.palette(for: appearance).muted.foreground(trueColor: graphicsCapabilities.trueColor)
            rootChildren.append(Fixed(.absolute(ClientLayout.dividerWidth), VerticalDividerNode(color: divider)))
        }
        rootChildren.append(Flexible(1, Column(mainChildren)))
        return Row(rootChildren)
    }

    /// What the accounting footer should say right now.
    ///
    /// The cwd comes from the SESSION — the sidebar row for the open session —
    /// and not from the client's own process, which may be running somewhere else
    /// entirely (that is the whole point of `--serve`). The branch comes from
    /// disk, through the cache above. The numbers come from the store, which
    /// folds the live stream on top of the server's last authoritative answer.
    private func footerModel() -> FooterModel {
        let cwd = store.sessions.first { $0.id == store.selectedSessionID }?.cwd ?? ""
        refreshBranchIfNeeded(cwd: cwd)
        return FooterModel(cwd: cwd, branch: branchCache?.branch, accounting: store.accounting)
    }

    /// Re-read the branch when the directory changed or a turn just settled, and
    /// at no other time. See ``branchCache``.
    private func refreshBranchIfNeeded(cwd: String) {
        let turnJustSettled = branchCacheRunState == .running && store.runState == .idle
        branchCacheRunState = store.runState
        guard branchCache?.cwd != cwd || turnJustSettled else { return }
        branchCache = (cwd, GitInfo.branch(forWorkingDirectory: cwd))
    }

    /// The status line: what the run is doing right now, then the key hints.
    ///
    /// The run state alone ("streaming…") is not enough to distinguish "the model is
    /// thinking", "a tool is running" and "a tool is parked waiting for you" — and
    /// the third is the one a user reads as a freeze. Each gets its own text.
    private func statusText() -> String {
        var parts: [String] = []
        if !streamConnected {
            // Name the reason. "disconnected — reconnecting…" says only that
            // something is wrong; "connection refused" says the runtime is gone,
            // and "HTTP 401" says the token is.
            let reason = lastStreamError.map { " — \(sanitizeUntrustedText(collapseToOneLine($0)))" } ?? ""
            parts.append("\u{1b}[31mdisconnected\(reason) — reconnecting…\u{1b}[0m")
        }
        if let active = store.activeToolCall {
            let label = active.detail.isEmpty ? active.name : "\(active.name) \(active.detail)"
            switch active.state {
            case .awaitingApproval:
                parts.append("⏳ \(label) — needs approval")
            default:
                parts.append("\(spinnerGlyph()) \(label)")
            }
        } else {
            switch store.runState {
            case .running: parts.append("\(spinnerGlyph()) thinking…")
            case .idle: parts.append(store.lastStopReason.map { "idle (\($0))" } ?? "idle")
            }
        }
        // How long the stream has been silent, whenever a run is supposed to be in
        // flight. This one segment is the difference between "the model is slow"
        // and "nothing is connected", which up to now looked identical: a spinner.
        //
        // Outside the run-state branch above rather than inside it, deliberately.
        // A tool call that has been running for six minutes is the same question,
        // and the answer is just as available: the server heartbeats every 15 s
        // whether or not a turn is doing anything, so silence past the threshold
        // means the STREAM is dead, never merely that the work is slow.
        if store.runState == .running {
            let quiet = Int(Date().timeIntervalSince(store.lastEventAt))
            if quiet >= Int(Self.silenceThreshold) { parts.append("(no data for \(quiet)s)") }
        }
        if store.queuedMessageCount > 0 {
            parts.append("queued \(store.queuedMessageCount)")
        }
        if store.selectedSessionID != nil {
            parts.append("mode " + agentMode.rawValue)
            parts.append("ws " + workspaceSnapshotStatus.rawValue)
        }
        if transcriptView.hasImages {
            parts.append(transcriptView.imagesExpanded ? "F6: shrink images" : "F6: enlarge images")
        }
        // Contextual controls come before transient notices. The status row is
        // truncated from the right, and a long disconnect or refusal notice can
        // otherwise hide the diagnostic key at exactly the moment it explains the
        // problem. The notice remains useful when it follows the key, while the
        // key remains discoverable throughout the notice's lifetime.
        if !streamConnected || store.runState == .running {
            parts.append("^G: diagnostics")
        }
        if store.hasExpandableDetail {
            parts.append(transcriptView.expandErrors ? "^O: collapse" : "^O: expand")
        }
        if let notice {
            parts.append("\u{1b}[33m\(notice)\u{1b}[0m")
        }
        if transcriptView.scrollOffset > 0 {
            // Names a key, not a wheel. The wheel is gone the moment the mouse is
            // released, and this segment used to go on advertising "scroll down to
            // follow" while no gesture on the machine could do it.
            parts.append("↑ \(transcriptView.scrollOffset) rows — PgDn to follow")
        }
        // While a modal owns the keyboard the ordinary hints are lies: Enter answers
        // the prompt rather than sending, and Escape selects Reject rather than
        // aborting the turn. Advertising the wrong contract is how a user ends up
        // pressing keys that do something they did not intend.
        if permissionList != nil {
            parts.append("↑/↓: choose")
            parts.append("Enter: answer")
            parts.append("Esc: select Reject")
            parts.append("^C: quit")
        } else if selection.selection != nil {
            // While something is highlighted the ordinary hints are wrong in the
            // two places that matter: Escape clears the selection rather than
            // aborting the turn, and there is a gesture on offer that is otherwise
            // undiscoverable. A selection is short-lived, so this replaces the hints
            // rather than crowding in beside them.
            parts.append("right-click: copy")
            parts.append("Esc: clear selection")
            parts.append(mouseOwned ? "F8: release mouse" : "F8: capture mouse")
            parts.append("^C: quit")
        } else {
            // Which mode the mouse is in, always, and FIRST among the hints — a
            // released mouse changes what every other hint means (whether a drag
            // selects here or in the terminal, whether the wheel scrolls the
            // transcript), and a status line is truncated from the right, so a
            // mode marker at the end is a mode marker that vanishes on a narrow
            // terminal exactly when a notice is explaining it.
            //
            // It also carries the scroll keys, and it is the ONLY place they are
            // advertised, for two reasons. The line is already over budget at
            // ordinary widths — a ninth constant hint would push `Esc: abort` off
            // an 80-column terminal — and this is exactly the state in which the
            // wheel does not work, so it is the state in which the keys have to be
            // discoverable. With the mouse captured the wheel is the gesture, and
            // the "↑ N rows — PgDn to follow" segment names the key the moment
            // there is anything to scroll back to.
            //
            // Spelled "mouse: released" rather than "mouse released" so it is not a
            // substring of the six-second F8 notice: the two used to be
            // indistinguishable on the page, which meant deleting this marker
            // entirely changed nothing any test could see.
            //
            // Kept SHORT on purpose. Naming the keys here instead cost 21 columns
            // and pushed "Esc: abort" and "^C: quit" off a 150-column terminal
            // whenever the mouse was released — the same harm this block's own
            // reasoning avoids by not adding a ninth constant hint. The keys go on
            // the transient F8 notice, which has the room and is on screen at
            // exactly the moment the user needs them.
            if !mouseOwned { parts.append("mouse: released") }
            // The current mouse contract is more important than the static
            // navigation hints below, and the notice above can consume most of
            // the row on a narrow terminal. Keep the escape hatch beside the
            // persistent mode marker so it remains visible in both directions.
            parts.append(mouseOwned ? "F8: release mouse" : "F8: capture mouse")
            // Keep the abort contract near the contextual controls. The status
            // row is truncated from the right, and on a narrow full-screen client
            // the always-available tail would otherwise disappear before the
            // user can see how to stop a run.
            parts.append("Esc: abort")
            parts.append("Tab: mode")
            parts.append("Enter: send")
            // The working newline bindings, not the one a user will reach for first.
            // Shift+Enter is byte-identical to Enter unless the terminal volunteers a
            // CSI-u report, and this package never negotiates the Kitty keyboard
            // protocol that would ask for one — so advertising Shift+Enter would be
            // advertising a key that submits.
            parts.append("Alt+↵/^J: newline")
            parts.append("↑/↓: history")
            parts.append("^C: quit")
        }
        return parts.joined(separator: "   ")
    }

    /// Post a transient message to the status line.
    ///
    /// The client had no error surface at all, which is why every failure it could
    /// not handle was simply swallowed. Anything that refuses or loses user input has
    /// somewhere to say so now.
    private func post(notice text: String, seconds: Double = 4) {
        notice = text
        noticeExpiry = Date().addingTimeInterval(seconds)
        noticeIsRunScoped = false
        surface?.requestRender()
    }

    /// Drop a run-scoped notice once the run it described has settled.
    ///
    /// Called on every applied frame, so it fires on the `agent_end` that ends
    /// the run whether it completed, errored, or was aborted from this client.
    private func clearNoticeIfRunSettled() {
        guard noticeIsRunScoped, store.runState != .running else { return }
        noticeIsRunScoped = false
        notice = nil
        noticeExpiry = nil
    }

    /// Start the optional display-title request at the lifecycle boundary where it
    /// is safe: after a normal first turn has emitted `agent_end`. Starting it when
    /// the frame arrives races the server's final `finishRun` hop and produces a
    /// spurious 409; starting it from the prompt path can also title an aborted or
    /// errored session. The observed session id prevents a late end from one session
    /// from titling the session the user just selected.
    private func observeRunStateChange() {
        let sessionID = store.selectedSessionID
        guard observedRunSessionID == sessionID else {
            observedRunSessionID = sessionID
            observedRunState = store.runState
            terminalNative?.setProgress(store.runState == .running ? .indeterminate : .clear)
            return
        }
        let previous = observedRunState
        observedRunState = store.runState

        if previous != store.runState {
            if store.runState == .running {
                terminalNative?.setProgress(.indeterminate)
            } else if previous == .running {
                terminalNative?.setProgress(.clear)
                if store.runState == .idle,
                   store.lastStopReason == "completed",
                   terminalFocused == false {
                    terminalNative?.notify(
                        title: "DoMoCode",
                        message: "Run finished",
                        protocol: .osc777
                    )
                }
            }
        }

        guard previous == .running,
              store.runState == .idle,
              store.lastStopReason == "completed",
              let sessionID,
              !automaticTitleAttemptedSessionIDs.contains(sessionID),
              autoTitleTask == nil,
              store.sessions.first(where: { $0.id == sessionID })?.name == nil
        else { return }

        automaticTitleAttemptedSessionIDs.insert(sessionID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoTitleTask = nil }
            let retryCount = 4
            for attempt in 0..<retryCount {
                guard !Task.isCancelled else { return }
                do {
                    guard let title = try await self.client.autoTitle(sessionID: sessionID) else { return }
                    guard self.store.selectedSessionID == sessionID else { return }
                    do {
                        self.store.setSessions(try await self.client.listSessions())
                    } catch {
                        // The title is already durable; the next sidebar refresh
                        // will pick it up. Avoid turning optional presentation
                        // metadata into a transcript error row.
                        self.post(notice: "session titled: " + sanitizeUntrustedText(title))
                        return
                    }
                    self.post(notice: "session titled: " + sanitizeUntrustedText(title))
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if case ServerClientError.unexpectedStatus(409, _, _) = error,
                       attempt + 1 < retryCount {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    guard self.store.selectedSessionID == sessionID else { return }
                    self.post(notice: "automatic title unavailable — use ^P to retry")
                    return
                }
            }
        }
        autoTitleTask = task
        actionTasks.append(task)
    }

    /// Show a non-error runtime notice on the status line.
    ///
    /// The dwell comes from the notice's own TTL when it has one, because the
    /// only producer today — a retry — knows exactly how long its message stays
    /// true: the backoff it is about to sleep. Clamped at both ends so a hostile
    /// or absurd `Retry-After` can neither flash the line for 20ms nor pin it
    /// there for an hour.
    ///
    /// The upper bound is deliberately generous — the retry sleep budget's
    /// default, not the per-attempt cap. An operator may raise
    /// `DOMOCODE_RETRY_MAX_MS` above the 60s default, and this client cannot see
    /// what they chose; clamping to a guess would blank the status line while the
    /// run is still waiting, which is the silence this path exists to remove.
    /// Staleness is handled by ``clearNoticeIfRunSettled()`` rather than by a
    /// tight timer: the notice goes the moment the run does, so the only thing
    /// this ceiling still guards against is an absurd TTL during a run that
    /// really is still going.
    ///
    /// The text is sanitized even though the retry summary is built from
    /// program-controlled parts. This is the general door for warning/info
    /// notices, the next producer may not be so careful, and a status line that
    /// accepts raw provider text is how an escape sequence reaches the frame.
    private func show(_ notice: ServerNotice) {
        let body = sanitizeUntrustedText(collapseToOneLine(notice.text))
        guard !body.isEmpty else { return }
        let seconds = notice.ttlMilliseconds.map { Double($0) / 1000 }
        post(notice: body, seconds: min(max(seconds ?? 4, 2), Self.maxNoticeDwell))
        // After `post`, which resets the flag for the ordinary case.
        noticeIsRunScoped = notice.code == "retry"
    }

    /// One line describing anything the transport threw.
    ///
    /// Three shapes, because three things are actually thrown here. An HTTP
    /// status keeps the endpoint AND the body — a 500 and a 502 look identical
    /// until you read what the server said about it. A ``DoMoError`` keeps its
    /// whole cause chain, which is the one line it was designed to produce.
    /// Anything else falls back to `String(describing:)`, which for a
    /// `NIOConnectionError` is at least the address that refused.
    private static func describe(_ error: any Error) -> String {
        if case ServerClientError.unexpectedStatus(let status, let path, let body) = error {
            return "HTTP \(status) from \(path)" + (body.map { ": \($0)" } ?? "")
        }
        if case ServerClientError.timedOut(let path) = error { return "timed out: \(path)" }
        if case ServerClientError.streamIdle(let path) = error { return "stream went silent: \(path)" }
        if let domo = error as? DoMoError { return domo.description }
        return String(describing: error)
    }

    /// Put a failure on the transcript, where it stays.
    ///
    /// The rule this file now follows: a transient notice is for an action that
    /// was REFUSED with nothing lost and an obvious remedy ("no session is
    /// open"); a transcript row is for anything the user has to read, act on, or
    /// copy. A four-second status message is not a delivery mechanism for
    /// "prompts will not work until you reopen this session".
    ///
    /// The session file is appended to the hint because it is the only "where do
    /// I see more" this program can honestly offer: there is no log file, and
    /// stderr under the alternate screen is invisible.
    private func postError(_ headline: String, _ error: any Error, hint: String? = nil) {
        postError(headline, reason: Self.describe(error), hint: hint)
    }

    /// The same row, for a failure that is already a sentence rather than a
    /// thrown value — a stream that ended cleanly has nothing to `describe`.
    private func postError(_ headline: String, reason: String, hint: String? = nil) {
        var hints: [String] = []
        if let hint { hints.append(hint) }
        if let path = store.sessionPath { hints.append("Full transcript: \(path)") }
        store.postError(
            headline: headline,
            message: reason,
            hint: hints.isEmpty ? nil : hints.joined(separator: " ")
        )
    }

    private func spinnerGlyph() -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        return frames[((transcriptView.spinnerFrame % frames.count) + frames.count) % frames.count]
    }

    // MARK: In-flight animation

    /// Advance the spinner while anything is in flight, and repaint.
    ///
    /// Adaptive: it ticks at the animation rate only when there is something to
    /// animate, and otherwise idles at a slow poll — an idle session must not repaint
    /// ten times a second forever. Cancelled with the session.
    private func startSpinnerClock() {
        spinnerTask?.cancel()
        spinnerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let expiry = self.noticeExpiry, Date() >= expiry {
                    self.notice = nil
                    self.noticeExpiry = nil
                    self.surface?.requestRender()
                }
                let animating = self.store.runState == .running || self.store.activeToolCall != nil
                let width = self.surface?.target.columns ?? 0
                let height = self.surface?.target.rows ?? 0
                let layout = ClientLayout(
                    width: width,
                    height: height,
                    promptRows: self.promptRows,
                    footerRows: ClientLayout.footerRows(for: height)
                )
                let marqueeAnimating = self.statusBar.marqueeActive(width: layout.mainWidth)
                    || self.sidebar.marqueeActive(width: layout.sidebarWidth)
                if animating {
                    self.transcriptView.spinnerFrame &+= 1
                }
                if animating || marqueeAnimating {
                    self.surface?.requestRender()
                }
                self.pollStatusIfDue()
                try? await Task.sleep(for: animating || marqueeAnimating ? .milliseconds(100) : .milliseconds(250))
            }
        }
    }

    /// Ask the server what it actually believes, while the client believes a run is
    /// in flight, and adopt the answer.
    ///
    /// This is the one thing that makes the client self-correcting. Every other
    /// path back to `idle` is an edge — `agent_end`, a `connected(running:false)`,
    /// an abort that answers "nothing was running" — and the wedge is precisely the
    /// state where none of those edges will ever arrive. There is a real window in
    /// which even `connected` lies: the run task broadcasts its terminal `agent_end`
    /// and only THEN hops to `finishRun`, so a `connected` frame generated during
    /// that hop reports `running: true` AFTER the client already applied the end,
    /// pinning it with no further frame ever coming.
    ///
    /// Folded into the existing spinner clock rather than given a timer of its own:
    /// that clock is already adaptive, already cancelled with the app, and one task
    /// that can be reasoned about beats two that can drift apart.
    private func pollStatusIfDue() {
        // `wantsAccountingPoll` is the second trigger, and it is what keeps the
        // footer honest between runs: the last turn of a run is folded locally,
        // and a compaction's own usage is billed to the session without ever
        // being streamed as an assistant turn, so an idle session's total is only
        // right once the server has been asked one more time. The store clears
        // the flag on any answer — and ``EventStore/noteAccountingPollFailed()``
        // clears it on a failure — so this is one extra poll per run, not a
        // second timer.
        guard store.runState == .running || store.wantsAccountingPoll,
              !statusPollInFlight,
              Date().timeIntervalSince(lastStatusPollAt) >= Self.statusPollInterval,
              let id = store.selectedSessionID
        else { return }
        statusPollInFlight = true
        lastStatusPollAt = Date()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.statusPollInFlight = false }
            await self.reconcileWithServer(id)
        }
        actionTasks.append(task)
    }

    /// Ask for the server's snapshot once and adopt it.
    ///
    /// `try?` throughout: an older runtime has no such route, and this is a
    /// diagnosis rather than something the user asked for — it must never put a row
    /// on the transcript for failing.
    private func reconcileWithServer(_ id: String) async {
        guard let status = try? await client.status(sessionID: id) else {
            // Told, rather than swallowed. The accounting trigger above re-asks
            // until it gets an answer, and against a runtime that is gone (or one
            // that predates this route) "until it gets an answer" is forever.
            // Session-checked like every other write here: a poll that failed for
            // the session we just left must not silence the one we just opened.
            if store.selectedSessionID == id { store.noteAccountingPollFailed() }
            return
        }
        guard store.selectedSessionID == id else { return }
        let wasRunning = store.runState == .running
        adoptAgentMode(status.mode)
        store.adopt(status)
        if wasRunning, !status.running {
            // Said out loud, because from the user's side nothing visibly happened:
            // the spinner they had been watching simply stops.
            post(notice: "the server says nothing is running — you can send again")
        }
        // The ask frame was lost while we stayed connected. This is the window the
        // connected-reconcile can never cover, because no reconnect happens and
        // therefore no `connected` frame is ever generated to trigger it.
        if store.hasUnseenPermission(in: status.pendingPermissionIDs) {
            await reconcilePendingPermissions(id)
        }
        if store.hasUnseenQuestion(in: status.pendingQuestionIDs ?? []) {
            await reconcilePendingQuestions(id)
        }
    }

    // MARK: Scrolling

    /// Move a pane's viewport. The ONE writer of ``TranscriptView/scrollOffset``.
    ///
    /// Shared by the wheel and by the keyboard deliberately. Until this existed the
    /// offset was written in exactly one place — inside `handleMouse`, behind
    /// `guard mouseOwned` — so releasing the mouse (F8, or `--no-mouse` for a whole
    /// session) left the transcript with no way to scroll at all while the status
    /// line went on advertising a gesture that no longer existed.
    ///
    /// No upper clamp here: only ``TranscriptNode/place(in:into:)`` knows the
    /// viewport height, and it writes the clamped value back after painting, so a
    /// PgUp past the top self-corrects on the very next frame rather than leaving a
    /// phantom offset the status line would report.
    private func scroll(_ pane: ClientLayout.Pane, rows: Int, up: Bool, layout: ClientLayout) {
        // Rows are about to move under the selection, so it is gone by definition —
        // cleared BEFORE the scroll, so no frame is ever composed with a highlight
        // over content that has shifted. The click run goes with it: a second click
        // in the same cell after a scroll is a click on different text and must not
        // expand to a word.
        selection.clear()
        selection.resetClickRun()
        switch pane {
        case .sidebar:
            sidebar.scroll(by: up ? -rows : rows, viewportHeight: layout.height)
        case .divider, .transcript, .mainFooter:
            // The transcript is the main column's scrollable body; the status and
            // prompt rows are one line each and scroll it too, so a wheel near the
            // bottom edge is not silently dead.
            transcriptView.scrollOffset = max(0, transcriptView.scrollOffset + (up ? rows : -rows))
        }
    }

    /// A scroll asked for with the keyboard, or nil when `data` is not one.
    ///
    /// PgUp/PgDn is the primary binding and Shift+↑/↓ the fine-grained one. Both
    /// were checked against `DoMoTermIO/KeyDecoding.swift` rather than assumed:
    ///
    /// * PgUp/PgDn arrive as `\e[5~`/`\e[6~` (`legacyKeySequences`) or as the
    ///   Kitty `\e[5;1~` form, both unmodified and both unambiguous. They are
    ///   bound to `.editorPageUp`/`.editorPageDown` in `Keybindings.defaults`, so
    ///   intercepting them here TAKES them from the prompt — deliberately. The
    ///   prompt is capped at about a third of the screen and its page motion there
    ///   is indistinguishable from ↑/↓, while the transcript is the only viewport
    ///   in this UI with a page worth turning. They are also bound to
    ///   `.selectPageUp`/`.selectPageDown`, which is why this check sits BELOW the
    ///   modal and diagnostics branches: a list that is up keeps its own paging.
    /// * Shift+↑/↓ arrive as `\e[1;2A`/`\e[1;2B` (xterm/kitty/iTerm2) or `\e[a`/
    ///   `\e[b` (rxvt) — different bytes from the bare `\e[A`/`\e[B` that recall
    ///   prompt history, so the decoder tells them apart and the boundary-row
    ///   history gesture is untouched. On a terminal that sends bare arrows for
    ///   Shift+arrow the keystroke simply recalls history, exactly as it does
    ///   today.
    ///
    /// Ctrl-U/Ctrl-D were rejected: `Keybindings.defaults` binds them to
    /// `.editorDeleteToLineStart` and `.editorDeleteCharForward`, so taking them
    /// would make a scroll key delete the user's text on a terminal where the
    /// other bindings work.
    private func keyboardScroll(_ data: [UInt8]) -> (rows: Int, up: Bool, page: Bool)? {
        if matchesKey(data, Key.pageUp) { return (0, true, true) }
        if matchesKey(data, Key.pageDown) { return (0, false, true) }
        if matchesKey(data, KeyId(base: .up, shift: true)) { return (1, true, false) }
        if matchesKey(data, KeyId(base: .down, shift: true)) { return (1, false, false) }
        return nil
    }

    /// Scroll the pane the user is looking at, from the keyboard.
    ///
    /// FOCUS-targeted, unlike the wheel, because a keystroke carries no
    /// coordinates: with the sidebar focused the keys page the session list, and
    /// otherwise — including the ordinary case where the prompt holds the caret —
    /// they page the transcript, which is what a user reading a long reply while
    /// typing the next question expects.
    private func scrollFromKeyboard(rows: Int, up: Bool, page: Bool) {
        let columns = surface?.target.columns ?? 0
        let height = surface?.target.rows ?? 0
        let layout = ClientLayout(
            width: columns,
            height: height,
            promptRows: promptRows,
            footerRows: ClientLayout.footerRows(for: height)
        )
        // A page keeps one row of overlap, so the eye has an anchor across the
        // jump — the same step the Ctrl-wheel already uses.
        let step = page ? max(1, layout.transcriptHeight - 1) : max(1, rows)
        scroll(focus.current === sidebar ? .sidebar : .transcript, rows: step, up: up, layout: layout)
        surface?.requestRender()
    }

    // MARK: Mouse

    /// Route a mouse report to the pane under the pointer.
    ///
    /// Pointer-targeted rather than focus-targeted, which is what every terminal
    /// application does and what a user expects: you scroll — and select — what you
    /// are looking at, without first Tab-ing focus to it.
    ///
    /// Two gestures live here. The wheel scrolls, because the alternate screen has
    /// no scrollback for the terminal to scroll on our behalf. A left drag selects
    /// and a right click copies, because taking the mouse for the first also takes
    /// away the terminal's OWN selection and its right-click menu — a debt this
    /// pays back rather than leaving the user with F8 as the only answer.
    private func handleMouse(_ event: MouseEvent) {
        // With the mouse released the terminal owns the pointer. A report can still
        // arrive — one already in the pipe when F8 was pressed — and acting on it
        // would paint a highlight the user cannot clear with a gesture we no longer
        // receive.
        guard mouseOwned, let target = surface?.target else { return }
        let layout = ClientLayout(
            width: target.columns,
            height: target.rows,
            promptRows: promptRows,
            footerRows: ClientLayout.footerRows(for: target.rows)
        )

        if !event.isScroll {
            switch layout.pane(atColumn: event.column, row: event.row) {
            case .sidebar:
                sidebar.updateHover(screenRow: event.row)
            default:
                sidebar.clearHover()
            }
        }

        if event.isScroll {
            guard event.kind == .scrollUp || event.kind == .scrollDown else { return }
            // Ctrl-wheel pages, matching the convention of a viewport that has no
            // separate page keys.
            let step = event.ctrl ? max(1, layout.transcriptHeight - 1) : 3
            scroll(
                layout.pane(atColumn: event.column, row: event.row),
                rows: step,
                up: event.kind == .scrollUp,
                layout: layout
            )
            surface?.requestRender()
            return
        }

        let cell = ScreenCell(row: event.row, column: event.column)
        // The PREVIOUS frame, which is what the user was looking at when they
        // pressed. `validate` re-checks it against the next composed frame, and
        // `copySelection` re-checks it before copying, so a press against a frame
        // that has since changed can never produce a wrong clipboard.
        let frame = surface?.lastFrameLines ?? []
        switch (event.kind, event.button) {
        case (.press, .left):
            let pane = layout.pane(atColumn: event.column, row: event.row)
            selection.press(
                at: cell,
                columns: layout.bounds(of: pane).columns,
                frame: frame,
                shiftExtend: event.shift,
                now: Date()
            )
        case (.move, .left):
            selection.drag(to: cell, frame: frame)
        case (.release, .left), (.release, .none):
            // SGR names the button on release; X10 has no release code of its own
            // and reports button bits `3`, which the decoder maps to `.none`. Both
            // end the drag.
            selection.release(at: cell, frame: frame)
        case (.press, .right):
            copySelection()
        default:
            // Middle click is X11 primary-selection paste. It stays inert on
            // purpose: reading a clipboard needs an OSC 52 *query*, whose answer
            // arrives on stdin — a terminal-side exfiltration channel this program
            // will not open for a convenience.
            break
        }
        surface?.requestRender()
    }

    /// Right-click: put the selection on the clipboard.
    private func copySelection() {
        let frame = surface?.lastFrameLines ?? []
        // Re-checked against the frame the copy is actually taken from, so a
        // selection whose rows changed between the drag and the click copies
        // nothing rather than copying whatever replaced them.
        selection.validate(against: frame)
        guard let text = selection.text(from: frame), !text.isEmpty else {
            // Nothing selected. Say what the gesture is for rather than doing
            // something surprising: pasting is impossible (we cannot read the
            // clipboard) and selecting under the pointer would copy text the user
            // never chose.
            post(notice: "drag to select, then right-click to copy · F8 releases the mouse")
            return
        }
        writeClipboard(text)
        // The highlight goes with the copy: it has served its purpose, and leaving
        // it up invites a second right-click that copies the same thing again.
        selection.clear()
    }

    /// Put `text` on the user's clipboard by both routes that exist.
    ///
    /// OSC 52 first, because it is the only one that works across ssh and inside a
    /// multiplexer — the bytes ride the tty this UI is already painting on. The
    /// local helper second, because several terminals ship OSC 52 writes disabled
    /// and would otherwise silently do nothing. Neither is a fallback for the
    /// other; whichever the user's setup supports wins, and doing both is how the
    /// copy works without asking the user which one they have.
    ///
    /// Writing an escape between frames is safe here specifically: every
    /// alternate-screen row is placed with an absolute CUP, so an out-of-band
    /// sequence cannot desynchronise the paint cursor.
    private func writeClipboard(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if let sequence = osc52CopySequence(Array(text.utf8), multiplexer: multiplexer) {
            surface?.target.write(String(decoding: sequence, as: UTF8.self))
            post(notice: "copied \(lines) line\(lines == 1 ? "" : "s")")
        } else {
            // A refusal, not a truncation: a terminal bounds its OSC parser and
            // truncates past the bound SILENTLY, so an oversized sequence does not
            // fail, it produces a wrong clipboard. The local helper has no such cap.
            post(notice: "selection too large for the terminal clipboard — trying the local helper")
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if case .failed(let why) = await self.clipboard.copy(text) {
                self.post(notice: "clipboard: \(sanitizeUntrustedText(collapseToOneLine(why)))")
            }
        }
        actionTasks.append(task)
    }

    /// Read Ctrl-V from the injected local clipboard source. Image bytes are
    /// sniffed again before staging, bounded by the same per-turn limits as file
    /// drops, and kept in the attachment chip rather than written to a durable
    /// temporary file.
    private func pasteClipboard() {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let image = await self.clipboardPaste.readImage() {
                self.stageClipboardImage(image)
                return
            }
            if let text = await self.clipboardPaste.readText() {
                let clean = PromptInput.sanitizedForInsertion(text)
                if !clean.isEmpty {
                    self.promptInput.restore(clean)
                    self.surface?.requestRender()
                }
                return
            }
            self.post(notice: "clipboard has no readable image or text")
        }
        actionTasks.append(task)
    }

    private func stageClipboardImage(_ clipboardImage: ClipboardImage) {
        let data = clipboardImage.data
        guard !data.isEmpty else {
            post(notice: "clipboard image is empty")
            return
        }
        guard data.count <= Self.attachmentLimits.maximumBytesPerImage else {
            post(notice: "clipboard image is over the \(LoadedImage.formattedByteCount(Self.attachmentLimits.maximumBytesPerImage)) limit")
            return
        }
        guard promptInput.attachments.count < Self.attachmentLimits.maximumCount else {
            post(notice: "at most \(Self.attachmentLimits.maximumCount) images per message")
            return
        }
        let currentBytes = promptInput.attachments.reduce(0) { $0 + $1.byteCount }
        guard currentBytes <= Self.attachmentLimits.maximumTotalBytes,
              data.count <= Self.attachmentLimits.maximumTotalBytes - currentBytes else {
            post(notice: "clipboard image would exceed the \(LoadedImage.formattedByteCount(Self.attachmentLimits.maximumTotalBytes)) total limit")
            return
        }
        guard let mediaType = FileContentProbe.imageMediaType(data) else {
            post(notice: "clipboard does not contain a supported image")
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
        let path = FilePath("/tmp/domocode-clipboard-\(UUID().uuidString).\(extensionName)")
        let loaded = LoadedImage(
            path: path,
            displayName: "clipboard.\(extensionName)",
            mediaType: mediaType,
            data: data
        )
        guard let attachment = stage([loaded]).first else { return }
        promptInput.addAttachment(attachment)
        post(notice: "attached clipboard image")
        surface?.requestRender()
    }

    /// F8: hand the mouse back to the terminal, or take it again.
    ///
    /// The escape hatch the in-app selection owes the user. Terminals differ, and
    /// this program cannot be right about all of them; a user whose terminal it
    /// gets wrong needs their own selection and their own right-click menu back
    /// without ending the session and restarting with `--no-mouse`.
    private func toggleMouse() {
        mouseOwned.toggle()
        // Whatever was selected was selected with a mouse we may no longer have.
        selection.clear()
        lifecycle?.setMouseReporting(mouseOwned)
        post(
            // The wheel goes WITH the mouse — that is the surprise, and saying it
            // is the whole point of this notice: a user who pressed F8 to get
            // their terminal's own selection back did not ask to lose scrolling
            // and would otherwise discover it by finding the transcript frozen.
            // The replacement keys are on the persistent marker beside it, which
            // outlives the six seconds; repeating them here would only cost the
            // columns that the marker itself needs.
            notice: mouseOwned
                ? "mouse captured — drag to select, right-click to copy"
                : "mouse released — PgUp/PgDn scrolls now, the wheel went with it",
            seconds: 6
        )
        surface?.requestRender()
    }

    // MARK: Dropped files

    /// Answer a drop the prompt handed over: read the candidate paths off the main
    /// actor and either stage them as chips or give the text back.
    ///
    /// The whole gesture rests on one rule — NEVER SILENTLY EAT A PATH THE USER
    /// MEANT AS TEXT. `DroppedPaths` refuses to even offer prose, and this refuses
    /// everything that is not an image on disk right now, putting the raw paste
    /// back at the caret verbatim. Asking about `/tmp/notes.txt` in a sentence, or
    /// dropping a PDF, leaves you with exactly the text you pasted plus a line
    /// saying why nothing was attached.
    ///
    /// Three outcomes, not two, because `ImageAttachmentLoader.resolveDrop` ranks
    /// whole READINGS of the paste: `/Users/x/my pic.png` is either one file with a
    /// space or two files, and only the disk can say which. A rejection can
    /// therefore mean either "this tokenization was wrong" — in which case nothing
    /// may be attached and the raw paste goes back whole — or "this file cannot
    /// ride this message", in which case the ones that CAN must be attached and
    /// only the refused paths go back. ``readingResolved(_:candidateCount:)`` is
    /// where those two are told apart; treating every rejection as the first is
    /// how a drop of nine photos attached none of them and then said the ninth
    /// had been "skipped".
    private func resolveDrop(token: UInt32, candidates: [[String]]) {
        // Taken before the hop: the raw text is the only copy of what the user
        // pasted, and the prompt forgets it the moment the drop is answered.
        let rawText = promptInput.pendingDropText(for: token) ?? ""
        let staged = promptInput.attachments
        let limits = Self.attachmentLimits
        let fileSystem = self.fileSystem
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // `resolveDrop` is `@concurrent`, so the stat/sniff/read and the whole
            // image payload stay off the render loop — which is the difference
            // between a chip appearing and the UI freezing for the length of a
            // 5 MiB read.
            let result = await ImageAttachmentLoader.resolveDrop(
                candidates: candidates,
                using: fileSystem,
                limits: limits,
                alreadyLoaded: staged.map(Self.loadedImage)
            )
            defer { self.surface?.requestRender() }

            if result.isCompleteSuccess {
                let attached = self.stage(result.loaded)
                let live = self.promptInput.resolveDrop(token: token, outcome: .attached(attached))
                guard live else { self.reportAbandonedDrop(attached.count); return }
                if attached.isEmpty {
                    // Every path in the reading named something already staged. Not a
                    // failure, and not a new chip either — say so, or a second drop of
                    // the same file looks like it did nothing.
                    self.post(notice: "already attached")
                } else {
                    self.post(notice: "attached \(attached.count) image\(attached.count == 1 ? "" : "s")")
                }
                return
            }

            // A resolved reading that hit a limit or named one non-image among
            // several: attach what loaded and hand back ONLY the refused paths.
            if !result.loaded.isEmpty,
               Self.readingResolved(result, candidateCount: candidates.count) {
                let attached = self.stage(result.loaded)
                // The paths as the loader named them, one per line — not `rawText`,
                // which is the whole paste and would put the attached files back as
                // text beside their own chips.
                let refusedText = result.rejected.map(\.path.string).joined(separator: "\n")
                let live = self.promptInput.resolveDrop(
                    token: token,
                    outcome: .partial(attached: attached, text: refusedText)
                )
                guard live else { self.reportAbandonedDrop(attached.count); return }
                self.post(notice: Self.partialNotice(attached: attached.count, refused: result.rejected), seconds: 6)
                return
            }

            // A cancelled batch is a gesture the user took back, so it earns no
            // complaint — but the text still goes back, because losing it would
            // be the one failure this feature must never have.
            let notice = result.wasCancelled
                ? ""
                : (result.rejected.first?.message ?? "nothing there to attach")
            let live = self.promptInput.resolveDrop(
                token: token, outcome: .rejected(rawText: rawText, notice: notice))
            guard live else { self.reportAbandonedDrop(0); return }
            if !notice.isEmpty {
                self.post(notice: "not attached — \(sanitizeUntrustedText(collapseToOneLine(notice)))", seconds: 6)
            }
        }
        actionTasks.append(task)
    }

    /// A drop whose answer arrived after the prompt had moved on.
    ///
    /// `PromptInput.resolveDrop` applies nothing to a document that was cleared
    /// under it, so this is the ONLY thing standing between the user and a message
    /// that silently lost its picture while the status line congratulated them. It
    /// says the opposite of what the success notice would have said.
    private func reportAbandonedDrop(_ count: Int) {
        guard count > 0 else { return }
        post(
            notice: "the prompt was cleared while it loaded — "
                + "\(count) image\(count == 1 ? "" : "s") not attached · drop again",
            seconds: 6
        )
    }

    /// Whether a reading that produced rejections nonetheless RESOLVED — i.e. the
    /// rejections mean "this file cannot be attached", not "this was the wrong
    /// tokenization of the paste".
    ///
    /// Exactly two reasons are treated as evidence AGAINST the tokenization, and
    /// only while an alternative reading exists:
    ///
    /// * `.missing` — nothing at that path. This is the signature of a bad split:
    ///   `/Users/x/my pic.png` read as two tokens leaves `/Users/x/my`, which is
    ///   not there. It is also what the whole-string reading produces when the
    ///   drop really was several files.
    /// * `.notARegularFile` — a directory, which is the other thing the leading
    ///   half of a split filename tends to be.
    ///
    /// Every other reason — `.notAnImage`, `.tooLarge`, `.unreadable`, and both
    /// limits — means a REAL FILE was found at that exact path and could not be
    /// attached. A path that resolves to a file on disk is the strongest evidence
    /// there is that the tokenization was right, so the reading is resolved and
    /// the images beside it must be kept.
    ///
    /// The count check is not redundant: `DroppedPaths` offers the whole trimmed
    /// string as a single path alongside the tokenized reading, so a
    /// space-separated multi-file drop essentially always has two candidates and a
    /// rule keyed on "was there only one reading" would refuse every one of them.
    private static func readingResolved(
        _ result: ImageAttachmentLoadResult,
        candidateCount: Int
    ) -> Bool {
        if candidateCount <= 1 { return true }
        return result.rejected.allSatisfy { rejection in
            switch rejection.reason {
            case .missing, .notARegularFile: return false
            default: return true
            }
        }
    }

    /// The notice for a drop that partly attached.
    ///
    /// `ImageAttachmentRejection.message` says "skipped", which is written for the
    /// all-or-nothing surfaces (`--image`, the REPL) where nothing else happened.
    /// Here something else did happen — the rest are on the prompt — so the two
    /// limit reasons are re-worded to say which file is missing from the message
    /// about to be sent. Every other reason already names itself exactly.
    private static func partialNotice(attached: Int, refused: [ImageAttachmentRejection]) -> String {
        let head = "attached \(attached) image\(attached == 1 ? "" : "s")"
        guard let first = refused.first else { return head }
        let clause: String
        switch first.reason {
        case .countLimitReached(let limit):
            clause = "\(first.displayName) not attached: at most \(limit) image\(limit == 1 ? "" : "s") per message"
        case .totalBytesExceeded(let limit):
            clause = "\(first.displayName) not attached: over the "
                + "\(LoadedImage.formattedByteCount(limit)) total limit"
        default:
            clause = first.message
        }
        let more = refused.count > 1 ? " (+\(refused.count - 1) more)" : ""
        return head + " — " + sanitizeUntrustedText(collapseToOneLine(clause)) + more
    }

    /// Turn loaded images into chips, minting an id for each.
    private func stage(_ images: [LoadedImage]) -> [PromptAttachment] {
        images.map { image in
            attachmentCounter &+= 1
            return PromptAttachment(
                id: attachmentCounter,
                path: image.path.string,
                name: image.displayName,
                byteCount: image.byteCount,
                image: ImageBlock(mediaType: image.mediaType, data: image.data)
            )
        }
    }

    /// A staged chip, in the loader's terms, so the count and total-byte limits are
    /// enforced against what is ALREADY on the prompt rather than against each drop
    /// in isolation.
    private static func loadedImage(_ attachment: PromptAttachment) -> LoadedImage {
        LoadedImage(
            path: FilePath(attachment.path),
            displayName: attachment.name,
            mediaType: attachment.image.mediaType,
            data: attachment.image.data
        )
    }

    // MARK: Session lifecycle

    /// Run `work`, retrying a few times before giving up, saying so between goes.
    ///
    /// Only for the two calls that make a session usable at all — the create and
    /// the resume. Everything else in this file is either idempotent and retried
    /// by its own loop (the event stream) or is a user action that must fail
    /// visibly rather than silently take four seconds (a prompt, an abort).
    ///
    /// The notice is the point as much as the retry is: a startup that pauses for
    /// three seconds with a blank sidebar and no explanation is the same experience
    /// as a startup that failed.
    private func retrying<T>(
        _ what: String,
        _ work: () async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        for attempt in 1...Self.sessionAttempts {
            do {
                return try await work()
            } catch {
                lastError = error
                guard attempt < Self.sessionAttempts else { break }
                post(notice: "could not \(what) — retrying (\(attempt)/\(Self.sessionAttempts - 1))")
                try? await Task.sleep(for: .milliseconds(500 * attempt))
            }
        }
        // Non-nil: the loop runs at least once and only leaves here via a `catch`.
        throw lastError ?? ServerClientError.timedOut(path: what)
    }

    private func bootstrap() async {
        // Prompt history first, and off the render loop: it is a local file read, it
        // is what the very first Up will want, and it must not be behind a network
        // round trip to the runtime.
        if let historyStore {
            promptInput.seedHistory(await historyStore.load())
        }
        do {
            commandRegistry = try await client.commands()
            promptInput.setAutocompleteProvider(makeAutocompleteProvider(commands: commandRegistry))
        } catch {
            // Older runtimes do not have the additive route yet. Keep the built-in
            // local actions usable and let the prompt request surface any unknown
            // remote command normally.
            post(notice: "command list unavailable — using built-ins")
        }
        let sessions: [SessionSummary]
        do {
            sessions = try await client.listSessions()
        } catch {
            // Everything below this needs the runtime. Reporting and stopping is
            // honest; carrying on with an empty list produced an empty sidebar,
            // an empty pane, and a prompt box that silently 404'd every send.
            postError(
                "Could not reach the runtime",
                error,
                hint: "The server may not be running, or the token may be wrong."
            )
            return
        }
        store.setSessions(sessions)
        if let first = sessions.first {
            await open(first.id)
        } else {
            await createAndOpen()
        }
    }

    private func createAndOpen() async {
        let ref: SessionRef
        do {
            ref = try await retrying("create a session") { try await self.client.createSession() }
        } catch {
            // A `guard … else { return }` here left the app with no session at
            // all: no transcript, no target for a prompt, and no explanation —
            // and, because bootstrap is the only caller, no way back short of
            // restarting the program.
            postError(
                "Could not create a session",
                error,
                hint: "There is no session to send to. Press 'n' in the sidebar to try again."
            )
            return
        }
        // No `setSessionPath` here: `open` selects the session, which clears it,
        // and then re-learns it from the idempotent resume. One producer.
        do {
            store.setSessions(try await client.listSessions())
        } catch {
            // The sidebar's CONTENT is intact — it is missing one new row, and
            // the session we just made is about to be opened anyway. A transient
            // notice is the right weight for that.
            post(notice: "the session list did not refresh")
        }
        await open(ref.id)
    }

    private func open(_ sessionID: String) async {
        if toolCatalogHandle != nil { dismissToolCatalog() }
        if diffReviewSessionID != nil, diffReviewSessionID != sessionID {
            dismissDiffReview()
        }
        // A new session's transcript is a different document; carrying the old
        // scroll position into it would open it part-way up at an arbitrary row.
        transcriptView.scrollToBottom()
        store.select(sessionID)
        // The status request below is authoritative for this session. Reset the
        // render cache while it is in flight so a previous session's plan marker
        // cannot briefly describe the newly selected conversation.
        agentMode = .build

        // Make the session LIVE on the server before touching its live endpoints.
        //
        // The sidebar lists sessions from DISK, but the runtime only knows sessions
        // it created this process. Every session from a previous launch was therefore
        // dead: `/events` 404'd (so no transcript updates and, crucially, no
        // permission_request could ever arrive), and `/prompt` and `/abort` 404'd into
        // a `try?`. Since bootstrap opens the most recent session, the SECOND and
        // every later launch of `domo` came up attached to a session where nothing
        // worked and nothing said so. `createSession(resume:)` is idempotent — it
        // returns the existing reference when the session is already live — so this is
        // also correct for the session we just created.
        // Both failures below are held and posted AFTER `seed`, never before:
        // `seed` replaces the whole transcript, so a row appended first would be
        // silently deleted by the very next statement — a report that reports
        // nothing is worse than the `try?` it replaced.
        var failures: [(headline: String, error: any Error, hint: String?)] = []

        do {
            // The path comes back on the reference; it is the only durable record
            // of this conversation there is, so a failure row can point at it.
            //
            // Retried, because ONE failure here used to be permanent: the client
            // attached to a session the server does not have live, every endpoint
            // 404'd, and no code path ever tried the resume again. A runtime that
            // is a second slow to come up is not a dead session.
            let ref = try await retrying("reopen this session") {
                try await self.client.createSession(resume: sessionID)
            }
            guard store.selectedSessionID == sessionID else { return }
            store.setSessionPath(ref.path)
        } catch {
            guard store.selectedSessionID == sessionID else { return }
            // The highest-value row in this file. Without it the session opens
            // looking completely normal and then refuses everything: prompts,
            // aborts and approvals all 404 into a `try?`, the stream never
            // attaches, and no permission_request can arrive. The user sees a
            // working-looking UI that does nothing.
            failures.append((
                "This session is not live on the server",
                error,
                "Prompts, aborts and approvals will not work until it is reopened. Retrying in the background."
            ))
        }
        guard store.selectedSessionID == sessionID else { return }

        var history: [Message] = []
        do {
            history = try await client.messages(sessionID: sessionID)
        } catch {
            guard store.selectedSessionID == sessionID else { return }
            // An empty pane is indistinguishable from a brand-new session, so a
            // history that would not load must say so — and the stream still gets
            // attached below, because live events are useful even without the past.
            failures.append(("Could not load this session's history", error, nil))
        }
        // A newer selection may have superseded this one while messages() was in
        // flight (a slow session opened, then a fast one). Drop this stale
        // completion so it cannot clobber the newer session's transcript or attach
        // the wrong live stream — which would leave the sidebar marking B while the
        // pane shows A and a prompt silently targets B.
        guard store.selectedSessionID == sessionID else { return }
        store.seed(history)
        for failure in failures { postError(failure.headline, failure.error, hint: failure.hint) }
        attachEvents(sessionID)
        // Ask for this session's totals once, on open.
        //
        // The stream is delta-only: it can tell the footer what THIS attachment
        // spends and nothing about what the session already spent, so without
        // this a resumed conversation comes up reading zero — a number that is
        // wrong rather than merely absent. After `attachEvents`, so the round trip
        // does not delay the subscription.
        //
        // Accounting ONLY. A full `reconcileWithServer` here would also adopt run
        // state, which is not this call's business and is not free: the SSE
        // `connected(running:)` frame is authoritative for that both ways, and
        // taking it over on open defeats the wedge repair path, where the client
        // believes it is idle until a 409 tells it otherwise.
        //
        // `lastStatusPollAt` is stamped BEFORE the await, not after: the spinner
        // clock's own poll is due whenever `lastStatusPollAt` is `.distantPast`,
        // so without this a session that opens mid-run is polled twice within a
        // few milliseconds, and the second answer lands before the first has been
        // adopted.
        lastStatusPollAt = Date()
        await seedAccounting(sessionID)
        await seedWorkspaceStatus(sessionID)
    }

    /// Fill the footer's totals for a session that was already under way.
    ///
    /// `try?` throughout, and silent: nobody asked for this, an older runtime has
    /// no such route, and a footer that comes up blank is a far better outcome
    /// than a transcript row apologising for a number.
    private func seedAccounting(_ id: String) async {
        guard let status = try? await client.status(sessionID: id) else {
            if store.selectedSessionID == id { store.noteAccountingPollFailed() }
            return
        }
        guard store.selectedSessionID == id else { return }
        adoptAgentMode(status.mode)
        store.adoptAccounting(status)
    }

    private func adoptAgentMode(_ raw: String?) {
        guard let raw, let mode = AgentMode(rawValue: raw.lowercased()) else { return }
        agentMode = mode
    }

    private func seedWorkspaceStatus(_ id: String) async {
        guard let status = try? await client.workspaceStatus(sessionID: id) else {
            if store.selectedSessionID == id {
                workspaceSnapshotStatus = .unavailable
                surface?.requestRender()
            }
            return
        }
        guard store.selectedSessionID == id else { return }
        workspaceSnapshotStatus = status
        surface?.requestRender()
    }

    /// Subscribe to a session's event stream, and KEEP it subscribed.
    ///
    /// The stream is the only push path for `permission_request`, so losing it parks
    /// the server run forever with no modal and no way to answer — the UI keeps
    /// animating "thinking…", indistinguishable from a slow model. It used to be lost
    /// permanently by two doors: a thrown transport error (swallowed by an empty
    /// `catch`) and a clean end-of-body (which fell out of the `for await` and was not
    /// an error at all). Both now land in the same reconnect loop, and the reconnect
    /// re-runs the `connected` reconcile, which recovers any prompt asked while the
    /// client was away.
    private func attachEvents(_ sessionID: String) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            var backoffMS = 125
            var isReconnect = false
            // When the CURRENT outage began, or nil while the stream is up. The
            // escalation below is a statement about elapsed time, so it has to be
            // measured in elapsed time.
            var outageStartedAt: Date?
            // The thrown value, not just its description: a 404 here is a
            // different DIAGNOSIS from every other failure and gets a different
            // repair (see below), and `lastStreamError` has already flattened it
            // to prose by then.
            var lastFailure: (any Error)?
            while !Task.isCancelled {
                guard let self, self.store.selectedSessionID == sessionID else { return }
                lastFailure = nil
                do {
                    for try await event in self.client.events(sessionID: sessionID) {
                        guard self.store.selectedSessionID == sessionID else { return }
                        if case .connected = event {
                            // Reconcile pending prompts only AFTER the SSE is live (the
                            // server sends `connected` first). Doing the GET before
                            // subscribing would lose a prompt asked in the gap.
                            backoffMS = 125
                            self.lastStreamError = nil
                            // Armed again: the NEXT outage gets its own row. An
                            // outage that recovered is a different event from the
                            // one that follows it.
                            self.reportedStreamFailure = false
                            outageStartedAt = nil
                            self.setStreamConnected(true)
                            // Re-seed after an OUTAGE: the stream is delta-only, so
                            // everything that streamed while we were away is simply
                            // missing from the pane, with nothing to say so. Not on the
                            // first connect — `open()` has just fetched the same
                            // history, and re-seeding a mid-turn attach would discard
                            // partial streamed text. Before `apply`, because `seed`
                            // clears the transcript (and the run state with it), which
                            // would wipe the `running` this very frame carries.
                            if isReconnect {
                                do {
                                    let history = try await self.client.messages(sessionID: sessionID)
                                    guard self.store.selectedSessionID == sessionID else { return }
                                    self.store.seed(history)
                                } catch {
                                    // The pane keeps what it has; what it is missing
                                    // is whatever streamed while we were away. A
                                    // transient notice, because nothing the user
                                    // typed was lost and the next reconnect retries.
                                    self.post(notice: "history refresh failed — the pane may be missing what streamed while you were away")
                                }
                            }
                            isReconnect = false
                            self.store.apply(event)
                            await self.reconcilePendingPermissions(sessionID)
                            continue
                        }
                        self.store.apply(event)
                        if case .permissionRequest = event {
                            await self.refreshToolCatalog(sessionID: sessionID)
                        } else if case .permissionResolved = event {
                            await self.refreshToolCatalog(sessionID: sessionID)
                        }
                    }
                } catch {
                    // Fall through to the same retry as a clean end — but KEEP the
                    // reason. A thrown transport error and a clean end-of-body are
                    // the same recovery and very different diagnoses, and the
                    // status line can only say which if this records it.
                    self.lastStreamError = Self.describe(error)
                    lastFailure = error
                }
                guard !Task.isCancelled, self.store.selectedSessionID == sessionID else { return }
                // The stream is down. Say so — a silent disconnect is exactly what made
                // this look like a freeze — then retry with bounded backoff.
                self.setStreamConnected(false)
                let outageStart = outageStartedAt ?? Date()
                outageStartedAt = outageStart
                // Escalate from the status line to a persistent row ONCE the outage
                // has genuinely lasted a while, so scrolling away from a spinner no
                // longer hides the fact that nothing is connected.
                //
                // Measured against the CLOCK, not against the backoff counter. The
                // counter only tracks elapsed time if each failed attempt returns
                // instantly, and the case that matters most — a runtime whose port is
                // gone — costs about ten seconds per attempt to surface ECONNREFUSED.
                // Six of those put the row nearly a minute after the outage, long past
                // the point the user has decided the client is broken.
                if Date().timeIntervalSince(outageStart) >= Self.streamOutageNoticeDelay,
                   !self.reportedStreamFailure {
                    self.reportedStreamFailure = true
                    self.postError(
                        "Lost the connection to the runtime",
                        reason: self.lastStreamError ?? "the event stream ended without an error",
                        hint: "Reconnecting automatically; nothing you typed was lost."
                    )
                }
                // A 404 on the event stream means one specific thing: the runtime
                // does not have this session LIVE. That is not a network problem
                // and reconnecting forever will never fix it — the resume is what
                // fixes it, and until this existed nothing ever tried the resume a
                // second time, so a session that failed to open at startup stayed
                // permanently inert with every endpoint 404ing.
                if let failure = lastFailure,
                   case ServerClientError.unexpectedStatus(404, _, _) = failure {
                    await self.reviveSession(sessionID)
                }
                isReconnect = true
                try? await Task.sleep(for: .milliseconds(backoffMS))
                backoffMS = min(backoffMS * 2, 4000)
            }
        }
    }

    /// Try to make a session live again after the runtime said it does not have it.
    ///
    /// `createSession(resume:)` is idempotent and cheap, and it is the ONLY thing
    /// that turns a 404-ing session back into a working one. Silent on failure —
    /// the reconnect loop is already saying, once, that the connection is down, and
    /// this runs on every backoff tick.
    private func reviveSession(_ sessionID: String) async {
        guard let ref = try? await client.createSession(resume: sessionID),
              store.selectedSessionID == sessionID
        else { return }
        store.setSessionPath(ref.path)
        post(notice: "the session is live again")
    }

    /// Record the stream's health for the status line, repainting on a change.
    private func setStreamConnected(_ connected: Bool) {
        guard streamConnected != connected else { return }
        streamConnected = connected
        surface?.requestRender()
    }

    /// Fetch and fold any still-open prompts for `sessionID` (a prompt the client
    /// missed on the drop-oldest SSE stream, or one left over on reconnect). The store
    /// drops events for the wrong session and already-resolved ids, so this is safe.
    private func reconcilePendingPermissions(_ sessionID: String) async {
        guard store.selectedSessionID == sessionID else { return }
        let pending: [ServerEvent]
        do {
            pending = try await client.pendingPermissions(sessionID: sessionID)
        } catch {
            // A parked run stays unanswerable until the next reconnect retries
            // this, so the user has to know the modal they are waiting for may
            // never arrive. Transient: the retry is automatic and close.
            post(notice: "could not check for pending approvals")
            return
        }
        guard store.selectedSessionID == sessionID else { return }
        for event in pending { store.apply(event) }
    }

    /// Fetch and fold any still-open structured questions for `sessionID`, using
    /// the same level-triggered recovery as permission prompts. A question is a
    /// parked tool call, so silently missing this request would leave the run
    /// waiting forever with no visible affordance.
    private func reconcilePendingQuestions(_ sessionID: String) async {
        guard store.selectedSessionID == sessionID else { return }
        let pending: [ServerEvent]
        do {
            pending = try await client.pendingQuestions(sessionID: sessionID)
        } catch {
            post(notice: "could not check for pending questions")
            return
        }
        guard store.selectedSessionID == sessionID else { return }
        for event in pending { store.apply(event) }
    }

    // MARK: Dialogs and pickers

    /// Remove an application dialog through the shared stack so focus ownership
    /// and the stack's LIFO bookkeeping stay in sync. The fallback keeps the
    /// helper safe during teardown, when the surface may already be gone.
    private func dismissDialog(_ handle: ScreenOverlayHandle?) {
        guard let handle else { return }
        if let dialogs {
            dialogs.dismiss(handle)
        } else {
            handle.hide()
        }
    }

    private func overlayOptions(width: Int = 70, height: Int? = nil) -> OverlayOptions {
        OverlayOptions(
            width: .absolute(min(width, max(30, surface?.target.columns ?? width))),
            minWidth: 20,
            maxHeight: height.map { .absolute($0) },
            anchor: .center
        )
    }

    private func reconcileAutocomplete(_ suggestions: AutocompleteSuggestions?) {
        dismissDialog(autocompleteHandle)
        autocompleteHandle = nil
        autocompleteDialog = nil
        guard let suggestions, !suggestions.items.isEmpty else { return }
        let items = suggestions.items.map {
            SelectItem(value: $0.value, label: $0.label, description: $0.description)
        }
        let dialog = SearchableSelectDialog(title: "Complete", items: items, keybindings: keybindings)
        dialog.onCancel = { [weak self] in self?.dismissAutocomplete() }
        dialog.onSelect = { [weak self] item in
            guard let self,
                  let selected = suggestions.items.first(where: { $0.value == item.value })
            else { return }
            self.promptInput.applyAutocomplete(selected, prefix: suggestions.prefix)
            self.dismissAutocomplete()
        }
        autocompleteDialog = dialog
        autocompleteHandle = dialogs?.present(dialog, options: overlayOptions(width: 76, height: 16))
    }

    private func dismissAutocomplete() {
        dismissDialog(autocompleteHandle)
        autocompleteHandle = nil
        autocompleteDialog = nil
        promptInput.dismissAutocomplete()
    }

    private func openPalette() {
        if paletteHandle != nil { dismissPalette(); return }
        let items = [
            SelectItem(value: "session", label: "Open session", description: "Search and switch sessions"),
            SelectItem(value: "rename", label: "Rename session", description: "Persist a display name"),
            SelectItem(value: "title", label: "Auto-title session", description: "Ask the active model for a short name"),
            SelectItem(value: "model", label: "Switch model", description: "Write a model_change entry"),
            SelectItem(value: "mode", label: "Toggle build/plan mode", description: "Tab also toggles the active policy"),
            SelectItem(value: "tree", label: "Browse conversation tree", description: "Search, fold, and branch"),
            SelectItem(value: "timeline", label: "Show session timeline", description: "Inspect checkpoints and history moves"),
            SelectItem(value: "undo", label: "Undo conversation and workspace", description: "Restore the previous checkpoint"),
            SelectItem(value: "redo", label: "Redo conversation and workspace", description: "Reapply the most recent undo"),
            SelectItem(value: "fork", label: "Fork session", description: "Open a new session from this branch"),
            SelectItem(value: "clone", label: "Clone session", description: "Open an independent copy of this branch"),
            SelectItem(value: "diff", label: "Review working-tree diff", description: "Inspect changes since the session started"),
            SelectItem(value: "review", label: "Review diff (guided)", description: "Mark files reviewed and restore individual paths"),
            SelectItem(value: "theme-dark", label: "Theme: dark", description: "Use the dark palette"),
            SelectItem(value: "theme-light", label: "Theme: light", description: "Use the light palette"),
            SelectItem(value: "edit-dialog", label: "Edit prompt in dialog", description: "Edit the draft inside the client"),
            SelectItem(value: "edit", label: "Edit prompt in $EDITOR", description: "Hand the draft to the external editor"),
        ]
        let dialog = SearchableSelectDialog(title: "Command palette", items: items, keybindings: keybindings)
        dialog.onCancel = { [weak self] in self?.dismissPalette() }
        dialog.onSelect = { [weak self] item in
            guard let self else { return }
            self.dismissPalette()
            self.activatePalette(item.value)
        }
        paletteDialog = dialog
        paletteHandle = dialogs?.present(dialog, options: overlayOptions(width: 82, height: 15))
    }

    private func dismissPalette() {
        dismissDialog(paletteHandle)
        paletteHandle = nil
        paletteDialog = nil
    }

    /// Fetch and show the runtime's current tool projection. The endpoint is
    /// intentionally resolved on demand so a mode/model change or an MCP
    /// `tools/list_changed` refresh cannot leave this view advertising stale
    /// model capabilities.
    private func openToolCatalog() {
        if toolCatalogHandle != nil {
            dismissToolCatalog()
            return
        }
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        dismissAutocomplete()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.client.toolCatalog(sessionID: id)
                guard self.store.selectedSessionID == id else { return }
                let items = entries.map(Self.toolCatalogItem)
                guard !items.isEmpty else {
                    self.post(notice: "the runtime has no registered tools")
                    return
                }
                let dialog = SearchableSelectDialog(
                    title: "Tool catalog (\(entries.count))",
                    items: items,
                    keybindings: self.keybindings
                )
                dialog.onCancel = { [weak self] in self?.dismissToolCatalog() }
                dialog.onSelect = { [weak self] item in
                    self?.dismissToolCatalog()
                    self?.post(notice: item.description ?? item.value, seconds: 8)
                }
                self.toolCatalogDialog = dialog
                self.toolCatalogHandle = self.dialogs?.present(
                    dialog,
                    options: self.overlayOptions(width: 110, height: 22)
                )
                self.startToolCatalogRefresh(for: id)
            } catch {
                self.postError("Could not load the tool catalog", error)
            }
        }
        actionTasks.append(task)
    }

    private func dismissToolCatalog() {
        toolCatalogRefreshTask?.cancel()
        toolCatalogRefreshTask = nil
        dismissDialog(toolCatalogHandle)
        toolCatalogHandle = nil
        toolCatalogDialog = nil
    }

    /// Keep an open catalog aligned with the runtime's late-bound tool resolver.
    /// The route is intentionally polled while the dialog is visible: local MCP
    /// list-changed notifications stay inside the MCP manager, while mode/model
    /// and permission changes arrive through separate server paths. A short,
    /// bounded poll gives all three paths one client-side refresh contract without
    /// advertising a tool during the next request that the runtime has already
    /// removed.
    private func startToolCatalogRefresh(for sessionID: String) {
        toolCatalogRefreshTask?.cancel()
        toolCatalogRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self,
                      self.toolCatalogHandle != nil,
                      self.store.selectedSessionID == sessionID
                else { return }
                await self.refreshToolCatalog(sessionID: sessionID)
            }
        }
    }

    private func refreshToolCatalog(sessionID: String) async {
        guard toolCatalogHandle != nil, store.selectedSessionID == sessionID else { return }
        do {
            let entries = try await client.toolCatalog(sessionID: sessionID)
            guard store.selectedSessionID == sessionID, let dialog = toolCatalogDialog else { return }
            dialog.update(
                title: "Tool catalog (\(entries.count))",
                items: entries.map(Self.toolCatalogItem)
            )
            surface?.requestRender()
        } catch {
            // An open catalog is an inspection surface, not a run. Keep its last
            // known projection visible and avoid turning a transient poll failure
            // into a noisy transcript row.
        }
    }

    private static func toolCatalogItem(_ entry: ToolCatalogEntry) -> SelectItem {
        let description = sanitizeUntrustedText(collapseToOneLine(entry.description ?? ""))
        let source = entry.source.rawValue
        let permission = entry.permission.rawValue
        let schema = entry.metadata["schemaSummary"]?.stringValue ?? "schema"
        var details = "\(source) · \(permission) · schema: \(schema)"
        if let hiddenReason = entry.hiddenReason {
            details += " · hidden: \(hiddenReason)"
        }
        let rowDescription = description.isEmpty ? details : "\(description) · \(details)"
        return SelectItem(
            value: entry.name,
            label: sanitizeUntrustedText(entry.name),
            description: sanitizeUntrustedText(rowDescription)
        )
    }

    private func activatePalette(_ value: String) {
        switch value {
        case "session": openSessionPicker()
        case "rename": openRenameDialog()
        case "title": autoTitleSession()
        case "model": openModelPicker()
        case "mode": toggleAgentMode()
        case "tools": openToolCatalog()
        case "tree": openTreePicker()
        case "timeline": showTimeline()
        case "undo": moveWorkspaceHistory(.undo)
        case "redo": moveWorkspaceHistory(.redo)
        case "fork": forkSession(clone: false)
        case "clone": forkSession(clone: true)
        case "diff": openDiffReview(advisory: false)
        case "review": openDiffReview(advisory: true)
        case "theme-dark": setAppearance(.dark)
        case "theme-light": setAppearance(.light)
        case "edit-dialog": openPromptEditorDialog()
        case "edit": editPromptInEditor()
        default: break
        }
    }

    private func openSessionPicker() {
        if sessionPickerHandle != nil { dismissSessionPicker(); return }
        let items = sessionPickerItems()
        guard !items.isEmpty else { post(notice: "no sessions to open"); return }
        let dialog = SearchableSelectDialog(title: "Open session", items: items, keybindings: keybindings)
        dialog.onCancel = { [weak self] in self?.dismissSessionPicker() }
        dialog.onSelect = { [weak self] item in
            self?.dismissSessionPicker()
            self?.openSession(item.value)
        }
        sessionPickerDialog = dialog
        sessionPickerHandle = dialogs?.present(dialog, options: overlayOptions(width: 82, height: 18))
    }

    private func sessionPickerItems() -> [SelectItem] {
        store.sessions.map { session in
            let title = session.name ?? session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
            return SelectItem(
                value: session.id,
                label: sanitizeUntrustedText(title),
                description: sanitizeUntrustedText(session.cwd)
            )
        }
    }

    private func refreshSessionPicker() {
        guard let sessionPickerDialog else { return }
        sessionPickerDialog.updateItems(sessionPickerItems())
    }

    private func dismissSessionPicker() {
        dismissDialog(sessionPickerHandle)
        sessionPickerHandle = nil
        sessionPickerDialog = nil
    }

    private func openModelPicker() {
        guard store.selectedSessionID != nil else { post(notice: "no session is open"); return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let models = try await self.client.models()
                guard !models.isEmpty else { self.post(notice: "the runtime has no model aliases"); return }
                let items = models.map {
                    SelectItem(value: $0.id, label: $0.id, description: $0.contextWindow.map { "window \($0) tokens" })
                }
                let dialog = SearchableSelectDialog(title: "Switch model", items: items, keybindings: self.keybindings)
                dialog.onCancel = { [weak self] in self?.dismissModelPicker() }
                dialog.onSelect = { [weak self] item in
                    self?.dismissModelPicker()
                    self?.selectModel(item.value)
                }
                self.modelPickerDialog = dialog
                self.modelPickerHandle = self.dialogs?.present(dialog, options: self.overlayOptions(width: 82, height: 18))
            } catch {
                self.postError("Could not load models", error)
            }
        }
        actionTasks.append(task)
    }

    private func dismissModelPicker() {
        dismissDialog(modelPickerHandle)
        modelPickerHandle = nil
        modelPickerDialog = nil
    }

    private func selectModel(_ model: String) {
        guard let id = store.selectedSessionID else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.changeModel(sessionID: id, modelID: model)
                self.post(notice: "model selected: \(sanitizeUntrustedText(model))")
                self.store.markAccountingStale()
                await self.refreshToolCatalog(sessionID: id)
            } catch {
                self.postError("Could not change model", error)
            }
        }
        actionTasks.append(task)
    }

    /// Change the selected session's policy boundary. The runtime refuses a
    /// mid-turn switch, because changing the permission set under an active tool
    /// call would make one turn observe two different policies.
    private func toggleAgentMode() {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        let next: AgentMode = agentMode == .build ? .plan : .build
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.changeMode(sessionID: id, mode: next)
                guard self.store.selectedSessionID == id else { return }
                self.agentMode = next
                self.post(notice: "mode: \(next.rawValue)")
                self.surface?.requestRender()
                await self.refreshToolCatalog(sessionID: id)
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                self.refuseAsBusy()
                await self.reconcileWithServer(id)
            } catch {
                self.postError("Could not change mode", error)
            }
        }
        actionTasks.append(task)
    }

    private func openTreePicker() {
        guard let id = store.selectedSessionID else { post(notice: "no session is open"); return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.client.tree(sessionID: id)
                let items = self.treeDialogItems(entries)
                guard !items.isEmpty else { self.post(notice: "the conversation tree is empty"); return }
                let dialog = TreeDialog(title: "Conversation tree", items: items, keybindings: self.keybindings)
                dialog.onCancel = { [weak self] in self?.dismissTreePicker() }
                dialog.onSelect = { [weak self] item in
                    self?.dismissTreePicker()
                    self?.moveToTreeEntry(item.value)
                }
                dialog.onLabel = { [weak self] item in self?.openLabelDialog(for: item) }
                self.treePickerDialog = dialog
                self.treePickerHandle = self.dialogs?.present(dialog, options: self.overlayOptions(width: 92, height: 20))
            } catch {
                self.postError("Could not load the conversation tree", error)
            }
        }
        actionTasks.append(task)
    }

    private func showTimeline() {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.client.timeline(sessionID: id)
                guard self.store.selectedSessionID == id else { return }
                self.post(notice: Self.timelineNotice(entries), seconds: 8)
            } catch {
                self.postError("Could not load the session timeline", error)
            }
        }
        actionTasks.append(task)
    }

    /// Open the content-options dialog before copying the lossless server history.
    /// The visible transcript is a projection and may omit rows folded during
    /// reconnect, so `/copy` stays aligned with `domo export` rather than with
    /// the current viewport.
    private func openCopyOptionsDialog() {
        guard store.selectedSessionID != nil else {
            post(notice: "no session is open")
            return
        }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        let dialog = TranscriptOptionsDialog(keybindings: keybindings)
        dialog.onCancel = { [weak self] in self?.dismissCopyOptionsDialog() }
        dialog.onSubmit = { [weak self] options in
            self?.dismissCopyOptionsDialog()
            self?.copyTranscript(options: options)
        }
        copyOptionsDialog = dialog
        copyOptionsHandle = dialogs?.present(
            Box(dialog, paddingX: 1),
            options: overlayOptions(width: 68, height: 10)
        )
    }

    private func dismissCopyOptionsDialog() {
        dismissDialog(copyOptionsHandle)
        copyOptionsHandle = nil
        copyOptionsDialog = nil
    }

    private func copyTranscript(options: TranscriptFormatOptions) {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let messages = try await self.client.messages(sessionID: id)
                let text = TranscriptFormatter.markdown(messages: messages, options: options)
                guard !text.isEmpty else {
                    self.post(notice: "nothing to copy")
                    return
                }
                switch await self.clipboard.copy(text) {
                case .copied(let mechanism):
                    self.post(notice: "copied transcript as Markdown via \(mechanism)")
                case .unavailable:
                    self.post(notice: "clipboard unavailable; use domo export to write Markdown")
                case .failed(let reason):
                    self.post(notice: "clipboard: \(sanitizeUntrustedText(collapseToOneLine(reason)))")
                }
            } catch {
                self.postError("Could not copy the transcript", error)
            }
        }
        actionTasks.append(task)
    }

    private func moveWorkspaceHistory(_ operation: SessionHistoryOperation) {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: WorkspaceHistoryResult
                switch operation {
                case .undo: result = try await self.client.undo(sessionID: id)
                case .redo: result = try await self.client.redo(sessionID: id)
                }
                guard self.store.selectedSessionID == id else { return }
                if let history = try? await self.client.messages(sessionID: id) {
                    guard self.store.selectedSessionID == id else { return }
                    self.store.seed(history)
                }
                await self.seedAccounting(id)
                await self.seedWorkspaceStatus(id)
                self.post(notice: Self.historyNotice(result), seconds: 8)
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                self.refuseAsBusy()
            } catch {
                self.postError("Could not move workspace history", error)
            }
        }
        actionTasks.append(task)
    }

    private func forkSession(clone: Bool) {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let ref: SessionRef
                if clone {
                    ref = try await self.client.clone(sessionID: id)
                } else {
                    ref = try await self.client.fork(sessionID: id)
                }
                self.store.setSessions(try await self.client.listSessions())
                await self.open(ref.id)
                self.post(notice: (clone ? "cloned" : "forked") + " session")
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                self.refuseAsBusy()
            } catch {
                self.postError(clone ? "Could not clone the session" : "Could not fork the session", error)
            }
        }
        actionTasks.append(task)
    }

    private func dismissTreePicker() {
        dismissDialog(treePickerHandle)
        treePickerHandle = nil
        treePickerDialog = nil
    }

    private func treeDialogItems(_ entries: [SessionTreeEntry]) -> [TreeDialogItem] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let children = Dictionary(grouping: entries, by: { $0.parentId })
        var labelsByTarget: [String: String] = [:]
        for entry in entries {
            guard case .label(let targetID, let value) = entry.payload else { continue }
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clean.isEmpty {
                labelsByTarget.removeValue(forKey: targetID)
            } else {
                labelsByTarget[targetID] = clean
            }
        }

        func depth(of entry: SessionTreeEntry) -> Int {
            var depth = 0
            var parent = entry.parentId
            var seen: Set<String> = []
            while let parentID = parent, seen.insert(parentID).inserted {
                depth += 1
                parent = byID[parentID]?.parentId
            }
            return min(depth, 32)
        }

        return entries.map { entry in
            let label: String
            let description: String
            let kind: TreeDialogItem.Kind
            switch entry.payload {
            case .message(let message):
                kind = .message
                switch message {
                case .user(let user): label = "user  \(collapseToOneLine(user.text))"
                case .assistant(let assistant): label = "assistant  \(collapseToOneLine(assistant.text))"
                case .tool(let tool): label = "tool  \(tool.toolName)"
                case .system: label = "system"
                }
                description = entry.id
            case .modelChange(let provider, let modelId):
                kind = .metadata
                label = "model  \(modelId)"
                description = provider
            case .branchSummary(let summary):
                kind = .branch
                label = "branch summary  \(collapseToOneLine(summary.summary))"
                description = entry.id
            case .compaction(let compaction):
                kind = .metadata
                label = "compaction  \(collapseToOneLine(compaction.summary))"
                description = entry.id
            case .label(let targetID, let value):
                kind = .label
                label = "label  \(value ?? "(cleared)")"
                description = targetID
            case .sessionInfo(let name):
                kind = .metadata
                label = "session  \(name ?? "(unnamed)")"
                description = entry.id
            case .sessionStart(let head):
                kind = .metadata
                label = "git  session start"
                description = head
            case .workspaceCheckpoint(let snapshot):
                kind = .metadata
                label = "workspace  checkpoint"
                description = String(snapshot.files.count) + " changed path(s)  " + snapshot.id
            case .historyAction(let action):
                kind = .branch
                label = "workspace  " + action.operation.rawValue
                description = action.status.rawValue + ", " + String(action.paths.count) + " path(s)"
            case .leaf(let targetID):
                kind = .branch
                label = "branch  \(targetID ?? "root")"
                description = entry.id
            case .subagent(let event):
                kind = .branch
                label = "subagent  \(event.status.rawValue)  \(collapseToOneLine(event.description))"
                description = event.childSessionID
            }
            let currentLabel = labelsByTarget[entry.id]
            let decoratedLabel = currentLabel.map { label + "  [" + $0 + "]" } ?? label
            return TreeDialogItem(
                value: entry.id,
                label: sanitizeUntrustedText(collapseToOneLine(decoratedLabel)),
                description: sanitizeUntrustedText(collapseToOneLine(description)),
                parentID: entry.parentId,
                depth: depth(of: entry),
                kind: kind,
                hasChildren: !(children[entry.id] ?? []).isEmpty,
                currentLabel: currentLabel.map(sanitizeUntrustedText)
            )
        }
    }

    private func openLabelDialog(for item: TreeDialogItem) {
        let dialog = DialogTextInput(title: "Label tree entry", initial: item.currentLabel ?? "")
        dialog.onCancel = { [weak self] in self?.dismissLabelDialog() }
        dialog.onSubmit = { [weak self] label in
            self?.dismissLabelDialog()
            self?.setLabel(label, targetID: item.value)
        }
        labelDialog = dialog
        labelHandle = dialogs?.present(dialog, options: overlayOptions(width: 72, height: 7))
    }

    private func dismissLabelDialog() {
        dismissDialog(labelHandle)
        labelHandle = nil
        labelDialog = nil
    }

    private func setLabel(_ label: String, targetID: String) {
        guard let id = store.selectedSessionID else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                try await self.client.label(
                    sessionID: id,
                    targetID: targetID,
                    label: clean.isEmpty ? nil : clean
                )
                self.post(notice: clean.isEmpty ? "label cleared" : "label saved")
                if self.treePickerHandle != nil {
                    self.dismissTreePicker()
                    self.openTreePicker()
                }
            } catch {
                self.postError("Could not save the label", error)
            }
        }
        actionTasks.append(task)
    }

    private func moveToTreeEntry(_ entryID: String) {
        guard let id = store.selectedSessionID else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.moveLeaf(sessionID: id, targetID: entryID)
                await self.open(id)
                self.post(notice: "moved to the selected branch")
            } catch {
                self.postError("Could not move to that branch", error)
            }
        }
        actionTasks.append(task)
    }

    private func openRenameDialog() {
        guard let current = store.sessions.first(where: { $0.id == store.selectedSessionID }) else {
            post(notice: "no session is open")
            return
        }
        let dialog = DialogForm(
            title: "Rename session",
            fields: [DialogFormField(label: "Name", value: current.name ?? "")],
            keybindings: keybindings
        )
        dialog.onCancel = { [weak self] in self?.dismissRenameDialog() }
        dialog.onSubmit = { [weak self] values in
            self?.dismissRenameDialog()
            self?.renameSession(values.first ?? "")
        }
        renameDialog = dialog
        renameHandle = dialogs?.present(dialog, options: overlayOptions(width: 72, height: 8))
    }

    private func dismissRenameDialog() {
        dismissDialog(renameHandle)
        renameHandle = nil
        renameDialog = nil
    }

    private func renameSession(_ name: String) {
        guard let id = store.selectedSessionID else { return }
        // An explicit rename, including an intentional clear, is the user's
        // decision about this session's title. Do not immediately replace it with
        // an automatic title after the next completed turn.
        automaticTitleAttemptedSessionIDs.insert(id)
        autoTitleTask?.cancel()
        autoTitleTask = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.renameSession(sessionID: id, name: name)
                self.store.setSessions(try await self.client.listSessions())
                self.post(notice: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "session name cleared" : "session renamed")
            } catch {
                self.postError("Could not rename the session", error)
            }
        }
        actionTasks.append(task)
    }

    private func autoTitleSession() {
        guard let id = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }
        guard autoTitleTask == nil else {
            post(notice: "automatic title is still being generated")
            return
        }
        automaticTitleAttemptedSessionIDs.insert(id)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let title = try await self.client.autoTitle(sessionID: id) else {
                    self.post(notice: "session already has a name or no messages")
                    return
                }
                self.store.setSessions(try await self.client.listSessions())
                self.post(notice: "session titled: \(sanitizeUntrustedText(title))")
            } catch {
                self.postError("Could not auto-title the session", error)
            }
        }
        actionTasks.append(task)
    }

    private func openPromptEditorDialog() {
        if draftEditorHandle != nil {
            dismissPromptEditorDialog()
            return
        }
        let dialog = DialogEditor(
            title: "Edit prompt",
            initial: promptInput.text,
            rows: { [weak self] in
                max(4, min(14, (self?.surface?.target.rows ?? 24) - 8))
            }
        )
        dialog.onCancel = { [weak self] in self?.dismissPromptEditorDialog() }
        dialog.onSubmit = { [weak self] text in
            guard let self else { return }
            self.dismissPromptEditorDialog()
            self.promptInput.setText(text)
            self.post(notice: "draft updated")
        }
        draftEditorDialog = dialog
        draftEditorHandle = dialogs?.present(dialog, options: overlayOptions(width: 92, height: 18))
    }

    private func dismissPromptEditorDialog() {
        dismissDialog(draftEditorHandle)
        draftEditorHandle = nil
        draftEditorDialog = nil
    }

    // MARK: Diff review

    /// Open the working-tree review surface for the selected session. The server
    /// remains the authority for the repository path and session checkpoint; the
    /// client only owns navigation marks and the destructive-action confirmation.
    private func openDiffReview(advisory: Bool) {
        if diffReviewHandle != nil {
            dismissDiffReview()
            return
        }
        guard let sessionID = store.selectedSessionID else {
            post(notice: "no session is open")
            return
        }

        let dialog = DiffReviewDialog()
        dialog.onClose = { [weak self] in self?.dismissDiffReview() }
        dialog.onRevert = { [weak self] path in self?.confirmDiffRevert(path: path) }
        dialog.onCommitMessage = { [weak self] in self?.requestCommitMessage() }
        diffReviewDialog = dialog
        diffReviewSessionID = sessionID
        guard let handle = dialogs?.present(
            dialog,
            options: overlayOptions(
                width: min(140, max(60, surface?.target.columns ?? 100)),
                height: max(10, (surface?.target.rows ?? 24) - 2)
            )
        ) else {
            diffReviewDialog = nil
            diffReviewSessionID = nil
            post(notice: "could not open the diff review")
            return
        }
        diffReviewHandle = handle

        let initial = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadDiffReview(sessionID: sessionID, reportFailure: true)
        }
        actionTasks.append(initial)

        diffRefreshTask?.cancel()
        diffRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self,
                      self.diffReviewHandle != nil,
                      self.diffReviewSessionID == sessionID
                else { return }
                await self.loadDiffReview(sessionID: sessionID, reportFailure: false)
            }
        }
        if advisory {
            post(notice: "review mode — mark files with r, restore with v", seconds: 6)
        }
    }

    private func loadDiffReview(sessionID: String, reportFailure: Bool) async {
        guard diffReviewSessionID == sessionID, diffReviewHandle != nil else { return }
        do {
            let diff = try await client.diff(sessionID: sessionID)
            guard diffReviewSessionID == sessionID, diffReviewHandle != nil else { return }
            diffReviewDialog?.update(diff: diff)
            surface?.requestRender()
        } catch {
            guard diffReviewSessionID == sessionID, diffReviewHandle != nil else { return }
            if reportFailure {
                postError("Could not load the working-tree diff", error)
            }
        }
    }

    private func dismissDiffReview() {
        diffRefreshTask?.cancel()
        diffRefreshTask = nil
        dismissDiffRevertConfirmation()
        dismissDialog(diffReviewHandle)
        diffReviewHandle = nil
        diffReviewDialog = nil
        diffReviewSessionID = nil
    }

    private func confirmDiffRevert(path: String) {
        guard let sessionID = diffReviewSessionID, diffReviewHandle != nil else { return }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        guard diffRevertHandle == nil else { return }
        let visiblePath = sanitizeUntrustedText(collapseToOneLine(path))
        let dialog = DialogConfirm(
            title: "Restore file?",
            message: "Discard the working-tree changes in \(visiblePath)?",
            confirmLabel: "Restore",
            cancelLabel: "Cancel",
            keybindings: keybindings
        )
        dialog.onCancel = { [weak self] in self?.dismissDiffRevertConfirmation() }
        dialog.onResult = { [weak self] confirmed in
            guard let self else { return }
            self.dismissDiffRevertConfirmation()
            guard confirmed else {
                self.post(notice: "restore cancelled")
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.client.restoreDiffFile(sessionID: sessionID, path: path)
                    guard self.diffReviewSessionID == sessionID else { return }
                    await self.loadDiffReview(sessionID: sessionID, reportFailure: true)
                    self.post(notice: "restored \(visiblePath)")
                } catch {
                    self.postError("Could not restore \(visiblePath)", error)
                }
            }
            self.actionTasks.append(task)
        }
        diffRevertDialog = dialog
        diffRevertHandle = dialogs?.present(dialog, options: overlayOptions(width: 82, height: 8))
        if diffRevertHandle == nil {
            diffRevertDialog = nil
            post(notice: "could not open the restore confirmation")
        }
    }

    private func dismissDiffRevertConfirmation() {
        dismissDialog(diffRevertHandle)
        diffRevertHandle = nil
        diffRevertDialog = nil
    }

    private func requestCommitMessage() {
        guard let sessionID = diffReviewSessionID, diffReviewHandle != nil else { return }
        guard store.runState != .running else {
            refuseAsBusy()
            return
        }
        diffReviewDialog?.showCommitMessage("generating…")
        surface?.requestRender()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let message = try await self.client.commitMessage(sessionID: sessionID)
                guard self.diffReviewSessionID == sessionID, self.diffReviewHandle != nil else { return }
                self.diffReviewDialog?.showCommitMessage(message ?? "no subject generated")
                self.surface?.requestRender()
            } catch {
                self.postError("Could not generate a commit subject", error)
            }
        }
        actionTasks.append(task)
    }

    private func setAppearance(_ value: ThemeAppearance) {
        appearance = value
        promptInput.applyTheme(theme, appearance: value, trueColor: graphicsCapabilities.trueColor)
        statusBar.applyTheme(theme, appearance: value, trueColor: graphicsCapabilities.trueColor)
        footerBar.applyTheme(theme, appearance: value, trueColor: graphicsCapabilities.trueColor)
        surface?.frameBackground = theme.palette(for: value).background
        surface?.frameBackgroundTrueColor = graphicsCapabilities.trueColor
        surface?.requestFullRedraw()
        post(notice: "theme: \(value.rawValue)")
    }

    /// Hand the current draft to `$VISUAL`/`$EDITOR` while restoring the terminal
    /// first. Re-entering the lifecycle and forcing a redraw makes this safe for
    /// both the alternate screen and terminals whose raw-mode state is strict.
    private func editPromptInEditor() {
        let editorName = ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
            ?? "vi"
        let parts = editorName.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = parts.first, !executable.isEmpty else { return }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-prompt-\(UUID().uuidString).txt")
        do {
            try Data(promptInput.text.utf8).write(to: temporary)
            lifecycle?.stop()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(parts.dropFirst()) + [temporary.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let updated = try? String(contentsOf: temporary, encoding: .utf8) {
                promptInput.setText(updated)
            }
            try? FileManager.default.removeItem(at: temporary)
            try lifecycle?.enter()
            surface?.requestFullRedraw()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? lifecycle?.enter()
            post(notice: "could not launch \(executable)")
        }
    }

    // MARK: Actions (called from the render actor via component callbacks)

    private func openSession(_ id: String) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.open(id)
        }
        actionTasks.append(task)
    }

    /// Refresh the sidebar's disk-backed session list without changing the
    /// selected transcript. Delegated children are born during a live parent run,
    /// so their creation is the natural moment to make them visible to a client
    /// that is already attached to that parent.
    private func refreshSessions() {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.store.setSessions(try await self.client.listSessions())
            } catch {
                // The lifecycle notice is still useful even if this optional
                // refresh races a runtime restart; the next open or reconnect
                // will refresh the same list again.
            }
        }
        actionTasks.append(task)
    }

    private func newSession() {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.createAndOpen()
        }
        actionTasks.append(task)
    }

    /// Mount the dedicated workflow root. The standard phase values are a neutral
    /// initial snapshot; later run events replace them through the controller's
    /// `setPhases` seam without changing navigation or layout.
    private func openWorkflow(startingAt phaseID: String? = nil) {
        if workflowWorkspace != nil {
            post(notice: "workflow workspace is already open")
            return
        }
        let workspace = WorkflowWorkspaceController(phases: Self.standardWorkflowPhases)
        workspace.onChange = { [weak self] in self?.surface?.requestRender() }
        workspace.onExit = { [weak self] in self?.closeWorkflow() }
        workspace.onApprove = { [weak self] in self?.resolveSelectedWorkflowApproval(decision: "approved") }
        workspace.onDeny = { [weak self] in self?.resolveSelectedWorkflowApproval(decision: "denied") }
        if let phaseID { workspace.selectPhase(id: phaseID) }
        workflowRunID = nil
        workflowApprovals = []
        workflowWorkspace = workspace
        focus.register(workspace)
        focus.setCurrent(workspace)
        startWorkflowRefresh(preferredPhaseID: phaseID)
        surface?.requestFullRedraw()
    }

    private func closeWorkflow() {
        guard let workspace = workflowWorkspace else { return }
        workflowWorkspace = nil
        workflowRefreshTask?.cancel()
        workflowRefreshTask = nil
        workflowRunID = nil
        workflowApprovals = []
        focus.unregister(workspace)
        focus.setCurrent(promptInput)
        surface?.requestFullRedraw()
    }

    /// Poll the level-triggered workflow projection while its dedicated root is
    /// mounted. The ordinary SSE stream is session-scoped, so treating this as a
    /// separate, bounded poll keeps workflow progress correct for remote servers
    /// and for runs that began before the client entered the workspace.
    private func startWorkflowRefresh(preferredPhaseID: String?) {
        workflowRefreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            var reportedUnavailable = false
            while !Task.isCancelled {
                guard let self, let workspace = self.workflowWorkspace else { return }
                do {
                    let definitions = try await self.client.workflowDefinitions()
                    if let definition = Self.workflowDefinition(
                        from: definitions,
                        preferredPhaseID: preferredPhaseID
                    ) {
                        let runs = try await self.client.workflowRuns(workflowID: definition.id)
                        let latest = runs.max { $0.updatedAt < $1.updatedAt }
                        if self.workflowRunID == nil { self.workflowRunID = latest?.id }
                        let selectedRun = self.workflowRunID.flatMap { runID in
                            runs.first(where: { $0.id == runID })
                        } ?? latest
                        let approvals: [WorkflowApprovalRequest]
                        if let selectedRun {
                            approvals = (try? await self.client.workflowApprovals(
                                workflowID: definition.id,
                                runID: selectedRun.id
                            )) ?? []
                        } else {
                            approvals = []
                        }
                        self.workflowApprovals = approvals
                        workspace.setPhases(Self.workflowPhases(
                            definition: definition,
                            run: selectedRun,
                            approvals: approvals
                        ))
                        if let preferredPhaseID { workspace.selectPhase(id: preferredPhaseID) }
                        self.surface?.requestRender()
                    }
                    reportedUnavailable = false
                } catch {
                    // A client can attach to an older server without workflow
                    // routes. Keep the immediately usable workspace and explain
                    // the missing live projection once, rather than replacing it
                    // with a blank pane or spamming the transcript.
                    if !reportedUnavailable {
                        self.post(notice: "workflow snapshot unavailable — showing the local phase layout")
                        reportedUnavailable = true
                    }
                }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
        workflowRefreshTask = task
        actionTasks.append(task)
    }

    private func resolveSelectedWorkflowApproval(decision: String) {
        guard let workspace = workflowWorkspace,
              let runID = workflowRunID,
              let phaseID = workspace.selectedPhase?.id,
              let approval = workflowApprovals.first(where: { $0.stage.id == phaseID })
        else {
            post(notice: "no pending approval for the selected stage")
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolveWorkflowApproval(
                    workflowID: approval.workflowID,
                    runID: runID,
                    stageID: approval.stage.id,
                    decision: decision,
                    reason: decision == "denied" ? "Denied from the workflow workspace." : nil
                )
                self.workflowApprovals.removeAll { $0.stage.id == approval.stage.id }
                self.surface?.requestRender()
            } catch {
                self.postError("Could not resolve workflow approval", error)
            }
        }
        actionTasks.append(task)
    }

    /// Admit a workflow from a slash-command argument. The workflow workspace is
    /// mounted before the request so a slow server still gives the user the
    /// phase/agent surface immediately; the durable run then replaces the local
    /// placeholders on the next bounded snapshot poll.
    private func startWorkflowFromCommand(
        prompt: String,
        preferredPhaseID: String?
    ) {
        guard let sessionID = store.selectedSessionID else {
            post(notice: "open a session before starting a workflow")
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let definitions = try await self.client.workflowDefinitions()
                guard let definition = Self.workflowDefinition(
                    from: definitions,
                    preferredPhaseID: preferredPhaseID
                ) else {
                    self.post(notice: "this server has no workflow definitions")
                    return
                }
                let run = try await self.client.startWorkflow(
                    workflowID: definition.id,
                    sessionID: sessionID,
                    input: .string(prompt)
                )
                guard self.workflowWorkspace != nil else { return }
                self.workflowRunID = run.id
                self.surface?.requestRender()
            } catch {
                self.postError("Could not start workflow", error)
            }
        }
        actionTasks.append(task)
    }

    private static func workflowDefinition(
        from definitions: [WorkflowDefinition],
        preferredPhaseID: String?
    ) -> WorkflowDefinition? {
        guard !definitions.isEmpty else { return nil }
        if let preferredPhaseID,
           let match = definitions.first(where: { definition in
               definition.stages.contains { $0.id.caseInsensitiveCompare(preferredPhaseID) == .orderedSame }
           }) {
            return match
        }
        return definitions.first(where: { $0.id == WorkflowDefinition.standard.id }) ?? definitions[0]
    }

    private static func workflowPhases(
        definition: WorkflowDefinition,
        run: WorkflowRunRecord?,
        approvals: [WorkflowApprovalRequest] = []
    ) -> [WorkflowWorkspacePhase] {
        definition.stages.map { stage in
            let stageRun = run?.stage(withID: stage.id)
            let agentIDs = stageRun?.agentIDs.isEmpty == false
                ? stageRun?.agentIDs ?? []
                : [stage.id + "-agent"]
            let output = stageRun.map(workflowOutputText) ?? ""
            let error = stageRun?.error.map { "\n\nerror: \($0)" } ?? ""
            let content = output + error
            let agents = agentIDs.map { agentID in
                WorkflowWorkspaceAgent(
                    id: agentID,
                    title: agentID,
                    status: stageRun?.status ?? .pending,
                    content: content
                )
            }
            var summary = "tool policy: \(stage.toolPolicy.mode.rawValue)"
            if let profile = stage.profile { summary += " · profile: \(profile)" }
            if let artifact = stage.outputArtifact { summary += " · artifact: \(artifact)" }
            if !stage.dependencies.isEmpty {
                summary += " · after: " + stage.dependencies.joined(separator: ", ")
            }
            if approvals.contains(where: { $0.stage.id == stage.id }) {
                summary += " · approval required"
            }
            return WorkflowWorkspacePhase(
                id: stage.id,
                title: stage.displayName,
                status: stageRun?.status ?? .pending,
                summary: summary,
                agents: agents
            )
        }
    }

    private static func workflowOutputText(_ stage: WorkflowStageRunRecord) -> String {
        guard stage.output != .null else {
            return stage.metadata["progress"]?.stringValue ?? ""
        }
        if let string = stage.output.stringValue { return string }
        guard let data = try? JSONEncoder().encode(stage.output) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let standardWorkflowPhases: [WorkflowWorkspacePhase] = [
        WorkflowWorkspacePhase(
            id: "research",
            title: "Research",
            summary: "Read-only evidence gathering and source provenance.",
            agents: [WorkflowWorkspaceAgent(id: "research-agent", title: "research", content: "")]
        ),
        WorkflowWorkspacePhase(
            id: "plan",
            title: "Plan",
            summary: "Turn the collected evidence into a reviewable implementation plan.",
            agents: [WorkflowWorkspaceAgent(id: "plan-agent", title: "plan", content: "")]
        ),
        WorkflowWorkspacePhase(
            id: "execute",
            title: "Execute",
            summary: "Apply approved work with the session's permission and sandbox policy.",
            agents: [WorkflowWorkspaceAgent(id: "execute-agent", title: "execute", content: "")]
        ),
        WorkflowWorkspacePhase(
            id: "synthesize",
            title: "Synthesize",
            summary: "Collect outcomes, evidence, and unresolved follow-up items.",
            agents: [WorkflowWorkspaceAgent(id: "synthesize-agent", title: "synthesize", content: "")]
        ),
    ]

    /// Send a prompt — and never destroy it silently.
    ///
    /// `PromptInput` clears its text BEFORE calling this, so the typed string survives
    /// only as this argument. It used to be handed to a detached `try?`, so a refusal
    /// (the server now queues it through `/steer` when a run is active) erased the
    /// user's message with no message, no retry and no trace. The transport chooses
    /// the queue or normal prompt route and retries the opposite route once when the
    /// run state changes during that request; failures still restore the exact input.
    private func submit(_ text: String, _ attachments: [PromptAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commandName = Self.commandName(in: trimmed),
           let descriptor = commandRegistry.command(named: commandName),
           let action = descriptor.action {
            switch action {
            case .clear:
                guard store.runState != .running else {
                    promptInput.restore(text, attachments: attachments)
                    refuseAsBusy()
                    return
                }
                store.seed([])
                transcriptView.scrollToBottom()
                post(notice: "transcript cleared")
            case .clone:
                forkSession(clone: true)
            case .exit:
                quit.quit()
            case .fork:
                forkSession(clone: false)
            case .help:
                let names = commandRegistry.commands.map { "/\($0.name)" }.joined(separator: " · ")
                post(notice: names, seconds: 8)
            case .tools:
                openToolCatalog()
            case .memory:
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        self.post(notice: Self.memoryNotice(try await self.client.memory()), seconds: 8)
                    } catch {
                        self.postError("Could not load durable project memory", error)
                    }
                }
                actionTasks.append(task)
            case .tree:
                openTreePicker()
            case .timeline:
                showTimeline()
            case .copy:
                openCopyOptionsDialog()
            case .undo:
                moveWorkspaceHistory(.undo)
            case .redo:
                moveWorkspaceHistory(.redo)
            case .diff:
                openDiffReview(advisory: false)
            case .review:
                openDiffReview(advisory: true)
            case .workflow:
                let phase = ["research", "plan", "execute", "synthesize"].contains(commandName.lowercased())
                    ? commandName.lowercased()
                    : nil
                openWorkflow(startingAt: phase)
                let argument = Self.commandArguments(in: trimmed)
                if !argument.isEmpty {
                    guard attachments.isEmpty else {
                        promptInput.restore(text, attachments: attachments)
                        post(notice: "workflow commands currently accept text only")
                        return
                    }
                    startWorkflowFromCommand(prompt: argument, preferredPhaseID: phase)
                }
            case .compact:
                guard let id = store.selectedSessionID else {
                    post(notice: "no session is open")
                    return
                }
                guard store.runState != .running else {
                    refuseAsBusy()
                    return
                }
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let compacted = try await self.client.compact(sessionID: id)
                        guard self.store.selectedSessionID == id else { return }
                        // Compaction is a metadata checkpoint, so it does not
                        // emit a transcript event. Refresh the lossless pane and
                        // the cumulative meter explicitly after the REST write.
                        if let history = try? await self.client.messages(sessionID: id) {
                            guard self.store.selectedSessionID == id else { return }
                            self.store.seed(history)
                        }
                        await self.seedAccounting(id)
                        self.post(
                            notice: compacted
                                ? "context compacted"
                                : "nothing to compact in the current context"
                        )
                    } catch ServerClientError.unexpectedStatus(409, _, _) {
                        self.refuseAsBusy()
                    } catch {
                        self.postError("Could not compact the context", error)
                    }
                }
                actionTasks.append(task)
            case .context:
                guard let id = store.selectedSessionID else {
                    post(notice: "no session is open")
                    return
                }
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let snapshot = try await self.client.context(sessionID: id)
                        guard self.store.selectedSessionID == id else { return }
                        self.post(notice: Self.contextNotice(snapshot), seconds: 8)
                    } catch {
                        self.postError("Could not inspect the context", error)
                    }
                }
                actionTasks.append(task)
            }
            return
        }
        guard let id = store.selectedSessionID else {
            promptInput.restore(text, attachments: attachments)
            post(notice: "no session is open")
            return
        }
        // The client's view of run state is racy against the server's. The transport
        // uses this as a fast path only; it retries the opposite route once when the
        // server says the run changed state between the snapshot and the request.
        let preferSteer = store.runState == .running
        // Sending snaps the transcript back to the tail: a user who scrolled up to
        // re-read something and then asks a question must see the answer, not stay
        // parked in the history while the reply streams in off-screen.
        transcriptView.scrollToBottom()
        // The bytes are already in hand — they were read at drop time, off the main
        // actor — so this is a pure send with no IO of its own and nothing that can
        // fail for a reason the prompt is not about.
        let images = attachments.map(\.image)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendPromptOrSteer(
                    sessionID: id,
                    prompt: text,
                    images: images,
                    preferSteer: preferSteer
                )
            } catch ServerClientError.unexpectedStatus(413, _, _) {
                // The body was refused as too large. Everything is put back —
                // including the chips, which is the whole point: a 413 that
                // restored the text and dropped the images would leave the user
                // re-sending a message that is silently missing its attachment.
                self.promptInput.restore(text, attachments: attachments)
                self.post(notice: "attachments too large — the message was put back")
                self.postError(
                    "The server refused the message as too large",
                    reason: "HTTP 413 — the prompt and its \(images.count) attachment\(images.count == 1 ? "" : "s") exceed the server's body limit",
                    hint: "Remove an image (Backspace on an empty prompt) or send a smaller one. Your text and chips were put back."
                )
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                // Both routes rejected the prompt with a conflict, so neither an
                // enqueue nor a new run was accepted. No transcript row — a red
                // block for a short race is noise.
                self.promptInput.restore(text, attachments: attachments)
                self.refuseAsBusy()
                // The refusal is only trustworthy if the run it names is real. A
                // 409 from a run that can never settle is exactly the wedge, and
                // asking the server here is what turns the SECOND press of Enter
                // into the thing that either clears the state or proves it is real.
                await self.reconcileWithServer(id)
            } catch {
                self.promptInput.restore(text, attachments: attachments)
                self.post(notice: "could not send — the message was put back")
                // The notice says the text is safe; the row says WHY it did not
                // send, which is the part that survives long enough to act on.
                self.postError(
                    "Could not send the message",
                    error,
                    hint: "Your text was put back in the prompt."
                )
            }
        }
        actionTasks.append(task)
    }

    private static func commandName(in input: String) -> String? {
        guard input.first == "/" else { return nil }
        let rest = input.dropFirst()
        guard let first = rest.first, !first.isWhitespace else { return nil }
        let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let name = String(rest[..<end])
        return name.isEmpty ? nil : name
    }

    private static func commandArguments(in input: String) -> String {
        guard let name = commandName(in: input) else { return "" }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/" + name
        guard trimmed.count > prefix.count else { return "" }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timelineNotice(_ entries: [SessionTreeEntry]) -> String {
        let tail = entries.suffix(6).map { entry in
            entry.entryType.rawValue + "#" + String(entry.id.prefix(8))
        }.joined(separator: " · ")
        return "timeline: " + String(entries.count) + " entries" + (tail.isEmpty ? "" : " · " + tail)
    }

    private static func memoryNotice(_ records: [ProjectMemoryRecord]) -> String {
        guard !records.isEmpty else { return "memory: no durable project memory" }
        let shown = records.prefix(8).map { record in
            let body = sanitizeUntrustedText(
                SessionRecallIndex.elideMiddle(record.content, limit: 160)
                    .replacingOccurrences(of: "\n", with: " ")
            )
            return "\(record.kind.rawValue): \(sanitizeUntrustedText(record.title)) — \(body)"
        }
        let suffix = records.count > 8 ? " · \(records.count - 8) more" : ""
        return "memory: " + shown.joined(separator: " · ") + suffix
    }

    private static func historyNotice(_ result: WorkspaceHistoryResult) -> String {
        var notice = result.operation.rawValue + ": "
            + (result.moved ? "moved" : "no change")
            + " · " + result.status.rawValue
        if !result.restoredPaths.isEmpty {
            notice += " · restored " + String(result.restoredPaths.count)
        }
        if !result.skippedPaths.isEmpty {
            notice += " · skipped " + String(result.skippedPaths.count)
        }
        if !result.failedPaths.isEmpty {
            notice += " · failed " + String(result.failedPaths.count)
        }
        return notice
    }

    /// A bounded, useful `/context` acknowledgement. The full message bodies
    /// remain available from the REST response, but putting them in a transient
    /// status line would make a context-inspection command unusable in a TUI.
    private static func contextNotice(_ snapshot: ContextSnapshot) -> String {
        var users = 0
        var assistants = 0
        var tools = 0
        var systems = 0
        for message in snapshot.messages {
            switch message {
            case .system: systems += 1
            case .user: users += 1
            case .assistant: assistants += 1
            case .tool: tools += 1
            }
        }
        var result = "context: \(snapshot.messages.count) messages (system \(systems), user \(users), assistant \(assistants), tool \(tools))"
        if let accounting = snapshot.accounting {
            result += " · \(FooterRow.formatContext(accounting))"
        } else {
            result += " · accounting unavailable"
        }
        return result
    }

    /// Refuse a prompt because a turn is already in flight — and make the refusal
    /// itself a repair.
    ///
    /// "a turn is already running" was true and useless: it named no way out, and
    /// in the wedged case it was not even true, because the run it named could
    /// never finish. So the message names BOTH exits, and pressing Enter forces the
    /// authoritative poll on the very next tick — meaning a user hammering the key
    /// in frustration is, without knowing it, doing the exact thing that unsticks a
    /// client whose run state is stale.
    private func refuseAsBusy() {
        post(notice: "a turn is already running — Esc aborts it · ^G shows why")
        lastStatusPollAt = .distantPast
    }

    private func abort() {
        // No `runState == .running` guard: the client's copy of that flag can be stale
        // (it is reset on every session selection), and aborting an idle session is a
        // harmless 200 — `ServerRuntime.abort` cancels a nil task and drains an empty
        // map. Refusing to try was how "Esc does nothing" happened.
        guard let id = store.selectedSessionID else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The server answers whether anything was actually in flight. `false`
                // means our own run state was stale — self-correct it, so the prompt
                // box stops refusing input, instead of leaving the user pressing a key
                // that appears to do nothing.
                if try await self.client.abort(sessionID: id) == false {
                    self.store.markIdle()
                    self.post(notice: "nothing to abort")
                }
            } catch {
                self.post(notice: "could not abort — the run may still be going")
                // A run the user asked to stop and could not is something they
                // have to decide about; that decision outlives four seconds.
                self.postError("Could not abort the run", error)
            }
        }
        actionTasks.append(task)
    }

    // MARK: Diagnostics (^G)

    /// The ^G panel's outer width.
    private static let diagnosticsOverlayWidth = 70

    /// Open or close the diagnostics panel.
    private func toggleDiagnostics() {
        if diagnosticsHandle != nil {
            dismissDiagnosticsOverlay()
        } else {
            presentDiagnosticsOverlay()
            fetchDiagnosticsStatus()
        }
    }

    /// Show the panel: what the client believes, what the server says, and the one
    /// lever that frees a session whose run can never settle.
    ///
    /// The whole point is that a user who wedges has something to LOOK at and
    /// something to PULL, instead of a spinner and a restart. It is reachable while
    /// a permission modal is up — see the branch order in ``handleInput(_:)`` —
    /// because "why is this parked" is exactly the question a modal provokes.
    private func presentDiagnosticsOverlay() {
        let items = [
            SelectItem(value: "close", label: "Close", description: nil),
            SelectItem(
                value: "force-clear",
                label: "Force-clear the run (frees the session, loses this turn)",
                description: nil
            ),
        ]
        let columns = surface?.target.columns ?? Self.diagnosticsOverlayWidth
        let width = min(Self.diagnosticsOverlayWidth, max(30, columns))

        let list = SelectList(items: items, maxVisible: items.count, keybindings: keybindings)
        let inner = Container()
        inner.addChild(Text("\u{1b}[1mConnection & run state\u{1b}[0m", wrap: false))
        // A LIVE component, not a snapshot: "last frame 4s ago" is the single most
        // useful row here and it would be a lie one second after it was drawn.
        // The overlay is re-rendered every frame, so a closure-backed component
        // simply keeps telling the truth for as long as the panel is open — and
        // it is handed the width the compositor is actually laying it out at,
        // rather than one captured when the panel opened.
        inner.addChild(DynamicLines { [weak self] width in self?.diagnosticsRows(width: width) ?? [] })
        inner.addChild(Spacer(lines: 1))
        inner.addChild(list)
        inner.addChild(Text(dim("↑/↓ choose · Enter · ^G or Esc closes"), wrap: false))

        let contentHeight = 1 + Self.diagnosticsRowCount + 1 + items.count + 1
        diagnosticsOverlaySize = surface.map { ($0.target.columns, $0.target.rows) }
        // The HANDLE is assigned FIRST and the list second, and the input branch
        // keys off the handle. The other order is a whole-keyboard trap: a nil
        // surface would leave a list with no overlay, and the input branch would
        // then swallow every key forever with nothing on screen to dismiss.
        diagnosticsHandle = dialogs?.present(
            Box(inner, paddingX: 1),
            options: OverlayOptions(
                width: .absolute(width),
                minWidth: 20,
                maxHeight: .absolute(contentHeight + 2),
                anchor: .center
            )
        )
        diagnosticsList = list
    }

    /// How many rows ``diagnosticsRows(width:)`` always produces, so the overlay's
    /// height budget and its content cannot drift apart.
    private static let diagnosticsRowCount = 9

    /// The panel's body. Every value is read fresh on each render.
    private func diagnosticsRows(width: Int) -> [String] {
        let quiet = Int(Date().timeIntervalSince(store.lastEventAt))
        func row(_ label: String, _ value: String) -> String {
            let padded = label.padding(toLength: min(22, max(1, width)), withPad: " ", startingAt: 0)
            return truncateToWidth(padded + " " + sanitizeUntrustedText(collapseToOneLine(value)), width)
        }
        let server: [String]
        if let status = diagnosticsStatus {
            server = [
                row("server running", status.running ? "yes" : "no"),
                row("server run started", status.runStartedAt ?? "—"),
                row("server prompts", status.pendingPermissionIDs.isEmpty
                    ? "none" : status.pendingPermissionIDs.joined(separator: ", ")),
                row("server subscribers", String(status.subscribers)),
            ]
        } else {
            let reason = diagnosticsStatusError ?? "checking…"
            server = [row("server", reason), row("", ""), row("", ""), row("", "")]
        }
        return [
            row("runtime", client.baseURL),
            row("stream", streamConnected ? "connected" : "reconnecting… \(lastStreamError ?? "")"),
            row("last frame", "\(quiet)s ago"),
            row("client run state", store.runState == .running
                ? "running" : "idle\(store.lastStopReason.map { " (\($0))" } ?? "")"),
            row("client prompt", store.pendingPermission?.id ?? "none"),
        ] + server
    }

    /// Ask the server for its half of the panel, once, when the panel opens.
    private func fetchDiagnosticsStatus() {
        diagnosticsStatus = nil
        diagnosticsStatusError = nil
        guard let id = store.selectedSessionID else {
            diagnosticsStatusError = "no session is open"
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.status(sessionID: id)
                guard self.store.selectedSessionID == id else { return }
                self.adoptAgentMode(status.mode)
                self.diagnosticsStatus = status
            } catch {
                // Named, not swallowed: "unavailable" and "the token is wrong" are
                // very different answers to "why does nothing work".
                self.diagnosticsStatusError = "unavailable — \(Self.describe(error))"
            }
            self.surface?.requestRender()
        }
        actionTasks.append(task)
    }

    /// Rebuild the panel when the terminal size changes, mirroring the modal's own
    /// re-fit: an overlay laid out for the old size is clipped or cramped.
    private func rebuildDiagnosticsOverlayIfResized() {
        guard diagnosticsHandle != nil, let surface else { return }
        let size = (surface.target.columns, surface.target.rows)
        guard let previous = diagnosticsOverlaySize, previous != size else {
            diagnosticsOverlaySize = size
            return
        }
        // Carried by VALUE, not index: losing the selection silently across a
        // resize is how a window drag turns "Close" into a destructive lever, or
        // the reverse. `diagnosticsStatus` survives on its own — only the overlay
        // is rebuilt, and the server's answer is not part of it.
        let selected = diagnosticsList?.getSelectedItem()?.value
        dismissDiagnosticsOverlay()
        presentDiagnosticsOverlay()
        if selected == "force-clear" { diagnosticsList?.setSelectedIndex(1) }
    }

    private func dismissDiagnosticsOverlay() {
        dismissDialog(diagnosticsHandle)
        diagnosticsHandle = nil
        diagnosticsList = nil
        diagnosticsOverlaySize = nil
    }

    /// Act on the selected panel row.
    private func activateDiagnosticsRow() {
        let value = diagnosticsList?.getSelectedItem()?.value
        dismissDiagnosticsOverlay()
        guard value == "force-clear", let id = store.selectedSessionID else { return }
        presentForceClearConfirmation(sessionID: id)
    }

    private func presentForceClearConfirmation(sessionID: String) {
        let dialog = DialogConfirm(
            title: "Force-clear run?",
            message: "This abandons the stuck turn and reopens the session.",
            confirmLabel: "Clear run",
            cancelLabel: "Keep running",
            keybindings: keybindings
        )
        dialog.onCancel = { [weak self] in self?.dismissForceClearConfirmation() }
        dialog.onResult = { [weak self] confirmed in
            guard let self else { return }
            self.dismissForceClearConfirmation()
            guard confirmed else {
                self.post(notice: "run was not cleared")
                return
            }
            self.forceClearRun(sessionID: sessionID)
        }
        forceClearDialog = dialog
        forceClearHandle = dialogs?.present(dialog, options: overlayOptions(width: 72, height: 7))
    }

    private func dismissForceClearConfirmation() {
        dismissDialog(forceClearHandle)
        forceClearHandle = nil
        forceClearDialog = nil
    }

    private func forceClearRun(sessionID id: String) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.forceClearRun(sessionID: id)
                // Do not wait for a frame to tell us: the whole reason this lever
                // exists is that the run in question cannot produce one.
                self.store.markIdle()
                self.post(notice: "the run was cleared — you can send again")
            } catch {
                self.post(notice: "could not clear the run")
                self.postError("Could not clear the run", error)
            }
        }
        actionTasks.append(task)
    }

    // MARK: Structured questions

    /// Keep the question modal level-triggered from the store, just like the
    /// permission modal. This makes SSE delivery, reconnect reconciliation and a
    /// successful REST answer all converge on the same presentation path.
    private func reconcileQuestionOverlay() {
        if let pending = store.pendingQuestion {
            if questionHandle == nil { presentQuestionOverlay(pending) }
        } else if questionHandle != nil {
            dismissQuestionOverlay()
        }
        diagnosticsHandle?.bringToFront()
    }

    private static let questionOverlayWidth = 78

    private func presentQuestionOverlay(_ pending: EventStore.PendingQuestion) {
        guard !pending.questions.isEmpty else { return }
        let dialog = QuestionDialog(questions: pending.questions, keybindings: keybindings)
        dialog.onSubmit = { [weak self] answers in self?.answerQuestion(answers) }
        dialog.onCancel = { [weak self] in self?.answerQuestion(nil) }

        let width = min(
            Self.questionOverlayWidth,
            max(30, surface?.target.columns ?? Self.questionOverlayWidth)
        )
        let innerWidth = max(1, width - 4)
        let naturalHeight = dialog.render(width: innerWidth).count
        let maxHeight = max(1, (surface?.target.rows ?? 24) - 2)
        questionOverlaySize = surface.map { ($0.target.columns, $0.target.rows) }
        questionHandle = dialogs?.present(
            Box(dialog, paddingX: 1),
            options: OverlayOptions(
                width: .absolute(width),
                minWidth: 20,
                maxHeight: .absolute(min(naturalHeight + 2, maxHeight)),
                anchor: .center
            )
        )
        questionDialog = dialog
    }

    private func rebuildQuestionOverlayIfResized() {
        guard questionHandle != nil, let surface, let pending = store.pendingQuestion else { return }
        let size = (surface.target.columns, surface.target.rows)
        guard let previous = questionOverlaySize, previous != size else {
            questionOverlaySize = size
            return
        }
        // The dialog's current prompt/selection is kept in the component.
        // Rebuilding a resized overlay must not reset a multi-select batch.
        let dialog = questionDialog
        dismissQuestionOverlay()
        if let dialog {
            let width = min(Self.questionOverlayWidth, max(30, surface.target.columns))
            let naturalHeight = dialog.render(width: max(1, width - 4)).count
            let maxHeight = max(1, surface.target.rows - 2)
            questionOverlaySize = (surface.target.columns, surface.target.rows)
            questionHandle = dialogs?.present(
                Box(dialog, paddingX: 1),
                options: OverlayOptions(
                    width: .absolute(width),
                    minWidth: 20,
                    maxHeight: .absolute(min(naturalHeight + 2, maxHeight)),
                    anchor: .center
                )
            )
        } else {
            presentQuestionOverlay(pending)
        }
    }

    private func dismissQuestionOverlay() {
        dismissDialog(questionHandle)
        questionHandle = nil
        questionDialog = nil
        questionOverlaySize = nil
    }

    /// Submit the selected answers (or nil for Escape), then optimistically hide
    /// the modal. A failed POST re-fetches the parked request so a transport
    /// error cannot leave the server suspended with no way to answer.
    private func answerQuestion(_ answers: [ServerQuestionAnswer]?) {
        guard let pending = store.pendingQuestion else {
            dismissQuestionOverlay()
            return
        }
        dismissQuestionOverlay()
        store.clearPendingQuestion()
        let sessionID = pending.sessionID
        let requestID = pending.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolveQuestion(
                    sessionID: sessionID,
                    requestID: requestID,
                    answers: answers
                )
            } catch {
                self.post(notice: "the answer did not reach the server — re-asking")
                await self.reconcilePendingQuestions(sessionID)
            }
        }
        actionTasks.append(task)
    }

    // MARK: Permission approval

    /// Show or hide the approval modal to match `store.pendingPermission`. Called from
    /// `onChange`, so every trigger — the ask event, an answer, a server-side resolve,
    /// a session switch — funnels through here instead of being hand-tracked.
    private func reconcilePermissionOverlay() {
        if let request = store.pendingPermission {
            if permissionHandle == nil { presentPermissionOverlay(request) }
        } else if permissionHandle != nil {
            dismissPermissionOverlay()
        }
        // A permission event may be reconciled after ^G opened diagnostics. The
        // modal belongs underneath that panel: it explains the parked action, but
        // must not hide the panel's client/server state rows.
        diagnosticsHandle?.bringToFront()
    }

    /// The modal's outer width. The content is framed in a ``Box``, whose rows are
    /// always exactly this wide — which is what makes the modal *opaque*: the old
    /// unframed overlay spliced only as many columns as each line happened to
    /// occupy, so the transcript showed through around it and a prompt on a busy
    /// screen was easy to miss entirely.
    private static let permissionOverlayWidth = 64

    private func presentPermissionOverlay(_ request: PermissionRequest) {
        var items = [SelectItem(value: "once", label: "Allow once", description: nil)]
        // Name the grant in the ROW, not in a dim hint beside it. This row writes to
        // the user's global settings.json and survives restarts, so "Allow always"
        // under a bold `edit  a.txt` must not be read as "always allow edits to
        // a.txt" when it means something wider. Hidden entirely when there is nothing
        // to persist, rather than offered as a choice that does nothing.
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

        // Fit the modal to the terminal, shedding decoration before substance.
        //
        // The overlay compositor keeps a clipped overlay's FIRST rows and drops the
        // rest, so a modal taller than the screen lost exactly the part that has to be
        // there: the options, the key hints and the bottom border. The prompt then
        // looked like decoration and could not be answered — a stalled tool call with
        // no visible way out. So the options are never optional; the title, the blank
        // spacers and the hint are, in that order of sacrifice.
        let available = max(1, (surface?.target.rows ?? 24) - 2)
        let borderRows = 2
        var budget = available - borderRows - items.count      // rows left for the rest
        // Substance before decoration: `header[1]` names the tool and its target and
        // is the ONLY row that says what is being approved; `header[0]` is the
        // constant "Permission required", which the framed yellow box already
        // conveys. Budgeting the title first meant that on a short terminal the user
        // was asked to approve something the modal never named.
        let showAction = budget >= 1
        if showAction { budget -= 1 }
        let showTitle = budget >= 1
        if showTitle { budget -= 1 }
        let showHint = budget >= 1
        if showHint { budget -= 1 }
        let showSpacers = budget >= 2

        // The list gets whatever vertical room actually remains, so its selection
        // marker is always on screen — a marker scrolled out of view meant Enter acted
        // on an option the user could not see.
        let visibleItems = max(1, min(items.count, available - borderRows))
        let list = SelectList(items: items, maxVisible: visibleItems, keybindings: keybindings)
        permissionItemValues = items.map(\.value)

        // Box takes one column of border and one of padding on each side.
        let innerWidth = Self.permissionOverlayWidth - 4
        let header = Self.permissionHeader(request, width: innerWidth)
        let inner = Container()
        if showTitle, let title = header.first { inner.addChild(Text(title, wrap: false)) }
        if showAction, header.count > 1 { inner.addChild(Text(header[1], wrap: false)) }
        if showSpacers { inner.addChild(Spacer(lines: 1)) }
        inner.addChild(list)
        if showSpacers { inner.addChild(Spacer(lines: 1)) }
        if showHint { inner.addChild(Text(dim("↑/↓ choose · Enter confirm · Esc selects Reject · ^C quits"), wrap: false)) }

        var contentHeight = visibleItems
        // SelectList appends a "(N more below)" row whenever its window cannot show
        // every option. Unbudgeted, the compositor's prefix-clip eats the Box's
        // bottom border instead.
        if visibleItems < items.count { contentHeight += 1 }
        if showTitle { contentHeight += 1 }
        if showAction, header.count > 1 { contentHeight += 1 }
        if showSpacers { contentHeight += 2 }
        if showHint { contentHeight += 1 }

        permissionOverlaySize = surface.map { ($0.target.columns, $0.target.rows) }
        // Handle FIRST, list second — and `handleInput` keys off the HANDLE.
        //
        // The other order is one refactor away from the worst wedge in this file: a
        // nil `surface` would leave `permissionList` set with no overlay on screen,
        // and the input branch would then swallow the entire keyboard forever with
        // nothing visible and no path to dismissal (`reconcilePermissionOverlay`
        // keys off the handle, so it would never take it down either).
        permissionHandle = dialogs?.present(
            Box(inner, paddingX: 1),
            options: OverlayOptions(
                width: .absolute(min(Self.permissionOverlayWidth, max(30, surface?.target.columns ?? Self.permissionOverlayWidth))),
                minWidth: 20,
                maxHeight: .absolute(contentHeight + borderRows),
                anchor: .center
            )
        )
        permissionList = list
    }

    /// Rebuild the modal when the terminal size changes.
    ///
    /// The overlay's height budget is decided once, when the ask arrives. Without
    /// this, resizing the window smaller while a prompt is up re-clips it back to an
    /// unanswerable stub, and resizing larger leaves it needlessly cramped.
    private func rebuildPermissionOverlayIfResized() {
        guard permissionHandle != nil, let surface, let request = store.pendingPermission else { return }
        let size = (surface.target.columns, surface.target.rows)
        guard let previous = permissionOverlaySize, previous != size else {
            permissionOverlaySize = size
            return
        }
        // Carry the current choice across the rebuild, by VALUE not index (the rows
        // are conditional). Losing it silently reset an Escape-selected "Reject" to
        // the default "Allow once", so a window resize could turn a rejection into an
        // approval on the next Enter.
        let selected = permissionList?.getSelectedItem()?.value
        dismissPermissionOverlay()
        presentPermissionOverlay(request)
        if let selected, let index = permissionItemValues.firstIndex(of: selected) {
            permissionList?.setSelectedIndex(index)
        }
    }

    /// Move the modal's selection onto "Reject" (what Escape does), so the
    /// destructive answer is one deliberate Enter away rather than one stray byte.
    private func selectRejectRow() {
        guard let list = permissionList else { return }
        list.setSelectedIndex(permissionItemValues.firstIndex(of: "reject") ?? 0)
        surface?.requestRender()
    }

    private func dismissPermissionOverlay() {
        dismissDialog(permissionHandle)
        permissionHandle = nil
        permissionList = nil
        permissionOverlaySize = nil
        permissionItemValues = []
    }

    /// Answer the pending prompt: dismiss the modal, clear the store optimistically
    /// (so reconcile does not re-show it before the server's echo), and POST the reply.
    private func answer(_ reply: PermissionReply) {
        guard let request = store.pendingPermission else { dismissPermissionOverlay(); return }
        dismissPermissionOverlay()
        store.clearPendingPermission()
        let sessionID = request.sessionID
        let requestID = request.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolvePermission(sessionID: sessionID, requestID: requestID, reply: reply)
            } catch {
                // The answer never landed, so the server run is still parked with no
                // modal. Re-fetch the pending prompt so it returns and can be
                // re-answered, rather than leaving the run hung.
                //
                // Say so first: the modal is about to reappear on its own, and a
                // prompt that silently re-asks the question you just answered
                // reads as the UI having lost the answer rather than the network.
                self.post(notice: "the approval did not reach the server — re-asking")
                await self.reconcilePendingPermissions(sessionID)
            }
        }
        actionTasks.append(task)
    }

    private static func reply(for value: String?) -> PermissionReply {
        switch value {
        case "once": return .once
        case "always": return .always
        default: return .reject(message: nil)
        }
    }

    /// The modal's headline rows: what is being asked for, and on what.
    ///
    /// The target is elided from the LEFT, so a deep path keeps the filename that
    /// actually identifies it, and a multi-line shell command is folded to one row
    /// so it cannot blow the modal's height budget.
    ///
    /// Deliberately glyph-free. `⚠` is East-Asian-ambiguous: terminals disagree with
    /// each other (and with our own ``graphemeWidth``) about whether it occupies one
    /// column or two, and inside a framed box a one-column disagreement visibly
    /// breaks the right border. Bold yellow inside a box is alarm enough, and its
    /// width is exactly what it looks like.
    private static func permissionHeader(_ request: PermissionRequest, width: Int) -> [String] {
        var lines = ["\u{1b}[1;33mPermission required\u{1b}[0m"]
        let target: String? =
            request.metadata["command"]?.stringValue
            ?? request.metadata["filepath"]?.stringValue
            ?? request.patterns.first.flatMap { $0 == "*" ? nil : $0 }

        // The permission name and the target both come from the model's tool call, so
        // they are sanitized before being framed — an escape here would erase the very
        // prompt the user has to answer.
        let permission = sanitizeUntrustedText(request.permission)
        let action = "\u{1b}[1m" + permission + sgrReset
        if let target, !target.isEmpty {
            let budget = max(1, width - visibleWidth(permission) - 2)
            lines.append(action + "  " + elideLeading(sanitizeUntrustedText(collapseToOneLine(target)), width: budget))
        } else {
            lines.append(action)
        }
        return lines
    }
}

// MARK: - TerminalApp

extension ClientApp: TerminalApp {
    public var target: any RenderTarget {
        // `run` sets `surface` before the driver ever touches this; a nil here would
        // be a programming error (using the app outside `run`).
        surface!.target
    }

    public func renderSync() throws(DoMoError) {
        // The driver repaints on resize, which is the only hook the app gets; use it
        // to re-fit a modal that is already up.
        rebuildPermissionOverlayIfResized()
        rebuildQuestionOverlayIfResized()
        rebuildDiagnosticsOverlayIfResized()
        try surface?.renderSync()
    }

    public func terminalDidEnter() {
        terminalNative?.setTitle("DoMoCode")
        terminalNative?.setProgress(store.runState == .running ? .indeterminate : .clear)
    }

    public func handleFocusChange(_ focused: Bool) {
        terminalFocused = focused
    }

    public func handleInput(_ data: [UInt8]) {
        // The mouse is handled first, and outside every other branch: scrolling back
        // through the transcript has to work WHILE a modal is up (that is exactly
        // when you want to re-read what the tool is about to do), and a wheel report
        // that fell through to a text handler would be typed into the prompt as
        // escape gibberish.
        if let mouse = decodeMouseEvent(data) {
            handleMouse(mouse)
            return
        }
        // Ctrl-C quits, ALWAYS — checked before the modal, which used to consume it.
        // A modal that swallowed Ctrl-C turned it into "reject this one prompt", so an
        // agent that re-asks on every tool call left the session genuinely unquittable
        // while the status bar still advertised "^C: quit".
        if data == Self.ctrlC { quit.quit(); return }
        // F8 takes or releases the mouse. ABOVE the modal branch deliberately: the
        // moment a user most wants their terminal's own selection back is while a
        // modal is showing them a command they want to copy elsewhere.
        if matchesKey(data, Key.f8) { toggleMouse(); return }
        // ^G opens the diagnostics panel. ABOVE the modal branch, and for the same
        // reason ^O is: a parked modal is one of the states you most want to
        // diagnose, and it is the state in which a user is most likely to conclude
        // the client has frozen. BELOW Ctrl-C, always, so it can never shadow quit.
        if data == Self.ctrlG { toggleDiagnostics(); return }
        // ^O expands capped error and failed-tool detail. ABOVE the modal branch
        // deliberately: reading the failure that is being re-tried, or the tool
        // output that prompted the approval you are being asked for, is exactly
        // what you want while a modal is up.
        if data == Self.ctrlO {
            transcriptView.expandErrors.toggle()
            surface?.requestRender()
            return
        }
        if matchesKey(data, Key.f6) {
            transcriptView.toggleImageExpansion()
            surface?.requestRender()
            return
        }
        if data == Self.ctrlP { openPalette(); return }
        if data == Self.ctrlS { openSessionPicker(); return }
        if data == Self.ctrlM { openModelPicker(); return }
        if data == Self.ctrlT { openTreePicker(); return }
        if data == Self.ctrlE { editPromptInEditor(); return }
        // The workflow workspace is a separate root, not a modal. Keep the
        // process-level quit and mouse controls above, then hand every remaining
        // key to its phase/agent navigator so Escape means "back" rather than
        // aborting the ordinary session run.
        if workflowWorkspace != nil {
            surface?.handleInput(data)
            return
        }
        // The reusable client dialogs capture ordinary keyboard input. This
        // branch must precede the global Escape/abort interpretation below:
        // Escape dismisses a palette, picker, or rename form, while it still
        // aborts a turn when no dialog owns the surface.
        if autocompleteHandle != nil || paletteHandle != nil || toolCatalogHandle != nil
            || sessionPickerHandle != nil
            || modelPickerHandle != nil || treePickerHandle != nil || renameHandle != nil
            || labelHandle != nil || forceClearHandle != nil || draftEditorHandle != nil
            || diffReviewHandle != nil || diffRevertHandle != nil
            || questionHandle != nil || copyOptionsHandle != nil {
            surface?.handleInput(data)
            return
        }
        // The diagnostics panel owns the keyboard while it is up — including over a
        // permission modal, which it can be opened on top of. Keyed off the HANDLE,
        // so a list that somehow exists without an overlay cannot eat every key.
        // Keyboard scrolling sits with the other above-the-modal globals, for the
        // same reason the WHEEL does: re-reading what a tool is about to do is
        // exactly what you want while its approval modal is up. Below the modal
        // branch — which returns unconditionally — a released mouse plus a modal
        // left the transcript unscrollable by any means at all, which is the hole
        // this whole mechanism exists to close, in its most important state.
        // Safe here: the modal reads only its four select actions and already
        // swallowed these keys, and the sidebar ignores them.
        // Escape clears a live selection BEFORE it means abort. Two reasons, and the
        // order is semantic rather than a preference: dismissing a highlight is the
        // less destructive of the two readings, and it is the one the status line is
        // advertising at that exact moment. Below Ctrl-C, always — a selection must
        // never make the session harder to leave.
        if selection.selection != nil, matchesKey(data, Key.escape) {
            selection.clear()
            surface?.requestRender()
            return
        }
        // Through the decoder, not a raw byte compare: the framer delivers two fast
        // Escapes as ONE `[esc, esc]` frame, which a byte compare against `[0x1b]`
        // never matches — so the abort key did not get the fix the decoder did.
        // `matchesKey` (not `.selectCancel`) deliberately: that action is also bound
        // to Ctrl-C, which must keep meaning quit.
        if matchesKey(data, Key.escape) { abort(); return }
        // The keyboard scroll, and the LAST branch before the surface, so every
        // modal, overlay and global key above keeps its own meaning for these
        // bytes. It is what makes a released mouse — F8, or `--no-mouse` for the
        // whole session — a real alternative rather than a one-way door: the wheel
        // goes with the mouse, and until this existed nothing else could move the
        // transcript.
        if let request = keyboardScroll(data) {
            scrollFromKeyboard(rows: request.rows, up: request.up, page: request.page)
            return
        }

        if diagnosticsHandle != nil {
            if isKeyRelease(data) { return }
            if let list = diagnosticsList,
               keybindings.matches(data, .selectUp) || keybindings.matches(data, .selectDown) {
                list.handleInput(data)
                surface?.requestRender()
            } else if keybindings.matches(data, .selectConfirm) {
                activateDiagnosticsRow()
            } else if keybindings.matches(data, .selectCancel) {
                dismissDiagnosticsOverlay()
            }
            return
        }
        // A permission prompt captures the rest of the keyboard: arrows move, Enter
        // confirms, Escape rejects; everything else is swallowed while a tool waits.
        if let list = permissionList {
            // Kitty key-RELEASE frames are not answers. Every other input path in the
            // app drops them (ScreenSurface honours `wantsKeyRelease`); this branch
            // bypassed that, so on a Kitty-protocol terminal the release of the very
            // key that opened the modal could confirm it.
            if isKeyRelease(data) { return }
            if keybindings.matches(data, .selectUp) || keybindings.matches(data, .selectDown) {
                list.handleInput(data)
                surface?.requestRender()
            } else if keybindings.matches(data, .selectConfirm) {
                answer(Self.reply(for: list.getSelectedItem()?.value))
            } else if keybindings.matches(data, .selectCancel) {
                // Escape SELECTS "Reject"; it does not answer. A terminal splits an
                // arrow key into `ESC` and `[B`, and if the two land more than the
                // disambiguation window apart the lone `ESC` is delivered as a real
                // Escape — indistinguishable from a keypress at this point, because
                // the tail only arrives after we would already have replied. Answering
                // on it meant a cursor keystroke silently rejected the tool call. One
                // extra Enter is a small price for a destructive action that can be
                // triggered by a timing race.
                selectRejectRow()
            }
            return
        }
        // Tab is the phase-14 mode switch on the main surface. Modal dialogs keep
        // Tab for their own controls through the branches above; the runtime remains
        // authoritative and rejects a switch while a turn is running.
        if data == [0x09] {
            toggleAgentMode()
            return
        }
        let slashCatalogShortcut = data == [0x2f] && promptInput.focused && promptInput.text.isEmpty
        surface?.handleInput(data)
        if slashCatalogShortcut { openToolCatalog() }
    }

    public func stop() {
        surface?.stop()
    }
}
