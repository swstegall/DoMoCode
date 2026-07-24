// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/render-utils.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// DoMoTools is headless by design — no TUI import — so a `ToolResult` carries
// only the model-facing text plus structured `details`, and nothing about how it
// is drawn. This module reattaches the rendering that pi keeps inline on each
// tool definition (`renderResult` in `core/tools/*.ts`), turning a result into
// styled terminal lines the transcript can stack.
//
// The registry-of-renderers shape, the per-tool preview line counts, the
// truncation "N more lines" marker, the head/tail bash preview and the styled
// truncation warnings are ported from `core/tools/`. The theme-as-hooks pattern
// (a struct of `(String) -> String` so the palette lives outside the renderer,
// with an identity `.plain` the tests assert exact widths against) follows this
// package's own `SelectListTheme`.

import DoMoCore
import DoMoTUI
import DoMoTools

// MARK: - Theme

/// The style hooks a tool renderer calls to colour the parts of its output.
///
/// Every hook adds only ANSI SGR styling, which has zero visible width, so the
/// width budget the renderer enforces is computed on the styled string and the
/// result still fits — ``truncateToWidth(_:_:ellipsis:pad:)`` is escape-aware and
/// carries the active style across a cut. pi threads a `Theme` object of
/// `(text) -> text` functions through every `renderResult`; this mirrors that so
/// the palette is a caller concern, not baked into the renderers.
///
/// ``plain`` is the identity theme: every hook returns its input unchanged. It is
/// what the tests render against, so a line's visible width is exactly its
/// content width with no escapes to reason about.
public struct ToolRenderTheme: Sendable {
    /// The tool name / command header, e.g. `edit` or `$ ls`. Bold in ``ansi``.
    public var title: @Sendable (String) -> String
    /// A file path or the primary argument. Cyan in ``ansi``.
    public var accent: @Sendable (String) -> String
    /// Ordinary tool output — the body lines.
    public var output: @Sendable (String) -> String
    /// De-emphasized supporting text: the "N more lines" marker, durations.
    public var muted: @Sendable (String) -> String
    /// A non-fatal notice: truncation, limits reached.
    public var warning: @Sendable (String) -> String
    /// An error result's message.
    public var error: @Sendable (String) -> String
    /// An added diff line (`+`). Green in ``ansi``.
    public var diffAdded: @Sendable (String) -> String
    /// A removed diff line (`-`). Red in ``ansi``.
    public var diffRemoved: @Sendable (String) -> String
    /// A diff context line (unchanged). Dim in ``ansi``.
    public var diffContext: @Sendable (String) -> String
    /// The intra-line highlight on the changed tokens of a modified line.
    public var inverse: @Sendable (String) -> String

    public init(
        title: @escaping @Sendable (String) -> String,
        accent: @escaping @Sendable (String) -> String,
        output: @escaping @Sendable (String) -> String,
        muted: @escaping @Sendable (String) -> String,
        warning: @escaping @Sendable (String) -> String,
        error: @escaping @Sendable (String) -> String,
        diffAdded: @escaping @Sendable (String) -> String,
        diffRemoved: @escaping @Sendable (String) -> String,
        diffContext: @escaping @Sendable (String) -> String,
        inverse: @escaping @Sendable (String) -> String
    ) {
        self.title = title
        self.accent = accent
        self.output = output
        self.muted = muted
        self.warning = warning
        self.error = error
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.diffContext = diffContext
        self.inverse = inverse
    }

    /// The identity theme — every hook returns its input unchanged. The tests
    /// render against this so widths are exact.
    public static let plain = ToolRenderTheme(
        title: { $0 },
        accent: { $0 },
        output: { $0 },
        muted: { $0 },
        warning: { $0 },
        error: { $0 },
        diffAdded: { $0 },
        diffRemoved: { $0 },
        diffContext: { $0 },
        inverse: { $0 }
    )

