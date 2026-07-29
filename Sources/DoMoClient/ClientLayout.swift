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
//
// The footer stopped being a constant when the prompt learned to grow. A layout is
// therefore no longer a pure function of the terminal size: it is a function of the
// size AND of how tall the prompt made itself for the frame currently on screen. It
// still has exactly one field for that, `promptRows`, because two would drift.

/// Where the panes sit for a given terminal size and prompt height.
struct ClientLayout {
    let width: Int
    let height: Int
    /// The sidebar's column count; the main column takes the rest.
    let sidebarWidth: Int

    /// The rows the prompt occupies RIGHT NOW, attachment chip rows INCLUDED.
    ///
    /// There is exactly one footer-height field on purpose:
    /// ``PromptInput/height(forWidth:maxRows:)`` already budgets its chip rows
    /// inside the number it returns, so a separate `attachmentRows` would be a
    /// second derivation of the same quantity and would eventually disagree.
    let promptRows: Int

    /// The status line is still exactly one row.
    static let statusRows = 1

    init(width: Int, height: Int, promptRows: Int = 1) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.sidebarWidth = Self.sidebarWidth(for: self.width)
        self.promptRows = max(1, promptRows)
    }

    /// A quarter of the terminal, bounded to something usable — the rule the tree
    /// has always applied, now named.
    static func sidebarWidth(for width: Int) -> Int {
        min(32, max(16, width / 4))
    }

    /// The tallest the prompt may grow to at this terminal height.
    ///
    /// About a third of the screen, never below the 3 rows a bordered single-line
    /// editor wants, and — the part that is not cosmetic — never so tall that the
    /// transcript loses its last row. `Fixed.measure` returns its basis
    /// unconditionally (LayoutNode.swift) and `distributeMainAxis` hands the
    /// flexible children only `max(0, mainExtent - fixedTotal)` (Stack.swift), so
    /// an uncapped prompt first starves the transcript to zero rows and then
    /// overruns the rect, where it is silently clipped. This cap is the only thing
    /// standing between a long paste and that.
    static func promptRowCap(for height: Int) -> Int {
        let ceiling = Swift.max(3, height / 3)
        let roomLeavingOneTranscriptRow = height - statusRows - 1
        return Swift.max(1, Swift.min(ceiling, roomLeavingOneTranscriptRow))
    }

    /// The rows the main column spends below the transcript: the status line plus
    /// however tall the prompt currently is.
    var mainFooterRows: Int { Self.statusRows + promptRows }

    /// The transcript viewport's height, once the status line and prompt are taken.
    var transcriptHeight: Int {
        max(0, height - mainFooterRows)
    }

    /// The panes a pointer can land in.
    enum Pane {
        case sidebar
        case transcript
        /// The status line or the prompt — the bottom rows of the main column.
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

    /// The screen window a pane occupies, as half-open ranges.
    struct PaneBounds: Equatable {
        let columns: Range<Int>
        let rows: Range<Int>
    }

    /// Where a pane lives.
    ///
    /// Derived here, from the same `sidebarWidth` and `transcriptHeight` the hit
    /// test uses, for the reason this file's header gives: a second derivation of
    /// the same rectangle drifts from the first. A text selection is clamped to
    /// this window, so a drag that began in the transcript never cuts the sidebar
    /// into every copied line.
    ///
    /// `.sidebar` spans the full height because the sidebar is one column with no
    /// footer of its own — the status line and prompt live only in the main
    /// column.
    func bounds(of pane: Pane) -> PaneBounds {
        switch pane {
        case .sidebar:
            return PaneBounds(columns: 0..<min(sidebarWidth, width), rows: 0..<height)
        case .transcript:
            return PaneBounds(columns: min(sidebarWidth, width)..<width, rows: 0..<transcriptHeight)
        case .mainFooter:
            return PaneBounds(columns: min(sidebarWidth, width)..<width, rows: transcriptHeight..<height)
        }
    }
}
