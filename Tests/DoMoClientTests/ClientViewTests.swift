// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The client's view components, asserted at the render/line level: what a pane
// draws for a given state, and how it responds to keys. The renderer pipeline
// itself (layout + alt-screen diff + cursor) is covered by DoMoTUI's oracle
// tests; here the concern is the client's own formatting and input handling.

import DoMoLLM
import DoMoServer
import DoMoTermGraphics
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
private final class Lines: @MainActor Component {
    let lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] { lines }
}

@MainActor
@Suite("Client views")
struct ClientViewTests {
    private func summary(_ id: String, cwd: String = "/home/proj") -> SessionSummary {
        SessionSummary(id: id, path: "/sessions/\(id).jsonl", cwd: cwd, timestamp: "2026")
    }

    @Test("The sidebar lists sessions and highlights the focused cursor row")
    func sidebarRendersAndHighlights() {
        let sidebar = SessionSidebar()
        sidebar.sessions = [summary("abcd1234ef01"), summary("beef5678aa02")]
        sidebar.openID = "abcd1234ef01"
        sidebar.focused = true

        let lines = sidebar.render(width: 30)
        #expect(lines.contains { $0.contains("34ef01") })     // trailing (random) id hex
        #expect(lines.contains { $0.contains("proj") })       // cwd basename
        #expect(lines.contains { $0.contains("•") })          // open marker
        #expect(lines.contains { $0.contains("\u{1b}[7m") })  // inverse highlight while focused
    }

    @Test("Sidebar down-arrow then Enter selects the next session")
    func sidebarNavigatesAndSelects() {
        let sidebar = SessionSidebar()
        sidebar.sessions = [summary("aaaaaaaa01"), summary("bbbbbbbb02")]
        var selected: String?
        sidebar.onSelect = { selected = $0 }

        sidebar.handleInput([0x1b, 0x5b, 0x42])   // down
        sidebar.handleInput([0x0d])               // Enter
        #expect(selected == "bbbbbbbb02")
    }

    @Test("Sidebar 'n' starts a new session")
    func sidebarNew() {
        let sidebar = SessionSidebar()
        sidebar.sessions = [summary("aaaaaaaa01")]
        var newed = false
        sidebar.onNew = { newed = true }
        sidebar.handleInput([0x6e])   // 'n'
        #expect(newed)
    }

    @Test("Sidebar marks a child and returns to its parent")
    func sidebarBackToParent() {
        let parent = summary("parent01")
        let child = SessionSummary(
            id: "child02",
            path: "/sessions/child02.jsonl",
            cwd: "/home/proj",
            timestamp: "2026",
            parentSession: parent.path
        )
        let sidebar = SessionSidebar()
        sidebar.sessions = [parent, child]
        sidebar.openID = child.id
        var returned: String?
        sidebar.onBack = { returned = $0 }

        let lines = sidebar.render(width: 40)
        sidebar.handleInput([0x62])   // 'b'

        #expect(lines.contains { $0.contains("↳") })
        #expect(returned == parent.id)
    }

    @Test("Hovering a long sidebar row scrolls only its body and keeps marker and id stable")
    func sidebarHoverMarquee() {
        let sidebar = SessionSidebar()
        sidebar.sessions = [
            summary("abcdef123456", cwd: "/home/a-very-long-project-directory"),
            summary("beefed654321", cwd: "/home/another-very-long-project-directory"),
        ]
        sidebar.clock = { 2.0 }
        sidebar.updateHover(screenRow: 2)

        let initialLines = sidebar.render(width: 20)
        let initial = initialLines[2]
        let unrelated = initialLines[3]
        #expect(initial.contains("123456"))
        #expect(initial.hasPrefix("  "))

        sidebar.clock = { 3.1 }
        let movedLines = sidebar.render(width: 20)
        let moved = movedLines[2]
        #expect(moved.contains("123456"))
        #expect(moved != initial)
        #expect(visibleWidth(moved) == 20)
        #expect(movedLines[3] == unrelated)

        sidebar.clearHover()
        #expect(sidebar.hoveredSessionID == nil)
        #expect(sidebar.render(width: 20)[3] == unrelated)
    }

