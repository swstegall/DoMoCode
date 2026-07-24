// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing
@testable import DoMoTUI

// Real byte sequences for the Input keybindings, exercising the DoMoTermIO
// decoder rather than a stand-in.
private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
private let leftBytes = ascii("\u{1b}[D")
private let rightBytes = ascii("\u{1b}[C")
private let homeBytes: [UInt8] = [0x01] // ctrl+a
private let endBytes: [UInt8] = [0x05] // ctrl+e
private let backspaceBytes: [UInt8] = [0x7f]
private let deleteFwdBytes = ascii("\u{1b}[3~")
private let wordLeftBytes: [UInt8] = [0x1b, 0x62] // alt+b
private let wordRightBytes: [UInt8] = [0x1b, 0x66] // alt+f
private let delWordBackBytes: [UInt8] = [0x17] // ctrl+w
private let delWordFwdBytes: [UInt8] = [0x1b, 0x64] // alt+d
private let killToStartBytes: [UInt8] = [0x15] // ctrl+u
private let killToEndBytes: [UInt8] = [0x0b] // ctrl+k
private let yankBytes: [UInt8] = [0x19] // ctrl+y
private let yankPopBytes: [UInt8] = [0x1b, 0x79] // alt+y
private let undoBytes: [UInt8] = [0x1f] // ctrl+-
private let enterBytes: [UInt8] = [0x0d]
private let escBytes: [UInt8] = [0x1b]

@MainActor
private func type(_ input: Input, _ text: String) {
    for scalar in text {
        input.handleInput(Array(String(scalar).utf8))
    }
}

@MainActor
@Suite("Input")
struct InputTests {
    // MARK: Insertion & cursor motion

    @Test("Typing inserts characters and advances the cursor")
    func typing() {
        let input = Input()
        type(input, "hello")
        #expect(input.getValue() == "hello")
        #expect(input.cursorIndex == 5)
    }

    @Test("Left/right move by one grapheme; insertion happens at the cursor")
    func cursorMotion() {
        let input = Input()
        type(input, "helo")
        input.handleInput(leftBytes) // between 'l' and 'o'
        type(input, "l") // "hello"
        #expect(input.getValue() == "hello")
        input.handleInput(rightBytes) // past 'o' (end)
        type(input, "!")
        #expect(input.getValue() == "hello!")
    }

    @Test("Home and End jump to the ends")
    func homeEnd() {
        let input = Input()
        type(input, "world")
        input.handleInput(homeBytes)
        #expect(input.cursorIndex == 0)
        type(input, "> ")
        #expect(input.getValue() == "> world")
        input.handleInput(endBytes)
        type(input, "!")
        #expect(input.getValue() == "> world!")
    }

    // MARK: Deletion

    @Test("Backspace deletes before the cursor; forward-delete deletes after")
    func deletion() {
        let input = Input()
        type(input, "abcd")
        input.handleInput(backspaceBytes) // "abc"
        #expect(input.getValue() == "abc")
        input.handleInput(homeBytes)
        input.handleInput(deleteFwdBytes) // delete 'a' -> "bc"
        #expect(input.getValue() == "bc")
        #expect(input.cursorIndex == 0)
    }

    @Test("A grapheme cluster deletes as one unit")
    func graphemeDeletion() {
        let input = Input()
        // Family emoji ZWJ sequence is one grapheme cluster.
        type(input, "x👨‍👩‍👧y")
        input.handleInput(leftBytes) // before 'y'
        input.handleInput(backspaceBytes) // deletes the whole family cluster
        #expect(input.getValue() == "xy")
    }

    // MARK: Word ops

    @Test("Word left/right move across word boundaries")
    func wordMotion() {
        let input = Input()
        type(input, "foo bar baz")
        input.handleInput(wordLeftBytes) // to start of "baz"
        type(input, "X")
        #expect(input.getValue() == "foo bar Xbaz")
        input.handleInput(homeBytes)
        input.handleInput(wordRightBytes) // to end of "foo"
        type(input, "Y")
        #expect(input.getValue() == "fooY bar Xbaz")
    }

    @Test("Delete-word-backward removes the previous word and kills it for yank")
    func deleteWordBackwardYank() {
        let input = Input()
        type(input, "hello world")
        input.handleInput(delWordBackBytes) // removes "world"
        #expect(input.getValue() == "hello ")
        input.handleInput(yankBytes) // yanks "world" back
        #expect(input.getValue() == "hello world")
    }

    @Test("Delete-word-forward removes the next word")
    func deleteWordForward() {
        let input = Input()
        type(input, "hello world")
        input.handleInput(homeBytes)
        input.handleInput(delWordFwdBytes) // removes "hello"
        #expect(input.getValue() == " world")
    }

