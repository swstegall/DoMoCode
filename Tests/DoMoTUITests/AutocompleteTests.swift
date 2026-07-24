// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

// A fake directory tree, keyed by the path the provider asks to list. No disk is
// touched — this is the whole point of the injected ``DirectoryLister`` seam.
private let fakeTree: [String: [DirectoryEntry]] = [
    "": [
        DirectoryEntry(name: "README.md", isDirectory: false),
        DirectoryEntry(name: "package.swift", isDirectory: false),
        DirectoryEntry(name: "src", isDirectory: true),
    ],
    "src/": [
        DirectoryEntry(name: "autocomplete.swift", isDirectory: false),
        DirectoryEntry(name: "app.swift", isDirectory: false),
        DirectoryEntry(name: "components", isDirectory: true),
    ],
    "src/components/": [
        DirectoryEntry(name: "button.swift", isDirectory: false),
    ],
]

private let fakeLister: DirectoryLister = { directory in fakeTree[directory] ?? [] }
private let emptyLister: DirectoryLister = { _ in [] }

@MainActor
@Suite("Autocomplete")
struct AutocompleteTests {
    // MARK: @ file completion

    @Test("@ completion matches a partial segment in a nested directory")
    func atNestedPartialSegment() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: false, signal: .none)

        let suggestions = try! #require(result)
        #expect(suggestions.prefix == "@src/aut")
        #expect(suggestions.items.map(\.label) == ["autocomplete.swift"])
        #expect(suggestions.items.first?.value == "@src/autocomplete.swift")
        #expect(suggestions.items.first?.description == "src/autocomplete.swift")
    }

    @Test("@ completion at root lists everything, directories first")
    func atRootListsAllDirsFirst() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["@"], cursorLine: 0, cursorCol: 1, force: false, signal: .none)

        let suggestions = try! #require(result)
        // Directory sorts ahead of files; files then order case-insensitively.
        #expect(suggestions.items.map(\.label) == ["src/", "package.swift", "README.md"])
    }

    @Test("@ completion of a partial directory name yields a directory value")
    func atPartialDirectory() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["@sr"], cursorLine: 0, cursorCol: 3, force: false, signal: .none)

        let suggestions = try! #require(result)
        #expect(suggestions.items.map(\.value) == ["@src/"])
        #expect(suggestions.items.map(\.label) == ["src/"])
    }

    @Test("@ completion returns nil when nothing in the segment matches")
    func atNoMatch() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["@zzz"], cursorLine: 0, cursorCol: 4, force: false, signal: .none)
        #expect(result == nil)
    }

    @Test("An injected lister that returns nothing yields no suggestions")
    func emptyListerYieldsNil() async {
        let provider = FileCompletionProvider(lister: emptyLister)
        let result = await provider.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: false, signal: .none)
        #expect(result == nil)
    }

    @Test("No @ token means the file provider declines")
    func noAtTokenDeclines() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["hello src/"], cursorLine: 0, cursorCol: 10, force: false, signal: .none)
        #expect(result == nil)
    }

    @Test("The @ token is found only at a delimiter boundary")
    func atTokenBoundary() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        // "@" is mid-token (email-like) — not a completion trigger.
        let mid = await provider.getSuggestions(
            lines: ["foo@sr"], cursorLine: 0, cursorCol: 6, force: false, signal: .none)
        #expect(mid == nil)
        // After a space it starts a fresh token and does trigger.
        let boundary = await provider.getSuggestions(
            lines: ["look @sr"], cursorLine: 0, cursorCol: 8, force: false, signal: .none)
        #expect(boundary != nil)
    }

    // MARK: Cancellation and force

    @Test("A cancelled signal abandons the lookup before listing")
    func cancelledSignalReturnsNil() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let cancelled = CancellationSignal { true }
        let result = await provider.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: false, signal: cancelled)
        #expect(result == nil)
    }

    @Test("File completion still fires under force (Tab)")
    func fileCompletionUnderForce() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let result = await provider.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: true, signal: .none)
        #expect(result != nil)
    }

    // MARK: applyCompletion — files

    @Test("Applying a file completion replaces the prefix and adds a space")
    func applyFileCompletion() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let item = AutocompleteItem(value: "@src/autocomplete.swift", label: "autocomplete.swift")
        let result = try! #require(provider.applyCompletion(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, item: item, prefix: "@src/aut"))
        #expect(result.lines == ["@src/autocomplete.swift "])
        #expect(result.cursorCol == Array("@src/autocomplete.swift ").count)
    }

    @Test("Applying a directory completion adds no trailing space")
    func applyDirectoryCompletion() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let item = AutocompleteItem(value: "@src/", label: "src/")
        let result = try! #require(provider.applyCompletion(
            lines: ["@sr"], cursorLine: 0, cursorCol: 3, item: item, prefix: "@sr"))
        #expect(result.lines == ["@src/"])
        #expect(result.cursorCol == 5)
    }

    @Test("Applying a completion preserves the text after the cursor")
    func applyPreservesSuffix() async {
        let provider = FileCompletionProvider(lister: fakeLister)
        let item = AutocompleteItem(value: "@src/autocomplete.swift", label: "autocomplete.swift")
        let result = try! #require(provider.applyCompletion(
            lines: ["@src/aut done"], cursorLine: 0, cursorCol: 8, item: item, prefix: "@src/aut"))
        #expect(result.lines == ["@src/autocomplete.swift  done"])
    }

    // MARK: Slash commands

    private let commands = [
        SlashCommand(name: "compact", description: "Compact the context"),
        SlashCommand(name: "clear", description: "Clear the screen"),
        SlashCommand(name: "cost", description: "Show token cost"),
    ]

    @Test("Slash completion fuzzy-filters the command palette")
    func slashCompletion() async {
        let provider = SlashCommandProvider(commands: commands)
        let result = await provider.getSuggestions(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, force: false, signal: .none)

        let suggestions = try! #require(result)
        #expect(suggestions.prefix == "/co")
        // "co" is a subsequence of compact and cost, not clear.
        #expect(suggestions.items.map(\.value) == ["compact", "cost"])
        #expect(suggestions.items.first?.description == "Compact the context")
    }

    @Test("Slash completion declines under force (Tab is for files)")
    func slashDeclinesUnderForce() async {
        let provider = SlashCommandProvider(commands: commands)
        let result = await provider.getSuggestions(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, force: true, signal: .none)
        #expect(result == nil)
    }

    @Test("Slash completion declines once the command name is complete")
    func slashDeclinesAfterSpace() async {
        let provider = SlashCommandProvider(commands: commands)
        let result = await provider.getSuggestions(
            lines: ["/compact now"], cursorLine: 0, cursorCol: 12, force: false, signal: .none)
        #expect(result == nil)
    }

    @Test("Applying a slash completion inserts /name and a space")
    func applySlashCompletion() async {
        let provider = SlashCommandProvider(commands: commands)
        let item = AutocompleteItem(value: "compact", label: "compact")
        let result = try! #require(provider.applyCompletion(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, item: item, prefix: "/co"))
        #expect(result.lines == ["/compact "])
        #expect(result.cursorCol == Array("/compact ").count)
    }

    @Test("The argument hint is folded into the description column")
    func slashDescriptionWithHint() async {
        let provider = SlashCommandProvider(commands: [
            SlashCommand(name: "model", description: "Switch model", argumentHint: "<name>"),
        ])
        let result = try! #require(await provider.getSuggestions(
            lines: ["/mo"], cursorLine: 0, cursorCol: 3, force: false, signal: .none))
        #expect(result.items.first?.description == "<name> — Switch model")
    }

    // MARK: Combined provider

    @Test("Combined provider routes slash and @ contexts to the right source")
    func combinedRoutes() async {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)

        let slash = try! #require(await combined.getSuggestions(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, force: false, signal: .none))
        #expect(slash.items.map(\.value) == ["compact", "cost"])

        let file = try! #require(await combined.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: false, signal: .none))
        #expect(file.items.map(\.label) == ["autocomplete.swift"])
    }

    @Test("Combined applyCompletion routes an item back to its author")
    func combinedApplyRoutes() async {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)

        let slashItem = AutocompleteItem(value: "compact", label: "compact")
        let slashResult = try! #require(combined.applyCompletion(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, item: slashItem, prefix: "/co"))
        #expect(slashResult.lines == ["/compact "])

        let fileItem = AutocompleteItem(value: "@src/", label: "src/")
        let fileResult = try! #require(combined.applyCompletion(
            lines: ["@sr"], cursorLine: 0, cursorCol: 3, item: fileItem, prefix: "@sr"))
        #expect(fileResult.lines == ["@src/"])
    }

    @Test("Combined provider under force reserves Tab for file completion")
    func combinedForceReservesTab() async {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)
        // A slash context under force yields nothing (slash declines, no @ token).
        let slashForced = await combined.getSuggestions(
            lines: ["/co"], cursorLine: 0, cursorCol: 3, force: true, signal: .none)
        #expect(slashForced == nil)
        // A file context under force still completes.
        let fileForced = await combined.getSuggestions(
            lines: ["@src/aut"], cursorLine: 0, cursorCol: 8, force: true, signal: .none)
        #expect(fileForced != nil)
    }

    @Test("Combined triggerCharacters unions its sub-providers")
    func combinedTriggerCharacters() {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)
        #expect(combined.triggerCharacters == ["/", "@"])
    }

    // MARK: shouldTriggerFileCompletion

    @Test("shouldTriggerFileCompletion fires at an @ boundary")
    func triggerAtBoundary() {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)
        #expect(combined.shouldTriggerFileCompletion(lines: ["@"], cursorLine: 0, cursorCol: 1))
        #expect(combined.shouldTriggerFileCompletion(lines: ["look @sr"], cursorLine: 0, cursorCol: 8))
    }

    @Test("shouldTriggerFileCompletion stays out of a slash-command name")
    func noTriggerInSlashName() {
        let combined = CombinedAutocompleteProvider(commands: commands, lister: fakeLister)
        #expect(!combined.shouldTriggerFileCompletion(lines: ["/co"], cursorLine: 0, cursorCol: 3))
        // Once the command name is done (a space), file completion is fair game.
        #expect(combined.shouldTriggerFileCompletion(lines: ["/run src"], cursorLine: 0, cursorCol: 8))
    }
}
