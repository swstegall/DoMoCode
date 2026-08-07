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
///
/// ``insertion`` exists because `value` is not always the literal text that should
/// land in the document. The unified palette lists three kinds of entry side by
/// side — slash commands, tools and agents — and only the first two are *spelled*
/// with a leading `/`. Deriving the spelling at accept time (`"/" + value`) is what
/// produced `"//read"`, so the spelling is decided once, by whoever built the item,
/// and carried here. `nil` keeps the historical behavior for every producer that
/// has not been taught about it.
///
/// `value` is also the item's IDENTITY: every consumer of a popup hands back the
/// row's value and looks the item up with `items.first { $0.value == chosen }`, so
/// two items sharing a value are one item as far as any of them can tell — the
/// second row is unselectable and choosing it applies the first row's insertion.
/// A producer that can emit two different entries under one name (a `plan`
/// command beside a `plan` agent profile, which a default install really has) must
/// therefore make `value` carry whatever distinguishes them; ``SlashCommandProvider``
/// uses the spelling, exactly as ``FileCompletionProvider`` always has.
public nonisolated struct AutocompleteItem: Sendable, Equatable {
    public var value: String
    public var label: String
    public var description: String?
    /// The literal text to splice when this item is accepted; `nil` means "derive
    /// it the way this provider always has".
    public var insertion: String?

    public init(value: String, label: String, description: String? = nil, insertion: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
        self.insertion = insertion
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

// MARK: - Token splice

/// The boundary test for ``spliceTokenAtCursor``: whitespace only.
///
/// Deliberately narrower than the path-delimiter set above. A command, tool or
/// agent name is a bare word; a quote or `=` sitting next to one is text the user
/// typed, not a seam the palette gets to cut on. `nonisolated` because the public
/// splice is — see below.
private nonisolated func isPaletteTokenDelimiter(_ character: Character) -> Bool {
    character == " " || character == "\t"
}

/// The half-open range of the whitespace-delimited token `cursor` sits in.
///
/// Factored out because three callers need the SAME boundary — the splice, the
/// token query the palette decides its gesture on, and (through the query) the
/// prompt's insert-at-caret path. Two copies of a two-directional scan is how one
/// of them ends up treating a tab as a boundary and another one not.
///
/// `cursor` must already be clamped into `0...characters.count`.
private nonisolated func paletteTokenRange(_ characters: [Character], _ cursor: Int) -> Range<Int> {
    var start = cursor
    while start > 0, !isPaletteTokenDelimiter(characters[start - 1]) { start -= 1 }
    var end = cursor
    while end < characters.count, !isPaletteTokenDelimiter(characters[end]) { end += 1 }
    return start..<end
}

/// The whitespace-delimited token the caret sits in, or `""` when the caret sits
/// on a boundary (or the coordinates are stale).
///
/// The palette needs this to tell two GESTURES apart, which is a distinction the
/// splice itself cannot make. Choosing a row out of a popup the user opened by
/// typing `/` means "replace what I typed to get here"; choosing one out of the
/// ^P palette, opened by a keystroke while the caret sat in the middle of a
/// sentence, means "put this here" — and replacing the token there deletes a word
/// the user wrote. See ``spliceTokenAtCursor`` and ``insertAtCursor``.
///
/// Clamps rather than traps, for the same reason everything else in this file
/// does: the coordinates can come from a superseded keystroke.
public nonisolated func paletteTokenAtCursor(lines: [String], cursorLine: Int, cursorCol: Int) -> String {
    guard cursorLine >= 0, cursorLine < lines.count else { return "" }
    let characters = Array(lines[cursorLine])
    let cursor = max(0, min(cursorCol, characters.count))
    return String(characters[paletteTokenRange(characters, cursor)])
}

/// Insert `insertion` AT the caret, separated from what is already there by one
/// space, leaving every surrounding word intact.
///
/// The counterpart to ``spliceTokenAtCursor``, and the reason both exist: the two
/// palette gestures want opposite things. A popup opened by typing `/` has to
/// CONSUME the token that opened it, or the `/` is doubled. A palette opened by
/// ^P has to consume nothing: the caret is wherever the user was writing, and the
/// pre-palette guarantee was that inserting a command "never destroys text the
/// user has already written". Splicing there turned "please summarize report"
/// into "please summarize /read " — the word `report` deleted with no undo the
/// user knows about, and no trace that anything was removed.
///
/// A trailing space always follows the insertion (the caret lands after it, ready
/// for arguments), matching the splice and the `@` file completion. The leading
/// space is added only when the character before the caret is not already
/// whitespace, so an insertion at the start of a line or right after a space does
/// not acquire a stray one.
///
/// An empty document synthesizes the line the text would have lived on: the
/// editor rejects an empty `lines`, so returning the input unchanged would make
/// the palette look broken rather than empty.
public nonisolated func insertAtCursor(
    lines: [String],
    cursorLine: Int,
    cursorCol: Int,
    insertion: String
) -> AutocompleteResult {
    guard cursorLine >= 0, cursorLine < lines.count else {
        if lines.isEmpty {
            let inserted = Array(insertion) + [" "]
            return AutocompleteResult(lines: [String(inserted)], cursorLine: 0, cursorCol: inserted.count)
        }
        return AutocompleteResult(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
    }

    let characters = Array(lines[cursorLine])
    let cursor = max(0, min(cursorCol, characters.count))
    let before = Array(characters[0..<cursor])
    let after = Array(characters[cursor...])

    let needsSeparator = before.last.map { !isPaletteTokenDelimiter($0) } ?? false
    var inserted: [Character] = needsSeparator ? [" "] : []
    inserted.append(contentsOf: Array(insertion))
    inserted.append(" ")

    var newLines = lines
    newLines[cursorLine] = String(before + inserted + after)
    return AutocompleteResult(
        lines: newLines,
        cursorLine: cursorLine,
        cursorCol: before.count + inserted.count
    )
}

/// Replace the whitespace-delimited token under the caret with `insertion` plus a
/// trailing space, and report the caret's new grapheme column.
///
/// This exists because "append the command to the draft" is the wrong operation at
/// a caret. The palette used to build its edit by concatenating `"/" + name` onto
/// the existing text, so opening the popup by typing `/` and then choosing `/read`
/// produced `"//read "` — a string no command parser accepts. Replacing the token
/// the caret sits in collapses four palette rules into one operation instead of
/// four special cases: a `/` the user already typed is *consumed* by the
/// replacement rather than doubled; an entry spelled with a slash brings its own;
/// an entry invoked by bare name (a tool, an agent) lands without one even though
/// `/` opened the popup; and the words on either side of the token survive.
///
/// The caret may sit in the middle of a token with more text after it (`"/re|ad"`
/// after arrowing back), which is exactly why the scan runs in both directions —
/// replacing only the text *before* the cursor would leave the tail behind as
/// `"/readad"`.
///
/// Coordinates clamp rather than trap, so a stale `(line, col)` from a superseded
/// keystroke can never be the thing that crashes a session. A document with no
/// lines at all synthesizes the single line the text would have lived on:
/// `Editor.applyAutocomplete` rejects an empty `lines` outright, so returning the
/// input unchanged there would make the palette look broken rather than empty.
///
/// `nonisolated` so a non-`MainActor` surface can compute an edit without hopping;
/// it reads nothing but its arguments.
public nonisolated func spliceTokenAtCursor(
    lines: [String],
    cursorLine: Int,
    cursorCol: Int,
    insertion: String
) -> AutocompleteResult {
    // Grapheme arrays throughout: every column in this file is a `Character`
    // offset, and building the new line out of `[Character]` keeps it that way.
    let inserted = Array(insertion) + [" "]

    guard cursorLine >= 0, cursorLine < lines.count else {
        if lines.isEmpty {
            return AutocompleteResult(lines: [String(inserted)], cursorLine: 0, cursorCol: inserted.count)
        }
        return AutocompleteResult(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol)
    }

    let characters = Array(lines[cursorLine])
    let cursor = max(0, min(cursorCol, characters.count))

    let token = paletteTokenRange(characters, cursor)
    let before = Array(characters[0..<token.lowerBound])
    let after = Array(characters[token.upperBound...])

    var newLines = lines
    newLines[cursorLine] = String(before + inserted + after)
    return AutocompleteResult(
        lines: newLines,
        cursorLine: cursorLine,
        cursorCol: before.count + inserted.count
    )
}

// MARK: - Slash-command provider

/// A slash command in the static palette: its `name`, an optional one-line
/// `description`, and an optional `argumentHint` shown before the description.
///
/// pi's `SlashCommand` also carries `getArgumentCompletions` for per-command
/// argument suggestion; that is intentionally **left out** here (see the file
/// report) — this provider completes the command *name* only.
///
/// ``requiresSlash`` and ``kind`` are what let one popup list more than commands.
/// The `/` popup now offers tools and agents alongside slash commands, and an
/// agent is invoked by bare name: `/` is how you *reach* the list, not part of
/// what you insert. `requiresSlash == false` says "this name stands alone", which
/// ``SlashCommandProvider`` turns into an insertion that eats the typed `/` rather
/// than keeping it. ``kind`` is display only — a group label ("command", "tool",
/// "agent", "skill") folded into the description column so a list mixing all four
/// stays readable. Both default to today's meaning so every existing construction
/// site keeps compiling and behaving identically.
public nonisolated struct SlashCommand: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var argumentHint: String?
    /// Whether the inserted text carries a leading `/`. `false` for entries the
    /// model invokes by bare name.
    public var requiresSlash: Bool
    /// A display group shown ahead of the description; `nil` shows nothing.
    public var kind: String?

    public init(
        name: String,
        description: String? = nil,
        argumentHint: String? = nil,
        requiresSlash: Bool = true,
        kind: String? = nil
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.requiresSlash = requiresSlash
        self.kind = kind
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
            // The spelling is decided HERE, once, by the side that knows whether
            // this entry is a slash command or a bare name — not derived at accept
            // time from `value`, which is how `"//read"` happened.
            let insertion = command.requiresSlash ? "/" + command.name : command.name
            // The row is LABELLED with what it will insert, not with the bare
            // name. In a list that mixes slash commands, tools and agents, the
            // spelling is the one thing the user cannot infer from the name — and
            // a row reading `explore` in a popup opened by typing `/` is precisely
            // how a user learns the `/` is about to be eaten, before pressing
            // Enter rather than after.
            //
            // `value` is the spelling too, and that is a fix rather than tidiness.
            // `value` is the identity every consumer resolves a chosen row back on
            // (`items.first { $0.value == chosen.value }`), and a default install
            // has a `plan` COMMAND and a `plan` AGENT PROFILE — two rows, two
            // different insertions, one bare name. Keyed on the name they were the
            // same item: the second row could not be selected at all, and picking
            // it applied the first one's spelling, breaking the user's rule that a
            // non-slash entry inserts `foo` and not `/foo`. The spelling is what
            // actually distinguishes them, and it is what
            // ``FileCompletionProvider`` has always put in `value`.
            return AutocompleteItem(
                value: insertion,
                label: insertion,
                description: description,
                insertion: insertion
            )
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

        // `item.insertion` carries the literal spelling. The `"/" + value`
        // fallback is only ever reached by an item this provider did not build —
        // one a caller hand-assembled before `insertion` existed, whose `value` is
        // therefore the bare name it always was. Items from
        // ``getSuggestions(lines:cursorLine:cursorCol:force:signal:)`` always carry
        // `insertion`, so the change that made their `value` the spelling cannot
        // reach this line and double a slash.
        //
        // The splice replaces the WHOLE token under the caret rather than just the
        // matched prefix. That is the difference between a `/` typed to open the
        // popup being consumed by a bare-name entry and it being left in front of
        // one, and it is also what keeps a caret parked mid-token from leaving the
        // token's tail stranded after the insertion.
        let insertion = item.insertion ?? ("/" + item.value)
        return spliceTokenAtCursor(
            lines: lines,
            cursorLine: cursorLine,
            cursorCol: cursorCol,
            insertion: insertion
        )
    }

    /// Fold `kind`, `argumentHint` and `description` into the popup's second
    /// column, matching pi's `hint — desc` composition and extending it with the
    /// group label a mixed command/tool/agent list needs to stay readable.
    ///
    /// Composing by joining the non-empty parts keeps the no-`kind` output
    /// byte-identical to what this produced before the palette was unified — there
    /// is no separator to strand when a part is missing.
    private static func describe(_ command: SlashCommand) -> String? {
        var parts: [String] = []
        if let kind = command.kind, !kind.isEmpty { parts.append(kind) }
        if let hint = command.argumentHint, !hint.isEmpty { parts.append(hint) }
        if let desc = command.description, !desc.isEmpty { parts.append(desc) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
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
