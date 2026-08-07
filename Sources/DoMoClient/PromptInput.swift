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

import DoMoCore
import DoMoTUI
import DoMoTermIO

/// The full-screen client's prompt input.
@MainActor
final class PromptInput: @MainActor Focusable {
    private let editor: Editor
    private let keybindings: Keybindings
    private var autocompleteTask: Task<Void, Never>?
    private var autocompleteProvider: AutocompleteProvider?
    private var autocompleteSuggestions: AutocompleteSuggestions?

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

    /// Fired when Enter was REFUSED because a drop is still being read.
    ///
    /// The prompt has no status line of its own, so the refusal would otherwise be
    /// a keypress that visibly does nothing — which is exactly how a user concludes
    /// the client has frozen and hammers the key.
    var onSubmitDeferredForDrop: (() -> Void)?

    /// Fired after an explicit Tab lookup. The client presents the returned
    /// suggestions as an overlay; keeping the provider and editor here means the
    /// same completion cursor arithmetic is used by every client surface.
    var onAutocomplete: ((AutocompleteSuggestions?) -> Void)?

    /// Fired by the image-paste keybinding. Clipboard IO belongs to the app/CLI
    /// boundary, so the prompt only exposes the synchronous gesture hook.
    var onPasteImage: (() -> Void)?

    private(set) var attachments: [PromptAttachment] = []

    /// Drops handed to the app and not yet answered, each holding the RAW pasted
    /// text it was made from. A resolution for anything not in here is stale (the
    /// prompt was cleared, or the same token answered twice) and is dropped
    /// rather than applied to a document that has moved on.
    ///
    /// The raw text is kept because it is the only copy: `handlePastedText`
    /// swallows the paste, so if the app decides the paths were not attachable
    /// after all, this is what has to go back into the document. The app asks for
    /// it with ``pendingDropText(for:)`` rather than being handed it through
    /// `onDrop`, so the hook stays the two-argument shape everything else is
    /// written against and the text has exactly one owner.
    private var pendingDrops: [UInt32: String] = [:]
    private var dropCounter: UInt32 = 0

    private static let placeholder =
        "Type a message — Enter to send, Shift+Enter or ^J for a newline, ↑/↓ for history, Tab to switch pane"

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

    func setText(_ text: String) { editor.setText(text) }

    /// Insert a palette entry — a slash command, a tool, an agent — over the token
    /// under the caret, leaving the caret ready for arguments.
    ///
    /// REPLACING the token rather than APPENDING to the draft is the whole fix.
    /// The palette is normally opened by typing `/`, so that `/` is still sitting
    /// in the document when the choice comes back; appending `"/" + name` to it
    /// produced `//read `, which is not a tool and fails at the parser. Splicing
    /// over the token makes all four spellings the same rule: a slash entry
    /// overwrites the `/` (`/read `, never `//read `), a bare entry — an agent —
    /// overwrites it too and so eats it (`explore `, never `/explore `), and from
    /// an empty draft each inserts exactly itself.
    ///
    /// The write goes through ``DoMoTUI/Editor/applyAutocomplete(_:)``, not
    /// `setText`. `setText` re-anchors the caret to the END of the document, which
    /// is wrong for an insertion the user made mid-sentence, and — as
    /// ``restore(_:attachments:)`` explains — it clears the paste registry, so it
    /// can only be fed `getExpandedText()`, unfolding a 40-line paste into the
    /// draft as a side effect of picking a command. (`applyAutocomplete` resets
    /// the registry too, so a marker already in the draft still goes literal; that
    /// is a DoMoTUI limitation rather than an argument for `setText`, which loses
    /// the caret on top of it.)
    ///
    /// - Parameter requiresSlash: whether this entry is invoked as `/name`. Tools
    ///   and commands are; agent names are typed bare.
    func insertCommand(_ name: String, requiresSlash: Bool) {
        // The name can arrive from an MCP server, which makes it foreign text like
        // any paste: an escape sequence inside a tool name would otherwise be
        // spliced into a live document and repainted verbatim. `sanitizedForInsertion`
        // deliberately KEEPS newlines, and a literal newline inside a line is an
        // invariant violation for `Editor` (which addresses its buffer as lines of
        // `Character`, joined by `\n` on the way out), so they are folded to spaces
        // here — visibly wrong for a name that was already malformed, rather than
        // silently welding two fragments into one plausible-looking command.
        let sanitized = Self.sanitizedForInsertion(name)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A catalog whose entry is spelled `"/read"` is the doubling bug arriving
        // from the other side: every caller hands over a bare name, but one that
        // does not must not get a second slash welded on.
        let bare = String(sanitized.drop { $0 == "/" })
        guard !bare.isEmpty else { return }

        let insertion = requiresSlash ? "/" + bare : bare
        let cursor = editor.getCursor()
        editor.applyAutocomplete(
            spliceTokenAtCursor(
                lines: editor.getLines(),
                cursorLine: cursor.line,
                cursorCol: cursor.col,
                insertion: insertion
            )
        )
        // An in-flight lookup was started against the pre-splice document; letting
        // it land would reopen the popup over text that has moved underneath it.
        dismissAutocomplete()
    }

