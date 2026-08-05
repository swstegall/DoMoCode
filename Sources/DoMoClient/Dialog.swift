// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoGit
import DoMoHarness
import DoMoTUI
import DoMoServer
import DoMoTermIO

/// The full-screen client's reusable overlay owner. `ScreenSurface` already
/// saves and restores focus for every overlay; this small stack adds the missing
/// application-level rule that dialogs are dismissed in LIFO order and that a
/// caller never has to reach into the surface to present one.
@MainActor
final class DialogStack {
    private weak var surface: ScreenSurface?
    private var handles: [ScreenOverlayHandle] = []

    init(surface: ScreenSurface) { self.surface = surface }

    var isEmpty: Bool { handles.isEmpty }

    @discardableResult
    func present(_ component: Component, options: OverlayOptions? = nil) -> ScreenOverlayHandle? {
        guard let surface else { return nil }
        // Every application dialog gets the same visible frame. Preserve the
        // explicitly boxed callers whose sizing logic already accounts for the
        // two border rows, while making palette/picker/form callers equally clear
        // against a bright or dark page background.
        let framed: Component = component is Box ? component : Box(component, paddingX: 1)
        let handle = surface.showOverlay(
            framed,
            options: Self.optionsForFramedComponent(component, options: options)
        )
        handles.append(handle)
        return handle
    }

    /// A ``Box`` contributes one top and one bottom row. Callers size the
    /// unframed dialog content, so preserve both rules when an explicit height
    /// cap is supplied. Explicitly boxed callers already include those rows in
    /// their own budget and are left unchanged.
    static func optionsForFramedComponent(_ component: Component, options: OverlayOptions?) -> OverlayOptions? {
        guard !(component is Box), let original = options else { return options }
        var adjusted = original
        guard case .absolute(let height) = adjusted.maxHeight else { return options }
        adjusted.maxHeight = .absolute(height + 2)
        return adjusted
    }

    func dismiss(_ handle: ScreenOverlayHandle?) {
        guard let handle else { return }
        handle.hide()
        handles.removeAll { $0 === handle }
    }

    func dismissTop() {
        guard let handle = handles.last else { return }
        dismiss(handle)
    }

    func dismissAll() {
        while let handle = handles.popLast() { handle.hide() }
    }
}

/// A compact searchable list dialog. Printable input changes the prefix filter,
/// while the underlying `SelectList` retains all of the shared wrap/navigation
/// and width-safe rendering behavior.
@MainActor
final class SearchableSelectDialog: Component {
    private var title: String
    private var items: [SelectItem]
    private var list: SelectList
    private var query = ""
    private let keybindings: Keybindings

    var onSelect: ((SelectItem) -> Void)?
    /// Optional insertion action used by catalogs whose selected value becomes
    /// prompt text. Plain Tab is intentionally inert for every other picker.
    var onInsert: ((SelectItem) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, items: [SelectItem], keybindings: Keybindings = Keybindings()) {
        self.title = title
        self.keybindings = keybindings
        self.items = items
        self.list = SelectList(items: [], maxVisible: 12, keybindings: keybindings)
        rebuildList()
    }

    /// Replace the source rows without losing the current search query or, when
    /// possible, the selected value. Session names can change while this picker is
    /// open (for example when automatic titling finishes), so a snapshot-only list
    /// makes the dialog visibly stale until it is dismissed and reopened.
    func update(title: String? = nil, items: [SelectItem]) {
        if let title { self.title = title }
        let selectedValue = list.getSelectedItem()?.value
        self.items = items
        rebuildList(preferredValue: selectedValue)
    }

    func updateItems(_ items: [SelectItem]) {
        update(items: items)
    }

    func render(width: Int) -> [String] {
        let heading = truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m  \(query.isEmpty ? "" : "[\(query)]")", width, ellipsis: "")
        return [heading] + list.render(width: width)
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) { return }
        if keybindings.matches(data, .inputTab) {
            if let item = list.getSelectedItem() {
                onInsert?(item)
            }
            return
        }
        if keybindings.matches(data, .selectUp)
            || keybindings.matches(data, .selectDown)
            || keybindings.matches(data, .selectConfirm) {
            list.handleInput(data)
            return
        }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
            return
        }
        if data == [0x7f] || data == [0x08] {
            guard !query.isEmpty else { return }
            query.removeLast()
            rebuildList()
            return
        }
        guard let scalar = data.first, data.count == 1, scalar >= 0x20, scalar != 0x7f else { return }
        let character = String(decoding: data, as: UTF8.self)
        guard !character.isEmpty, !character.contains("\u{1b}") else { return }
        query += character
        rebuildList()
    }

    private func rebuildList(preferredValue: String? = nil) {
        let needle = query.lowercased()
        let filtered = needle.isEmpty
            ? items
            : items.filter { item in
                let primary = item.label.isEmpty ? item.value : item.label
                let haystack = "\(primary) \(item.value) \(item.description ?? "")".lowercased()
                return haystack.contains(needle)
            }
        let replacement = SelectList(
            items: filtered,
            maxVisible: max(1, min(filtered.count, 12)),
            keybindings: keybindings
        )
        replacement.onSelect = { [weak self] item in self?.onSelect?(item) }
        replacement.onInsert = { [weak self] item in self?.onInsert?(item) }
        replacement.onCancel = { [weak self] in self?.onCancel?() }
        if let preferredValue,
           let index = filtered.firstIndex(where: { $0.value == preferredValue }) {
            replacement.setSelectedIndex(index)
        }
        list = replacement
    }
}

