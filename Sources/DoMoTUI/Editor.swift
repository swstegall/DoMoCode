// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/editor.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness — the multi-line editor: word-wrap
// layout with a logical↔visual position map, sticky-column vertical movement,
// atomic paste markers with a renumbering registry, an emacs kill ring, fish-
// style coalescing undo, prompt history, character jump, and a scrolling
// viewport.
//
// Deliberate divergences from pi (documented at their sites below):
//   * The buffer is `[[Character]]` (one grapheme-cluster array per logical
//     line) with `Int` cursor indices, replacing pi's `string[]` and its
//     UTF-16-code-unit arithmetic. A Swift `Character` *is* a grapheme cluster,
//     so cursor motion and deletion cannot split one — this removes pi's manual
//     `Intl.Segmenter` grapheme walking wholesale.
//   * Paste markers, which pi merges into single atomic segments via a marker-
//     aware `Intl.Segmenter`, are handled here by scanning each line for marker
//     ranges (`findMarkers`) and treating those ranges atomically for cursor
//     motion, deletion, word navigation, and wrapping.
//   * Autocomplete is out of scope for this component (a separate slice owns the
//     provider and fuzzy matcher); pi's autocomplete wiring is intentionally not
//     ported. The kill ring reuses the module-internal `KillRing` defined in
//     `Input.swift` rather than redeclaring it.

import DoMoTermIO

// MARK: - Paste markers

/// A marker occurrence found in a line: the `Character`-index range it spans and
/// its numeric id.
struct MarkerMatch {
    var range: Range<Int>
    var id: Int
}

private nonisolated func isASCIIDigit(_ c: Character) -> Bool {
    c >= "0" && c <= "9"
}

private nonisolated func matchAt(_ chars: [Character], _ pos: Int, _ pattern: [Character]) -> Bool {
    guard pos + pattern.count <= chars.count else { return false }
    for k in 0..<pattern.count where chars[pos + k] != pattern[k] { return false }
    return true
}

private nonisolated let markerPrefix = Array("[paste #")
private nonisolated let markerLinesSuffix = Array(" lines")
private nonisolated let markerCharsSuffix = Array(" chars")

/// Find paste-marker occurrences (`[paste #N]`, `[paste #N +M lines]`, or
/// `[paste #N K chars]`) in a `Character` array.
///
/// When `validIds` is non-nil, only markers whose id is in the set are returned
/// (marker-aware segmentation only treats *real* pastes as atomic, so manually
/// typed marker-like text stays ordinary). When `validIds` is nil, every
/// structurally valid marker matches, regardless of id — this is what the
/// renumber pass needs.
nonisolated func findMarkers(_ chars: [Character], validIds: Set<Int>?) -> [MarkerMatch] {
    if let ids = validIds, ids.isEmpty { return [] }
    var result: [MarkerMatch] = []
    let n = chars.count
    var i = 0
    while i < n {
        guard matchAt(chars, i, markerPrefix) else { i += 1; continue }
        var j = i + markerPrefix.count
        var idString = ""
        while j < n, isASCIIDigit(chars[j]) {
            idString.append(chars[j])
            j += 1
        }
        guard !idString.isEmpty, let id = Int(idString) else { i += 1; continue }

        var end = j
        if j < n, chars[j] == " " {
            // Optional " +M lines" or " K chars" suffix.
            if j + 1 < n, chars[j + 1] == "+" {
                var t = j + 2
                var digits = ""
                while t < n, isASCIIDigit(chars[t]) { digits.append(chars[t]); t += 1 }
                if !digits.isEmpty, matchAt(chars, t, markerLinesSuffix) { end = t + markerLinesSuffix.count }
            } else {
                var t = j + 1
                var digits = ""
                while t < n, isASCIIDigit(chars[t]) { digits.append(chars[t]); t += 1 }
                if !digits.isEmpty, matchAt(chars, t, markerCharsSuffix) { end = t + markerCharsSuffix.count }
            }
        }

        guard end < n, chars[end] == "]" else { i += 1; continue }
        let close = end + 1
        if validIds == nil || validIds!.contains(id) {
            result.append(MarkerMatch(range: i..<close, id: id))
        }
        i = close
    }
    return result
}

// MARK: - Word wrap

/// A chunk of a wrapped line: its rendered text and the `Character`-index span it
/// covers in the source line.
struct TextChunk {
    var text: String
    var startIndex: Int
    var endIndex: Int
}

/// One grapheme-or-marker segment of a line, for wrap and cursor layout.
private struct GraphemeSeg {
    var start: Int
    var length: Int
    var text: String
    var width: Int
    var isMarker: Bool
}

/// Build the marker-aware grapheme segmentation of a line: a paste marker in
/// `markers` becomes one atomic segment; every other `Character` is its own.
private nonisolated func graphemeSegments(_ line: [Character], _ markers: [Range<Int>]) -> [GraphemeSeg] {
    var segs: [GraphemeSeg] = []
    var i = 0
    let n = line.count
    while i < n {
        if let m = markers.first(where: { $0.lowerBound == i }) {
            let text = String(line[m])
            segs.append(GraphemeSeg(start: i, length: m.count, text: text, width: visibleWidth(text), isMarker: true))
            i = m.upperBound
        } else {
            let c = line[i]
            segs.append(GraphemeSeg(start: i, length: 1, text: String(c), width: graphemeWidth(c), isMarker: false))
            i += 1
        }
    }
    return segs
}

/// Split a line into word-wrapped chunks. Wraps at word boundaries when possible,
/// allows a break at any CJK boundary, and force-breaks a token longer than the
/// available width. An atomic segment (paste marker) wider than `maxWidth` is
/// re-wrapped at `Character` granularity — the split is purely visual; the segment
/// stays logically atomic for cursor motion.
///
/// Ported from pi's `wordWrapLine`. `markers` gives the atomic ranges; tests pass
/// them directly, the editor derives them from valid paste ids.
nonisolated func wordWrapLine(_ line: String, _ maxWidth: Int, markers: [Range<Int>] = []) -> [TextChunk] {
    wordWrapLine(Array(line), maxWidth, markers)
}

nonisolated func wordWrapLine(_ line: [Character], _ maxWidth: Int, _ markers: [Range<Int>] = []) -> [TextChunk] {
    if line.isEmpty || maxWidth <= 0 {
        return [TextChunk(text: "", startIndex: 0, endIndex: 0)]
    }
    let segments = graphemeSegments(line, markers)
    var lineWidth = 0
    for s in segments { lineWidth += s.width }
    if lineWidth <= maxWidth {
        return [TextChunk(text: String(line), startIndex: 0, endIndex: line.count)]
    }
    return wrapSegments(line, maxWidth, segments)
}

private nonisolated func isWhitespaceSeg(_ seg: GraphemeSeg, _ line: [Character]) -> Bool {
    !seg.isMarker && seg.length == 1 && isWhitespaceCluster(line[seg.start])
}

