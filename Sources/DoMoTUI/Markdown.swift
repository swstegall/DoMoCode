// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/markdown.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. pi parses with `marked` and mutates
// its token stream in place; this port parses with swift-markdown, whose AST is
// immutable, so the two structural choices that flow from that swap are called
// out where they happen: the streaming anti-flicker fix moves to the *text* level
// (``trimPartialClosingFence(_:)``) because there is no token to trim after
// parsing, and strict strikethrough is enforced from each node's source range
// (``strikethroughDelimiterCount(for:)``) because swift-markdown has no
// pluggable tokenizer to reject a single `~`. Exact byte parity with pi is a
// non-goal — see README, "Markdown rendering gap".

import Markdown

// MARK: - ANSI styling

// Markdown styling is expressed as SGR escapes. Every span uses a *targeted*
// disable code (22 for bold/dim, 23 italic, 24 underline, 29 strikethrough, 39
// foreground) rather than a blanket `\e[0m`, so nested spans compose without
// tearing down the styling of the text that surrounds them: a bold word inside a
// coloured heading closes only bold and leaves the heading colour standing. The
// width engine ignores every one of these escapes, so styling never affects
// which column a line wraps at.

private func sgr(_ open: String, _ text: String, _ close: String) -> String {
    "\u{1b}[\(open)m\(text)\u{1b}[\(close)m"
}

private let esc = "\u{1b}"

private func boldStyle(_ t: String) -> String { sgr("1", t, "22") }
private func italicStyle(_ t: String) -> String { sgr("3", t, "23") }
private func underlineStyle(_ t: String) -> String { sgr("4", t, "24") }
private func strikethroughStyle(_ t: String) -> String { sgr("9", t, "29") }
private func dimStyle(_ t: String) -> String { sgr("2", t, "22") }
private func codeStyle(_ t: String) -> String { sgr("33", t, "39") }
private func linkStyle(_ t: String) -> String { sgr("34;4", t, "24;39") }
private func linkUrlStyle(_ t: String) -> String { dimStyle(t) }
private func quoteStyle(_ t: String) -> String { sgr("2;3", t, "23;22") }
private let quoteReopen = "\u{1b}[2m\u{1b}[3m"
private let headingColorOpen = "\u{1b}[36m"
private let fullReset = "\u{1b}[0m"

/// An OSC 8 hyperlink: `text` made clickable, pointing at `url`. The escapes have
/// zero visible width (they terminate with BEL), so a hyperlinked run measures
/// exactly as its visible text does.
private func osc8Hyperlink(_ url: String, _ text: String) -> String {
    "\u{1b}]8;;\(url)\u{07}\(text)\u{1b}]8;;\u{07}"
}

// MARK: - Inline style context

/// How a run of inline text is styled, and how to restore that styling after a
/// child span resets an attribute it shares.
///
/// Ports pi's `InlineStyleContext`. `apply` wraps a bare text segment in the
/// context's base style (identity at the top level, where markdown adds no
/// default styling). `restore` is the escape re-emitted after any child that
/// closes the foreground colour — an inline code span or a link — so the base
/// colour of an enclosing heading survives the child's `\e[39m`. It is appended
/// after every child and trimmed if it lands at the very end, exactly as pi
/// appends and trims its `stylePrefix`.
private struct InlineStyle {
    var apply: (String) -> String = { $0 }
    var restore: String = ""
}

// MARK: - Markdown

/// Markdown text rendered to ANSI-styled terminal lines that fit a given width.
///
/// The rendering pipeline mirrors pi's: normalise tabs, apply the streaming
/// anti-flicker fix, parse, walk the block tree to styled lines, word-wrap every
/// line to the content width through the shared width engine, then frame each
/// line with horizontal padding and pad it to exactly `width`. That last pad is
/// the fatal-width guard — every emitted line is composed to `width` columns
/// through ``truncateToWidth(_:_:ellipsis:pad:)``, so a wide CJK cluster or a
/// long code line can never overhang the budget the renderer reserved.
///
/// The AST walk is a plain recursive descent over `Markup.children` with a
/// type-switch rather than a ``MarkupWalker`` conformance: a walker's visit
/// methods return `Void` and thread state through `mutating` calls, which fits an
/// accumulate-into-a-buffer traversal poorly when each block must *return* its
/// own `[String]`. The descent visits the same tree in the same order.
public final class Markdown: Component {
    /// The markdown source to render.
    public var text: String

