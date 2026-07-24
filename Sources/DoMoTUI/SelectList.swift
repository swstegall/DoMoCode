// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/select-list.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The item model, the scroll-window
// arithmetic, the two-column primary/description layout, the primary-column
// sizing, and the wrap-around navigation are ported verbatim. Two deliberate
// divergences from pi are documented inline: input consults an injected
// `Keybindings` value rather than a process-global registry, and the scroll
// indicator reports directional "N more above/below" counts rather than pi's
// `(current/total)` position string.

import DoMoTermIO

// MARK: - Item

/// One selectable row: a stable `value`, a human `label`, and an optional
/// `description` shown in a second column when there is room.
///
/// A value type — the list owns its items and never needs identity on them, and
/// `Sendable` lets a caller build the item array off the main actor and hand it
/// in. `label` falls back to `value` when empty, matching pi's `label || value`.
public struct SelectItem: Sendable, Equatable {
    public var value: String
    public var label: String
    public var description: String?

    public init(value: String, label: String = "", description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }

    /// The text drawn in the primary column: the label when set, else the value.
    var displayValue: String {
        label.isEmpty ? value : label
    }
}

// MARK: - Theme

/// The style hooks the list calls to colourize its parts.
///
/// pi passes a theme object of `(text) -> text` functions so the palette lives
/// outside the component. Each hook only adds ANSI styling (zero visible width),
/// so the width budget the renderer enforces is computed on the un-styled text
/// and the styled result still fits. ``plain`` is the identity theme used when a
/// caller wants no colour — and what the tests assert against so widths are
/// exact.
public struct SelectListTheme {
    public var selectedPrefix: (String) -> String
    public var selectedText: (String) -> String
    public var description: (String) -> String
    public var scrollInfo: (String) -> String
    public var noMatch: (String) -> String

    public init(
        selectedPrefix: @escaping (String) -> String,
        selectedText: @escaping (String) -> String,
        description: @escaping (String) -> String,
        scrollInfo: @escaping (String) -> String,
        noMatch: @escaping (String) -> String
    ) {
        self.selectedPrefix = selectedPrefix
        self.selectedText = selectedText
        self.description = description
        self.scrollInfo = scrollInfo
        self.noMatch = noMatch
    }

    /// The identity theme — every hook returns its input unchanged.
    public static var plain: SelectListTheme {
        SelectListTheme(
            selectedPrefix: { $0 },
            selectedText: { $0 },
            description: { $0 },
            scrollInfo: { $0 },
            noMatch: { $0 }
        )
    }
}

// MARK: - Layout options

/// Context handed to a caller's custom primary-column truncator.
public struct SelectListTruncatePrimaryContext {
    public var text: String
    public var maxWidth: Int
    public var columnWidth: Int
    public var item: SelectItem
    public var isSelected: Bool
}

/// Tuning for the primary column: its width bounds and an optional custom
/// truncator. Both bounds default to ``SelectList/defaultPrimaryColumnWidth``.
public struct SelectListLayoutOptions {
    public var minPrimaryColumnWidth: Int?
    public var maxPrimaryColumnWidth: Int?
    public var truncatePrimary: ((SelectListTruncatePrimaryContext) -> String)?

    public init(
        minPrimaryColumnWidth: Int? = nil,
        maxPrimaryColumnWidth: Int? = nil,
        truncatePrimary: ((SelectListTruncatePrimaryContext) -> String)? = nil
    ) {
        self.minPrimaryColumnWidth = minPrimaryColumnWidth
        self.maxPrimaryColumnWidth = maxPrimaryColumnWidth
        self.truncatePrimary = truncatePrimary
    }
}

// MARK: - SelectList

/// A scrollable, filterable list with a moving selection.
///
/// The selection wraps at both ends, the visible window slides to keep the
/// selection centred, and a scroll indicator reports how much content is hidden
/// above and below. Navigation is driven entirely through an injected
/// ``Keybindings`` value (`tui.select.up/down/confirm/cancel`), so the component
/// owns its binding policy and the renderer only routes bytes.
///
/// Every rendered line is kept within the width budget by measuring with
/// ``visibleWidth(_:)`` and clipping with ``truncateToWidth(_:_:ellipsis:pad:)``,
/// so the list never emits the over-wide line the renderer treats as fatal.
public final class SelectList: Component {
    /// pi's `DEFAULT_PRIMARY_COLUMN_WIDTH`.
    public static let defaultPrimaryColumnWidth = 32
    /// pi's `PRIMARY_COLUMN_GAP` — the minimum gap after the primary column.
    private static let primaryColumnGap = 2
    /// pi's `MIN_DESCRIPTION_WIDTH` — below this the description column is dropped.
    private static let minDescriptionWidth = 10

