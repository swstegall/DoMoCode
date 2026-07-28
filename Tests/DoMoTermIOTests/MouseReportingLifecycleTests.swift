// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `setMouseReporting` driven against a REAL tty.
//
// The rest of TerminalLifecycleTests asserts byte composition through the static
// `teardownSequence`/`mouseSequence` seams, which is exactly the right shape for a
// pure ordering question — and exactly the wrong shape for this one. Both existing
// `setMouseReporting` tests construct with `outputDescriptor: -1`, so the `isatty`
// guard returns before a single byte is written or a single registration is
// rewritten: the whole method body can be replaced with `{}` and the suite stays
// green. Nothing then covers the half its own docstring calls load-bearing — that
// taking the mouse mid-session REWRITES the crash-safe exit sequence, so a
// lifecycle built with `enableMouse: false` that later takes the mouse still
// releases it when the process dies instead of leaving the user's shell filling
// with raw mouse escapes.
//
// A pty gives a genuine tty (`isatty == 1`) with no controlling terminal, so the
// real path runs and the master end sees the exact bytes. `stop()` is used as the
// probe for the registration because it replays it verbatim: asserting the bytes
// `stop()` emits IS asserting what a `SIGINT` or an `atexit` would have emitted.
//
// The master end is drained by a DEDICATED THREAD, not polled between assertions.
// `RawMode.restore()` ends in `tcsetattr(..., TCSAFLUSH, ...)`, and TCSAFLUSH
// blocks until the terminal's output queue has drained — on a pty that means until
// the master has read every byte. A test that only reads between calls deadlocks
// inside `stop()`, with the teardown bytes it is about to assert sitting unread in
// the very queue it is waiting on.
//
// SERIALIZED, because `enter()` writes a PROCESS-GLOBAL restore registration: two
// of these running concurrently would each observe the other's.

import DoMoCore
import DoMoTermIO
import Foundation
import Synchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A thread that keeps the master end of a pty drained for as long as the test
/// runs, so the slave's output queue never fills and `tcsetattr(TCSAFLUSH)` never
/// blocks.
///
/// The reads are NON-blocking and the loop is polled. A blocking `read` would be
/// simpler and is a trap: `close()` on macOS does not wake a thread parked inside
/// `read` on that descriptor, so tearing the pty down would deadlock in `close`
/// instead of in `tcsetattr` — the same hang, one frame further along.
private final class MasterTap: Sendable {
    private let collected = Mutex<[UInt8]>([])
    private let running = Mutex<Bool>(true)
    private let finished = Mutex<Bool>(false)

    init(master: Int32) {
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while self.running.withLock({ $0 }) {
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    read(master, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    self.collected.withLock { $0.append(contentsOf: buffer[0..<count]) }
                    continue
                }
                usleep(500)
            }
            self.finished.withLock { $0 = true }
        }
    }

    /// Everything the master has seen since the last call.
    ///
    /// Waits for the byte count to stop growing rather than for a fixed delay, so
    /// a sequence split across two `read`s is never asserted half-arrived. With
    /// `expectingBytes: false` the wait is for silence instead.
    func take(expectingBytes: Bool = true) -> [UInt8] {
        var previous = -1
        var stableRounds = 0
        for _ in 0..<600 {
            let count = collected.withLock { $0.count }
            if count == previous, expectingBytes ? count > 0 : true {
                stableRounds += 1
                if stableRounds >= 4 { break }
            } else {
                stableRounds = 0
            }
            previous = count
            usleep(1000)
        }
        return collected.withLock { value in
            defer { value = [] }
            return value
        }
    }

    /// Stop the reader and WAIT for it, so the descriptors can be closed without
    /// the loop touching a stale (possibly reused) file descriptor.
    func shutdown() {
        running.withLock { $0 = false }
        for _ in 0..<2000 where !finished.withLock({ $0 }) {
            usleep(500)
        }
    }
}

@Suite("Mouse reporting on a real tty", .serialized)
struct MouseReportingLifecycleTests {

    private let enableMouseBytes = Array("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8)
    private let disableMouseBytes = Array("\u{1b}[?1006l\u{1b}[?1002l\u{1b}[?1000l".utf8)
    private let leaveAlternateScreen = Array("\u{1b}[?1049l".utf8)

    private func withLifecycle(
        useAlternateScreen: Bool,
        enableMouse: Bool,
        _ body: (MasterTap, TerminalLifecycle) throws -> Void
    ) rethrows {
        guard let pty = PTYPair() else {
            withKnownIssue("no pty available") { Issue.record("pty unavailable") }
            return
        }
        #expect(
            isatty(pty.slave) == 1,
            "the slave must be a genuine tty, or the isatty gate makes this whole suite vacuous"
        )
        let tap = MasterTap(master: pty.master)
        let lifecycle = TerminalLifecycle(
            inputDescriptor: pty.slave,
            outputDescriptor: pty.slave,
            useAlternateScreen: useAlternateScreen,
            enableMouse: enableMouse
        )
        // Unwind before the descriptors go, so a failed expectation cannot leave
        // the process-global registration pointing at a closed descriptor.
        defer {
            lifecycle.stop()
            tap.shutdown()
            pty.cleanup()
        }
        try body(tap, lifecycle)
    }

