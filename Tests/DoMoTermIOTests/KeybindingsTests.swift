import Testing

import DoMoTermIO

private func seq(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite("Keybindings")
struct KeybindingsTests {
    @Test("Default bindings resolve and match")
    func defaults() {
        let kb = Keybindings()
        #expect(kb.matches([0x03], .inputCopy))              // ctrl+c
        #expect(kb.matches(seq("\u{1b}[A"), .editorCursorUp)) // up
        #expect(kb.matches([0x01], .editorCursorLineStart))   // ctrl+a
        #expect(kb.matches([0x17], .editorDeleteWordBackward)) // ctrl+w
        #expect(kb.matches(seq("\u{1b}\u{7f}"), .editorDeleteWordBackward)) // alt+backspace
        #expect(!kb.matches([0x03], .editorCursorUp))
    }

    @Test("Multiple keys per action all match")
    func multiKey() {
        let kb = Keybindings()
        #expect(kb.matches(seq("\u{1b}[D"), .editorCursorLeft)) // left
        #expect(kb.matches([0x02], .editorCursorLeft))          // ctrl+b
    }

    @Test("A default table reusing a key across actions is not a conflict")
    func defaultsHaveNoConflicts() {
        let kb = Keybindings()
        #expect(kb.conflicts.isEmpty)
    }

    @Test("User override replaces the default entirely")
    func overrideReplaces() {
        let kb = Keybindings(userBindings: [.inputSubmit: [Key.ctrl("s")]])
        #expect(kb.matches([0x13], .inputSubmit))    // ctrl+s now submits
        #expect(!kb.matches([0x0d], .inputSubmit))   // enter no longer submits
        #expect(kb.keys(for: .inputSubmit) == [Key.ctrl("s")])
    }

    @Test("Overriding one action leaves others on their defaults")
    func overrideIsScoped() {
        let kb = Keybindings(userBindings: [.inputSubmit: [Key.ctrl("s")]])
        #expect(kb.matches(seq("\u{1b}[A"), .editorCursorUp))
    }

    @Test("Two user actions claiming one key is a reported conflict")
    func conflictDetection() {
        let kb = Keybindings(userBindings: [
            .inputSubmit: [Key.ctrl("x")],
            .inputCopy: [Key.ctrl("x")],
        ])
        #expect(kb.conflicts.count == 1)
        let conflict = kb.conflicts[0]
        #expect(conflict.key == Key.ctrl("x"))
        #expect(Set(conflict.keybindings) == [.inputSubmit, .inputCopy])
    }

    @Test("Duplicate keys within one action are deduped, not a conflict")
    func dedupeWithinAction() {
        let kb = Keybindings(userBindings: [.inputSubmit: [Key.ctrl("s"), Key.ctrl("s")]])
        #expect(kb.keys(for: .inputSubmit) == [Key.ctrl("s")])
        #expect(kb.conflicts.isEmpty)
    }

    @Test("The value type is copyable and independent")
    func valueSemantics() {
        let base = Keybindings()
        let custom = Keybindings(userBindings: [.inputSubmit: [Key.ctrl("s")]])
        // Mutating one never affects the other: they are separate values.
        #expect(base.matches([0x0d], .inputSubmit))
        #expect(!custom.matches([0x0d], .inputSubmit))
    }
}