    /// A concrete ANSI palette approximating pi's default theme. The exact hues
    /// are not load-bearing — the renderers and their width invariant are — so
    /// this is kept deliberately small (a handful of SGR codes) rather than a
    /// full theme port.
    public static let ansi = ToolRenderTheme(
        title: { sgr("1", $0, "22") },
        accent: { sgr("36", $0, "39") },
        output: { $0 },
        muted: { sgr("2", $0, "22") },
        warning: { sgr("33", $0, "39") },
        error: { sgr("31", $0, "39") },
        diffAdded: { sgr("32", $0, "39") },
        diffRemoved: { sgr("31", $0, "39") },
        diffContext: { sgr("2", $0, "22") },
        inverse: { sgr("7", $0, "27") }
    )
}

/// Wraps `text` in an SGR pair — `open` before, `close` after — the one styling
/// primitive the ``ToolRenderTheme/ansi`` hooks are built from. Matches DoMoTUI's
/// own `Markdown` helper of the same shape.
@Sendable
nonisolated func sgr(_ open: String, _ text: String, _ close: String) -> String {
    "\u{1b}[\(open)m\(text)\u{1b}[\(close)m"
}

// MARK: - Request

/// Everything a renderer needs to draw one tool result: the call that produced
/// it, the result itself, and the viewport width every emitted line must fit.
///
/// `arguments` is the raw, model-supplied call — a renderer reads a path or a
/// command out of it for the header exactly as pi's `renderCall` does, defending
/// against the wrong shape. `expanded` mirrors pi's per-result expand toggle: a
/// collapsed result shows a bounded preview, an expanded one shows everything
/// (still width-clipped). `homeDirectory`, when set, is collapsed to `~` in
/// displayed paths, matching `shortenPath`.
public struct ToolRenderRequest: Sendable {
    public var toolName: String
    public var arguments: JSONValue
    public var result: ToolResult
    public var width: Int
    public var theme: ToolRenderTheme
    public var expanded: Bool
    public var homeDirectory: String?

    public init(
        toolName: String,
        arguments: JSONValue,
        result: ToolResult,
        width: Int,
        theme: ToolRenderTheme = .plain,
        expanded: Bool = false,
        homeDirectory: String? = nil
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.width = width
        self.theme = theme
        self.expanded = expanded
        self.homeDirectory = homeDirectory
    }
}

// MARK: - Renderer

/// Turns one tool result into styled terminal lines that fit ``ToolRenderRequest/width``.
///
/// A renderer **must** keep every returned line within the requested width — the
/// differential renderer treats an over-wide line as fatal because one stray
/// column shifts every cell after it. Every line here is therefore built through
/// ``clip(_:to:)`` (a width-aware, escape-aware truncation), so the contract is
/// upheld by construction rather than by hope.
///
/// The protocol returns `[String]` rather than a `Component` so it stays pure and
/// off-actor: it is trivially testable (assert widths on the array) and does not
/// touch the render loop. ``ToolResultView`` adapts a registry into a `Component`
/// for the transcript when one is wanted.
public protocol ToolRenderer: Sendable {
    func render(_ request: ToolRenderRequest) -> [String]
}

// MARK: - Registry

/// Maps a tool name to the renderer that draws its results, with a fallback for
/// names it does not know.
///
/// pi attaches `renderResult` to each tool definition; here the drawing is split
/// out of the headless tool and re-associated by name. An unknown tool is not an
/// error — a locally-registered or model-invented tool still has *some* text
/// result — so it falls through to ``DefaultToolRenderer``, which shows a
/// truncated text dump. Registration order is irrelevant: lookup is by name.
public struct ToolRendererRegistry: Sendable {
    private var byName: [String: any ToolRenderer]
    private let fallback: any ToolRenderer

    public init(default fallback: any ToolRenderer = DefaultToolRenderer()) {
        self.byName = [:]
        self.fallback = fallback
    }

    /// Registers `renderer` for `name`, replacing any existing one.
    public mutating func register(_ name: String, _ renderer: any ToolRenderer) {
        byName[name] = renderer
    }