    /// Columns of blank inset on the left and right of the content. Clamped to a
    /// non-negative value: a negative inset has no meaning and would trap the
    /// render's `String(repeating:count:)`.
    public var paddingX: Int {
        didSet {
            if paddingX < 0 { paddingX = 0 }
            invalidate()
        }
    }

    /// Blank lines above and below the content. Clamped to a non-negative value
    /// for the same reason `paddingX` is: a negative count traps `0..<paddingY`.
    public var paddingY: Int {
        didSet {
            if paddingY < 0 { paddingY = 0 }
            invalidate()
        }
    }

    /// Render links as OSC 8 hyperlinks (text only, URL hidden) when true;
    /// otherwise print the URL in parentheses after the text when they differ.
    public var useHyperlinks: Bool {
        didSet { invalidate() }
    }

    /// Apply the streaming anti-flicker trim (``trimPartialClosingFence(_:)``).
    /// On by default and safe on completed text — a finished document has no
    /// partial closing fence to trim.
    public var streaming: Bool {
        didSet { invalidate() }
    }

    // Cache keyed on the inputs that determine the output: `text` and `width`
    // are compared directly in ``render(width:)``, and every other
    // output-determining property invalidates the cache when it changes.
    private var cachedText: String?
    private var cachedWidth: Int?
    private var cachedLines: [String]?

    // The parse-time source, split into UTF-8 bytes per line, so a node's
    // source range (line + UTF-8 column) can be read back to enforce strict
    // strikethrough. Set at the top of each parse.
    private var sourceUTF8Lines: [[UInt8]] = []

    public init(
        _ text: String,
        paddingX: Int = 0,
        paddingY: Int = 0,
        useHyperlinks: Bool = false,
        streaming: Bool = true
    ) {
        self.text = text
        self.paddingX = max(0, paddingX)
        self.paddingY = max(0, paddingY)
        self.useHyperlinks = useHyperlinks
        self.streaming = streaming
    }

    public func setText(_ text: String) {
        self.text = text
        invalidate()
    }

    public func invalidate() {
        cachedText = nil
        cachedWidth = nil
        cachedLines = nil
    }

    // MARK: Render

    public func render(width: Int) -> [String] {
        if let cachedLines, cachedText == text, cachedWidth == width {
            return cachedLines
        }

        let contentWidth = max(1, width - paddingX * 2)

        if text.trimmingWhitespace().isEmpty {
            let result: [String] = []
            cachedText = text
            cachedWidth = width
            cachedLines = result
            return result
        }

        // Tabs to three spaces, matching the width engine's `tabColumnWidth`, so
        // wrapping measures what parsing produced.
        let normalized = text.replacingOccurrences(of: "\t", with: "   ")
        let prepared = streaming ? trimPartialClosingFence(normalized) : normalized

        sourceUTF8Lines = prepared
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Array($0.utf8) }

        let document = Document(parsing: prepared)
        let blocks = Array(document.blockChildren)
        let styledLines = renderBlocks(blocks, width: contentWidth, style: InlineStyle(), separateWithBlank: true)

        // Word-wrap every styled line to the content width. Lines that already
        // fit (list rows, quote rows) pass through; over-long code lines split.
        var wrapped: [String] = []
        for line in styledLines {
            wrapped.append(contentsOf: wrapTextWithAnsi(line, contentWidth))
        }

        let leftPad = String(repeating: " ", count: paddingX)
        let rightPad = leftPad
        let blankRow = String(repeating: " ", count: width)

        var result: [String] = []
        for _ in 0..<paddingY { result.append(blankRow) }
        for line in wrapped {
            // Compose margins, then clamp to exactly `width`. When wrapping kept
            // the content within `contentWidth` the pad just fills to the right
            // margin; if a boundary ever put it over, truncateToWidth clips on a
            // cluster boundary so no over-wide (renderer-fatal) line escapes.
            let composed = leftPad + line + rightPad
            result.append(truncateToWidth(composed, width, ellipsis: "", pad: true))
        }
        for _ in 0..<paddingY { result.append(blankRow) }

