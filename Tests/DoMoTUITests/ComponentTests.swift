// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

@MainActor
@Suite("Components and primitives")
struct ComponentTests {
    // MARK: Container

    @Test("Container stacks its children's lines top to bottom")
    func containerStacks() {
        let container = Container()
        container.addChild(LinesComponent(["a", "b"]))
        container.addChild(LinesComponent(["c"]))
        #expect(container.render(width: 10) == ["a", "b", "c"])
    }

    @Test("Container removeChild and clear drop children")
    func containerMutation() {
        let container = Container()
        let first = LinesComponent(["a"])
        let second = LinesComponent(["b"])
        container.addChild(first)
        container.addChild(second)
        container.removeChild(first)
        #expect(container.render(width: 10) == ["b"])
        container.clear()
        #expect(container.render(width: 10) == [])
    }

    // MARK: Text

    @Test("Text keeps a short line intact")
    func textShort() {
        #expect(Text("hello").render(width: 20) == ["hello"])
    }

    @Test("Text word-wraps a long line to the width")
    func textWraps() {
        let lines = Text("the quick brown fox").render(width: 10)
        for line in lines { #expect(visibleWidth(line) <= 10) }
        #expect(lines == ["the quick", "brown fox"])
    }

    @Test("Text honours embedded newlines")
    func textNewlines() {
        #expect(Text("a\nb\nc").render(width: 10) == ["a", "b", "c"])
    }

    @Test("Text in no-wrap mode truncates with an ellipsis")
    func textTruncates() {
        let lines = Text("this is a very long line", wrap: false).render(width: 10)
        #expect(lines.count == 1)
        #expect(visibleWidth(lines[0]) <= 10)
        // The ellipsis is present (a trailing zero-width SGR reset follows it).
        #expect(lines[0].contains("..."))
    }

    @Test("Text preserves ANSI styling across a wrap")
    func textStyledWrap() {
        // A bold run spanning the wrap point should reopen bold on the next line.
        let bold = "\u{1b}[1m"
        let lines = Text("\(bold)alpha beta gamma").render(width: 8)
        #expect(lines.count >= 2)
        // The continuation line re-emits the active SGR code.
        #expect(lines[1].contains("\u{1b}[1m"))
    }

    // MARK: Spacer

    @Test("Spacer emits blank lines")
    func spacer() {
        #expect(Spacer(lines: 3).render(width: 10) == ["", "", ""])
        #expect(Spacer(lines: 0).render(width: 10) == [])
    }

    // MARK: Box

    @Test("Box frames a child with a border of exactly the given width")
    func boxBorderWidth() {
        let box = Box(Text("hi"), paddingX: 1, paddingY: 0)
        let lines = box.render(width: 10)
        for line in lines { #expect(visibleWidth(line) == 10) }
        #expect(lines.first?.hasPrefix("\u{250C}") == true) // top-left corner
        #expect(lines.first?.hasSuffix("\u{2510}") == true) // top-right corner
        #expect(lines.last?.hasPrefix("\u{2514}") == true) // bottom-left corner
    }

    @Test("Box renders its child inside the frame")
    func boxContent() throws {
        let oracle = ScreenOracle(rows: 4, cols: 12)
        let target = CaptureTarget(columns: 12, rows: 4)
        let tui = TUI(target: target)
        tui.addChild(Box(Text("hi"), paddingX: 1, paddingY: 0))
        try oracle.drive(tui, from: target)

        // Row 0 is the top border, row 1 holds "hi" inside the border + padding.
        #expect(oracle.cell(col: 0, row: 1)?.character == "\u{2502}") // left border
        #expect(oracle.cell(col: 2, row: 1)?.character == "h") // after 1 pad
        #expect(oracle.cell(col: 3, row: 1)?.character == "i")
        #expect(oracle.cell(col: 11, row: 1)?.character == "\u{2502}") // right border
    }

    @Test("Box vertical padding adds blank inner rows")
    func boxVerticalPadding() {
        let box = Box(Text("x"), paddingX: 1, paddingY: 1)
        let lines = box.render(width: 8)
        // top border + pad row + content + pad row + bottom border = 5 lines.
        #expect(lines.count == 5)
        for line in lines { #expect(visibleWidth(line) == 8) }
    }

    // MARK: Component defaults

    @Test("A default component ignores input and key releases")
    func componentDefaults() {
        let component = LinesComponent(["x"])
        #expect(component.wantsKeyRelease == false)
        component.handleInput([0x61]) // no-op, must not crash
        component.invalidate() // no-op
    }
}
