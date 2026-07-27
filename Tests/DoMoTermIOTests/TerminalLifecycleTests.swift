// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The crash-safe teardown ordering is the load-bearing invariant of the
// alternate-screen mode: a crash between enter and a normal exit must leave the
// user on the normal buffer with a visible cursor. Driving the real lifecycle
// installs process-global signal/atexit handlers, so the byte *composition* is
// asserted directly through the public teardown seam instead — the same bytes the
// registration replays.

import DoMoTermIO
import Testing

@Suite("Terminal lifecycle teardown")
struct TerminalLifecycleTests {

    private let showCursor = Array("\u{1b}[?25h".utf8)
    private let disablePaste = Array("\u{1b}[?2004l".utf8)
    private let leaveAlternateScreen = Array("\u{1b}[?1049l".utf8)

    @Test("Inline teardown disables paste then shows cursor, with no alt-screen switch")
    func inlineTeardown() {
        let bytes = TerminalLifecycle.teardownSequence(useAlternateScreen: false)
        #expect(bytes == disablePaste + showCursor)
    }

    @Test("Full-screen teardown leaves the alternate screen LAST, after paste and cursor")
    func alternateScreenTeardownLeavesAltScreenLast() {
        let bytes = TerminalLifecycle.teardownSequence(useAlternateScreen: true)
        #expect(bytes == disablePaste + showCursor + leaveAlternateScreen)
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
        #expect(bytes == disableMouse + disablePaste + showCursor + leaveAlternateScreen)
        // A terminal left in `?1000h` after a crash types raw mouse escapes into the
        // user's shell, so releasing it is part of the crash-safe restore — and it
        // goes first, exactly reversing an enter that took the mouse last.
        #expect(Array(bytes.prefix(disableMouse.count)) == disableMouse, "mouse must be released first")
        #expect(
            Array(bytes.suffix(leaveAlternateScreen.count)) == leaveAlternateScreen,
            "?1049l must still be emitted last"
        )
    }

    @Test("Mouse is opt-in: the default teardown does not touch mouse modes")
    func mouseIsOptIn() {
        let inline = TerminalLifecycle.teardownSequence(useAlternateScreen: false)
        let fullScreen = TerminalLifecycle.teardownSequence(useAlternateScreen: true)
        #expect(!containsSubsequence(inline, disableMouse))
        #expect(!containsSubsequence(fullScreen, disableMouse))
    }

    private let disableMouse = Array("\u{1b}[?1006l\u{1b}[?1000l".utf8)

    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
