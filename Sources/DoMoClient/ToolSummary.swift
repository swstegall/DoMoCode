// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// One line of "what is this tool call actually doing", derived from the arguments
// the `tool_start` frame already carries. The transcript used to show only the
// tool's NAME, which makes every `edit` look like every other `edit` — and makes a
// call that is merely slow indistinguishable from one that is stuck. Naming the
// target is the cheapest possible fix for that.
//
// Tool-aware, mirroring `DoMoPermissions.PermissionRequestFactory`: the same
// argument a call is *gated* on is the one worth showing, so the transcript row and
// the approval modal name the same thing.

import DoMoCore
import DoMoTUI

/// A compact, single-line summary of a tool call's arguments — the file path, the
/// shell command, the search pattern — or an empty string when there is nothing
/// worth saying.
///
/// Never returns a multi-line string: a newline in a shell command (a heredoc, a
/// multi-line script) is folded to `⏎` so the row stays one line and the caller's
/// width budget holds.
nonisolated func toolCallDetail(name: String, arguments: JSONValue) -> String {
    let raw: String
    switch name {
    case "bash":
        raw = arguments["command"]?.stringValue ?? ""
    case "read", "write", "edit":
        raw = pathArgument(arguments)
    case "ls":
        raw = arguments["path"]?.stringValue ?? "."
    case "grep":
        let pattern = arguments["pattern"]?.stringValue ?? ""
        let path = arguments["path"]?.stringValue
        raw = [pattern, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  in  ")
    case "find":
        let pattern = arguments["pattern"]?.stringValue ?? arguments["glob"]?.stringValue ?? ""
        let path = arguments["path"]?.stringValue
        raw = [pattern, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  in  ")
    default:
        // An unknown built-in or any MCP tool: show its scalar arguments as
        // `key=value`, in sorted order so the row is stable frame to frame.
        raw = genericSummary(arguments)
    }
    // Tool arguments are model-controlled, so the summary is untrusted text like any
    // other: an `ESC[2J` in a "path" would otherwise wipe the page from the row that
    // is supposed to be telling you what the tool is about to do.
    return sanitizeUntrustedText(collapseToOneLine(raw))
}

/// The `path` / `file_path` argument, defensively — the tool layer accepts both
/// spellings, so the summary must too or an `edit` row reads blank.
private func pathArgument(_ arguments: JSONValue) -> String {
    arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue ?? ""
}

/// `key=value` for the scalar arguments, sorted by key. Nested objects and arrays
/// are reported by shape (`edits[2]`) rather than dumped: the row has one line.
private func genericSummary(_ arguments: JSONValue) -> String {
    guard let object = arguments.objectValue, !object.isEmpty else { return "" }
    var parts: [String] = []
    for key in object.keys.sorted() {
        guard let value = object[key] else { continue }
        switch value {
        case .string(let text):
            parts.append("\(key)=\(collapseToOneLine(text))")
        case .int(let number):
            parts.append("\(key)=\(number)")
        case .double(let number):
            parts.append("\(key)=\(number)")
        case .bool(let flag):
            parts.append("\(key)=\(flag)")
        case .array(let items):
            parts.append("\(key)[\(items.count)]")
        case .object, .null:
            continue
        }
    }
    return parts.joined(separator: "  ")
}

/// Fold newlines and tabs so a summary is always exactly one line, and collapse
/// runs of whitespace so an indented heredoc does not render as a long blank gap.
nonisolated func collapseToOneLine(_ text: String) -> String {
    var result = ""
    var lastWasSpace = false
    for character in text {
        if character == "\n" || character == "\r" {
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
    func trimmingCharactersInWhitespace() -> String {
        var characters = Array(self)
        while let first = characters.first, first == " " { characters.removeFirst() }
        while let last = characters.last, last == " " { characters.removeLast() }
        return String(characters)
    }
}

// MARK: - Untrusted text

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
nonisolated func sanitizeUntrustedText(_ text: String) -> String {
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

private func isDisallowedControl(_ scalar: Unicode.Scalar) -> Bool {
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
nonisolated func elideLeading(_ text: String, width: Int) -> String {
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
