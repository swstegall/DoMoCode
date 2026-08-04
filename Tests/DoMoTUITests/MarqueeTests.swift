// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI
import Testing

@MainActor
@Suite("Marquee rendering")
struct MarqueeTests {
    @Test("a long row pauses, advances, pauses at the end, then resets")
    func pausesAndAdvancesDeterministically() {
        var state = MarqueeState()
        let text = "0123456789"

        #expect(Marquee.render(text, width: 5, identity: "row", now: 100, state: &state) == "01234")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 100.8, state: &state) == "01234")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 101.04, state: &state) == "01234")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 101.05, state: &state) == "12345")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 102.50, state: &state) == "56789")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 102.90, state: &state) == "56789")
        #expect(Marquee.render(text, width: 5, identity: "row", now: 103.10, state: &state) == "01234")
    }

    @Test("identity changes restart the leading pause and fitting text clears motion")
    func identityReset() {
        var state = MarqueeState()
        _ = Marquee.render("abcdefghij", width: 4, identity: "first", now: 10, state: &state)
        #expect(Marquee.render("abcdefghij", width: 4, identity: "second", now: 20, state: &state) == "abcd")
        #expect(Marquee.render("ok", width: 4, identity: "short", now: 30, state: &state) == "ok")
        #expect(!Marquee.isNeeded("ok", width: 4))
    }

    @Test("styled text keeps its visible width while it scrolls")
    func styledTextFits() {
        var state = MarqueeState()
        let styled = "\u{1b}[31mabcdef\u{1b}[0m"
        let result = Marquee.render(styled, width: 3, identity: "styled", now: 2, state: &state)
        #expect(visibleWidth(result) == 3)
    }
}