        cachedText = text
        cachedWidth = width
        cachedLines = result
        return result
    }

    // MARK: Block walk

    /// Render a run of sibling blocks, optionally with one blank line between
    /// them. The blank separator is what turns stacked block elements into
    /// readable paragraphs; it is suppressed inside tight list items, where a
    /// bullet's blocks must sit flush.
    private func renderBlocks(
        _ blocks: [Markup],
        width: Int,
        style: InlineStyle,
        separateWithBlank: Bool
    ) -> [String] {
        var lines: [String] = []
        for (index, block) in blocks.enumerated() {
            lines.append(contentsOf: renderBlock(block, width: width, style: style))
            if separateWithBlank, index < blocks.count - 1 {
                lines.append("")
            }
        }
        return lines
    }

    private func renderBlock(_ block: Markup, width: Int, style: InlineStyle) -> [String] {
        switch block {
        case let heading as Heading:
            return renderHeading(heading)
        case let paragraph as Paragraph:
            return [renderInline(Array(paragraph.children), style: style)]
        case let code as CodeBlock:
            return renderCodeBlock(code)
        case let list as UnorderedList:
            return renderList(Array(list.listItems), ordered: false, start: 1, depth: 0, width: width, style: style)
        case let list as OrderedList:
            return renderList(Array(list.listItems), ordered: true, start: Int(list.startIndex), depth: 0, width: width, style: style)
        case let quote as BlockQuote:
            return renderBlockQuote(quote, width: width)
        case is ThematicBreak:
            return [dimStyle(String(repeating: "\u{2500}", count: min(width, 80)))]
        case let html as HTMLBlock:
            return [dimStyle(html.rawHTML.trimmingWhitespace())]
        case let table as Table:
            return renderTable(table, width: width, style: style)
        default:
            // Any unhandled block (block directive, custom block) degrades to its
            // plain text so nothing silently vanishes.
            let plain = block.children.map { plainText(of: $0, style: style) }.joined()
            return plain.isEmpty ? [] : [style.apply(plain)]
        }
    }

    private func renderHeading(_ heading: Heading) -> [String] {
        let level = heading.level
        let prefix = String(repeating: "#", count: max(1, level)) + " "
        // The whole line is wrapped in one style; inner spans restore the heading
        // colour after any foreground reset. h1 additionally underlines.
        let open = level <= 1
            ? "\u{1b}[1m\u{1b}[4m" + headingColorOpen
            : "\u{1b}[1m" + headingColorOpen
        let context = InlineStyle(apply: { $0 }, restore: headingColorOpen)
        let inner = renderInline(Array(heading.children), style: context)
        return [open + prefix + inner + fullReset]
    }

    private func renderCodeBlock(_ code: CodeBlock) -> [String] {
        let indent = "  "
        let language = code.language ?? ""
        var lines: [String] = []
        lines.append(dimStyle("```\(language)"))
        // swift-markdown's `code` ends with a trailing newline; dropping it
        // avoids an empty final code row.
        var body = code.code
        if body.hasSuffix("\n") { body.removeLast() }
        for codeLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(indent + String(codeLine))
        }
        lines.append(dimStyle("```"))
        return lines
    }

    /// Render a list. `depth` drives four-space indent per nesting level, and a
    /// nested list re-enters at the same content `width` so its own indent — not
    /// a shrinking budget — expresses the nesting, exactly as pi does.
    private func renderList(
        _ items: [ListItem],
        ordered: Bool,
        start: Int,
        depth: Int,
        width: Int,
        style: InlineStyle
    ) -> [String] {
        var lines: [String] = []
        let indent = String(repeating: " ", count: 4 * depth)

        for (i, item) in items.enumerated() {
            let bullet = ordered ? "\(start + i). " : "- "
            let checkbox: String
            switch item.checkbox {
            case .checked: checkbox = "[x] "
            case .unchecked: checkbox = "[ ] "
            case nil: checkbox = ""
            }
            let marker = bullet + checkbox
            let firstPrefix = indent + marker
            let continuationPrefix = indent + String(repeating: " ", count: visibleWidth(marker))
            let itemWidth = max(1, width - visibleWidth(firstPrefix))
            var renderedAnyLine = false

            for childBlock in item.children {
                if let nested = childBlock as? UnorderedList {
                    lines.append(contentsOf: renderList(Array(nested.listItems), ordered: false, start: 1, depth: depth + 1, width: width, style: style))
                    renderedAnyLine = true
                    continue
                }
                if let nested = childBlock as? OrderedList {
                    lines.append(contentsOf: renderList(Array(nested.listItems), ordered: true, start: Int(nested.startIndex), depth: depth + 1, width: width, style: style))
                    renderedAnyLine = true
                    continue
                }
                for blockLine in renderBlock(childBlock, width: itemWidth, style: style) {
                    for wrappedLine in wrapTextWithAnsi(blockLine, itemWidth) {
                        lines.append((renderedAnyLine ? continuationPrefix : firstPrefix) + wrappedLine)
                        renderedAnyLine = true
                    }
                }
            }

            if !renderedAnyLine {
                lines.append(firstPrefix)
            }
        }

        return lines
    }

    private func renderBlockQuote(_ quote: BlockQuote, width: Int) -> [String] {
        let innerWidth = max(1, width - 2)
        let context = InlineStyle(apply: { $0 }, restore: quoteReopen)
        var inner = renderBlocks(Array(quote.blockChildren), width: innerWidth, style: context, separateWithBlank: true)
        while inner.last == "" { inner.removeLast() }

        var lines: [String] = []
        for quoteLine in inner {
            for wrappedLine in wrapTextWithAnsi(quoteLine, innerWidth) {
                lines.append(dimStyle("\u{2502} ") + quoteStyle(wrappedLine))
            }
        }
        return lines
    }

    /// A deliberately minimal table: header and body rows joined with " | " and
    /// left to wrap like any paragraph. pi draws a box-ruled table; that is not
    /// ported (README gap) because the fatal-width guarantee matters more than
    /// the ruling, and a wrapped plain-text table always fits.
    private func renderTable(_ table: Table, width: Int, style: InlineStyle) -> [String] {
        var rows: [String] = []
        func renderRow(_ row: Markup, bold: Bool) {
            let cells = row.children.map { renderInline(Array($0.children), style: style) }
            let joined = cells.joined(separator: " | ")
            rows.append(bold ? boldStyle(joined) : joined)
        }
        for headRow in table.head.children { renderRow(headRow, bold: true) }
        for bodyRow in table.body.children { renderRow(bodyRow, bold: false) }
        return rows
    }

    // MARK: Inline walk

    private func renderInline(_ inlines: [Markup], style: InlineStyle) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case let strong as Strong:
                result += boldStyle(renderInline(Array(strong.children), style: style)) + style.restore
            case let emphasis as Emphasis:
                result += italicStyle(renderInline(Array(emphasis.children), style: style)) + style.restore
            case let strike as Strikethrough:
                result += renderStrikethrough(strike, style: style)
            case let code as InlineCode:
                result += codeStyle(code.code) + style.restore
            case let link as Link:
                result += renderLink(link, style: style)
            case let image as Image:
                result += renderImage(image, style: style)
            case is SoftBreak:
                // A source newline inside a paragraph is a space so the wrapper
                // can re-flow the text to the render width.
                result += " "
            case is LineBreak:
                result += "\n"
            case let html as InlineHTML:
                result += style.apply(html.rawHTML)
            default:
                result += style.apply(plainText(of: inline, style: style))
            }
        }
        // A restore appended after the final child is dead weight; drop it, as pi
        // trims a trailing stylePrefix.
        if !style.restore.isEmpty {
            while result.hasSuffix(style.restore) {
                result.removeLast(style.restore.count)
            }
        }
        return result
    }

    /// Strict strikethrough: swift-markdown accepts a single `~` as a delimiter,
    /// but pi requires `~~`. The node carries no delimiter count, so read it from
    /// the source: a single-tilde span is rendered literally (tildes and all,
    /// unstyled) instead of struck.
    private func renderStrikethrough(_ strike: Strikethrough, style: InlineStyle) -> String {
        let inner = renderInline(Array(strike.children), style: style)
        let delimiters = strikethroughDelimiterCount(for: strike)
        if delimiters >= 2 {
            return strikethroughStyle(inner) + style.restore
        }
        let literal = String(repeating: "~", count: max(1, delimiters))
        return style.apply(literal) + inner + style.apply(literal)
    }

    private func strikethroughDelimiterCount(for strike: Strikethrough) -> Int {
        guard let range = strike.range else { return 2 }
        let lineIndex = range.lowerBound.line - 1
        guard lineIndex >= 0, lineIndex < sourceUTF8Lines.count else { return 2 }
        let bytes = sourceUTF8Lines[lineIndex]
        var index = range.lowerBound.column - 1
        var count = 0
        while index >= 0, index < bytes.count, bytes[index] == 0x7E {
            count += 1
            index += 1
        }
        return count
    }

    private func renderLink(_ link: Link, style: InlineStyle) -> String {
        let linkText = renderInline(Array(link.children), style: style)
        let destination = link.destination ?? ""
        let styled = linkStyle(linkText)
        if useHyperlinks {
            return osc8Hyperlink(destination, styled) + style.restore
        }
        // Fall back to the URL in parentheses when it adds information beyond the
        // visible text. mailto: autolinks carry text without the scheme.
        let comparison = destination.hasPrefix("mailto:") ? String(destination.dropFirst(7)) : destination
        let plain = link.plainText
        if plain == destination || plain == comparison || destination.isEmpty {
            return styled + style.restore
        }
        return styled + linkUrlStyle(" (\(destination))") + style.restore
    }

    private func renderImage(_ image: Image, style: InlineStyle) -> String {
        let alt = renderInline(Array(image.children), style: style)
        let source = image.source ?? ""
        let label = alt.isEmpty ? "[image]" : "[\(alt)]"
        if source.isEmpty { return style.apply(label) }
        return style.apply(label) + linkUrlStyle(" (\(source))")
    }

    private func plainText(of markup: Markup, style: InlineStyle) -> String {
        if let convertible = markup as? any InlineMarkup {
            return convertible.plainText
        }
        return markup.children.map { plainText(of: $0, style: style) }.joined()
    }

    // MARK: Streaming anti-flicker

    /// Trim a partial closing code fence from the end of a still-streaming buffer.
    ///
    /// While an LLM streams a fenced code block, the closing fence arrives one
    /// backtick at a time: the buffer briefly ends in ``` ``\n `` `` (two of a
    /// three-backtick fence). CommonMark treats that short run as *content*, so
    /// swift-markdown would render a literal ``` `` `` code line that vanishes the
    /// instant the third backtick lands — the flicker pi's in-place token trim
    /// avoids (earendil-works/pi#5825). The AST here is immutable, so the fix
    /// moves earlier: detect the unterminated fence at the text level and drop the
    /// trailing partial-fence line, leaving swift-markdown to render a clean open
    /// code block. Only a final line made solely of the fence character, shorter
    /// than the opener, is removed; genuine code content and a completed fence are
    /// left untouched.
    private func trimPartialClosingFence(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var insideFence = false
        var fenceChar: Character = "`"
        var fenceLength = 0

        for line in lines {
            if insideFence {
                if isFenceClose(line, fenceChar, minimum: fenceLength) {
                    insideFence = false
                }
            } else if let (character, length) = fenceOpen(line) {
                insideFence = true
                fenceChar = character
                fenceLength = length
            }
        }

        guard insideFence else { return text }

        var index = lines.count - 1
        while index >= 0, isAllWhitespace(lines[index]) { index -= 1 }
        guard index >= 0 else { return text }

        let candidate = stripLeadingSpaces(lines[index], upTo: 3)
        guard !candidate.isEmpty,
              candidate.count < fenceLength,
              candidate.allSatisfy({ $0 == fenceChar }) else {
            return text
        }
        return lines[0..<index].joined(separator: "\n")
    }
}