private nonisolated func wrapSegments(_ line: [Character], _ maxWidth: Int, _ segments: [GraphemeSeg]) -> [TextChunk] {
    var chunks: [TextChunk] = []
    var currentWidth = 0
    var chunkStart = 0
    var wrapOppIndex = -1
    var wrapOppWidth = 0

    var idx = 0
    while idx < segments.count {
        let seg = segments[idx]
        let gWidth = seg.width
        let charIndex = seg.start
        let isWs = isWhitespaceSeg(seg, line)

        // Overflow check before advancing.
        if currentWidth + gWidth > maxWidth {
            if wrapOppIndex >= 0, currentWidth - wrapOppWidth + gWidth <= maxWidth {
                chunks.append(TextChunk(text: String(line[chunkStart..<wrapOppIndex]), startIndex: chunkStart, endIndex: wrapOppIndex))
                chunkStart = wrapOppIndex
                currentWidth -= wrapOppWidth
            } else if chunkStart < charIndex {
                chunks.append(TextChunk(text: String(line[chunkStart..<charIndex]), startIndex: chunkStart, endIndex: charIndex))
                chunkStart = charIndex
                currentWidth = 0
            }
            wrapOppIndex = -1
        }

        if gWidth > maxWidth {
            let segChars = Array(seg.text)
            if segChars.count > 1 {
                // Oversized *multi-cluster* atomic segment (a paste marker):
                // re-wrap its text at Character granularity.
                let subChunks = wordWrapLine(segChars, maxWidth)
                if subChunks.count >= 1 {
                    for j in 0..<(subChunks.count - 1) {
                        let sc = subChunks[j]
                        chunks.append(TextChunk(text: sc.text, startIndex: charIndex + sc.startIndex, endIndex: charIndex + sc.endIndex))
                    }
                    let last = subChunks[subChunks.count - 1]
                    chunkStart = charIndex + last.startIndex
                    currentWidth = visibleWidth(last.text)
                }
            } else {
                // A single grapheme cluster wider than `maxWidth` (a width-2 CJK
                // or emoji in a very narrow column) is indivisible: re-wrapping
                // its text yields the same one-cluster line and recurses forever.
                // Emit it as its own chunk instead. The chunk is wider than
                // `maxWidth`, but that is unavoidable for an atomic grapheme and
                // the renderer's width guard handles the degenerate case.
                if chunkStart < charIndex {
                    chunks.append(TextChunk(text: String(line[chunkStart..<charIndex]), startIndex: chunkStart, endIndex: charIndex))
                }
                chunks.append(TextChunk(text: seg.text, startIndex: charIndex, endIndex: charIndex + seg.length))
                chunkStart = charIndex + seg.length
                currentWidth = 0
            }
            wrapOppIndex = -1
            idx += 1
            continue
        }

        currentWidth += gWidth

        // Record a wrap opportunity.
        let next: GraphemeSeg? = idx + 1 < segments.count ? segments[idx + 1] : nil
        if isWs, let next {
            let nextIsWs = isWhitespaceSeg(next, line)
            if next.isMarker || !nextIsWs {
                wrapOppIndex = next.start
                wrapOppWidth = currentWidth
            }
        } else if !isWs, let next {
            let nextIsWs = isWhitespaceSeg(next, line)
            if !nextIsWs {
                let isCjk = !seg.isMarker && isCJKCluster(line[seg.start])
                let nextIsCjk = !next.isMarker && next.length == 1 && isCJKCluster(line[next.start])
                if isCjk || nextIsCjk {
                    wrapOppIndex = next.start
                    wrapOppWidth = currentWidth
                }
            }
        }
        idx += 1
    }

    chunks.append(TextChunk(text: String(line[chunkStart...]), startIndex: chunkStart, endIndex: line.count))
    return chunks
}

// MARK: - Theme

/// The editor's theme: how border lines are coloured.
///
/// pi's `EditorTheme` also carries a `SelectListTheme` for the autocomplete
/// popup; that surface is a separate slice and omitted here.
public struct EditorTheme {
    public var borderColor: (String) -> String

    public init(borderColor: @escaping (String) -> String = { $0 }) {
        self.borderColor = borderColor
    }
}

// MARK: - Editor

/// A multi-line text editor.
public final class Editor: Component, Focusable {
    private struct EditorState {
        var lines: [[Character]] = [[]]
        var cursorLine: Int = 0
        var cursorCol: Int = 0
    }

    private struct EditorSnapshot {
        var state: EditorState
        var pastes: [Int: String]
        var pasteCounter: Int
    }

    private enum LastAction { case kill, yank, typeWord }
    private enum JumpMode { case forward, backward }

    private var state = EditorState()

    public var focused = false

    private let keybindings: Keybindings
    private var theme: EditorTheme
    private let rows: () -> Int
    private var paddingX: Int

    /// Last layout width, kept in lockstep with the wrapping width so cursor
    /// navigation and rendering agree.
    private var lastWidth = 80

    private var scrollOffset = 0

    public var borderColor: (String) -> String

    // Paste registry.
    private var pastes: [Int: String] = [:]
    private var pasteCounter = 0

    // Bracketed paste buffering.
    private var pasteBuffer = ""
    private var isInPaste = false

    // Prompt history.
    private var history: [String] = []
    private var historyIndex = -1
    private var historyDraft: EditorState?

    // Kill ring (reuses the module-internal `KillRing` from Input.swift).
    private var killRing = KillRing()
    private var lastAction: LastAction?

    // Character jump.
    private var jumpMode: JumpMode?

    // Sticky column for vertical movement.
    private var preferredVisualCol: Int?
    private var snappedFromCursorCol: Int?

    // Undo.
    private var undoStack = UndoStack<EditorSnapshot>()

    public var onSubmit: ((String) -> Void)?
    public var onChange: ((String) -> Void)?
    public var disableSubmit = false

    public var wantsKeyRelease: Bool { false }

    private static let pasteStart = "\u{1b}[200~"
    private static let pasteEnd = "\u{1b}[201~"

    public init(
        theme: EditorTheme = EditorTheme(),
        keybindings: Keybindings = Keybindings(),
        paddingX: Int = 0,
        rows: @escaping () -> Int = { 24 }
    ) {
        self.theme = theme
        self.keybindings = keybindings
        self.borderColor = theme.borderColor
        self.paddingX = max(0, paddingX)
        self.rows = rows
    }

    // MARK: Paste-id set

    private func validPasteIds() -> Set<Int> { Set(pastes.keys) }

    /// Valid marker ranges in a given line.
    private func markerRanges(_ line: [Character]) -> [Range<Int>] {
        findMarkers(line, validIds: validPasteIds()).map(\.range)
    }

    // MARK: Public accessors

    public func getText() -> String {
        state.lines.map { String($0) }.joined(separator: "\n")
    }