    /// The renderer for `name`, or the fallback when none is registered.
    public func renderer(for name: String) -> any ToolRenderer {
        byName[name] ?? fallback
    }

    /// Renders `result` with the renderer for `toolName`.
    public func render(
        toolName: String,
        arguments: JSONValue,
        result: ToolResult,
        width: Int,
        theme: ToolRenderTheme = .plain,
        expanded: Bool = false,
        homeDirectory: String? = nil
    ) -> [String] {
        renderer(for: toolName).render(
            ToolRenderRequest(
                toolName: toolName,
                arguments: arguments,
                result: result,
                width: width,
                theme: theme,
                expanded: expanded,
                homeDirectory: homeDirectory
            )
        )
    }

    /// The renderers for pi's seven built-in tools, keyed by their stable names.
    public static var builtin: ToolRendererRegistry {
        var registry = ToolRendererRegistry()
        registry.register("read", ReadToolRenderer())
        registry.register("write", WriteToolRenderer())
        registry.register("edit", EditToolRenderer())
        registry.register("bash", BashToolRenderer())
        registry.register("grep", GrepToolRenderer())
        registry.register("find", FindToolRenderer())
        registry.register("ls", LsToolRenderer())
        return registry
    }
}

// MARK: - Default renderer

/// The fallback for an unknown tool: a styled header and a truncated dump of the
/// result text.
///
/// Mirrors what pi does for a tool without a bespoke `renderResult` — there is
/// always text to show, so show a bounded, width-safe preview of it. An error
/// result is styled distinctly.
public struct DefaultToolRenderer: ToolRenderer {
    /// Lines shown before the "N more lines" marker when collapsed. Matches the
    /// mid-range of pi's per-tool preview budgets.
    static let previewLines = 15

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let header = clip(theme.title(request.toolName), to: request.width)
        if request.result.isError {
            return [header] + errorLines(request)
        }
        var lines = [header]
        lines.append(
            contentsOf: bodyLines(
                request.result.text,
                width: request.width,
                maxLines: Self.previewLines,
                expanded: request.expanded,
                theme: theme
            )
        )
        return lines
    }
}

// MARK: - Component adapter

/// A `Component` that draws a tool result through a ``ToolRendererRegistry`` at
/// whatever width the transcript hands it.
///
/// This is the "or a `Component`" half of the deliverable. It holds everything
/// except the width and re-renders on each `render(width:)`, so it stays correct
/// across a terminal resize — the registry is asked for lines at the *current*
/// width every frame. `@MainActor` because a `Component` is MainActor by
/// DoMoTUI's module rule; the renderers it calls are pure and isolation-free.
@MainActor
public final class ToolResultView: Component {
    private let registry: ToolRendererRegistry
    private let toolName: String
    private let arguments: JSONValue
    private let result: ToolResult
    private let theme: ToolRenderTheme
    private let homeDirectory: String?

    /// Whether the result is drawn in full. The transcript flips this on a
    /// key hint; the change is picked up on the next render.
    public var expanded: Bool

    public init(
        registry: ToolRendererRegistry,
        toolName: String,
        arguments: JSONValue,
        result: ToolResult,
        theme: ToolRenderTheme = .plain,
        expanded: Bool = false,
        homeDirectory: String? = nil
    ) {
        self.registry = registry
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.theme = theme
        self.expanded = expanded
        self.homeDirectory = homeDirectory
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        return registry.render(
            toolName: toolName,
            arguments: arguments,
            result: result,
            width: width,
            theme: theme,
            expanded: expanded,
            homeDirectory: homeDirectory
        )
    }
}

// MARK: - Shared rendering helpers

