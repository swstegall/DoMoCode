// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The crash-safe teardown ordering is the load-bearing invariant of the
// alternate-screen mode: a crash between enter and a normal exit must leave the
// user on the normal buffer with a visible cursor. Driving the real lifecycle
// installs process-global signal/atexit handlers, so the byte *composition* is
// asserted directly through the public teardown seam instead — the same bytes the
// registration replays.
//
// That is composition only, and composition is not behaviour: every test here
// passes with `setMouseReporting`'s body deleted. MouseReportingLifecycleTests
// drives the real object against a pty for the parts that need a terminal — the
// bytes actually written, and the rewrite of the registered exit sequence.

import DoMoTermIO
import Testing

@Suite("Terminal lifecycle teardown")
struct TerminalLifecycleTests {

    private let showCursor = Array("\u{1b}[?25h".utf8)
    private let disablePaste = Array("\u{1b}[?2004l".utf8)
    private let leaveAlternateScreen = Array("\u{1b}[?1049l".utf8)
    private let resetKeyboard = Array("\u{1b}[>4;0m\u{1b}[<u".utf8)
    private let disableFocus = Array("\u{1b}[?1004l".utf8)
    private let clearPresentation = Array("\u{1b}]9;4;0;\u{07}\u{1b}]0;\u{07}".utf8)

    @Test("Inline teardown restores native modes after paste and cursor")
    func inlineTeardown() {
        let bytes = TerminalLifecycle.teardownSequence(useAlternateScreen: false)
        #expect(bytes == disablePaste + showCursor + resetKeyboard + disableFocus + clearPresentation)
    }

    @Test("Full-screen teardown leaves the alternate screen LAST, after paste and cursor")
    func alternateScreenTeardownLeavesAltScreenLast() {
        let bytes = TerminalLifecycle.teardownSequence(useAlternateScreen: true)
        #expect(bytes == disablePaste + showCursor + resetKeyboard + disableFocus + clearPresentation + leaveAlternateScreen)
        // ?1049l is the final run of bytes: a crash restores the normal buffer only
        // after the cursor is shown and paste is disabled, never stranding the user
        // on a blank alternate screen with an invisible cursor.
        #expect(
            Array(bytes.suffix(leaveAlternateScreen.count)) == leaveAlternateScreen,
            "?1049l must be emitted last"
        )
    }

    @Test("Mouse teardown releases the mouse FIRST, and still leaves the alt screen last")
    func mouseTeardownOrdering() {
        let bytes = TerminalLifecycle.teardownSequence(useAlternateScreen: true, enableMouse: true)
        #expect(bytes == disableMouse + disablePaste + showCursor + resetKeyboard + disableFocus + clearPresentation + leaveAlternateScreen)
        // A terminal left in `?1000h`/`?1002h` after a crash types raw mouse escapes
        // into the user's shell, so releasing it is part of the crash-safe restore —
        // and it goes first, exactly reversing an enter that took the mouse last.
        #expect(Array(bytes.prefix(disableMouse.count)) == disableMouse, "mouse must be released first")
        #expect(
            Array(bytes.suffix(leaveAlternateScreen.count)) == leaveAlternateScreen,
            "?1049l must still be emitted last"
        )
    }

    @Test("Mini-mode teardown resets DECSTBM before restoring the shell")
    func splitFooterTeardown() {
        let reset = Array("\u{1b}[r\u{1b}[999;1H".utf8)
        let bytes = TerminalLifecycle.teardownSequence(
            useAlternateScreen: false,
            resetScrollRegion: true
        )
        #expect(Array(bytes.prefix(reset.count)) == reset)
        #expect(Array(bytes.dropFirst(reset.count)) == TerminalLifecycle.teardownSequence(useAlternateScreen: false))
    }

    @Test("Taking the mouse enables button-event tracking, so a drag reports at all")
    func mouseEnableIncludesMotionTracking() {
        #expect(TerminalLifecycle.mouseSequence(enabled: true) == enableMouse)
        // `?1002h` is the whole reason a drag-selection is possible: under `?1000h`
        // alone a terminal reports the press and the release and nothing between.
        #expect(containsSubsequence(enableMouse, Array("\u{1b}[?1002h".utf8)))
        // `?1003h` is deliberately absent — its button-less motion reports carry the
        // same button bits X10 uses for a release, so it would end drags mid-gesture.
        #expect(!containsSubsequence(enableMouse, Array("\u{1b}[?1003h".utf8)))
    }

    @Test("The mouse release order is the exact reverse of the take order")
    func mouseDisableIsTheExactReverseOfEnable() {
        let taken = modes(in: TerminalLifecycle.mouseSequence(enabled: true))
        let released = modes(in: TerminalLifecycle.mouseSequence(enabled: false))
        #expect(taken == ["1000h", "1002h", "1006h"])
        #expect(released == ["1006l", "1002l", "1000l"])
        // Reversing the release order is what leaves a terminal half-configured when
        // a mode's disable depends on an outer mode still being set.
        #expect(released.map { String($0.dropLast()) } == taken.map { String($0.dropLast()) }.reversed())
        #expect(TerminalLifecycle.mouseSequence(enabled: false) == disableMouse)
    }

    @Test("Mouse is opt-in: the default teardown does not touch mouse modes")
    func mouseIsOptIn() {
        let inline = TerminalLifecycle.teardownSequence(useAlternateScreen: false)
        let fullScreen = TerminalLifecycle.teardownSequence(useAlternateScreen: true)
        for sequence in [inline, fullScreen] {
            #expect(!containsSubsequence(sequence, disableMouse))
            #expect(!containsSubsequence(sequence, Array("\u{1b}[?1000l".utf8)))
            #expect(!containsSubsequence(sequence, Array("\u{1b}[?1002l".utf8)))
            #expect(!containsSubsequence(sequence, Array("\u{1b}[?1006l".utf8)))
        }
        // And explicitly opting out says the same thing.
        #expect(TerminalLifecycle.teardownSequence(useAlternateScreen: true, enableMouse: false) == fullScreen)
    }

    @Test("setMouseReporting is a no-op off a tty, and never leaves the terminal changed")
    func setMouseReportingIsInertWithoutATTY() {
        // A closed descriptor is definitively not a terminal, which is what exercises
        // the `isatty` gate: the escape must not leak into a redirected stream, and
        // with no registration armed there is nothing to rewrite. It must not crash,
        // must not hang, and must be safe to call before `enter()` ever ran. Driving
        // the real stdout here would be a bug in the test — on a developer's terminal
        // it would take the mouse and never give it back.
        let lifecycle = TerminalLifecycle(
            outputDescriptor: -1,
            useAlternateScreen: true,
            enableMouse: true
        )
        lifecycle.setMouseReporting(false)
        lifecycle.setMouseReporting(true)
        // The declared mode is fixed at init and a mid-session toggle does not
        // rewrite it — only the registered exit bytes change.
        #expect(lifecycle.enableMouse == true)
        #expect(lifecycle.useAlternateScreen == true)
    }

    private let enableMouse = Array("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8)
    private let disableMouse = Array("\u{1b}[?1006l\u{1b}[?1002l\u{1b}[?1000l".utf8)

    /// The `?<digits><h|l>` private modes in a run of `ESC [ ? … h|l` sequences, in
    /// the order they are written.
    private func modes(in bytes: [UInt8]) -> [String] {
        String(decoding: bytes, as: UTF8.self)
            .split(separator: "\u{1b}", omittingEmptySubsequences: true)
            .compactMap { chunk in
                guard chunk.hasPrefix("[?") else { return nil }
                return String(chunk.dropFirst(2))
            }
    }

    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