    /// The tool-catalog spelling: a tool is always invoked as `/name`.
    func insertToolCommand(_ name: String) { insertCommand(name, requiresSlash: true) }

    func applyTheme(_ theme: Theme, appearance: ThemeAppearance, trueColor: Bool = true) {
        let palette = theme.palette(for: appearance)
        editor.borderColor = { value in
            let color = palette.accent.foreground(trueColor: trueColor)
            return color.isEmpty ? value : color + value + sgrReset
        }
    }

    func setAutocompleteProvider(_ provider: AutocompleteProvider?) {
        autocompleteTask?.cancel()
        autocompleteTask = nil
        autocompleteProvider = provider
        autocompleteSuggestions = nil
        onAutocomplete?(nil)
    }

    func applyAutocomplete(_ item: AutocompleteItem, prefix: String) {
        guard let provider = autocompleteProvider,
              let result = provider.applyCompletion(
                lines: editor.getLines(),
                cursorLine: editor.getCursor().line,
                cursorCol: editor.getCursor().col,
                item: item,
                prefix: prefix
              )
        else { return }
        editor.applyAutocomplete(result)
        autocompleteSuggestions = nil
        onAutocomplete?(nil)
    }

    func dismissAutocomplete() {
        autocompleteTask?.cancel()
        autocompleteTask = nil
        autocompleteSuggestions = nil
        onAutocomplete?(nil)
    }

    func clear() {
        dismissAutocomplete()
        editor.setText("")
        attachments = []
        pendingDrops = [:]
    }

    /// Put a submitted message, and anything staged with it, back after a refused
    /// send.
    ///
    /// The editor clears itself BEFORE `onSubmit` runs, so the typed string survives
    /// only as the callback argument and a refusal would otherwise destroy it.
    ///
    /// Restoring lands at the END of the document, on its own line — never at the
    /// caret. A failure can arrive asynchronously, by which time the user may
    /// already be typing the next thing, and the caret is by definition in the
    /// middle of it: splicing there produced `"abc the failed messagedef"` out of
    /// `"abcdef"` with the caret three back. A newline rather than a space keeps two
    /// messages legible when several refusals land in a row.
    ///
    /// The append goes through `setText` on the EXPANDED text, because `setText`
    /// clears the paste registry and a live `[paste #1 …]` marker left behind would
    /// become dead literal text. Expanding costs the fold — a big paste unfolds in
    /// the draft — but never loses or corrupts the payload, and it is the only
    /// end-anchored write `Editor` exposes.
    func restore(_ restored: String, attachments restoredAttachments: [PromptAttachment] = []) {
        for attachment in restoredAttachments { addAttachment(attachment) }
        guard !restored.isEmpty else { return }
        let existing = editor.getExpandedText()
        editor.setText(existing.isEmpty ? restored : existing + "\n" + restored)
    }

