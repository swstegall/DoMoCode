// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The seam that lets one `TerminalDriver` drive either renderer. The driver was
// born hard-wired to the inline `TUI`; a full-screen coordinator (`ScreenSurface`)
// needs the exact same four things from the driver — render on demand, take framed
// input, hand back a `RenderTarget` for resize, and stop cleanly — so those four
// become a protocol both conform to. Nothing inline changes: `TUI` already has all
// four as public members, so its conformance is empty.

import DoMoCore

// MARK: - Terminal app

/// A renderable, input-taking coordinator a ``TerminalDriver`` can run.
///
/// The abstraction over "the thing bound to the terminal for one session": the
/// inline ``TUI`` and the full-screen ``ScreenSurface``. The driver speaks only
/// this protocol, so the same input pump, resize handler, and crash-safe restore
/// serve both rendering models — the whole point of *inline/full-screen
/// coexistence*.
///
/// `AnyObject` because the driver holds it `weak` (a session outlives no
/// coordinator). `Sendable` because the driver captures it into the `@Sendable`
/// child tasks of its run loop; both conformers are `@MainActor final class`es,
/// which are `Sendable` by construction, and every requirement here is
/// `MainActor`-isolated so the captured reference is only ever touched back on the
/// one actor.
@MainActor
public protocol TerminalApp: AnyObject, Sendable {
    /// Where frames are written, and the object a resize is applied to (the driver
    /// downcasts it to ``ResizableRenderTarget``).
    var target: any RenderTarget { get }

    /// Render one frame synchronously and write it. Throws on an over-wide line —
    /// the driver treats that as an unrecoverable frame and ends the session.
    func renderSync() throws(DoMoError)

    /// Handle one framed input sequence (a keypress or a bracketed paste).
    func handleInput(_ data: [UInt8])

    /// Stop scheduling further frames. Called from the driver's teardown `defer`.
    func stop()

    /// Called after raw mode and terminal-native setup are active, immediately
    /// before the first frame.
    func terminalDidEnter()

    /// Receive a terminal focus-in/focus-out report.
    func handleFocusChange(_ focused: Bool)
}

public extension TerminalApp {
    func terminalDidEnter() {}
    func handleFocusChange(_ focused: Bool) {}
}

// `TUI` already satisfies every requirement (`target`, `renderSync()`,
// `handleInput(_:)`, `stop()` are all public members), so coexistence costs the
// inline path exactly one empty conformance.
extension TUI: TerminalApp {}