/// The scrollable command reference shown by the palette's Help action and the
/// `/help` command. The rows are assembled from the injected canonical keymap and
/// command registry so project commands and binding changes do not leave a stale
/// hard-coded reference behind.
@MainActor
final class HelpDialog: Component {
    private let keybindings: Keybindings
    private let rows: [String]
    private let viewportRows: Int
    private var offset = 0

    var onCancel: (() -> Void)?

    init(
        commands: CommandRegistry,
        keybindings: Keybindings = Keybindings(),
        globalShortcuts: [(String, String)],
        viewportRows: Int = 18
    ) {
        self.keybindings = keybindings
        self.viewportRows = max(8, viewportRows)
        self.rows = Self.makeRows(
            commands: commands,
            keybindings: keybindings,
            globalShortcuts: globalShortcuts
        )
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        let bodyRows = max(1, viewportRows - 2)
        let start = min(offset, max(0, rows.count - 1))
        let end = min(rows.count, start + bodyRows)
        var output = [truncateToWidth("\u{1b}[1mHelp\u{1b}[0m", width, ellipsis: "")]
        output.append(contentsOf: rows[start..<end].map {
            truncateToWidth($0, width, ellipsis: "")
        })
        if rows.count > bodyRows {
            let range = "\(start + 1)-\(end)/\(rows.count)"
            output.append(truncateToWidth(
                "↑/↓ or PgUp/PgDn scroll · \(range) · Esc close",
                width,
                ellipsis: ""
            ))
        } else {
            output.append(truncateToWidth("Esc close", width, ellipsis: ""))
        }
        return output
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) { return }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
            return
        }
        let bodyRows = max(1, viewportRows - 2)
        if keybindings.matches(data, .selectUp) {
            scroll(by: -1, bodyRows: bodyRows)
        } else if keybindings.matches(data, .selectDown) {
            scroll(by: 1, bodyRows: bodyRows)
        } else if keybindings.matches(data, .selectPageUp) || matchesKey(data, Key.pageUp) {
            scroll(by: -bodyRows, bodyRows: bodyRows)
        } else if keybindings.matches(data, .selectPageDown) || matchesKey(data, Key.pageDown) {
            scroll(by: bodyRows, bodyRows: bodyRows)
        } else if matchesKey(data, Key.home) || data == Array("g".utf8) {
            offset = 0
        } else if matchesKey(data, Key.end) || data == Array("G".utf8) {
            offset = max(0, rows.count - bodyRows)
        }
    }

    private func scroll(by delta: Int, bodyRows: Int) {
        offset = max(0, min(offset + delta, max(0, rows.count - bodyRows)))
    }

    private static func makeRows(
        commands: CommandRegistry,
        keybindings: Keybindings,
        globalShortcuts: [(String, String)]
    ) -> [String] {
        var rows = ["GLOBAL SHORTCUTS"]
        rows.append(contentsOf: globalShortcuts.map { "  \($0.0)  —  \($0.1)" })
        rows.append("")
        rows.append("EDITOR AND SELECTORS")
        for binding in Keybinding.allCases {
            let keys = keybindings.keys(for: binding).map(Self.displayKey).joined(separator: " / ")
            rows.append("  \(keys)  —  \(Self.description(for: binding))")
        }
        rows.append("")
        rows.append("COMMANDS")
        for command in commands.commands {
            let hint = command.argumentHint.map { " ($0)" } ?? ""
            let description = command.description ?? (command.kind == .local ? "Local client action" : "Send a prompt")
            rows.append("  /\(command.name)\(hint)  —  \(sanitizeUntrustedText(collapseToOneLine(description)))")
        }
        rows.append("")
        rows.append("WORKFLOWS")
        rows.append("  /workflow [prompt]  —  open the phase-and-agent workspace")
        rows.append("  /research, /plan, /execute, /synthesize  —  open at a named phase")
        rows.append("  Enter a phase to inspect its agents; Enter an agent to view its running content")
        rows.append("  Escape walks back from agents to phases and from the workflow to sessions")
        return rows
    }

    private static func displayKey(_ key: KeyId) -> String {
        let description = key.description
        if key.ctrl, case .char(let character) = key.base {
            return "^" + String(character).uppercased()
        }
        if key.shift, case .tab = key.base { return "Shift+Tab" }
        if key.shift, case .enter = key.base { return "Shift+Enter" }
        return description
    }

    private static func description(for binding: Keybinding) -> String {
        switch binding {
        case .editorCursorUp: return "move the prompt cursor up"
        case .editorCursorDown: return "move the prompt cursor down"
        case .editorCursorLeft: return "move left"
        case .editorCursorRight: return "move right"
        case .editorCursorWordLeft: return "move one word left"
        case .editorCursorWordRight: return "move one word right"
        case .editorCursorLineStart: return "move to the line start"
        case .editorCursorLineEnd: return "move to the line end"
        case .editorJumpForward: return "jump forward to a matching bracket"
        case .editorJumpBackward: return "jump backward to a matching bracket"
        case .editorPageUp: return "page up in the prompt editor"
        case .editorPageDown: return "page down in the prompt editor"
        case .editorDeleteCharBackward: return "delete the previous character"
        case .editorDeleteCharForward: return "delete the next character"
        case .editorDeleteWordBackward: return "delete the previous word"
        case .editorDeleteWordForward: return "delete the next word"
        case .editorDeleteToLineStart: return "delete to the line start"
        case .editorDeleteToLineEnd: return "delete to the line end"
        case .editorYank: return "yank the cut text"
        case .editorYankPop: return "cycle the yank ring"
        case .editorUndo: return "undo prompt editing"
        case .inputNewLine: return "insert a newline without sending"
        case .inputSubmit: return "send the prompt"
        case .inputTab: return "move focus to the next pane"
        case .inputCopy: return "copy the current input or quit at the app level"
        case .inputPasteImage: return "paste an image from the clipboard"
        case .selectUp: return "move a selector up"
        case .selectDown: return "move a selector down"
        case .selectPageUp: return "page up in a selector"
        case .selectPageDown: return "page down in a selector"
        case .selectConfirm: return "confirm a selector choice"
        case .selectCancel: return "cancel a selector"
        }
    }
}

