// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Text that came from OUTSIDE the program — a model's answer, a tool's stdout, a
// file the model read, a shell command it wants to run — and the two things every
// surface must do to it before putting it in a frame.
//
// It lives here, in the shared TUI layer, because BOTH surfaces render untrusted
// text: the full-screen client's transcript and the inline REPL's blocks and
// approval overlay. It was originally written for the client alone, which left the
// inline REPL's approval prompt taking raw model-controlled text — the one place
// where corrupting the display also corrupts a security decision.

import Foundation

// MARK: - Untrusted text

/// Fold newlines and tabs so a summary is always exactly one line, and collapse
/// runs of whitespace so an indented heredoc does not render as a long blank gap.
public nonisolated func collapseToOneLine(_ text: String) -> String {
    var result = ""
    var lastWasSpace = false
    for character in text {
        // Match on the cluster's FIRST scalar, not on the whole Character: Swift
        // joins CR+LF into ONE grapheme that equals neither "\n" nor "\r", so an
        // equality test silently passes Windows line endings straight through into a
        // frame row — which is exactly the newline injection this exists to stop.
        let leading = character.unicodeScalars.first?.value ?? 0
        if leading == 0x0A || leading == 0x0D {
            if !result.isEmpty && !lastWasSpace { result.append(" ") }
            result.append("⏎")
            lastWasSpace = false
            continue
        }
        if character == "\t" || character == " " {
            if !lastWasSpace && !result.isEmpty { result.append(" ") }
            lastWasSpace = true
            continue
        }
        result.append(character)
        lastWasSpace = false
    }
    return result.trimmingCharactersInWhitespace()
}

private extension String {
    /// Trim leading/trailing spaces without pulling in Foundation's character sets.
    nonisolated func trimmingCharactersInWhitespace() -> String {
        var characters = Array(self)
        while let first = characters.first, first == " " { characters.removeFirst() }
        while let last = characters.last, last == " " { characters.removeLast() }
        return String(characters)
    }
}

/// Strip the control characters that let model- or tool-supplied text escape its
/// row and drive the terminal directly.
///
/// Everything in a transcript — assistant text, a tool's stdout, a file the model
/// read, an argument summary — is untrusted with respect to the RENDERER. The
/// renderer composes each frame row as a string and trusts that a row occupies one
/// row; a bare `ESC` from that text is not the app's own SGR styling but a live
/// escape sequence, and a bare `CR` returns the paint cursor to column zero. Left
/// in, `ESC[2J` wipes the page, `ESC[nA` walks the cursor into another pane, and a
/// lone `CR` overwrites the sidebar — all of which read to a user as "the UI
/// froze", because the app happily keeps painting rows that no longer land where it
/// thinks.
///
/// Applied where untrusted text ENTERS the read model, so everything downstream —
/// transcript rows, the status line, the approval modal — is already safe, and the
/// styling the app adds afterwards is unaffected.
///
/// `\n` survives (it is how paragraphs are split) and `\t` survives (the renderer
/// expands tabs itself). Every other C0 control, `DEL`, and the C1 range are
/// replaced with a visible `·` so the text keeps its shape instead of silently
/// losing characters.
/// A `CR` that is part of a `CRLF` is dropped rather than marked, so a file with
/// Windows line endings reads normally. (It also makes such text *split* into lines
/// correctly: Swift treats `"\r\n"` as ONE grapheme cluster, so a `Character`-wise
/// wrap never sees the `\n` and collapses the whole file into a single paragraph.)
public nonisolated func sanitizeUntrustedText(_ text: String) -> String {
    // Fast path: the overwhelmingly common case has nothing to strip.
    guard text.unicodeScalars.contains(where: isDisallowedControl) else { return text }
    var scalars = String.UnicodeScalarView()
    var iterator = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = iterator.next()
    while let scalar = pending {
        pending = iterator.next()
        if scalar.value == 0x0D {
            // CRLF -> LF; a lone CR is a control character like any other.
            if pending?.value == 0x0A { continue }
            scalars.append("\u{00B7}")
            continue
        }
        scalars.append(isDisallowedControl(scalar) ? "\u{00B7}" : scalar)
    }
    return String(scalars)
}

nonisolated private func isDisallowedControl(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0A, 0x09: return false                 // newline and tab are content
    case 0x00...0x1F, 0x7F: return true           // C0 controls incl. ESC and CR, and DEL
    case 0x80...0x9F: return true                 // C1 controls (8-bit CSI and friends)
    default: return false
    }
}

/// Shorten a path to fit `width` by dropping leading components, keeping the tail
/// (the part that identifies the file) rather than the head.
///
/// `truncateToWidth` cuts the END, which for `/very/long/path/to/Foo.swift` throws
/// away the only part the user recognises. This keeps the filename.
public nonisolated func elideLeading(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    guard visibleWidth(text) > width else { return text }
    let ellipsis = "…"
    let budget = width - 1
    guard budget > 0 else { return ellipsis }
    var kept = ""
    var keptWidth = 0
    for character in text.reversed() {
        let characterWidth = graphemeWidth(character)
        if keptWidth + characterWidth > budget { break }
        kept.append(character)
        keptWidth += characterWidth
    }
    return ellipsis + String(kept.reversed())
}
