// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The sidebar: a focusable session list. Up/down (arrows or j/k) move a cursor,
// Enter opens the cursor's session, `n` starts a new one, and `b` returns from a
// delegated child to its parent. The open session is marked; the cursor row is
// highlighted only while the sidebar holds focus, so the user can see which pane
// is active.

import DoMoServer
import DoMoTUI
import Foundation

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
    /// Open the current session's parent, when it is a delegated child.
    var onBack: ((String) -> Void)?

    private var cursor = 0

    /// How many session rows are scrolled off the top. The list is clipped to the
    /// pane height by ``ComponentBox``, so without this a long session list simply
    /// has no way to reach its tail.
    private(set) var scrollOffset = 0

    /// The session currently under the pointer, if any. Hover is independent of
    /// keyboard focus so a pointer can preview a long label without moving the
    /// caret into the sidebar.
    private(set) var hoveredSessionID: String?
    /// Injectable for deterministic hover-marquee tests; production uses wall time.
    var clock: () -> Double = { Date().timeIntervalSinceReferenceDate }
    private var marqueeStates: [String: MarqueeState] = [:]

    private static let arrowUp: [UInt8] = [0x1b, 0x5b, 0x41]
    private static let arrowDown: [UInt8] = [0x1b, 0x5b, 0x42]

    /// The two header rows (title + rule) that are not session rows.
    private static let headerRows = 2

    /// Scroll the list by `delta` rows, clamped to the content. `viewportHeight` is
    /// the pane height the app knows and the component does not.
    func scroll(by delta: Int, viewportHeight: Int) {
        let visibleRows = max(1, viewportHeight - Self.headerRows)
        let maxOffset = max(0, sessions.count - visibleRows)
        scrollOffset = min(max(0, scrollOffset + delta), maxOffset)
        hoveredSessionID = nil
    }

    /// Update the pointer hover from a screen row. Header rows and empty rows clear
    /// the hover; session rows are translated through the current scroll offset.
    func updateHover(screenRow: Int) {
        let index = scrollOffset + screenRow - Self.headerRows
        guard index >= 0, index < sessions.count else {
            hoveredSessionID = nil
            return
        }
        hoveredSessionID = sessions[index].id
    }

    func clearHover() {
        hoveredSessionID = nil
    }

    func marqueeActive(width: Int) -> Bool {
        guard let hoveredSessionID,
              let session = sessions.first(where: { $0.id == hoveredSessionID })
        else { return false }
        let parts = sessionLabelParts(session)
        return Marquee.isNeeded(parts.body, width: bodyWidth(for: width, suffix: parts.suffix))
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        lines.append(truncateToWidth(dim("Sessions (n: new · b: parent)"), width))
        lines.append(String(repeating: "─", count: width))

        if sessions.isEmpty {
            lines.append(truncateToWidth(dim("  (none)"), width))
            return lines
        }
        let clampedCursor = min(cursor, sessions.count - 1)
        // Clamp here too: `sessions` can shrink between a scroll and a render.
        let offset = min(max(0, scrollOffset), max(0, sessions.count - 1))
        for (index, session) in sessions.enumerated().dropFirst(offset) {
            let label = sessionRow(session, width: width)
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
        case [0x62]:                                     // 'b' — parent session
            guard let currentID = openID,
                  let current = sessions.first(where: { $0.id == currentID }),
                  let parentPath = current.parentSession,
                  let parent = sessions.first(where: { $0.path == parentPath })
            else { return }
            onBack?(parent.id)
        default:
            break
        }
    }

    private func sessionRow(_ session: SessionSummary, width: Int) -> String {
        let marker = session.id == openID ? "• " : "  "
        let parts = sessionLabelParts(session)
        let budget = bodyWidth(for: width, suffix: parts.suffix)
        let identity = session.id + "\u{0}" + parts.body + "\u{0}" + String(budget)
        var state = marqueeStates[session.id] ?? MarqueeState()
        let body: String
        if session.id == hoveredSessionID {
            body = Marquee.render(
                parts.body,
                width: budget,
                identity: identity,
                now: clock(),
                state: &state
            )
        } else {
            state.reset(identity: identity, now: clock())
            body = truncateToWidth(parts.body, budget, ellipsis: "", pad: true)
        }
        marqueeStates[session.id] = state
        return truncateToWidth(marker + body + parts.suffix, width, ellipsis: "", pad: true)
    }

    private func bodyWidth(for width: Int, suffix: String) -> Int {
        max(0, width - 2 - visibleWidth(suffix))
    }

    /// A compact one-line label split so the open marker and trailing id stay at
    /// stable columns while a hovered body scrolls between them.
    ///
    /// Uses the id's TRAILING hex, which is random in a UUIDv7 — the leading hex is
    /// a time-ordered prefix that is identical for sessions created close together,
    /// so a prefix would render same-cwd siblings as indistinguishable rows.
    private func sessionLabelParts(_ session: SessionSummary) -> (body: String, suffix: String) {
        let shortID = String(session.id.suffix(6))
        let cwdName = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        let childMarker = session.parentSession == nil ? "" : "↳ "
        let suffix = "  " + shortID
        if let name = session.name, !name.isEmpty {
            return ("\(childMarker)\(sanitizeUntrustedText(name))  ·  \(sanitizeUntrustedText(cwdName))", suffix)
        }
        return ("\(childMarker)\(sanitizeUntrustedText(cwdName))", suffix)
    }
}