/// A one-line input dialog used for session names and other small metadata.
@MainActor
final class DialogTextInput: @MainActor Focusable {
    private let title: String
    private let editor: Editor

    var focused = false { didSet { editor.focused = focused } }
    var wantsKeyRelease: Bool { false }
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, initial: String = "") {
        self.title = title
        self.editor = Editor(paddingX: 0, rows: { 4 })
        self.editor.setText(initial)
        self.editor.showBorders = false
        self.editor.maxVisibleLines = 1
        self.editor.onSubmit = { [weak self] text in self?.onSubmit?(text) }
    }

    func render(width: Int) -> [String] {
        let titleLine = truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m", width, ellipsis: "")
        return [titleLine] + editor.render(width: width) + [truncateToWidth(dim("Enter confirm · Esc cancel"), width, ellipsis: "")]
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) { return }
        if data == [0x1b] {
            onCancel?()
            return
        }
        editor.handleInput(data)
    }

    func invalidate() { editor.invalidate() }
}

/// A two-choice confirmation dialog. Keeping the answer as a value rather than
/// making callers inspect a selected row lets the same overlay work for destructive
/// actions and simple yes/no questions.
@MainActor
final class DialogConfirm: Component {
    private let title: String
    private let message: String
    private let list: SelectList

    var onResult: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(
        title: String,
        message: String,
        confirmLabel: String = "Confirm",
        cancelLabel: String = "Cancel",
        keybindings: Keybindings = Keybindings()
    ) {
        self.title = title
        self.message = message
        self.list = SelectList(
            items: [
                SelectItem(value: "confirm", label: confirmLabel),
                SelectItem(value: "cancel", label: cancelLabel),
            ],
            maxVisible: 2,
            keybindings: keybindings
        )
        self.list.onSelect = { [weak self] item in
            self?.onResult?(item.value == "confirm")
        }
        self.list.onCancel = { [weak self] in self?.onCancel?() }
    }

    func render(width: Int) -> [String] {
        [truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m", width, ellipsis: ""),
         truncateToWidth(message, width, ellipsis: "")] + list.render(width: width)
    }

    func handleInput(_ data: [UInt8]) { list.handleInput(data) }
}