    // MARK: History

    /// Seed the editor's history from disk.
    ///
    /// `entries` must be OLDEST FIRST. `Editor.addToHistory` inserts at index 0 and
    /// dedups against the newest entry, so replaying in that order reproduces the
    /// on-disk order exactly and needs no new editor API.
    ///
    /// Sanitized here, not only in the store: an entry goes into a live terminal the
    /// moment Up recalls it, and `PromptHistoryStore.load()` being careful is a
    /// guarantee that lives in a different type from the one that depends on it.
    func seedHistory(_ entries: [String]) {
        for entry in entries {
            let clean = Self.sanitizedForInsertion(entry)
            if !clean.isEmpty { editor.addToHistory(clean) }
        }
    }

    /// Strip everything a terminal would ACT on, keeping newlines.
    ///
    /// `Editor.handlePaste` applies exactly this filter, but `onPaste` returning
    /// `true` short-circuits it, so every route that puts foreign text into the
    /// document — a rejected drop's raw payload, a seeded history entry — has to
    /// apply it itself. Line endings and tabs are folded first, the way
    /// `Editor.normalizeText` would, so a CR-separated drop keeps its line breaks
    /// instead of collapsing into one line.
    static func sanitizedForInsertion(_ text: String) -> String {
        var folded = text.replacingOccurrences(of: "\r\n", with: "\n")
        folded = folded.replacingOccurrences(of: "\r", with: "\n")
        folded = folded.replacingOccurrences(of: "\t", with: "    ")
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            let value = scalar.value
            if value == 0x0a {
                scalars.append(scalar)
                continue
            }
            if value < 0x20 || value == 0x7f || (value >= 0x80 && value <= 0x9f) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
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
        /// inserted at the caret — the "never silently eat a path the user meant as
        /// text" guarantee — with control characters stripped, because it is a
        /// clipboard/drag payload rather than the user's keystrokes and the paste
        /// filter it would otherwise have gone through was short-circuited by the
        /// drop hook. `notice` is the app's to display; the prompt has no status
        /// line of its own.
        case rejected(rawText: String, notice: String)
        /// The reading RESOLVED, and part of it attached: `attached` is staged as
        /// chips and `text` — the paths that were refused, and only those — goes
        /// back into the document.
        ///
        /// Distinct from `.rejected` because it is not a failed reading of the
        /// paste: the tokenization was right, and the files that could not be
        /// attached are named by the app's notice. Distinct from `.attached`
        /// because something DID have to go back as text, and `.attached` has no
        /// way to say so. Folding either of those two into a single case is how a
        /// drop of nine photos ended up attaching none of them.
        case partial(attached: [PromptAttachment], text: String)
    }

    /// Mint a token for a drop about to be handed to the app, remembering the raw
    /// text it came from.
    ///
    /// Kept separate from `onDrop` so the caller decides whether the paste is a drop
    /// at all — the parse needs a path grammar this component deliberately does not
    /// own.
    func beginDrop(rawText: String = "") -> UInt32 {
        dropCounter &+= 1
        pendingDrops[dropCounter] = rawText
        return dropCounter
    }

    /// The raw pasted text behind an unanswered drop, for an app that has to put
    /// it back. `nil` once the drop is answered or abandoned.
    func pendingDropText(for token: UInt32) -> String? { pendingDrops[token] }

    /// Apply the app's answer to a drop.
    ///
    /// - Returns: whether the token was still LIVE. `false` means the drop was
    ///   abandoned while it was being read — the prompt was cleared, or a session
    ///   was opened under it — and NOTHING was applied. The caller has to know:
    ///   posting "attached 1 image" after a `false` is a claim that the message
    ///   the user is about to send carries a picture it does not carry, which is
    ///   worse than any error, because it is silent.
    @discardableResult
    func resolveDrop(token: UInt32, outcome: DropOutcome) -> Bool {
        guard pendingDrops.removeValue(forKey: token) != nil else { return false }
        switch outcome {
        case .attached(let resolved):
            for attachment in resolved { addAttachment(attachment) }
        case .rejected(let rawText, _):
            insertAsText(rawText)
        case .partial(let resolved, let text):
            for attachment in resolved { addAttachment(attachment) }
            insertAsText(text)
        }
        return true
    }

