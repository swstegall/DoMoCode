// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one entry point the CLI calls to run the full-screen client. It owns the
// AsyncHTTPClient lifecycle (created here, shut down on every exit path) so the
// CLI never has to import the transport package — it hands over a base URL, a
// token, and the live terminal collaborators, and gets back a session.

import AsyncHTTPClient
import DoMoCore
import DoMoTUI
import DoMoTermIO
import SystemPackage

/// The terminal state the full-screen client requires, as one named thing.
///
/// It exists because the alternative — the caller passing the right flags — is
/// what actually went wrong: the client shipped addressing absolute rows on the
/// NORMAL screen buffer, because the CLI constructed a default
/// ``TerminalLifecycle`` and no test could see the difference. The two flags are
/// not caller preferences, they are preconditions of this UI:
///
///  - **Alternate screen.** Frames are painted at absolute rows by
///    ``AltScreenCore``. On the normal buffer those frames overwrite the user's
///    scrollback, and any scroll of the real viewport permanently desynchronises
///    every later repaint — the UI then looks frozen, with new frames (including
///    an approval modal) landing off-viewport.
///  - **Mouse reporting.** A corollary of the first: the alternate screen has no
///    scrollback for the terminal to scroll, so the wheel must reach the app or
///    it does nothing at all.
///
/// A caller that wants a scripted, headless lifecycle still injects its own into
/// ``runFullScreenClient(baseURL:token:target:input:resize:lifecycle:)``.
///
/// `enableMouse` is the one genuine caller choice: a user who wants their
/// terminal's own selection back asks for it, and the app then never claims the
/// mouse at all.
@MainActor
public func fullScreenClientLifecycle(enableMouse: Bool = true) -> TerminalLifecycle {
    TerminalLifecycle(useAlternateScreen: true, enableMouse: enableMouse)
}

/// Run the two-pane full-screen client against a `domo --serve` runtime at
/// `baseURL`, authenticated with `token`, until the user quits.
///
/// Creates and tears down the shared ``HTTPClient`` (a leaked one traps on
/// deinit), so it is shut down on the normal return and on a throw alike. The
/// terminal collaborators are the same live seams the inline REPL uses; a test
/// can substitute scripted ones.
@MainActor
public func runFullScreenClient(
    baseURL: String,
    token: String,
    target: any RenderTarget,
    input: AsyncStream<[UInt8]>,
    resize: AsyncStream<TerminalSize>,
    lifecycle: any TerminalLifecycleControl,
    promptHistoryPath: FilePath? = nil,
    clipboard: any ClipboardSink = NoClipboardSink(),
    clipboardPaste: any ClipboardPasteSource = NoClipboardPasteSource(),
    multiplexer: TerminalMultiplexer = .none,
    mouseOwned: Bool = true
) async throws {
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let client = ServerClient(baseURL: baseURL, token: token, http: http)
    let app = ClientApp(
        client: client,
        historyStore: promptHistoryPath.map { PromptHistoryStore(path: $0) },
        clipboard: clipboard,
        clipboardPaste: clipboardPaste,
        multiplexer: multiplexer,
        mouseOwned: mouseOwned
    )
    do {
        try await app.run(target: target, input: input, resize: resize, lifecycle: lifecycle)
    } catch {
        try? await http.shutdown()
        throw error
    }
    try? await http.shutdown()
}