/// A keyboard-first diff review surface. The sidebar is deliberately compact:
/// common directory prefixes collapse to an ellipsis, leaving room for the
/// selected file's hunks. The dialog keeps review marks locally; refreshing a
/// live diff preserves marks for paths that still exist.
@MainActor
final class DiffReviewDialog: Component {
    private var diff: GitDiff?
    private var selectedFile = 0
    private var selectedHunk = 0
    private var reviewed: Set<String> = []
    private var splitView = false
    private var splitModeExplicit = false
    private var commitMessage: String?

    var onClose: (() -> Void)?
    var onRevert: ((String) -> Void)?
    var onCommitMessage: (() -> Void)?

    init(diff: GitDiff? = nil) {
        self.diff = diff
    }

    func update(diff: GitDiff) {
        self.diff = diff
        let paths = Set(diff.files.map(\.path))
        reviewed = reviewed.intersection(paths)
        selectedFile = min(selectedFile, max(0, diff.files.count - 1))
        selectedHunk = min(selectedHunk, max(0, selectedFileHunks.count - 1))
    }

    func showCommitMessage(_ message: String?) {
        commitMessage = message.map { sanitizeUntrustedText(collapseToOneLine($0)) }
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        if !splitModeExplicit { splitView = width >= 96 }
        guard let diff else {
            return [
                truncateToWidth("\u{1b}[1mGit diff review\u{1b}[0m", width, ellipsis: ""),
                "Loading diff…",
            ]
        }
        let files = diff.files
        let sidebarWidth = min(34, max(20, width / 3))
        let bodyWidth = max(1, width - sidebarWidth - 3)
        var rows: [String] = []
        let base = diff.base.map { String($0.prefix(12)) } ?? "working tree"
            rows.append(truncateToWidth(
                "\u{1b}[1mGit diff review\u{1b}[0m  \(base)  \(diff.additions)+ \(diff.deletions)-",
            width,
            ellipsis: ""
        ))
        if files.isEmpty {
            rows.append("No modified files.")
        } else {
            let left = sidebarRows(files: files, width: sidebarWidth)
            let right = bodyRows(files: files, width: bodyWidth)
            let height = max(left.count, right.count)
            for index in 0..<height {
                let leftRow = index < left.count ? left[index] : ""
                let rightRow = index < right.count ? right[index] : ""
                let paddedLeft = padToWidth(leftRow, sidebarWidth)
                rows.append(truncateToWidth(paddedLeft + " │ " + rightRow, width, ellipsis: ""))
            }
        }
        if let commitMessage, !commitMessage.isEmpty {
            rows.append(truncateToWidth("commit subject: \(commitMessage)", width, ellipsis: ""))
        }
        rows.append(truncateToWidth(
            "↑/↓ file · ]/[ hunk · r reviewed · u \(splitView ? "unified" : "split") · v restore · c subject · Esc close",
            width,
            ellipsis: ""
        ))
        return rows
    }

    func handleInput(_ data: [UInt8]) {
        if data == [0x1b] {
            onClose?()
            return
        }
        guard let diff, !diff.files.isEmpty else { return }
        switch data {
        case [0x1b, 0x5b, 0x41]:
            moveFile(by: -1)
        case [0x1b, 0x5b, 0x42]:
            moveFile(by: 1)
        case Array("]".utf8):
            moveHunk(by: 1)
        case Array("[".utf8):
            moveHunk(by: -1)
        case Array("r".utf8), Array("m".utf8):
            reviewed.insert(diff.files[selectedFile].path)
        case Array("u".utf8):
            splitModeExplicit = true
            splitView.toggle()
        case Array("v".utf8):
            onRevert?(diff.files[selectedFile].path)
        case Array("c".utf8):
            onCommitMessage?()
        default:
            return
        }
    }

    private var selectedHunkCount: Int {
        guard let diff, diff.files.indices.contains(selectedFile) else { return 0 }
        return diff.files[selectedFile].hunks.count
    }

    private var selectedFileHunks: [GitDiffHunk] {
        guard let diff, diff.files.indices.contains(selectedFile) else { return [] }
        return diff.files[selectedFile].hunks
    }

    private func moveFile(by delta: Int) {
        guard let diff, !diff.files.isEmpty else { return }
        selectedFile = (selectedFile + delta + diff.files.count) % diff.files.count
        selectedHunk = 0
    }

    private func moveHunk(by delta: Int) {
        guard selectedHunkCount > 0 else { return }
        selectedHunk = (selectedHunk + delta + selectedHunkCount) % selectedHunkCount
    }

