// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/autocomplete.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The token-boundary detection, the
// `@`/`/` prefix parsing, the completion-value construction (quoting, trailing
// slash on directories, `@`-prefix reattachment), and the apply-completion cursor
// arithmetic are ported from pi's `CombinedAutocompleteProvider`.
//
// Two deliberate divergences from pi are structural, both asked for by the port
// brief:
//
//   1. pi's provider is one monolith that reads the filesystem itself (readdirSync
//      + a spawned `fd`). This split it into a ``CombinedAutocompleteProvider``
//      that *composes* independent sub-providers, and made file listing a single
//      injected ``DirectoryLister`` closure so the engine does zero I/O and stays
//      pure and testable — the CLI wires the real lister in later.
//   2. Cancellation is an injected ``CancellationSignal`` (pi's `AbortSignal`
//      shape) rather than JS's `AbortController`, checked around the one awaited
//      hop (the lister call).
//
// Columns are grapheme (`Character`) offsets, never UTF-16 code-unit offsets — the
// editor addresses its `[[Character]]` buffer the same way, so none of pi's
// UTF-16 slice arithmetic is ported.

// Explicit, though `trimmingCharacters(in:)` currently resolves via a transitive
// re-export: this file depends on Foundation and should say so, not rely on a
// dependency continuing to leak it.
import Foundation

// MARK: - Value model

