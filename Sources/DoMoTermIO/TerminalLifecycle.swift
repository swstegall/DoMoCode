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
/// Reset the DEC scrolling margins before the shell receives the terminal.
private let resetScrollRegionSequence: [UInt8] = Array("\u{1b}[r".utf8)
/// Enable mouse reporting: `?1000h` turns on button/wheel reports, `?1002h` adds
/// motion reports *while a button is held*, and `?1006h` asks for all of them in
/// the SGR encoding (decimal, unbounded coordinates, press and release
/// distinguishable). Only written in full-screen mode — on the alternate screen
/// there is no scrollback for the terminal to scroll, so the wheel is the app's to
/// handle; inline, taking the mouse would break the user's own selection and
/// scrollback for no gain.
///
/// `?1002h` is what makes an in-app drag-selection possible at all. Under
/// `?1000h` alone a terminal reports the press and the release and *nothing in
/// between*, so an app can never learn where the pointer travelled and a drag is
/// indistinguishable from a click somewhere else. Button-event tracking reports
/// each cell the pointer crosses while a button is down — exactly the drag — and
/// stays silent when the pointer merely moves across the screen.
///
/// `?1003h` (any-motion tracking) is deliberately NOT enabled. It floods stdin on
/// every pointer move for no added capability, and its button-less motion reports
/// carry button bits `3`, which ``decodeMouseEvent(_:)``'s X10 release heuristic
/// reads as "a button came up" — so enabling it would synthesise phantom releases
/// that end a drag the user is still making.
private let enableMouseSequence: [UInt8] = Array("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8)
/// Disable mouse reporting, in the exact reverse of enable. A terminal left in
/// `?1000h`/`?1002h` after a crash types raw mouse escapes into the user's shell,
/// so this is part of the crash-safe restore, not merely of `stop()`.
private let disableMouseSequence: [UInt8] = Array("\u{1b}[?1006l\u{1b}[?1002l\u{1b}[?1000l".utf8)

/// Disable focus reports before handing stdin back to the shell.
private let disableFocusReportingSequence = TerminalNativeSequence.focusReportingSequence(enabled: false)
/// Reset both keyboard protocols. Terminals ignore a reset for a mode they did
/// not enable, while a crash after a successful handshake must not leak Kitty or
/// modifyOtherKeys encodings into the parent shell.
private let resetKeyboardProtocolSequence =
    TerminalNativeSequence.modifyOtherKeysSequence(enabled: false)
    + TerminalNativeSequence.disableKittyKeyboardProtocol()
/// Clear progress and the client-owned title on every exit path.
private let clearTerminalPresentationSequence =
    TerminalNativeSequence.progressSequence(.clear)
    + TerminalNativeSequence.clearTitleSequence()

/// The teardown bytes for the inline model: disable paste, show the cursor, reset
/// negotiated keyboard/focus modes, and clear client-owned presentation state.
/// Preallocated so the restore path, which may run from a signal or `atexit`,
/// allocates nothing. Full-screen instances register a longer sequence (see
/// ``enterAlternateScreenSequence``); the exact bytes to replay travel inside
/// ``RestoreRegistration`` rather than living here, so `performRestore` needs no
/// branch on the mode.
private let inlineExitSequence: [UInt8] =
    disableBracketedPasteSequence
    + showCursorSequence
    + resetKeyboardProtocolSequence
    + disableFocusReportingSequence
    + clearTerminalPresentationSequence
/// The teardown bytes for full-screen mode: the inline sequence, then leave the
/// alternate screen (`?1049l` LAST — the exact reverse of enter, whose alt-screen
/// switch came first). Preallocated for the same allocation-free-restore reason.
private let alternateScreenExitSequence: [UInt8] = inlineExitSequence + exitAlternateScreenSequence
/// Full-screen with the mouse taken: release the mouse FIRST (enter took it last),
/// then the ordinary full-screen teardown. Preallocated, like its siblings — the
/// four mode combinations are all precomputed so `performRestore` only ever
/// replays a stored array.
private let mouseInlineExitSequence: [UInt8] = disableMouseSequence + inlineExitSequence
private let mouseAlternateScreenExitSequence: [UInt8] = disableMouseSequence + alternateScreenExitSequence

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
    /// crash-safe restore. Readable so a caller's *choice* of terminal mode can be
    /// asserted without standing up a tty — the mode a UI needs is part of its
    /// contract, not an implementation detail of `enter()`.
    public let useAlternateScreen: Bool
    /// Whether enter takes over mouse reporting and teardown gives it back. Fixed
    /// at init, and readable, for the same reasons as ``useAlternateScreen``.
    public let enableMouse: Bool
    /// Whether teardown resets a DECSTBM scrolling region owned by the renderer.
    /// Mini mode sets this so the shell regains the full terminal on every exit.
    public let resetScrollRegion: Bool

    /// The signal sources, retained so they keep firing, and serialised by the
    /// `Mutex`.
    ///
    /// Boxed rather than stored bare: the `Mutex` serialises ACCESS, which is a
    /// different thing from making the element type `Sendable`, and on
    /// swift-corelibs-libdispatch `DispatchSourceSignal` is not — so assigning a
    /// task-isolated array of them through `withLock` is a hard error on Linux
    /// and compiles on Darwin. See ``DispatchSourceBox``.
    private let sources = Mutex<[DispatchSourceBox]>([])

    /// - Parameters:
    ///   - inputDescriptor: the tty whose line discipline becomes raw — stdin.
    ///   - outputDescriptor: where cursor and paste sequences are written — stdout.
    ///   - useAlternateScreen: when true, enter the alternate screen buffer on
    ///     ``enter()`` and leave it on teardown. Defaults to false — the inline
    ///     model — so existing callers are unaffected.
    ///   - enableMouse: when true, take over mouse reporting (`?1000h`/`?1006h`)
    ///     on ``enter()`` and give it back on teardown, so the app receives wheel
    ///     and click reports on stdin. Defaults to false; pair it with
    ///     `useAlternateScreen`, since inline the terminal's own scrollback is the
    ///     better owner of the wheel.
    public init(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        useAlternateScreen: Bool = false,
        enableMouse: Bool = false,
        resetScrollRegion: Bool = false
    ) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.useAlternateScreen = useAlternateScreen
        self.enableMouse = enableMouse
        self.resetScrollRegion = resetScrollRegion
    }

    /// The exact teardown bytes replayed on exit for a given mode.
    ///
    /// The single source ``enter()`` draws the registration's exit sequence from,
    /// exposed so the crash-safe ordering — mouse released FIRST, then paste
    /// disabled and cursor shown, with `?1049l` LAST — can be asserted without
    /// standing up a real terminal. Because the registration uses this, the tested
    /// bytes are exactly the emitted bytes.
    public static func teardownSequence(
        useAlternateScreen: Bool,
        enableMouse: Bool = false,
        resetScrollRegion: Bool = false
    ) -> [UInt8] {
        let base: [UInt8]
        switch (useAlternateScreen, enableMouse) {
        case (false, false): base = inlineExitSequence
        case (true, false): base = alternateScreenExitSequence
        case (false, true): base = mouseInlineExitSequence
        case (true, true): base = mouseAlternateScreenExitSequence
        }
        return resetScrollRegion ? resetScrollRegionSequence + base : base
    }

    /// The exact bytes that take (`enabled`) or release the mouse.
    ///
    /// The single source both ``enter()`` and ``setMouseReporting(_:)`` draw
    /// from, exposed for the same reason ``teardownSequence(useAlternateScreen:enableMouse:)``
    /// is: the release order must be provably the exact reverse of the take
    /// order, and that is an assertion no test should have to stand up a tty to
    /// make.
    public static func mouseSequence(enabled: Bool) -> [UInt8] {
        enabled ? enableMouseSequence : disableMouseSequence
    }

    /// The bytes used to negotiate Kitty keyboard reporting.
    public static func keyboardProtocolQuery() -> [UInt8] {
        TerminalNativeSequence.keyboardProtocolQuery()
    }

    /// The bytes used to select or clear xterm `modifyOtherKeys` mode 2.
    public static func modifyOtherKeysSequence(enabled: Bool) -> [UInt8] {
        TerminalNativeSequence.modifyOtherKeysSequence(enabled: enabled)
    }

    /// The bytes used to enable or disable focus-in/focus-out reports.
    public static func focusReportingSequence(enabled: Bool) -> [UInt8] {
        TerminalNativeSequence.focusReportingSequence(enabled: enabled)
    }

    /// Write the keyboard query to the live tty. The driver consumes the
    /// response and never forwards it to the focused app.
    public func beginKeyboardProtocolNegotiation() {
        writeIfActive(TerminalNativeSequence.keyboardProtocolQuery())
    }

    /// Select xterm `modifyOtherKeys` mode 2 as the keyboard fallback.
    public func setModifyOtherKeys(_ enabled: Bool) {
        writeIfActive(TerminalNativeSequence.modifyOtherKeysSequence(enabled: enabled))
    }

    /// Set the terminal title through OSC 0.
    public func setTitle(_ title: String) {
        writeIfActive(TerminalNativeSequence.titleSequence(title))
    }

    /// Update the terminal's progress indicator through OSC 9;4.
    public func setProgress(_ progress: TerminalProgress) {
        writeIfActive(TerminalNativeSequence.progressSequence(progress))
    }

    /// Show a desktop/terminal notification using the requested OSC format.
    public func notify(
        title: String,
        message: String,
        protocol: TerminalNotificationProtocol = .osc777
    ) {
        writeIfActive(
            TerminalNativeSequence.notificationSequence(
                title: title,
                message: message,
                protocol: `protocol`
            )
        )
    }

    /// Give the terminal a short quiet period after the input reader is stopped,
    /// so queued key-release/focus bytes cannot become shell input. The descriptor
    /// is made nonblocking for the drain and restored exactly as it was found.
    public func drainInput(maxMilliseconds: Int = 1_000, idleMilliseconds: Int = 50) {
        guard maxMilliseconds > 0, idleMilliseconds >= 0 else { return }
        guard let flags = NonblockingFileDescriptor.makeNonblocking(inputDescriptor) else { return }
        defer { flags.restore() }

        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + UInt64(maxMilliseconds) * 1_000_000
        var lastByte = started
        writeIfActive(resetKeyboardProtocolSequence + disableFocusReportingSequence)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return }
            switch NonblockingFileDescriptor.read(inputDescriptor) {
            case .bytes:
                lastByte = now
            case .wouldBlock:
                let idle = now >= lastByte ? (now - lastByte) / 1_000_000 : 0
                if idle >= UInt64(idleMilliseconds) { return }
                usleep(1_000)
            case .endOfFile, .error:
                return
            }
        }
    }

    /// Take or release mouse reporting *after* ``enter()``.
    ///
    /// This is the escape hatch behind an in-app selection: while the app owns
    /// the mouse the terminal emulator cannot run its own selection or its
    /// right-click menu, so a user whose terminal this program gets wrong needs a
    /// way to hand the mouse back without ending the session.
    ///
    /// Writes the same bytes ``enter()`` would have written and — the
    /// load-bearing half — REWRITES the registered crash-safe exit sequence so
    /// the current mode is released however the process dies. Without that
    /// rewrite a lifecycle constructed with `enableMouse: false` that later took
    /// the mouse would leave the terminal in `?1000h` after a `SIGINT`, typing
    /// raw mouse escapes into the user's shell — precisely the failure the
    /// crash-safe restore exists to prevent.
    ///
    /// A no-op when the output descriptor is not a tty (the same gate
    /// ``enter()`` applies, so a redirected stdout never collects tracking-mode
    /// escapes), and a no-op once the restore has already run: the registration
    /// is only ever UPDATED, never resurrected, so a `stop()` that already put
    /// the terminal back is not undone by a late toggle.
    ///
    /// Safe to call on a value: it mutates only the process-global registration,
    /// under its `Mutex`, which is why ``TerminalLifecycleControl`` can require
    /// it without also requiring `AnyObject`.
    public func setMouseReporting(_ enabled: Bool) {
        guard isatty(outputDescriptor) == 1 else { return }
        writeAll(outputDescriptor, Self.mouseSequence(enabled: enabled))
        let exitSequence = Self.teardownSequence(
            useAlternateScreen: useAlternateScreen,
            enableMouse: enabled,
            resetScrollRegion: resetScrollRegion
        )
        restoreRegistration.withLock { slot in
            guard let current = slot else { return }
            slot = RestoreRegistration(
                rawMode: current.rawMode,
                outputDescriptor: current.outputDescriptor,
                exitSequence: exitSequence
            )
        }
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
        // Mouse LAST, so teardown (which releases it first) is the exact reverse.
        // Gated on a real tty for the same reason the alt-screen switch is: a
        // redirected stdout must not collect tracking-mode escapes.
        if enableMouse, isatty(outputDescriptor) == 1 {
            writeAll(outputDescriptor, enableMouseSequence)
        }
        if isatty(outputDescriptor) == 1 {
            writeAll(outputDescriptor, TerminalNativeSequence.focusReportingSequence(enabled: true))
        }

        let exitSequence = Self.teardownSequence(
            useAlternateScreen: useAlternateScreen,
            enableMouse: enableMouse,
            resetScrollRegion: resetScrollRegion
        )
        restoreRegistration.withLock { slot in
            slot = RestoreRegistration(
                rawMode: rawMode,
                outputDescriptor: outputDescriptor,
                exitSequence: exitSequence
            )
        }
        installHandlers()
    }

    /// Leave: restore every terminal mode and presentation state, then restore the
    /// line discipline. Idempotent — safe to call after a signal already restored,
    /// and safe to call twice.
    public func stop() {
        performRestore()
    }

    /// Write a native sequence only while this lifecycle still owns an armed
    /// restore registration. Holding the registry lock across the write closes
    /// the small race in which a late task could emit after `stop()`.
    private func writeIfActive(_ bytes: [UInt8]) {
        guard isatty(outputDescriptor) == 1 else { return }
        restoreRegistration.withLock { slot in
            guard slot != nil else { return }
            writeAll(outputDescriptor, bytes)
        }
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
        var installed: [DispatchSourceBox] = []
        for signalNumber in terminatingSignals {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                performRestore()
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
            source.resume()
            installed.append(DispatchSourceBox(source))
        }
        sources.withLock { $0 = installed }
    }
}