    private var items: [SelectItem]
    private var filteredItems: [SelectItem]
    private var selectedIndex = 0
    private let maxVisible: Int
    private let theme: SelectListTheme
    private let layout: SelectListLayoutOptions
    private let keybindings: Keybindings

    /// Fired when the user confirms (Enter) with a valid selection.
    public var onSelect: ((SelectItem) -> Void)?
    /// Fired when the user cancels (Escape / Ctrl+C).
    public var onCancel: (() -> Void)?
    /// Fired whenever the moving selection lands on a new item.
    public var onSelectionChange: ((SelectItem) -> Void)?

    public init(
        items: [SelectItem],
        maxVisible: Int,
        theme: SelectListTheme = .plain,
        layout: SelectListLayoutOptions = SelectListLayoutOptions(),
        keybindings: Keybindings = Keybindings()
    ) {
        self.items = items
        self.filteredItems = items
        self.maxVisible = max(1, maxVisible)
        self.theme = theme
        self.layout = layout
        self.keybindings = keybindings
    }

    // MARK: State access

    /// Narrow the visible items to those whose `value` starts with `filter`
    /// (case-insensitive), resetting the selection to the top. Ports pi's
    /// `setFilter`.
    public func setFilter(_ filter: String) {
        let needle = filter.lowercased()
        filteredItems = needle.isEmpty
            ? items
            : items.filter { $0.value.lowercased().hasPrefix(needle) }
        selectedIndex = 0
    }

    /// Clamp and set the selected index within the filtered items.
    public func setSelectedIndex(_ index: Int) {
        selectedIndex = max(0, min(index, filteredItems.count - 1))
    }

