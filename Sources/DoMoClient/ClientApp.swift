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
import DoMoPermissions
import Foundation
import DoMoServer
import DoMoTUI
import DoMoTermGraphics
import DoMoTermIO

/// The remote full-screen client application.
@MainActor
public final class ClientApp {
    private let client: ServerClient
    private let store = EventStore()
    private let sidebar = SessionSidebar()
    private let transcriptView = TranscriptView()
    private let promptInput = PromptInput()
    private let statusBar = StatusBar()
    private let focus = FocusRing()
    private let quit = QuitSignal()

    /// The terminal's inline-image capability and cell pixel size, detected once at
    /// startup (the client owns the tty; the remote runtime has none).
    private var graphicsCapabilities = TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false)
    private var cellSize: CellDimensions = .default

    private var surface: ScreenSurface?
    private var eventTask: Task<Void, Never>?
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
    /// Whether the session's event stream is currently up. Surfaced in the status
    /// line, because a dead stream is otherwise indistinguishable from a slow model.
    private var streamConnected = true
    /// A transient status-line message and when it lapses — the client's only error
    /// surface. Without one there is nowhere to report a refused or failed action,
    /// which is precisely why they used to be swallowed.
    private var notice: String?
    private var noticeExpiry: Date?

    private static let ctrlC: [UInt8] = [0x03]
    private static let escape: [UInt8] = [0x1b]

    public init(client: ServerClient) {
        self.client = client
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
        detectGraphics()

        let surface = ScreenSurface(target: target, focus: focus) { [weak self] in
            self?.buildTree(width: target.columns, height: target.rows) ?? Column([])
        }
        self.surface = surface

        store.onChange = { [weak self] in
            self?.reconcilePermissionOverlay()
            self?.surface?.requestRender()
        }
        promptInput.onSubmit = { [weak self] text in self?.submit(text) }
        sidebar.onSelect = { [weak self] id in self?.openSession(id) }
        sidebar.onNew = { [weak self] in self?.newSession() }

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

        eventTask?.cancel()
        eventTask = nil
        spinnerTask?.cancel()
        spinnerTask = nil

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

    private func buildTree(width: Int, height: Int) -> any LayoutNode {
        // Refresh the views from the current store state.
        sidebar.sessions = store.sessions
        sidebar.openID = store.selectedSessionID
        transcriptView.items = store.transcript
        transcriptView.running = store.runState == .running
        statusBar.text = statusText()

        let layout = ClientLayout(width: width, height: height)
        let main = Column([
            Flexible(1, TranscriptNode(view: transcriptView, capabilities: graphicsCapabilities, cell: cellSize)),
            Fixed(.absolute(1), statusBar.layout),
            Fixed(.absolute(1), promptInput.layout),
        ])
        return Row([
            Fixed(.absolute(layout.sidebarWidth), sidebar.layout),
            Flexible(1, main),
        ])
    }

    /// The status line: what the run is doing right now, then the key hints.
    ///
    /// The run state alone ("streaming…") is not enough to distinguish "the model is
    /// thinking", "a tool is running" and "a tool is parked waiting for you" — and
    /// the third is the one a user reads as a freeze. Each gets its own text.
    private func statusText() -> String {
        var parts: [String] = []
        if !streamConnected {
            parts.append("\u{1b}[31mdisconnected — reconnecting…\u{1b}[0m")
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
        if let notice {
            parts.append("\u{1b}[33m\(notice)\u{1b}[0m")
        }
        if transcriptView.scrollOffset > 0 {
            parts.append("↑ \(transcriptView.scrollOffset) rows — scroll down to follow")
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
        } else {
            parts.append("Tab: pane")
            parts.append("Enter: send")
            parts.append("Esc: abort")
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
        surface?.requestRender()
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
                if animating {
                    self.transcriptView.spinnerFrame &+= 1
                    self.surface?.requestRender()
                }
                try? await Task.sleep(for: animating ? .milliseconds(100) : .milliseconds(250))
            }
        }
    }

    // MARK: Mouse

    /// Route a wheel report to the pane under the pointer.
    ///
    /// Pointer-targeted rather than focus-targeted, which is what every terminal
    /// application does and what a user expects: you scroll what you are looking at,
    /// without first Tab-ing focus to it. Buttons and motion are ignored — this
    /// takes the mouse only so the wheel works, since the alternate screen has no
    /// scrollback for the terminal to scroll on our behalf.
    private func handleMouse(_ event: MouseEvent) {
        guard event.kind == .scrollUp || event.kind == .scrollDown else { return }
        guard let target = surface?.target else { return }
        let layout = ClientLayout(width: target.columns, height: target.rows)
        // Ctrl-wheel pages, matching the convention of a viewport that has no
        // separate page keys.
        let step = event.ctrl ? max(1, layout.transcriptHeight - 1) : 3
        let up = event.kind == .scrollUp

        switch layout.pane(atColumn: event.column, row: event.row) {
        case .sidebar:
            sidebar.scroll(by: up ? -step : step, viewportHeight: layout.height)
        case .transcript, .mainFooter:
            // The transcript is the main column's scrollable body; the status and
            // prompt rows are one line each and scroll it too, so a wheel near the
            // bottom edge is not silently dead.
            transcriptView.scrollOffset = max(0, transcriptView.scrollOffset + (up ? step : -step))
        }
        surface?.requestRender()
    }

    // MARK: Session lifecycle

    private func bootstrap() async {
        let sessions = (try? await client.listSessions()) ?? []
        store.setSessions(sessions)
        if let first = sessions.first {
            await open(first.id)
        } else {
            await createAndOpen()
        }
    }

    private func createAndOpen() async {
        guard let ref = try? await client.createSession() else { return }
        let sessions = (try? await client.listSessions()) ?? store.sessions
        store.setSessions(sessions)
        await open(ref.id)
    }

    private func open(_ sessionID: String) async {
        // A new session's transcript is a different document; carrying the old
        // scroll position into it would open it part-way up at an arbitrary row.
        transcriptView.scrollToBottom()
        store.select(sessionID)

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
        _ = try? await client.createSession(resume: sessionID)
        guard store.selectedSessionID == sessionID else { return }

        let history = (try? await client.messages(sessionID: sessionID)) ?? []
        // A newer selection may have superseded this one while messages() was in
        // flight (a slow session opened, then a fast one). Drop this stale
        // completion so it cannot clobber the newer session's transcript or attach
        // the wrong live stream — which would leave the sidebar marking B while the
        // pane shows A and a prompt silently targets B.
        guard store.selectedSessionID == sessionID else { return }
        store.seed(history)
        attachEvents(sessionID)
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
            while !Task.isCancelled {
                guard let self, self.store.selectedSessionID == sessionID else { return }
                do {
                    for try await event in self.client.events(sessionID: sessionID) {
                        guard self.store.selectedSessionID == sessionID else { return }
                        if case .connected = event {
                            // Reconcile pending prompts only AFTER the SSE is live (the
                            // server sends `connected` first). Doing the GET before
                            // subscribing would lose a prompt asked in the gap.
                            backoffMS = 125
                            self.setStreamConnected(true)
                            // Re-seed after an OUTAGE: the stream is delta-only, so
                            // everything that streamed while we were away is simply
                            // missing from the pane, with nothing to say so. Not on the
                            // first connect — `open()` has just fetched the same
                            // history, and re-seeding a mid-turn attach would discard
                            // partial streamed text. Before `apply`, because `seed`
                            // clears the transcript (and the run state with it), which
                            // would wipe the `running` this very frame carries.
                            if isReconnect, let history = try? await self.client.messages(sessionID: sessionID) {
                                guard self.store.selectedSessionID == sessionID else { return }
                                self.store.seed(history)
                            }
                            isReconnect = false
                            self.store.apply(event)
                            await self.reconcilePendingPermissions(sessionID)
                            continue
                        }
                        self.store.apply(event)
                    }
                } catch {
                    // Fall through to the same retry as a clean end.
                }
                guard !Task.isCancelled, self.store.selectedSessionID == sessionID else { return }
                // The stream is down. Say so — a silent disconnect is exactly what made
                // this look like a freeze — then retry with bounded backoff.
                self.setStreamConnected(false)
                isReconnect = true
                try? await Task.sleep(for: .milliseconds(backoffMS))
                backoffMS = min(backoffMS * 2, 4000)
            }
        }
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
        guard store.selectedSessionID == sessionID,
              let pending = try? await client.pendingPermissions(sessionID: sessionID),
              store.selectedSessionID == sessionID
        else { return }
        for event in pending { store.apply(event) }
    }

    // MARK: Actions (called from the render actor via component callbacks)

    private func openSession(_ id: String) {
        Task { @MainActor [weak self] in await self?.open(id) }
    }

    private func newSession() {
        Task { @MainActor [weak self] in await self?.createAndOpen() }
    }

    /// Send a prompt — and never destroy it silently.
    ///
    /// `PromptInput` clears its text BEFORE calling this, so the typed string survives
    /// only as this argument. It used to be handed to a detached `try?`, so a refusal
    /// (the server allows one turn at a time and answers 409 `sessionBusy`) erased the
    /// user's message with no message, no retry and no trace. Two guards now: a
    /// synchronous one for the common case, which can put the text back in the same
    /// main-actor turn as the keystroke; and a `catch` for every remaining race, which
    /// restores it too.
    private func submit(_ text: String) {
        guard let id = store.selectedSessionID else {
            promptInput.restore(text)
            post(notice: "no session is open")
            return
        }
        // The client's view of run state is racy against the server's, so this is an
        // optimisation of the common case, not the guarantee — the catch below is.
        if store.runState == .running {
            promptInput.restore(text)
            post(notice: "a turn is already running — Esc to abort it, or wait")
            return
        }
        // Sending snaps the transcript back to the tail: a user who scrolled up to
        // re-read something and then asks a question must see the answer, not stay
        // parked in the history while the reply streams in off-screen.
        transcriptView.scrollToBottom()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendPrompt(sessionID: id, prompt: text)
            } catch ServerClientError.unexpectedStatus(409, _, _) {
                self.promptInput.restore(text)
                self.post(notice: "a turn is already running — Esc to abort it, or wait")
            } catch {
                self.promptInput.restore(text)
                self.post(notice: "could not send — the message was put back")
            }
        }
    }

    private func abort() {
        // No `runState == .running` guard: the client's copy of that flag can be stale
        // (it is reset on every session selection), and aborting an idle session is a
        // harmless 200 — `ServerRuntime.abort` cancels a nil task and drains an empty
        // map. Refusing to try was how "Esc does nothing" happened.
        guard let id = store.selectedSessionID else { return }
        Task { @MainActor [weak self] in
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
            }
        }
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
        permissionList = list
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
        permissionHandle = surface?.showOverlay(
            Box(inner, paddingX: 1),
            options: OverlayOptions(
                width: .absolute(min(Self.permissionOverlayWidth, max(30, surface?.target.columns ?? Self.permissionOverlayWidth))),
                minWidth: 20,
                maxHeight: .absolute(contentHeight + borderRows),
                anchor: .center
            )
        )
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
        permissionHandle?.hide()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.resolvePermission(sessionID: sessionID, requestID: requestID, reply: reply)
            } catch {
                // The answer never landed, so the server run is still parked with no
                // modal. Re-fetch the pending prompt so it returns and can be
                // re-answered, rather than leaving the run hung.
                await self.reconcilePendingPermissions(sessionID)
            }
        }
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
        try surface?.renderSync()
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
        // Through the decoder, not a raw byte compare: the framer delivers two fast
        // Escapes as ONE `[esc, esc]` frame, which a byte compare against `[0x1b]`
        // never matches — so the abort key did not get the fix the decoder did.
        // `matchesKey` (not `.selectCancel`) deliberately: that action is also bound
        // to Ctrl-C, which must keep meaning quit.
        if matchesKey(data, Key.escape) { abort(); return }
        surface?.handleInput(data)
    }

    public func stop() {
        surface?.stop()
    }
}