    /// The document with paste markers expanded to their stored content.
    public func getExpandedText() -> String {
        expandPasteMarkers(getText())
    }

    public func getLines() -> [String] {
        state.lines.map { String($0) }
    }

    public func getCursor() -> (line: Int, col: Int) {
        (state.cursorLine, state.cursorCol)
    }

    public func getPaddingX() -> Int { paddingX }

    // MARK: Prompt history

    /// Add a submitted prompt to history for up/down navigation.
    public func addToHistory(_ text: String) {
        let trimmed = text.trimmingCharactersInWhitespace()
        if trimmed.isEmpty { return }
        if let first = history.first, first == trimmed { return }
        history.insert(trimmed, at: 0)
        if history.count > 100 { history.removeLast() }
    }

    // MARK: setText

    public func setText(_ text: String) {
        lastAction = nil
        exitHistoryBrowsing()
        let normalized = normalizeText(text)
        if getText() != normalized {
            pushUndoSnapshot()
        }
        pastes.removeAll()
        pasteCounter = 0
        setTextInternal(normalized)
    }

    public func insertTextAtCursor(_ text: String) {
        if text.isEmpty { return }
        pushUndoSnapshot()
        lastAction = nil
        exitHistoryBrowsing()
        insertTextAtCursorInternal(text)
    }

    // MARK: Focusable / Component

    public func invalidate() {}

    // MARK: Input dispatch

    public func handleInput(_ data: [UInt8]) {
        var text = String(decoding: data, as: UTF8.self)
        let kb = keybindings

        // Character jump mode.
        if let mode = jumpMode {
            if kb.matches(data, .editorJumpForward) || kb.matches(data, .editorJumpBackward) {
                jumpMode = nil
                return
            }
            var printable = decodePrintableKey(data)
            if printable == nil, let first = text.unicodeScalars.first, first.value >= 32 {
                printable = text
            }
            if let printable, !printable.isEmpty {
                jumpMode = nil
                jumpToChar(Character(String(printable.prefix(1))), mode)
                return
            }
            jumpMode = nil
            // fall through
        }

        // Bracketed paste.
        if text.contains(Editor.pasteStart) {
            isInPaste = true
            pasteBuffer = ""
            text = text.replacingOccurrences(of: Editor.pasteStart, with: "")
        }
        if isInPaste {
            pasteBuffer += text
            if let endRange = pasteBuffer.range(of: Editor.pasteEnd) {
                let pasteContent = String(pasteBuffer[pasteBuffer.startIndex..<endRange.lowerBound])
                if !pasteContent.isEmpty { handlePaste(pasteContent) }
                isInPaste = false
                let remaining = String(pasteBuffer[endRange.upperBound...])
                pasteBuffer = ""
                if !remaining.isEmpty { handleInput(Array(remaining.utf8)) }
            }
            return
        }

        // Ctrl+C — let the parent handle exit/clear.
        if kb.matches(data, .inputCopy) { return }

        if kb.matches(data, .editorUndo) { undo(); return }

        // Tab — no-op here (autocomplete is a separate slice).
        if kb.matches(data, .inputTab) { return }

        // Deletion.
        if kb.matches(data, .editorDeleteToLineEnd) { deleteToEndOfLine(); return }
        if kb.matches(data, .editorDeleteToLineStart) { deleteToStartOfLine(); return }
        if kb.matches(data, .editorDeleteWordBackward) { deleteWordBackwards(); return }
        if kb.matches(data, .editorDeleteWordForward) { deleteWordForward(); return }
        if kb.matches(data, .editorDeleteCharBackward) { handleBackspace(); return }
        if kb.matches(data, .editorDeleteCharForward) { handleForwardDelete(); return }

        // Kill ring.
        if kb.matches(data, .editorYank) { yank(); return }
        if kb.matches(data, .editorYankPop) { yankPop(); return }

        // Cursor movement.
        if kb.matches(data, .editorCursorLineStart) { moveToLineStart(); return }
        if kb.matches(data, .editorCursorLineEnd) { moveToLineEnd(); return }
        if kb.matches(data, .editorCursorWordLeft) { moveWordBackwards(); return }
        if kb.matches(data, .editorCursorWordRight) { moveWordForwards(); return }

        // New line (Shift+Enter / Ctrl+J, or a bare LF).
        if kb.matches(data, .inputNewLine) || text == "\n" {
            addNewLine()
            return
        }

        // Submit (Enter). Backslash-immediately-before-cursor becomes a newline,
        // a workaround for terminals without Shift+Enter.
        if kb.matches(data, .inputSubmit) {
            if disableSubmit { return }
            let currentLine = state.lines[state.cursorLine]
            if state.cursorCol > 0, currentLine[state.cursorCol - 1] == "\\" {
                handleBackspace()
                addNewLine()
                return
            }
            submitValue()
            return
        }

        // Arrow navigation with history support.
        if kb.matches(data, .editorCursorUp) {
            if isOnFirstVisualLine(), isEditorEmpty() || historyIndex > -1 || state.cursorCol == 0 {
                navigateHistory(-1)
            } else if isOnFirstVisualLine() {
                moveToLineStart()
            } else {
                moveCursor(deltaLine: -1, deltaCol: 0)
            }
            return
        }
        if kb.matches(data, .editorCursorDown) {
            if historyIndex > -1, isOnLastVisualLine() {
                navigateHistory(1)
            } else if isOnLastVisualLine() {
                moveToLineEnd()
            } else {
                moveCursor(deltaLine: 1, deltaCol: 0)
            }
            return
        }
        if kb.matches(data, .editorCursorRight) { moveCursor(deltaLine: 0, deltaCol: 1); return }
        if kb.matches(data, .editorCursorLeft) { moveCursor(deltaLine: 0, deltaCol: -1); return }

        if kb.matches(data, .editorPageUp) { pageScroll(-1); return }
        if kb.matches(data, .editorPageDown) { pageScroll(1); return }

        if kb.matches(data, .editorJumpForward) { jumpMode = .forward; return }
        if kb.matches(data, .editorJumpBackward) { jumpMode = .backward; return }

        // Printable input.
        if let printable = decodePrintableKey(data) {
            insertCharacter(printable)
            return
        }
        if let first = text.unicodeScalars.first, first.value >= 32, !hasControlScalars(text) {
            insertCharacter(text)
        }
    }

    // MARK: Layout

    private struct LayoutLine {
        var text: String
        var hasCursor: Bool
        var cursorPos: Int?
    }

