// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The inline REPL's `/` popup, end to end at the value level: the palette the
// in-process session assembles, and what the completion provider does with it
// when a row is chosen. The four rules the user asked for are asserted on the
// resulting DOCUMENT text — `//read` is a string defect, so a string is what
// proves it gone.

import DoMoCLI
import DoMoCore
import DoMoHarness
import DoMoLLM
import DoMoTUI
import Testing

/// A tool definition reduced to what the palette reads. The schema is empty
/// because nothing here looks at it.
private func toolNamed(_ name: String, _ description: String = "") -> ToolDefinition {
    ToolDefinition(name: name, description: description, parameters: JSONSchema())
}

/// The three-kind palette every insertion test below starts from.
private let mixedPalette = InteractivePalette.entries(
    commands: [
        CommandDescriptor(
            name: "review",
            description: "Review the current diff",
            kind: .local,
            action: .review
        )
    ],
    skills: [],
    tools: [toolNamed("read", "Read a file")],
    agents: [AgentProfile(name: "explore", description: "Read-only exploration")]
)

@MainActor
@Suite("Inline command palette")
struct InteractivePaletteTests {

    // MARK: Assembly

    @Test("The palette lists commands, then tools, then agents")
    func listsEveryKindInOrder() {
        #expect(mixedPalette.map(\.name) == ["review", "read", "explore"])
        #expect(mixedPalette.map(\.kind) == ["command", "tool", "agent"])
        // Only the agent stands alone; a command and a tool are both spelled
        // with a slash.
        #expect(mixedPalette.map(\.requiresSlash) == [true, true, false])
    }

    @Test("A name is offered once, by its first source")
    func nameCollisionsResolveToOneRow() {
        // `review` is a real collision: a built-in local command and a built-in
        // agent profile. Two rows sharing a name would make the second one
        // unselectable, because the popup resolves a chosen row back to its item
        // by name.
        let palette = InteractivePalette.entries(
            commands: [CommandDescriptor(name: "review", description: "Review the diff", kind: .local, action: .review)],
            skills: [],
            tools: [toolNamed("review", "A tool that also calls itself review")],
            agents: [AgentProfile(name: "Review", description: "The review persona")]
        )
        #expect(palette.map(\.name) == ["review"])
        #expect(palette.first?.kind == "command")
        #expect(palette.first?.requiresSlash == true)
    }

    @Test("A command promoted from a skill is labelled as one")
    func promotedSkillsAreLabelled() {
        let palette = InteractivePalette.entries(
            commands: [
                CommandDescriptor(name: "dataviz", description: "Chart guidance"),
                CommandDescriptor(name: "compact", description: "Compact the context", kind: .local, action: .compact),
            ],
            skills: [PromptSkill(name: "DataViz", body: "Chart guidance body.")],
            tools: [],
            agents: []
        )
        #expect(palette.map(\.kind) == ["skill", "command"])
    }

    @Test("A name that could not be typed as one token is dropped")
    func unusableNamesAreDropped() {
        let palette = InteractivePalette.entries(
            commands: [],
            skills: [],
            tools: [
                toolNamed("mcp_server_read"),
                toolNamed("two words"),
                toolNamed("bell\u{7}"),
                toolNamed("wipe\u{1b}[2J"),
                toolNamed(""),
            ],
            agents: []
        )
        #expect(palette.map(\.name) == ["mcp_server_read"])
    }

    @Test("Descriptions are collapsed to one line and stripped of terminal controls")
    func descriptionsAreSanitized() {
        let palette = InteractivePalette.entries(
            commands: [],
            skills: [],
            tools: [toolNamed("read", "Read\na file\u{1b}[2J")],
            agents: []
        )
        #expect(palette.first?.description == "Read ⏎a file·[2J")
    }

    @Test("A descriptionless entry carries no description at all")
    func emptyDescriptionsBecomeNil() {
        let palette = InteractivePalette.entries(
            commands: [],
            skills: [],
            tools: [toolNamed("read", "   ")],
            agents: [AgentProfile(name: "build")]
        )
        #expect(palette.map(\.name) == ["read", "build"])
        #expect(palette.allSatisfy({ $0.description == nil }))
    }

    // MARK: The popup

