// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The prompt: a multi-line, vertically growing input, built as a façade over
// DoMoTUI's `Editor` rather than as a second editor.
//
// What it replaced was an 82-line single-line box that appended printable scalars
// and rendered the TAIL of the text through `sliceByColumn` — so a prompt longer
// than the pane scrolled sideways, the beginning of what you were writing was
// simply gone, and a pasted newline was silently deleted along with every other
// control character. Everything needed to fix that already existed and was already
// shipping in the inline REPL: word wrap with a logical↔visual map, internal
// scrolling that keeps the caret on screen, sticky-column vertical movement,
// bracketed-paste buffering that INSERTS newlines and never submits, and a prompt
// history whose up/down semantics are exactly the ones asked for. Writing a second
// one would have re-derived ~700 lines of wrap and cursor arithmetic the project
// deliberately ported once.
//
// Composition, not subclassing: `Editor` is `final`. The façade adds only what the
// full-screen client needs on top — a height contract for a layout slot that has
// to leave the transcript its last row, a placeholder, attachment chips, and a
// persistence hook for history.

import DoMoTUI
import DoMoTermIO

/// The full-screen client's prompt input.
@MainActor
final class PromptInput: @MainActor Focusable {
    private let editor: Editor
    private let keybindings: Keybindings

    var focused = false {
        didSet { editor.focused = focused }
    }

    var wantsKeyRelease: Bool { false }

    /// Called with the submitted prompt and the attachments staged with it.
    ///
    /// Never called with an empty prompt AND no attachments — a bare Enter on an
    /// empty box is not a message.
    var onSubmit: ((String, [PromptAttachment]) -> Void)?

    /// Called with each accepted history entry, for persistence.
    ///
    /// Fires AFTER the in-memory add, so a consecutive duplicate still reaches the
    /// store; the store dedups too and is the single source of truth on disk.
    var onHistoryAdd: ((String) -> Void)?

    /// Fired when a pasted segment parses as dropped paths.
    ///
    /// The app owns the filesystem: it resolves the candidates off the main actor
    /// and answers with ``resolveDrop(token:outcome:)``. Keeping the IO out here is
    /// what lets the prompt stay a pure UI component with no filesystem seam of its
    /// own, and it is why the hook is a token-and-callback rather than a return
    /// value — the answer cannot be synchronous.
    var onDrop: ((_ token: UInt32, _ candidates: [[String]]) -> Void)?

    private(set) var attachments: [PromptAttachment] = []

    /// Drops handed to the app and not yet answered. A resolution for anything not
    /// in here is stale (the prompt was cleared, or the same token answered twice)
    /// and is dropped rather than applied to a document that has moved on.
    private var pendingDrops: Set<UInt32> = []
    private var dropCounter: UInt32 = 0

    private static let placeholder =
        "Type a message — Enter to send, Alt+↵ or ^J for a newline, ↑/↓ for history, Tab to switch pane"

    init(keybindings: Keybindings = Keybindings(), terminalRows: @escaping () -> Int = { 24 }) {
        self.keybindings = keybindings
        self.editor = Editor(keybindings: keybindings, paddingX: 0, rows: terminalRows)
        self.editor.onSubmit = { [weak self] text in self?.handleSubmit(text) }
        // The paste hook has to live on the EDITOR, not on this façade: a bracketed
        // paste is buffered across `handleInput` calls until its terminator arrives,
        // so anything sniffing raw bytes one frame at a time would miss a paste the
        // driver split in two. Returning `false` is byte-for-byte today's behaviour.
        self.editor.onPaste = { [weak self] pasted in self?.handlePastedText(pasted) ?? false }
    }

    // MARK: Text

    /// The document as the user sees it — paste markers UNEXPANDED.
    ///
    /// `Editor` folds a large paste into a single `[paste #1 +40 lines]` marker and
    /// expands it again on submit, so this is the display text, not the payload.
    var text: String { editor.getText() }

    func clear() {
        editor.setText("")
        attachments = []
        pendingDrops = []
    }

    /// Put a submitted message, and anything staged with it, back after a refused
    /// send.
    ///
    /// The editor clears itself BEFORE `onSubmit` runs, so the typed string survives
    /// only as the callback argument and a refusal would otherwise destroy it.
    ///
    /// Restoring APPENDS at the caret rather than prepending through `setText`: a
    /// failure can arrive asynchronously, by which time the user may already be
    /// typing the next thing, and `setText` clears the paste registry — which would
    /// turn a live `[paste #1 …]` marker in the half-typed replacement into dead
    /// literal text. The restored string is the EXPANDED text, so nothing is lost.
    func restore(_ restored: String, attachments restoredAttachments: [PromptAttachment] = []) {
        for attachment in restoredAttachments { addAttachment(attachment) }
        guard !restored.isEmpty else { return }
        if editor.getText().isEmpty {
            editor.setText(restored)
        } else {
            editor.insertTextAtCursor(" " + restored)
        }
    }

    // MARK: History

    /// Seed the editor's history from disk.
    ///
    /// `entries` must be OLDEST FIRST. `Editor.addToHistory` inserts at index 0 and
    /// dedups against the newest entry, so replaying in that order reproduces the
    /// on-disk order exactly and needs no new editor API.
    func seedHistory(_ entries: [String]) {
        for entry in entries { editor.addToHistory(entry) }
    }

    // MARK: Attachments