// MARK: - Fence scanning helpers

/// A code-fence opener at the start of `line` (after up to three leading spaces):
/// three or more backticks or tildes. Returns the fence character and run length.
private func fenceOpen(_ line: String) -> (Character, Int)? {
    let trimmed = stripLeadingSpaces(line, upTo: 3)
    guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
    var count = 0
    for character in trimmed {
        if character == first { count += 1 } else { break }
    }
    return count >= 3 ? (first, count) : nil
}

/// Whether `line` closes a fence of `character`: a run of at least `minimum` of
/// that character (after up to three leading spaces) followed only by whitespace.
private func isFenceClose(_ line: String, _ character: Character, minimum: Int) -> Bool {
    let trimmed = stripLeadingSpaces(line, upTo: 3)
    var count = 0
    var rest = trimmed[trimmed.startIndex...]
    while let first = rest.first, first == character {
        count += 1
        rest = rest.dropFirst()
    }
    guard count >= minimum else { return false }
    return rest.allSatisfy { $0 == " " || $0 == "\t" }
}

private func stripLeadingSpaces(_ line: String, upTo maximum: Int) -> String {
    var dropped = 0
    var index = line.startIndex
    while dropped < maximum, index < line.endIndex, line[index] == " " {
        index = line.index(after: index)
        dropped += 1
    }
    return String(line[index...])
}

private func isAllWhitespace(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
}

private extension String {
    func trimmingWhitespace() -> String {
        var chars = Array(self)
        while let first = chars.first, first == " " || first == "\t" || first == "\n" || first == "\r" {
            chars.removeFirst()
        }
        while let last = chars.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            chars.removeLast()
        }
        return String(chars)
    }
}