    /// Put foreign text back into the document, control characters stripped — the
    /// one filter `onPaste` short-circuited.
    ///
    /// Anchored at the END, on its own line, exactly as ``restore(_:attachments:)``
    /// is and for the same reason: this text arrives ASYNCHRONOUSLY, after a
    /// filesystem round trip, by which time the caret is wherever the user has since
    /// typed. Inserting there spliced a refused path into the middle of the sentence
    /// being written — "abc/tmp/notes.txtdef" out of "abcdef" — and the `.partial`
    /// case made that a routine, non-error path rather than a rare one.
    private func insertAsText(_ text: String) {
        let clean = Self.sanitizedForInsertion(text)
        guard !clean.isEmpty else { return }
        let existing = editor.getExpandedText()
        editor.setText(existing.isEmpty ? clean : existing + "\n" + clean)
    }

    /// How many chip rows the last `height(forWidth:maxRows:)` call budgeted.
    ///
    /// Stored for the same reason `showBorders`/`maxVisibleLines` are: measure and
    /// paint have to agree on ONE number. They did not — `height` clamped the chip
    /// count to `maxRows - 1` and `render` emitted every chip, so six chips in a
    /// six-row slot promised 6 rows and painted 7. `ComponentBox.place` builds
    /// exactly `rect.height` rows and drops the rest, and chips come FIRST, so what
    /// the overflow clipped away was the editor: the user's text and the caret.
    private var chipBudget = 0

    /// One chip per row.
    ///
    /// The SINGLE height and rendering source for chips. One per row keeps the
    /// arithmetic exact and keeps a long filename readable; what actually reaches
    /// the frame is `budgetedChipRows(width:)`, which holds this to the row count
    /// `height(forWidth:maxRows:)` promised.
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

    /// The chip rows that fit the budget, with the overflow named rather than
    /// silently dropped.
    ///
    /// Eight images dropped on a 24-row terminal is the realistic case — the cap
    /// there is 8 rows — and a chip that vanishes with no trace is a file the user
    /// believes they attached. The last budgeted row becomes `+N more` instead.
    private func budgetedChipRows(width: Int) -> [String] {
        let all = chipRows(width: width)
        guard chipBudget > 0, !all.isEmpty else { return [] }
        if all.count <= chipBudget { return all }
        var kept = Array(all.prefix(chipBudget - 1))
        let hidden = all.count - kept.count
        kept.append(truncateToWidth(dim("📎 +\(hidden) more"), width, ellipsis: "…"))
        return kept
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
        guard width > 0, maxRows > 0 else {
            chipBudget = 0
            return 1
        }
        let chips = min(chipRows(width: width).count, max(0, maxRows - 1))
        chipBudget = chips
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
        var lines = budgetedChipRows(width: width)
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
        if keybindings.matches(data, .inputPasteImage) {
            onPasteImage?()
            return
        }
        // Backspace on an empty document pops the newest chip before the keystroke
        // can reach the editor, where it would do nothing at all.
        if !attachments.isEmpty, editor.getText().isEmpty,
           keybindings.matches(data, .editorDeleteCharBackward) {
            attachments.removeLast()
            return
        }
        // Editor deliberately treats Tab as a no-op. It is the explicit,
        // unambiguous request to consult the async provider in the full-screen
        // client, so do this before handing the sequence to the editor.
        if keybindings.matches(data, .inputTab) {
            requestAutocomplete(force: true)
            return
        }
        editor.handleInput(data)
    }

    func invalidate() { editor.invalidate() }