    private func layoutText(_ contentWidth: Int) -> [LayoutLine] {
        var layoutLines: [LayoutLine] = []

        if isEditorEmpty() {
            layoutLines.append(LayoutLine(text: "", hasCursor: true, cursorPos: 0))
            return layoutLines
        }

        for i in 0..<state.lines.count {
            let line = state.lines[i]
            let isCurrentLine = i == state.cursorLine
            let lineVisibleWidth = visibleWidth(String(line))

            if lineVisibleWidth <= contentWidth {
                layoutLines.append(LayoutLine(
                    text: String(line),
                    hasCursor: isCurrentLine,
                    cursorPos: isCurrentLine ? state.cursorCol : nil
                ))
            } else {
                let chunks = wordWrapLine(line, contentWidth, markerRanges(line))
                for chunkIndex in 0..<chunks.count {
                    let chunk = chunks[chunkIndex]
                    let cursorPos = state.cursorCol
                    let isLastChunk = chunkIndex == chunks.count - 1

                    var hasCursorInChunk = false
                    var adjustedCursorPos = 0
                    if isCurrentLine {
                        if isLastChunk {
                            hasCursorInChunk = cursorPos >= chunk.startIndex
                            adjustedCursorPos = cursorPos - chunk.startIndex
                        } else {
                            hasCursorInChunk = cursorPos >= chunk.startIndex && cursorPos < chunk.endIndex
                            if hasCursorInChunk {
                                adjustedCursorPos = cursorPos - chunk.startIndex
                                let textLen = chunk.text.count
                                if adjustedCursorPos > textLen { adjustedCursorPos = textLen }
                            }
                        }
                    }

                    layoutLines.append(LayoutLine(
                        text: chunk.text,
                        hasCursor: hasCursorInChunk,
                        cursorPos: hasCursorInChunk ? adjustedCursorPos : nil
                    ))
                }
            }
        }
        return layoutLines
    }

    public func render(width: Int) -> [String] {
        let maxPadding = max(0, (width - 1) / 2)
        let effectivePadding = min(paddingX, maxPadding)
        let contentWidth = max(1, width - effectivePadding * 2)
        let layoutWidth = max(1, contentWidth - (effectivePadding > 0 ? 0 : 1))
        lastWidth = layoutWidth

        let horizontal = theme.borderColor("─")
        let layoutLines = layoutText(layoutWidth)

        let terminalRows = rows()
        let maxVisibleLines = max(5, Int(Double(terminalRows) * 0.3))

        let cursorLineIndex = layoutLines.firstIndex(where: { $0.hasCursor }) ?? 0

        if cursorLineIndex < scrollOffset {
            scrollOffset = cursorLineIndex
        } else if cursorLineIndex >= scrollOffset + maxVisibleLines {
            scrollOffset = cursorLineIndex - maxVisibleLines + 1
        }
        let maxScrollOffset = max(0, layoutLines.count - maxVisibleLines)
        scrollOffset = max(0, min(scrollOffset, maxScrollOffset))

        let visibleEnd = min(scrollOffset + maxVisibleLines, layoutLines.count)
        let visibleLines = Array(layoutLines[scrollOffset..<visibleEnd])

        var result: [String] = []
        let leftPadding = String(repeating: " ", count: effectivePadding)
        let rightPadding = leftPadding

        // Top border.
        if scrollOffset > 0 {
            let indicator = "─── ↑ \(scrollOffset) more "
            let remaining = width - visibleWidth(indicator)
            if remaining >= 0 {
                result.append(theme.borderColor(indicator + String(repeating: "─", count: remaining)))
            } else {
                result.append(theme.borderColor(truncateToWidth(indicator, width, ellipsis: "")))
            }
        } else {
            result.append(String(repeating: horizontal, count: width))
        }

        let emitCursorMarker = focused

        for layoutLine in visibleLines {
            var displayText = layoutLine.text
            var lineVisibleWidth = visibleWidth(layoutLine.text)
            var cursorInPadding = false

            if layoutLine.hasCursor, let rawPos = layoutLine.cursorPos {
                let chars = Array(displayText)
                let cursorPos = min(max(0, rawPos), chars.count)
                let marker = emitCursorMarker ? cursorMarker : ""
                if cursorPos < chars.count {
                    let before = String(chars[0..<cursorPos])
                    let atChar = String(chars[cursorPos])
                    let after = String(chars[(cursorPos + 1)...])
                    let cursor = "\u{1b}[7m\(atChar)\u{1b}[0m"
                    displayText = before + marker + cursor + after
                } else {
                    let cursor = "\u{1b}[7m \u{1b}[0m"
                    displayText = displayText + marker + cursor
                    lineVisibleWidth += 1
                    if lineVisibleWidth > contentWidth, effectivePadding > 0 {
                        cursorInPadding = true
                    }
                }
            }

            let padding = String(repeating: " ", count: max(0, contentWidth - lineVisibleWidth))
            let lineRightPadding = cursorInPadding ? String(rightPadding.dropFirst()) : rightPadding
            result.append("\(leftPadding)\(displayText)\(padding)\(lineRightPadding)")
        }

        // Bottom border.
        let linesBelow = layoutLines.count - (scrollOffset + visibleLines.count)
        if linesBelow > 0 {
            let indicator = "─── ↓ \(linesBelow) more "
            let remaining = width - visibleWidth(indicator)
            result.append(theme.borderColor(indicator + String(repeating: "─", count: max(0, remaining))))
        } else {
            result.append(String(repeating: horizontal, count: width))
        }

        return result
    }

    // MARK: Text mutation helpers

    private func isEditorEmpty() -> Bool {
        state.lines.count == 1 && state.lines[0].isEmpty
    }

    /// Normalize line endings (`\r\n`, `\r` → `\n`) and expand tabs to 4 spaces.
    private func normalizeText(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\t", with: "    ")
        return t
    }

    private func setTextInternal(_ text: String, placement: CursorPlacement = .end) {
        let parts = text.components(separatedBy: "\n")
        state.lines = parts.isEmpty ? [[]] : parts.map { Array($0) }
        state.cursorLine = placement == .start ? 0 : state.lines.count - 1
        setCursorCol(placement == .start ? 0 : state.lines[state.cursorLine].count)
        scrollOffset = 0
        onChange?(getText())
    }

    private enum CursorPlacement { case start, end }

    private func insertTextAtCursorInternal(_ text: String) {
        if text.isEmpty { return }
        let normalized = normalizeText(text)
        let insertedLines = normalized.components(separatedBy: "\n").map { Array($0) }

        let currentLine = state.lines[state.cursorLine]
        let beforeCursor = Array(currentLine[0..<state.cursorCol])
        let afterCursor = Array(currentLine[state.cursorCol...])

        if insertedLines.count == 1 {
            state.lines[state.cursorLine] = beforeCursor + insertedLines[0] + afterCursor
            setCursorCol(state.cursorCol + insertedLines[0].count)
        } else {
            var newLines: [[Character]] = []
            newLines.append(contentsOf: state.lines[0..<state.cursorLine])
            newLines.append(beforeCursor + insertedLines[0])
            if insertedLines.count > 2 {
                newLines.append(contentsOf: insertedLines[1..<(insertedLines.count - 1)])
            }
            newLines.append(insertedLines[insertedLines.count - 1] + afterCursor)
            newLines.append(contentsOf: state.lines[(state.cursorLine + 1)...])
            state.lines = newLines
            state.cursorLine += insertedLines.count - 1
            setCursorCol(insertedLines[insertedLines.count - 1].count)
        }
        onChange?(getText())
    }

