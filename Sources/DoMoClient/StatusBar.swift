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
    private var style: (String) -> String = dim

    func applyTheme(_ theme: Theme, appearance: ThemeAppearance, trueColor: Bool = true) {
        let color = theme.palette(for: appearance).muted.foreground(trueColor: trueColor)
        style = color.isEmpty ? { $0 } : { color + $0 + sgrReset }
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return [truncateToWidth(style(text), width)]
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
    // **Every number on this row arrived over a socket.** The whole
    // `SessionAccounting` is decoded from the `/status` body with no bounds
    // applied anywhere on the way in, and the token halves of it are also folded
    // from SSE `message_end` frames, so a buggy, older or hostile server can put
    // `Int.max` in any field. Arithmetic here therefore either saturates
    // (``DoMoLLM/Usage/totalTokens`` and `Usage.+`, which clamp) or clamps its
    // operands before the operation (``formatContext``'s multiply). A trap in any
    // of them is not a wrong number on a row — it is SIGTRAP with the alternate
    // screen still on, which takes the session with it.
    //
    // These three are this side's copy of `DoMoCLI/InlineAccountingSummary`'s
    // `compact`, `cost` and `context`, which draw the same numbers on the inline
    // REPL's status line. Two surfaces of one program rendering the same
    // `SessionAccounting` differently is the exact class of drift this phase
    // exists to end, and the dependency graph runs DoMoCLI -> DoMoClient, so the
    // shared spelling cannot live in the CLI. Change one and change the other.
    //
    // They are not yet the same strings, and this note used to claim they were.
    // Two differences are live, and both belong to the inline copy:
    //
    // * **A negative total.** ``formatCost`` tests `!= 0` and renders a credit as
    //   `-$0.25`; the inline copy tests `> 0`, so the identical accounting reads
    //   `$0.00?` there. The two surfaces disagree about that session outright.
    // * **Hostile magnitudes.** The hardening this section is about — dividing
    //   before the round in ``formatTokens(_:)``, clamping before the multiply in
    //   ``formatContext(_:)`` — exists only here. The inline copy still rounds with
    //   `value + 50_000` and still computes `contextTokens * 100` unclamped.
    //
    // The second is a GAP rather than a difference in exposure. The inline REPL
    // reads its totals from the local harness, but the harness seeds them from the
    // provider's `usage` frames — ``DoMoHarness/calculateContextTokens(_:)`` returns
    // the reported total verbatim — so an absurd `total_tokens` reaches that
    // arithmetic too; it just makes one hop fewer on the way.

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
    ///
    /// `$0.00?` therefore means "zero, on a session that demonstrably ran, and
    /// this row cannot say which zero it is". It does NOT mean "nobody priced this
    /// session" — which is what this comment used to assert: a model an operator
    /// deliberately priced AT ZERO produces the same total and renders the same
    /// `$0.00?` here. Print mode CAN tell the two apart, and says so differently
    /// — `$0` for a stated zero, `cost unknown` for a run nothing priced — because
    /// it carries the run's `ratesConfigured` alongside the number
    /// (`DoMoCLI/PrintUsageEncoding.reportableCost(_:ratesConfigured:reportedCost:)`).
    /// All that reaches this row is a `Decimal`. So it marks the number unknown
    /// instead of asserting a price it cannot see: widening ``SessionAccounting``
    /// to carry that fact is the fix, under-claiming is the interim, and the `?`
    /// is what keeps the interim honest.
    ///
    /// The test is `!= 0` and not `> 0` because a NEGATIVE total is a different
    /// fact, and one this side does not get to rule out: `costTotal` is whatever
    /// number the server put in the `/status` body, decoded with no bounds (the
    /// two local sources of a price — a validated `x-litellm-response-cost` and a
    /// validated rate table — both refuse negatives, but neither is what this
    /// argument comes through). Whatever produced it, a credit is a session that
    /// WAS priced, so it renders as the negative number it is — `-$0.25`, sign in
    /// front of the amount the way accounting spells a credit — instead of being
    /// swept into the "unknown" bucket by a test that could not tell the two apart.
    static func formatCost(_ total: Decimal, turns: Int, tokens: Int) -> String {
        guard total != 0 else {
            return turns > 0 && tokens > 0 ? "$0.00?" : "$0.00"
        }
        return total < 0 ? "-$" + (-total).description : "$" + total.description
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
        // Clamped before the multiply, not after: `contextTokens * 100` on a
        // hostile value traps rather than wrapping, and every number on this row
        // arrives over a socket (see the section comment above — the token and
        // cost segments answer the same door by saturating instead). The inline
        // surface's copy of this does NOT clamp; that is an open gap, not a
        // surface with no such door, because the harness it reads from takes its
        // context total straight from the provider's `usage` frames.
        let tokens = min(max(0, accounting.contextTokens), Int.max / 100)
        return "ctx \(label) (\(min(9_999, tokens * 100 / window))%)"
    }
}

/// The accounting footer: one dim row under the status line.
@MainActor
final class FooterBar: Component {
    var model = FooterModel()
    private var style: (String) -> String = dim

    func applyTheme(_ theme: Theme, appearance: ThemeAppearance, trueColor: Bool = true) {
        let color = theme.palette(for: appearance).muted.foreground(trueColor: trueColor)
        style = color.isEmpty ? { $0 } : { color + $0 + sgrReset }
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return [style(FooterRow.compose(model, width: width))]
    }
}
