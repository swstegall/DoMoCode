import Testing

import DoMoTermIO

private func seq(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite("Legacy sequences")
struct LegacySequenceTests {
    @Test("Arrow keys in both CSI and SS3 legacy forms")
    func arrows() {
        #expect(parseKey(seq("\u{1b}[A")) == Key.up)
        #expect(parseKey(seq("\u{1b}[B")) == Key.down)
        #expect(parseKey(seq("\u{1b}[C")) == Key.right)
        #expect(parseKey(seq("\u{1b}[D")) == Key.left)
        #expect(parseKey(seq("\u{1b}OA")) == Key.up)
        #expect(parseKey(seq("\u{1b}OD")) == Key.left)
        #expect(matchesKey(seq("\u{1b}[A"), Key.up))
        #expect(matchesKey(seq("\u{1b}OA"), Key.up))
        #expect(!matchesKey(seq("\u{1b}[A"), Key.down))
    }

    @Test("Function keys across SS3, CSI-tilde and CSI-bracket forms")
    func functionKeys() {
        #expect(parseKey(seq("\u{1b}OP")) == Key.f1)
        #expect(parseKey(seq("\u{1b}[15~")) == Key.f5)
        #expect(parseKey(seq("\u{1b}[24~")) == Key.f12)
        #expect(matchesKey(seq("\u{1b}OP"), Key.f1))
        #expect(matchesKey(seq("\u{1b}[11~"), Key.f1))
        #expect(matchesKey(seq("\u{1b}[[A"), Key.f1))
        #expect(matchesKey(seq("\u{1b}[24~"), Key.f12))
        #expect(!matchesKey(seq("\u{1b}OP"), Key.f2))
    }

    @Test("Home and End have multiple legacy encodings")
    func homeEnd() {
        for form in ["\u{1b}[H", "\u{1b}OH", "\u{1b}[1~", "\u{1b}[7~"] {
            #expect(matchesKey(seq(form), Key.home), "home form \(form)")
        }
        for form in ["\u{1b}[F", "\u{1b}OF", "\u{1b}[4~", "\u{1b}[8~"] {
            #expect(matchesKey(seq(form), Key.end), "end form \(form)")
        }
        #expect(parseKey(seq("\u{1b}[H")) == Key.home)
        #expect(parseKey(seq("\u{1b}OF")) == Key.end)
    }

    @Test("insert / delete / pageUp / pageDown")
    func navKeys() {
        #expect(matchesKey(seq("\u{1b}[2~"), Key.insert))
        #expect(matchesKey(seq("\u{1b}[3~"), Key.delete))
        #expect(matchesKey(seq("\u{1b}[5~"), Key.pageUp))
        #expect(matchesKey(seq("\u{1b}[6~"), Key.pageDown))
        #expect(parseKey(seq("\u{1b}[3~")) == Key.delete)
    }

    @Test("Shifted and ctrl legacy modifier sequences")
    func modifierSequences() {
        #expect(matchesKey(seq("\u{1b}[a"), KeyId(base: .up, shift: true)))
        #expect(matchesKey(seq("\u{1b}Oa"), KeyId(base: .up, ctrl: true)))
        #expect(matchesKey(seq("\u{1b}[7$"), KeyId(base: .home, shift: true)))
        #expect(matchesKey(seq("\u{1b}[7^"), KeyId(base: .home, ctrl: true)))
        #expect(parseKey(seq("\u{1b}[a")) == KeyId(base: .up, shift: true))
    }
}

@Suite("Ctrl letters and raw bytes")
struct CtrlLetterTests {
    @Test("Ctrl+letter is the control byte")
    func ctrlLetters() {
        #expect(matchesKey([0x03], Key.ctrl("c")))
        #expect(matchesKey([0x01], Key.ctrl("a")))
        #expect(matchesKey([0x1a], Key.ctrl("z")))
        #expect(!matchesKey([0x03], Key.ctrl("a")))
        #expect(parseKey([0x03]) == Key.ctrl("c"))
        #expect(parseKey([0x1a]) == Key.ctrl("z"))
    }

    @Test("Ctrl+symbol via the 0x1c..0x1f range")
    func ctrlSymbols() {
        #expect(parseKey([0x1c]) == KeyId(base: .char("\\"), ctrl: true))
        #expect(parseKey([0x1d]) == KeyId(base: .char("]"), ctrl: true))
        #expect(parseKey([0x1f]) == KeyId(base: .char("-"), ctrl: true))
        #expect(matchesKey([0x1d], Key.ctrl("]")))
    }

    @Test("Escape, tab, enter, space, backspace raw bytes")
    func controlBytes() {
        #expect(parseKey([0x1b]) == Key.escape)
        #expect(parseKey([0x09]) == Key.tab)
        #expect(parseKey([0x0d]) == Key.enter)
        #expect(parseKey(seq(" ")) == Key.space)
        #expect(parseKey([0x7f]) == Key.backspace)
        #expect(parseKey([0x00]) == KeyId(base: .space, ctrl: true))
        #expect(matchesKey([0x1b], Key.escape))
        #expect(matchesKey([0x09], Key.tab))
        #expect(matchesKey([0x0d], Key.enter))
        #expect(matchesKey([0x7f], Key.backspace))
    }

    @Test("Plain printable letter round-trips")
    func printable() {
        #expect(parseKey(seq("a")) == KeyId(base: .char("a")))
        #expect(matchesKey(seq("a"), KeyId(base: .char("a"))))
        #expect(!matchesKey(seq("a"), KeyId(base: .char("b"))))
    }
}

@Suite("Kitty keyboard protocol")
struct KittyProtocolTests {
    @Test("Plain key CSI-u")
    func plainKey() {
        #expect(parseKey(seq("\u{1b}[97u")) == KeyId(base: .char("a")))
        #expect(matchesKey(seq("\u{1b}[97u"), KeyId(base: .char("a"))))
        #expect(decodePrintableKey(seq("\u{1b}[97u")) == "a")
    }

    @Test("Shifted key prefers the shifted codepoint for text")
    func shiftedKey() {
        let shiftA = seq("\u{1b}[97:65;2u")
        #expect(parseKey(shiftA) == KeyId(base: .char("a"), shift: true))
        #expect(matchesKey(shiftA, KeyId(base: .char("a"), shift: true)))
        #expect(decodeKittyPrintable(shiftA) == "A")
    }

    @Test("Ctrl+Enter as CSI-u")
    func ctrlEnter() {
        let data = seq("\u{1b}[13;5u")
        #expect(matchesKey(data, KeyId(base: .enter, ctrl: true)))
        #expect(parseKey(data) == KeyId(base: .enter, ctrl: true))
        // Ctrl is a command, not text.
        #expect(decodePrintableKey(data) == nil)
    }

    @Test("Release event is detected and still matches its key")
    func releaseEvent() {
        let release = seq("\u{1b}[99;5:3u")
        #expect(keyEventType(release) == .release)
        #expect(isKeyRelease(release))
        #expect(!isKeyRepeat(release))
        #expect(matchesKey(release, Key.ctrl("c")))
    }

    @Test("Repeat event detection")
    func repeatEvent() {
        let rep = seq("\u{1b}[97;1:2u")
        #expect(keyEventType(rep) == .repeat)
        #expect(isKeyRepeat(rep))
        #expect(!isKeyRelease(rep))
    }

    @Test("Press is the default event type")
    func pressEvent() {
        #expect(keyEventType(seq("\u{1b}[97u")) == .press)
        #expect(keyEventType(seq("\u{1b}[97;5u")) == .press)
    }

    @Test("Bracketed paste content is never read as release/repeat")
    func pasteGuard() {
        let paste = seq("\u{1b}[200~90:62:3F:A5\u{1b}[201~")
        #expect(!isKeyRelease(paste))
        #expect(!isKeyRepeat(seq("\u{1b}[200~ab:2Fcd\u{1b}[201~")))
    }

    @Test("Numpad codepoints normalize to their base key")
    func numpadNormalization() {
        #expect(parseKey(seq("\u{1b}[57400u")) == KeyId(base: .char("1")))
        #expect(matchesKey(seq("\u{1b}[57400u"), KeyId(base: .char("1"))))
        #expect(matchesKey(seq("\u{1b}[57417u"), Key.left)) // KP_LEFT
        #expect(matchesKey(seq("\u{1b}[57414u"), Key.enter)) // KP_ENTER
    }

    @Test("Modified arrows and functional CSI forms")
    func modifiedFunctional() {
        #expect(matchesKey(seq("\u{1b}[1;5A"), KeyId(base: .up, ctrl: true)))
        #expect(matchesKey(seq("\u{1b}[1;2H"), KeyId(base: .home, shift: true)))
        #expect(matchesKey(seq("\u{1b}[3;5~"), KeyId(base: .delete, ctrl: true)))
    }
}

@Suite("Base-layout fallback suppression")
struct BaseLayoutTests {
    // Cyrillic lowercase 'es' (U+0441 = 1089) with base layout key 'c' (99).
    @Test("Cyrillic layout key matches its Latin binding via base layout")
    func cyrillicMatches() {
        let ctrlCyrillic = seq("\u{1b}[1089::99;5u")
        #expect(matchesKey(ctrlCyrillic, Key.ctrl("c")))
        #expect(parseKey(ctrlCyrillic) == Key.ctrl("c"))
    }

    // Dvorak: physical 'v' position emits 'k' (107); base layout reports 'v' (118).
    // The reported codepoint is a Latin letter, so the base-layout fallback is
    // suppressed and Ctrl+K must NOT false-match Ctrl+V.
    @Test("Latin letter does not trigger base-layout fallback")
    func latinSuppressed() {
        let remapped = seq("\u{1b}[107::118;5u")
        #expect(!matchesKey(remapped, Key.ctrl("v")))
        #expect(matchesKey(remapped, Key.ctrl("k")))
        #expect(parseKey(remapped) == Key.ctrl("k"))
    }

    @Test("Symbol also suppresses base-layout fallback")
    func symbolSuppressed() {
        // '/' (47) reported, base layout '[' (91). Must not match Ctrl+[.
        let remapped = seq("\u{1b}[47::91;5u")
        #expect(!matchesKey(remapped, Key.ctrl("[")))
        #expect(matchesKey(remapped, Key.ctrl("/")))
    }
}

@Suite("xterm modifyOtherKeys")
struct ModifyOtherKeysTests {
    @Test("Ctrl+char via CSI 27")
    func ctrlChar() {
        let data = seq("\u{1b}[27;5;99~")
        #expect(matchesKey(data, Key.ctrl("c")))
        #expect(parseKey(data) == Key.ctrl("c"))
    }

    @Test("Shift+char decodes to text")
    func shiftChar() {
        // Shift+A: modifier 2, codepoint 65.
        let data = seq("\u{1b}[27;2;65~")
        #expect(decodePrintableKey(data) == "A")
    }

    @Test("Modified special keys via modifyOtherKeys")
    func specialKeys() {
        #expect(matchesKey(seq("\u{1b}[27;3;13~"), KeyId(base: .enter, alt: true)))
        #expect(matchesKey(seq("\u{1b}[27;2;9~"), KeyId(base: .tab, shift: true)))
    }
}

@Suite("Kitty-active mode disambiguation")
struct KittyModeTests {
    @Test("shift+enter vs alt+enter depends on protocol state")
    func enterAmbiguity() {
        // \x1b\r : alt+enter in legacy mode, shift+enter under Kitty.
        #expect(parseKey(seq("\u{1b}\r")) == KeyId(base: .enter, alt: true))
        #expect(parseKey(seq("\u{1b}\r"), kittyProtocolActive: true) == KeyId(base: .enter, shift: true))
        #expect(matchesKey(seq("\u{1b}\r"), KeyId(base: .enter, alt: true)))
        #expect(matchesKey(seq("\u{1b}\r"), KeyId(base: .enter, shift: true), kittyProtocolActive: true))
    }

    @Test("Bare newline is enter legacy, shift+enter under Kitty")
    func newlineAmbiguity() {
        #expect(parseKey([0x0a]) == Key.enter)
        #expect(parseKey([0x0a], kittyProtocolActive: true) == KeyId(base: .enter, shift: true))
    }
}

@Suite("Adversarial and lock-mask decoding")
struct AdversarialDecodingTests {
    // A garbage or hostile terminal can emit an arbitrarily long digit run
    // inside a CSI sequence. The parameter accumulator must not overflow `Int`
    // and trap the renderer (the README forbids trapping on input).
    @Test("A long numeric CSI-u param does not trap")
    func hugeCSIuParam() {
        let data = seq("\u{1b}[" + String(repeating: "9", count: 40) + "u")
        _ = parseKey(data)
        _ = matchesKey(data, Key.ctrl("c"))
        _ = decodePrintableKey(data)
    }

    @Test("A long numeric modifyOtherKeys param does not trap")
    func hugeModifyOtherKeysParam() {
        _ = parseKey(seq("\u{1b}[27;5;" + String(repeating: "9", count: 40) + "~"))
    }

    @Test("Assorted malformed CSI never crash")
    func malformedCSI() {
        for c in ["\u{1b}[", "\u{1b}[u", "\u{1b}[;u", "\u{1b}[:u", "\u{1b}[1;u",
                  "\u{1b}[1:2:3:4:5u", "\u{1b}[55296u", "\u{1b}[2000000u"] {
            _ = parseKey(seq(c))
            _ = matchesKey(seq(c), Key.ctrl("c"))
            _ = decodePrintableKey(seq(c))
        }
    }

    // Caps Lock (64) and Num Lock (128) must be masked out before comparing
    // modifiers, so a binding fires regardless of a lock light.
    @Test("Caps and Num lock bits are masked")
    func lockMasking() {
        #expect(parseKey(seq("\u{1b}[97;65u")) == KeyId(base: .char("a")))   // caps only
        #expect(parseKey(seq("\u{1b}[97;129u")) == KeyId(base: .char("a")))  // num only
        #expect(parseKey(seq("\u{1b}[99;133u")) == Key.ctrl("c"))            // ctrl + num
        #expect(matchesKey(seq("\u{1b}[99;133u"), Key.ctrl("c")))
    }
}

@Suite("Alt printable legacy forms")
struct AltPrintableTests {
    @Test("Alt+letter is ESC + letter")
    func altLetter() {
        #expect(parseKey(seq("\u{1b}a")) == KeyId(base: .char("a"), alt: true))
        #expect(matchesKey(seq("\u{1b}a"), Key.alt("a")))
    }

    @Test("Ctrl+Alt+letter is ESC + control byte")
    func ctrlAltLetter() {
        #expect(parseKey(seq("\u{1b}\u{03}")) == KeyId(base: .char("c"), alt: true, ctrl: true))
        #expect(matchesKey(seq("\u{1b}\u{03}"), KeyId(base: .char("c"), alt: true, ctrl: true)))
    }

    @Test("Alt+backspace")
    func altBackspace() {
        #expect(parseKey(seq("\u{1b}\u{7f}")) == KeyId(base: .backspace, alt: true))
        #expect(matchesKey(seq("\u{1b}\u{7f}"), KeyId(base: .backspace, alt: true)))
    }
}
