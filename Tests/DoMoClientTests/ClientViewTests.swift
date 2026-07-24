// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The client's view components, asserted at the render/line level: what a pane
// draws for a given state, and how it responds to keys. The renderer pipeline
// itself (layout + alt-screen diff + cursor) is covered by DoMoTUI's oracle
// tests; here the concern is the client's own formatting and input handling.

import DoMoServer
import DoMoTUI
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

    @Test("The transcript marks roles and renders a tool header")
    func transcriptFormatting() {
        let view = TranscriptView()
        view.items = [
            .user("hi there"),
            .assistant("hello back"),
            .tool(name: "bash", output: "ok", isError: false, imageCount: 0),
        ]
        let lines = view.render(width: 40)
        #expect(lines.contains { $0.contains("›") && $0.contains("hi there") })
        #expect(lines.contains { $0.contains("hello back") })
        #expect(lines.contains { $0.contains("⚙") && $0.contains("bash") })
        // Every line fits the width budget.
        #expect(lines.allSatisfy { visibleWidth($0) <= 40 })
    }

    @Test("The prompt input accepts typing, shows a caret when focused, and submits on Enter")
    func promptInputTypeAndSubmit() {
        let input = PromptInput()
        input.focused = true
        var submitted: String?
        input.onSubmit = { submitted = $0 }

        for byte in Array("hey".utf8) { input.handleInput([byte]) }
        #expect(input.text == "hey")

        let line = input.render(width: 40)[0]
        #expect(line.contains("hey"))
        #expect(line.contains(cursorMarker))   // caret at the end while focused

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
        input.onSubmit = { submitted = $0 }
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
}
