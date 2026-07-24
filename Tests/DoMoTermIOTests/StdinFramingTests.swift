// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

import DoMoTermIO

// The framer needs no TTY: it is a pure function of its byte input, so every
// case here drives it directly and asserts on the emitted events.

private let esc: UInt8 = 0x1b
private let bel: UInt8 = 0x07

private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

/// Feed a byte stream one byte per `process` call — the worst case for a state
/// machine, since every escape sequence is maximally fragmented.
private func feedByteByByte(_ input: [UInt8]) -> [StdinEvent] {
    var framer = StdinFramer()
    var events: [StdinEvent] = []
    for byte in input {
        events.append(contentsOf: framer.process([byte]))
    }
    return events
}

/// Feed a byte stream in one chunk.
private func feedWhole(_ input: [UInt8]) -> [StdinEvent] {
    var framer = StdinFramer()
    return framer.process(input)
}

@Suite("Stdin framing")
struct StdinFramingTests {

    // MARK: SGR mouse reassembly

    @Test("SGR mouse split at every byte boundary reassembles as one event")
    func sgrMouseEveryBoundary() {
        let mouse = bytes("\u{1b}[<35;20;5m")

        // Byte-by-byte: the maximal fragmentation.
        #expect(feedByteByByte(mouse) == [.sequence(mouse)])

        // Every single split point into two chunks.
        for cut in 1..<mouse.count {
            var framer = StdinFramer()
            var events = framer.process(Array(mouse[..<cut]))
            events.append(contentsOf: framer.process(Array(mouse[cut...])))
            #expect(events == [.sequence(mouse)], "split at \(cut) did not reassemble")
        }
    }

    @Test("SGR mouse release form ends in lowercase m")
    func sgrMouseRelease() {
        let mouse = bytes("\u{1b}[<0;1;1m")
        #expect(feedByteByByte(mouse) == [.sequence(mouse)])
    }

    @Test("A malformed SGR mouse tail is held, not misread as complete")
    func sgrMouseMalformedHeldIncomplete() {
        // Two coordinates instead of three: never a whole mouse report, so the
        // final `m` must not close it.
        let partial = bytes("\u{1b}[<35;20m")
        var framer = StdinFramer()
        let events = framer.process(partial)
        #expect(events.isEmpty)
        #expect(framer.hasPendingBytes)
    }

    // MARK: Incomplete-tail flush (ESC disambiguation)

    @Test("An incomplete tail flushes after the timeout as ESC")
    func incompleteTailFlushesAsEsc() {
        var framer = StdinFramer()
        let live = framer.process([esc])
        #expect(live.isEmpty)
        #expect(framer.hasPendingBytes)

        let flushed = framer.flush()
        #expect(flushed == [.sequence([esc])])
        #expect(!framer.hasPendingBytes)
    }

    @Test("Flushing an empty buffer yields nothing")
    func flushEmpty() {
        var framer = StdinFramer()
        #expect(framer.flush().isEmpty)
    }

    @Test("A held CSI prefix flushes verbatim on timeout")
    func heldCsiPrefixFlushes() {
        var framer = StdinFramer()
        _ = framer.process(bytes("\u{1b}["))
        #expect(framer.hasPendingBytes)
        #expect(framer.flush() == [.sequence(bytes("\u{1b}["))])
    }

    // MARK: Bracketed paste

    @Test("Bracketed paste with an embedded ESC in the payload")
    func pasteWithEmbeddedEsc() {
        let payload = bytes("ab\u{1b}cd")
        let stream = bytes("\u{1b}[200~") + payload + bytes("\u{1b}[201~")
        #expect(feedWhole(stream) == [.paste(payload)])
    }

    @Test("A paste split across chunks still emits one paste event")
    func pasteSplitAcrossChunks() {
        let payload = bytes("hello world")
        let stream = bytes("\u{1b}[200~") + payload + bytes("\u{1b}[201~")

        for cut in 1..<stream.count {
            var framer = StdinFramer()
            var events = framer.process(Array(stream[..<cut]))
            events.append(contentsOf: framer.process(Array(stream[cut...])))
            #expect(events == [.paste(payload)], "paste split at \(cut) failed")
        }
    }

    @Test("Input before and after a paste is framed around it")
    func inputAroundPaste() {
        let stream = bytes("a\u{1b}[200~pasted\u{1b}[201~b")
        let events = feedWhole(stream)
        #expect(events == [.sequence(bytes("a")), .paste(bytes("pasted")), .sequence(bytes("b"))])
    }

