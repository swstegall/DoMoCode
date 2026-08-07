// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The regression suite for the unified command palette.
//
// The bug these exist for: choosing `/read` out of a popup that was opened by
// typing `/` produced `"//read "`, because the accept path APPENDED `"/" + name`
// to the draft instead of replacing the token the caret was sitting in. The four
// rules the user asked for are all consequences of that one operation, so they are
// asserted here as four separate expectations rather than as one — a regression in
// any single rule has to name itself.
//
// Plain `import DoMoTUI`, not `@testable`: everything under test is public, and a
// `@testable` import does not build in release, where this package is also tested.

import Testing
import DoMoTUI

// The palette never lists files, so the combined-provider case needs a lister that
// answers nothing rather than a fake tree.
private let noDirectories: DirectoryLister = { _ in [] }

@MainActor
@Suite("Palette completion")
struct PaletteCompletionTests {
    // A palette mixing the three entry shapes the client now feeds in: a tool and
    // a command that are spelled with a slash, and an agent that is invoked by
    // bare name.
    private let paletteCommands = [
        SlashCommand(name: "read", description: "Read a file", requiresSlash: true, kind: "tool"),
        SlashCommand(name: "explore", description: "Survey the codebase", requiresSlash: false, kind: "agent"),
        SlashCommand(name: "compact", description: "Compact the context"),
    ]

    // MARK: spliceTokenAtCursor — the seam the palette calls directly

    @Test("Splicing into an empty line inserts the text and a trailing space")
    func spliceIntoEmptyLine() {
        let result = spliceTokenAtCursor(lines: [""], cursorLine: 0, cursorCol: 0, insertion: "/read")
        #expect(result.lines == ["/read "])
        #expect(result.cursorLine == 0)
        #expect(result.cursorCol == 6)
    }

    @Test("A token that is exactly \"/\" is replaced, never prefixed")
    func spliceOverLoneSlash() {
        let result = spliceTokenAtCursor(lines: ["/"], cursorLine: 0, cursorCol: 1, insertion: "/read")
        #expect(result.lines == ["/read "])
        #expect(result.cursorCol == 6)
    }

    @Test("A bare insertion over a lone \"/\" eats the slash")
    func spliceBareOverLoneSlash() {
        let result = spliceTokenAtCursor(lines: ["/"], cursorLine: 0, cursorCol: 1, insertion: "explore")
        #expect(result.lines == ["explore "])
        #expect(result.cursorCol == 8)
    }

    @Test("A caret in the middle of a word replaces the whole word, tail included")
    func spliceMidWord() {
        // Caret between "/re" and "ad" — replacing only what is left of the caret
        // would strand "ad" and produce "/readad".
        let result = spliceTokenAtCursor(lines: ["/read"], cursorLine: 0, cursorCol: 3, insertion: "/reset")
        #expect(result.lines == ["/reset "])
        #expect(result.cursorCol == 7)
    }

    @Test("Text after the token on the same line survives")
    func spliceKeepsTailAfterToken() {
        let result = spliceTokenAtCursor(lines: ["/re rest of it"], cursorLine: 0, cursorCol: 3, insertion: "/read")
        // Two spaces: the splice always contributes its own separator, exactly as
        // the `@` file completion has always done. The token boundary is not moved
        // to absorb whitespace the user typed.
        #expect(result.lines == ["/read  rest of it"])
        #expect(result.cursorCol == 6)
    }

    @Test("Words on either side of the token are untouched")
    func spliceKeepsSurroundingWords() {
        let result = spliceTokenAtCursor(
            lines: ["fix @a.swift /re now"], cursorLine: 0, cursorCol: 16, insertion: "/read")
        #expect(result.lines == ["fix @a.swift /read  now"])
        #expect(result.cursorCol == 19)
    }

    @Test("A multi-line document is edited only on the caret's line")
    func spliceMultiLine() {
        let result = spliceTokenAtCursor(
            lines: ["first line", "/re", "third line"], cursorLine: 1, cursorCol: 3, insertion: "/read")
        #expect(result.lines == ["first line", "/read ", "third line"])
        #expect(result.cursorLine == 1)
        #expect(result.cursorCol == 6)
    }