/// One completion candidate: the text to insert (`value`), what to show in the
/// popup (`label`), and an optional second-column `description`.
///
/// A `Sendable` value type so a lister or ranker can build a batch off the main
/// actor and hand it back. Distinct from ``SelectItem`` — that is the list
/// widget's row model; a popup maps these to those at render time, keeping the
/// completion engine free of any renderer dependency.
public nonisolated struct AutocompleteItem: Sendable, Equatable {
    public var value: String
    public var label: String
    public var description: String?

    public init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

/// A provider's answer: the ranked ``items`` plus the ``prefix`` they were matched
/// against (e.g. `"/co"` or `"@src/"`).
///
/// ``prefix`` is load-bearing, not informational: ``AutocompleteProvider/applyCompletion``
/// needs to know how many characters before the cursor to replace, and pi carries
/// exactly this pair for the same reason.
public nonisolated struct AutocompleteSuggestions: Sendable, Equatable {
    public var items: [AutocompleteItem]
    public var prefix: String

    public init(items: [AutocompleteItem], prefix: String) {
        self.items = items
        self.prefix = prefix
    }
}

/// The edit ``AutocompleteProvider/applyCompletion`` produces: the whole new line
/// set and where the caret lands. `cursorCol` is a grapheme offset into
/// `lines[cursorLine]`.
public nonisolated struct AutocompleteResult: Sendable, Equatable {
    public var lines: [String]
    public var cursorLine: Int
    public var cursorCol: Int

    public init(lines: [String], cursorLine: Int, cursorCol: Int) {
        self.lines = lines
        self.cursorLine = cursorLine
        self.cursorCol = cursorCol
    }
}

// MARK: - Cancellation

/// A cooperative cancellation flag threaded through an async suggestion request.
///
/// pi passes a DOM `AbortSignal`; the Swift shape is a `Sendable` box around a
/// `@Sendable () -> Bool` so a caller can wire it to a `Task`'s cancellation
/// (`.init { Task.isCancelled }`), a manual flag, or — in tests — a fixed value.
/// A provider polls ``isCancelled`` around its one awaited hop and bails to `nil`
/// so a superseded keystroke's lookup cannot clobber a newer one.
public nonisolated struct CancellationSignal: Sendable {
    private let flag: @Sendable () -> Bool

    public init(isCancelled: @escaping @Sendable () -> Bool) {
        self.flag = isCancelled
    }

    public var isCancelled: Bool { flag() }

    /// A signal that never cancels — the default for callers that don't debounce.
    public static let none = CancellationSignal { false }
}

// MARK: - Directory listing seam

/// One entry a ``DirectoryLister`` reports: a bare `name` and whether it is a
/// directory. No path, no stat — the provider composes paths itself.
public nonisolated struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// The one filesystem seam: given a directory path (as the user typed it, e.g.
/// `""`, `"src/"`, `"~/notes/"`), return its immediate children.
///
/// `async` so a real implementation can shell out to `fd` or hit the disk off the
/// main actor; `@Sendable` so it can. Tests pass a pure closure over a fake tree,
/// which is the whole point of the seam — the engine never imports `Foundation`
/// or touches a disk.
public typealias DirectoryLister = @Sendable (String) async -> [DirectoryEntry]

// MARK: - Provider protocol

/// A source of completions for the text before the cursor.
///
/// ``getSuggestions`` returns `nil` when this provider has nothing to offer at the
/// cursor (wrong trigger, no match), which is how ``CombinedAutocompleteProvider``
/// chains providers — first non-`nil` wins. ``applyCompletion`` likewise returns
/// `nil` when a `prefix` isn't one this provider produced, so the combined
/// provider can route an accepted item back to its author.
public protocol AutocompleteProvider: AnyObject {
    /// Characters that naturally open this provider at a token boundary (`"@"`,
    /// `"/"`). Advisory — used by a caller to decide when to fire a lookup.
    var triggerCharacters: [Character] { get }

    /// Suggestions for the cursor at `(cursorLine, cursorCol)`, or `nil` if this
    /// provider doesn't apply there. `force` is an explicit Tab request; `signal`
    /// lets a superseded request abandon its awaited work.
    func getSuggestions(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        force: Bool,
        signal: CancellationSignal
    ) async -> AutocompleteSuggestions?

    /// Apply `item` (chosen for `prefix`), returning the new lines and caret, or
    /// `nil` if `prefix` isn't this provider's.
    func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> AutocompleteResult?

    /// Whether an explicit Tab should open file completion here. Default `false`.
    func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool
}

public extension AutocompleteProvider {
    var triggerCharacters: [Character] { [] }
    func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool { false }
}

// MARK: - Shared cursor helpers

/// The substring of `lines[cursorLine]` left of a grapheme-indexed cursor.
///
/// Everything upstream reasons in `Character` offsets; converting to `[Character]`
/// once here is what keeps a cursor from ever landing mid-grapheme. Out-of-range
/// indices clamp rather than trap so a provider is never the thing that crashes on
/// a stale `(line, col)`.
private func textBeforeCursor(_ lines: [String], _ cursorLine: Int, _ cursorCol: Int) -> [Character] {
    guard cursorLine >= 0, cursorLine < lines.count else { return [] }
    let characters = Array(lines[cursorLine])
    let end = max(0, min(cursorCol, characters.count))
    return Array(characters[0..<end])
}

/// Splice `insertion` in place of the `prefixLength` characters ending at the
/// cursor, appending `suffix`, and report the caret's new grapheme column.
///
/// The one place lines are rebuilt on accept: both providers funnel through it so
/// the "replace the prefix, keep the tail, place the caret" arithmetic exists once.
private func spliceCompletion(
    lines: [String],
    cursorLine: Int,
    cursorCol: Int,
    prefixLength: Int,
    insertion: String,
    suffix: String,
    cursorAfterInsertionOffset: Int
) -> AutocompleteResult {
    guard cursorLine >= 0, cursorLine < lines.count else {
        return AutocompleteResult(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
    }
    let characters = Array(lines[cursorLine])
    let cursor = max(0, min(cursorCol, characters.count))
    let prefixStart = max(0, cursor - prefixLength)
    let before = Array(characters[0..<prefixStart])
    let after = Array(characters[cursor...])

    let newLine = String(before) + insertion + suffix + String(after)
    var newLines = lines
    newLines[cursorLine] = newLine

    let newCol = before.count + cursorAfterInsertionOffset + suffix.count
    return AutocompleteResult(lines: newLines, cursorLine: cursorLine, cursorCol: newCol)
}

// MARK: - Token-boundary parsing (ported from pi)

/// pi's `PATH_DELIMITERS`: the characters that end a path token.
private let pathDelimiters: Set<Character> = [" ", "\t", "\"", "'", "="]

/// Index of the last delimiter in `characters`, or `-1`. Ports pi's
/// `findLastDelimiter`.
private func lastDelimiterIndex(_ characters: [Character]) -> Int {
    var i = characters.count - 1
    while i >= 0 {
        if pathDelimiters.contains(characters[i]) { return i }
        i -= 1
    }
    return -1
}

/// True if `index` begins a fresh token (line start or right after a delimiter).
/// Ports pi's `isTokenStart`.
private func isTokenStart(_ characters: [Character], _ index: Int) -> Bool {
    index == 0 || (index > 0 && pathDelimiters.contains(characters[index - 1]))
}

// MARK: - Slash-command provider

/// A slash command in the static palette: its `name`, an optional one-line
/// `description`, and an optional `argumentHint` shown before the description.
///
/// pi's `SlashCommand` also carries `getArgumentCompletions` for per-command
/// argument suggestion; that is intentionally **left out** here (see the file
/// report) — this provider completes the command *name* only.
public nonisolated struct SlashCommand: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var argumentHint: String?

    public init(name: String, description: String? = nil, argumentHint: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }
}

/// Completes `/command` names at the start of the current line.
///
/// Fires only for a leading `/` with no space yet (the command-name context), and
/// never under an explicit Tab (`force`) — pi reserves Tab for file completion.
/// Names are ranked by ``fuzzyFilter(_:query:getText:)`` so `/cmp` finds
/// `/compact`.
public final class SlashCommandProvider: AutocompleteProvider {
    private let commands: [SlashCommand]

    public init(commands: [SlashCommand]) {
        self.commands = commands
    }

    public var triggerCharacters: [Character] { ["/"] }

    public func getSuggestions(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        force: Bool,
        signal: CancellationSignal
    ) async -> AutocompleteSuggestions? {
        // Tab (force) is reserved for file completion, matching pi's guard.
        if force { return nil }

        let before = textBeforeCursor(lines, cursorLine, cursorCol)
        guard before.first == "/" else { return nil }
        // A space ends the command name; argument completion is out of scope here.
        guard !before.contains(" ") else { return nil }

        let query = String(before.dropFirst())
        let ranked = fuzzyFilter(commands, query: query, getText: { $0.name })
        if ranked.isEmpty { return nil }

        let items = ranked.map { result -> AutocompleteItem in
            let command = result.item
            let description = Self.describe(command)
            return AutocompleteItem(value: command.name, label: command.name, description: description)
        }
        return AutocompleteSuggestions(items: items, prefix: String(before))
    }

    public func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> AutocompleteResult? {
        // Ours iff the prefix is a leading slash-command token: starts with "/",
        // nothing but whitespace before it, and no path separator inside it.
        guard prefix.first == "/" else { return nil }
        let before = textBeforeCursor(lines, cursorLine, cursorCol)
        let beforePrefix = before.dropLast(min(Array(prefix).count, before.count))
        guard String(beforePrefix).trimmingCharacters(in: [" ", "\t"]).isEmpty else { return nil }
        guard !prefix.dropFirst().contains("/") else { return nil }

        // Insert "/name " and drop the caret after the trailing space.
        let insertion = "/" + item.value
        return spliceCompletion(
            lines: lines,
            cursorLine: cursorLine,
            cursorCol: cursorCol,
            prefixLength: Array(prefix).count,
            insertion: insertion,
            suffix: " ",
            cursorAfterInsertionOffset: Array(insertion).count
        )
    }

    /// Fold `argumentHint` and `description` into the popup's second column,
    /// matching pi's `hint — desc` composition.
    private static func describe(_ command: SlashCommand) -> String? {
        let hint = command.argumentHint
        let desc = command.description ?? ""
        if let hint, !hint.isEmpty {
            return desc.isEmpty ? hint : "\(hint) — \(desc)"
        }
        return desc.isEmpty ? nil : desc
    }
}

// MARK: - File-completion provider

/// Completes `@`-prefixed file paths against an injected ``DirectoryLister``.
///
/// Recognizes an `@` (optionally `@"`) token at a delimiter boundary, splits the
/// path into a directory to list and a trailing segment to match, ranks the
/// directory's children by ``fuzzyMatch(_:_:)`` (directories first), and builds
/// completion values that re-attach the `@`, keep quotes balanced, and add a
/// trailing slash to directories. All path *listing* is delegated; this type does
/// no I/O.
public final class FileCompletionProvider: AutocompleteProvider {
    private let lister: DirectoryLister
    private let maxResults: Int

    public init(lister: @escaping DirectoryLister, maxResults: Int = 50) {
        self.lister = lister
        self.maxResults = maxResults
    }

    public var triggerCharacters: [Character] { ["@"] }

    public func getSuggestions(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        force: Bool,
        signal: CancellationSignal
    ) async -> AutocompleteSuggestions? {
        let before = textBeforeCursor(lines, cursorLine, cursorCol)
        guard let atPrefix = Self.extractAtPrefix(before) else { return nil }
        if signal.isCancelled { return nil }

        let parsed = Self.parseAtPrefix(atPrefix)
        let scope = Self.splitPath(parsed.rawPath)

        let entries = await lister(scope.directory)
        if signal.isCancelled { return nil }

        let items = Self.rank(entries, query: scope.segment).prefix(maxResults).map { entry in
            Self.buildItem(entry, displayBase: scope.displayBase, isQuoted: parsed.isQuoted)
        }
        if items.isEmpty { return nil }

        return AutocompleteSuggestions(items: Array(items), prefix: atPrefix)
    }

    public func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> AutocompleteResult? {
        guard prefix.first == "@" else { return nil }

        // No space after a directory so the user can keep drilling in; a space
        // after a file terminates the token. Ports pi's `@`-branch suffix rule.
        let isDirectory = item.label.hasSuffix("/")
        let suffix = isDirectory ? "" : " "

        // When the completion ends in a closing quote and the item is a directory,
        // pi parks the caret just before that quote so typing continues inside it.
        let hasTrailingQuote = item.value.hasSuffix("\"")
        let insertionCount = Array(item.value).count
        let caretOffset = (isDirectory && hasTrailingQuote) ? insertionCount - 1 : insertionCount

        return spliceCompletion(
            lines: lines,
            cursorLine: cursorLine,
            cursorCol: cursorCol,
            prefixLength: Array(prefix).count,
            insertion: item.value,
            suffix: suffix,
            cursorAfterInsertionOffset: caretOffset
        )
    }

    public func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        true
    }

    // MARK: Prefix extraction

    /// The `@…` token ending at the cursor, or `nil`. Handles an unclosed `@"`
    /// quote as well as a bare `@` at a token boundary. Ports pi's
    /// `extractAtPrefix` (its `extractQuotedPrefix` fast path folded in).
    static func extractAtPrefix(_ characters: [Character]) -> String? {
        // Unclosed quote opened by `@"`: an odd number of quotes leaves one open,
        // and if `@` sits just before it at a token start, the token is the whole
        // `@"…` tail.
        if let quoteStart = unclosedQuoteStart(characters),
            quoteStart > 0,
            characters[quoteStart - 1] == "@",
            isTokenStart(characters, quoteStart - 1) {
            return String(characters[(quoteStart - 1)...])
        }

        let delimiter = lastDelimiterIndex(characters)
        let tokenStart = delimiter == -1 ? 0 : delimiter + 1
        guard tokenStart < characters.count, characters[tokenStart] == "@" else { return nil }
        return String(characters[tokenStart...])
    }

    /// Start index of an unclosed double quote, or `nil`. Ports pi's
    /// `findUnclosedQuoteStart`.
    private static func unclosedQuoteStart(_ characters: [Character]) -> Int? {
        var inQuotes = false
        var start = -1
        for (i, character) in characters.enumerated() where character == "\"" {
            inQuotes.toggle()
            if inQuotes { start = i }
        }
        return inQuotes ? start : nil
    }

    /// Peel the leading `@` (and an optional opening quote) off a token, reporting
    /// the raw path and whether the token was quoted. Ports pi's `parsePathPrefix`
    /// for the `@` cases.
    static func parseAtPrefix(_ prefix: String) -> (rawPath: String, isQuoted: Bool) {
        if prefix.hasPrefix("@\"") { return (String(prefix.dropFirst(2)), true) }
        if prefix.hasPrefix("@") { return (String(prefix.dropFirst()), false) }
        return (prefix, false)
    }

    // MARK: Path scoping

    /// Split a raw path into the directory to list, the trailing segment to match,
    /// and the base string to re-prepend to each result for display.
    ///
    /// `"src/comp"` → list `"src/"`, match `"comp"`, display base `"src/"`.
    /// `"comp"` → list `""` (the anchor the lister resolves), match `"comp"`, no
    /// base. A trailing slash means "list this directory, match everything".
    static func splitPath(_ rawPath: String) -> (directory: String, segment: String, displayBase: String) {
        let characters = Array(rawPath)
        guard let slash = characters.lastIndex(of: "/") else {
            return (directory: "", segment: rawPath, displayBase: "")
        }
        let base = String(characters[0...slash])
        let segment = String(characters[(slash + 1)...])
        return (directory: base, segment: segment, displayBase: base)
    }

    // MARK: Ranking

    /// Rank a directory's children against `segment`: fuzzy-matched only (all when
    /// `segment` is empty), directories first, then better fuzzy score, then name.
    ///
    /// DIVERGENCE: pi's `readdirSync` branch filters by case-insensitive *prefix*;
    /// this uses ``fuzzyMatch(_:_:)`` so the `@` completer is genuinely fuzzy (the
    /// title's promise), with a directory-first tie-break preserved from pi's sort.
    static func rank(_ entries: [DirectoryEntry], query: String) -> [DirectoryEntry] {
        if query.isEmpty {
            return entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCompareLike(rhs.name)
            }
        }

        let scored: [(entry: DirectoryEntry, score: Double)] = entries.compactMap { entry in
            let match = fuzzyMatch(query, entry.name)
            return match.matches ? (entry, match.score) : nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.entry.name.localizedCompareLike(rhs.entry.name)
        }.map(\.entry)
    }

    // MARK: Item construction

    /// Build the completion for one entry: `@`-prefixed value with a trailing
    /// slash on directories and balanced quotes when the token was quoted; label
    /// is the bare name (`+ "/"` for a directory); description is the full path.
    /// Ports pi's `buildCompletionValue` for the `@` case.
    static func buildItem(_ entry: DirectoryEntry, displayBase: String, isQuoted: Bool) -> AutocompleteItem {
        let displayPath = displayBase + entry.name + (entry.isDirectory ? "/" : "")
        let needsQuotes = isQuoted || displayPath.contains(" ")
        let value: String = needsQuotes ? "@\"\(displayPath)\"" : "@\(displayPath)"
        let label = entry.name + (entry.isDirectory ? "/" : "")
        return AutocompleteItem(value: value, label: label, description: displayPath)
    }
}