    @Test("The full-screen status bar scrolls long controls instead of dropping them")
    func statusBarMarquee() {
        let status = StatusBar()
        status.text = "working — diagnostics — Esc: abort — Tab: pane — Ctrl+Tab: mode — Enter: send"
        status.clock = { 10.0 }
        let initial = status.render(width: 18)[0]
        status.clock = { 11.2 }
        let moved = status.render(width: 18)[0]
        #expect(visibleWidth(initial) == 18)
        #expect(visibleWidth(moved) == 18)
        #expect(initial != moved)
    }

    @Test("The transcript marks roles and renders a tool header")
    func transcriptFormatting() {
        let view = TranscriptView()
        view.items = [
            .user("hi there"),
            .assistant("hello back"),
            .tool(name: "bash", detail: "", output: "ok", state: .succeeded, imageCount: 0),
        ]
        let lines = view.render(width: 40)
        #expect(lines.contains { $0.contains("›") && $0.contains("hi there") })
        #expect(lines.contains { $0.contains("hello back") })
        #expect(lines.contains { $0.contains("✓") && $0.contains("bash") })
        // Every line fits the width budget.
        #expect(lines.allSatisfy { visibleWidth($0) <= 40 })
    }

    @Test("Assistant markdown emits OSC 8 only on a hyperlink-capable terminal")
    func assistantHyperlinks() {
        let view = TranscriptView()
        view.items = [.assistant("Visit [DoMoCode](https://example.com).")]
        let capable = view.visualRows(
            width: 60,
            capabilities: TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true),
            cell: .default
        )
        let capableText = capable.compactMap { row -> String? in
            if case .text(let value) = row { return value }
            return nil
        }.joined()
        #expect(capableText.contains("\u{1b}]8;;https://example.com\u{07}"))