    private func sidebarRows(files: [GitDiffFile], width: Int) -> [String] {
        var rows = ["FILES \(files.count)"]
        for (index, file) in files.enumerated() {
            let marker = index == selectedFile ? ">" : " "
            let done = reviewed.contains(file.path) ? "✓" : " "
            let change = "\(file.additions)+ \(file.deletions)-"
            rows.append(truncateToWidth(
                "\(marker)\(done) \(collapsedPath(sanitizeUntrustedText(file.path), width: width - 10)) \(change)",
                width,
                ellipsis: ""
            ))
        }
        return rows
    }

    private func bodyRows(files: [GitDiffFile], width: Int) -> [String] {
        guard files.indices.contains(selectedFile) else { return [] }
        let file = files[selectedFile]
        var rows = [
            "\(sanitizeUntrustedText(file.path))  \(file.status.rawValue)  \(file.additions)+ \(file.deletions)-",
            file.binary ? "binary file" : "hunks \(file.hunks.count)",
        ]
        guard !file.binary else { return rows }
        for (index, hunk) in file.hunks.enumerated() {
            let marker = index == selectedHunk ? ">" : " "
            rows.append("\(marker) \(sanitizeUntrustedText(hunk.header))")
            if index != selectedHunk { continue }
            rows.append(contentsOf: splitView
                ? splitRows(hunk: hunk, width: width)
                : hunk.lines.map { line in
                    let prefix: String
                    switch line.kind {
                    case .addition: prefix = "+"
                    case .deletion: prefix = "-"
                    case .context: prefix = " "
                    case .metadata: prefix = "!"
                    }
                    return prefix + sanitizeUntrustedText(line.text)
                })
        }
        return rows
    }

    private func splitRows(hunk: GitDiffHunk, width: Int) -> [String] {
        let column = max(1, (width - 3) / 2)
        var old: [String] = []
        var new: [String] = []
        for line in hunk.lines {
            switch line.kind {
            case .deletion, .context:
                old.append(line.text)
            default:
                break
            }
            switch line.kind {
            case .addition, .context:
                new.append(line.text)
            default:
                break
            }
        }
        let rows = max(old.count, new.count)
        return (0..<rows).map { index in
            let left = index < old.count ? sanitizeUntrustedText(old[index]) : ""
            let right = index < new.count ? sanitizeUntrustedText(new[index]) : ""
            return padToWidth(String(left.prefix(column)), column) + " │ " + String(right.prefix(column))
        }
    }

    private func collapsedPath(_ path: String, width: Int) -> String {
        let safeWidth = max(6, width)
        guard path.count > safeWidth else { return path }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else {
            return "…" + String(path.suffix(safeWidth - 1))
        }
        let tail = components.suffix(2).joined(separator: "/")
        return "…/" + String(tail.suffix(safeWidth - 2))
    }

    private func padToWidth(_ value: String, _ width: Int) -> String {
        let clipped = truncateToWidth(value, width, ellipsis: "")
        let visible = visibleWidth(clipped)
        guard visible < width else { return clipped }
        return clipped + String(repeating: " ", count: width - visible)
    }
}

/// The full-screen client's structured-question surface. A server question may
/// contain several prompts, so the dialog advances one prompt at a time and
/// returns one answer for each in the original order. Multiple-choice prompts
/// use Space to toggle rows; single-choice prompts use the highlighted row.
@MainActor
final class QuestionDialog: Component {
    private let questions: [ServerQuestionPrompt]
    private let keybindings: Keybindings
    private var questionIndex = 0
    private var selectedIndex = 0
    private var selectedLabels: [Set<String>]

    var onSubmit: (([ServerQuestionAnswer]) -> Void)?
    var onCancel: (() -> Void)?

    init(questions: [ServerQuestionPrompt], keybindings: Keybindings = Keybindings()) {
        self.questions = questions
        self.keybindings = keybindings
        self.selectedLabels = questions.map { _ in [] }
    }

