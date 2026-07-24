// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/truncated-text.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore

// MARK: - TruncatedText

/// A single logical line clipped to the viewport width with an ellipsis, framed
/// by optional horizontal and vertical padding.
///
/// The counterpart to ``Text`` for the "status line, never wraps" case: it keeps
/// only the first physical line of its content (everything up to the first
/// newline), truncates that to the padded inner width through the width engine,
/// and pads the result back out so every emitted line is exactly `width` columns.
/// That fixed-width guarantee is what the renderer's fatal-width invariant wants,
/// and what lets a `TruncatedText` sit inside an overlay without shifting the
/// columns beside it.
///
/// pi measures and truncates against ANSI-aware widths (`truncateToWidth`,
/// `visibleWidth`); this uses the same engine, so a styled prefix is preserved
/// and the ellipsis lands on a cluster boundary rather than mid-glyph.
public final class TruncatedText: Component {
    public var text: String
    public var paddingX: Int
    public var paddingY: Int

    public init(_ text: String, paddingX: Int = 0, paddingY: Int = 0) {
        self.text = text
        self.paddingX = max(0, paddingX)
        self.paddingY = max(0, paddingY)
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        var result: [String] = []
        let emptyLine = String(repeating: " ", count: width)

        for _ in 0..<paddingY { result.append(emptyLine) }

        // Available width after horizontal padding on both sides. pi floors at 1
        // so a very narrow viewport still truncates rather than producing a
        // negative budget.
        let availableWidth = max(1, width - paddingX * 2)

        // Only the first physical line — stop at the first newline like pi.
        var singleLine = text
        if let newlineIndex = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            singleLine = String(text[text.startIndex..<newlineIndex])
        }

        let displayText = truncateToWidth(singleLine, availableWidth)

        let horizontalPad = String(repeating: " ", count: paddingX)
        let lineWithPadding = horizontalPad + displayText + horizontalPad

        // Emit the padded line at exactly `width`. When `paddingX * 2 >= width`
        // the `availableWidth` floor above cannot reserve room for both pads, so
        // the composed line can be *wider* than `width` — the over-wide line the
        // renderer treats as fatal. Clamp through the width engine: it pads when
        // the line is short and clips (on a cluster boundary) when the pads
        // overflowed, always landing on exactly `width`.
        result.append(truncateToWidth(lineWithPadding, width, ellipsis: "", pad: true))

        for _ in 0..<paddingY { result.append(emptyLine) }

        return result
    }
}
