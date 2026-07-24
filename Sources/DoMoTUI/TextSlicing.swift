// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/utils.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore

// MARK: - SGR reset

/// The full SGR reset, emitted after a truncated prefix and its ellipsis so a
/// style opened inside the kept text cannot bleed into whatever the renderer
/// places to the right.
private nonisolated let sgrReset = "\u{1b}[0m"

// MARK: - Slicing

/// The substring of `line` covering visible columns `from..<to`.
///
/// Never splits a grapheme cluster and never splits inside an ANSI escape: the
/// scan advances by whole `Character`s and whole escapes (``ansiEscapeLength``).
/// SGR/OSC state that was opened *before* the window is carried in and prepended
/// to the first kept grapheme, so the slice renders with the same active styling
/// it would have had in place — a slice of coloured text stays coloured.
///
/// `strict` decides the right boundary when a wide (2-column) cluster straddles
/// it. With `strict` true a cluster is dropped unless it fits entirely within
/// `to`, so the result never exceeds the requested span. With `strict` false the
/// pi default the cluster is kept, so the result can overhang `to` by one
/// column; ``checkedSliceByColumn(_:from:to:strict:)`` is the guard for callers
/// that cannot absorb that overhang.
public nonisolated func sliceByColumn(
    _ line: String,
    from: Int,
    to: Int,
    strict: Bool = false
) -> String {
    sliceWithWidth(line, from: from, to: to, strict: strict).text
}

/// ``sliceByColumn(_:from:to:strict:)`` plus the measured width of the result,
/// so a caller that already sliced does not have to re-measure to learn whether
/// a wide cluster overhung the boundary.
public nonisolated func sliceWithWidth(
    _ line: String,
    from: Int,
    to: Int,
    strict: Bool = false
) -> (text: String, width: Int) {
    guard to > from else { return ("", 0) }
    let startColumn = max(0, from)
    let endColumn = to

    let chars = Array(line)
    var result = ""
    var resultWidth = 0
    var currentColumn = 0
    var pendingAnsi = ""
    var index = 0

    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            let code = String(chars[index..<index + length])
            if currentColumn >= startColumn, currentColumn < endColumn {
                result += code
            } else if currentColumn < startColumn {
                // Held so the entering style is emitted just before the first
                // kept grapheme, never stranded before column `from`.
                pendingAnsi += code
            }
            index += length
            continue
        }

        let character = chars[index]
        let width = graphemeWidth(character)
        let inRange = currentColumn >= startColumn && currentColumn < endColumn
        let fits = !strict || currentColumn + width <= endColumn
        if inRange, fits {
            if !pendingAnsi.isEmpty {
                result += pendingAnsi
                pendingAnsi = ""
            }
            result.append(character)
            resultWidth += width
        }
        currentColumn += width
        index += 1
        if currentColumn >= endColumn { break }
    }

    return (result, resultWidth)
}

/// ``sliceByColumn(_:from:to:strict:)`` that refuses to return a slice wider than
/// the requested column span.
///
/// This is the fatal-width safeguard. A non-strict slice whose right boundary
/// falls in the middle of a wide cluster overhangs by one column, and one stray
/// column shifts every cell after it — so the renderer, which has budgeted an
/// exact width, must be told loudly rather than paint a corrupted line. It
/// throws ``DoMoError`` (kind ``DoMoError/Kind/malformedResponse``) instead of
/// calling `precondition`, because `precondition` traps in release and a wide
/// glyph landing on a boundary is a recoverable layout event, not a reason to
/// kill an agent mid-render. With `strict` true the result fits by construction
/// and this never throws.
public nonisolated func checkedSliceByColumn(
    _ line: String,
    from: Int,
    to: Int,
    strict: Bool = false
) throws(DoMoError) -> String {
    let sliced = sliceWithWidth(line, from: from, to: to, strict: strict)
    let budget = max(0, to - from)
    guard sliced.width <= budget else {
        throw widthOverflow(measured: sliced.width, budget: budget, what: "slice [\(from), \(to))")
    }
    return sliced.text
}

// MARK: - Truncation