    private func insertCharacter(_ char: String) {
        exitHistoryBrowsing()
        let chars = Array(char)
        guard !chars.isEmpty else { return }

        // Undo coalescing (fish-style): consecutive word chars fold into one
        // unit; a space captures the pre-space state and is separately undoable.
        if isWhitespaceString(char) || lastAction != .typeWord {
            pushUndoSnapshot()
        }
        lastAction = .typeWord

        let line = state.lines[state.cursorLine]
        let before = Array(line[0..<state.cursorCol])
        let after = Array(line[state.cursorCol...])
        state.lines[state.cursorLine] = before + chars + after
        setCursorCol(state.cursorCol + chars.count)
        onChange?(getText())
    }

    private func handlePaste(_ pastedText: String) {
        exitHistoryBrowsing()
        lastAction = nil
        pushUndoSnapshot()

        // Decode CSI-u Ctrl+<letter> re-encodings some terminals inject into a
        // paste (tmux popups with extended-keys-format=csi-u).
        let decoded = decodeCSIuControls(pastedText)
        let cleanText = normalizeText(decoded)

        // Keep newlines and printable characters, drop other control chars.
        var filtered = String(cleanText.filter { $0 == "\n" || ($0.unicodeScalars.first.map { $0.value >= 32 } ?? false) })

        // A pasted path following a word char reads better with a leading space.
        if let firstScalar = filtered.first, firstScalar == "/" || firstScalar == "~" || firstScalar == "." {
            let currentLine = state.lines[state.cursorLine]
            if state.cursorCol > 0 {
                let before = currentLine[state.cursorCol - 1]
                if isWordCharacter(before) { filtered = " " + filtered }
            }
        }

        let pastedLines = filtered.components(separatedBy: "\n")
        let totalChars = filtered.count

        if pastedLines.count > 10 || totalChars > 1000 {
            pasteCounter += 1
            let pasteId = pasteCounter
            pastes[pasteId] = filtered
            let marker: String = pastedLines.count > 10
                ? "[paste #\(pasteId) +\(pastedLines.count) lines]"
                : "[paste #\(pasteId) \(totalChars) chars]"
            insertTextAtCursorInternal(marker)
            return
        }

        insertTextAtCursorInternal(filtered)
    }

    private func addNewLine() {
        exitHistoryBrowsing()
        lastAction = nil
        pushUndoSnapshot()

        let currentLine = state.lines[state.cursorLine]
        let before = Array(currentLine[0..<state.cursorCol])
        let after = Array(currentLine[state.cursorCol...])
        state.lines[state.cursorLine] = before
        state.lines.insert(after, at: state.cursorLine + 1)
        state.cursorLine += 1
        setCursorCol(0)
        onChange?(getText())
    }

    private func submitValue() {
        let result = expandPasteMarkers(getText()).trimmingCharactersInWhitespace()
        state = EditorState()
        pastes.removeAll()
        pasteCounter = 0
        exitHistoryBrowsing()
        scrollOffset = 0
        undoStack.clear()
        lastAction = nil
        onChange?("")
        onSubmit?(result)
    }

    // MARK: Deletion

    private func handleBackspace() {
        exitHistoryBrowsing()
        lastAction = nil

        if state.cursorCol > 0 {
            pushUndoSnapshot()
            var line = state.lines[state.cursorLine]

            // Atomic paste-marker deletion (a marker ending exactly at the cursor).
            var graphemeLength = 1
            let matches = findMarkers(line, validIds: validPasteIds())
            if let hit = matches.first(where: { $0.range.upperBound == state.cursorCol }) {
                deletePasteRegistryEntry(hit.id)
                graphemeLength = hit.range.count
                line = state.lines[state.cursorLine]
            }

            let before = Array(line[0..<(state.cursorCol - graphemeLength)])
            let after = Array(line[state.cursorCol...])
            state.lines[state.cursorLine] = before + after
            setCursorCol(state.cursorCol - graphemeLength)
        } else if state.cursorLine > 0 {
            pushUndoSnapshot()
            let currentLine = state.lines[state.cursorLine]
            let previousLine = state.lines[state.cursorLine - 1]
            state.lines[state.cursorLine - 1] = previousLine + currentLine
            state.lines.remove(at: state.cursorLine)
            state.cursorLine -= 1
            setCursorCol(previousLine.count)
        }
        onChange?(getText())
    }

    /// Remove a paste id from the registry and renumber higher ids and their
    /// markers, matching pi's ascending-order compaction.
    private func deletePasteRegistryEntry(_ targetId: Int) {
        pastes.removeValue(forKey: targetId)
        pasteCounter -= 1

        let higherIds = pastes.keys.filter { $0 > targetId }.sorted()
        for id in higherIds {
            pastes[id - 1] = pastes[id]
            pastes.removeValue(forKey: id)
        }

        // Renumber markers (any structural marker with id > target → id-1) in
        // every line's text.
        for i in 0..<state.lines.count {
            state.lines[i] = renumberMarkers(state.lines[i], targetId: targetId)
        }
    }

    private func renumberMarkers(_ line: [Character], targetId: Int) -> [Character] {
        let matches = findMarkers(line, validIds: nil)
        if matches.isEmpty { return line }
        var result: [Character] = []
        var pos = 0
        for m in matches {
            result.append(contentsOf: line[pos..<m.range.lowerBound])
            if m.id > targetId {
                // Replace the "#<id>" run inside the marker text.
                let markerText = String(line[m.range])
                let replaced = markerText.replacingOccurrences(of: "#\(m.id)", with: "#\(m.id - 1)")
                result.append(contentsOf: Array(replaced))
            } else {
                result.append(contentsOf: line[m.range])
            }
            pos = m.range.upperBound
        }
        result.append(contentsOf: line[pos...])
        return result
    }

    private func handleForwardDelete() {
        exitHistoryBrowsing()
        lastAction = nil

        let currentLine = state.lines[state.cursorLine]
        if state.cursorCol < currentLine.count {
            pushUndoSnapshot()
            var graphemeLength = 1
            let matches = findMarkers(currentLine, validIds: validPasteIds())
            if let hit = matches.first(where: { $0.range.lowerBound == state.cursorCol }) {
                deletePasteRegistryEntry(hit.id)
                graphemeLength = hit.range.count
            }
            let line = state.lines[state.cursorLine]
            let before = Array(line[0..<state.cursorCol])
            let after = Array(line[(state.cursorCol + graphemeLength)...])
            state.lines[state.cursorLine] = before + after
        } else if state.cursorLine < state.lines.count - 1 {
            pushUndoSnapshot()
            let nextLine = state.lines[state.cursorLine + 1]
            state.lines[state.cursorLine] = currentLine + nextLine
            state.lines.remove(at: state.cursorLine + 1)
        }
        onChange?(getText())
    }

