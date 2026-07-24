// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A terminal's saved line discipline plus the switch into and back out of raw
/// mode.
///
/// `swift-system` deliberately stops short of `termios`, so this is hand-written
/// over the platform C library — the reason `DoMoTermIO` is the one target that
/// imports `Darwin`/`Glibc`/`Musl`. The value type carries the *original*
/// `termios`, never the raw one: restoring means writing back exactly what was
/// there before, and a missed restore is not cosmetic — it leaves the user's
/// shell with `ECHO` and `ICANON` off, so typed characters are invisible and
/// line editing is dead until they blindly type `reset`.
public struct RawMode: Sendable {
    /// The descriptor whose line discipline was changed — the tty, normally
    /// `STDIN_FILENO`. Restore must target the same one.
    public let fileDescriptor: Int32

    /// The line discipline as it was before ``enable(on:)`` touched it.
    public let original: termios

    private init(fileDescriptor: Int32, original: termios) {
        self.fileDescriptor = fileDescriptor
        self.original = original
    }

    /// Read the current line discipline, switch the descriptor to raw, and return
    /// the token that restores it.
    ///
    /// Throws ``DoMoError`` with ``DoMoError/Kind/configuration`` when the
    /// descriptor is not a terminal (a pipe or file), because raw mode is
    /// meaningless there and `tcsetattr` would fail regardless — the caller
    /// should fall back to line-buffered input rather than press on.
    public static func enable(on fileDescriptor: Int32) throws(DoMoError) -> RawMode {
        guard isatty(fileDescriptor) == 1 else {
            throw DoMoError(.configuration, "cannot enable raw mode: fd \(fileDescriptor) is not a terminal")
        }

        var current = termios()
        guard tcgetattr(fileDescriptor, &current) == 0 else {
            let code = errno
            throw DoMoError(.configuration, "tcgetattr(fd \(fileDescriptor)) failed: \(String(cString: strerror(code)))")
        }

        var raw = makeRawTermios(from: current)
        // TCSAFLUSH so any bytes typed during the switch are discarded rather
        // than delivered under the new discipline, where a half-line of cooked
        // input would be reinterpreted as raw keystrokes.
        guard tcsetattr(fileDescriptor, TCSAFLUSH, &raw) == 0 else {
            let code = errno
            throw DoMoError(.configuration, "tcsetattr(fd \(fileDescriptor)) failed: \(String(cString: strerror(code)))")
        }

        return RawMode(fileDescriptor: fileDescriptor, original: current)
    }

    /// Write the saved discipline back.
    ///
    /// Best-effort and idempotent: it neither throws nor allocates, so it is safe
    /// on every teardown path including the signal and `atexit` restores in
    /// ``TerminalLifecycle``, and calling it twice simply writes the same bytes
    /// twice. A failed restore here has nowhere useful to report to — the process
    /// is usually already unwinding — so the result is discarded.
    public func restore() {
        var saved = original
        _ = tcsetattr(fileDescriptor, TCSAFLUSH, &saved)
    }

    /// Derive a raw discipline from a cooked one.
    ///
    /// Pure and side-effect free so the flag arithmetic can be asserted without a
    /// terminal. The cleared flags are exactly what upstream pi (via Node's
    /// `setRawMode`, i.e. libuv's tty raw mode) clears, and no more:
    ///
    /// - `c_lflag`: `ICANON` (line buffering), `ECHO`, `ISIG` (so Ctrl-C reaches
    ///   the app as a byte instead of raising `SIGINT`), `IEXTEN`.
    /// - `c_iflag`: `IXON` (flow control), `ICRNL` (CR→NL rewrite that would hide
    ///   Enter's real byte), `BRKINT`, `INPCK`, `ISTRIP`.
    /// - `VMIN = 1`, `VTIME = 0`: block for at least one byte, no read timer.
    ///
    /// `OPOST` is left **on**, which is the deliberate divergence from a textbook
    /// `cfmakeraw`. The renderer writes `\n` and relies on `OPOST`/`ONLCR` to add
    /// the carriage return; clearing it would stair-step every line. libuv keeps
    /// it for the same reason, so this matches the behaviour pi is built against.
    public static func makeRawTermios(from source: termios) -> termios {
        var raw = source

        let lflagClear = tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG) | tcflag_t(IEXTEN)
        raw.c_lflag &= ~lflagClear

        let iflagClear =
            tcflag_t(IXON) | tcflag_t(ICRNL) | tcflag_t(BRKINT) | tcflag_t(INPCK) | tcflag_t(ISTRIP)
        raw.c_iflag &= ~iflagClear

        setControlCharacter(&raw, VMIN, 1)
        setControlCharacter(&raw, VTIME, 0)
        return raw
    }
}

/// Set one `c_cc` control character by its index.
///
/// `c_cc` imports as a fixed-size homogeneous tuple, which Swift cannot subscript
/// by a runtime index, so it is rebound to a `cc_t` buffer. This is the kind of
/// pointer work that is why `DoMoTermIO` opts out of strict memory safety.
private func setControlCharacter(_ term: inout termios, _ index: Int32, _ value: cc_t) {
    withUnsafeMutablePointer(to: &term.c_cc) { tuplePointer in
        tuplePointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buffer in
            buffer[Int(index)] = value
        }
    }
}
