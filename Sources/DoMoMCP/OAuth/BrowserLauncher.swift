// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Opening the system browser on the authorize URL — behind a protocol,
// because tests must never open a browser, and headless machines cannot.
// Failure is a soft outcome, not an error: the URL is always printed too, so
// a user whose `open` is broken (or absent, on a bare Linux box) pastes it by
// hand and the flow continues unchanged.

import Subprocess

/// Opens a URL in the user's browser. `false` means "could not launch";
/// callers must already have shown the URL for manual use.
public protocol BrowserLaunching: Sendable {
    func open(_ url: String) async -> Bool
}

/// `open(1)` on macOS, `xdg-open(1)` elsewhere.
public struct SystemBrowserLauncher: BrowserLaunching {
    public init() {}

    public func open(_ url: String) async -> Bool {
        #if os(macOS)
        let executable = Subprocess.Executable.path("/usr/bin/open")
        #else
        let executable = Subprocess.Executable.name("xdg-open")
        #endif
        do {
            let result = try await Subprocess.run(
                executable,
                arguments: Subprocess.Arguments([url]),
                output: .discarded,
                error: .discarded
            )
            return result.terminationStatus.isSuccess
        } catch {
            return false
        }
    }
}