/// `line` shortened to at most `maxColumns` visible columns, with `ellipsis`
/// appended when anything was dropped.
///
/// Ported from pi's `truncateToWidth`, preserving its two load-bearing choices.
/// The full width is measured first, so the ellipsis appears only when the line
/// genuinely does not fit — a line exactly `maxColumns` wide is returned intact,
/// not needlessly clipped. And the kept prefix is built against
/// `maxColumns - visibleWidth(ellipsis)`, dropping any wide cluster that would
/// straddle that budget rather than splitting it, so `ellipsis` always has room
/// and no half-cluster ever reaches the terminal.
///
/// With `pad` true the result is right-padded with spaces to exactly
/// `maxColumns`, which is how a fixed-width column asks for a value that fills
/// its cell whether or not it was truncated.
public nonisolated func truncateToWidth(
    _ line: String,
    _ maxColumns: Int,
    ellipsis: String = "...",
    pad: Bool = false
) -> String {
    if maxColumns <= 0 { return "" }
    if line.isEmpty { return pad ? String(repeating: " ", count: maxColumns) : "" }

    let totalWidth = visibleWidth(line)
    if totalWidth <= maxColumns {
        return pad ? line + String(repeating: " ", count: maxColumns - totalWidth) : line
    }

    let ellipsisWidth = visibleWidth(ellipsis)

    // The ellipsis alone does not fit: clip the ellipsis itself and drop the
    // text entirely, matching pi's degenerate-width branch.
    if ellipsisWidth >= maxColumns {
        let clipped = sliceWithWidth(ellipsis, from: 0, to: maxColumns, strict: true)
        if clipped.width == 0 { return pad ? String(repeating: " ", count: maxColumns) : "" }
        let body = clipped.text + sgrReset
        return pad ? body + String(repeating: " ", count: max(0, maxColumns - clipped.width)) : body
    }

    let targetWidth = maxColumns - ellipsisWidth
    let chars = Array(line)
    var result = ""
    var pendingAnsi = ""
    var keptWidth = 0
    var index = 0
    while index < chars.count {
        if let length = ansiEscapeLength(in: chars, at: index) {
            pendingAnsi += String(chars[index..<index + length])
            index += length
            continue
        }
        let width = graphemeWidth(chars[index])
        guard keptWidth + width <= targetWidth else { break }
        if !pendingAnsi.isEmpty {
            result += pendingAnsi
            pendingAnsi = ""
        }
        result.append(chars[index])
        keptWidth += width
        index += 1
    }

    var output = result + sgrReset + ellipsis + sgrReset
    if pad {
        let visible = keptWidth + ellipsisWidth
        output += String(repeating: " ", count: max(0, maxColumns - visible))
    }
    return output
}

// MARK: - Padding

/// `text` right-padded with `pad` to at least `width` visible columns.
///
/// Padding only: a `text` already wider than `width` is returned unchanged, on
/// the theory that a pad helper's job is to add cells, not remove them. Use
/// ``padToWidthChecked(_:_:with:)`` at the seams where over-width is a bug that
/// must not pass silently, and ``truncateToWidth(_:_:ellipsis:pad:)`` where the
/// intent is to fit-and-fill.
public nonisolated func padToWidth(_ text: String, _ width: Int, with pad: Character = " ") -> String {
    let measured = visibleWidth(text)
    guard measured < width else { return text }
    return text + String(repeating: pad, count: width - measured)
}

/// ``padToWidth(_:_:with:)`` that throws when `text` is *already* wider than
/// `width`.
///
/// The renderer composes a line it believes is exactly `width` columns and pads
/// it to fill the cell; if the belief is wrong the line is one or more columns
/// too wide and will shift everything after it. That is the class of bug this
/// guard exists to surface — loudly, catchably, and never as a release-mode trap.
public nonisolated func padToWidthChecked(
    _ text: String,
    _ width: Int,
    with pad: Character = " "
) throws(DoMoError) -> String {
    let measured = visibleWidth(text)
    if measured > width {
        throw widthOverflow(measured: measured, budget: width, what: "text")
    }
    if measured == width { return text }
    return text + String(repeating: pad, count: width - measured)
}

/// Measures `text` and confirms it fits `columns`, returning the width.
///
/// The primitive behind the checked helpers, exposed so a renderer can assert an
/// already-composed fragment fits its column budget without building a padded
/// copy it does not want. Throws ``DoMoError`` rather than trapping, for the same
/// reason: an over-wide fragment is a bug to report, not a process to kill.
public nonisolated func requireVisibleWidth(
    _ text: String,
    atMost columns: Int
) throws(DoMoError) -> Int {
    let measured = visibleWidth(text)
    guard measured <= columns else {
        throw widthOverflow(measured: measured, budget: columns, what: "text")
    }
    return measured
}

// MARK: - Errors

/// Builds the width-overflow error the checked helpers throw.
///
/// Uses ``DoMoError/Kind/malformedResponse``. The taxonomy has no render-layer
/// kind, and this is the closest fit: a width overflow is a deterministic
/// internal disagreement that will not heal on a retry and should be reported as
/// a bug rather than absorbed — exactly that kind's stated contract. The message
/// carries the numbers a renderer needs to localize the corruption.
private nonisolated func widthOverflow(measured: Int, budget: Int, what: String) -> DoMoError {
    DoMoError(
        .malformedResponse,
        "\(what) measured \(measured) columns, over the \(budget)-column budget"
    )
}