    @Test("A paste containing the 201~ terminator only closes at the real one")
    func pasteEmptyPayload() {
        let stream = bytes("\u{1b}[200~\u{1b}[201~")
        #expect(feedWhole(stream) == [.paste([])])
    }

    // MARK: OSC termination

    @Test("OSC terminated by BEL is one sequence")
    func oscTerminatedByBEL() {
        let osc = bytes("\u{1b}]0;title") + [bel]
        #expect(feedByteByByte(osc) == [.sequence(osc)])
    }

    @Test("OSC terminated by ST is one sequence")
    func oscTerminatedByST() {
        let osc = bytes("\u{1b}]0;title\u{1b}\\")
        #expect(feedByteByByte(osc) == [.sequence(osc)])
    }

    @Test("DCS is terminated by ST only")
    func dcsTerminatedByST() {
        let dcs = bytes("\u{1b}P>|term\u{1b}\\")
        #expect(feedByteByByte(dcs) == [.sequence(dcs)])
    }

    @Test("APC is terminated by ST only")
    func apcTerminatedByST() {
        let apc = bytes("\u{1b}_Gi=1\u{1b}\\")
        #expect(feedByteByByte(apc) == [.sequence(apc)])
    }

    // MARK: Bare ESC vs CSI start

    @Test("A bare ESC held then completed becomes a CSI, not a meta key")
    func bareEscBecomesCSI() {
        var framer = StdinFramer()
        #expect(framer.process([esc]).isEmpty)
        #expect(framer.hasPendingBytes)
        // The '[' arrives: still incomplete (need a final byte).
        #expect(framer.process(bytes("[")).isEmpty)
        // The final byte closes the CSI.
        let events = framer.process(bytes("A"))
        #expect(events == [.sequence(bytes("\u{1b}[A"))])
    }

    @Test("ESC followed by an ordinary char is a meta chord")
    func escMetaChord() {
        var framer = StdinFramer()
        #expect(framer.process([esc]).isEmpty)
        let events = framer.process(bytes("a"))
        #expect(events == [.sequence(bytes("\u{1b}a"))])
    }

    @Test("A lone ESC with nothing following flushes as the Escape key")
    func loneEscIsEscapeKey() {
        var framer = StdinFramer()
        _ = framer.process([esc])
        #expect(framer.flush() == [.sequence([esc])])
    }

    // MARK: WezTerm double-ESC split

    @Test("WezTerm double-ESC splits into ESC then the following CSI")
    func wezTermDoubleEsc() {
        // ESC ESC [27;5u — the Escape press as a raw byte, immediately followed
        // by the release as a Kitty CSI-u, concatenated in one read.
        let stream = [esc] + bytes("\u{1b}[27;5u")
        let events = feedWhole(stream)
        #expect(events == [.sequence([esc]), .sequence(bytes("\u{1b}[27;5u"))])
    }

    @Test("Double-ESC before OSC/SS3 also splits")
    func wezTermDoubleEscBeforeSS3() {
        let stream = [esc] + bytes("\u{1b}OP")
        let events = feedWhole(stream)
        #expect(events == [.sequence([esc]), .sequence(bytes("\u{1b}OP"))])
    }

    @Test("WezTerm double-ESC reassembles when split at every byte boundary")
    func wezTermDoubleEscEveryBoundary() {
        // The Escape press as a raw byte immediately followed by the release as a
        // Kitty CSI-u. Fragmented at any read() boundary — including right between
        // the two ESCs — it must still surface as exactly two events (Escape, then
        // the CSI-u), never `ESC ESC` plus the CSI-u's bytes typed as text.
        let stream = [esc] + bytes("\u{1b}[27;5u")
        let want: [StdinEvent] = [.sequence([esc]), .sequence(bytes("\u{1b}[27;5u"))]

        #expect(feedByteByByte(stream) == want)

        for cut in 1..<stream.count {
            var framer = StdinFramer()
            var events = framer.process(Array(stream[..<cut]))
            events.append(contentsOf: framer.process(Array(stream[cut...])))
            #expect(events == want, "double-ESC split at \(cut) did not reassemble")
        }
    }

    @Test("A held double-ESC flushes as ESC ESC when nothing follows")
    func doubleEscFlushesWhenAlone() {
        // Alt+Escape (or a bare double-Escape) is held for the disambiguation
        // window like a lone ESC, then flushed intact rather than being emitted
        // early and misframing a CSI that might have followed.
        var framer = StdinFramer()
        #expect(framer.process([esc]).isEmpty)
        #expect(framer.process([esc]).isEmpty)
        #expect(framer.hasPendingBytes)
        #expect(framer.flush() == [.sequence([esc, esc])])
    }