    private func requestAutocomplete(force: Bool) {
        guard let provider = autocompleteProvider else { return }
        autocompleteTask?.cancel()
        let lines = editor.getLines()
        let cursor = editor.getCursor()
        autocompleteTask = Task { @MainActor [weak self] in
            let suggestions = await provider.getSuggestions(
                lines: lines,
                cursorLine: cursor.line,
                cursorCol: cursor.col,
                force: force,
                signal: CancellationSignal { Task.isCancelled }
            )
            guard let self, !Task.isCancelled else { return }
            self.autocompleteSuggestions = suggestions
            self.onAutocomplete?(suggestions)
        }
    }

    // MARK: Paste

    /// Consulted with a WHOLE bracketed paste before the editor inserts it. Return
    /// `true` to swallow it.
    ///
    /// This is the one place drop decoding can correctly live: dragging a file onto
    /// a terminal makes the terminal PASTE the path, so a drop and a paste are the
    /// same event and only the content tells them apart. The hook is on the editor
    /// rather than on this façade because a bracketed paste is buffered across
    /// `handleInput` calls until its terminator arrives — a sniff at this level
    /// would miss any paste the driver delivered in two pieces.
    ///
    /// ``DoMoCore/DroppedPaths/candidates(_:)`` owns the grammar and is deliberately
    /// conservative: it answers with an empty array for anything that is not
    /// unambiguously a list of absolute paths, and prose mentioning a path — "check
    /// /tmp/a.png and tell me" — is such a thing. An empty answer returns `false`
    /// here, which is today's behaviour byte for byte: ordinary text, newlines
    /// intact, never a submit.
    ///
    /// With no `onDrop` consumer the paste is also ordinary text. A prompt whose
    /// owner cannot resolve a file must not swallow one: there would be nobody to
    /// answer ``resolveDrop(token:outcome:)`` and the user's path would simply
    /// vanish.
    private func handlePastedText(_ pasted: String) -> Bool {
        guard let onDrop else { return false }
        let candidates = DroppedPaths.candidates(pasted)
        guard !candidates.isEmpty else { return false }
        // Nothing is inserted here, and nothing is inserted by the app on
        // success. The raw text is held against the token so a rejection can put
        // it back exactly as it arrived.
        onDrop(beginDrop(rawText: pasted), candidates)
        return true
    }

    // MARK: Submit

    /// Submit, unless a dropped file is still being read.
    ///
    /// THE WINDOW THIS CLOSES. Dropping a file hands a token to the app and
    /// swallows the paste; the answer comes back one multi-megabyte read later.
    /// Clearing `pendingDrops` here — which is what the send does — made that
    /// answer stale, so `resolveDrop` discarded it: the images never reached the
    /// prompt, the message went to the model with no picture in it, and the status
    /// line said "attached 1 image" anyway. The whole read is the window, not the
    /// 4 KiB sniff, and a 2 MiB screenshot is enough to hit it on the first try.
    ///
    /// Refusing is the only answer that cannot lose anything. Sending without the
    /// images sends a message the user did not write; waiting for the read on the
    /// render loop freezes the UI for the length of it; and attaching them to the
    /// NEXT message puts a picture on a message it was not meant for. So Enter
    /// puts the text back, says why, and works on the next press — which is
    /// milliseconds later, because the read is already running.
    ///
    /// The restore is `restore(_:)`, the same path a refused send uses: `Editor`
    /// clears itself BEFORE `onSubmit` runs, so the argument is the only surviving
    /// copy of what was typed.
    private func handleSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = attachments
        guard !trimmed.isEmpty || !pending.isEmpty else { return }
        guard pendingDrops.isEmpty else {
            restore(trimmed)
            onSubmitDeferredForDrop?()
            return
        }
        attachments = []
        pendingDrops = [:]
        if !trimmed.isEmpty {
            editor.addToHistory(trimmed)
            onHistoryAdd?(trimmed)
        }
        onSubmit?(trimmed, pending)
    }
}
