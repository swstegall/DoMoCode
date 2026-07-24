// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported from pi's editor.test.ts (and the sticky-column / paste-marker slices in
// particular, which pi documents as the spec). Autocomplete-specific cases are
// omitted (separate slice). Cursor indices are Character indices, which coincide
// with pi's for the BMP inputs used here.

import DoMoTermIO
import Testing
@testable import DoMoTUI

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// Real key byte sequences.
private let up = bytes("\u{1b}[A")
private let down = bytes("\u{1b}[B")
private let left = bytes("\u{1b}[D")
private let right = bytes("\u{1b}[C")
private let ctrlA: [UInt8] = [0x01]
private let ctrlE: [UInt8] = [0x05]
private let backspace: [UInt8] = [0x7f]
private let deleteFwd = bytes("\u{1b}[3~")
private let ctrlW: [UInt8] = [0x17]
private let altD: [UInt8] = [0x1b, 0x64]
private let ctrlU: [UInt8] = [0x15]
private let ctrlK: [UInt8] = [0x0b]
private let ctrlY: [UInt8] = [0x19]
private let altY: [UInt8] = [0x1b, 0x79]
private let undo: [UInt8] = [0x1f]
private let enter: [UInt8] = [0x0d]
private let newline: [UInt8] = [0x0a]
private let ctrlLeft = bytes("\u{1b}[1;5D")
private let ctrlRight = bytes("\u{1b}[1;5C")
private let ctrlBracket: [UInt8] = [0x1d]
private let ctrlAltBracket: [UInt8] = [0x1b, 0x1d]

@MainActor
private func type(_ e: Editor, _ text: String) {
    for scalar in text { e.handleInput(Array(String(scalar).utf8)) }
}

@MainActor
private func paste(_ e: Editor, _ content: String) {
    e.handleInput(bytes("\u{1b}[200~\(content)\u{1b}[201~"))
}

/// A 20-line paste that produces a `[paste #N +20 lines]` marker.
@MainActor
private func pasteMarker(_ e: Editor) {
    paste(e, Array(repeating: "line", count: 20).joined(separator: "\n"))
}

private func stripANSI(_ s: String) -> String {
    var out = ""
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        if let len = ansiEscapeLengthTest(chars, i) { i += len; continue }
        out.append(chars[i]); i += 1
    }
    return out
}

// Minimal escape skipper for test assertions (CSI/OSC/APC).
private func ansiEscapeLengthTest(_ chars: [Character], _ pos: Int) -> Int? {
    guard pos < chars.count, chars[pos] == "\u{1b}", pos + 1 < chars.count else { return nil }
    let next = chars[pos + 1]
    if next == "[" {
        var j = pos + 2
        while j < chars.count, !("a"..."z" ~= chars[j]) && !("A"..."Z" ~= chars[j]) { j += 1 }
        return j < chars.count ? j + 1 - pos : nil
    }
    if next == "]" || next == "_" {
        var j = pos + 2
        while j < chars.count {
            if chars[j] == "\u{07}" { return j + 1 - pos }
            if chars[j] == "\u{1b}", j + 1 < chars.count, chars[j + 1] == "\\" { return j + 2 - pos }
            j += 1
        }
        return nil
    }
    return nil
}

@MainActor
@Suite("Editor")
struct EditorTests {
    // MARK: Prompt history

    @Test("Up on empty editor with history shows most recent")
    func historyBasic() {
        let e = Editor()
        e.addToHistory("first prompt")
        e.addToHistory("second prompt")
        e.handleInput(up)
        #expect(e.getText() == "second prompt")
    }

    @Test("Up does nothing when history empty")
    func historyEmpty() {
        let e = Editor()
        e.handleInput(up)
        #expect(e.getText() == "")
    }

    @Test("cycles and clamps at oldest")
    func historyCycle() {
        let e = Editor()
        e.addToHistory("first"); e.addToHistory("second"); e.addToHistory("third")
        e.handleInput(up); #expect(e.getText() == "third")
        e.handleInput(up); #expect(e.getText() == "second")
        e.handleInput(up); #expect(e.getText() == "first")
        e.handleInput(up); #expect(e.getText() == "first")
    }

    @Test("multi-line history entry: up places cursor at start, then older")
    func historyMultilineUp() {
        let e = Editor()
        e.addToHistory("older entry")
        e.addToHistory("line1\nline2\nline3")
        e.handleInput(up)
        #expect(e.getText() == "line1\nline2\nline3")
        #expect(e.getCursor() == (0, 0))
        e.handleInput(up)
        #expect(e.getText() == "older entry")
    }

    @Test("Down navigates forward and restores draft")
    func historyDraft() {
        let e = Editor()
        e.addToHistory("prompt")
        e.setText("draft")
        e.handleInput(left); e.handleInput(left)
        e.handleInput(up) // jumps to start of draft
        #expect(e.getText() == "draft")
        #expect(e.getCursor() == (0, 0))
        e.handleInput(up) // shows prompt
        #expect(e.getText() == "prompt")
        e.handleInput(down) // restores draft
        #expect(e.getText() == "draft")
    }