    private func deleteToStartOfLine() {
        exitHistoryBrowsing()
        let currentLine = state.lines[state.cursorLine]
        if state.cursorCol > 0 {
            pushUndoSnapshot()
            let deleted = String(currentLine[0..<state.cursorCol])
            killRing.push(deleted, prepend: true, accumulate: lastAction == .kill)
            lastAction = .kill
            state.lines[state.cursorLine] = Array(currentLine[state.cursorCol...])
            setCursorCol(0)
        } else if state.cursorLine > 0 {
            pushUndoSnapshot()
            killRing.push("\n", prepend: true, accumulate: lastAction == .kill)
            lastAction = .kill
            let previousLine = state.lines[state.cursorLine - 1]
            state.lines[state.cursorLine - 1] = previousLine + currentLine
            state.lines.remove(at: state.cursorLine)
            state.cursorLine -= 1
            setCursorCol(previousLine.count)
        }
        onChange?(getText())
    }

    private func deleteToEndOfLine() {
        exitHistoryBrowsing()
        let currentLine = state.lines[state.cursorLine]
        if state.cursorCol < currentLine.count {
            pushUndoSnapshot()
            let deleted = String(currentLine[state.cursorCol...])
            killRing.push(deleted, prepend: false, accumulate: lastAction == .kill)
            lastAction = .kill
            state.lines[state.cursorLine] = Array(currentLine[0..<state.cursorCol])
        } else if state.cursorLine < state.lines.count - 1 {
            pushUndoSnapshot()
            killRing.push("\n", prepend: false, accumulate: lastAction == .kill)
            lastAction = .kill
            let nextLine = state.lines[state.cursorLine + 1]
            state.lines[state.cursorLine] = currentLine + nextLine
            state.lines.remove(at: state.cursorLine + 1)
        }
        onChange?(getText())
    }

    private func deleteWordBackwards() {
        exitHistoryBrowsing()
        let currentLine = state.lines[state.cursorLine]

        if state.cursorCol == 0 {
            if state.cursorLine > 0 {
                pushUndoSnapshot()
                killRing.push("\n", prepend: true, accumulate: lastAction == .kill)
                lastAction = .kill
                let previousLine = state.lines[state.cursorLine - 1]
                state.lines[state.cursorLine - 1] = previousLine + currentLine
                state.lines.remove(at: state.cursorLine)
                state.cursorLine -= 1
                setCursorCol(previousLine.count)
            }
        } else {
            pushUndoSnapshot()
            let wasKill = lastAction == .kill
            let oldCursorCol = state.cursorCol
            let deleteFrom = findWordBackward(currentLine, oldCursorCol, markers: markerRanges(currentLine))
            let deleted = String(currentLine[deleteFrom..<oldCursorCol])
            killRing.push(deleted, prepend: true, accumulate: wasKill)
            lastAction = .kill
            state.lines[state.cursorLine] = Array(currentLine[0..<deleteFrom]) + Array(currentLine[oldCursorCol...])
            setCursorCol(deleteFrom)
        }
        onChange?(getText())
    }

    private func deleteWordForward() {
        exitHistoryBrowsing()
        let currentLine = state.lines[state.cursorLine]

        if state.cursorCol >= currentLine.count {
            if state.cursorLine < state.lines.count - 1 {
                pushUndoSnapshot()
                killRing.push("\n", prepend: false, accumulate: lastAction == .kill)
                lastAction = .kill
                let nextLine = state.lines[state.cursorLine + 1]
                state.lines[state.cursorLine] = currentLine + nextLine
                state.lines.remove(at: state.cursorLine + 1)
            }
        } else {
            pushUndoSnapshot()
            let wasKill = lastAction == .kill
            let deleteTo = findWordForward(currentLine, state.cursorCol, markers: markerRanges(currentLine))
            let deleted = String(currentLine[state.cursorCol..<deleteTo])
            killRing.push(deleted, prepend: false, accumulate: wasKill)
            lastAction = .kill
            state.lines[state.cursorLine] = Array(currentLine[0..<state.cursorCol]) + Array(currentLine[deleteTo...])
        }
        onChange?(getText())
    }

    // MARK: Cursor movement

    /// Set the cursor column and clear all sticky-column state — for every
    /// non-vertical movement.
    private func setCursorCol(_ col: Int) {
        state.cursorCol = col
        preferredVisualCol = nil
        snappedFromCursorCol = nil
    }

    private func moveToLineStart() {
        lastAction = nil
        setCursorCol(0)
    }

    private func moveToLineEnd() {
        lastAction = nil
        setCursorCol(state.lines[state.cursorLine].count)
    }

    private func moveWordBackwards() {
        lastAction = nil
        let currentLine = state.lines[state.cursorLine]
        if state.cursorCol == 0 {
            if state.cursorLine > 0 {
                state.cursorLine -= 1
                setCursorCol(state.lines[state.cursorLine].count)
            }
            return
        }
        setCursorCol(findWordBackward(currentLine, state.cursorCol, markers: markerRanges(currentLine)))
    }

    private func moveWordForwards() {
        lastAction = nil
        let currentLine = state.lines[state.cursorLine]
        if state.cursorCol >= currentLine.count {
            if state.cursorLine < state.lines.count - 1 {
                state.cursorLine += 1
                setCursorCol(0)
            }
            return
        }
        setCursorCol(findWordForward(currentLine, state.cursorCol, markers: markerRanges(currentLine)))
    }

    private struct VisualLine {
        var logicalLine: Int
        var startCol: Int
        var length: Int
    }

    private func buildVisualLineMap(_ width: Int) -> [VisualLine] {
        var visualLines: [VisualLine] = []
        for i in 0..<state.lines.count {
            let line = state.lines[i]
            let lineVisWidth = visibleWidth(String(line))
            if line.isEmpty {
                visualLines.append(VisualLine(logicalLine: i, startCol: 0, length: 0))
            } else if lineVisWidth <= width {
                visualLines.append(VisualLine(logicalLine: i, startCol: 0, length: line.count))
            } else {
                let chunks = wordWrapLine(line, width, markerRanges(line))
                for chunk in chunks {
                    visualLines.append(VisualLine(logicalLine: i, startCol: chunk.startIndex, length: chunk.endIndex - chunk.startIndex))
                }
            }
        }
        return visualLines
    }

    private func findVisualLineAt(_ visualLines: [VisualLine], _ line: Int, _ col: Int) -> Int {
        for i in 0..<visualLines.count {
            let vl = visualLines[i]
            if vl.logicalLine != line { continue }
            let offset = col - vl.startCol
            let isLastSegmentOfLine = i == visualLines.count - 1 || visualLines[i + 1].logicalLine != vl.logicalLine
            if offset >= 0, offset < vl.length || (isLastSegmentOfLine && offset == vl.length) {
                return i
            }
        }
        return visualLines.count - 1
    }

