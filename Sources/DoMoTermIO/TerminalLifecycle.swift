// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. `start`/`stop`, the enter/exit
// ordering, cursor hide/show and bracketed-paste enable map to
// `ProcessTerminal.start`/`stop`; the crash-safe restore is new — Node restores
// on `exit` and pi never runs the alternate screen, so this inherits pi's
// inline model and adds the POSIX signal plumbing Node did for it.
//
// The full-screen mode (`useAlternateScreen`) is a DoMoCode addition on top of
// pi's inline model: entering the DEC alternate screen buffer (`?1049h`) and,
// crucially, leaving it (`?1049l`) on every exit path a crash can take. pi never
// runs the alternate screen, so it never had to make the leave crash-safe; here
// the exit sequence lives inside the process-global restore registration so a
// signal or `atexit` restore can put the user back on their normal screen
// allocation-free, never stranding them on a blank alt buffer.

import DoMoCore
import Dispatch
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Output sequences

/// Hide the hardware cursor. The renderer paints its own, and a blinking real
/// cursor chasing the repaint is visible flicker.
private let hideCursorSequence: [UInt8] = Array("\u{1b}[?25l".utf8)
/// Show the cursor. Part of teardown.
private let showCursorSequence: [UInt8] = Array("\u{1b}[?25h".utf8)
/// Enable bracketed paste, so a paste arrives wrapped in `ESC[200~ … ESC[201~`
/// and the framer can hand it back as data instead of a burst of keystrokes.
private let enableBracketedPasteSequence: [UInt8] = Array("\u{1b}[?2004h".utf8)
/// Disable bracketed paste.
private let disableBracketedPasteSequence: [UInt8] = Array("\u{1b}[?2004l".utf8)
/// Enter the DEC alternate screen buffer (`?1049h`): save the cursor, switch to
/// a fresh full-screen buffer with no scrollback. Only written in full-screen
/// mode, and only to a real tty.
private let enterAlternateScreenSequence: [UInt8] = Array("\u{1b}[?1049h".utf8)
/// Leave the alternate screen buffer (`?1049l`): restore the normal buffer and
/// the saved cursor, exactly reversing `?1049h`. Part of the full-screen exit
/// sequence, and the byte a crash must never fail to emit.
private let exitAlternateScreenSequence: [UInt8] = Array("\u{1b}[?1049l".utf8)

/// The teardown bytes for the inline model: disable paste, then show cursor —
/// the exact reverse of the enter order. Preallocated so the restore path, which
/// may run from a signal or `atexit`, allocates nothing. Full-screen instances
/// register a longer sequence (see ``enterAlternateScreenSequence``); the exact
/// bytes to replay now travel inside ``RestoreRegistration`` rather than living
/// here, so `performRestore` needs no branch on the mode.
private let inlineExitSequence: [UInt8] = disableBracketedPasteSequence + showCursorSequence
/// The teardown bytes for full-screen mode: the inline sequence, then leave the
/// alternate screen (`?1049l` LAST — the exact reverse of enter, whose alt-screen
/// switch came first). Preallocated for the same allocation-free-restore reason.
private let alternateScreenExitSequence: [UInt8] = inlineExitSequence + exitAlternateScreenSequence

// MARK: - Global restore registry

/// What the crash-safe restore needs, held process-globally.
///
/// It has to be global because `atexit` takes a bare C function pointer that
/// cannot capture an instance, and because a signal-driven restore must reach
/// the saved discipline no matter which object still holds a reference. The
/// `Mutex` makes the register/perform race safe and — since `Mutex` is
/// unconditionally `Sendable` — lets the whole thing be a `nonisolated let`.
private struct RestoreRegistration {
    let rawMode: RawMode
    let outputDescriptor: Int32
    /// The exact teardown bytes to replay, chosen at register time by the mode:
    /// ``inlineExitSequence`` inline, ``alternateScreenExitSequence`` full-screen.
    /// Carried here — not selected in `performRestore` — so the restore stays a
    /// single unconditional `writeAll` that a signal or `atexit` can run
    /// allocation-free, and so a full-screen crash always emits `?1049l` last.
    let exitSequence: [UInt8]
}

private let restoreRegistration = Mutex<RestoreRegistration?>(nil)

/// Whether `atexit`/signal handlers have been installed. Installed once per
/// process; re-entering the lifecycle re-registers the discipline but not the
/// handlers.
private let handlersInstalled = Mutex<Bool>(false)

/// Restore the terminal, exactly once.
///
/// Allocation-free (the escape bytes are preallocated; the `termios` copy lives
/// on the stack) and idempotent: the registration is cleared under the lock
/// before the work runs, so a normal `stop()` followed by the `atexit` restore —
/// or two racing signals — writes the sequence and resets the discipline only
/// once. Written back in reverse of enter: escape sequences first, then the line
/// discipline, so `ECHO` returns last after the cursor is already visible.
private func performRestore() {
    let registration: RestoreRegistration? = restoreRegistration.withLock { slot in
        defer { slot = nil }
        return slot
    }
    guard let registration else { return }

    writeAll(registration.outputDescriptor, registration.exitSequence)
    registration.rawMode.restore()
}

/// Write every byte, retrying the short writes and `EINTR` that a signal-time
/// `write` invites.
private func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, base + offset, raw.count - offset)
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }
}

// MARK: - Lifecycle

