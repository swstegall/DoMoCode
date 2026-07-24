// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

import DoMoCore
import DoMoTermIO

// A pseudo-terminal gives a real tty pair without a controlling terminal, so raw
// mode and window-size ioctls run in CI. Where even that is unavailable the
// tests skip rather than fail.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A master/slave pty pair. `slave` is a genuine tty (`isatty == 1`).
struct PTYPair {
    let master: Int32
    let slave: Int32

    init?() {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            _ = close(master)
            return nil
        }
        guard let name = ptsname(master) else {
            _ = close(master)
            return nil
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            _ = close(master)
            return nil
        }
        self.master = master
        self.slave = slave
    }

    func cleanup() {
        _ = close(master)
        _ = close(slave)
    }
}

private func readControlCharacter(_ term: inout termios, _ index: Int32) -> cc_t {
    withUnsafeMutablePointer(to: &term.c_cc) { pointer in
        pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buffer in
            buffer[Int(index)]
        }
    }
}

@Suite("Raw mode")
struct RawModeTests {

    // MARK: Pure flag arithmetic (no TTY)

    @Test("makeRawTermios clears the local and input flags pi clears")
    func makeRawClearsFlags() {
        var cooked = termios()
        cooked.c_lflag = tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG) | tcflag_t(IEXTEN)
        cooked.c_iflag =
            tcflag_t(IXON) | tcflag_t(ICRNL) | tcflag_t(BRKINT) | tcflag_t(INPCK) | tcflag_t(ISTRIP)
        cooked.c_oflag = tcflag_t(OPOST)

        var raw = RawMode.makeRawTermios(from: cooked)

        #expect(raw.c_lflag & tcflag_t(ICANON) == 0)
        #expect(raw.c_lflag & tcflag_t(ECHO) == 0)
        #expect(raw.c_lflag & tcflag_t(ISIG) == 0)
        #expect(raw.c_lflag & tcflag_t(IEXTEN) == 0)

        #expect(raw.c_iflag & tcflag_t(IXON) == 0)
        #expect(raw.c_iflag & tcflag_t(ICRNL) == 0)
        #expect(raw.c_iflag & tcflag_t(BRKINT) == 0)
        #expect(raw.c_iflag & tcflag_t(INPCK) == 0)
        #expect(raw.c_iflag & tcflag_t(ISTRIP) == 0)

        #expect(readControlCharacter(&raw, VMIN) == 1)
        #expect(readControlCharacter(&raw, VTIME) == 0)
    }

    @Test("makeRawTermios preserves OPOST so newline translation still happens")
    func makeRawPreservesOPOST() {
        var cooked = termios()
        cooked.c_oflag = tcflag_t(OPOST)
        let raw = RawMode.makeRawTermios(from: cooked)
        #expect(raw.c_oflag & tcflag_t(OPOST) != 0)
    }

    @Test("makeRawTermios leaves other local flags untouched")
    func makeRawLeavesUnrelatedFlags() {
        var cooked = termios()
        cooked.c_lflag = tcflag_t(TOSTOP) | tcflag_t(ICANON)
        let raw = RawMode.makeRawTermios(from: cooked)
        #expect(raw.c_lflag & tcflag_t(TOSTOP) != 0)
        #expect(raw.c_lflag & tcflag_t(ICANON) == 0)
    }

    // MARK: Non-tty rejection

    @Test("Enabling raw mode on a pipe throws configuration")
    func enableOnPipeThrows() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        // `enable` is `throws(DoMoError)`, so the caught error is already typed.
        do {
            _ = try RawMode.enable(on: fds[0])
            Issue.record("expected a throw on a non-tty descriptor")
        } catch {
            #expect(error.kind == .configuration)
        }
    }

    // MARK: Real tty round-trip (PTY)

    @Test("Enable then restore round-trips the discipline on a pty")
    func enableRestoreRoundTrip() throws {
        guard let pty = PTYPair() else {
            withKnownIssue("no pty available") { Issue.record("pty unavailable") }
            return
        }
        defer { pty.cleanup() }

        var before = termios()
        #expect(tcgetattr(pty.slave, &before) == 0)
        #expect(before.c_lflag & tcflag_t(ICANON) != 0)

        let raw = try RawMode.enable(on: pty.slave)

        var duringRaw = termios()
        #expect(tcgetattr(pty.slave, &duringRaw) == 0)
        #expect(duringRaw.c_lflag & tcflag_t(ICANON) == 0)
        #expect(duringRaw.c_lflag & tcflag_t(ECHO) == 0)

        raw.restore()

        var afterRestore = termios()
        #expect(tcgetattr(pty.slave, &afterRestore) == 0)
        #expect(afterRestore.c_lflag & tcflag_t(ICANON) != 0)
    }

    @Test("Restore is idempotent")
    func restoreIdempotent() throws {
        guard let pty = PTYPair() else {
            withKnownIssue("no pty available") { Issue.record("pty unavailable") }
            return
        }
        defer { pty.cleanup() }

        let raw = try RawMode.enable(on: pty.slave)
        raw.restore()
        raw.restore()
        raw.restore()

        var term = termios()
        #expect(tcgetattr(pty.slave, &term) == 0)
        #expect(term.c_lflag & tcflag_t(ICANON) != 0)
    }
}