    @Test("A document with no lines at all yields the line the text would live on")
    func spliceEmptyDocument() {
        // `Editor.applyAutocomplete` refuses an empty `lines`, so returning the
        // input unchanged here would silently drop the insertion.
        let result = spliceTokenAtCursor(lines: [], cursorLine: 0, cursorCol: 0, insertion: "/read")
        #expect(result.lines == ["/read "])
        #expect(result.cursorLine == 0)
        #expect(result.cursorCol == 6)
    }

    @Test("A cursor column past the end of the line clamps instead of trapping")
    func spliceClampsColumn() {
        let result = spliceTokenAtCursor(lines: ["/re"], cursorLine: 0, cursorCol: 99, insertion: "/read")
        #expect(result.lines == ["/read "])
        #expect(result.cursorCol == 6)
    }

    @Test("A stale line index leaves a non-empty document alone")
    func spliceStaleLineIndexIsInert() {
        let unchanged = spliceTokenAtCursor(lines: ["/re"], cursorLine: 7, cursorCol: 0, insertion: "/read")
        #expect(unchanged.lines == ["/re"])
        let negative = spliceTokenAtCursor(lines: ["/re"], cursorLine: -1, cursorCol: 0, insertion: "/read")
        #expect(negative.lines == ["/re"])
    }

    @Test("A tab is a token boundary")
    func spliceTabBoundary() {
        let result = spliceTokenAtCursor(lines: ["a\t/re"], cursorLine: 0, cursorCol: 5, insertion: "/read")
        #expect(result.lines == ["a\t/read "])
        #expect(result.cursorCol == 8)
    }

    @Test("Columns are grapheme offsets, not UTF-16 code units")
    func spliceCountsGraphemes() {
        // "👍🏽" is one Character and four UTF-16 code units. A UTF-16-based column
        // would report 11 here instead of 8.
        let result = spliceTokenAtCursor(lines: ["👍🏽 /re"], cursorLine: 0, cursorCol: 5, insertion: "/read")
        #expect(result.lines == ["👍🏽 /read "])
        #expect(result.cursorCol == 8)
    }

    // MARK: The four palette rules, through SlashCommandProvider

    @Test("Rule 1: a slash command chosen from a lone \"/\" inserts one slash, not two")
    func slashCommandKeepsOneSlash() async throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/"], cursorLine: 0, cursorCol: 1, force: false, signal: .none))
        let read = try #require(suggestions.items.first { $0.value == "read" })
        #expect(read.insertion == "/read")

