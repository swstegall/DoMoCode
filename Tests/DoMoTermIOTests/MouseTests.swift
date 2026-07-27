// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Mouse report decoding: the SGR encoding the full-screen lifecycle asks for
// (`?1006h`), the legacy X10 encoding a terminal may send anyway, and the
// malformed input that must decode to nothing rather than to a wrong position —
// because a mis-decoded report is a scroll of the wrong pane, and an
// undecoded one is escape gibberish typed into the prompt.

import DoMoTermIO
import Testing

private func sgr(_ button: Int, _ column: Int, _ row: Int, press: Bool = true) -> [UInt8] {
    Array("\u{1b}[<\(button);\(column);\(row)\(press ? "M" : "m")".utf8)
}

@Suite("Mouse decoding")
struct MouseTests {

    @Test("SGR wheel up and down decode with 0-based coordinates")
    func sgrWheel() {
        // Button 64 = wheel up, 65 = wheel down. SGR coordinates are 1-based.
        let up = decodeMouseEvent(sgr(64, 10, 5))
        #expect(up?.kind == .scrollUp)
        #expect(up?.column == 9)
        #expect(up?.row == 4)
        #expect(up?.isScroll == true)

        let down = decodeMouseEvent(sgr(65, 1, 1))
        #expect(down?.kind == .scrollDown)
        #expect(down?.column == 0)
        #expect(down?.row == 0)
    }

    @Test("SGR buttons and press/release are distinguished")
    func sgrButtons() {
        #expect(decodeMouseEvent(sgr(0, 3, 3))?.kind == .press)
        #expect(decodeMouseEvent(sgr(0, 3, 3))?.button == .left)
        #expect(decodeMouseEvent(sgr(1, 3, 3))?.button == .middle)
        #expect(decodeMouseEvent(sgr(2, 3, 3))?.button == .right)
        // Same report, `m` final byte: the release.
        #expect(decodeMouseEvent(sgr(0, 3, 3, press: false))?.kind == .release)
    }

    @Test("Modifier bits decode independently of the button")
    func modifiers() {
        // 64 = wheel up, +4 shift, +8 alt, +16 ctrl.
        #expect(decodeMouseEvent(sgr(64 + 4, 2, 2))?.shift == true)
        #expect(decodeMouseEvent(sgr(64 + 8, 2, 2))?.alt == true)
        #expect(decodeMouseEvent(sgr(64 + 16, 2, 2))?.ctrl == true)
        // Ctrl-wheel is what pages a viewport, so it must still read as a wheel.
        #expect(decodeMouseEvent(sgr(64 + 16, 2, 2))?.kind == .scrollUp)
        #expect(decodeMouseEvent(sgr(64, 2, 2))?.ctrl == false)
    }

    @Test("Motion reports are marked as moves, not presses")
    func motion() {
        // +32 is the motion bit.
        #expect(decodeMouseEvent(sgr(32, 4, 4))?.kind == .move)
    }

    @Test("Large coordinates survive — the reason SGR exists")
    func largeCoordinates() {
        let event = decodeMouseEvent(sgr(65, 300, 240))
        #expect(event?.column == 299)
        #expect(event?.row == 239)
    }

    @Test("Legacy X10 reports decode, including the wheel")
    func x10() {
        // ESC [ M, then button+32, column+33, row+33.
        let wheelUp: [UInt8] = [0x1b, 0x5b, 0x4d, UInt8(64 + 32), UInt8(33 + 9), UInt8(33 + 4)]
        let event = decodeMouseEvent(wheelUp)
        #expect(event?.kind == .scrollUp)
        #expect(event?.column == 9)
        #expect(event?.row == 4)

        let leftPress: [UInt8] = [0x1b, 0x5b, 0x4d, 32, 33, 33]
        #expect(decodeMouseEvent(leftPress)?.kind == .press)
        #expect(decodeMouseEvent(leftPress)?.button == .left)

        // Button code 3 with no wheel bit is X10's "a button came up".
        let release: [UInt8] = [0x1b, 0x5b, 0x4d, UInt8(3 + 32), 33, 33]
        #expect(decodeMouseEvent(release)?.kind == .release)
    }

    @Test("Non-mouse and malformed input decode to nil, never to a position")
    func rejectsNonMouse() {
        #expect(decodeMouseEvent(Array("a".utf8)) == nil)
        #expect(decodeMouseEvent([0x1b]) == nil)
        #expect(decodeMouseEvent(Array("\u{1b}[A".utf8)) == nil)            // arrow up
        #expect(decodeMouseEvent(Array("\u{1b}[200~".utf8)) == nil)         // paste guard
        #expect(decodeMouseEvent(Array("\u{1b}[<64;10;5".utf8)) == nil)     // truncated: no final byte
        #expect(decodeMouseEvent(Array("\u{1b}[<64;10M".utf8)) == nil)      // only two fields
        #expect(decodeMouseEvent(Array("\u{1b}[<64;;5M".utf8)) == nil)      // empty field
        #expect(decodeMouseEvent(Array("\u{1b}[<64;1x;5M".utf8)) == nil)    // non-digit
        #expect(decodeMouseEvent([0x1b, 0x5b, 0x4d, 32, 33]) == nil)        // short X10
    }

    @Test("A wheel report is framed as one whole sequence before it is decoded")
    func framedWhole() {
        // The decoder is only correct on WHOLE sequences, so the framer must not
        // split one — a split report would be typed as text.
        var framer = StdinFramer()
        let events = framer.process(sgr(64, 12, 7))
        let sequences = events.compactMap { event -> [UInt8]? in
            if case .sequence(let bytes) = event { return bytes }
            return nil
        }
        #expect(sequences.count == 1)
        #expect(decodeMouseEvent(sequences[0])?.kind == .scrollUp)
        #expect(decodeMouseEvent(sequences[0])?.column == 11)
    }
}