// MARK: - Combined provider

/// Chains sub-providers into one ``AutocompleteProvider``.
///
/// ``getSuggestions`` returns the first sub-provider's non-`nil` answer (order is
/// priority — slash before file, so `/` at line start never reads as a path).
/// ``applyCompletion`` routes an accepted item back to whichever sub-provider
/// claims its `prefix`. This replaces pi's single monolithic provider with
/// composition, so a host can add or reorder sources without editing one class.
public final class CombinedAutocompleteProvider: AutocompleteProvider {
    private let providers: [AutocompleteProvider]

    public init(providers: [AutocompleteProvider]) {
        self.providers = providers
    }

    /// Convenience for the common `[slash, file]` pairing.
    public convenience init(commands: [SlashCommand], lister: @escaping DirectoryLister) {
        self.init(providers: [
            SlashCommandProvider(commands: commands),
            FileCompletionProvider(lister: lister),
        ])
    }

    public var triggerCharacters: [Character] {
        var seen: Set<Character> = []
        var result: [Character] = []
        for provider in providers {
            for character in provider.triggerCharacters where seen.insert(character).inserted {
                result.append(character)
            }
        }
        return result
    }

    public func getSuggestions(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        force: Bool,
        signal: CancellationSignal
    ) async -> AutocompleteSuggestions? {
        for provider in providers {
            if signal.isCancelled { return nil }
            if let suggestions = await provider.getSuggestions(
                lines: lines,
                cursorLine: cursorLine,
                cursorCol: cursorCol,
                force: force,
                signal: signal
            ) {
                return suggestions
            }
        }
        return nil
    }

