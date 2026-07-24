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

/// The bytes written on teardown, in one buffer: disable paste, then show
/// cursor — the exact reverse of the enter order. Preallocated so the restore
/// path, which may run from a signal or `atexit`, allocates nothing.
private let exitSequence: [UInt8] = disableBracketedPasteSequence + showCursorSequence

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

    writeAll(registration.outputDescriptor, exitSequence)
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

/// Enters and leaves the inline TUI's terminal state, and guarantees the leave.
///
/// One object owns the whole reversible transaction — raw mode, hidden cursor,
/// bracketed paste — and unwinds it in exact reverse on every exit: an ordinary
/// ``stop()``, a `SIGINT`/`SIGTERM`/`SIGHUP`, or process teardown via `atexit`.
/// Inline, never the alternate screen: pi paints into normal scrollback with
/// relative cursor motion, which is what lets its output stay in shell history,
/// so there is no screen to switch away from — only cursor and input state to
/// put back.
///
/// The failure this exists to prevent is a crash between enter and a normal
/// exit leaving the user in a shell with no echo and an invisible cursor. That
/// is why the restore is wired to signals and `atexit` and not merely to
/// ``stop()``.
public final class TerminalLifecycle: Sendable {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32

    /// The signal sources, retained so they keep firing. Non-`Sendable`
    /// `DispatchSource`s live safely inside the `Mutex`, which serialises every
    /// access to them.
    private let sources = Mutex<[any DispatchSourceSignal]>([])

    /// - Parameters:
    ///   - inputDescriptor: the tty whose line discipline becomes raw — stdin.
    ///   - outputDescriptor: where cursor and paste sequences are written — stdout.
    public init(inputDescriptor: Int32 = STDIN_FILENO, outputDescriptor: Int32 = STDOUT_FILENO) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
    }

    /// Enter raw mode, hide the cursor, enable bracketed paste, and arm the
    /// crash-safe restore.
    ///
    /// Order matters and is the inverse of teardown: raw mode first (so a stray
    /// byte during setup is not echoed), then the output sequences. Registering
    /// the restore and installing the handlers is the last step, so a throw from
    /// `tcsetattr` leaves nothing half-registered.
    public func enter() throws(DoMoError) {
        let rawMode = try RawMode.enable(on: inputDescriptor)
        writeAll(outputDescriptor, hideCursorSequence)
        writeAll(outputDescriptor, enableBracketedPasteSequence)

        restoreRegistration.withLock { slot in
            slot = RestoreRegistration(rawMode: rawMode, outputDescriptor: outputDescriptor)
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