    func render(width: Int) -> [String] {
        guard width > 0, questions.indices.contains(questionIndex) else { return [] }
        let prompt = questions[questionIndex]
        let ordinal = "Question \(questionIndex + 1) of \(questions.count)"
        let title = prompt.header.map(sanitizeUntrustedText).map(collapseToOneLine) ?? ordinal
        var lines = [truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m  \(ordinal)", width, ellipsis: "")]
        lines.append(truncateToWidth(
            sanitizeUntrustedText(collapseToOneLine(prompt.question)), width, ellipsis: ""
        ))
        lines.append("")

        for (index, option) in prompt.options.enumerated() {
            let isSelected = index == selectedIndex
            let isChecked = selectedLabels[questionIndex].contains(option.label)
            let prefix: String
            if prompt.allowsMultiple {
                prefix = (isChecked ? "[x] " : "[ ] ")
            } else {
                prefix = isSelected ? "> " : "  "
            }
            var text = prefix + sanitizeUntrustedText(collapseToOneLine(option.label))
            if let description = option.description, !description.isEmpty {
                text += " — " + sanitizeUntrustedText(collapseToOneLine(description))
            }
            lines.append(truncateToWidth(text, width, ellipsis: ""))
        }
        let hint = prompt.allowsMultiple
            ? "↑/↓ choose · Space toggle · Enter next · Esc cancel"
            : "↑/↓ choose · Enter confirm · Esc cancel"
        lines.append("")
        lines.append(truncateToWidth(dim(hint), width, ellipsis: ""))
        return lines
    }

    func handleInput(_ data: [UInt8]) {
        guard !isKeyRelease(data), questions.indices.contains(questionIndex) else {
            return
        }
        let prompt = questions[questionIndex]
        guard !prompt.options.isEmpty else { return }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
        } else if keybindings.matches(data, .selectUp) {
            selectedIndex = selectedIndex == 0 ? prompt.options.count - 1 : selectedIndex - 1
        } else if keybindings.matches(data, .selectDown) {
            selectedIndex = selectedIndex == prompt.options.count - 1 ? 0 : selectedIndex + 1
        } else if prompt.allowsMultiple, data == [0x20] {
            let label = prompt.options[selectedIndex].label
            if selectedLabels[questionIndex].contains(label) {
                selectedLabels[questionIndex].remove(label)
            } else {
                selectedLabels[questionIndex].insert(label)
            }
        } else if keybindings.matches(data, .selectConfirm) {
            submitCurrent(prompt)
        }
    }

    private func submitCurrent(_ prompt: ServerQuestionPrompt) {
        if !prompt.allowsMultiple {
            selectedLabels[questionIndex] = [prompt.options[selectedIndex].label]
        }
        guard questionIndex + 1 < questions.count else {
            let answers = questions.enumerated().map { index, prompt in
                ServerQuestionAnswer(
                    selectedLabels: prompt.options.compactMap { selectedLabels[index].contains($0.label) ? $0.label : nil }
                )
            }
            onSubmit?(answers)
            return
        }
        questionIndex += 1
        selectedIndex = 0
    }
}

/// Chooses which transcript content crosses the clipboard boundary.
///
/// Export and copy share the same formatter, but copy is an interactive gesture:
/// a small multi-select lets a user keep the default complete conversation or
/// remove reasoning, tool activity, or session bookkeeping before the Markdown
/// is handed to the clipboard.
@MainActor
final class TranscriptOptionsDialog: Component {
    private let keybindings: Keybindings
    private var selectedIndex = 0
    private var includeReasoning: Bool
    private var includeTools: Bool
    private var includeMetadata: Bool

    var onSubmit: ((TranscriptFormatOptions) -> Void)?
    var onCancel: (() -> Void)?

    init(options: TranscriptFormatOptions = .copy, keybindings: Keybindings = Keybindings()) {
        self.keybindings = keybindings
        self.includeReasoning = options.includeReasoning
        self.includeTools = options.includeToolCalls || options.includeToolResults
        self.includeMetadata = options.includeMetadata
    }

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        let rows = [
            ("Reasoning", includeReasoning),
            ("Tool calls and results", includeTools),
            ("Session metadata", includeMetadata),
        ]
        var lines = [truncateToWidth("\u{1b}[1mCopy transcript\u{1b}[0m", width, ellipsis: "")]
        for (index, row) in rows.enumerated() {
            let marker = row.1 ? "[x]" : "[ ]"
            let prefix = index == selectedIndex ? "> " : "  "
            lines.append(truncateToWidth("\(prefix)\(marker) \(row.0)", width, ellipsis: ""))
        }
        lines.append("")
        lines.append(truncateToWidth(dim("↑/↓ choose · Space toggle · Enter copy · Esc cancel"), width, ellipsis: ""))
        return lines
    }

    func handleInput(_ data: [UInt8]) {
        guard !isKeyRelease(data) else { return }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
        } else if keybindings.matches(data, .selectUp) {
            selectedIndex = selectedIndex == 0 ? 2 : selectedIndex - 1
        } else if keybindings.matches(data, .selectDown) {
            selectedIndex = selectedIndex == 2 ? 0 : selectedIndex + 1
        } else if data == [0x20] {
            toggleSelected()
        } else if keybindings.matches(data, .selectConfirm) {
            onSubmit?(
                TranscriptFormatOptions(
                    includeReasoning: includeReasoning,
                    includeToolCalls: includeTools,
                    includeToolResults: includeTools,
                    includeMetadata: includeMetadata
                )
            )
        }
    }

    private func toggleSelected() {
        switch selectedIndex {
        case 0: includeReasoning.toggle()
        case 1: includeTools.toggle()
        default: includeMetadata.toggle()
        }
    }
}