        let conservative = view.visualRows(
            width: 60,
            capabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false),
            cell: .default
        )
        let conservativeText = conservative.compactMap { row -> String? in
            if case .text(let value) = row { return value }
            return nil
        }.joined()
        #expect(!conservativeText.contains("\u{1b}]8;;"))
        #expect(conservativeText.contains("[DoMoCode](https://example.com)"))
    }

    @Test("Ctrl-V is exposed as an asynchronous clipboard-paste gesture")
    func clipboardPasteGesture() {
        let input = PromptInput()
        var called = false
        input.onPasteImage = { called = true }
        input.handleInput([0x16])
        #expect(called)
    }

    @Test("The prompt input accepts typing, shows a caret when focused, and submits on Enter")
    func promptInputTypeAndSubmit() {
        let input = PromptInput()
        input.focused = true
        var submitted: String?
        input.onSubmit = { text, _ in submitted = text }

        for byte in Array("hey".utf8) { input.handleInput([byte]) }
        #expect(input.text == "hey")

        // Row 0 is the editor's top rule now, not the text — the input grew from a
        // single line into a bordered box. The text lives between the rules.
        _ = input.height(forWidth: 40, maxRows: 8)
        let lines = input.render(width: 40)
        #expect(lines.count == 3)
        #expect(lines[1].contains("hey"))
        #expect(lines[1].contains(cursorMarker))   // caret at the end while focused

        input.handleInput([0x7f])               // backspace
        #expect(input.text == "he")

        input.handleInput([0x0d])               // Enter submits and clears
        #expect(submitted == "he")
        #expect(input.text.isEmpty)
    }

    @Test("An empty prompt does not submit")
    func promptInputEmptyNoSubmit() {
        let input = PromptInput()
        var submitted: String?
        input.onSubmit = { text, _ in submitted = text }
        input.handleInput([0x0d])       // Enter on empty
        #expect(submitted == nil)
    }

    @Test("wrapToWidth never emits an over-wide line, even with wide glyphs")
    func wrapWidthInvariant() {
        let inputs = ["hello world foo bar", "你好世界 test", "🎉🎉🎉 party time", String(repeating: "x", count: 40), "line one\nline two"]
        for width in 1...8 {
            for text in inputs {
                for line in wrapToWidth(text, width: width) {
                    #expect(visibleWidth(line) <= width, "over-wide (\(visibleWidth(line))>\(width)): \(line)")
                }
            }
        }
    }

    @Test("A large single line wraps in linear time and fits the width")
    func wrapLargeLineIsLinear() {
        // O(N^2) wrapping of 200k chars would take minutes; O(N) is instant. The
        // test completing at all is the signal, plus the exact line count.
        let big = String(repeating: "a", count: 200_000)
        let lines = wrapToWidth(big, width: 80)
        #expect(lines.count == 2500)
        #expect(lines.allSatisfy { visibleWidth($0) <= 80 })
    }

    @Test("The transcript memoizes: unchanged items+width re-render is identical")
    func transcriptMemoizes() {
        let view = TranscriptView()
        view.items = [.user("hi"), .assistant("hello")]
        let first = view.render(width: 30)
        let second = view.render(width: 30)   // unchanged -> cached
        #expect(first == second)
        view.items = [.user("hi"), .assistant("hello"), .user("again")]
        let third = view.render(width: 30)    // changed -> re-rendered
        #expect(third.count > first.count)
    }

    @Test("TailBox shows the LAST rect.height lines of a taller component")
    func tailBoxShowsTail() {
        let box = TailBox(Lines(["l0", "l1", "l2", "l3", "l4"]))
        var buffer = CellBuffer(width: 10, height: 3)
        box.place(in: Rect(x: 0, y: 0, width: 10, height: 3), into: &buffer)
        let out = buffer.flatten()
        #expect(out.count == 3)
        // flatten() wraps each row in per-line reset sequences, so assert on content.
        #expect(out[0].contains("l2"))    // tail of 5 lines into a height-3 box
        #expect(out[1].contains("l3"))
        #expect(out[2].contains("l4"))
        let joined = out.joined()
        #expect(!joined.contains("l0"))   // the head scrolled off
        #expect(!joined.contains("l1"))
    }

    // MARK: The multi-line prompt

    /// Ctrl+J — the newline binding guaranteed on every terminal.
    private static let ctrlJ: [UInt8] = [0x0a]
    /// Shift+Enter, Kitty CSI-u.
    private static let shiftEnter: [UInt8] = Array("\u{1b}[13;2u".utf8)
    /// Alt/Option+Enter, `ESC \r`, intentionally no longer a newline binding.
    private static let altEnter: [UInt8] = [0x1b, 0x0d]
    private static let enter: [UInt8] = [0x0d]

    private func type(_ input: PromptInput, _ text: String) {
        for byte in Array(text.utf8) { input.handleInput([byte]) }
    }

    private func attachment(_ id: UInt32, _ name: String, bytes: Int = 2048) -> PromptAttachment {
        PromptAttachment(
            id: id,
            path: "/tmp/\(name)",
            name: name,
            byteCount: bytes,
            image: ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50, 0x4e, 0x47]))
        )
    }

    @Test("The prompt grows a row per line instead of staying one row tall")
    func promptInputGrowsWithNewlines() {
        let input = PromptInput()
        input.focused = true
        #expect(input.height(forWidth: 40, maxRows: 8) == 3)   // 2 rules + 1 empty row

        type(input, "a")
        input.handleInput(Self.ctrlJ)
        type(input, "b")
        #expect(input.text == "a\nb")
        #expect(input.height(forWidth: 40, maxRows: 8) == 4)
        #expect(input.render(width: 40).count == 4)
    }

    @Test("Enter submits; Ctrl+J and Shift+Enter insert a newline")
    func promptInputEnterSubmitsCtrlJAndShiftEnterDoNot() {
        let input = PromptInput()
        input.focused = true
        var submitted: [String] = []
        input.onSubmit = { text, _ in submitted.append(text) }

        type(input, "a")
        input.handleInput(Self.ctrlJ)
        type(input, "b")
        input.handleInput(Self.shiftEnter)
        type(input, "c")
        #expect(input.text == "a\nb\nc", "neither newline binding may submit")
        #expect(submitted.isEmpty)

        input.handleInput(Self.altEnter)
        #expect(input.text == "a\nb\nc", "Alt+Enter is no longer a newline binding")

        input.handleInput(Self.enter)
        #expect(submitted == ["a\nb\nc"])
        #expect(input.text.isEmpty)
    }

    @Test("A pasted newline is inserted and never submits")
    func promptInputPastedNewlineInsertsAndNeverSubmits() {
        let input = PromptInput()
        input.focused = true
        var submitted: [String] = []
        input.onSubmit = { text, _ in submitted.append(text) }

        // Exactly the shape `TerminalDriver.dispatch` re-wraps a `.paste` into.
        input.handleInput(Array("\u{1b}[200~one\ntwo\u{1b}[201~".utf8))
        #expect(input.text == "one\ntwo")
        #expect(submitted.isEmpty, "a paste carries no intent to send")
        #expect(input.height(forWidth: 40, maxRows: 8) == 4)
    }

    @Test("A long line wraps and grows the box instead of scrolling sideways")
    func promptInputWrapsInsteadOfScrollingHorizontally() {
        let input = PromptInput()
        input.focused = true
        // Twenty words, well past a 20-column pane.
        type(input, String(repeating: "ab ", count: 20).trimmingCharacters(in: .whitespaces))

        let rows = input.height(forWidth: 20, maxRows: 10)
        let lines = input.render(width: 20)
        #expect(rows > 3, "the box has to grow — the old input showed only the tail")
        #expect(lines.count == rows)
        #expect(lines.allSatisfy { visibleWidth($0) <= 20 })
        // The BEGINNING of the text is on screen. The single-line input showed the
        // tail and nothing else, which is the whole complaint.
        #expect(lines[1].hasPrefix("ab ab"))
    }

    @Test("The prompt stops growing at its cap and scrolls inside instead")
    func promptInputHeightIsCappedAndScrollsInternally() {
        let input = PromptInput()
        input.focused = true
        for index in 0..<40 {
            type(input, "line\(index)")
            input.handleInput(Self.ctrlJ)
        }
        #expect(input.height(forWidth: 40, maxRows: 6) == 6)
        let lines = input.render(width: 40)
        #expect(lines.count == 6)
        #expect(lines[0].contains("↑"), "the top rule doubles as the scroll affordance")
        #expect(lines.contains { $0.contains(cursorMarker) }, "the caret stays on screen")
    }

    @Test("The placeholder shows only on an empty, unfocused prompt")
    func promptInputPlaceholderOnlyWhenEmptyAndUnfocused() {
        let input = PromptInput()
        input.focused = false
        _ = input.height(forWidth: 60, maxRows: 8)
        #expect(input.render(width: 60).contains { $0.contains("Enter to send") })

        input.focused = true
        _ = input.height(forWidth: 60, maxRows: 8)
        let focusedLines = input.render(width: 60)
        #expect(!focusedLines.contains { $0.contains("Enter to send") })
        #expect(focusedLines.contains { $0.contains(cursorMarker) })
    }

    @Test("Measuring and painting agree at the same width, at every size")
    func promptInputMeasureAndPlaceAgreeAtTheSameWidth() {
        for width in [12, 20, 37, 80, 120] {
            for maxRows in 1...10 {
                let input = PromptInput()
                input.focused = true
                type(input, "the quick brown fox jumps over the lazy dog")
                input.handleInput(Self.ctrlJ)
                type(input, "and then it does it again, at length, with feeling")

                let rows = input.height(forWidth: width, maxRows: maxRows)
                let lines = input.render(width: width)
                #expect(rows <= maxRows, "w=\(width) maxRows=\(maxRows)")
                #expect(lines.count == rows, "measure/paint disagree at w=\(width) maxRows=\(maxRows)")
                #expect(
                    lines.allSatisfy { visibleWidth($0) <= width },
                    "over-wide line at w=\(width) maxRows=\(maxRows)"
                )
            }
        }
    }

    // MARK: Prompt history

    @Test("Up walks back through history and Down brings the draft back")
    func promptHistoryUpRecallsAndDownRestoresTheDraft() {
        let input = PromptInput()
        input.focused = true
        input.seedHistory(["first", "second"])   // oldest first, as it comes off disk
        type(input, "draft")
        _ = input.height(forWidth: 40, maxRows: 8)

        input.handleInput([0x01])                // Ctrl+A: to the start of the line
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "second")
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "first")
        input.handleInput(ArrowKeys.down)
        #expect(input.text == "second")
        input.handleInput(ArrowKeys.down)
        #expect(input.text == "draft", "the in-progress draft has to survive the trip")
    }

    @Test("Seeded history arrives newest-first in the editor")
    func seededHistoryLandsNewestFirstInTheEditor() {
        let input = PromptInput()
        input.focused = true
        input.seedHistory(["oldest", "middle", "newest"])
        _ = input.height(forWidth: 40, maxRows: 8)

        input.handleInput(ArrowKeys.up)
        #expect(input.text == "newest")
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "middle")
    }

    @Test("Away from the edge rows the arrows move the caret, not the history")
    func promptHistoryArrowsMoveTheCaretAwayFromTheEdges() {
        let input = PromptInput()
        input.focused = true
        input.seedHistory(["old"])
        type(input, "a")
        input.handleInput(Self.ctrlJ)
        type(input, "b")
        input.handleInput(Self.ctrlJ)
        type(input, "c")
        _ = input.height(forWidth: 40, maxRows: 8)
        #expect(input.text == "a\nb\nc")

        // From the LAST row: Up walks the caret up a visual line, twice, before the
        // first row is even reached.
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "a\nb\nc")
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "a\nb\nc", "arriving on the first row is still a caret move")
        // On the first row but mid-line, Up is "go to the start of the line" — the
        // one documented divergence from a literal reading of "Up at the top row
        // recalls". It is what makes Up usable on a long first line, and history is
        // still exactly one more Up away.
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "a\nb\nc", "mid-line on the first row, Up moves to column 0")
        // Only now, at column 0 of the first visual row, does Up mean history.
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "old")

        // And Down at the last row, while not browsing, is a caret move.
        input.handleInput(ArrowKeys.down)   // leaves history: back to the draft
        input.handleInput(ArrowKeys.down)
        #expect(input.text == "a\nb\nc")
    }

    // MARK: Attachment chips (the seam the drag-and-drop work fills in)

    @Test("A submit carries the staged attachments out and clears them")
    func promptInputSubmitCarriesAndClearsAttachments() {
        let input = PromptInput()
        input.focused = true
        let bare = input.height(forWidth: 40, maxRows: 8)

        input.addAttachment(attachment(1, "a.png"))
        #expect(input.height(forWidth: 40, maxRows: 8) == bare + 1)
        #expect(input.render(width: 40).contains { $0.contains("a.png") })

        var got: (String, [PromptAttachment])?
        input.onSubmit = { text, attachments in got = (text, attachments) }
        type(input, "go")
        input.handleInput(Self.enter)
        #expect(got?.0 == "go")
        #expect(got?.1.map(\.id) == [1])
        #expect(input.attachments.isEmpty)
    }

    @Test("Backspace on an empty document pops the newest chip")
    func promptInputBackspacePopsAChip() {
        let input = PromptInput()
        input.focused = true
        input.addAttachment(attachment(1, "a.png"))
        input.addAttachment(attachment(2, "b.png"))
        #expect(input.attachments.count == 2)

        input.handleInput([0x7f])
        #expect(input.attachments.map(\.id) == [1])

        // With text in the box the keystroke belongs to the editor again.
        type(input, "x")
        input.handleInput([0x7f])
        #expect(input.text.isEmpty)
        #expect(input.attachments.map(\.id) == [1], "the chip survives a backspace that had text to eat")
    }

    @Test("A drop resolution only applies while its token is live")
    func promptInputResolvesADropOnceAndOnlyOnce() {
        let input = PromptInput()
        input.focused = true
        let token = input.beginDrop()
        input.resolveDrop(token: token, outcome: .attached([attachment(7, "shot.png")]))
        #expect(input.attachments.map(\.id) == [7])
        // A second answer for the same token is stale — the document has moved on.
        input.resolveDrop(token: token, outcome: .attached([attachment(8, "other.png")]))
        #expect(input.attachments.map(\.id) == [7])

        // A rejection puts the raw text back verbatim rather than eating it.
        let second = input.beginDrop()
        input.resolveDrop(token: second, outcome: .rejected(rawText: "/tmp/notanimage.txt", notice: "nope"))
        #expect(input.text == "/tmp/notanimage.txt")
    }

    @Test("Chips never paint more rows than the height they were budgeted")
    func promptInputChipsNeverOverrunTheMeasuredHeight() {
        // The measure path clamped the chip count and the paint path did not, and
        // chips are emitted FIRST — so `ComponentBox.place`, which builds exactly
        // `rect.height` rows and drops the rest, clipped away the EDITOR: the text
        // being typed and the caret vanished. Eight images on a 24-row terminal
        // (cap 8) is the case the drag-and-drop work lands on.
        for chipCount in 0...10 {
            for maxRows in 1...10 {
                let input = PromptInput()
                input.focused = true
                for index in 0..<chipCount {
                    input.addAttachment(attachment(UInt32(index + 1), "shot\(index).png"))
                }
                type(input, "typed text the user must not lose")

                let rows = input.height(forWidth: 40, maxRows: maxRows)
                let lines = input.render(width: 40)
                #expect(rows <= maxRows, "chips=\(chipCount) maxRows=\(maxRows)")
                #expect(
                    lines.count == rows,
                    "chips=\(chipCount) maxRows=\(maxRows): promised \(rows), painted \(lines.count)"
                )
            }
        }
    }

    @Test("A chip dropped for want of rows is announced, not silently lost")
    func promptInputOverflowingChipsShowAMoreAffordance() {
        let input = PromptInput()
        input.focused = true
        for index in 0..<8 { input.addAttachment(attachment(UInt32(index + 1), "shot\(index).png")) }

        // 8 chips into a 4-row slot: 3 chips fit, the 4th row names the other 5.
        let rows = input.height(forWidth: 40, maxRows: 4)
        let lines = input.render(width: 40)
        #expect(rows == 4)
        #expect(lines.count == 4)
        #expect(lines[0].contains("shot0.png"))
        #expect(lines[2].contains("+6 more"), "the chips that did not fit are still visible")
        #expect(!lines.contains { $0.contains("shot7.png") })
    }

    @Test("A rejected drop cannot paint escape sequences into the terminal")
    func promptInputRejectedDropStripsControlCharacters() {
        // `handlePastedText` returning true short-circuits `Editor.handlePaste`
        // BEFORE its control-character filter, so a rejected drop would re-insert
        // the ORIGINAL unfiltered payload. The source is a clipboard/drag payload,
        // not the user's keystrokes.
        let input = PromptInput()
        input.focused = true
        let token = input.beginDrop()
        input.resolveDrop(
            token: token,
            outcome: .rejected(rawText: "x\u{1b}[2J\u{1b}]0;pwned\u{7}y", notice: "nope")
        )
        #expect(!input.text.unicodeScalars.contains { $0.value == 0x1b })
        #expect(!input.text.unicodeScalars.contains { $0.value == 0x07 })
        #expect(input.text == "x[2J]0;pwnedy")

        // CR-separated payloads keep their line breaks rather than collapsing.
        input.clear()
        let second = input.beginDrop()
        input.resolveDrop(token: second, outcome: .rejected(rawText: "a\r\nb\rc", notice: ""))
        #expect(input.text == "a\nb\nc")
    }

    @Test("A seeded history entry cannot paint escape sequences on recall")
    func promptInputSeededHistoryStripsControlCharacters() {
        // Defence in depth: the store sanitizes on load, but the guarantee has to
        // live in the type that depends on it — a recalled entry goes into a live
        // terminal.
        let input = PromptInput()
        input.focused = true
        input.seedHistory(["evil\u{1b}[2Jtext"])
        _ = input.height(forWidth: 40, maxRows: 8)
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "evil[2Jtext")
        #expect(!input.text.unicodeScalars.contains { $0.value == 0x1b })
    }

    // MARK: History is recorded BY SUBMITTING — not only by replaying disk

    @Test("A submitted prompt is recalled by Up in the same session")
    func promptSubmitRecordsItsOwnHistory() {
        // Nothing here may call `seedHistory`: the disk-replay path was the only
        // one under test, so deleting `editor.addToHistory` from the submit path
        // left the whole suite green while a submitted prompt was recorded nowhere.
        let input = PromptInput()
        input.focused = true
        type(input, "remember me")
        input.handleInput(Self.enter)
        #expect(input.text.isEmpty)

        _ = input.height(forWidth: 40, maxRows: 8)
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "remember me", "the just-submitted prompt has to be one Up away")

        // And a second submit is the newer entry.
        input.handleInput(Self.enter)          // resubmits the recalled text
        type(input, "second thing")
        input.handleInput(Self.enter)
        _ = input.height(forWidth: 40, maxRows: 8)
        input.handleInput(ArrowKeys.up)
        #expect(input.text == "second thing")
    }

    @Test("onHistoryAdd fires exactly once per accepted submit, with the trimmed text")
    func promptSubmitNotifiesThePersistenceHookOnce() {
        let input = PromptInput()
        input.focused = true
        var added: [String] = []
        input.onHistoryAdd = { added.append($0) }

        type(input, "  keep me  ")
        input.handleInput(Self.enter)
        #expect(added == ["keep me"], "the store is fed the trimmed text, exactly once")

        // A bare Enter is not a message and must not reach the store.
        input.handleInput(Self.enter)
        #expect(added == ["keep me"])

        type(input, "another")
        input.handleInput(Self.enter)
        #expect(added == ["keep me", "another"])
    }

    @Test("An 8-bit CSI or OSC in a rejected drop never reaches the document")
    @MainActor
    func rejectedDropStripsEightBitControls() {
        // U+009B is CSI and U+009D is OSC in their 8-bit forms: an xterm-family
        // terminal in 8-bit mode acts on them directly, with no ESC to spot. The
        // payload here is one the user never typed — it is a drag or clipboard
        // payload being handed back verbatim — so the filter has to cover the range
        // the 7-bit check alone misses.
        let input = PromptInput()
        let token = input.beginDrop()
        input.resolveDrop(
            token: token,
            outcome: .rejected(rawText: "a\u{9b}2Jb\u{9d}0;titl\u{7}c", notice: "not an image")
        )
        #expect(input.text == "a2Jb0;titlc", "an 8-bit control reached the document: \(String(reflecting: input.text))")
    }
}

/// The arrow-key byte sequences, named once.
private enum ArrowKeys {
    static let up: [UInt8] = Array("\u{1b}[A".utf8)
    static let down: [UInt8] = Array("\u{1b}[B".utf8)

}
