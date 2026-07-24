// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/input.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The editing surface — insertion,
// grapheme-wise cursor motion, backspace/forward-delete, home/end, kill-to-line,
// word delete, the kill ring, undo, bracketed paste — and the horizontal-scroll
// render with its inverse-video fake cursor are ported. Two deliberate
// divergences are documented inline:
//   * The value is modeled as an array of grapheme clusters (Swift `Character`)
//     with an integer cursor, replacing pi's UTF-16 code-unit offsets — a
//     `Character` already *is* an extended grapheme cluster, so grapheme motion
//     is index arithmetic and cannot split a cluster.
//   * Word navigation is a Swift-native character-class scan rather than a port
//     of pi's `Intl.Segmenter`-based `word-navigation.ts` (not ported; the
//     stdlib exposes no word segmenter). It matches the common emacs behaviour —
//     skip whitespace, then one run of word chars or one run of punctuation.

import DoMoTermIO

// MARK: - Kill ring

/// A ring buffer for emacs-style kill/yank. Ported from pi's `KillRing`.
///
/// A value type: the input owns exactly one and never shares it, so there is no
/// reason for reference semantics.
struct KillRing {
    private var ring: [String] = []

    /// Add killed text. When `accumulate` is set and the ring is non-empty, merge
    /// with the most recent entry — `prepend` for a backward deletion (the new
    /// text precedes what was already there), append for a forward deletion.
    mutating func push(_ text: String, prepend: Bool, accumulate: Bool) {
        guard !text.isEmpty else { return }
        if accumulate, let last = ring.popLast() {
            ring.append(prepend ? text + last : last + text)
        } else {
            ring.append(text)
        }
    }

    /// The most recent entry without modifying the ring.
    func peek() -> String? { ring.last }

    /// Move the last entry to the front, for yank-pop cycling.
    mutating func rotate() {
        guard ring.count > 1, let last = ring.popLast() else { return }
        ring.insert(last, at: 0)
    }

    var count: Int { ring.count }
}

// MARK: - Input

/// A single-line text editor with horizontal scrolling.
///
/// Focusable: when focused it emits ``cursorMarker`` at the caret so the renderer
/// can park the hardware cursor there (for IME), and it draws its own inverse-
/// video block cursor. The value scrolls horizontally to keep the caret in view
/// once the text outgrows the width, and the rendered line is always padded to
/// exactly `width` columns — never over-wide.
///
/// This is the single-line input only. The multi-line editor is a separate,
/// later component and is deliberately not built here.
public final class Input: Component, Focusable {
    /// The value as grapheme clusters; the cursor is an index into it.
    private var clusters: [Character] = []
    private var cursor = 0

    /// Fired on submit (Enter) with the current value.
    public var onSubmit: ((String) -> Void)?
    /// Fired on escape/cancel.
    public var onEscape: (() -> Void)?

    /// Set by the renderer when focus changes.
    public var focused = false

    private let keybindings: Keybindings

    // Bracketed-paste buffering.
    private var pasteBuffer = ""
    private var isInPaste = false

    // Kill ring + undo.
    private var killRing = KillRing()
    private var lastAction: LastAction?
    private var undoStack: [(clusters: [Character], cursor: Int)] = []

    private enum LastAction { case kill, yank, typeWord }

    private static let pasteStart = "\u{1b}[200~"
    private static let pasteEnd = "\u{1b}[201~"

    public init(keybindings: Keybindings = Keybindings()) {
        self.keybindings = keybindings
    }

    // MARK: Value access

    public func getValue() -> String { String(clusters) }

    public func setValue(_ value: String) {
        clusters = Array(value)
        cursor = min(cursor, clusters.count)
    }

    /// The caret position as a grapheme-cluster index (0...count). Exposed for
    /// tests.
    public var cursorIndex: Int { cursor }

    // MARK: Input dispatch