/// Enters and leaves the TUI's terminal state, and guarantees the leave.
///
/// One object owns the whole reversible transaction — raw mode, hidden cursor,
/// bracketed paste, and (in full-screen mode) the alternate screen buffer — and
/// unwinds it in exact reverse on every exit: an ordinary ``stop()``, a
/// `SIGINT`/`SIGTERM`/`SIGHUP`, or process teardown via `atexit`.
///
/// Two modes, chosen at init:
///  - **Inline** (default) — pi's model: paint into normal scrollback with
///    relative cursor motion, which is what lets output stay in shell history.
///    There is no screen to switch away from, only cursor and input state to put
///    back.
///  - **Full-screen** (`useAlternateScreen`) — switch to the DEC alternate
///    screen buffer (`?1049h`) on enter and leave it (`?1049l`) on every exit.
///    The alt buffer is a fresh full-screen page with no scrollback, so the TUI
///    can address absolute rows without scrolling the user's transcript away.
///
/// The failure this exists to prevent is a crash between enter and a normal exit
/// leaving the user in a shell with no echo and an invisible cursor — and, in
/// full-screen mode, stranded on a blank alternate screen with their real
/// transcript hidden. That is why the restore, including `?1049l`, is wired to
/// signals and `atexit` and not merely to ``stop()``.
public final class TerminalLifecycle: Sendable {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    /// Whether enter switches to the alternate screen buffer and teardown leaves
    /// it. Fixed at init; it selects the exit sequence registered for the
    /// crash-safe restore.
    private let useAlternateScreen: Bool

    /// The signal sources, retained so they keep firing. Non-`Sendable`
    /// `DispatchSource`s live safely inside the `Mutex`, which serialises every
    /// access to them.
    private let sources = Mutex<[any DispatchSourceSignal]>([])

    /// - Parameters:
    ///   - inputDescriptor: the tty whose line discipline becomes raw — stdin.
    ///   - outputDescriptor: where cursor and paste sequences are written — stdout.
    ///   - useAlternateScreen: when true, enter the alternate screen buffer on
    ///     ``enter()`` and leave it on teardown. Defaults to false — the inline
    ///     model — so existing callers are unaffected.
    public init(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        useAlternateScreen: Bool = false
    ) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.useAlternateScreen = useAlternateScreen
    }

    /// The exact teardown bytes replayed on exit for a given mode.
    ///
    /// The single source ``enter()`` draws the registration's exit sequence from,
    /// exposed so the crash-safe ordering — paste disabled and cursor shown BEFORE
    /// the alternate screen is left, with `?1049l` LAST — can be asserted without
    /// standing up a real terminal. Because the registration uses this, the tested
    /// bytes are exactly the emitted bytes.
    public static func teardownSequence(useAlternateScreen: Bool) -> [UInt8] {
        useAlternateScreen ? alternateScreenExitSequence : inlineExitSequence
    }

    /// Enter raw mode, optionally switch to the alternate screen, hide the
    /// cursor, enable bracketed paste, and arm the crash-safe restore.
    ///
    /// Order matters and is the inverse of teardown: raw mode first (so a stray
    /// byte during setup is not echoed), then — in full-screen mode — the
    /// alternate-screen switch (`?1049h`) BEFORE the cursor and paste sequences,
    /// so no setup byte echoes onto the fresh alt page and the enter order
    /// (`?1049h` first) is the exact reverse of the exit order (`?1049l` last).
    /// The alt-screen switch is gated on `isatty(outputDescriptor)` so a
    /// redirected stdout never leaks `?1049h` into a file or pipe; the registered
    /// exit sequence still carries `?1049l` unconditionally, which a real
    /// terminal that never saw `?1049h` simply ignores.
    ///
    /// Registering the restore and installing the handlers is the last step, so a
    /// throw from `tcsetattr` leaves nothing half-registered.
    public func enter() throws(DoMoError) {
        let rawMode = try RawMode.enable(on: inputDescriptor)
        let onAlternateScreen = useAlternateScreen && isatty(outputDescriptor) == 1
        if onAlternateScreen {
            writeAll(outputDescriptor, enterAlternateScreenSequence)
        }
        writeAll(outputDescriptor, hideCursorSequence)
        writeAll(outputDescriptor, enableBracketedPasteSequence)

        let exitSequence = Self.teardownSequence(useAlternateScreen: useAlternateScreen)
        restoreRegistration.withLock { slot in
            slot = RestoreRegistration(
                rawMode: rawMode,
                outputDescriptor: outputDescriptor,
                exitSequence: exitSequence
            )
        }
        installHandlers()
    }

    /// Leave: show the cursor, disable bracketed paste, restore the discipline.
    /// Idempotent — safe to call after a signal already restored, and safe to
    /// call twice.
    public func stop() {
        performRestore()
    }

    /// Install the `SIGINT`/`SIGTERM`/`SIGHUP` and `atexit` restores, once per
    /// process.
    ///
    /// Each terminating signal is set to `SIG_IGN` and then observed through a
    /// `DispatchSource`; the handler restores and re-raises the default action so
    /// the process still dies with the right status, but with the terminal put
    /// back first. This is the README's rule made concrete: the handler does its
    /// work on a dispatch queue, and the C signal context does nothing but exist.
    private func installHandlers() {
        let alreadyInstalled = handlersInstalled.withLock { installed -> Bool in
            if installed { return true }
            installed = true
            return false
        }
        guard !alreadyInstalled else { return }

        atexit {
            performRestore()
        }

        let terminatingSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        var installed: [any DispatchSourceSignal] = []
        for signalNumber in terminatingSignals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                performRestore()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            installed.append(source)
        }
        sources.withLock { $0 = installed }
    }
}