    /// The currently selected item, or `nil` when the filter matched nothing.
    public func getSelectedItem() -> SelectItem? {
        guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return nil }
        return filteredItems[selectedIndex]
    }

    // MARK: Rendering

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        var lines: [String] = []

        if filteredItems.isEmpty {
            // Clamp to the width budget: the message is 22 columns and would be
            // an over-wide (fatal) line in any narrower viewport.
            lines.append(theme.noMatch(truncateToWidth("  No matching commands", width, ellipsis: "")))
            return lines
        }

        let primaryColumnWidth = getPrimaryColumnWidth()

        // Visible window: keep the selection roughly centred, clamped so the
        // window never runs past either end. Ports pi's start/end arithmetic.
        let startIndex = max(
            0,
            min(
                selectedIndex - maxVisible / 2,
                filteredItems.count - maxVisible
            )
        )
        let endIndex = min(startIndex + maxVisible, filteredItems.count)

        for i in startIndex..<endIndex {
            let item = filteredItems[i]
            let isSelected = i == selectedIndex
            let descriptionSingleLine = item.description.map(SelectList.normalizeToSingleLine)
            lines.append(renderItem(item, isSelected: isSelected, width: width,
                                    descriptionSingleLine: descriptionSingleLine,
                                    primaryColumnWidth: primaryColumnWidth))
        }

        // Scroll indicator. DIVERGENCE FROM PI: pi renders `(current/total)`;
        // this reports directional "N more above/below" counts, which the brief
        // asks for. Still a single extra line, so the component's height is
        // pi's shape. Truncated to the width budget like pi's indicator.
        if startIndex > 0 || endIndex < filteredItems.count {
            let above = startIndex
            let below = filteredItems.count - endIndex
            var parts: [String] = []
            if above > 0 { parts.append("\(above) more above") }
            if below > 0 { parts.append("\(below) more below") }
            let scrollText = "  (" + parts.joined(separator: ", ") + ")"
            lines.append(theme.scrollInfo(truncateToWidth(scrollText, max(0, width - 2), ellipsis: "")))
        }

        // Final width clamp. Item rows are bounded by construction for width >= 2,
        // but the fixed 2-column selection prefix overruns a width-1 viewport;
        // clamping here honours the type's "every rendered line fits" contract for
        // every width rather than most. A line already within budget is returned
        // unchanged, so styled rows and existing golden frames are untouched.
        return lines.map { truncateToWidth($0, width, ellipsis: "") }
    }

    // MARK: Input

    public func handleInput(_ data: [UInt8]) {
        guard !filteredItems.isEmpty else {
            if keybindings.matches(data, .selectCancel) { onCancel?() }
            return
        }
        if keybindings.matches(data, .selectUp) {
            selectedIndex = selectedIndex == 0 ? filteredItems.count - 1 : selectedIndex - 1
            notifySelectionChange()
        } else if keybindings.matches(data, .selectDown) {
            selectedIndex = selectedIndex == filteredItems.count - 1 ? 0 : selectedIndex + 1
            notifySelectionChange()
        } else if keybindings.matches(data, .selectConfirm) {
            if let item = getSelectedItem() { onSelect?(item) }
        } else if keybindings.matches(data, .selectCancel) {
            onCancel?()
        }
    }

    // MARK: Item rendering

    private func renderItem(
        _ item: SelectItem,
        isSelected: Bool,
        width: Int,
        descriptionSingleLine: String?,
        primaryColumnWidth: Int
    ) -> String {
        let prefix = isSelected ? "→ " : "  "
        let prefixWidth = visibleWidth(prefix)

        if let descriptionSingleLine, width > 40 {
            let effectivePrimaryColumnWidth = max(1, min(primaryColumnWidth, width - prefixWidth - 4))
            let maxPrimaryWidth = max(1, effectivePrimaryColumnWidth - SelectList.primaryColumnGap)
            let truncatedValue = truncatePrimary(item, isSelected: isSelected,
                                                 maxWidth: maxPrimaryWidth,
                                                 columnWidth: effectivePrimaryColumnWidth)
            let truncatedValueWidth = visibleWidth(truncatedValue)
            let spacingCount = max(1, effectivePrimaryColumnWidth - truncatedValueWidth)
            let spacing = String(repeating: " ", count: spacingCount)
            let descriptionStart = prefixWidth + truncatedValueWidth + spacingCount
            let remainingWidth = width - descriptionStart - 2 // -2 for safety, as pi

            if remainingWidth > SelectList.minDescriptionWidth {
                let truncatedDesc = truncateToWidth(descriptionSingleLine, remainingWidth, ellipsis: "")
                if isSelected {
                    return theme.selectedText("\(prefix)\(truncatedValue)\(spacing)\(truncatedDesc)")
                }
                let descText = theme.description(spacing + truncatedDesc)
                return prefix + truncatedValue + descText
            }
        }

        let maxWidth = width - prefixWidth - 2
        let truncatedValue = truncatePrimary(item, isSelected: isSelected, maxWidth: maxWidth, columnWidth: maxWidth)
        if isSelected {
            return theme.selectedText("\(prefix)\(truncatedValue)")
        }
        return prefix + truncatedValue
    }

    private func getPrimaryColumnWidth() -> Int {
        let bounds = getPrimaryColumnBounds()
        let widestPrimary = filteredItems.reduce(0) { widest, item in
            max(widest, visibleWidth(item.displayValue) + SelectList.primaryColumnGap)
        }
        return max(bounds.min, min(widestPrimary, bounds.max))
    }

    private func getPrimaryColumnBounds() -> (min: Int, max: Int) {
        let rawMin = layout.minPrimaryColumnWidth
            ?? layout.maxPrimaryColumnWidth
            ?? SelectList.defaultPrimaryColumnWidth
        let rawMax = layout.maxPrimaryColumnWidth
            ?? layout.minPrimaryColumnWidth
            ?? SelectList.defaultPrimaryColumnWidth
        return (
            min: max(1, min(rawMin, rawMax)),
            max: max(1, max(rawMin, rawMax))
        )
    }

    private func truncatePrimary(
        _ item: SelectItem,
        isSelected: Bool,
        maxWidth: Int,
        columnWidth: Int
    ) -> String {
        let displayValue = item.displayValue
        let truncatedValue: String
        if let custom = layout.truncatePrimary {
            truncatedValue = custom(SelectListTruncatePrimaryContext(
                text: displayValue, maxWidth: maxWidth, columnWidth: columnWidth,
                item: item, isSelected: isSelected))
        } else {
            truncatedValue = truncateToWidth(displayValue, maxWidth, ellipsis: "")
        }
        // Second pass: a custom truncator may have overshot; clamp to the budget.
        return truncateToWidth(truncatedValue, maxWidth, ellipsis: "")
    }

    private func notifySelectionChange() {
        if let item = getSelectedItem() { onSelectionChange?(item) }
    }

    /// Collapse any run of CR/LF to a single space and trim the ends, so a
    /// multi-line description shows as one row. Ports pi's `normalizeToSingleLine`.
    private static func normalizeToSingleLine(_ text: String) -> String {
        var result = ""
        var lastWasBreak = false
        for character in text {
            if character == "\r" || character == "\n" {
                if !lastWasBreak { result.append(" ") }
                lastWasBreak = true
            } else {
                result.append(character)
                lastWasBreak = false
            }
        }
        return result.trimmingCharacters(in: [" "])
    }
}
