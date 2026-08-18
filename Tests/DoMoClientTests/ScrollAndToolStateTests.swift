// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Three things the two-pane client gained together, because they answer one
// complaint — "the tool call froze":
//
//  1. the terminal state the UI actually requires (it was silently not asking for
//     the alternate screen, so absolute-addressed frames landed on the user's
//     normal buffer and desynchronised on any real scroll),
//  2. a scrollable transcript, since the alternate screen has no scrollback of its
//     own for the wheel to move, and
//  3. tool-call rows that say which state they are in and what they are acting on,
//     so a call parked on an approval prompt cannot look like a finished one.

import DoMoCore
import DoMoLLM
import DoMoServer
import DoMoTUI
import DoMoTermGraphics
import Testing

@testable import DoMoClient

@MainActor
@Suite("Full-screen client: terminal state, scrolling, tool-call state")
struct ScrollAndToolStateTests {

    // MARK: Terminal state

    @Test("The full-screen client declares the alternate screen and the mouse")
    func fullScreenClientDeclaresItsTerminalState() {
        // The regression this pins: the client addresses absolute rows, but the CLI
        // built a DEFAULT lifecycle, so it painted onto the NORMAL buffer — clobbering
        // scrollback, and desynchronising every repaint the moment the real viewport
        // scrolled. The requirement now lives with the UI that has it.
        let lifecycle = fullScreenClientLifecycle()
        #expect(lifecycle.useAlternateScreen)
        #expect(lifecycle.enableMouse)
    }

    // MARK: Pane geometry

    @Test("Pane hit-testing splits the sidebar, divider, transcript and footer")
    func paneHitTest() {
        let layout = ClientLayout(width: 100, height: 24)
        #expect(layout.sidebarWidth == 25)
        #expect(layout.dividerColumn == 25)
        #expect(layout.mainColumnStart == 26)
        #expect(layout.transcriptHeight == 22)
        #expect(layout.pane(atColumn: 0, row: 0) == .sidebar)
        #expect(layout.pane(atColumn: 24, row: 10) == .sidebar)
        #expect(layout.pane(atColumn: 25, row: 0) == .divider)
        #expect(layout.pane(atColumn: 26, row: 0) == .transcript)
        #expect(layout.pane(atColumn: 99, row: 21) == .transcript)
        #expect(layout.pane(atColumn: 60, row: 22) == .mainFooter)   // status line
        #expect(layout.pane(atColumn: 60, row: 23) == .mainFooter)   // prompt
    }

    @Test("A collapsed sidebar gives the main pane the full width")
    func collapsedSidebarGeometry() {
        let layout = ClientLayout(width: 100, height: 24, sidebarVisible: false)
        #expect(layout.sidebarWidth == 0)
        #expect(layout.mainColumnStart == 0)
        #expect(layout.mainWidth == 100)
        #expect(layout.dividerColumn == nil)
        #expect(layout.pane(atColumn: 0, row: 0) == .transcript)
        #expect(layout.bounds(of: .sidebar) == ClientLayout.PaneBounds(columns: 0..<0, rows: 0..<24))
    }

    @Test("The sidebar keeps its minimum and maximum width at extreme sizes")
    func sidebarWidthBounds() {
        #expect(ClientLayout(width: 20, height: 10).sidebarWidth == 16)
        #expect(ClientLayout(width: 400, height: 10).sidebarWidth == 32)
        // Degenerate sizes must not produce a negative viewport.
        #expect(ClientLayout(width: 0, height: 0).transcriptHeight == 0)
        #expect(ClientLayout(width: 10, height: 1).transcriptHeight == 0)
    }

    @Test("The prompt's current height moves the footer boundary the mouse hit-tests")
    func promptRowsDriveTheFooterHitTest() {
        // The footer stopped being two rows the moment the prompt learned to grow. A
        // hit test against a nominal 2-row footer would send a wheel meant for the
        // transcript into the prompt (or the reverse) by exactly however many rows
        // the user has typed.
        let layout = ClientLayout(width: 100, height: 24, promptRows: 5)
        #expect(layout.mainFooterRows == 6)
        #expect(layout.transcriptHeight == 18)
        #expect(layout.pane(atColumn: 60, row: 17) == .transcript)
        #expect(layout.pane(atColumn: 60, row: 18) == .mainFooter)
        #expect(layout.pane(atColumn: 60, row: 23) == .mainFooter)
        #expect(layout.pane(atColumn: 0, row: 23) == .sidebar)

        // The default is the old geometry, so nothing that never asks for a taller
        // prompt sees a change.
        #expect(ClientLayout(width: 100, height: 24).transcriptHeight == 22)
    }