    @Test("Up moves cursor (not history) when editor has content")
    func historyNotWhenContent() {
        let e = Editor()
        e.addToHistory("history item")
        e.setText("line1\nline2")
        e.handleInput(up)
        type(e, "X")
        #expect(e.getText() == "line1X\nline2")
    }

    @Test("no empty or consecutive-dup entries")
    func historyFilters() {
        let e = Editor()
        e.addToHistory(""); e.addToHistory("   "); e.addToHistory("valid")
        e.handleInput(up); #expect(e.getText() == "valid")
        e.handleInput(up); #expect(e.getText() == "valid")
    }

    // MARK: Backslash + Enter

    @Test("backslash then Enter becomes a newline")
    func backslashEnter() {
        let e = Editor()
        type(e, "\\")
        e.handleInput(enter)
        #expect(e.getText() == "\n")
    }

    @Test("backslash followed by text submits normally")
    func backslashThenText() {
        let e = Editor()
        var submitted = false
        e.onSubmit = { _ in submitted = true }
        type(e, "\\"); type(e, "x")
        e.handleInput(enter)
        #expect(submitted)
    }

    @Test("only one backslash removed on Enter")
    func backslashMultiple() {
        let e = Editor()
        type(e, "\\\\\\")
        #expect(e.getText() == "\\\\\\")
        e.handleInput(enter)
        #expect(e.getText() == "\\\\\n")
    }

    // MARK: Unicode editing

    @Test("mixed ASCII, umlauts, emoji insert literally")
    func unicodeInsert() {
        let e = Editor()
        type(e, "Hello äöü 😀")
        #expect(e.getText() == "Hello äöü 😀")
    }

    @Test("single backspace deletes a whole emoji grapheme")
    func emojiBackspace() {
        let e = Editor()
        type(e, "😀👍")
        e.handleInput(backspace)
        #expect(e.getText() == "😀")
    }

    @Test("editing around a ZWJ family emoji never splits it")
    func zwjEmoji() {
        let e = Editor()
        type(e, "x👨‍👩‍👧y")
        e.handleInput(left) // before 'y'
        e.handleInput(backspace) // deletes whole family cluster
        #expect(e.getText() == "xy")
        // Re-insert and move across it with one arrow.
        e.setText("👨‍👩‍👧z")
        e.handleInput(ctrlA)
        e.handleInput(right) // over the whole family cluster
        type(e, "!")
        #expect(e.getText() == "👨‍👩‍👧!z")
    }

    @Test("cursor moves across emoji as single graphemes")
    func emojiCursor() {
        let e = Editor()
        type(e, "😀👍🎉")
        e.handleInput(left); e.handleInput(left)
        type(e, "x")
        #expect(e.getText() == "😀x👍🎉")
    }

    // MARK: Word deletion / navigation

    @Test("Ctrl+W word deletion across punctuation and lines")
    func ctrlWDeletion() {
        let e = Editor()
        e.setText("foo bar baz"); e.handleInput(ctrlW)
        #expect(e.getText() == "foo bar ")
        e.setText("foo bar   "); e.handleInput(ctrlW)
        #expect(e.getText() == "foo ")
        e.setText("foo bar..."); e.handleInput(ctrlW)
        #expect(e.getText() == "foo bar")
        e.setText("foo.bar"); e.handleInput(ctrlW)
        #expect(e.getText() == "foo.")
        e.setText("foo:bar"); e.handleInput(ctrlW)
        #expect(e.getText() == "foo:")
        e.setText("line one\nline two"); e.handleInput(ctrlW)
        #expect(e.getText() == "line one\nline ")
        e.setText("foo 😀😀 bar"); e.handleInput(ctrlW)
        #expect(e.getText() == "foo 😀😀 ")
        e.handleInput(ctrlW)
        #expect(e.getText() == "foo ")
    }

