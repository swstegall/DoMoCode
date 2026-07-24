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

/// Run the two-pane full-screen client against a `domo serve` runtime at
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
    lifecycle: any TerminalLifecycleControl
) async throws {
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let client = ServerClient(baseURL: baseURL, token: token, http: http)
    let app = ClientApp(client: client)
    do {
        try await app.run(target: target, input: input, resize: resize, lifecycle: lifecycle)
    } catch {
        try? await http.shutdown()
        throw error
    }
    try? await http.shutdown()
}