        let result = try #require(provider.applyCompletion(
            lines: ["/"], cursorLine: 0, cursorCol: 1, item: read, prefix: suggestions.prefix))
        #expect(result.lines == ["/read "])
        #expect(result.cursorCol == 6)
    }

    @Test("Rule 2: an entry that needs no slash carries none")
    func bareEntryCarriesNoSlash() async throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/"], cursorLine: 0, cursorCol: 1, force: false, signal: .none))
        let explore = try #require(suggestions.items.first { $0.value == "explore" })
        #expect(explore.insertion == "explore")
    }

    @Test("Rule 3: a partially typed slash command completes to a single slash")
    func partialSlashCommandCompletes() async throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/re"], cursorLine: 0, cursorCol: 3, force: false, signal: .none))
        #expect(suggestions.prefix == "/re")
        let read = try #require(suggestions.items.first { $0.value == "read" })

        let result = try #require(provider.applyCompletion(
            lines: ["/re"], cursorLine: 0, cursorCol: 3, item: read, prefix: "/re"))
        #expect(result.lines == ["/read "])
    }

    @Test("Rule 4: choosing a bare entry after typing \"/\" eats the slash")
    func bareEntryEatsTheTypedSlash() async throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/ex"], cursorLine: 0, cursorCol: 3, force: false, signal: .none))
        let explore = try #require(suggestions.items.first { $0.value == "explore" })

        let result = try #require(provider.applyCompletion(
            lines: ["/ex"], cursorLine: 0, cursorCol: 3, item: explore, prefix: "/ex"))
        #expect(result.lines == ["explore "])
        #expect(result.cursorCol == 8)
    }

    @Test("A bare entry chosen when the token is exactly \"/\" keeps the rest of the line")
    func bareEntryOverLoneSlashKeepsTail() throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let explore = AutocompleteItem(value: "explore", label: "explore", insertion: "explore")
        let result = try #require(provider.applyCompletion(
            lines: ["/ tail"], cursorLine: 0, cursorCol: 1, item: explore, prefix: "/"))
        #expect(result.lines == ["explore  tail"])
        #expect(result.cursorCol == 8)
    }

    @Test("Accepting with the caret mid-token consumes the token's tail")
    func acceptMidTokenConsumesTail() throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let read = AutocompleteItem(value: "read", label: "read", insertion: "/read")
        // Caret after "/re" in "/reXX" — the popup matched "/re", but the accept
        // has to take the whole word or "XX" is left dangling.
        let result = try #require(provider.applyCompletion(
            lines: ["/reXX"], cursorLine: 0, cursorCol: 3, item: read, prefix: "/re"))
        #expect(result.lines == ["/read "])
    }

    // MARK: Back-compatibility

    @Test("An item with no insertion still gets the historical \"/\" + value")
    func legacyItemKeepsHistoricalSpelling() throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let legacy = AutocompleteItem(value: "compact", label: "compact")
        #expect(legacy.insertion == nil)
        let result = try #require(provider.applyCompletion(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, item: legacy, prefix: "/co"))
        #expect(result.lines == ["/compact "])
    }

    @Test("A command declared without the new fields is a slash command with no kind")
    func slashCommandDefaults() {
        let command = SlashCommand(name: "compact", description: "Compact the context")
        #expect(command.requiresSlash)
        #expect(command.kind == nil)
    }

    @Test("applyCompletion still declines a token that is not the leading one")
    func nonLeadingTokenDeclined() {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let read = AutocompleteItem(value: "read", label: "read", insertion: "/read")
        // A slash mid-sentence is not a command; the guard predates the palette and
        // has to survive it, or "see /re" would rewrite itself into a command.
        #expect(provider.applyCompletion(
            lines: ["hello /re"], cursorLine: 0, cursorCol: 9, item: read, prefix: "/re") == nil)
    }

    // MARK: Description composition

    @Test("The kind is folded in front of the description")
    func kindPrefixesDescription() async throws {
        let provider = SlashCommandProvider(commands: paletteCommands)
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/"], cursorLine: 0, cursorCol: 1, force: false, signal: .none))
        let read = try #require(suggestions.items.first { $0.value == "read" })
        #expect(read.description == "tool — Read a file")
        let explore = try #require(suggestions.items.first { $0.value == "explore" })
        #expect(explore.description == "agent — Survey the codebase")
        // No kind: byte-identical to what this produced before the palette merge.
        let compact = try #require(suggestions.items.first { $0.value == "compact" })
        #expect(compact.description == "Compact the context")
    }

    @Test("Kind, argument hint and description compose in that order")
    func kindHintAndDescriptionCompose() async throws {
        let provider = SlashCommandProvider(commands: [
            SlashCommand(
                name: "model", description: "Switch model", argumentHint: "<name>",
                requiresSlash: true, kind: "command"),
        ])
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/mo"], cursorLine: 0, cursorCol: 3, force: false, signal: .none))
        #expect(suggestions.items.first?.description == "command — <name> — Switch model")
    }

    // MARK: Through the combined provider

    @Test("The combined provider routes a bare-name entry to the slash provider")
    func combinedRoutesBareEntry() {
        let combined = CombinedAutocompleteProvider(commands: paletteCommands, lister: noDirectories)
        let explore = AutocompleteItem(value: "explore", label: "explore", insertion: "explore")
        let result = combined.applyCompletion(
            lines: ["/"], cursorLine: 0, cursorCol: 1, item: explore, prefix: "/")
        #expect(result?.lines == ["explore "])
    }
}
