// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

// MARK: - Helpers

/// Strip ANSI/OSC/APC escapes so a test can assert on the visible text a
/// terminal would show. Mirrors the width engine's notion of an escape.
private func stripAnsi(_ line: String) -> String {
    var out = ""
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        if chars[i] == "\u{1b}", i + 1 < chars.count {
            let next = chars[i + 1]
            if next == "[" {
                i += 2
                while i < chars.count, !("a"..."z" ~= chars[i]) && !("A"..."Z" ~= chars[i]) { i += 1 }
                if i < chars.count { i += 1 }
                continue
            }
            if next == "]" || next == "_" {
                i += 2
                while i < chars.count {
                    if chars[i] == "\u{07}" { i += 1; break }
                    if chars[i] == "\u{1b}", i + 1 < chars.count, chars[i + 1] == "\\" { i += 2; break }
                    i += 1
                }
                continue
            }
        }
        out.append(chars[i])
        i += 1
    }
    return out
}

/// Assert every rendered line fits its width budget — the fatal-width invariant.
private func expectFits(_ lines: [String], width: Int, _ label: String) {
    for line in lines {
        #expect(visibleWidth(line) <= width, "\(label): line over \(width): \(visibleWidth(line)) — \(stripAnsi(line).debugDescription)")
    }
}

/// The rendered lines joined into one string for substring assertions.
private func joined(_ lines: [String]) -> String { lines.joined(separator: "\n") }

// SGR fragments the styling emits.
private let boldOpen = "\u{1b}[1m"
private let italicOpen = "\u{1b}[3m"
private let underlineOpen = "\u{1b}[4m"
private let strikeOpen = "\u{1b}[9m"

@MainActor
@Suite("Markdown")
struct MarkdownTests {
    // MARK: Per-element styling + fit

    @Test("A heading renders bold and coloured and fits the width")
    func heading() {
        let lines = Markdown("# Hello World").render(width: 30)
        expectFits(lines, width: 30, "heading")
        let text = joined(lines)
        #expect(text.contains(boldOpen))
        #expect(text.contains(underlineOpen)) // h1 underlines
        #expect(stripAnsi(text).contains("# Hello World"))
    }

    @Test("Bold, italic, and inline code each emit their SGR and fit")
    func inlineEmphasis() {
        let lines = Markdown("Text **bold** then *italic* then `code` end.").render(width: 50)
        expectFits(lines, width: 50, "inline")
        let text = joined(lines)
        #expect(text.contains(boldOpen))
        #expect(text.contains(italicOpen))
        #expect(text.contains("\u{1b}[33m")) // inline code fg
        let visible = stripAnsi(text)
        #expect(visible.contains("bold"))
        #expect(visible.contains("italic"))
        #expect(visible.contains("code"))
    }

    @Test("A fenced code block shows its language label and indents content")
    func fencedCodeWithLanguage() {
        let lines = Markdown("```swift\nlet x = 1\nprint(x)\n```").render(width: 24)
        expectFits(lines, width: 24, "code")
        let visible = lines.map(stripAnsi)
        // A language-labelled opening fence.
        #expect(visible.contains { $0.contains("```swift") })
        // Content indented by two spaces.
        #expect(visible.contains { $0.hasPrefix("  let x = 1") })
        #expect(visible.contains { $0.hasPrefix("  print(x)") })
        // A closing fence with no language.
        #expect(visible.contains { stripAnsi($0).trimmingCharacters == "```" })
    }

    @Test("A block quote draws a border and fits the width")
    func blockQuote() {
        let lines = Markdown("> quoted words here that are long").render(width: 16)
        expectFits(lines, width: 16, "quote")
        #expect(lines.allSatisfy { stripAnsi($0).isEmpty || stripAnsi($0).hasPrefix("\u{2502} ") })
        #expect(joined(lines).contains("\u{1b}[2;3m")) // quote content dim+italic
    }

    @Test("A horizontal rule fills the width without overrunning it")
    func horizontalRule() {
        for width in [10, 20, 100] {
            let lines = Markdown("above\n\n---\n\nbelow").render(width: width)
            expectFits(lines, width: width, "hr")
            #expect(lines.contains { stripAnsi($0).contains("\u{2500}\u{2500}\u{2500}") })
        }
    }

    @Test("A link shows its text and URL when they differ")
    func linkWithUrl() {
        let lines = Markdown("Visit [Pi](https://example.com) today.").render(width: 60)
        expectFits(lines, width: 60, "link")
        let visible = stripAnsi(joined(lines))
        #expect(visible.contains("Pi"))
        #expect(visible.contains("(https://example.com)"))
        #expect(joined(lines).contains("\u{1b}[34;4m")) // link blue + underlined
    }