    @Test("Ctrl+Left/Right over punctuation")
    func wordNav() {
        let e = Editor()
        e.setText("foo bar... baz")
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 11))
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 7))
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 4))
        e.handleInput(ctrlRight); #expect(e.getCursor() == (0, 7))
        e.handleInput(ctrlRight); #expect(e.getCursor() == (0, 10))
        e.handleInput(ctrlRight); #expect(e.getCursor() == (0, 14))
    }

    @Test("stops at fullwidth Chinese punctuation")
    func cjkWordNav() {
        let e = Editor()
        e.setText("你好，世界")
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 3))
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 2))
        e.handleInput(ctrlLeft); #expect(e.getCursor() == (0, 0))
    }

    // MARK: Word wrapping (chunk-level)

    @Test("wordWrapLine wraps at word boundaries")
    func wrapWordBoundary() {
        let chunks = wordWrapLine("hello world test", 11)
        #expect(chunks.count == 2)
        #expect(chunks[0].text == "hello ")
        #expect(chunks[1].text == "world test")
    }

    @Test("wordWrapLine keeps trailing space at boundary")
    func wrapTrailingSpace() {
        let chunks = wordWrapLine("hello world test", 12)
        #expect(chunks[0].text == "hello world ")
        #expect(chunks[1].text == "test")
    }

    @Test("wordWrapLine force-breaks a long token")
    func wrapForceBreak() {
        let chunks = wordWrapLine("aaaaaaaaaaaa aaaa", 12)
        #expect(chunks[0].text == "aaaaaaaaaaaa")
        #expect(chunks[1].text == " aaaa")
    }

    @Test("wordWrapLine multi-space grouping")
    func wrapMultiSpace() {
        let chunks = wordWrapLine("Lorem ipsum dolor sit amet,    consectetur", 30)
        #expect(chunks.count == 2)
        #expect(chunks[0].text == "Lorem ipsum dolor sit ")
        #expect(chunks[1].text == "amet,    consectetur")
    }

    @Test("wordWrapLine force-break with wide char after word boundary preserves content")
    func wrapWideForceBreak() {
        let line = " " + String(repeating: "a", count: 186) + "你"
        let chunks = wordWrapLine(line, 187)
        for chunk in chunks { #expect(visibleWidth(chunk.text) <= 187) }
        let reconstructed = chunks.map { String(Array(line)[$0.startIndex..<$0.endIndex]) }.joined()
        #expect(reconstructed == line)
    }

    @Test("oversized atomic marker splits across chunks, content preserved")
    func wrapOversizedMarker() {
        let marker = "[paste #1 +20 lines]" // 20 chars
        let line = "A\(marker)B"
        let markers = [1..<(1 + marker.count)]
        let chunks = wordWrapLine(line, 10, markers: markers)
        for chunk in chunks { #expect(visibleWidth(chunk.text) <= 10) }
        let arr = Array(line)
        let reconstructed = chunks.map { String(arr[$0.startIndex..<$0.endIndex]) }.joined()
        #expect(reconstructed == line)
        #expect(chunks[0].text == "A")
    }

    // MARK: Render width safety (the fatal-width invariant)

    @Test("no rendered line exceeds the width, across content and widths")
    func renderWidthSafety() {
        let contents = [
            "Hello ✅ World",
            "✅✅✅✅✅✅",
            "日本語テスト",
            "Word1 Word2 Word3 Word4 Word5 Word6",
            "Check https://example.com/very/long/path/that/exceeds/width here",
            "😀👍🎉👨‍👩‍👧 mixed 世界 text",
        ]
        for content in contents {
            let e = Editor()
            e.setText(content)
            for width in [8, 10, 11, 15, 20, 30, 40] {
                for line in e.render(width: width) {
                    #expect(visibleWidth(line) <= width, "over width \(width): \(content)")
                }
            }
        }
    }

    @Test("CJK line wraps to exact width and splits correctly")
    func cjkWrap() {
        let e = Editor()
        e.setText("日本語テスト")
        let width = 10 + 1 // +1 reserved for cursor
        let lines = e.render(width: width)
        for i in 1..<(lines.count - 1) {
            #expect(visibleWidth(lines[i]) == width)
        }
        let content = lines[1..<(lines.count - 1)].map { stripANSI($0).trimmingTrailing() }
        #expect(content.count == 2)
        #expect(content[0] == "日本語テス")
        #expect(content[1] == "ト")
    }

    @Test("wide emoji at wrap boundary never overflows")
    func emojiWrapBoundary() {
        let e = Editor()
        e.setText("0123456789✅")
        for line in e.render(width: 11) {
            #expect(visibleWidth(line) <= 11)
        }
    }

    @Test("wrapping a wide grapheme narrower than its width terminates")
    func wideGraphemeNarrowerThanWidthTerminates() {
        // Regression: a single grapheme cluster wider than `maxWidth` (a width-2
        // CJK/emoji in a 1-column region) used to send `wordWrapLine` into an
        // infinite self-recursion (re-wrapping the same one-cluster text), a
        // stack-overflow crash that no `DoMoError` could catch. It must instead
        // emit the indivisible cluster as its own chunk and terminate.
        for content in ["你", "你好世界", "a你b好c", "😀テ"] {
            let chunks = wordWrapLine(Array(content), 1, [])
            // Reconstructs the source exactly (nothing lost or duplicated).
            #expect(chunks.map(\.text).joined() == content)
            // Every chunk is either within the width or a single indivisible
            // cluster (which cannot be made narrower).
            for c in chunks {
                #expect(visibleWidth(c.text) <= 1 || Array(c.text).count == 1)
            }
        }
    }

    @Test("Editor.render survives pathologically narrow widths with wide content")
    func renderTinyWidthsDoNotCrash() {
        // The layout width collapses to 1 at width 1-2 (and at width 3 once
        // paddingX squeezes the content region to a single column). A wide
        // grapheme there must not trap the renderer.
        for padding in [0, 2] {
            for w in [1, 2, 3] {
                let e = Editor(paddingX: padding)
                e.setText("日本語😀テ")
                _ = e.render(width: w) // must return, not stack-overflow
            }
        }
        #expect(Bool(true))
    }

    @Test("renders through the screen oracle with no over-wide cell rows")
    func oracleWidth() {
        let e = Editor()
        e.setText("日本語テスト hello 😀 world")
        let width = 12
        let lines = e.render(width: width)
        let oracle = ScreenOracle(rows: lines.count + 1, cols: width)
        oracle.feed(lines.joined(separator: "\r\n"))
        for r in 0..<lines.count {
            #expect(visibleWidth(oracle.row(r)) <= width)
        }
    }

    // MARK: Kill ring

    @Test("Ctrl+W kills and Ctrl+Y yanks")
    func killYank() {
        let e = Editor()
        e.setText("foo bar baz")
        e.handleInput(ctrlW)
        #expect(e.getText() == "foo bar ")
        e.handleInput(ctrlA)
        e.handleInput(ctrlY)
        #expect(e.getText() == "bazfoo bar ")
    }

    @Test("consecutive Ctrl+W accumulate into one entry")
    func killAccumulate() {
        let e = Editor()
        e.setText("one two three")
        e.handleInput(ctrlW); e.handleInput(ctrlW); e.handleInput(ctrlW)
        #expect(e.getText() == "")
        e.handleInput(ctrlY)
        #expect(e.getText() == "one two three")
    }

    @Test("Ctrl+U accumulates multiline deletes including newlines")
    func killMultiline() {
        let e = Editor()
        e.setText("line1\nline2\nline3")
        e.handleInput(ctrlU); #expect(e.getText() == "line1\nline2\n")
        e.handleInput(ctrlU); #expect(e.getText() == "line1\nline2")
        e.handleInput(ctrlU); #expect(e.getText() == "line1\n")
        e.handleInput(ctrlU); #expect(e.getText() == "line1")
        e.handleInput(ctrlU); #expect(e.getText() == "")
        e.handleInput(ctrlY); #expect(e.getText() == "line1\nline2\nline3")
    }

    @Test("Alt+Y cycles through kill ring after yank")
    func yankPopCycle() {
        let e = Editor()
        e.setText("first"); e.handleInput(ctrlW)
        e.setText("second"); e.handleInput(ctrlW)
        e.setText("third"); e.handleInput(ctrlW)
        #expect(e.getText() == "")
        e.handleInput(ctrlY); #expect(e.getText() == "third")
        e.handleInput(altY); #expect(e.getText() == "second")
        e.handleInput(altY); #expect(e.getText() == "first")
        e.handleInput(altY); #expect(e.getText() == "third")
    }

    @Test("non-delete action breaks accumulation")
    func killBreak() {
        let e = Editor()
        e.setText("foo bar baz")
        e.handleInput(ctrlW)
        type(e, "x")
        e.handleInput(ctrlW)
        #expect(e.getText() == "foo bar ")
        e.handleInput(ctrlY); #expect(e.getText() == "foo bar x")
        e.handleInput(altY); #expect(e.getText() == "foo bar baz")
    }

    @Test("Alt+D deletes word forward accumulating")
    func altDForward() {
        let e = Editor()
        e.setText("hello world test")
        e.handleInput(ctrlA)
        e.handleInput(altD); #expect(e.getText() == " world test")
        e.handleInput(altD); #expect(e.getText() == " test")
        e.handleInput(ctrlY); #expect(e.getText() == "hello world test")
    }

    // MARK: Undo

    @Test("coalesces word chars; spaces separately undoable")
    func undoCoalesce() {
        let e = Editor()
        type(e, "hello world")
        e.handleInput(undo); #expect(e.getText() == "hello")
        e.handleInput(undo); #expect(e.getText() == "")
    }

    @Test("cursor movement starts a new undo unit")
    func undoNewUnit() {
        let e = Editor()
        type(e, "hello world")
        for _ in 0..<5 { e.handleInput(left) }
        type(e, "lol")
        #expect(e.getText() == "hello lolworld")
        e.handleInput(undo)
        #expect(e.getText() == "hello world")
    }

    @Test("undo restores single- and multi-line pastes atomically")
    func undoPaste() {
        let e = Editor()
        e.setText("hello world")
        e.handleInput(ctrlA)
        for _ in 0..<5 { e.handleInput(right) }
        paste(e, "beep boop")
        #expect(e.getText() == "hellobeep boop world")
        e.handleInput(undo)
        #expect(e.getText() == "hello world")

        e.setText("hello world")
        e.handleInput(ctrlA)
        for _ in 0..<5 { e.handleInput(right) }
        paste(e, "line1\nline2\nline3")
        #expect(e.getText() == "helloline1\nline2\nline3 world")
        e.handleInput(undo)
        #expect(e.getText() == "hello world")
    }

    @Test("no-op deletes do not push undo snapshots")
    func undoNoop() {
        let e = Editor()
        type(e, "hello")
        e.handleInput(ctrlW); #expect(e.getText() == "")
        e.handleInput(ctrlW); e.handleInput(ctrlW)
        e.handleInput(undo)
        #expect(e.getText() == "hello")
    }

    @Test("submit clears undo stack")
    func undoSubmitClears() {
        let e = Editor()
        type(e, "hello")
        e.handleInput(enter)
        #expect(e.getText() == "")
        e.handleInput(undo)
        #expect(e.getText() == "")
    }

    // MARK: Character jump

    @Test("jump forward and backward to a character")
    func charJump() {
        let e = Editor()
        e.setText("hello world")
        e.handleInput(ctrlA)
        e.handleInput(ctrlBracket); type(e, "o")
        #expect(e.getCursor() == (0, 4))
        e.handleInput(ctrlBracket); type(e, "o")
        #expect(e.getCursor() == (0, 7))
        e.handleInput(ctrlAltBracket); type(e, "h")
        #expect(e.getCursor() == (0, 0))
    }

    @Test("jump across lines and no-op when not found")
    func charJumpLines() {
        let e = Editor()
        e.setText("abc\ndef\nghi")
        e.handleInput(up); e.handleInput(up); e.handleInput(ctrlA)
        e.handleInput(ctrlBracket); type(e, "g")
        #expect(e.getCursor() == (2, 0))
        e.handleInput(ctrlBracket); type(e, "z")
        #expect(e.getCursor() == (2, 0))
    }

    @Test("jump mode cancels when hotkey pressed again")
    func charJumpCancel() {
        let e = Editor()
        e.setText("hello world")
        e.handleInput(ctrlA)
        e.handleInput(ctrlBracket); e.handleInput(ctrlBracket)
        type(e, "o")
        #expect(e.getText() == "ohello world")
    }

    // MARK: Sticky column

    @Test("preserves target column moving up through a shorter line")
    func stickyUp() {
        let e = Editor()
        e.setText("2222222222x222\n\n1111111111_111111111111")
        #expect(e.getCursor() == (2, 23))
        e.handleInput(ctrlA)
        for _ in 0..<10 { e.handleInput(right) }
        #expect(e.getCursor() == (2, 10))
        e.handleInput(up); #expect(e.getCursor() == (1, 0))
        e.handleInput(up); #expect(e.getCursor() == (0, 10))
    }

    @Test("preserves target column moving down through a shorter line")
    func stickyDown() {
        let e = Editor()
        e.setText("1111111111_111\n\n2222222222x222222222222")
        e.handleInput(up); e.handleInput(up)
        e.handleInput(ctrlA)
        for _ in 0..<10 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 10))
        e.handleInput(down); #expect(e.getCursor() == (1, 0))
        e.handleInput(down); #expect(e.getCursor() == (2, 10))
    }

    @Test("horizontal movement resets sticky column")
    func stickyResetHorizontal() {
        let e = Editor()
        e.setText("1234567890\n\n1234567890")
        e.handleInput(ctrlA)
        for _ in 0..<5 { e.handleInput(right) }
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 5))
        e.handleInput(left); #expect(e.getCursor() == (0, 4))
        e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor() == (2, 4))
    }

    @Test("typing resets sticky column")
    func stickyResetTyping() {
        let e = Editor()
        e.setText("1234567890\n\n1234567890")
        e.handleInput(ctrlA)
        for _ in 0..<8 { e.handleInput(right) }
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 8))
        type(e, "X"); #expect(e.getCursor() == (0, 9))
        e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor() == (2, 9))
    }

    @Test("Ctrl+E resets sticky column to end")
    func stickyResetEnd() {
        let e = Editor()
        e.setText("12345\n\n1234567890")
        e.handleInput(ctrlA)
        for _ in 0..<3 { e.handleInput(right) }
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 3))
        e.handleInput(ctrlE); #expect(e.getCursor() == (0, 5))
        e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor() == (2, 5))
    }

    @Test("multiple consecutive up/down through ragged short lines")
    func stickyRagged() {
        let e = Editor()
        e.setText("1234567890\nab\ncd\nef\n1234567890")
        e.handleInput(ctrlA)
        for _ in 0..<7 { e.handleInput(right) }
        #expect(e.getCursor() == (4, 7))
        e.handleInput(up); e.handleInput(up); e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 7))
        e.handleInput(down); e.handleInput(down); e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor() == (4, 7))
    }

    @Test("undo resets sticky column")
    func stickyUndo() {
        let e = Editor()
        e.setText("1234567890\n\n1234567890")
        e.handleInput(up); e.handleInput(up)
        e.handleInput(ctrlA)
        for _ in 0..<8 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 8))
        e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor() == (2, 8))
        type(e, "X")
        #expect(e.getCursor() == (2, 9))
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 9))
        e.handleInput(undo)
        #expect(e.getText() == "1234567890\n\n1234567890")
        #expect(e.getCursor() == (2, 8))
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 8))
    }

    @Test("Right at end of last line sets preferred visual col")
    func stickyRightAtEnd() {
        let e = Editor()
        e.setText("111111111x1111111111\n\n333333333_")
        e.handleInput(up); e.handleInput(up)
        e.handleInput(ctrlE); #expect(e.getCursor() == (0, 20))
        e.handleInput(down); e.handleInput(down); #expect(e.getCursor() == (2, 10))
        e.handleInput(right); #expect(e.getCursor() == (2, 10))
        e.handleInput(up); e.handleInput(up); #expect(e.getCursor() == (0, 10))
    }

    @Test("resize: preferred col clamped, then restored on same line")
    func stickyResizeSame() {
        let e = Editor(rows: { 24 })
        e.setText("12345678901234567890\n\n12345678901234567890")
        e.handleInput(ctrlA)
        for _ in 0..<15 { e.handleInput(right) }
        e.handleInput(up); e.handleInput(up)
        #expect(e.getCursor() == (0, 15))
        _ = e.render(width: 12)
        e.handleInput(down); e.handleInput(down)
        #expect(e.getCursor().col == 4)
    }

    @Test("rewrapped lines: target fits current visual column")
    func stickyRewrapFits() {
        let e = Editor()
        e.setText("abcdefghijklmnopqr\n123456789012345678")
        // position at line 0 col 18
        for _ in 0..<20 { e.handleInput(up) }
        e.handleInput(ctrlA)
        for _ in 0..<18 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 18))
        _ = e.render(width: 10)
        e.handleInput(down)
        #expect(e.getCursor() == (1, 8))
        _ = e.render(width: 80)
        e.handleInput(up)
        #expect(e.getCursor() == (0, 8))
        e.handleInput(down)
        #expect(e.getCursor() == (1, 8))
    }

    @Test("sticky column preserved across tabs (expanded to spaces)")
    func stickyTabs() {
        // Tabs normalize to 4 spaces; ragged lines still preserve the sticky col.
        let e = Editor()
        e.setText("a\tbcdefghij\n\n1\t23456789012")
        // "a" + 4 spaces + "bcdefghij" => 14 chars; second line similar length.
        e.handleInput(ctrlA)
        for _ in 0..<8 { e.handleInput(right) }
        #expect(e.getCursor() == (2, 8))
        e.handleInput(up); #expect(e.getCursor() == (1, 0))
        e.handleInput(up); #expect(e.getCursor() == (0, 8))
    }

    // MARK: Paste markers

    @Test("large paste creates a marker")
    func markerCreated() {
        let e = Editor()
        pasteMarker(e)
        #expect(e.getText().contains("[paste #1 +20 lines]"))
    }

    @Test("marker atomic for right/left arrow")
    func markerArrows() {
        let e = Editor()
        type(e, "A"); pasteMarker(e); type(e, "B")
        let markerLen = "[paste #1 +20 lines]".count
        e.handleInput(ctrlA)
        e.handleInput(right); #expect(e.getCursor() == (0, 1))
        e.handleInput(right); #expect(e.getCursor() == (0, 1 + markerLen))
        e.handleInput(right); #expect(e.getCursor() == (0, 2 + markerLen))
        e.handleInput(left); #expect(e.getCursor() == (0, 1 + markerLen))
        e.handleInput(left); #expect(e.getCursor() == (0, 1))
        e.handleInput(left); #expect(e.getCursor() == (0, 0))
    }

    @Test("marker atomic for backspace and forward-delete")
    func markerDelete() {
        let e = Editor()
        type(e, "A"); pasteMarker(e); type(e, "B")
        let markerLen = "[paste #1 +20 lines]".count
        e.handleInput(ctrlA)
        e.handleInput(right); e.handleInput(right)
        #expect(e.getCursor() == (0, 1 + markerLen))
        e.handleInput(backspace)
        #expect(e.getText() == "AB")
        #expect(e.getCursor() == (0, 1))

        let e2 = Editor()
        type(e2, "A"); pasteMarker(e2); type(e2, "B")
        e2.handleInput(ctrlA); e2.handleInput(right)
        e2.handleInput(deleteFwd)
        #expect(e2.getText() == "AB")
        #expect(e2.getCursor() == (0, 1))
    }

    @Test("marker atomic for word movement")
    func markerWordNav() {
        let e = Editor()
        type(e, "X"); type(e, " "); pasteMarker(e); type(e, " "); type(e, "Y")
        let markerLen = "[paste #1 +20 lines]".count
        e.handleInput(ctrlA)
        e.handleInput(ctrlRight); #expect(e.getCursor() == (0, 1))
        e.handleInput(ctrlRight); #expect(e.getCursor() == (0, 2 + markerLen))
    }

    @Test("undo after marker backspace restores marker and registry")
    func markerUndoRegistry() {
        let e = Editor()
        var submitted = ""
        e.onSubmit = { submitted = $0 }
        let content = (0..<12).map { "alpha\($0)" }.joined(separator: "\n")
        paste(e, content)
        e.handleInput(backspace) // delete the marker
        e.handleInput(undo) // restore marker + registry
        e.handleInput(enter)
        #expect(submitted == content)
    }

    @Test("deleting first of two markers renumbers registry; undo restores both")
    func markerRenumberUndo() {
        let e = Editor()
        var submitted = ""
        e.onSubmit = { submitted = $0 }
        let a = (0..<12).map { "alpha\($0)" }.joined(separator: "\n")
        let b = (0..<12).map { "beta\($0)" }.joined(separator: "\n")
        paste(e, a) // #1
        paste(e, b) // #2
        e.handleInput(ctrlA)
        e.handleInput(right) // over marker #1
        e.handleInput(backspace) // delete #1, renumber #2 -> #1
        e.handleInput(undo)
        e.handleInput(enter)
        #expect(submitted == a + b)
    }

    @Test("renumbers registry in ascending id order when markers out of order")
    func markerRenumberOrder() {
        let e = Editor()
        var submitted = ""
        e.onSubmit = { submitted = $0 }
        let a = (0..<12).map { "alpha\($0)" }.joined(separator: "\n")
        let b = (0..<12).map { "beta\($0)" }.joined(separator: "\n")
        let c = (0..<12).map { "gamma\($0)" }.joined(separator: "\n")
        paste(e, a); e.handleInput(ctrlA) // [#1]
        paste(e, b); e.handleInput(ctrlA) // [#2][#1]
        paste(e, c) // [#3][#2][#1]
        e.handleInput(ctrlE)
        e.handleInput(backspace) // delete #1
        e.handleInput(enter)
        #expect(submitted == c + b)
    }

    @Test("manually typed marker-like text is not atomic")
    func markerFake() {
        let e = Editor()
        let fake = "[paste #99 +5 lines]"
        type(e, fake)
        #expect(e.getText() == fake)
        e.handleInput(ctrlA)
        e.handleInput(right)
        #expect(e.getCursor() == (0, 1))
    }

    @Test("wide marker in a narrow terminal does not overflow width")
    func markerNarrow() {
        let e = Editor()
        paste(e, Array(repeating: "line", count: 47).joined(separator: "\n"))
        for line in e.render(width: 8) {
            #expect(visibleWidth(line) <= 8)
        }
    }

    @Test("text + marker exceeding width with cursor on marker does not overflow")
    func markerCursorOverflow() {
        let e = Editor()
        for _ in 0..<35 { type(e, "b") }
        paste(e, Array(repeating: "line", count: 27).joined(separator: "\n"))
        for _ in 0..<4 { type(e, "b") }
        for _ in 0..<5 { e.handleInput(left) } // land on marker
        for line in e.render(width: 54) {
            #expect(visibleWidth(line) <= 54)
        }
    }

    @Test("expands large pasted content literally")
    func markerExpand() {
        let e = Editor()
        let content = [
            "line 1", "line 2", "line 3", "line 4", "line 5",
            "line 6", "line 7", "line 8", "line 9", "line 10",
            "tokens $1 $2 $& $$ end",
        ].joined(separator: "\n")
        paste(e, content)
        #expect(e.getText().contains("[paste #1 +11 lines]"))
        #expect(e.getExpandedText() == content)
    }

    @Test("submits large pasted content literally")
    func markerSubmit() {
        let e = Editor()
        var submitted = ""
        e.onSubmit = { submitted = $0 }
        let content = (0..<11).map { "line \($0)" }.joined(separator: "\n")
        paste(e, content)
        e.handleInput(enter)
        #expect(submitted == content)
    }

    @Test("snaps to marker start when navigating down into it")
    func markerSnapDown() {
        let e = Editor()
        e.setText("12345678901234567890\n\nhello ")
        paste(e, String(repeating: "x", count: 2000))
        _ = e.render(width: 80)
        e.handleInput(up); e.handleInput(up)
        e.handleInput(ctrlA)
        for _ in 0..<10 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 10))
        e.handleInput(down); #expect(e.getCursor() == (1, 0))
        e.handleInput(down); #expect(e.getCursor() == (2, 6))
    }

    // MARK: Viewport

    @Test("viewport shows N-more indicators when content overflows")
    func viewportIndicators() {
        // 16 rows -> maxVisibleLines = max(5, floor(16*0.3)) = 5.
        let e = Editor(rows: { 16 })
        e.setText((0..<12).map { "line\($0)" }.joined(separator: "\n"))
        // Cursor at last line; move to the top so content sits below.
        for _ in 0..<20 { e.handleInput(up) }
        var lines = e.render(width: 40)
        // Top border plain (no scroll), bottom shows "↓ N more".
        #expect(lines.last!.contains("more"))
        #expect(lines.last!.contains("↓"))
        // Now go to the bottom: top border should show "↑ N more".
        for _ in 0..<20 { e.handleInput(down) }
        lines = e.render(width: 40)
        #expect(lines.first!.contains("↑"))
        #expect(lines.first!.contains("more"))
        // Every rendered line fits.
        for line in lines { #expect(visibleWidth(line) <= 40) }
    }

    @Test("focused editor emits the cursor marker")
    func focusedMarker() {
        let e = Editor()
        e.focused = true
        type(e, "hi")
        let lines = e.render(width: 20)
        #expect(lines.contains { $0.contains(cursorMarker) })
    }

    @Test("unfocused editor does not emit the cursor marker")
    func unfocusedNoMarker() {
        let e = Editor()
        type(e, "hi")
        let lines = e.render(width: 20)
        #expect(!lines.contains { $0.contains(cursorMarker) })
    }

    // MARK: Sticky column — rewrap + multi-visual-line markers (hardest cases)

    @Test("rewrapped lines: target shorter than current visual column")
    func stickyRewrapShorter() {
        let e = Editor()
        e.setText("abcdefghijklmnopqr\n123456789012345678\nab")
        for _ in 0..<20 { e.handleInput(up) }
        e.handleInput(ctrlA)
        for _ in 0..<18 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 18))
        _ = e.render(width: 10)
        e.handleInput(down)
        #expect(e.getCursor() == (1, 8))
        _ = e.render(width: 80)
        e.handleInput(down)
        #expect(e.getCursor() == (2, 2))
        e.handleInput(up)
        #expect(e.getCursor() == (1, 8))
    }

    @Test("resize when preferred col is on a different line")
    func stickyResizeDifferentLine() {
        let e = Editor()
        e.setText("short\n12345678901234567890")
        e.handleInput(ctrlA)
        for _ in 0..<15 { e.handleInput(right) }
        #expect(e.getCursor() == (1, 15))
        e.handleInput(up)
        #expect(e.getCursor() == (0, 5))
        _ = e.render(width: 10)
        e.handleInput(down)
        #expect(e.getCursor() == (1, 8))
        e.handleInput(up)
        #expect(e.getCursor() == (0, 5))
        _ = e.render(width: 80)
        e.handleInput(down)
        #expect(e.getCursor() == (1, 15))
    }

    @Test("does not get stuck moving down from a multi-visual-line paste marker")
    func markerMultiVisualDown() {
        let e = Editor(rows: { 24 })
        type(e, "abcdefgh")
        paste(e, Array(repeating: "line", count: 100).joined(separator: "\n"))
        type(e, "ijklmnopqr")
        e.handleInput(newline)
        type(e, "123456789012345678")
        _ = e.render(width: 20)

        let markerLen = "[paste #1 +100 lines]".count // 21
        let markerStart = 8
        let markerEnd = markerStart + markerLen

        e.handleInput(up) // to line 0
        e.handleInput(ctrlA)
        for _ in 0..<6 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 6))
        e.handleInput(down); #expect(e.getCursor() == (0, markerStart))
        e.handleInput(down)
        #expect(e.getCursor().line == 0)
        #expect(e.getCursor().col == markerEnd)
        e.handleInput(up); #expect(e.getCursor() == (0, markerStart))
        e.handleInput(up); #expect(e.getCursor() == (0, 6))
    }

    @Test("skips marker continuation VLs when preferred col falls in marker tail")
    func markerContinuationSkip() {
        let e = Editor(rows: { 24 })
        type(e, "abcdefgh")
        paste(e, Array(repeating: "line", count: 100).joined(separator: "\n"))
        type(e, "ijklmnopqr")
        e.handleInput(newline)
        type(e, "123456789012345678")
        _ = e.render(width: 20)

        e.handleInput(up)
        e.handleInput(ctrlA)
        for _ in 0..<3 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 3))
        e.handleInput(down); #expect(e.getCursor().col == 8)
        e.handleInput(down); #expect(e.getCursor() == (1, 3))
        e.handleInput(up); #expect(e.getCursor().col == 8)
        e.handleInput(up); #expect(e.getCursor() == (0, 3))
    }

    @Test("preserves sticky column when navigating through a paste marker line")
    func markerLineSticky() {
        let e = Editor(rows: { 24 })
        type(e, "1234567890123456")
        e.handleInput(newline); e.handleInput(newline)
        paste(e, String(repeating: "x", count: 2000))
        e.handleInput(newline); e.handleInput(newline)
        type(e, "abcdefghijklmnop")
        _ = e.render(width: 30)

        for _ in 0..<4 { e.handleInput(up) } // to line 0
        e.handleInput(ctrlA)
        for _ in 0..<10 { e.handleInput(right) }
        #expect(e.getCursor() == (0, 10))
        e.handleInput(down); #expect(e.getCursor() == (1, 0))
        e.handleInput(down); #expect(e.getCursor() == (2, 0)) // snapped to marker start
        e.handleInput(down); #expect(e.getCursor() == (3, 0))
        e.handleInput(down); #expect(e.getCursor() == (4, 10))
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var chars = Array(self)
        while let last = chars.last, last == " " { chars.removeLast() }
        return String(chars)
    }
}
