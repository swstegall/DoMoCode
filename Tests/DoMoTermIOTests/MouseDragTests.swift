// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The reports a drag-selection is made of, under `?1002h` (button-event
// tracking). The decoder needed no change to handle them — this pins that claim,
// because "no decoder change is required" is exactly the kind of assertion that
// rots silently.
//
// The X10 case at the end is the one a selection handler must be written around:
// X10 has no per-button release code, so a release arrives with no button
// identity, and a drag handler that only accepts `(.release, .left)` would never
// see the gesture end on a terminal that ignored `?1006h`.

import DoMoTermIO
import Testing

private func sgrReport(_ button: Int, _ column: Int, _ row: Int, press: Bool = true) -> [UInt8] {
    Array("\u{1b}[<\(button);\(column);\(row)\(press ? "M" : "m")".utf8)
}

@Suite("Mouse drag reports")
struct MouseDragTests {

    @Test("A held-button drag decodes as a move that still names its button")
    func heldButtonMotion() {
        // 32 is the motion bit; the low two bits still carry the held button, which
        // is what tells a selection handler that THIS drag is the left-button one.
        let left = try! #require(decodeMouseEvent(sgrReport(32, 10, 5)))
        #expect(left.kind == .move)
        #expect(left.button == .left)
        #expect(left.column == 9)
        #expect(left.row == 4)
        #expect(left.isScroll == false)
        #expect(left.isButtonEvent == true)

        #expect(decodeMouseEvent(sgrReport(33, 10, 5))?.button == .middle)
        #expect(decodeMouseEvent(sgrReport(34, 10, 5))?.button == .right)
        #expect(decodeMouseEvent(sgrReport(33, 10, 5))?.kind == .move)
    }

    @Test("A right press is a press, not a move — right-click is the copy gesture")
    func rightPress() {
        let event = try! #require(decodeMouseEvent(sgrReport(2, 3, 7)))
        #expect(event.kind == .press)
        #expect(event.button == .right)
        #expect(event.isButtonEvent == true)
    }

    @Test("An SGR release names the button that came up")
    func sgrReleaseNamesItsButton() {
        let event = try! #require(decodeMouseEvent(sgrReport(0, 4, 4, press: false)))
        #expect(event.kind == .release)
        #expect(event.button == .left)
    }

    @Test("Shift-drag carries the modifier, so shift-click can extend a selection")
    func shiftDrag() {
        let event = try! #require(decodeMouseEvent(sgrReport(32 + 4, 12, 6)))
        #expect(event.kind == .move)
        #expect(event.button == .left)
        #expect(event.shift == true)
        #expect(event.alt == false)
        #expect(event.ctrl == false)
        // And a shift PRESS, which is the gesture that extends rather than restarts.
        #expect(decodeMouseEvent(sgrReport(4, 12, 6))?.shift == true)
        #expect(decodeMouseEvent(sgrReport(4, 12, 6))?.kind == .press)
    }

    @Test("Three-digit coordinates survive, so a drag on a wide terminal is not clamped")
    func wideTerminalCoordinates() {
        let event = try! #require(decodeMouseEvent(sgrReport(32, 213, 104)))
        #expect(event.column == 212)
        #expect(event.row == 103)
    }

    @Test("An X10 release has no button identity, which the drag handler must accept")
    func x10ReleaseIsButtonless() {
        // `ESC [ M` + (32 + 3) + col + row: X10 signals "some button came up" with
        // button bits 3 and no identity. A handler that matched only
        // `(.release, .left)` would leave the drag live forever on such a terminal.
        let event = try! #require(decodeMouseEvent([0x1b, 0x5b, 0x4d, UInt8(32 + 3), 33, 33]))
        #expect(event.kind == .release)
        #expect(event.button == .none)
        #expect(event.column == 0)
        #expect(event.row == 0)
    }

    @Test("An X10 button-less motion report is indistinguishable from a release")
    func x10MotionCollidesWithRelease() {
        // 32 (motion) + 3 (no button) = 35. This is the exact ambiguity that makes
        // `?1003h` unusable: the same bytes mean "pointer moved with nothing held"
        // and "a button came up", and the decoder resolves them to a release. Under
        // `?1002h` a terminal never sends this, which is why `?1002h` is the mode the
        // lifecycle enables.
        let event = try! #require(decodeMouseEvent([0x1b, 0x5b, 0x4d, 35, 40, 40]))
        #expect(event.kind == .release)
        #expect(event.button == .none)
    }

    @Test("The wheel is still a wheel, and is never a button gesture")
    func wheelIsNotAButtonEvent() {
        let up = try! #require(decodeMouseEvent(sgrReport(64, 5, 5)))
        #expect(up.isScroll == true)
        #expect(up.isButtonEvent == false)
        // Bit 32 is set on a wheel report from some terminals; it must not turn the
        // wheel into a drag.
        let dragWheel = try! #require(decodeMouseEvent(sgrReport(64 + 32, 5, 5)))
        #expect(dragWheel.isScroll == true)
        #expect(dragWheel.isButtonEvent == false)
    }
}
