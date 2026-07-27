// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two-pane geometry, in one place.
//
// `buildTree` used to be the only thing that knew where the panes are, which was
// fine while input arrived as keystrokes — a keystroke goes to whoever holds focus
// and needs no coordinates. A mouse report carries a column and a row, so
// something has to turn those into "which pane is that". Deriving it twice, once
// in the tree and once in the hit test, is how the two silently drift apart; this
// is the single derivation both use.

/// Where the panes sit for a given terminal size.
struct ClientLayout {
    let width: Int
    let height: Int
    /// The sidebar's column count; the main column takes the rest.
    let sidebarWidth: Int

    /// The rows the main column spends on its status line and prompt, below the
    /// transcript.
    static let mainFooterRows = 2

    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.sidebarWidth = Self.sidebarWidth(for: self.width)
    }

    /// A quarter of the terminal, bounded to something usable — the rule the tree
    /// has always applied, now named.
    static func sidebarWidth(for width: Int) -> Int {
        min(32, max(16, width / 4))
    }

    /// The transcript viewport's height, once the status line and prompt are taken.
    var transcriptHeight: Int {
        max(0, height - Self.mainFooterRows)
    }

    /// The panes a pointer can land in.
    enum Pane {
        case sidebar
        case transcript
        /// The status line or the prompt — the bottom two rows of the main column.
        case mainFooter
    }

    /// Which pane contains a 0-based screen position.
    ///
    /// Out-of-range positions resolve to the nearest pane rather than to `nil`: a
    /// terminal can report a coordinate one past the edge during a resize, and a
    /// dropped scroll event reads to the user as a dead wheel.
    func pane(atColumn column: Int, row: Int) -> Pane {
        if column < sidebarWidth { return .sidebar }
        return row < transcriptHeight ? .transcript : .mainFooter
    }
}
