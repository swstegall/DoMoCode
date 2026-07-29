// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The seam between the full-screen client and the system clipboard, and nothing
// else. The client knows it wants text on the clipboard; it does not know how to
// spawn a process, and it must not learn — DoMoClient has no subprocess
// dependency today, and growing one so a right-click can reach `pbcopy` would put
// process spawning inside the target that also speaks HTTP to a server.
//
// The implementation lives in DoMoCLI, which already depends on DoMoExec, and is
// injected as a `ClipboardSink`. The terminal-native half of a copy (OSC 52) needs
// no seam at all: it is bytes written to the tty the UI already owns, built by
// `osc52CopySequence` in DoMoTermIO.

/// What a clipboard write did.
///
/// A result rather than a `throws`, because a failed copy is a status-line notice,
/// never an error that should unwind a UI gesture: the OSC 52 half may well have
/// succeeded even when the local helper is missing, and the user does not care
/// about the mechanism until it fails.
public enum ClipboardOutcome: Sendable, Equatable {
    /// The text reached the clipboard through the named mechanism (`"pbcopy"`,
    /// `"wl-copy"`, …). The name is carried so a notice can say what happened
    /// rather than assert something it cannot verify.
    case copied(String)
    /// No local helper exists on this machine. Not a failure: over ssh this is the
    /// expected answer, and OSC 52 is the path that works there.
    case unavailable
    /// A helper existed and did not do the job. The payload is one line, already
    /// fit for a status notice.
    case failed(String)
}

/// Somewhere to put text so the user's other applications can paste it.
///
/// `Sendable` and `async` because every implementation worth having spawns a
/// process; the UI awaits it off its own gesture handling and reports the outcome
/// when it arrives.
public protocol ClipboardSink: Sendable {
    /// Put `text` on the SYSTEM clipboard. Best effort; never throws.
    func copy(_ text: String) async -> ClipboardOutcome
}

/// The sink for a client with no local helper — a bare `--url` attach, a headless
/// test, an ssh session.
///
/// OSC 52 alone carries the copy in that case, which is precisely the situation
/// OSC 52 exists for, so this is the correct default rather than a degraded one.
public struct NoClipboardSink: ClipboardSink {
    public init() {}

    public func copy(_ text: String) async -> ClipboardOutcome { .unavailable }
}