    public func applyCompletion(
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        item: AutocompleteItem,
        prefix: String
    ) -> AutocompleteResult? {
        for provider in providers {
            if let result = provider.applyCompletion(
                lines: lines,
                cursorLine: cursorLine,
                cursorCol: cursorCol,
                item: item,
                prefix: prefix
            ) {
                return result
            }
        }
        return nil
    }

    /// pi's rule: don't offer file completion while a slash command name is being
    /// typed (leading `/`, no space yet); otherwise defer to any sub-provider that
    /// wants it.
    public func shouldTriggerFileCompletion(lines: [String], cursorLine: Int, cursorCol: Int) -> Bool {
        let trimmed = String(textBeforeCursor(lines, cursorLine, cursorCol))
            .trimmingCharacters(in: [" ", "\t"])
        if trimmed.hasPrefix("/"), !trimmed.contains(" ") {
            return false
        }
        return providers.contains { $0.shouldTriggerFileCompletion(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol) }
    }
}

// MARK: - Name ordering

private extension String {
    /// A deterministic, locale-independent name order for the directory-first
    /// tie-break: case-insensitive first, case-sensitive to break exact ties, so
    /// the ordering is total and stable across platforms (unlike `localizedCompare`).
    func localizedCompareLike(_ other: String) -> Bool {
        let lhs = lowercased()
        let rhs = other.lowercased()
        if lhs != rhs { return lhs < rhs }
        return self < other
    }
}