/// A small, keyboard-first form. Each field owns a normal `Editor`, so paste,
/// undo, Unicode cursor movement, and validation hooks remain the same as the
/// prompt input rather than being reimplemented for metadata dialogs.
struct DialogFormField: Sendable, Hashable {
    var label: String
    var value: String

    init(label: String, value: String = "") {
        self.label = label
        self.value = value
    }
}

@MainActor
final class DialogForm: @MainActor Focusable {
    private let title: String
    private let keybindings: Keybindings
    private let labels: [String]
    private let editors: [Editor]
    private var selectedIndex = 0

    var focused = false { didSet { updateFocus() } }
    var wantsKeyRelease: Bool { false }
    var onSubmit: (([String]) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, fields: [DialogFormField], keybindings: Keybindings = Keybindings()) {
        self.title = title
        self.keybindings = keybindings
        self.labels = fields.map { $0.label }
        self.editors = fields.map { field in
            let editor = Editor(paddingX: 0, rows: { 1 })
            editor.setText(field.value)
            editor.showBorders = false
            editor.maxVisibleLines = 1
            return editor
        }
        updateFocus()
    }

    func render(width: Int) -> [String] {
        var lines = [truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m", width, ellipsis: "")]
        for (index, editor) in editors.enumerated() {
            let prefix = (index == selectedIndex ? "> " : "  ") + labels[index] + ": "
            let value = editor.render(width: max(0, width - prefix.count)).joined(separator: " ")
            lines.append(truncateToWidth(prefix + value, width, ellipsis: ""))
        }
        lines.append(truncateToWidth(dim("↑/↓ field · Enter next/submit · Esc cancel"), width, ellipsis: ""))
        return lines
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) || editors.isEmpty { return }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
            return
        }
        if keybindings.matches(data, .selectUp) {
            selectedIndex = max(0, selectedIndex - 1)
            updateFocus()
            return
        }
        if keybindings.matches(data, .selectDown) {
            selectedIndex = min(editors.count - 1, selectedIndex + 1)
            updateFocus()
            return
        }
        if keybindings.matches(data, .selectConfirm) {
            if selectedIndex < editors.count - 1 {
                selectedIndex += 1
                updateFocus()
            } else {
                onSubmit?(editors.map { $0.getText() })
            }
            return
        }
        editors[selectedIndex].handleInput(data)
    }

    func invalidate() { editors.forEach { $0.invalidate() } }

    private func updateFocus() {
        for (index, editor) in editors.enumerated() {
            editor.focused = focused && index == selectedIndex
        }
    }
}

/// A multiline editor dialog used by callers that need a real text body rather
/// than the one-line metadata input. It deliberately exposes the same submit and
/// cancel callbacks as the other dialog shapes.
@MainActor
final class DialogEditor: @MainActor Focusable {
    private let title: String
    private let editor: Editor

    var focused = false { didSet { editor.focused = focused } }
    var wantsKeyRelease: Bool { false }
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, initial: String = "", rows: @escaping () -> Int = { 12 }) {
        self.title = title
        self.editor = Editor(paddingX: 0, rows: rows)
        self.editor.setText(initial)
        self.editor.onSubmit = { [weak self] text in self?.onSubmit?(text) }
    }

    var text: String { editor.getText() }

    func render(width: Int) -> [String] {
        [truncateToWidth("\u{1b}[1m\(title)\u{1b}[0m", width, ellipsis: "")]
            + editor.render(width: width)
            + [truncateToWidth(dim("Enter submit · Esc cancel"), width, ellipsis: "")]
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) { return }
        if data == [0x1b] {
            onCancel?()
            return
        }
        editor.handleInput(data)
    }

    func invalidate() { editor.invalidate() }
}

/// The row model for the conversation-tree dialog. It deliberately does not
/// depend on the session file type: the client can decorate entries with labels
/// and depths while the dialog only owns filtering, folding, and selection.
struct TreeDialogItem: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case message
        case metadata
        case label
        case branch
    }

    let value: String
    let label: String
    let description: String?
    let parentID: String?
    let depth: Int
    let kind: Kind
    let hasChildren: Bool
    let currentLabel: String?
}

enum TreeFilterMode: String, CaseIterable, Equatable, Sendable {
    case all
    case messages
    case metadata
    case labels
    case branches

    var next: TreeFilterMode {
        let modes = Self.allCases
        guard let index = modes.firstIndex(of: self) else { return .all }
        return modes[(index + 1) % modes.count]
    }