    @Test("A hyperlink-mode link hides the URL behind OSC 8")
    func linkOsc8() {
        let md = Markdown("Visit [Pi](https://example.com) today.", useHyperlinks: true)
        let lines = md.render(width: 60)
        expectFits(lines, width: 60, "osc8")
        let text = joined(lines)
        #expect(text.contains("\u{1b}]8;;https://example.com\u{07}")) // OSC 8 open
        #expect(!stripAnsi(text).contains("(https://example.com)")) // URL not printed inline
    }

    // MARK: Lists

    @Test("A nested list indents each level and fits the width")
    func nestedList() {
        let source = """
        - top one
          - child a
          - child b
        - top two
        """
        let lines = Markdown(source).render(width: 24)
        expectFits(lines, width: 24, "nested")
        let visible = lines.map { stripAnsi($0).trimmingTrailingSpaces }
        #expect(visible.contains { $0 == "- top one" })
        #expect(visible.contains { $0 == "    - child a" })
        #expect(visible.contains { $0 == "    - child b" })
        #expect(visible.contains { $0 == "- top two" })
    }

    @Test("An ordered list numbers items from the source start")
    func orderedList() {
        let lines = Markdown("3. three\n4. four\n5. five").render(width: 20)
        expectFits(lines, width: 20, "ordered")
        let visible = lines.map { stripAnsi($0).trimmingTrailingSpaces }
        #expect(visible.contains { $0 == "3. three" })
        #expect(visible.contains { $0 == "4. four" })
        #expect(visible.contains { $0 == "5. five" })
    }

    @Test("A task list renders checkboxes")
    func taskList() {
        let lines = Markdown("- [x] done\n- [ ] todo").render(width: 20)
        expectFits(lines, width: 20, "task")
        let visible = lines.map { stripAnsi($0).trimmingTrailingSpaces }
        #expect(visible.contains { $0 == "- [x] done" })
        #expect(visible.contains { $0 == "- [ ] todo" })
    }

    // MARK: CJK / emoji width

    @Test("A CJK and emoji paragraph wraps with no over-wide line")
    func cjkEmojiWrap() {
        let source = "你好世界你好世界你好世界 mixed 😀😀😀😀 latin tail words here"
        for width in [6, 8, 11, 12, 20] {
            let lines = Markdown(source).render(width: width)
            expectFits(lines, width: width, "cjk@\(width)")
            #expect(!lines.isEmpty)
        }
    }

    @Test("Padding never pushes a line over the width, even with CJK content")
    func cjkWithPadding() {
        let source = "你好世界你好世界 tail"
        for width in [6, 10, 16] {
            let lines = Markdown(source, paddingX: 2, paddingY: 1).render(width: width)
            expectFits(lines, width: width, "cjk-pad@\(width)")
        }
    }

    // MARK: Streaming anti-flicker

    @Test("A buffer ending mid-fence renders as an open code block, not raw backticks")
    func streamingPartialFence() {
        let streaming = Markdown("```python\nprint(1)\nprint(2)\n``")
        let lines = streaming.render(width: 24)
        expectFits(lines, width: 24, "streaming")
        let visible = lines.map { stripAnsi($0).trimmingCharacters }
        // The partial closing fence must not surface as a code content line.
        #expect(!visible.contains("``"))
        // The real content is still there.
        #expect(visible.contains { $0 == "print(1)" })
        #expect(visible.contains { $0 == "print(2)" })
        // And it reads as a code block (a fence line is present).
        #expect(visible.contains { $0.hasPrefix("```") })
    }

    @Test("Streaming content is stable when the closing fence completes")
    func streamingStableAcrossCompletion() {
        // The partial buffer and the completed buffer render the same code rows,
        // which is the anti-flicker guarantee: no shrink/flash on the last char.
        let partial = Markdown("```js\nconst a = 1\n``").render(width: 24).map { stripAnsi($0).trimmingCharacters }
        let complete = Markdown("```js\nconst a = 1\n```").render(width: 24).map { stripAnsi($0).trimmingCharacters }
        #expect(partial.contains { $0 == "const a = 1" })
        #expect(complete.contains { $0 == "const a = 1" })
        #expect(!partial.contains("``"))
    }

    @Test("An unterminated fence with no partial closer still renders as code")
    func streamingUnterminated() {
        let lines = Markdown("```\nsome code line\nmore code").render(width: 30)
        expectFits(lines, width: 30, "unterminated")
        let visible = lines.map { stripAnsi($0).trimmingCharacters }
        #expect(visible.contains { $0 == "some code line" })
        #expect(visible.contains { $0 == "more code" })
    }

    // MARK: Strict strikethrough

    @Test("Strikethrough is strict: double tilde strikes, single tilde is literal")
    func strictStrikethrough() {
        let lines = Markdown("a ~~struck~~ b ~single~ c").render(width: 40)
        expectFits(lines, width: 40, "strike")
        let text = joined(lines)
        // The double-tilde span is actually struck.
        #expect(text.contains(strikeOpen))
        #expect(text.contains("\(strikeOpen)struck"))
        // The single-tilde span keeps its literal tildes and is not struck.
        let visible = stripAnsi(text)
        #expect(visible.contains("~single~"))
        // "single" must not be wrapped by a strike open immediately before it.
        #expect(!text.contains("\(strikeOpen)single"))
    }

