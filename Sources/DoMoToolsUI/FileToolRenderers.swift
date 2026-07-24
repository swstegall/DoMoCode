// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/edit-diff.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// read/write/edit result rendering. The read/write preview budgets and the
// "N more lines" marker are from `tools/read.ts` and `tools/write.ts`. The edit
// renderer's diff pipeline — the line-numbered `±N content` diff string
// (`generateDiffString`, `edit-diff.ts`) and its colouring with intra-line
// word highlighting (`renderDiff`, `modes/interactive/components/diff.ts`) — is
// ported here. The one seam that differs: pi's `EditTool` returns a pre-rendered
// `details.diff`, while DoMoTools' headless `EditTool` returns the before/after
// content (`oldContent`/`newContent`) and leaves the diff to this module, so the
// line diff itself is computed here rather than upstream.

import DoMoCore
import DoMoTUI
import DoMoTools

// MARK: - Read

/// Renders a `read` result: a `read <path>` header and a bounded, width-clipped
/// preview of the numbered file content the tool returned.
public struct ReadToolRenderer: ToolRenderer {
    /// pi shows 10 lines of a collapsed read before the "more" marker.
    static let previewLines = 10

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let rawPath = argString(request.arguments, "file_path", "path")
        var header = theme.title("read") + " " + renderToolPath(rawPath, theme: theme, home: request.homeDirectory)
        if let offset = argInt(request.arguments, "offset") {
            let limit = argInt(request.arguments, "limit")
            let range = limit.map { "from line \(offset), \($0) lines" } ?? "from line \(offset)"
            header += " " + theme.muted("(\(range))")
        }
        let headerLine = clip(header, to: request.width)

        if request.result.isError {
            return [headerLine] + errorLines(request)
        }
        return [headerLine]
            + bodyLines(
                readTextOutput(request.result),
                width: request.width,
                maxLines: Self.previewLines,
                expanded: request.expanded,
                theme: theme
            )
    }
}

// MARK: - Write

/// Renders a `write` result: a `write <path>` header and the tool's
/// confirmation-with-size line ("Successfully wrote N bytes to …").
public struct WriteToolRenderer: ToolRenderer {
    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let rawPath = argString(request.arguments, "file_path", "path")
        let headerLine = clip(
            theme.title("write") + " " + renderToolPath(rawPath, theme: theme, home: request.homeDirectory),
            to: request.width
        )

        if request.result.isError {
            return [headerLine] + errorLines(request)
        }
        // The confirmation ("Successfully wrote N bytes to <path>") is short and
        // always present; styling it muted keeps the header the visual anchor.
        let confirmation = trimTrailingEmptyLines(
            stripCarriageReturns(request.result.text).components(separatedBy: "\n")
        )
        return [headerLine] + confirmation.map { clip(theme.muted($0), to: request.width) }
    }
}

// MARK: - Edit

/// Renders an `edit` result: an `edit <path>` header followed by a coloured,
/// line-numbered diff of the change.
///
/// The diff is computed here from the result's `oldContent`/`newContent`
/// details, then formatted (`generateDiffString`) and coloured (`renderDiff`)
/// exactly as pi does — added lines green, removed lines red, context dim, with
/// an inverse highlight on the changed tokens of a single-line modification.
public struct EditToolRenderer: ToolRenderer {
    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let rawPath = argString(request.arguments, "file_path", "path")
        let headerLine = clip(
            theme.title("edit") + " " + renderToolPath(rawPath, theme: theme, home: request.homeDirectory),
            to: request.width
        )

        if request.result.isError {
            return [headerLine] + errorLines(request)
        }

        guard
            let oldContent = request.result.details["oldContent"]?.stringValue,
            let newContent = request.result.details["newContent"]?.stringValue
        else {
            // No structured before/after (a tool variant that did not emit it):
            // fall back to the plain confirmation text.
            return [headerLine]
                + bodyLines(
                    request.result.text,
                    width: request.width,
                    maxLines: DefaultToolRenderer.previewLines,
                    expanded: request.expanded,
                    theme: theme
                )
        }

        let diff = generateDiffString(oldContent: oldContent, newContent: newContent)
        let diffLines = renderDiff(diff, width: request.width, theme: theme)
        return [headerLine] + diffLines
    }
}

// MARK: - Read text output