    func addAttachment(_ attachment: PromptAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id || $0.path == attachment.path })
        else { return }
        attachments.append(attachment)
    }

    func removeAttachment(id: UInt32) {
        attachments.removeAll { $0.id == id }
    }

    func clearAttachments() { attachments = [] }

    /// How a resolved drop came back from the app.
    enum DropOutcome {
        case attached([PromptAttachment])
        /// The paste was not (or not entirely) a droppable file. `rawText` is
        /// inserted at the caret VERBATIM — the "never silently eat a path the user
        /// meant as text" guarantee. `notice` is the app's to display; the prompt
        /// has no status line of its own.
        case rejected(rawText: String, notice: String)
    }

    /// Mint a token for a drop about to be handed to the app.
    ///
    /// Kept separate from `onDrop` so the caller decides whether the paste is a drop
    /// at all — the parse needs a path grammar this component deliberately does not
    /// own.
    func beginDrop() -> UInt32 {
        dropCounter &+= 1
        pendingDrops.insert(dropCounter)
        return dropCounter
    }

    /// Apply the app's answer to a drop.
    func resolveDrop(token: UInt32, outcome: DropOutcome) {
        guard pendingDrops.remove(token) != nil else { return }
        switch outcome {
        case .attached(let resolved):
            for attachment in resolved { addAttachment(attachment) }
        case .rejected(let rawText, _):
            guard !rawText.isEmpty else { return }
            editor.insertTextAtCursor(rawText)
        }
    }

    /// One chip per row.
    ///
    /// The SINGLE height and rendering source for chips: `height(forWidth:maxRows:)`
    /// budgets exactly this many rows, so a chip can never push the caret off the
    /// bottom of the slot. One per row keeps that arithmetic exact and keeps a long
    /// filename readable.
    func chipRows(width: Int) -> [String] {
        guard width > 0, !attachments.isEmpty else { return [] }
        return attachments.map { attachment in
            // The name comes off the filesystem and can legally contain an escape
            // sequence, so it is untrusted text like any other.
            let label = sanitizeUntrustedText(attachment.name)
            let detail = Self.byteLabel(attachment.byteCount)
            return truncateToWidth(dim("📎 " + label + "  " + detail), width, ellipsis: "…")
        }
    }

    /// A chip's size label.
    ///
    /// Integer arithmetic rather than `String(format:)`, which is an unsafe
    /// construct under this package's strict memory safety and would have to be
    /// spelled `unsafe` for a cosmetic decimal point.
    private static func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1 << 20 {
            let tenths = (bytes * 10 + (1 << 19)) / (1 << 20)
            return "\(tenths / 10).\(tenths % 10) MB"
        }
        if bytes >= 1 << 10 { return "\(bytes / (1 << 10)) KB" }
        return "\(bytes) B"
    }

    // MARK: Height

    /// How many rows this input wants at `width`, never more than `maxRows`.
    ///
    /// MUTATES `editor.showBorders` / `editor.maxVisibleLines` so that the
    /// subsequent `render(width:)` produces EXACTLY this many rows. A caller must
    /// therefore call this before placing the node, at the width the node will
    /// actually be given — measuring at one width and painting at another wraps
    /// differently in the two passes, and the editor's own first/last-visual-line
    /// tests (which drive history recall) are computed against the last width it
    /// rendered at.
    func height(forWidth width: Int, maxRows: Int) -> Int {
        guard width > 0, maxRows > 0 else { return 1 }
        let chips = min(chipRows(width: width).count, max(0, maxRows - 1))
        let forEditor = max(1, maxRows - chips)
        // Borders cost two rows and carry the "↑ N more" scroll affordance. Shed
        // them rather than lose the only row that can show text.
        let bordered = forEditor >= 3
        editor.showBorders = bordered
        editor.maxVisibleLines = max(1, forEditor - (bordered ? 2 : 0))
        let editorRows = max(1, editor.render(width: width).count)
        return min(maxRows, chips + editorRows)
    }

    // MARK: Component

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines = chipRows(width: width)
        var editorLines = editor.render(width: width)
        // The placeholder stands in for the single text row only when there is
        // nothing to show and no caret hiding behind it.
        if editor.getText().isEmpty, !focused, attachments.isEmpty {
            let row = editor.showBorders ? 1 : 0
            if editorLines.indices.contains(row) {
                editorLines[row] = truncateToWidth(dim("❯ " + Self.placeholder), width, ellipsis: "")
            }
        }
        lines.append(contentsOf: editorLines)
        return lines
    }

    func handleInput(_ data: [UInt8]) {
        // Backspace on an empty document pops the newest chip before the keystroke
        // can reach the editor, where it would do nothing at all.
        if !attachments.isEmpty, editor.getText().isEmpty,
           keybindings.matches(data, .editorDeleteCharBackward) {
            attachments.removeLast()
            return
        }
        editor.handleInput(data)
    }

    func invalidate() { editor.invalidate() }

    // MARK: Paste

    /// Consulted with a WHOLE bracketed paste before the editor inserts it. Return
    /// `true` to swallow it.
    ///
    /// This is the one place drop decoding can correctly live, and it is deliberately
    /// empty for now. What goes here is: parse `pasted` into path candidates, and if
    /// there are any, `let token = beginDrop(); onDrop?(token, candidates); return
    /// true` — the app then reads the files off the main actor and answers through
    /// ``resolveDrop(token:outcome:)``. The path grammar is not this component's to
    /// own, which is why the parse is not inlined.
    ///
    /// Until then every paste is ordinary text: inserted with its newlines intact,
    /// and never a submit.
    private func handlePastedText(_ pasted: String) -> Bool {
        _ = pasted
        return false
    }

    // MARK: Submit

    private func handleSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = attachments
        guard !trimmed.isEmpty || !pending.isEmpty else { return }
        attachments = []
        pendingDrops = []
        if !trimmed.isEmpty {
            editor.addToHistory(trimmed)
            onHistoryAdd?(trimmed)
        }
        onSubmit?(trimmed, pending)
    }
}
