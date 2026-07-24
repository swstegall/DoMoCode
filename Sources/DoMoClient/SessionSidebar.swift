// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The sidebar: a focusable session list. Up/down (arrows or j/k) move a cursor,
// Enter opens the cursor's session, `n` starts a new one. The open session is
// marked; the cursor row is highlighted only while the sidebar holds focus, so
// the user can see which pane is active.

import DoMoServer
import DoMoTUI

/// A focusable list of sessions for the sidebar pane.
@MainActor
final class SessionSidebar: @MainActor Focusable {
    var focused = false

    /// The sessions to list; set from `EventStore.sessions` each frame.
    var sessions: [SessionSummary] = []
    /// The id of the currently-open session, marked in the list.
    var openID: String?

    /// Open the session at the cursor.
    var onSelect: ((String) -> Void)?
    /// Start a new session.
    var onNew: (() -> Void)?

    private var cursor = 0

    private static let arrowUp: [UInt8] = [0x1b, 0x5b, 0x41]
    private static let arrowDown: [UInt8] = [0x1b, 0x5b, 0x42]

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        lines.append(truncateToWidth(dim("Sessions (n: new)"), width))
        lines.append(String(repeating: "─", count: width))

        if sessions.isEmpty {
            lines.append(truncateToWidth(dim("  (none)"), width))
            return lines
        }
        let clampedCursor = min(cursor, sessions.count - 1)
        for (index, session) in sessions.enumerated() {
            let marker = session.id == openID ? "• " : "  "
            let label = padToWidth(truncateToWidth(marker + sessionLabel(session), width), width)
            lines.append(index == clampedCursor && focused ? inverse(label) : label)
        }
        return lines
    }

    func handleInput(_ data: [UInt8]) {
        guard !sessions.isEmpty else {
            if data == [0x6e] { onNew?() }   // 'n'
            return
        }
        switch data {
        case Self.arrowUp, [0x6b]:                       // up / k
            cursor = max(0, min(cursor, sessions.count - 1) - 1)
        case Self.arrowDown, [0x6a]:                     // down / j
            cursor = min(sessions.count - 1, cursor + 1)
        case [0x0d], [0x0a]:                             // Enter
            let index = min(cursor, sessions.count - 1)
            onSelect?(sessions[index].id)
        case [0x6e]:                                     // 'n' — new session
            onNew?()
        default:
            break
        }
    }

    /// A compact one-line label: the working-directory basename and a short id.
    ///
    /// Uses the id's TRAILING hex, which is random in a UUIDv7 — the leading hex is
    /// a time-ordered prefix that is identical for sessions created close together,
    /// so a prefix would render same-cwd siblings as indistinguishable rows.
    private func sessionLabel(_ session: SessionSummary) -> String {
        let shortID = String(session.id.suffix(6))
        let cwdName = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        return "\(cwdName)  \(shortID)"
    }
}