    @Test("Kill-to-line-end and kill-to-line-start feed the kill ring")
    func killLineOps() {
        let input = Input()
        type(input, "hello world")
        input.handleInput(homeBytes)
        input.handleInput(killToEndBytes) // kills "hello world"
        #expect(input.getValue() == "")
        input.handleInput(yankBytes)
        #expect(input.getValue() == "hello world")

        input.handleInput(killToStartBytes) // cursor at end, kills all
        #expect(input.getValue() == "")
    }

    @Test("Yank-pop cycles through kill-ring entries")
    func yankPop() {
        let input = Input()
        // Two separate, non-accumulating kills produce two ring entries.
        type(input, "first")
        input.handleInput(killToStartBytes) // kill "first"
        type(input, "second")
        input.handleInput(homeBytes)
        input.handleInput(killToEndBytes) // kill "second" (fresh, not accumulating)
        // Ring now: ["first", "second"]. Yank pastes most recent ("second").
        input.handleInput(yankBytes)
        #expect(input.getValue() == "second")
        // Yank-pop replaces it with the older entry ("first").
        input.handleInput(yankPopBytes)
        #expect(input.getValue() == "first")
    }

    // MARK: Undo

    @Test("Undo reverts the last coalesced edit unit")
    func undo() {
        let input = Input()
        type(input, "hello")
        // The space press captures a snapshot of "hello" before inserting; the
        // following word coalesces into that same unit (pi's undo coalescing).
        input.handleInput(ascii(" "))
        type(input, "world")
        input.handleInput(undoBytes) // reverts the space + "world" back to "hello"
        #expect(input.getValue() == "hello")
    }

    // MARK: Submit / escape

    @Test("Enter submits and Escape cancels with the current value")
    func submitEscape() {
        let input = Input()
        var submitted: String?
        var escaped = false
        input.onSubmit = { submitted = $0 }
        input.onEscape = { escaped = true }
        type(input, "go")
        input.handleInput(enterBytes)
        #expect(submitted == "go")
        input.handleInput(escBytes)
        #expect(escaped)
    }

    // MARK: Rendering & horizontal scroll

    @Test("Rendered line always fits the width budget")
    func rendersWithinWidth() {
        let input = Input()
        type(input, String(repeating: "x", count: 200))
        for width in [3, 5, 12, 40, 80] {
            let lines = input.render(width: width)
            #expect(lines.count == 1)
            #expect(visibleWidth(lines[0]) <= width, "over budget at width \(width)")
        }
    }

    @Test("Horizontal scroll keeps the caret end visible for a long value")
    func horizontalScrollEnd() {
        let input = Input()
        type(input, "0123456789ABCDEFGHIJ") // 20 cols
        let lines = input.render(width: 12) // availableWidth 10
        #expect(lines.count == 1)
        #expect(visibleWidth(lines[0]) <= 12)
        // Cursor is at the end, so the tail must be visible and the head scrolled off.
        #expect(lines[0].contains("J"))
        #expect(!lines[0].contains("0123"))
    }

    @Test("Horizontal scroll centres a mid-string caret")
    func horizontalScrollMiddle() {
        let input = Input()
        type(input, "0123456789ABCDEFGHIJ")
        input.handleInput(homeBytes)
        for _ in 0..<10 { input.handleInput(rightBytes) } // caret at column 10
        let lines = input.render(width: 12)
        #expect(visibleWidth(lines[0]) <= 12)
        // Neither the extreme head nor the extreme tail is shown when centred.
        #expect(!lines[0].contains("0"))
        #expect(!lines[0].contains("J"))
    }

    @Test("A focused input emits the cursor marker and drives the hardware cursor")
    func focusedCursorMarker() throws {
        let input = Input()
        type(input, "hi")
        input.handleInput(homeBytes) // caret at column 0

        let oracle = ScreenOracle(rows: 3, cols: 20)
        let target = CaptureTarget(columns: 20, rows: 3)
        let tui = TUI(target: target, showHardwareCursor: true)
        tui.addChild(input)
        tui.setFocus(input)
        try oracle.drive(tui, from: target)

        // "> hi" is drawn; the hardware cursor parks on the prompt+caret column 2.
        #expect(oracle.row(0).hasPrefix("> hi"))
        #expect(oracle.cursor == (2, 0))
        // The line still fits the terminal width.
        #expect(visibleWidth(oracle.row(0)) <= 20)
    }

    // MARK: setValue

    @Test("setValue replaces the buffer and clamps the cursor")
    func setValueClamps() {
        let input = Input()
        type(input, "abcdefgh")
        input.setValue("xy")
        #expect(input.getValue() == "xy")
        #expect(input.cursorIndex <= 2)
    }
}