    private func findCurrentVisualLine(_ visualLines: [VisualLine]) -> Int {
        findVisualLineAt(visualLines, state.cursorLine, state.cursorCol)
    }

    private func isOnFirstVisualLine() -> Bool {
        let vls = buildVisualLineMap(lastWidth)
        return findCurrentVisualLine(vls) == 0
    }

    private func isOnLastVisualLine() -> Bool {
        let vls = buildVisualLineMap(lastWidth)
        return findCurrentVisualLine(vls) == vls.count - 1
    }

    private func moveCursor(deltaLine: Int, deltaCol: Int) {
        lastAction = nil
        let visualLines = buildVisualLineMap(lastWidth)
        let currentVisualLine = findCurrentVisualLine(visualLines)

        if deltaLine != 0 {
            let targetVisualLine = currentVisualLine + deltaLine
            if targetVisualLine >= 0, targetVisualLine < visualLines.count {
                moveToVisualLine(visualLines, currentVisualLine, targetVisualLine)
            }
        }

        if deltaCol != 0 {
            let currentLine = state.lines[state.cursorLine]
            if deltaCol > 0 {
                if state.cursorCol < currentLine.count {
                    let markers = markerRanges(currentLine)
                    if let m = markers.first(where: { $0.lowerBound == state.cursorCol }) {
                        setCursorCol(m.upperBound)
                    } else {
                        setCursorCol(state.cursorCol + 1)
                    }
                } else if state.cursorLine < state.lines.count - 1 {
                    state.cursorLine += 1
                    setCursorCol(0)
                } else {
                    let currentVL = visualLines[currentVisualLine]
                    preferredVisualCol = state.cursorCol - currentVL.startCol
                }
            } else {
                if state.cursorCol > 0 {
                    let markers = markerRanges(currentLine)
                    if let m = markers.first(where: { $0.upperBound == state.cursorCol }) {
                        setCursorCol(m.lowerBound)
                    } else {
                        setCursorCol(state.cursorCol - 1)
                    }
                } else if state.cursorLine > 0 {
                    state.cursorLine -= 1
                    setCursorCol(state.lines[state.cursorLine].count)
                }
            }
        }
    }

    private func pageScroll(_ direction: Int) {
        lastAction = nil
        let terminalRows = rows()
        let pageSize = max(5, Int(Double(terminalRows) * 0.3))
        let visualLines = buildVisualLineMap(lastWidth)
        let currentVisualLine = findCurrentVisualLine(visualLines)
        let targetVisualLine = max(0, min(visualLines.count - 1, currentVisualLine + direction * pageSize))
        moveToVisualLine(visualLines, currentVisualLine, targetVisualLine)
    }

    /// Move the cursor to a target visual line, applying sticky-column logic and
    /// snapping to atomic-segment boundaries. Ported from pi's `moveToVisualLine`.
    private func moveToVisualLine(_ visualLines: [VisualLine], _ currentVisualLine: Int, _ targetVisualLine: Int) {
        guard currentVisualLine >= 0, currentVisualLine < visualLines.count,
              targetVisualLine >= 0, targetVisualLine < visualLines.count else { return }
        let currentVL = visualLines[currentVisualLine]
        let targetVL = visualLines[targetVisualLine]

        let currentVisualCol: Int
        if let snapped = snappedFromCursorCol {
            let vlIndex = findVisualLineAt(visualLines, currentVL.logicalLine, snapped)
            currentVisualCol = snapped - visualLines[vlIndex].startCol
        } else {
            currentVisualCol = state.cursorCol - currentVL.startCol
        }

        let isLastSourceSegment = currentVisualLine == visualLines.count - 1
            || visualLines[currentVisualLine + 1].logicalLine != currentVL.logicalLine
        let sourceMaxVisualCol = isLastSourceSegment ? currentVL.length : max(0, currentVL.length - 1)

        let isLastTargetSegment = targetVisualLine == visualLines.count - 1
            || visualLines[targetVisualLine + 1].logicalLine != targetVL.logicalLine
        let targetMaxVisualCol = isLastTargetSegment ? targetVL.length : max(0, targetVL.length - 1)

        let moveToVisualCol = computeVerticalMoveColumn(currentVisualCol, sourceMaxVisualCol, targetMaxVisualCol)

        state.cursorLine = targetVL.logicalLine
        let targetCol = targetVL.startCol + moveToVisualCol
        let logicalLine = state.lines[targetVL.logicalLine]
        state.cursorCol = min(targetCol, logicalLine.count)

        // Snap to atomic-segment boundaries (paste markers).
        let segments = graphemeSegments(logicalLine, markerRanges(logicalLine))
        for seg in segments {
            if seg.start > state.cursorCol { break }
            if seg.length <= 1 { continue }
            if state.cursorCol < seg.start + seg.length {
                let isContinuation = seg.start < targetVL.startCol
                let isMovingDown = targetVisualLine > currentVisualLine
                if isContinuation, isMovingDown {
                    let segEnd = seg.start + seg.length
                    var next = targetVisualLine + 1
                    while next < visualLines.count,
                          visualLines[next].logicalLine == targetVL.logicalLine,
                          visualLines[next].startCol < segEnd {
                        next += 1
                    }
                    if next < visualLines.count {
                        moveToVisualLine(visualLines, currentVisualLine, next)
                        return
                    }
                }
                snappedFromCursorCol = state.cursorCol
                state.cursorCol = seg.start
                return
            }
        }
        snappedFromCursorCol = nil
    }

    /// Compute the target visual column for vertical movement — pi's documented
    /// sticky-column decision table (see editor.ts `computeVerticalMoveColumn`).
    private func computeVerticalMoveColumn(_ currentVisualCol: Int, _ sourceMaxVisualCol: Int, _ targetMaxVisualCol: Int) -> Int {
        let hasPreferred = preferredVisualCol != nil
        let cursorInMiddle = currentVisualCol < sourceMaxVisualCol
        let targetTooShort = targetMaxVisualCol < currentVisualCol

        if !hasPreferred || cursorInMiddle {
            if targetTooShort {
                preferredVisualCol = currentVisualCol
                return targetMaxVisualCol
            }
            preferredVisualCol = nil
            return currentVisualCol
        }

        let preferred = preferredVisualCol!
        let targetCantFitPreferred = targetMaxVisualCol < preferred
        if targetTooShort || targetCantFitPreferred {
            return targetMaxVisualCol
        }
        preferredVisualCol = nil
        return preferred
    }

    // MARK: History

    private func exitHistoryBrowsing() {
        historyIndex = -1
        historyDraft = nil
    }