    @Test("Double-ESC followed by an ordinary char is a meta chord, then the char")
    func doubleEscThenPrintable() {
        // `ESC ESC a` is a genuine double-escape, not a WezTerm split, so it frames
        // as the two ESCs then the character — byte-by-byte and whole.
        let stream = bytes("\u{1b}\u{1b}a")
        let want: [StdinEvent] = [.sequence([esc, esc]), .sequence(bytes("a"))]
        #expect(feedWhole(stream) == want)
        #expect(feedByteByByte(stream) == want)
    }

    // MARK: Legacy mouse and SS3

    @Test("Legacy X10 mouse needs six bytes and reassembles across boundaries")
    func legacyMouse() {
        let mouse: [UInt8] = [esc, 0x5b, 0x4d, 0x20, 0x21, 0x21]  // ESC [ M SP ! !
        #expect(feedByteByByte(mouse) == [.sequence(mouse)])
        // Five bytes is not enough.
        var framer = StdinFramer()
        _ = framer.process(Array(mouse[..<5]))
        #expect(framer.hasPendingBytes)
    }

    @Test("SS3 is ESC O plus exactly one byte")
    func ss3() {
        let ss3 = bytes("\u{1b}OP")  // F1
        #expect(feedByteByByte(ss3) == [.sequence(ss3)])
    }

    // MARK: Plain input and UTF-8

    @Test("Plain ASCII is emitted one byte per event")
    func plainAscii() {
        #expect(feedWhole(bytes("abc")) == [.sequence(bytes("a")), .sequence(bytes("b")), .sequence(bytes("c"))])
    }

    @Test("A multi-byte UTF-8 scalar is emitted as one event")
    func utf8Scalar() {
        let accented = bytes("é")  // 0xC3 0xA9
        #expect(accented.count == 2)
        #expect(feedWhole(accented) == [.sequence(accented)])
    }

    @Test("A UTF-8 scalar split across chunks is held then completed")
    func utf8ScalarSplit() {
        let accented = bytes("é")
        var framer = StdinFramer()
        #expect(framer.process([accented[0]]).isEmpty)
        #expect(framer.hasPendingBytes)
        #expect(framer.process([accented[1]]) == [.sequence(accented)])
    }

    @Test("An emoji (astral scalar) is emitted as one four-byte event")
    func emojiScalar() {
        let emoji = bytes("😀")  // 4 bytes
        #expect(emoji.count == 4)
        #expect(feedWhole(emoji) == [.sequence(emoji)])
    }

    // MARK: Kitty printable dedup

    @Test("A raw char echoing an unmodified Kitty CSI-u is de-duplicated")
    func kittyPrintableDedup() {
        var framer = StdinFramer()
        // The CSI-u report primes the dedup; the raw duplicate that follows is
        // swallowed. ESC[97u encodes codepoint 97 == 'a'.
        let first = framer.process(bytes("\u{1b}[97u"))
        #expect(first == [.sequence(bytes("\u{1b}[97u"))])
        let second = framer.process(bytes("a"))
        #expect(second.isEmpty, "the raw duplicate should be swallowed")
    }

    @Test("A raw char after a CSI-u for a different codepoint is not swallowed")
    func kittyPrintableNoFalseDedup() {
        var framer = StdinFramer()
        _ = framer.process(bytes("\u{1b}[98u"))  // 'b'
        let second = framer.process(bytes("a"))
        #expect(second == [.sequence(bytes("a"))])
    }

    // MARK: State machine classification

    @Test("isCompleteSequence classifies the sequence families")
    func completenessClassification() {
        #expect(StdinFramer.isCompleteSequence(bytes("a")[...]) == .notEscape)
        #expect(StdinFramer.isCompleteSequence([esc][...]) == .incomplete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}[")[...]) == .incomplete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}[A")[...]) == .complete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}a")[...]) == .complete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}]0;x")[...]) == .incomplete)
        #expect(StdinFramer.isCompleteSequence((bytes("\u{1b}]0;x") + [bel])[...]) == .complete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}O")[...]) == .incomplete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}OP")[...]) == .complete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}[<35;20;5")[...]) == .incomplete)
        #expect(StdinFramer.isCompleteSequence(bytes("\u{1b}[<35;20;5m")[...]) == .complete)
    }
}
