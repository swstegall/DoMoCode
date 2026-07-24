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
}
