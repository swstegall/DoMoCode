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
import DoMoServer
import DoMoTUI
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

    private var surface: ScreenSurface?
    private var eventTask: Task<Void, Never>?

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

        let surface = ScreenSurface(target: target, focus: focus) { [weak self] in
            self?.buildTree(width: target.columns, height: target.rows) ?? Column([])
        }
        self.surface = surface

        store.onChange = { [weak self] in self?.surface?.requestRender() }
        promptInput.onSubmit = { [weak self] text in self?.submit(text) }
        sidebar.onSelect = { [weak self] id in self?.openSession(id) }
        sidebar.onNew = { [weak self] in self?.newSession() }

        // Load sessions/history as the driver's background job — i.e. AFTER the
        // terminal is entered and the first (empty) frame is painted — so the store
        // mutations' coalesced renders never fire before the alt screen is active
        // and leak a frame onto the normal buffer. The UI comes up immediately and
        // fills in as the network responds.
        let driver = TerminalDriver(input: inputStream, resize: resize, lifecycle: lifecycle)
        await driver.run(self, quit: quit, background: { [weak self] in
            await self?.bootstrap()
        })

        eventTask?.cancel()
        eventTask = nil

        if let error = driver.startupError { throw error }
        if let error = driver.renderError { throw error }
    }

    // MARK: Layout

    private func buildTree(width: Int, height: Int) -> any LayoutNode {
        // Refresh the views from the current store state.
        sidebar.sessions = store.sessions
        sidebar.openID = store.selectedSessionID
        transcriptView.items = store.transcript
        transcriptView.running = store.runState == .running
        statusBar.text = statusText()

        let sidebarWidth = min(32, max(16, width / 4))
        let main = Column([
            Flexible(1, TailBox(transcriptView)),
            Fixed(.absolute(1), statusBar.layout),
            Fixed(.absolute(1), promptInput.layout),
        ])
        return Row([
            Fixed(.absolute(sidebarWidth), sidebar.layout),
            Flexible(1, main),
        ])
    }

    private func statusText() -> String {
        var parts: [String] = []
        switch store.runState {
        case .running: parts.append("streaming…")
        case .idle: parts.append(store.lastStopReason.map { "idle (\($0))" } ?? "idle")
        }
        parts.append("Tab: pane")
        parts.append("Enter: send")
        parts.append("Esc: abort")
        parts.append("^C: quit")
        return parts.joined(separator: "   ")
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
        store.select(sessionID)
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

    private func attachEvents(_ sessionID: String) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in self.client.events(sessionID: sessionID) {
                    self.store.apply(event)
                }
            } catch {
                // The stream ended or errored; the next selection re-attaches. The
                // transcript stays as last seen rather than clearing under the user.
            }
        }
    }

    // MARK: Actions (called from the render actor via component callbacks)

    private func openSession(_ id: String) {
        Task { @MainActor [weak self] in await self?.open(id) }
    }

    private func newSession() {
        Task { @MainActor [weak self] in await self?.createAndOpen() }
    }

    private func submit(_ text: String) {
        guard let id = store.selectedSessionID else { return }
        Task { @MainActor [weak self] in
            try? await self?.client.sendPrompt(sessionID: id, prompt: text)
        }
    }

    private func abort() {
        guard let id = store.selectedSessionID, store.runState == .running else { return }
        Task { @MainActor [weak self] in
            try? await self?.client.abort(sessionID: id)
        }
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
        try surface?.renderSync()
    }

    public func handleInput(_ data: [UInt8]) {
        if data == Self.ctrlC { quit.quit(); return }
        if data == Self.escape { abort(); return }
        surface?.handleInput(data)
    }

    public func stop() {
        surface?.stop()
    }
}
