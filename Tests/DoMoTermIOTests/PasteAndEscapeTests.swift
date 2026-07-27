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

        // First firing: the bytes that DID arrive are emitted as paste data (never
        // re-framed as keystrokes), and the paste stays open — a merely-slow paste
        // must not be chopped in half.
        let flushed = framer.flush()
        #expect(flushed.count == 1)
        guard case .paste(let content) = flushed.first else {
            Issue.record("an abandoned paste must be emitted as paste DATA, not re-framed as keystrokes")
            return
        }
        #expect(String(decoding: content, as: UTF8.self) == "stranded")
        #expect(framer.hasPendingPaste, "still open — more of the paste may yet arrive")

        // Second firing with nothing new: the end marker is never coming, so the
        // paste closes and the keyboard comes back.
        #expect(framer.flush().isEmpty)
        #expect(!framer.hasPendingPaste)

        // And the framer is usable again: a following keystroke gets through.
        let after = framer.process(Array("x".utf8))
        #expect(after.count == 1)
        if case .sequence(let bytes) = after[0] { #expect(bytes == Array("x".utf8)) } else { Issue.record("expected a key") }
    }

    @Test("A slow paste survives a watchdog firing and still closes as one stream")
    func slowPasteIsNotChopped() {
        // The regression this guards: leaving paste mode on the first watchdog firing
        // re-framed the REST of a legitimate paste as keystrokes, so an embedded
        // newline would submit the prompt mid-paste.
        var framer = StdinFramer()
        _ = framer.process(pasteStart + Array("first half\r".utf8))
        let drained = framer.flush()                       // the user's link stalled
        #expect(drained.count == 1)
        #expect(framer.hasPendingPaste, "the paste is slow, not abandoned")

        let rest = framer.process(Array("second half".utf8) + pasteEnd)
        #expect(rest.count == 1)
        guard case .paste(let tail) = rest.first else { Issue.record("expected paste"); return }
        #expect(String(decoding: tail, as: UTF8.self) == "second half")
        #expect(!framer.hasPendingPaste)
        // Crucially, the embedded CR came through as DATA in the first piece.
        guard case .paste(let head) = drained.first else { Issue.record("expected paste"); return }
        #expect(String(decoding: head, as: UTF8.self) == "first half\r")
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

    @Test("A committed paste-start prefix waits on the PASTE deadline, not the escape one")
    func splitPasteStartMarker() {
        // `ESC[200~` split across a read() boundary was emitted as garbage after 10 ms
        // and the whole paste that followed was framed as KEYSTROKES.
        var framer = StdinFramer()
        _ = framer.process(Array("\u{1b}[2".utf8))
        #expect(framer.hasPendingPasteStart, "a 3-byte committed CSI can only be growing into the marker")
        #expect(framer.hasPendingBytes)

        // The two genuinely ambiguous prefixes must NOT wait: they are indistinguishable
        // from a real Escape / Alt-[ keypress, and stalling them would make the abort
        // key feel broken.
        var short = StdinFramer()
        _ = short.process([0x1b])
        #expect(!short.hasPendingPasteStart)
        var alt = StdinFramer()
        _ = alt.process(Array("\u{1b}[".utf8))
        #expect(!alt.hasPendingPasteStart)

        // A CSI that is NOT growing into the marker is unaffected.
        var other = StdinFramer()
        _ = other.process(Array("\u{1b}[3".utf8))
        #expect(!other.hasPendingPasteStart)

        // And the split marker still completes into a real paste.
        let events = framer.process(Array("00~pasted".utf8) + pasteEnd)
        #expect(events.count == 1)
        guard case .paste(let content) = events.first else { Issue.record("expected a paste"); return }
        #expect(String(decoding: content, as: UTF8.self) == "pasted")
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
