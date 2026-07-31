// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two pinned one-line bars at the bottom of the main column.
//
// `StatusBar` is the volatile one: what the run is doing this instant, plus the
// key hints. `FooterBar` is the stable one: where you are (cwd, branch) and what
// this session has spent (tokens, cost, context). They are separate ROWS rather
// than one composed line for a reason the status line's own comments already
// record — it is over budget at ordinary widths, it is truncated from the RIGHT,
// and a ninth constant hint already pushes `Esc: abort` off an 80-column
// terminal. Appending five accounting segments to it would not produce a footer;
// it would produce a footer that is invisible on every terminal narrower than
// about 240 columns, which is every terminal.
//
// The cost of a second row is exactly one row of transcript, so the app only
// asks for it when the terminal can afford it — see
// ``ClientLayout/footerRows(for:)``.

import DoMoHarness
import DoMoLLM
import DoMoTUI
import Foundation

/// A one-line status bar; the app sets `text` each frame.
@MainActor
final class StatusBar: Component {
    var text = ""

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return [truncateToWidth(dim(text), width)]
    }
}

// MARK: - The accounting footer

/// Everything the footer draws, as plain values.
///
/// A value type rather than four properties on the component so the composition
/// — which is all the interesting behaviour — can be tested without a terminal.
struct FooterModel: Equatable, Sendable {
    /// The selected session's working directory. Externally sourced (it comes off
    /// the wire), so ``FooterRow/compose(_:width:)`` sanitizes it.
    var cwd: String = ""

    /// The branch read off `.git/HEAD`, or `nil` when the cwd is not a
    /// repository. Also externally sourced: a branch name is whatever bytes are
    /// in that file.
    var branch: String?

    /// The session's totals, or `nil` when the server has not said.
    ///
    /// `nil` is NOT zero. A session that has spent nothing reports zeros and the
    /// footer prints `$0.00`; a session the server could not account for prints
    /// nothing at all, because inventing a `$0.00` for it would be exactly the
    /// class of confident falsehood this phase exists to remove.
    var accounting: SessionAccounting?
}

/// Composes the footer row and fits it to a width.
///
/// Everything here is `static` and pure. The width fitting is the part that has
/// bitten this codebase before: an over-wide row is a fatal condition for the
/// renderer, and a row that simply overflows is worse than one that dropped a
/// segment on purpose.
enum FooterRow {
    /// Two spaces between segments. Deliberately not a glyph: `·` and `⎇` are
    /// East-Asian-ambiguous, terminals disagree with each other about whether
    /// they occupy one column or two, and this row is measured to the column.
    static let separator = "  "

    /// The narrowest the working directory may shrink to while anything else is
    /// on the row. Below this a path is `…c` — noise that costs columns the
    /// numbers beside it can use.
    static let minimumCwdWidth = 8

    /// Which segments give way as the row narrows, most expendable first.
    ///
    /// Indices into the segment array built by ``segments(_:)``. The **working
    /// directory is not in this list** because it is elastic: it shrinks from the
    /// left first and is dropped only when even ``minimumCwdWidth`` columns are
    /// not there, and it is re-offered on every round of this loop, so a row that
    /// sheds the token count gets the path back if the path now fits.
    ///
    /// The order of what remains, and why:
    ///
    /// * **branch** goes first. It is orientation, not accounting, and the
    ///   sidebar already names the session by its cwd's basename.
    /// * **tokens** next. Cumulative tokens are the least actionable number here:
    ///   the cost segment says what they were worth and the context meter says
    ///   how many of them still matter.
    /// * **cost** next.
    /// * **the context meter is last to go**, and is therefore the one segment a
    ///   very narrow terminal still shows. It is the only number that predicts
    ///   something about to happen — a compaction, and the loss of fidelity that
    ///   comes with it.
    static let dropOrder = [1, 2, 3]

    /// The row's segments in DISPLAY order: cwd, branch, tokens, cost, context.
    /// `nil` means "there is nothing to say", which is not the same as "it did
    /// not fit".
    static func segments(_ model: FooterModel) -> [String?] {
        let cwd = sanitizeUntrustedText(collapseToOneLine(model.cwd))
        let branch = model.branch.map { sanitizeUntrustedText(collapseToOneLine($0)) }
        return [
            cwd.isEmpty ? nil : cwd,
            branch.flatMap { $0.isEmpty ? nil : "git:" + $0 },
            model.accounting.map { "tok " + formatTokens($0.usage.totalTokens) },
            model.accounting.map {
                formatCost($0.costTotal, turns: $0.turns, tokens: $0.usage.totalTokens)
            },
            model.accounting.map(formatContext),
        ]
    }

    /// The footer as one row, never wider than `width` visible columns.
    static func compose(_ model: FooterModel, width: Int) -> String {
        guard width > 0 else { return "" }
        let base = segments(model)
        // Richest first: try the whole row, then shed one segment per round. The
        // cwd is retried inside `fitted` every round, which is what lets a row
        // that had to drop the token count show the path again.
        for dropCount in 0...dropOrder.count {
            var parts = base
            for index in dropOrder.prefix(dropCount) { parts[index] = nil }
            if let row = fitted(parts, width: width) { return row }
        }
        // Only the context meter is left and even that is wider than the
        // terminal. Cut it rather than return an over-wide row.
        return truncateToWidth(base.compactMap { $0 }.last ?? "", width, ellipsis: "")
    }