    // MARK: Re-wrap and invalidate

    @Test("render re-wraps to the current width")
    func reWrap() {
        let md = Markdown("one two three four five six seven eight nine ten")
        let narrow = md.render(width: 12)
        let wide = md.render(width: 60)
        expectFits(narrow, width: 12, "narrow")
        expectFits(wide, width: 60, "wide")
        #expect(narrow.count > wide.count) // narrower wraps to more rows
    }

    @Test("setText invalidates the cache and renders the new text")
    func setTextInvalidates() {
        let md = Markdown("first")
        #expect(stripAnsi(joined(md.render(width: 20))).contains("first"))
        md.setText("second")
        let updated = stripAnsi(joined(md.render(width: 20)))
        #expect(updated.contains("second"))
        #expect(!updated.contains("first"))
    }

    @Test("Empty or blank text renders nothing")
    func emptyText() {
        #expect(Markdown("").render(width: 20).isEmpty)
        #expect(Markdown("   \n  \t ").render(width: 20).isEmpty)
    }

    @Test("A negative padding assigned after construction never traps the render")
    func negativePaddingDoesNotTrap() {
        // The init clamps padding to >= 0, but the public vars are mutable; a
        // caller wiring a computed inset that goes negative must not trap
        // `String(repeating:count:)` (paddingX) or `0..<paddingY` (paddingY).
        let md = Markdown("hello world")
        md.paddingX = -3
        md.paddingY = -2
        let lines = md.render(width: 20)
        #expect(!lines.isEmpty)
        expectFits(lines, width: 20, "neg-padding")
        // Clamped to zero, so the render matches a zero-padding render.
        #expect(md.paddingX == 0)
        #expect(md.paddingY == 0)
        #expect(lines == Markdown("hello world").render(width: 20))
    }

    @Test("Mutating an output-determining property invalidates the cache")
    func propertyMutationInvalidatesCache() {
        // paddingX, useHyperlinks, and streaming all shape the output; changing
        // any of them after a render at the same width must not return stale
        // cached lines.
        let padded = Markdown("hello")
        let bare = padded.render(width: 20)
        padded.paddingX = 4
        #expect(padded.render(width: 20) != bare)

        let link = Markdown("[Pi](https://example.com)")
        _ = link.render(width: 40)
        link.useHyperlinks = true
        #expect(joined(link.render(width: 40)).contains("\u{1b}]8;;"))
    }

    // MARK: Oracle

    @Test("Rich markdown through the screen oracle: every row fits the width")
    func throughOracle() throws {
        let source = """
        # Heading

        A paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).

        - list item one
          - nested item
        - item two 你好世界

        > a quoted line

        ```swift
        let value = 42
        ```

        ---
        """
        let width = 40
        let md = Markdown(source, paddingX: 1)
        let rendered = md.render(width: width)
        expectFits(rendered, width: width, "oracle-source")

        let rows = max(rendered.count + 2, 4)
        let oracle = ScreenOracle(rows: rows, cols: width)
        let target = CaptureTarget(columns: width, rows: rows)
        let tui = TUI(target: target)
        tui.addChild(md)
        try oracle.drive(tui, from: target)
        for r in 0..<rows {
            #expect(visibleWidth(oracle.row(r)) <= width, "oracle row \(r) over width: \(oracle.row(r).debugDescription)")
        }
        // Content the emulator actually painted.
        let screen = oracle.screen.joined(separator: "\n")
        #expect(screen.contains("Heading"))
        #expect(screen.contains("let value = 42"))
    }

    @Test("A wide-glyph line through the oracle never claims an extra column")
    func cjkThroughOracle() throws {
        let width = 12
        let md = Markdown("你好世界你好世界你好世界 tail")
        let rendered = md.render(width: width)
        expectFits(rendered, width: width, "cjk-oracle-source")

        let rows = max(rendered.count + 1, 4)
        let oracle = ScreenOracle(rows: rows, cols: width)
        let target = CaptureTarget(columns: width, rows: rows)
        let tui = TUI(target: target)
        tui.addChild(md)
        try oracle.drive(tui, from: target)
        for r in 0..<rows {
            #expect(visibleWidth(oracle.row(r)) <= width)
        }
    }
}

// MARK: - Small string helper for the tests

private extension String {
    /// Trailing/leading ASCII-space trim, enough for the assertions here.
    var trimmingCharacters: String {
        var chars = Array(self)
        while let first = chars.first, first == " " { chars.removeFirst() }
        while let last = chars.last, last == " " { chars.removeLast() }
        return String(chars)
    }

    /// Trailing-only space trim, so list indent on the left is preserved.
    var trimmingTrailingSpaces: String {
        var chars = Array(self)
        while let last = chars.last, last == " " { chars.removeLast() }
        return String(chars)
    }
}