    private func navigateHistory(_ direction: Int) {
        lastAction = nil
        if history.isEmpty { return }
        let newIndex = historyIndex - direction
        if newIndex < -1 || newIndex >= history.count { return }

        if historyIndex == -1, newIndex >= 0 {
            pushUndoSnapshot()
            historyDraft = state
        }

        historyIndex = newIndex

        if historyIndex == -1 {
            let draft = historyDraft
            historyDraft = nil
            if let draft {
                state = draft
                preferredVisualCol = nil
                snappedFromCursorCol = nil
                scrollOffset = 0
                onChange?(getText())
            } else {
                setTextInternal("")
            }
        } else {
            setTextInternal(history[historyIndex], placement: direction == -1 ? .start : .end)
        }
    }

    // MARK: Kill ring

    private func yank() {
        guard let text = killRing.peek(), !text.isEmpty else { return }
        pushUndoSnapshot()
        insertYankedText(text)
        lastAction = .yank
    }

    private func yankPop() {
        guard lastAction == .yank, killRing.count > 1 else { return }
        pushUndoSnapshot()
        deleteYankedText()
        killRing.rotate()
        let text = killRing.peek() ?? ""
        insertYankedText(text)
        lastAction = .yank
    }

    private func insertYankedText(_ text: String) {
        exitHistoryBrowsing()
        let lines = text.components(separatedBy: "\n").map { Array($0) }
        let currentLine = state.lines[state.cursorLine]
        let before = Array(currentLine[0..<state.cursorCol])
        let after = Array(currentLine[state.cursorCol...])

        if lines.count == 1 {
            state.lines[state.cursorLine] = before + lines[0] + after
            setCursorCol(state.cursorCol + lines[0].count)
        } else {
            state.lines[state.cursorLine] = before + lines[0]
            for i in 1..<(lines.count - 1) {
                state.lines.insert(lines[i], at: state.cursorLine + i)
            }
            let lastLineIndex = state.cursorLine + lines.count - 1
            state.lines.insert(lines[lines.count - 1] + after, at: lastLineIndex)
            state.cursorLine = lastLineIndex
            setCursorCol(lines[lines.count - 1].count)
        }
        onChange?(getText())
    }

    private func deleteYankedText() {
        guard let yankedText = killRing.peek() else { return }
        let yankLines = yankedText.components(separatedBy: "\n").map { Array($0) }

        if yankLines.count == 1 {
            let currentLine = state.lines[state.cursorLine]
            let deleteLen = yankLines[0].count
            let before = Array(currentLine[0..<(state.cursorCol - deleteLen)])
            let after = Array(currentLine[state.cursorCol...])
            state.lines[state.cursorLine] = before + after
            setCursorCol(state.cursorCol - deleteLen)
        } else {
            let startLine = state.cursorLine - (yankLines.count - 1)
            let startCol = state.lines[startLine].count - yankLines[0].count
            let afterCursor = Array(state.lines[state.cursorLine][state.cursorCol...])
            let beforeYank = Array(state.lines[startLine][0..<startCol])
            state.lines.removeSubrange(startLine...state.cursorLine)
            state.lines.insert(beforeYank + afterCursor, at: startLine)
            state.cursorLine = startLine
            setCursorCol(startCol)
        }
        onChange?(getText())
    }

    // MARK: Undo

    private func pushUndoSnapshot() {
        undoStack.push(EditorSnapshot(state: state, pastes: pastes, pasteCounter: pasteCounter))
    }

    private func undo() {
        exitHistoryBrowsing()
        guard let snapshot = undoStack.pop() else { return }
        state = snapshot.state
        pastes = snapshot.pastes
        pasteCounter = snapshot.pasteCounter
        lastAction = nil
        preferredVisualCol = nil
        onChange?(getText())
    }

    // MARK: Character jump

    private func jumpToChar(_ char: Character, _ direction: JumpMode) {
        lastAction = nil
        let isForward = direction == .forward
        let lineCount = state.lines.count
        var lineIdx = state.cursorLine

        while lineIdx >= 0, lineIdx < lineCount {
            let line = state.lines[lineIdx]
            let isCurrentLine = lineIdx == state.cursorLine
            var found: Int?
            if isForward {
                let start = isCurrentLine ? state.cursorCol + 1 : 0
                if start <= line.count {
                    var k = start
                    while k < line.count { if line[k] == char { found = k; break }; k += 1 }
                }
            } else {
                let start = isCurrentLine ? state.cursorCol - 1 : line.count - 1
                var k = min(start, line.count - 1)
                while k >= 0 { if line[k] == char { found = k; break }; k -= 1 }
            }
            if let found {
                state.cursorLine = lineIdx
                setCursorCol(found)
                return
            }
            lineIdx += isForward ? 1 : -1
        }
    }

    // MARK: Paste marker expansion

    private func expandPasteMarkers(_ text: String) -> String {
        if pastes.isEmpty { return text }
        let chars = Array(text)
        let matches = findMarkers(chars, validIds: validPasteIds())
        if matches.isEmpty { return text }
        var result = ""
        var pos = 0
        for m in matches {
            result += String(chars[pos..<m.range.lowerBound])
            result += pastes[m.id] ?? String(chars[m.range])
            pos = m.range.upperBound
        }
        result += String(chars[pos...])
        return result
    }

    // MARK: CSI-u control decode

    private func decodeCSIuControls(_ text: String) -> String {
        guard text.contains("\u{1b}[") else { return text }
        var result = ""
        let chars = Array(text)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == "\u{1b}", i + 1 < n, chars[i + 1] == "[" {
                var j = i + 2
                var digits = ""
                while j < n, isASCIIDigit(chars[j]) { digits.append(chars[j]); j += 1 }
                if !digits.isEmpty, j + 1 < n, chars[j] == ";", chars[j + 1] == "5", j + 2 < n, chars[j + 2] == "u",
                   let cp = Int(digits) {
                    if cp >= 97, cp <= 122 {
                        result.append(Character(UnicodeScalar(UInt8(cp - 96))))
                        i = j + 3
                        continue
                    } else if cp >= 65, cp <= 90 {
                        result.append(Character(UnicodeScalar(UInt8(cp - 64))))
                        i = j + 3
                        continue
                    }
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }
}

// MARK: - Local helpers

private nonisolated func isWhitespaceString(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { isWhitespaceCluster($0) }
}

private nonisolated func hasControlScalars(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if v < 32 || v == 0x7f || (v >= 0x80 && v <= 0x9f) { return true }
    }
    return false
}

private extension String {
    /// Trim leading/trailing whitespace, matching JS `String.prototype.trim`
    /// closely enough for prompt-history and submit normalization.
    func trimmingCharactersInWhitespace() -> String {
        var chars = Array(self)
        while let first = chars.first, isWhitespaceCluster(first) { chars.removeFirst() }
        while let last = chars.last, isWhitespaceCluster(last) { chars.removeLast() }
        return String(chars)
    }
}
