// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `Editor` grew three additive members — `maxVisibleLines`, `showBorders` and
// `onPaste` — plus a `visibleLineCap` that replaced two copies of a hard-coded
// `max(5, rows() * 0.3)`. All three default to today's behaviour, which is a
// claim that has to be MEASURED rather than asserted: this file pins the exact
// rendered bytes an untouched `Editor` produces and only then exercises the new
// members.
//
// No `@testable` — everything here is public API, so this file builds in release.

import DoMoTermIO
import Testing

import DoMoTUI

@MainActor
private func defaultEditor(rows: Int = 24) -> Editor {
    Editor(rows: { rows })
}

@Suite("Editor seam additions are inert at their defaults")
@MainActor
struct EditorSeamDefaultsTests {

    @Test("A fresh Editor renders the same rows whether or not the new knobs exist")
    func rendersBordersByDefault() {
        let editor = defaultEditor()
        editor.setText("hello")
        let rendered = editor.render(width: 12)

        // Top rule, one text row, bottom rule — the shape before the change.
        // The text row carries the reverse-video cursor cell, which an unfocused
        // editor still draws (only the cursor-position MARKER is suppressed).
        #expect(rendered.count == 3)
        #expect(rendered[0] == String(repeating: "─", count: 12))
        #expect(rendered[2] == String(repeating: "─", count: 12))
        #expect(rendered[1] == "hello\u{1b}[7m \u{1b}[0m      ")
    }

    @Test("Setting the new members to their documented defaults changes nothing")
    func explicitDefaultsAreIdentical() {
        let untouched = defaultEditor()
        untouched.setText("alpha\nbeta\ngamma")
        let before = untouched.render(width: 20)

        let touched = defaultEditor()
        touched.setText("alpha\nbeta\ngamma")
        touched.maxVisibleLines = nil
        touched.showBorders = true
        touched.onPaste = nil
        #expect(touched.render(width: 20) == before)
    }

    @Test("visibleLineCap reproduces the old max(5, rows * 0.3) at every height")
    func lineCapMatchesTheOldFormula() {
        // The cap only becomes visible once the document is taller than it, so a
        // long document at each terminal height reveals the number directly: the
        // rendered row count is the cap plus the two rules.
        for terminalRows in [1, 10, 20, 24, 40, 80, 200] {
            let editor = defaultEditor(rows: terminalRows)
            editor.setText((1...300).map { "line \($0)" }.joined(separator: "\n"))
            let expected = max(5, Int(Double(terminalRows) * 0.3))
            #expect(
                editor.render(width: 20).count == expected + 2,
                "terminalRows=\(terminalRows) expected cap \(expected)"
            )
        }
    }

    @Test("A document shorter than the cap is unaffected by it")
    func shortDocumentIsUnclipped() {
        let editor = defaultEditor(rows: 80)   // cap 24
        editor.setText("one\ntwo\nthree")
        #expect(editor.render(width: 10).count == 5)   // 3 text + 2 rules
    }
}

@Suite("Editor seam additions do what they say once set")
@MainActor
struct EditorSeamBehaviourTests {

    @Test("showBorders = false drops exactly the two rules and nothing else")
    func bordersOff() {
        let editor = defaultEditor()
        editor.setText("alpha\nbeta")
        let bordered = editor.render(width: 16)

        editor.showBorders = false
        let bare = editor.render(width: 16)

        #expect(bordered.count == bare.count + 2)
        #expect(bare == Array(bordered.dropFirst().dropLast()))
    }

    @Test("showBorders = false also drops the scroll indicators, which ARE the rules")
    func bordersOffHidesScrollIndicators() {
        let editor = defaultEditor(rows: 24)   // cap 7
        editor.setText((1...40).map { "line \($0)" }.joined(separator: "\n"))
        editor.showBorders = false
        let bare = editor.render(width: 24)
        #expect(bare.count == 7)
        #expect(!bare.contains { $0.contains("more") })
    }

    @Test("maxVisibleLines overrides the derived cap in both directions")
    func explicitCap() {
        let editor = defaultEditor(rows: 80)   // derived cap 24
        editor.setText((1...100).map { "line \($0)" }.joined(separator: "\n"))

        editor.maxVisibleLines = 3
        #expect(editor.render(width: 20).count == 5)   // 3 text + 2 rules

        editor.maxVisibleLines = 40
        #expect(editor.render(width: 20).count == 42)
    }

    @Test("A degenerate maxVisibleLines still renders one line rather than trapping")
    func degenerateCapIsClamped() {
        let editor = defaultEditor()
        editor.setText("alpha\nbeta\ngamma")
        for cap in [0, -1, Int.min + 1] {
            editor.maxVisibleLines = cap
            editor.showBorders = false
            #expect(editor.render(width: 10).count == 1)
        }
    }

    @Test("onPaste returning true swallows the paste and leaves the editor untouched")
    func pasteSwallowed() {
        let editor = defaultEditor()
        editor.setText("before")
        var seen: [String] = []
        var changes = 0
        editor.onChange = { _ in changes += 1 }
        editor.onPaste = { text in seen.append(text); return true }

        editor.handleInput(Array("\u{1b}[200~/tmp/shot.png\u{1b}[201~".utf8))

        #expect(seen == ["/tmp/shot.png"])
        #expect(editor.getText() == "before")
        #expect(changes == 0, "a swallowed paste must not report a change")

        // ...and it consumed no undo slot. Compared against a control that never
        // saw the paste at all: one undo must land both editors in the same
        // place, which it cannot do if the swallowed paste pushed a snapshot.
        let control = defaultEditor()
        control.setText("before")
        editor.handleInput([0x1f])    // Ctrl-_ / undo
        control.handleInput([0x1f])
        #expect(editor.getText() == control.getText())
    }

    @Test("onPaste returning false leaves the paste exactly as it was before the hook")
    func pasteDeclined() {
        let hooked = defaultEditor()
        hooked.onPaste = { _ in false }
        hooked.handleInput(Array("\u{1b}[200~hello world\u{1b}[201~".utf8))

        let bare = defaultEditor()
        bare.handleInput(Array("\u{1b}[200~hello world\u{1b}[201~".utf8))

        #expect(hooked.getExpandedText() == bare.getExpandedText())
        #expect(hooked.render(width: 30) == bare.render(width: 30))
    }

    @Test("The hook sees a paste the driver split across chunks, whole")
    func splitPasteArrivesWhole() {
        let editor = defaultEditor()
        var seen: [String] = []
        editor.onPaste = { text in seen.append(text); return true }

        // Exactly the case a byte-sniffing caller above the Editor would miss.
        editor.handleInput(Array("\u{1b}[200~/tmp/a".utf8))
        #expect(seen.isEmpty, "an incomplete paste must not fire the hook")
        editor.handleInput(Array(".png /tmp/b.png\u{1b}[201~".utf8))
        #expect(seen == ["/tmp/a.png /tmp/b.png"])
    }
}
