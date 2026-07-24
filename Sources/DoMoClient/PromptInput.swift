// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The prompt line: a focusable single-line input where Enter submits. Minimal by
// design for this first cut — append, backspace, and paste-unwrap — with the full
// multi-line Editor a later polish. It emits the cursor marker at the caret so the
// alt-screen renderer drives the real cursor to the end of the text.

import DoMoTUI

/// A one-line prompt input; Enter submits its text and clears it.
@MainActor
final class PromptInput: @MainActor Focusable {
    var focused = false

    /// Called with the trimmed text when the user presses Enter (never with empty).
    var onSubmit: ((String) -> Void)?

    private(set) var text = ""
    private let prompt = "❯ "
    private let placeholder = "Type a message — Enter to send, Tab to switch pane"

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        if text.isEmpty && !focused {
            return [truncateToWidth(dim(prompt + placeholder), width)]
        }
        let promptWidth = visibleWidth(prompt)
        let available = max(1, width - promptWidth)
        // Show the tail of the text so the caret stays visible when it overflows.
        let shown = visibleWidth(text) > available
            ? sliceByColumn(text, from: visibleWidth(text) - available, to: visibleWidth(text))
            : text
        let caret = focused ? cursorMarker : ""
        // Clip the visible part to the width (the prompt glyph alone can exceed a
        // 1-2 col pane), then append the zero-width caret marker at the boundary.
        let visible = truncateToWidth(prompt + shown, width, ellipsis: "")
        return [visible + caret]
    }

    func handleInput(_ data: [UInt8]) {
        // Enter submits.
        if data == [0x0d] || data == [0x0a] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if !trimmed.isEmpty { onSubmit?(trimmed) }
            return
        }
        // Backspace / Delete.
        if data == [0x7f] || data == [0x08] {
            if !text.isEmpty { text.removeLast() }
            return
        }
        // Everything else: accept printable UTF-8 (paste guards stripped).
        guard let decoded = String(bytes: data, encoding: .utf8) else { return }
        let cleaned = stripPasteGuards(decoded)
        for scalar in cleaned.unicodeScalars where scalar.value >= 0x20 && scalar != "\u{7f}" {
            text.unicodeScalars.append(scalar)
        }
    }

    /// Remove bracketed-paste guards (`ESC[200~ … ESC[201~`) the driver re-wraps a
    /// paste in, keeping the pasted text itself.
    private func stripPasteGuards(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\u{1b}[200~", with: "")
            .replacingOccurrences(of: "\u{1b}[201~", with: "")
    }
}
