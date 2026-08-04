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
    /// The sidebar's content column count. When there is room, the divider is
    /// immediately after this column and the main column starts one cell later.
    let sidebarWidth: Int

    /// The theme-colored separator between the sidebar and main column.
    static let dividerWidth = 1

    /// The rows the prompt occupies RIGHT NOW, attachment chip rows INCLUDED.
    ///
    /// There is exactly one footer-height field on purpose:
    /// ``PromptInput/height(forWidth:maxRows:)`` already budgets its chip rows
    /// inside the number it returns, so a separate `attachmentRows` would be a
    /// second derivation of the same quantity and would eventually disagree.
    let promptRows: Int

    /// The status line is still exactly one row.
    static let statusRows = 1

    /// The rows the accounting footer occupies: 1 when the app is painting it,
    /// 0 when it is not.
    ///
    /// A parameter rather than a constant because the app decides — see
    /// ``footerRows(for:)`` — and because a geometry asked about for its own sake
    /// (a pane hit test in a unit test, say) should describe the layout it was
    /// asked about rather than assume one.
    let footerRows: Int

    /// The shortest terminal that still gets an accounting footer.
    ///
    /// A second `Fixed` row is not free: `Fixed.measure` returns its basis
    /// unconditionally and `distributeMainAxis` hands the flexible transcript
    /// only `max(0, mainExtent - fixedTotal)`, so the footer's row comes straight
    /// out of the transcript. At 10 rows the split is status 1 + footer 1 +
    /// prompt 3 + transcript 5, which is the point below which the conversation
    /// stops being readable — so below it the footer, not the transcript, is what
    /// gives way.
    static let minimumFooterHeight = 10

    /// Whether a terminal this tall can afford the footer.
    static func footerRows(for height: Int) -> Int {
        height >= minimumFooterHeight ? 1 : 0
    }

    init(width: Int, height: Int, promptRows: Int = 1, footerRows: Int = 0) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.sidebarWidth = min(Self.sidebarWidth(for: self.width), self.width)
        self.promptRows = max(1, promptRows)
        self.footerRows = max(0, min(1, footerRows))
    }

    /// A quarter of the terminal, bounded to something usable — the rule the tree
    /// has always applied, now named.
    static func sidebarWidth(for width: Int) -> Int {
        min(32, max(16, width / 4))
    }

    /// The first column available to the main pane. This is the one geometry
    /// calculation the tree and coordinate-based consumers must share.
    static func mainColumnStart(for width: Int) -> Int {
        let clampedWidth = max(0, width)
        let sidebar = min(sidebarWidth(for: clampedWidth), clampedWidth)
        return min(clampedWidth, sidebar + (sidebar < clampedWidth ? dividerWidth : 0))
    }

    /// The first main-pane column for this layout.
    var mainColumnStart: Int { Self.mainColumnStart(for: width) }

    /// The width left for the transcript, footer, and prompt.
    var mainWidth: Int { max(0, width - mainColumnStart) }

    /// The divider column, when the terminal is wide enough to show one.
    var dividerColumn: Int? {
        guard sidebarWidth < width else { return nil }
        return sidebarWidth
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
    /// - Parameter footerRows: the accounting footer's rows, so the cap accounts
    ///   for the row it takes too. Defaulted to 0 — the geometry without a
    ///   footer — so every caller that does not paint one is unchanged. At the
    ///   heights the app actually asks for a footer (``minimumFooterHeight`` and
    ///   up) the `height / 3` ceiling is always the binding constraint, so this
    ///   term changes nothing TODAY; it is here so that lowering that threshold
    ///   cannot silently start starving the transcript again.
    static func promptRowCap(for height: Int, footerRows: Int = 0) -> Int {
        let ceiling = Swift.max(3, height / 3)
        let roomLeavingOneTranscriptRow = height - statusRows - Swift.max(0, footerRows) - 1
        return Swift.max(1, Swift.min(ceiling, roomLeavingOneTranscriptRow))
    }

    /// The rows the main column spends below the transcript: the status line, the
    /// accounting footer when there is one, and however tall the prompt currently
    /// is.
    var mainFooterRows: Int { Self.statusRows + footerRows + promptRows }

    /// The transcript viewport's height, once the status line and prompt are taken.
    var transcriptHeight: Int {
        max(0, height - mainFooterRows)
    }

    /// The panes a pointer can land in.
    enum Pane {
        case sidebar
        case divider
        case transcript
        /// The status line, the accounting footer and the prompt — the bottom
        /// rows of the main column.
        case mainFooter
    }

    /// Which pane contains a 0-based screen position.
    ///
    /// Out-of-range positions resolve to the nearest pane rather than to `nil`: a
    /// terminal can report a coordinate one past the edge during a resize, and a
    /// dropped scroll event reads to the user as a dead wheel.
    func pane(atColumn column: Int, row: Int) -> Pane {
        if column < sidebarWidth { return .sidebar }
        if let dividerColumn, column == dividerColumn { return .divider }
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
    /// footer of its own — the status line, the accounting footer and the prompt
    /// live only in the main column.
    func bounds(of pane: Pane) -> PaneBounds {
        switch pane {
        case .sidebar:
            return PaneBounds(columns: 0..<min(sidebarWidth, width), rows: 0..<height)
        case .divider:
            guard let dividerColumn else { return PaneBounds(columns: width..<width, rows: 0..<height) }
            return PaneBounds(columns: dividerColumn..<(dividerColumn + dividerWidth), rows: 0..<height)
        case .transcript:
            return PaneBounds(columns: mainColumnStart..<width, rows: 0..<transcriptHeight)
        case .mainFooter:
            return PaneBounds(columns: mainColumnStart..<width, rows: transcriptHeight..<height)
        }
    }
}