    public func handleInput(_ data: [UInt8]) {
        let text = String(decoding: data, as: UTF8.self)

        // Bracketed paste: buffer everything between the start and end markers.
        var incoming = text
        if incoming.contains(Input.pasteStart) {
            isInPaste = true
            pasteBuffer = ""
            incoming = incoming.replacingOccurrences(of: Input.pasteStart, with: "")
        }
        if isInPaste {
            pasteBuffer += incoming
            if let endRange = pasteBuffer.range(of: Input.pasteEnd) {
                let pasteContent = String(pasteBuffer[pasteBuffer.startIndex..<endRange.lowerBound])
                handlePaste(pasteContent)
                isInPaste = false
                let remaining = String(pasteBuffer[endRange.upperBound...])
                pasteBuffer = ""
                if !remaining.isEmpty {
                    handleInput(Array(remaining.utf8))
                }
            }
            return
        }

        let kb = keybindings

        if kb.matches(data, .selectCancel) { onEscape?(); return }
        if kb.matches(data, .editorUndo) { undo(); return }
        if kb.matches(data, .inputSubmit) || data == [0x0a] { onSubmit?(getValue()); return }

        if kb.matches(data, .editorDeleteCharBackward) { handleBackspace(); return }
        if kb.matches(data, .editorDeleteCharForward) { handleForwardDelete(); return }
        if kb.matches(data, .editorDeleteWordBackward) { deleteWordBackwards(); return }
        if kb.matches(data, .editorDeleteWordForward) { deleteWordForward(); return }
        if kb.matches(data, .editorDeleteToLineStart) { deleteToLineStart(); return }
        if kb.matches(data, .editorDeleteToLineEnd) { deleteToLineEnd(); return }

        if kb.matches(data, .editorYank) { yank(); return }
        if kb.matches(data, .editorYankPop) { yankPop(); return }

        if kb.matches(data, .editorCursorLeft) {
            lastAction = nil
            if cursor > 0 { cursor -= 1 }
            return
        }
        if kb.matches(data, .editorCursorRight) {
            lastAction = nil
            if cursor < clusters.count { cursor += 1 }
            return
        }
        if kb.matches(data, .editorCursorLineStart) { lastAction = nil; cursor = 0; return }
        if kb.matches(data, .editorCursorLineEnd) { lastAction = nil; cursor = clusters.count; return }
        if kb.matches(data, .editorCursorWordLeft) { moveWordBackwards(); return }
        if kb.matches(data, .editorCursorWordRight) { moveWordForwards(); return }

        // Printable input. A Kitty/modifyOtherKeys printable decodes to its text;
        // otherwise treat the raw bytes as text unless they carry control chars
        // (C0, DEL, C1) — which is how escape sequences for unhandled keys are
        // rejected rather than inserted.
        if let printable = decodePrintableKey(data) {
            insertCharacter(printable)
            return
        }
        if !hasControlChars(text) {
            insertCharacter(text)
        }
    }

    // MARK: Editing

    private func insertCharacter(_ char: String) {
        let chars = Array(char)
        guard !chars.isEmpty else { return }
        // Undo coalescing: consecutive word characters fold into one undo unit.
        if isWhitespaceString(char) || lastAction != .typeWord {
            pushUndo()
        }
        lastAction = .typeWord
        clusters.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
    }

    private func handleBackspace() {
        lastAction = nil
        guard cursor > 0 else { return }
        pushUndo()
        clusters.remove(at: cursor - 1)
        cursor -= 1
    }

    private func handleForwardDelete() {
        lastAction = nil
        guard cursor < clusters.count else { return }
        pushUndo()
        clusters.remove(at: cursor)
    }

    private func deleteToLineStart() {
        guard cursor > 0 else { return }
        pushUndo()
        let deleted = String(clusters[0..<cursor])
        killRing.push(deleted, prepend: true, accumulate: lastAction == .kill)
        lastAction = .kill
        clusters.removeSubrange(0..<cursor)
        cursor = 0
    }

    private func deleteToLineEnd() {
        guard cursor < clusters.count else { return }
        pushUndo()
        let deleted = String(clusters[cursor...])
        killRing.push(deleted, prepend: false, accumulate: lastAction == .kill)
        lastAction = .kill
        clusters.removeSubrange(cursor...)
    }

    private func deleteWordBackwards() {
        guard cursor > 0 else { return }
        let wasKill = lastAction == .kill
        pushUndo()
        let oldCursor = cursor
        let deleteFrom = wordBoundaryBackward(from: cursor)
        let deleted = String(clusters[deleteFrom..<oldCursor])
        killRing.push(deleted, prepend: true, accumulate: wasKill)
        lastAction = .kill
        clusters.removeSubrange(deleteFrom..<oldCursor)
        cursor = deleteFrom
    }

    private func deleteWordForward() {
        guard cursor < clusters.count else { return }
        let wasKill = lastAction == .kill
        pushUndo()
        let deleteTo = wordBoundaryForward(from: cursor)
        let deleted = String(clusters[cursor..<deleteTo])
        killRing.push(deleted, prepend: false, accumulate: wasKill)
        lastAction = .kill
        clusters.removeSubrange(cursor..<deleteTo)
    }

    private func yank() {
        guard let text = killRing.peek(), !text.isEmpty else { return }
        pushUndo()
        let chars = Array(text)
        clusters.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
        lastAction = .yank
    }

    private func yankPop() {
        guard lastAction == .yank, killRing.count > 1 else { return }
        pushUndo()
        let prevText = killRing.peek() ?? ""
        let prevLen = Array(prevText).count
        if prevLen > 0, cursor >= prevLen {
            clusters.removeSubrange((cursor - prevLen)..<cursor)
            cursor -= prevLen
        }
        killRing.rotate()
        let text = killRing.peek() ?? ""
        let chars = Array(text)
        clusters.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
        lastAction = .yank
    }

    private func moveWordBackwards() {
        guard cursor > 0 else { return }
        lastAction = nil
        cursor = wordBoundaryBackward(from: cursor)
    }

    private func moveWordForwards() {
        guard cursor < clusters.count else { return }
        lastAction = nil
        cursor = wordBoundaryForward(from: cursor)
    }

