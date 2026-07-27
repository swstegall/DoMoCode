// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Two input-layer states that could swallow keystrokes for good: an open bracketed
// paste that never closes, and a double Escape.

import DoMoTermIO
import Testing

@Suite("Paste watchdog and double Escape")
struct PasteAndEscapeTests {

    private let pasteStart = Array("\u{1b}[200~".utf8)
    private let pasteEnd = Array("\u{1b}[201~".utf8)

    @Test("A closed paste is unaffected — content arrives once, intact")
    func closedPasteStillWorks() {
        var framer = StdinFramer()
        var events = framer.process(pasteStart + Array("line one\rline two".utf8))
        #expect(events.isEmpty, "nothing is emitted until the paste closes")
        #expect(framer.hasPendingPaste)
        events = framer.process(pasteEnd)
        #expect(events.count == 1)
        guard case .paste(let content) = events.first else {
            Issue.record("expected a paste event"); return
        }
        #expect(String(decoding: content, as: UTF8.self) == "line one\rline two")
        #expect(!framer.hasPendingPaste)
    }

    @Test("A paste split across chunks still arrives as ONE paste")
    func multiChunkPaste() {
        // The watchdog must not chop this: the gap between read() chunks inside one
        // real paste is routinely longer than the 10 ms escape window.
        var framer = StdinFramer()
        _ = framer.process(pasteStart + Array("abc".utf8))
        _ = framer.process(Array("def".utf8))
        let events = framer.process(Array("ghi".utf8) + pasteEnd)
        #expect(events.count == 1)
        guard case .paste(let content) = events.first else {
            Issue.record("expected one paste"); return
        }
        #expect(String(decoding: content, as: UTF8.self) == "abcdefghi")
    }

    @Test("An unterminated paste is drained by the watchdog instead of deafening the app")
    func unterminatedPasteDrains() {
        // The defect: `ESC[200~` with no `ESC[201~` left the framer swallowing EVERY
        // later byte forever. The UI kept painting, but no keystroke — not even
        // Ctrl-C — could reach it again.
        var framer = StdinFramer()
        _ = framer.process(pasteStart + Array("stranded".utf8))
        #expect(framer.hasPendingPaste, "an open paste must be reported, so the driver can arm its watchdog")
        #expect(!framer.hasPendingBytes, "and reported SEPARATELY from an escape tail, which has a shorter deadline")

        let flushed = framer.flush()
        #expect(flushed.count == 1)
        guard case .paste(let content) = flushed.first else {
            Issue.record("an abandoned paste must be emitted as paste DATA, not re-framed as keystrokes")
            return
        }
        #expect(String(decoding: content, as: UTF8.self) == "stranded")
        #expect(!framer.hasPendingPaste)

        // And the framer is usable again: a following keystroke gets through.
        let after = framer.process(Array("x".utf8))
        #expect(after.count == 1)
        if case .sequence(let bytes) = after[0] { #expect(bytes == Array("x".utf8)) } else { Issue.record("expected a key") }
    }

    @Test("An abandoned paste's newlines stay data, never commands")
    func abandonedPasteContentIsInert() {
        // Re-framing the remainder as keystrokes would make a pasted newline submit
        // the prompt and pasted control bytes fire commands — worse than the deadlock.
        var framer = StdinFramer()
        _ = framer.process(pasteStart + Array("one\rtwo\u{03}".utf8))
        let flushed = framer.flush()
        #expect(flushed.count == 1, "exactly one event, not one per embedded control byte")
        guard case .paste(let content) = flushed.first else { Issue.record("expected paste"); return }
        #expect(String(decoding: content, as: UTF8.self) == "one\rtwo\u{03}")
    }

    @Test("The paste deadline is much longer than the escape deadline")
    func timeoutsAreDistinct() {
        #expect(StdinFramer.pasteTimeout > StdinFramer.disambiguationTimeout * 10)
    }

    @Test("Double Escape decodes as Escape, not a dead chord")
    func doubleEscapeIsEscape() {
        // Two Escapes in quick succession reach the app as ONE two-byte sequence
        // (the framer holds a lone ESC, then flushes what it has). That used to
        // decode to ctrl+alt+`[`, which nothing binds — so a user mashing Escape at
        // a modal got no response at all.
        #expect(matchesKey([0x1b, 0x1b], Key.escape))
        #expect(matchesKey([0x1b], Key.escape))
        let bindings = Keybindings()
        #expect(bindings.matches([0x1b, 0x1b], .selectCancel))
    }
}