    @Test("Taking the mouse mid-session writes the enable bytes to the terminal")
    func setMouseReportingWritesToTheTTY() throws {
        try withLifecycle(useAlternateScreen: true, enableMouse: false) { tap, lifecycle in
            try lifecycle.enter()
            let entry = tap.take()
            #expect(!entry.isEmpty, "enter() wrote nothing to a real tty")
            #expect(
                !containsSubsequence(entry, enableMouseBytes),
                "a lifecycle built with enableMouse: false must not take the mouse on enter"
            )

            lifecycle.setMouseReporting(true)
            #expect(
                tap.take() == enableMouseBytes,
                "setMouseReporting(true) must write exactly the bytes mouseSequence(enabled: true) names"
            )

            lifecycle.setMouseReporting(false)
            #expect(tap.take() == disableMouseBytes)
        }
    }

    @Test("Taking the mouse mid-session REWRITES the crash-safe exit sequence")
    func setMouseReportingRewritesTheRegisteredTeardown() throws {
        try withLifecycle(useAlternateScreen: true, enableMouse: false) { tap, lifecycle in
            try lifecycle.enter()
            _ = tap.take()
            lifecycle.setMouseReporting(true)
            _ = tap.take()

            // `stop()` replays the registration verbatim, so these are the bytes a
            // SIGINT or an `atexit` would emit. Without the rewrite the process
            // would die with the terminal still in ?1000h/?1002h, typing raw mouse
            // escapes into the user's shell.
            lifecycle.stop()
            let teardown = tap.take()
            #expect(
                teardown == TerminalLifecycle.teardownSequence(useAlternateScreen: true, enableMouse: true),
                "the registered exit sequence was not rewritten to release the mouse"
            )
            #expect(
                Array(teardown.prefix(disableMouseBytes.count)) == disableMouseBytes,
                "the mouse must be released FIRST, exactly reversing an enter that took it last"
            )
            #expect(
                Array(teardown.suffix(leaveAlternateScreen.count)) == leaveAlternateScreen,
                "?1049l must still be emitted last"
            )
        }
    }

    @Test("Giving the mouse BACK mid-session rewrites the teardown to the mouse-free form")
    func releasingTheMouseRestoresTheMouseFreeTeardown() throws {
        // The escape hatch this method exists for: a user whose terminal this
        // program gets wrong hands the mouse back and keeps working. If the
        // registration still said "release the mouse", teardown would emit
        // tracking-mode escapes at a terminal no longer in tracking mode.
        try withLifecycle(useAlternateScreen: true, enableMouse: true) { tap, lifecycle in
            try lifecycle.enter()
            let entry = tap.take()
            #expect(
                containsSubsequence(entry, enableMouseBytes),
                "a lifecycle built with enableMouse: true must take the mouse on enter"
            )

            lifecycle.setMouseReporting(false)
            #expect(tap.take() == disableMouseBytes)

            lifecycle.stop()
            let teardown = tap.take()
            #expect(teardown == TerminalLifecycle.teardownSequence(useAlternateScreen: true, enableMouse: false))
            #expect(
                !containsSubsequence(teardown, disableMouseBytes),
                "the mouse was already released; teardown must not release it again"
            )
        }
    }

    @Test("A toggle after the restore has already run does not resurrect the registration")
    func aLateToggleDoesNotResurrectTheRegistration() throws {
        try withLifecycle(useAlternateScreen: true, enableMouse: true) { tap, lifecycle in
            try lifecycle.enter()
            _ = tap.take()
            lifecycle.stop()
            _ = tap.take()

            // The registration is only ever UPDATED, never re-armed: a `stop()` that
            // already put the terminal back must not be undone by a late toggle.
            lifecycle.setMouseReporting(true)
            #expect(tap.take() == enableMouseBytes, "the toggle still writes; only the registration is inert")
            lifecycle.stop()
            #expect(
                tap.take(expectingBytes: false).isEmpty,
                "a second stop() replayed a registration that should have been cleared"
            )
        }
    }

    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}