    func includes(_ item: TreeDialogItem) -> Bool {
        switch self {
        case .all: return true
        case .messages: return item.kind == .message
        case .metadata: return item.kind == .metadata
        case .labels: return item.kind == .label
        case .branches: return item.kind == .branch || item.hasChildren
        }
    }
}

/// A tree-aware select dialog. `f` cycles semantic filters, Space folds the
/// selected subtree, and `l` hands a selected node to the caller's label form.
/// Search is a case-insensitive substring match, which is more useful for long
/// assistant messages than the prefix filter used by ordinary pickers.
@MainActor
final class TreeDialog: Component {
    private let title: String
    private let items: [TreeDialogItem]
    private let keybindings: Keybindings
    private var list: SelectList
    private var query = ""
    private var filterMode: TreeFilterMode = .all
    private var folded: Set<String> = []

    var onSelect: ((TreeDialogItem) -> Void)?
    var onLabel: ((TreeDialogItem) -> Void)?
    var onCancel: (() -> Void)?

    init(title: String, items: [TreeDialogItem], keybindings: Keybindings = Keybindings()) {
        self.title = title
        self.items = items
        self.keybindings = keybindings
        self.list = SelectList(items: [], maxVisible: 16, keybindings: keybindings)
        rebuildList()
    }

    func render(width: Int) -> [String] {
        let filter = "filter: \(filterMode.rawValue)"
        let search = query.isEmpty ? "" : "  [\(query)]"
        let heading = truncateToWidth(
            "\u{1b}[1m\(title)\u{1b}[0m  \(filter)\(search)",
            width,
            ellipsis: ""
        )
        return [heading] + list.render(width: width)
            + [truncateToWidth(dim("f filter · Space fold · l label · Enter branch"), width, ellipsis: "")]
    }

    func handleInput(_ data: [UInt8]) {
        if isKeyRelease(data) { return }
        if keybindings.matches(data, .selectUp)
            || keybindings.matches(data, .selectDown)
            || keybindings.matches(data, .selectConfirm) {
            list.handleInput(data)
            return
        }
        if keybindings.matches(data, .selectCancel) {
            onCancel?()
            return
        }
        if data == [0x66] { // f
            filterMode = filterMode.next
            rebuildList(preferredID: selectedID())
            return
        }
        if data == [0x20] { // Space
            guard let item = selectedItem(), item.hasChildren else { return }
            if folded.contains(item.value) {
                folded.remove(item.value)
            } else {
                folded.insert(item.value)
            }
            rebuildList(preferredID: item.value)
            return
        }
        if data == [0x6c] { // l
            if let item = selectedItem() { onLabel?(item) }
            return
        }
        if data == [0x7f] || data == [0x08] {
            guard !query.isEmpty else { return }
            query.removeLast()
            rebuildList(preferredID: nil)
            return
        }
        guard data.count == 1, let scalar = data.first, scalar >= 0x20, scalar != 0x7f else { return }
        let character = String(decoding: data, as: UTF8.self)
        guard !character.isEmpty, !character.contains("\u{1b}") else { return }
        query += character
        rebuildList(preferredID: nil)
    }

    private func selectedID() -> String? { list.getSelectedItem()?.value }

    private func selectedItem() -> TreeDialogItem? {
        guard let id = selectedID() else { return nil }
        return items.first { $0.value == id }
    }

    private func rebuildList(preferredID: String? = nil) {
        let visible = items.filter { item in
            guard filterMode.includes(item), isVisible(item) else { return false }
            guard !query.isEmpty else { return true }
            let haystack = "\(item.label) \(item.description ?? "")".lowercased()
            return haystack.contains(query.lowercased())
        }
        let rows = visible.map { item in
            let marker = item.hasChildren && folded.contains(item.value) ? "▸ " : "  "
            let indent = String(repeating: "  ", count: item.depth)
            return SelectItem(
                value: item.value,
                label: indent + marker + item.label,
                description: item.description
            )
        }
        let replacement = SelectList(items: rows, maxVisible: 16, keybindings: keybindings)
        replacement.onSelect = { [weak self] row in
            guard let self, let item = self.items.first(where: { $0.value == row.value }) else { return }
            self.onSelect?(item)
        }
        replacement.onCancel = { [weak self] in self?.onCancel?() }
        if let preferredID,
           let index = rows.firstIndex(where: { $0.value == preferredID }) {
            replacement.setSelectedIndex(index)
        }
        list = replacement
    }

    private func isVisible(_ item: TreeDialogItem) -> Bool {
        var parent = item.parentID
        var seen: Set<String> = []
        while let parentID = parent, seen.insert(parentID).inserted {
            if folded.contains(parentID) { return false }
            parent = items.first(where: { $0.value == parentID })?.parentID
        }
        return true
    }
}