/// The text a read result shows, plus a fallback indicator for any image blocks
/// this terminal path does not inline. Ports the effect of `getTextOutput`.
private nonisolated func readTextOutput(_ result: ToolResult) -> String {
    var text = result.text
    if !result.images.isEmpty {
        let indicators = result.images.map { "[image: \($0.mediaType)]" }.joined(separator: "\n")
        text = text.isEmpty ? indicators : "\(text)\n\(indicators)"
    }
    return text
}

// MARK: - Diff string generation

/// A line-numbered, context-bounded diff string in pi's display format:
/// `+NN added`, `-NN removed`, ` NN context`, and ` ·· ...` for an elided run.
///
/// A faithful port of `generateDiffString` (`edit-diff.ts`), including its
/// context policy — up to `contextLines` lines are kept on each side of a change
/// and interior context longer than `contextLines * 2` collapses to a `...`
/// marker. The line diff underneath (`diffLines`) is computed here (see the file
/// header) rather than taken from a pre-rendered upstream string.
nonisolated func generateDiffString(
    oldContent: String,
    newContent: String,
    contextLines: Int = 4
) -> [String] {
    let old = splitForDiff(oldContent)
    let new = splitForDiff(newContent)
    let parts = diffLines(old.lines, new.lines)

    let maxLineNum = max(old.numberingCount, new.numberingCount)
    let lineNumWidth = String(maxLineNum).count

    func pad(_ number: Int) -> String {
        let text = String(number)
        return text.count >= lineNumWidth ? text : String(repeating: " ", count: lineNumWidth - text.count) + text
    }
    let blankNum = String(repeating: " ", count: lineNumWidth)

    var output: [String] = []
    var oldLineNum = 1
    var newLineNum = 1
    var lastWasChange = false

    for (index, part) in parts.enumerated() {
        let raw = part.lines
        switch part.kind {
        case .added:
            for line in raw {
                output.append("+\(pad(newLineNum)) \(line)")
                newLineNum += 1
            }
            lastWasChange = true
        case .removed:
            for line in raw {
                output.append("-\(pad(oldLineNum)) \(line)")
                oldLineNum += 1
            }
            lastWasChange = true
        case .equal:
            let nextIsChange = index < parts.count - 1 && parts[index + 1].kind != .equal
            let hasLeadingChange = lastWasChange
            let hasTrailingChange = nextIsChange

            func emitContext(_ line: String) {
                output.append(" \(pad(oldLineNum)) \(line)")
                oldLineNum += 1
                newLineNum += 1
            }

            if hasLeadingChange && hasTrailingChange {
                if raw.count <= contextLines * 2 {
                    for line in raw { emitContext(line) }
                } else {
                    for line in raw.prefix(contextLines) { emitContext(line) }
                    let skipped = raw.count - contextLines - contextLines
                    output.append(" \(blankNum) ...")
                    oldLineNum += skipped
                    newLineNum += skipped
                    for line in raw.suffix(contextLines) { emitContext(line) }
                }
            } else if hasLeadingChange {
                let shown = raw.prefix(contextLines)
                for line in shown { emitContext(line) }
                let skipped = raw.count - shown.count
                if skipped > 0 {
                    output.append(" \(blankNum) ...")
                    oldLineNum += skipped
                    newLineNum += skipped
                }
            } else if hasTrailingChange {
                let skipped = max(0, raw.count - contextLines)
                if skipped > 0 {
                    output.append(" \(blankNum) ...")
                    oldLineNum += skipped
                    newLineNum += skipped
                }
                for line in raw.suffix(raw.count - skipped) { emitContext(line) }
            } else {
                // Context far from any change: skip entirely, advancing counters.
                oldLineNum += raw.count
                newLineNum += raw.count
            }
            lastWasChange = false
        }
    }
    return output
}

/// Splits content into diff lines plus the count used for line-number width.
///
/// The count includes the empty element a trailing newline produces (so the
/// numbering width matches pi's `content.split("\n").length`), while the diff
/// lines drop that single trailing empty — pi pops it per-part, and dropping it
/// once here is the same effect without carrying a phantom blank line into the
/// diff.
private nonisolated func splitForDiff(_ content: String) -> (lines: [String], numberingCount: Int) {
    var lines = content.components(separatedBy: "\n")
    let count = lines.count
    if lines.last == "" { lines.removeLast() }
    return (lines, count)
}

// MARK: - Line diff

/// One run of same-kind lines in a diff.
enum DiffKind {
    case equal
    case added
    case removed
}