    private func handlePaste(_ pastedText: String) {
        lastAction = nil
        pushUndo()
        // Strip line breaks; expand tabs to four spaces, as pi does.
        var clean = pastedText
        clean = clean.replacingOccurrences(of: "\r\n", with: "")
        clean = clean.replacingOccurrences(of: "\r", with: "")
        clean = clean.replacingOccurrences(of: "\n", with: "")
        clean = clean.replacingOccurrences(of: "\t", with: "    ")
        let chars = Array(clean)
        clusters.insert(contentsOf: chars, at: cursor)
        cursor += chars.count
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append((clusters, cursor))
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        clusters = snapshot.clusters
        cursor = snapshot.cursor
        lastAction = nil
    }

    // MARK: Word boundaries (Swift-native, not pi's Intl.Segmenter port)

    private func wordBoundaryBackward(from index: Int) -> Int {
        var i = index
        // Skip trailing whitespace.
        while i > 0, isSpaceCluster(clusters[i - 1]) { i -= 1 }
        guard i > 0 else { return i }
        if isWordCluster(clusters[i - 1]) {
            while i > 0, isWordCluster(clusters[i - 1]) { i -= 1 }
        } else {
            while i > 0, !isWordCluster(clusters[i - 1]), !isSpaceCluster(clusters[i - 1]) { i -= 1 }
        }
        return i
    }

    private func wordBoundaryForward(from index: Int) -> Int {
        let n = clusters.count
        var i = index
        while i < n, isSpaceCluster(clusters[i]) { i += 1 }
        guard i < n else { return i }
        if isWordCluster(clusters[i]) {
            while i < n, isWordCluster(clusters[i]) { i += 1 }
        } else {
            while i < n, !isWordCluster(clusters[i]), !isSpaceCluster(clusters[i]) { i += 1 }
        }
        return i
    }

    // MARK: Rendering

    public func render(width: Int) -> [String] {
        let prompt = "> "
        let promptWidth = 2
        let availableWidth = width - promptWidth
        guard availableWidth > 0 else { return [prompt] }

        let value = clusters
        let totalWidth = visibleWidth(String(value))
        let cursorCol = visibleWidth(String(value[0..<cursor]))

        var visibleText: String
        var visibleCursorCol: Int

        if totalWidth < availableWidth {
            // Everything fits (with a column to spare for a caret at the end).
            visibleText = String(value)
            visibleCursorCol = cursorCol
        } else {
            // Horizontal scroll. Reserve one column for the caret when at the end.
            let scrollWidth = cursor == value.count ? availableWidth - 1 : availableWidth
            if scrollWidth > 0 {
                let halfWidth = scrollWidth / 2
                let startCol: Int
                if cursorCol < halfWidth {
                    startCol = 0
                } else if cursorCol > totalWidth - halfWidth {
                    startCol = max(0, totalWidth - scrollWidth)
                } else {
                    startCol = max(0, cursorCol - halfWidth)
                }
                visibleText = sliceByColumn(String(value), from: startCol, to: startCol + scrollWidth, strict: true)
                visibleCursorCol = cursorCol - startCol
            } else {
                visibleText = ""
                visibleCursorCol = 0
            }
        }

        // Split the visible text at the caret column into before / at / after.
        let split = splitAtColumn(visibleText, column: visibleCursorCol)
        let marker = focused ? cursorMarker : ""
        let cursorChar = "\u{1b}[7m\(split.at)\u{1b}[27m" // reverse video on/off
        let textWithCursor = split.before + marker + cursorChar + split.after

        let visualLength = visibleWidth(textWithCursor)
        let padding = String(repeating: " ", count: max(0, availableWidth - visualLength))
        return [prompt + textWithCursor + padding]
    }

    /// Split `text` at visible `column` into the text before, the single cluster
    /// at the caret (a space when the caret is past the end), and the text after.
    private func splitAtColumn(_ text: String, column: Int) -> (before: String, at: String, after: String) {
        var before = ""
        var width = 0
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let w = graphemeWidth(chars[index])
            if width >= column { break }
            before.append(chars[index])
            width += w
            index += 1
        }
        if index < chars.count {
            let at = String(chars[index])
            let after = String(chars[(index + 1)...])
            return (before, at, after)
        }
        // Caret is at or past the end: draw a space under it.
        return (before, " ", "")
    }
}

// MARK: - Character classification

private func isSpaceCluster(_ c: Character) -> Bool {
    c == " " || c == "\t" || c.isWhitespace
}

private func isWordCluster(_ c: Character) -> Bool {
    c == "_" || c.isLetter || c.isNumber
}

private func isWhitespaceString(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { isSpaceCluster($0) }
}

/// Whether `text` contains a control character (C0, DEL, or C1) — the set pi
/// rejects before inserting raw input as text.
private func hasControlChars(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
        let v = scalar.value
        if v < 32 || v == 0x7f || (v >= 0x80 && v <= 0x9f) { return true }
    }
    return false
}