/// Clips `line` to `width` visible columns, appending an ellipsis when it does
/// not fit. This is the single choke point through which every emitted line
/// passes, and the reason no renderer here can produce the over-wide line the
/// differential renderer treats as fatal: ``truncateToWidth(_:_:ellipsis:pad:)``
/// is escape-aware, so a styled line is measured and cut on its *visible* width.
///
/// A returned array element is one terminal *row*, so any embedded newline or
/// carriage return is first flattened to a space: the differential renderer
/// writes each element with a single `buffer += line` and accounts it as exactly
/// one row, but `visibleWidth` measures a bare `\n`/`\r` as zero columns — so an
/// embedded newline would pass the width check yet make the terminal advance a
/// row, desynchronising the renderer's cursor accounting. Body previews already
/// split on `\n`, but a header built straight from a model-supplied argument (a
/// multi-line `bash` command, a path or pattern carrying a newline) reaches here
/// with the newline intact, and this is where it is neutralised.
nonisolated func clip(_ line: String, to width: Int) -> String {
    truncateToWidth(flattenToSingleRow(line), width)
}

/// Collapses every carriage return / line feed in `text` to a single space so the
/// result occupies exactly one terminal row. `\r\n` collapses to one space rather
/// than two.
nonisolated func flattenToSingleRow(_ text: String) -> String {
    guard text.contains(where: { $0 == "\n" || $0 == "\r" }) else { return text }
    return
        text
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

/// Expands tabs to three spaces, matching DoMoTUI's ``tabColumnWidth`` and pi's
/// `replaceTabs`. A variable-width tab would make a line's width depend on its
/// column, which the fixed-width measure cannot see; expanding first keeps the
/// measure exact.
nonisolated func replaceTabs(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: "   ")
}

/// Strips carriage returns so a `\r\n` or bare `\r` in tool output does not draw
/// a stray control or reset the cursor mid-line. Ports pi's `normalizeDisplayText`.
nonisolated func stripCarriageReturns(_ text: String) -> String {
    text.replacingOccurrences(of: "\r", with: "")
}

/// Drops trailing empty lines from `lines`, matching pi's `trimTrailingEmptyLines`.
/// A file or command output that ends in newlines otherwise draws a run of blank
/// rows the reader did not ask for.
nonisolated func trimTrailingEmptyLines(_ lines: [String]) -> [String] {
    var result = lines
    while let last = result.last, last.isEmpty {
        result.removeLast()
    }
    return result
}

/// Styles one body line: a trailing bracketed notice (`[Truncated: …]`) is drawn
/// with the warning hook so a limit or truncation reads distinctly, everything
/// else with the output hook. Ports the effect of pi re-styling its truncation
/// warnings — the Swift tools bake the notice into the result text, so it is
/// recognized here by shape rather than rebuilt from `details`.
private nonisolated func styleBodyLine(_ line: String, theme: ToolRenderTheme) -> String {
    if line.hasPrefix("[") && line.hasSuffix("]") && line.count > 1 {
        return theme.warning(line)
    }
    return theme.output(line)
}

/// Splits `text` into head-bounded, width-clipped, styled body lines with a
/// muted "N more lines" marker when collapsed output was cut.
///
/// This is the shape shared by read, write, grep, find, ls and the default
/// renderer: normalize, expand tabs, drop trailing blanks, keep at most
/// `maxLines` (all of them when `expanded`), style, and clip. The marker itself
/// is clipped too, so even a narrow viewport cannot make it overflow.
nonisolated func bodyLines(
    _ text: String,
    width: Int,
    maxLines: Int,
    expanded: Bool,
    theme: ToolRenderTheme
) -> [String] {
    let normalized = replaceTabs(stripCarriageReturns(text))
    let allLines = trimTrailingEmptyLines(normalized.components(separatedBy: "\n"))
    guard !allLines.isEmpty else { return [] }

    let shownCount = expanded ? allLines.count : min(maxLines, allLines.count)
    var result = allLines.prefix(shownCount).map { clip(styleBodyLine($0, theme: theme), to: width) }

    let remaining = allLines.count - shownCount
    if remaining > 0 {
        result.append(clip(theme.muted("... (\(remaining) more lines)"), to: width))
    }
    return result
}