struct DiffPart {
    var kind: DiffKind
    var lines: [String]
}

/// Diffs two line arrays into ordered runs, standing in for the `diff` package's
/// `diffLines`.
///
/// Common prefix and suffix are trimmed first — the overwhelmingly common edit
/// touches a few lines of a large file, and trimming turns that into a tiny
/// middle the quadratic LCS can chew cheaply, keeping the whole thing near-linear
/// in practice. The changed middle is grouped into a removed run then an added
/// run per contiguous change region, matching how `diffLines` presents a
/// modification (old before new) — which is what `renderDiff` pairs up for
/// intra-line highlighting.
nonisolated func diffLines(_ old: [String], _ new: [String]) -> [DiffPart] {
    var start = 0
    let prefixMax = min(old.count, new.count)
    while start < prefixMax && old[start] == new[start] { start += 1 }

    var oldEnd = old.count
    var newEnd = new.count
    while oldEnd > start && newEnd > start && old[oldEnd - 1] == new[newEnd - 1] {
        oldEnd -= 1
        newEnd -= 1
    }

    var parts: [DiffPart] = []
    if start > 0 { parts.append(DiffPart(kind: .equal, lines: Array(old[0..<start]))) }
    parts.append(contentsOf: middleDiff(Array(old[start..<oldEnd]), Array(new[start..<newEnd])))
    if oldEnd < old.count { parts.append(DiffPart(kind: .equal, lines: Array(old[oldEnd..<old.count]))) }
    return parts
}

/// LCS diff of the non-common middle, grouped into removed-then-added runs
/// around each preserved (equal) line.
private nonisolated func middleDiff(_ a: [String], _ b: [String]) -> [DiffPart] {
    if a.isEmpty && b.isEmpty { return [] }
    if a.isEmpty { return [DiffPart(kind: .added, lines: b)] }
    if b.isEmpty { return [DiffPart(kind: .removed, lines: a)] }

    let n = a.count
    let m = b.count
    // dp[i][j] = LCS length of a[i...] and b[j...].
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    var i = n - 1
    while i >= 0 {
        var j = m - 1
        while j >= 0 {
            if a[i] == b[j] {
                dp[i][j] = dp[i + 1][j + 1] + 1
            } else {
                dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
            }
            j -= 1
        }
        i -= 1
    }

    var parts: [DiffPart] = []
    var removed: [String] = []
    var added: [String] = []

    func flush() {
        if !removed.isEmpty { parts.append(DiffPart(kind: .removed, lines: removed)); removed = [] }
        if !added.isEmpty { parts.append(DiffPart(kind: .added, lines: added)); added = [] }
    }

    i = 0
    var j = 0
    while i < n && j < m {
        if a[i] == b[j] {
            flush()
            // Coalesce the equal run.
            var run: [String] = []
            while i < n && j < m && a[i] == b[j] {
                run.append(a[i])
                i += 1
                j += 1
            }
            parts.append(DiffPart(kind: .equal, lines: run))
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            removed.append(a[i])
            i += 1
        } else {
            added.append(b[j])
            j += 1
        }
    }
    while i < n { removed.append(a[i]); i += 1 }
    while j < m { added.append(b[j]); j += 1 }
    flush()
    return parts
}

// MARK: - Diff colouring

/// A parsed diff line: its prefix (`+`, `-`, or space), line-number field, and
/// content. Ports `parseDiffLine`.
private struct ParsedDiffLine {
    var prefix: Character
    var lineNum: String
    var content: String
}

/// Parses a `generateDiffString` line back into prefix / number / content.
/// Format: one of `+`/`-`/` `, then a (possibly space-padded) number field, one
/// space, then the content.
private nonisolated func parseDiffLine(_ line: String) -> ParsedDiffLine? {
    guard let first = line.first, first == "+" || first == "-" || first == " " else { return nil }
    let rest = Array(line.dropFirst())
    // The number field runs up to the first space (it may be all spaces for a
    // `...` elision marker line).
    var k = 0
    while k < rest.count && rest[k] != " " { k += 1 }
    guard k < rest.count else { return nil }
    let numField = String(rest[0..<k])
    // Every digit-or-blank field is valid; reject anything else so a real text
    // line that merely starts with a sign is not mis-parsed.
    guard numField.allSatisfy({ $0.isNumber || $0 == " " }) else { return nil }
    let content = String(rest[(k + 1)...])
    return ParsedDiffLine(prefix: first, lineNum: numField, content: content)
}