    /// `parts` fitted into `width`, or `nil` when it cannot be done without
    /// dropping one of the inelastic segments.
    private static func fitted(_ parts: [String?], width: Int) -> String? {
        let whole = joined(parts)
        if visibleWidth(whole) <= width { return whole }

        var withoutCwd = parts
        let cwd = withoutCwd[0]
        withoutCwd[0] = nil
        let rest = joined(withoutCwd)
        let restWidth = visibleWidth(rest)

        if let cwd {
            // With nothing beside it the path may use the whole row, so the floor
            // does not apply — `…leaf` alone still says where you are. And a path
            // SHORTER than the floor is never dropped for want of columns it was
            // never going to use: the floor is about not showing a `…c` stub, not
            // about reserving space.
            let floor = rest.isEmpty ? 1 : min(minimumCwdWidth, visibleWidth(cwd))
            let room = rest.isEmpty ? width : width - restWidth - visibleWidth(separator)
            if room >= floor {
                var shrunk = withoutCwd
                // From the LEFT: the tail is the half that identifies a
                // directory, and `truncateToWidth` would throw exactly that away.
                shrunk[0] = elideLeading(cwd, width: room)
                return joined(shrunk)
            }
        }
        return restWidth <= width ? rest : nil
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: separator)
    }

    // MARK: Formatting
    //
    // These three deliberately produce the SAME strings as
    // `DoMoCLI/InlineAccountingSummary`, which draws the identical numbers on the
    // inline REPL's status line. Two surfaces of one program that render the same
    // `SessionAccounting` differently is the exact class of drift this phase
    // exists to end, and the dependency graph runs DoMoCLI -> DoMoClient, so the
    // shared spelling cannot live in the CLI. Change one and change the other.

    /// A token count as `842`, `12.3k` or `1.4M`.
    static func formatTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        // 999_950 and not 1_000_000: one decimal place already rounds to
        // "1000.0k" at that point, which is a unit nobody uses.
        if count < 999_950 { return tenths((count + 50) / 100, suffix: "k") }
        // Divide first and carry the remainder, rather than `(count + 50_000)`:
        // that addition traps at the top of `Int`, and unlike the inline
        // surface's copy of this, these numbers arrive over a socket. Identical
        // output for every value either can actually produce.
        return tenths(count / 100_000 + (count % 100_000 >= 50_000 ? 1 : 0), suffix: "M")
    }

    /// `count` is the value in TENTHS of the unit, so 123 renders `12.3k`.
    private static func tenths(_ count: Int, suffix: String) -> String {
        "\(count / 10).\(count % 10)\(suffix)"
    }

    /// A USD total.
    ///
    /// The `Decimal`'s own exact digits, not a fixed number of places: a turn
    /// that cost a third of a cent rounds to `$0.00` at two places, and "the
    /// meter reads zero" is the falsehood this phase exists to remove. It also
    /// keeps the number off `Double` entirely, and off `String(format:)`, whose
    /// varargs initializer is `unsafe` under this package's strict memory safety.
    ///
    /// A zero total on a session that demonstrably ran gets a trailing `?`. Two
    /// different situations produce that zero — a model nobody configured a price
    /// for, and a session file written before this phase recorded any cost at all
    /// — and neither of them is "it was free", so the footer marks the number
    /// unknown with the same glyph the context meter uses for an unknown window
    /// rather than asserting either one. A session that has genuinely spent
    /// nothing (no turns at all) still reads `$0.00`, never a blank.
    static func formatCost(_ total: Decimal, turns: Int, tokens: Int) -> String {
        guard total > 0 else {
            return turns > 0 && tokens > 0 ? "$0.00?" : "$0.00"
        }
        return "$" + total.description
    }

    /// The context meter: how big the context is, and how much of the window it
    /// fills.
    ///
    /// An unknown window renders `(?)` and NEVER a percentage. The compaction
    /// fallback window is a safety net, and a percentage computed against it
    /// looks identical on screen to one computed against a real number — which
    /// would be a new lie in the place of the old one.
    ///
    /// A context past its window reports the real figure rather than clamping at
    /// 100: it is a true state (the next turn is what compacts), and a meter
    /// pinned at 100% hides how far past it has gone. The 9999 ceiling is only so
    /// a nonsense window cannot widen the row without bound.
    static func formatContext(_ accounting: SessionAccounting) -> String {
        let label = formatTokens(max(0, accounting.contextTokens))
        guard let window = accounting.contextWindow, window > 0 else { return "ctx \(label) (?)" }
        // Clamped before the multiply, not after: these numbers arrive over a
        // socket, and `contextTokens * 100` on a hostile value traps rather than
        // wrapping. The inline surface takes its input from the local harness and
        // has no such door.
        let tokens = min(max(0, accounting.contextTokens), Int.max / 100)
        return "ctx \(label) (\(min(9_999, tokens * 100 / window))%)"
    }
}

/// The accounting footer: one dim row under the status line.
@MainActor
final class FooterBar: Component {
    var model = FooterModel()

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return [dim(FooterRow.compose(model, width: width))]
    }
}