/// Splits `text` into a *tail*-bounded preview: at most `maxLines` of the last
/// lines, preceded by a muted "N earlier lines" marker when the head was cut.
///
/// Ports pi's bash preview (`truncateToVisualLines` keeping the final
/// `BASH_PREVIEW_LINES`), where the end of a command's output is what the reader
/// wants to see. Line-oriented rather than pi's visual-line (post-wrap)
/// oriented: every line is clipped to a single row, so a logical line is one
/// preview line here, which keeps the count stable and the widths exact.
nonisolated func tailBodyLines(
    _ text: String,
    width: Int,
    maxLines: Int,
    expanded: Bool,
    theme: ToolRenderTheme
) -> [String] {
    let normalized = replaceTabs(stripCarriageReturns(text))
    let allLines = trimTrailingEmptyLines(normalized.components(separatedBy: "\n"))
    guard !allLines.isEmpty else { return [] }

    if expanded || allLines.count <= maxLines {
        return allLines.map { clip(styleBodyLine($0, theme: theme), to: width) }
    }

    let skipped = allLines.count - maxLines
    var result = [clip(theme.muted("... (\(skipped) earlier lines)"), to: width)]
    result.append(contentsOf: allLines.suffix(maxLines).map { clip(styleBodyLine($0, theme: theme), to: width) })
    return result
}

/// The lines of an error result: the message, each line styled with the error
/// hook and clipped. Kept separate so every renderer reports a failure the same
/// distinct way, per the "an error result is styled distinctly" requirement.
nonisolated func errorLines(_ request: ToolRenderRequest) -> [String] {
    let theme = request.theme
    let text = replaceTabs(stripCarriageReturns(request.result.text))
    let lines = trimTrailingEmptyLines(text.components(separatedBy: "\n"))
    if lines.isEmpty {
        return [clip(theme.error("[error]"), to: request.width)]
    }
    return lines.map { clip(theme.error($0), to: request.width) }
}

// MARK: - Argument / path helpers

/// The string value at the first present key among `keys`, defending against the
/// wrong shape exactly as pi's `str()` does: an absent (or null) key yields `""`
/// so the caller can apply its empty-fallback, while a *present* non-string
/// yields `nil` so the caller can render an "[invalid arg]" marker. Aliases are
/// tried in order, mirroring pi's `args?.file_path ?? args?.path`.
nonisolated func argString(_ arguments: JSONValue, _ keys: String...) -> String? {
    for key in keys {
        guard let value = arguments[key], value != .null else { continue }
        return value.stringValue
    }
    return ""
}

/// The integer value at `key`, accepting a numeric string, or `nil`. Used for a
/// read call's `offset`/`limit` line-range hint.
nonisolated func argInt(_ arguments: JSONValue, _ key: String) -> Int? {
    guard let value = arguments[key], value != .null else { return nil }
    if let int = value.intValue { return int }
    if let string = value.stringValue { return Int(string.trimmingCharacters(in: .whitespaces)) }
    return nil
}

/// Collapses a leading home-directory prefix to `~`, matching pi's `shortenPath`.
/// A `nil` home leaves the path untouched.
nonisolated func shortenPath(_ path: String, home: String?) -> String {
    guard let home, !home.isEmpty, path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
}

/// Renders the path portion of a header: the accent-styled, home-shortened path,
/// or an "[invalid arg]" marker when the argument was present but not a string,
/// or a muted `...` when it is absent. Ports `renderToolPath`.
nonisolated func renderToolPath(
    _ rawPath: String?,
    theme: ToolRenderTheme,
    home: String?,
    emptyFallback: String = ""
) -> String {
    guard let rawPath else { return theme.error("[invalid arg]") }
    let value = rawPath.isEmpty ? emptyFallback : rawPath
    guard !value.isEmpty else { return theme.muted("...") }
    return theme.accent(shortenPath(value, home: home))
}