/// Colours a diff string into width-clipped terminal lines: removed red, added
/// green, context dim, with an inverse intra-line highlight when exactly one line
/// was removed and one added (a single-line modification). Ports `renderDiff`.
nonisolated func renderDiff(_ diff: [String], width: Int, theme: ToolRenderTheme) -> [String] {
    var result: [String] = []
    var i = 0
    while i < diff.count {
        let line = diff[i]
        guard let parsed = parseDiffLine(line) else {
            result.append(clip(theme.diffContext(line), to: width))
            i += 1
            continue
        }

        if parsed.prefix == "-" {
            var removed: [ParsedDiffLine] = []
            while i < diff.count, let p = parseDiffLine(diff[i]), p.prefix == "-" {
                removed.append(p)
                i += 1
            }
            var added: [ParsedDiffLine] = []
            while i < diff.count, let p = parseDiffLine(diff[i]), p.prefix == "+" {
                added.append(p)
                i += 1
            }

            if removed.count == 1 && added.count == 1 {
                let pair = renderIntraLineDiff(
                    replaceTabs(removed[0].content),
                    replaceTabs(added[0].content),
                    theme: theme
                )
                result.append(clip(theme.diffRemoved("-\(removed[0].lineNum) \(pair.removed)"), to: width))
                result.append(clip(theme.diffAdded("+\(added[0].lineNum) \(pair.added)"), to: width))
            } else {
                for r in removed {
                    result.append(clip(theme.diffRemoved("-\(r.lineNum) \(replaceTabs(r.content))"), to: width))
                }
                for a in added {
                    result.append(clip(theme.diffAdded("+\(a.lineNum) \(replaceTabs(a.content))"), to: width))
                }
            }
        } else if parsed.prefix == "+" {
            result.append(clip(theme.diffAdded("+\(parsed.lineNum) \(replaceTabs(parsed.content))"), to: width))
            i += 1
        } else {
            result.append(clip(theme.diffContext(" \(parsed.lineNum) \(replaceTabs(parsed.content))"), to: width))
            i += 1
        }
    }
    return result
}

/// Highlights the changed tokens of a single-line modification with the inverse
/// hook, leaving shared runs unstyled. Ports `renderIntraLineDiff`: leading
/// whitespace on the first changed token of each side is left un-highlighted so
/// indentation is never inverted.
private nonisolated func renderIntraLineDiff(
    _ oldContent: String,
    _ newContent: String,
    theme: ToolRenderTheme
) -> (removed: String, added: String) {
    let parts = diffLines(tokenize(oldContent), tokenize(newContent))
    var removedLine = ""
    var addedLine = ""
    var isFirstRemoved = true
    var isFirstAdded = true

    for part in parts {
        let value = part.lines.joined()
        switch part.kind {
        case .removed:
            var text = value
            if isFirstRemoved {
                let leading = leadingWhitespace(text)
                removedLine += leading
                text = String(text.dropFirst(leading.count))
                isFirstRemoved = false
            }
            if !text.isEmpty { removedLine += theme.inverse(text) }
        case .added:
            var text = value
            if isFirstAdded {
                let leading = leadingWhitespace(text)
                addedLine += leading
                text = String(text.dropFirst(leading.count))
                isFirstAdded = false
            }
            if !text.isEmpty { addedLine += theme.inverse(text) }
        case .equal:
            removedLine += value
            addedLine += value
        }
    }
    return (removedLine, addedLine)
}

/// The run of leading whitespace of `text`.
private nonisolated func leadingWhitespace(_ text: String) -> String {
    var result = ""
    for character in text {
        if character == " " || character == "\t" { result.append(character) } else { break }
    }
    return result
}

/// Splits a line into word / non-word tokens for the intra-line diff. Runs of
/// alphanumerics form one token; every other character is its own token, so a
/// changed identifier highlights as a unit while punctuation stays granular.
/// A pragmatic stand-in for the `diff` package's `diffWords` — the visible
/// behaviour that matters (added/removed line colouring) does not depend on the
/// exact tokenisation.
private nonisolated func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in text {
        if character.isLetter || character.isNumber {
            current.append(character)
        } else {
            if !current.isEmpty { tokens.append(current); current = "" }
            tokens.append(String(character))
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}
