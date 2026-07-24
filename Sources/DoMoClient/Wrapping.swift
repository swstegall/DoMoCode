// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Small text helpers the client's views share: column-aware wrapping and a
// couple of SGR wrappers. They lean on DoMoTUI's width/slicing primitives so
// wide clusters and existing escapes are measured correctly, and they never emit
// a line wider than the requested width.

import DoMoTUI

/// Reset all SGR attributes — appended after any styled run so a style never
/// bleeds past the string it was meant for.
let sgrReset = "\u{1b}[0m"

/// Hard-wrap `text` to `width` visible columns, honoring existing newlines and
/// measuring by grapheme width.
///
/// A single O(N) pass over the grapheme clusters — it never re-slices or
/// re-measures the remaining string, so a large unbroken line wraps in linear
/// time rather than the quadratic time a slice-and-remeasure loop takes (a
/// megabyte of one line otherwise freezes the synchronous render). Never returns
/// a line wider than `width`: a lone cluster wider than the whole width (a
/// degenerate sub-glyph width) is dropped rather than emitted over-wide.
nonisolated func wrapToWidth(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    var lines: [String] = []
    for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if paragraph.isEmpty { lines.append(""); continue }
        var current = ""
        var currentWidth = 0
        for character in paragraph {
            let clusterWidth = graphemeWidth(character)
            if clusterWidth > width {
                // Cannot fit on any line at this width; flush and drop it.
                if !current.isEmpty { lines.append(current); current = ""; currentWidth = 0 }
                continue
            }
            if currentWidth + clusterWidth > width {
                lines.append(current)
                current = String(character)
                currentWidth = clusterWidth
            } else {
                current.append(character)
                currentWidth += clusterWidth
            }
        }
        lines.append(current)
    }
    return lines
}

/// Wrap `text` under a leading `label`: the first line carries the label, wrapped
/// continuations are indented to align under it. Each line is clipped to `width`,
/// so even a label wider than the width never produces an over-wide row.
nonisolated func labeledWrap(_ label: String, _ text: String, width: Int) -> [String] {
    let labelWidth = visibleWidth(label)
    let body = wrapToWidth(text, width: max(1, width - labelWidth))
    let indent = String(repeating: " ", count: labelWidth)
    guard !body.isEmpty else { return [truncateToWidth(label, width, ellipsis: "")] }
    return body.enumerated().map { index, line in
        truncateToWidth((index == 0 ? label : indent) + line, width, ellipsis: "")
    }
}

/// Dim a run (SGR 2), reset after. Zero added visible width.
nonisolated func dim(_ text: String) -> String { "\u{1b}[2m" + text + sgrReset }

/// Inverse-video a run (SGR 7), reset after. Used for the focused selection bar;
/// pad to the bar width first so the highlight spans the row.
nonisolated func inverse(_ text: String) -> String { "\u{1b}[7m" + text + sgrReset }