    @Test("The prompt-height cap never starves the transcript to nothing")
    func promptRowCapNeverStarvesTheTranscript() {
        // `Fixed.measure` returns its basis unconditionally and the flexible
        // transcript gets only what is left, so an uncapped prompt takes the
        // transcript to zero rows and then overruns the rect. This cap is the only
        // thing between a long paste and that.
        for height in 4...60 {
            let cap = ClientLayout.promptRowCap(for: height)
            #expect(cap >= 1, "h=\(height)")
            let layout = ClientLayout(width: 80, height: height, promptRows: cap)
            #expect(layout.transcriptHeight >= 1, "h=\(height) cap=\(cap) starved the transcript")
        }
        for height in 0...3 {
            let cap = ClientLayout.promptRowCap(for: height)
            #expect(cap >= 1, "h=\(height)")
            #expect(ClientLayout(width: 80, height: height, promptRows: cap).transcriptHeight >= 0)
        }
    }

    @Test("The prompt may take about a third of the screen, and not a row more")
    func promptRowCapIsAThirdOfTheScreen() {
        // Pinned with literals on purpose. The two invariant tests either side of
        // this one are both satisfied WITHOUT the ceiling — `transcriptHeight >= 1`
        // is the separate one-row clamp's doing, and asserting `rows <= cap` against
        // `promptRowCap`'s own return value is tautological — so deleting
        // `height / 3` left the suite green while a 60-row terminal gave the prompt
        // 58 rows and the transcript 1.
        #expect(ClientLayout.promptRowCap(for: 10) == 3)
        #expect(ClientLayout.promptRowCap(for: 24) == 8)
        #expect(ClientLayout.promptRowCap(for: 30) == 10)
        #expect(ClientLayout.promptRowCap(for: 40) == 13)
        #expect(ClientLayout.promptRowCap(for: 60) == 20)
        // Never below the 3 rows a bordered single-line editor wants, until the
        // screen itself is too short to give them.
        #expect(ClientLayout.promptRowCap(for: 6) == 3)
        #expect(ClientLayout.promptRowCap(for: 5) == 3)
        #expect(ClientLayout.promptRowCap(for: 4) == 2)
        // And the ceiling really is a ceiling, at every size the transcript clamp is
        // not the binding constraint.
        for height in 9...120 {
            #expect(
                ClientLayout.promptRowCap(for: height) == height / 3,
                "h=\(height) is no longer a third of the screen"
            )
        }
    }

    @Test("A prompt asked for more rows than the cap allows is held to the cap")
    func promptHeightHonoursTheCap() {
        let input = PromptInput()
        input.focused = true
        for _ in 0..<40 { input.handleInput([0x0a]) }   // 41 logical lines
        for height in [10, 24, 40, 60] {
            let cap = ClientLayout.promptRowCap(for: height)
            let rows = input.height(forWidth: 60, maxRows: cap)
            #expect(rows <= cap, "h=\(height)")
            #expect(input.render(width: 60).count == rows, "h=\(height)")
            #expect(ClientLayout(width: 80, height: height, promptRows: rows).transcriptHeight >= 1)
        }
    }

    // MARK: Transcript scrolling

    /// Place the view into a viewport and return the painted rows.
    private func paint(_ view: TranscriptView, width: Int, height: Int) -> [String] {
        var buffer = CellBuffer(width: width, height: height)
        let node = TranscriptNode(
            view: view,
            capabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false),
            cell: .default
        )
        node.place(in: Rect(x: 0, y: 0, width: width, height: height), into: &buffer)
        return buffer.flatten()
    }

    private func longTranscript(_ count: Int) -> [TranscriptItem] {
        (0..<count).map { .assistant("row\($0)") }
    }

    @Test("With no offset the transcript shows its newest rows")
    func tailByDefault() {
        let view = TranscriptView()
        view.items = longTranscript(20)
        let painted = paint(view, width: 20, height: 5)
        // The newest rows are in view and the oldest are not. (Rows carry a trailing
        // SGR/OSC-8 reset, so "blank" rows are not literally empty — assert on
        // content, not on emptiness.)
        #expect(painted.contains { $0.contains("row19") })
        #expect(!painted.contains { $0.contains("row0 ") || $0.contains("row1 ") })
        #expect(view.scrollOffset == 0)
    }

    @Test("A scroll offset moves the viewport up by that many rows")
    func scrollOffsetMovesViewport() {
        let view = TranscriptView()
        view.items = longTranscript(20)
        _ = paint(view, width: 20, height: 5)
        view.scrollOffset = 6
        let painted = paint(view, width: 20, height: 5)
        #expect(painted.joined().contains("row19") == false)
        #expect(painted.joined().contains("row16"))
    }

    @Test("The offset is clamped to the content, so a wheel spun past the top settles")
    func offsetClamps() {
        let view = TranscriptView()
        view.items = longTranscript(8)          // 8 items -> 16 rows (each has a spacer)
        view.scrollOffset = 10_000
        _ = paint(view, width: 20, height: 5)
        // Clamped, and WRITTEN BACK — otherwise the status line would report a
        // phantom offset and the first wheel-down would appear to do nothing.
        #expect(view.scrollOffset < 10_000)
        let maxOffset = view.scrollOffset
        // Scrolling back to the bottom really reaches it.
        view.scrollOffset = 0
        let painted = paint(view, width: 20, height: 5)
        #expect(painted.contains { $0.contains("row7") })
        #expect(maxOffset > 0)
    }

    @Test("Content appended while scrolled up does not slide the viewport")
    func scrollAnchorSurvivesAppend() {
        let view = TranscriptView()
        view.items = longTranscript(20)
        _ = paint(view, width: 20, height: 5)
        view.scrollOffset = 6
        let before = paint(view, width: 20, height: 5)

        // New content arrives at the tail while the user is reading history.
        view.items.append(.assistant("NEW-ROW"))
        let after = paint(view, width: 20, height: 5)
        #expect(before == after, "the rows under the user's eyes must not move")
        #expect(view.scrollOffset > 6, "the anchor absorbed the appended rows")
    }

    @Test("At the bottom, new content still follows the tail")
    func atBottomStillFollows() {
        let view = TranscriptView()
        view.items = longTranscript(20)
        _ = paint(view, width: 20, height: 5)
        view.items.append(.assistant("NEW-ROW"))
        let painted = paint(view, width: 20, height: 5)
        #expect(painted.joined().contains("NEW-ROW"))
        #expect(view.scrollOffset == 0)
    }

    @Test("The sidebar scrolls and clamps to its session list")
    func sidebarScroll() {
        let sidebar = SessionSidebar()
        sidebar.sessions = (0..<30).map {
            SessionSummary(id: "id\($0)", path: "/p\($0)", cwd: "/cwd\($0)", timestamp: "t")
        }
        sidebar.scroll(by: 5, viewportHeight: 12)
        #expect(sidebar.scrollOffset == 5)
        let lines = sidebar.render(width: 24)
        #expect(lines.joined().contains("id5".isEmpty ? "" : "cwd5"))
        // Past the end clamps rather than scrolling into blank space.
        sidebar.scroll(by: 1_000, viewportHeight: 12)
        #expect(sidebar.scrollOffset == 30 - (12 - 2))
        sidebar.scroll(by: -1_000, viewportHeight: 12)
        #expect(sidebar.scrollOffset == 0)
    }

    // MARK: Tool-call state

    @Test("A tool row shows its argument summary, not just the tool name")
    func toolRowNamesItsTarget() {
        let view = TranscriptView()
        view.items = [.tool(name: "edit", detail: "src/Foo.swift", output: "", state: .running, imageCount: 0)]
        let lines = view.render(width: 60)
        #expect(lines.contains { $0.contains("edit") && $0.contains("src/Foo.swift") })
    }

    @Test("Each tool-call state renders a distinct glyph")
    func toolStateGlyphs() {
        func header(_ state: ToolCallState) -> String {
            let view = TranscriptView()
            view.items = [.tool(name: "bash", detail: "ls", output: "", state: state, imageCount: 0)]
            return view.render(width: 60).first ?? ""
        }
        // The bug this closes: `running`, `awaitingApproval` and `succeeded` all used
        // to render the same static `⚙`, so a parked call was indistinguishable from
        // a finished one — which is what "it froze" looked like.
        #expect(header(.succeeded).contains("✓"))
        #expect(header(.failed).contains("✗"))
        #expect(header(.awaitingApproval).contains("⏳"))
        let running = header(.running)
        #expect(!running.contains("✓") && !running.contains("✗") && !running.contains("⏳"))
    }

    @Test("A parked tool call says so in the transcript, not only in the modal")
    func parkedCallIsLabelled() {
        let view = TranscriptView()
        view.items = [.tool(name: "edit", detail: "a.txt", output: "", state: .awaitingApproval, imageCount: 0)]
        let lines = view.render(width: 70)
        #expect(lines.contains { $0.contains("waiting for your approval") })
    }

    @Test("Every rendered tool row stays inside the width budget")
    func toolRowsFitTheWidth() {
        let view = TranscriptView()
        view.items = [
            .tool(name: "edit", detail: String(repeating: "deep/path/", count: 30) + "Foo.swift",
                  output: "", state: .running, imageCount: 0),
            .tool(name: "bash", detail: String(repeating: "x", count: 400), output: "", state: .awaitingApproval, imageCount: 2),
        ]
        for width in [10, 24, 40, 80] {
            let lines = view.render(width: width)
            #expect(lines.allSatisfy { visibleWidth($0) <= width }, "over-wide line at width \(width)")
        }
    }

    @Test("The spinner advances with the frame index")
    func spinnerAdvances() {
        let view = TranscriptView()
        view.items = [.tool(name: "bash", detail: "ls", output: "", state: .running, imageCount: 0)]
        view.spinnerFrame = 0
        let first = view.render(width: 40).first
        view.spinnerFrame = 1
        let second = view.render(width: 40).first
        // Also proves the memo cache is keyed on the frame — a cached row would
        // freeze the spinner, which is precisely the signal it exists to give.
        #expect(first != second)
    }

    // MARK: Store-driven state

    @Test("A pending permission marks the in-flight tool call, and resolving clears it")
    func pendingPermissionMarksTheToolCall() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.toolStart(id: "t1", name: "edit", arguments: .object(["path": .string("a.txt")])))
        #expect(store.activeToolCall?.state == .running)
        #expect(store.activeToolCall?.detail == "a.txt")

        store.apply(.permissionRequest(
            id: "per_1", sessionID: "s1", permission: "edit", patterns: ["a.txt"],
            always: ["*"], metadata: ["filepath": .string("a.txt")], disableAlways: false
        ))
        #expect(store.activeToolCall?.state == .awaitingApproval)

        store.apply(.permissionResolved(id: "per_1"))
        #expect(store.activeToolCall?.state == .running)

        store.apply(.toolEnd(id: "t1", name: "edit", output: "ok", isError: false, imageCount: 0))
        #expect(store.activeToolCall == nil)
        // The detail from tool_start survives into the finished row.
        #expect(store.transcript == [.tool(name: "edit", detail: "a.txt", output: "ok", state: .succeeded, imageCount: 0)])
    }

    @Test("A run that ends without a tool_end settles the row instead of spinning forever")
    func abandonedToolCallSettles() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        store.apply(.agentEnd(reason: "errored"))
        #expect(store.activeToolCall == nil)
        #expect(store.transcript.contains { item in
            if case .tool(_, _, _, .failed, _) = item { return true }
            return false
        })
    }

    // MARK: Argument summaries

    @Test("Tool argument summaries name the thing the call acts on")
    func argumentSummaries() {
        #expect(toolCallDetail(name: "edit", arguments: .object(["path": .string("a/b.swift")])) == "a/b.swift")
        let patch = "*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        #expect(toolCallDetail(name: "apply_patch", arguments: .object(["patch": .string(patch)])) == "Sources/App.swift")
        #expect(toolCallDetail(name: "websearch", arguments: .object(["query": .string("swift concurrency")])) == "swift concurrency")
        #expect(toolCallDetail(name: "mcp_resource", arguments: .object([
            "action": .string("read"),
            "server": .string("docs"),
            "uri": .string("memo://one"),
        ])) == "read  docs  memo://one")
        #expect(toolCallDetail(name: "skill", arguments: .object(["name": .string("review")])) == "review")
        // The tool layer accepts `file_path` as an alias, so the summary must too.
        #expect(toolCallDetail(name: "write", arguments: .object(["file_path": .string("c.txt")])) == "c.txt")
        #expect(toolCallDetail(name: "bash", arguments: .object(["command": .string("ls -la")])) == "ls -la")
        #expect(toolCallDetail(name: "ls", arguments: .object([:])) == ".")
        #expect(toolCallDetail(name: "grep", arguments: .object(["pattern": .string("needle")])) == "needle")
        // An unknown/MCP tool falls back to sorted scalar args, so the row is stable.
        // Whitespace runs collapse, so the joined pairs read as single-spaced.
        #expect(toolCallDetail(name: "mcp_thing", arguments: .object(["b": .int(2), "a": .string("x")])) == "a=x b=2")
    }

    @Test("A multi-line command is folded to one row")
    func multiLineCommandFolds() {
        let detail = toolCallDetail(name: "bash", arguments: .object(["command": .string("echo one\necho two")]))
        #expect(!detail.contains("\n"))
        #expect(detail.contains("⏎"))
    }

    // MARK: Run state and prompt safety

    @Test("Attaching mid-turn adopts the server's run state")
    func connectedFrameCarriesRunState() {
        // The client's run state used to be write-once per attach: it learned
        // "running" only from an `agent_start` it witnessed. Attaching mid-turn — a
        // session switch, a reconnect, re-opening the same session — therefore left
        // it stuck on "idle" for the rest of the turn, which killed the spinner,
        // disabled Esc/abort, and made every prompt look refusable.
        let store = EventStore()
        store.select("s1")
        #expect(store.runState == .idle)
        store.apply(.connected(protocolVersion: 1, sessionID: "s1", running: true))
        #expect(store.runState == .running)

        // A fresh attach to a quiet session must NOT invent a running turn.
        let quiet = EventStore()
        quiet.select("s2")
        quiet.apply(.connected(protocolVersion: 1, sessionID: "s2", running: false))
        #expect(quiet.runState == .idle)
    }

    @Test("The server's run state is adopted in BOTH directions")
    func connectedIsAuthoritativeBothWays() {
        // Adopting only `true` was its own bug: a reconnect that missed the turn's
        // `agent_end` pinned the client on "running" forever, and the synchronous
        // submit guard then refused every prompt for the life of the session. The
        // server owns this flag; `connected` is authoritative at the instant it is
        // sent (and always arrives first on a stream).
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        store.apply(.connected(protocolVersion: 1, sessionID: "s1", running: false))
        #expect(store.runState == .idle)
        #expect(store.activeToolCall == nil, "a settled turn cannot leave a tool call spinning")
    }

    @Test("A server that predates the field says nothing, and is not read as idle")
    func connectedWithoutRunStateIsIgnored() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.connected(protocolVersion: 1, sessionID: "s1", running: nil))
        #expect(store.runState == .running, "absent is not the same as `false`")
    }

    @Test("A refused prompt is put back, not destroyed")
    func promptInputRestores() {
        // `handleInput` clears the text BEFORE onSubmit runs, so the typed string
        // survives only as the callback argument — and a refused send used to drop it
        // on the floor with no message.
        let input = PromptInput()
        input.focused = true
        for byte in Array("hello there".utf8) { input.handleInput([byte]) }
        #expect(input.text == "hello there")
        input.handleInput([0x0d])            // Enter clears it
        #expect(input.text.isEmpty)

        input.restore("hello there")
        #expect(input.text == "hello there")

        // Restoring must not clobber something typed in the meantime: a failure can
        // arrive asynchronously.
        input.clear()
        for byte in Array("new".utf8) { input.handleInput([byte]) }
        input.restore("older")
        #expect(input.text == "new\nolder", "the refusal lands at the END, on its own line")
    }

    @Test("A refused message is never spliced into the word being typed")
    func promptInputRestoreDoesNotSpliceAtTheCaret() {
        // The async catch fires after a network round trip, by which time the caret
        // is wherever the user's next thought put it. Restoring THERE produced
        // "abc the failed messagedef" out of "abcdef" — both strings corrupted.
        let input = PromptInput()
        input.focused = true
        for byte in Array("abcdef".utf8) { input.handleInput([byte]) }
        let left: [UInt8] = Array("\u{1b}[D".utf8)
        for _ in 0..<3 { input.handleInput(left) }   // caret between "abc" and "def"

        input.restore("the failed message")
        #expect(input.text == "abcdef\nthe failed message")
        #expect(!input.text.contains("abc the failed messagedef"))

        // Two refusals in a row stay legible and in arrival order, one per line,
        // instead of space-joining into an unsendable scramble.
        input.restore("and another")
        #expect(input.text == "abcdef\nthe failed message\nand another")
    }

    @Test("An abort the server reports as a no-op self-corrects a stale run state")
    func markIdleClearsStaleRunState() {
        // The client's run state can be stale (it is reset on every selection). When
        // the server answers that there was nothing to abort, that is authoritative —
        // adopting it stops the prompt box refusing input over a turn that is not
        // actually running.
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.toolStart(id: "t1", name: "bash", arguments: .object([:])))
        #expect(store.runState == .running)
        store.markIdle()
        #expect(store.runState == .idle)
        #expect(store.activeToolCall == nil, "no spinner may outlive the turn")
    }

    // MARK: Untrusted text

    @Test("Control characters in model/tool text are neutralised")
    func controlCharactersAreStripped() {
        // Left in, these do not print — they DRIVE the terminal: ESC[2J wipes the
        // page, ESC[5A walks the paint cursor into another pane, and a lone CR returns
        // it to column zero so the row overwrites the sidebar. The app then keeps
        // painting rows that no longer land where it thinks they do, which reads as a
        // frozen or corrupted UI.
        let wiped = sanitizeUntrustedText("BEFORE\u{1b}[2JAFTER")
        #expect(!wiped.contains("\u{1b}"))
        #expect(wiped.contains("BEFORE") && wiped.contains("AFTER"))

        #expect(!sanitizeUntrustedText("a\rb").contains("\r"))
        #expect(!sanitizeUntrustedText("a\u{7f}b").contains("\u{7f}"))
        #expect(!sanitizeUntrustedText("a\u{9b}[2Jb").contains("\u{9b}"))   // 8-bit CSI

        // Newlines and tabs are content, not control: the wrapper splits on one and
        // the renderer expands the other.
        #expect(sanitizeUntrustedText("a\nb\tc") == "a\nb\tc")
        // Ordinary text is returned untouched (and takes the fast path).
        #expect(sanitizeUntrustedText("plain text ✓ 日本語") == "plain text ✓ 日本語")
    }

    @Test("CRLF becomes LF, so Windows line endings really split into lines")
    func crlfNormalises() {
        // Swift treats "\r\n" as ONE grapheme cluster, so a Character-wise wrap never
        // sees the \n and collapses the whole text into a single paragraph.
        let text = sanitizeUntrustedText("one\r\ntwo\r\nthree")
        #expect(text == "one\ntwo\nthree")
        #expect(wrapToWidth(text, width: 40).count == 3)
        // A LONE carriage return is still a control character and is marked, not kept.
        #expect(!sanitizeUntrustedText("one\rtwo").contains("\r"))
    }

    @Test("The store sanitises every route untrusted text takes into the transcript")
    func storeSanitisesIngress() {
        let store = EventStore()
        store.select("s1")
        store.apply(.agentStart)
        store.apply(.messageDelta(text: "hi\u{1b}[2J", reasoning: nil))
        store.apply(.toolStart(id: "t1", name: "read", arguments: .object(["path": .string("a\u{1b}[2J.txt")])))
        store.apply(.toolEnd(id: "t1", name: "read", output: "out\u{1b}[2Jput", isError: false, imageCount: 0))
        // A failure frame is ingress too, and its text is the far side of the wire
        // talking: `ErrorPresentation` cannot sanitise (DoMoCore cannot reach the
        // sanitiser), so the store has to.
        store.apply(.notice(ServerNotice(
            level: .error, code: "provider_error",
            text: "boom\u{1b}[2Jed", detail: "why\u{1b}[5Anot", kind: "provider"
        )))
        let rendered = TranscriptView()
        rendered.items = store.transcript
        // The rendered rows still carry the app's OWN styling escapes; what must not
        // survive is an ESC introducer that came from the model or the tool. Without
        // one, a stray `[2J` is inert text.
        #expect(!rendered.render(width: 60).joined().contains("\u{1b}[2J"))
        #expect(store.transcript.allSatisfy { item in
            switch item {
            case .assistant(let t), .user(let t), .reasoning(let t): return !t.contains("\u{1b}")
            case .tool(let n, let d, let o, _, _): return ![n, d, o].contains { $0.contains("\u{1b}") }
            case .image: return true
            // An error row's three parts are as untrusted as any other ingress
            // and must carry no ESC introducer.
            case .error(let headline, let message, let hint):
                return ![headline, message, hint ?? ""].contains { $0.contains("\u{1b}") }
            }
        })
    }

    @Test("A long path is elided from the LEFT, keeping the filename")
    func longPathKeepsItsTail() {
        let elided = elideLeading("/a/very/long/path/to/Interesting.swift", width: 20)
        #expect(visibleWidth(elided) <= 20)
        #expect(elided.hasSuffix("Interesting.swift"))
        // Short enough to fit: returned untouched.
        #expect(elideLeading("short.txt", width: 20) == "short.txt")
    }
}