    @Test("A bare slash offers every kind, each with its own spelling")
    func slashOffersEveryKind() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let suggestions = try #require(
            await provider.getSuggestions(
                lines: ["/"], cursorLine: 0, cursorCol: 1, force: false, signal: .none))

        // Labelled with the spelling, not the bare name: the row is the only
        // place the user can see that choosing the agent will eat the `/` they
        // typed to open the list.
        #expect(suggestions.items.map(\.label) == ["/review", "/read", "explore"])
        // `value` is the row's IDENTITY and carries the spelling too, so two rows
        // that share a name — `review` the command and `review` the agent profile,
        // both built in — are never the same item.
        #expect(suggestions.items.map(\.value) == ["/review", "/read", "explore"])
        // The spelling is decided when the item is built, which is the whole fix:
        // the agent's insertion has no slash to double.
        #expect(suggestions.items.map(\.insertion) == ["/review", "/read", "explore"])
    }

    @Test("Choosing a tool while the draft is just a slash does not double it")
    func toolInsertionKeepsOneSlash() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let item = try #require(await self.item(named: "read", from: provider, draft: "/"))
        let result = try #require(
            provider.applyCompletion(
                lines: ["/"], cursorLine: 0, cursorCol: 1, item: item, prefix: "/"))
        #expect(result.lines == ["/read "])
        #expect(result.cursorCol == Array("/read ").count)
    }

    @Test("Choosing an agent eats the slash the popup was opened with")
    func agentInsertionEatsTheSlash() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let item = try #require(await self.item(named: "explore", from: provider, draft: "/"))
        let result = try #require(
            provider.applyCompletion(
                lines: ["/"], cursorLine: 0, cursorCol: 1, item: item, prefix: "/"))
        #expect(result.lines == ["explore "])
        #expect(result.cursorCol == Array("explore ").count)
    }

    @Test("A slash already typed as part of the name is not doubled either")
    func partiallyTypedNameKeepsOneSlash() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let item = try #require(await self.item(named: "review", from: provider, draft: "/rev"))
        let result = try #require(
            provider.applyCompletion(
                lines: ["/rev"], cursorLine: 0, cursorCol: 4, item: item, prefix: "/rev"))
        #expect(result.lines == ["/review "])
    }

    @Test("A caret parked mid-token replaces the whole token, not just its head")
    func caretMidTokenReplacesWholeToken() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let item = try #require(await self.item(named: "review", from: provider, draft: "/r"))
        // "/r|ev": completing only the text before the caret would strand "ev".
        let result = try #require(
            provider.applyCompletion(
                lines: ["/rev"], cursorLine: 0, cursorCol: 2, item: item, prefix: "/r"))
        #expect(result.lines == ["/review "])
    }

    @Test("Words already in the draft survive the insertion")
    func trailingWordsSurvive() async throws {
        let provider = SlashCommandProvider(commands: mixedPalette)
        let item = try #require(await self.item(named: "explore", from: provider, draft: "/ex"))
        let result = try #require(
            provider.applyCompletion(
                lines: ["/ex this module"], cursorLine: 0, cursorCol: 3, item: item, prefix: "/ex"))
        #expect(result.lines == ["explore  this module"])
    }

    // MARK: Helpers

    /// The item the popup would offer for `name` after the user typed `draft`.
    ///
    /// Going through ``SlashCommandProvider/getSuggestions(lines:cursorLine:cursorCol:force:signal:)``
    /// rather than hand-building an ``AutocompleteItem`` is deliberate: the
    /// insertion is what these tests are about, and hand-building one would assert
    /// the test's opinion of the spelling instead of the palette's.
    private func item(
        named name: String,
        from provider: SlashCommandProvider,
        draft: String
    ) async -> AutocompleteItem? {
        let suggestions = await provider.getSuggestions(
            lines: [draft],
            cursorLine: 0,
            cursorCol: Array(draft).count,
            force: false,
            signal: .none
        )
        // Matched on the BARE name, because `value` is the row's identity and now
        // carries the spelling (`/read` vs `explore`) rather than the name. It has
        // to: `plan` and `review` exist as both a built-in command and a built-in
        // agent profile, and while both rows shared one bare `value` the popup
        // could not tell them apart — choosing the agent row inserted the
        // command's spelling.
        return suggestions?.items.first { $0.value == name || $0.value == "/" + name }
    }
}
