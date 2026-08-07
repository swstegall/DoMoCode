// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Three palette defects, each reproduced by running before it was fixed, each
// pinned here so it cannot come back quietly.
//
//   1. The unified palette made insertion a token SPLICE on every path. That is
//      right for the `/` popup — the splice is what eats the `/` the user typed
//      to open it — and wrong for ^P and the tool catalog, which are opened by a
//      keystroke with the caret mid-sentence: "please summarize report" plus a
//      chosen tool became "please summarize /read ", deleting `report`.
//   2. A default install has a `plan` COMMAND and a `plan` AGENT PROFILE (and the
//      same for `review`). The catalog keyed its de-duplication on the
//      (name, requiresSlash) pair, so both survived, and in the `/` popup both
//      rows carried the same bare `AutocompleteItem.value` — one item as far as
//      the accept path could tell, so the second row was unselectable and
//      choosing it inserted the first row's spelling.
//   3. The full-screen client asked for completions on Tab only, and the slash
//      provider declines a forced lookup, so typing `/` in `domo` showed nothing
//      at all.
//
// `@testable` for `PromptInput`, which is internal to the client, exactly as
// `ClientViewTests` does; everything else here is public API.

import DoMoCore
import DoMoHarness
import DoMoServer
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
@Suite("Palette insertion regressions")
struct PaletteInsertionRegressionTests {
    // MARK: Fixtures

    /// The wire shape of an agent profile. Built through JSON rather than through
    /// a memberwise initializer that is not part of the DTO's published contract —
    /// the same route `PaletteCatalogTests` takes, and for the same reason.
    private struct AgentWire: Encodable {
        var name: String
        var description: String?
        var mode: String
        var source: String
    }

    private func summaries(_ profiles: [AgentProfile]) throws -> [AgentProfileSummary] {
        try profiles.map { profile in
            let data = try JSONEncoder().encode(
                AgentWire(
                    name: profile.name,
                    description: profile.description,
                    mode: profile.mode.rawValue,
                    source: profile.source.rawValue
                )
            )
            return try JSONDecoder().decode(AgentProfileSummary.self, from: data)
        }
    }

    /// A prompt holding `text`, caret parked at the end (`setText`'s placement).
    private func prompt(_ text: String) -> PromptInput {
        let input = PromptInput()
        input.setText(text)
        return input
    }

    private static let leftArrow: [UInt8] = [0x1b, 0x5b, 0x44]

    /// Let an unstructured `Task` started by the component under test run.
    ///
    /// `requestAutocomplete` deliberately hops through a `Task` so a superseded
    /// keystroke's lookup can be cancelled; a test therefore cannot observe the
    /// result on the same turn it typed. Yielding until the predicate holds keeps
    /// this from depending on how many suspension points the provider has.
    private func settle(until predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
    }

    // MARK: 1 — the keystroke gesture must not destroy text

    @Test("A tool chosen mid-draft leaves the word the caret is on intact")
    func keystrokeInsertionKeepsTheWord() {
        let input = prompt("please summarize report")
        input.insertCommand("read", requiresSlash: true)
        // The regression: this used to be "please summarize /read " — `report`
        // silently gone, with nothing on screen to say a word had been removed.
        #expect(input.text == "please summarize report /read ")
    }

    @Test("An agent chosen mid-draft is inserted bare and destroys nothing")
    func keystrokeInsertionOfBareEntry() {
        let input = prompt("review the diff")
        input.insertCommand("explore", requiresSlash: false)
        #expect(input.text == "review the diff explore ")
    }

    @Test("A caret parked inside a word splits it rather than eating it")
    func keystrokeInsertionMidWordDestroysNothing() {
        let input = prompt("please summarize report")
        // Measured once first: cursor movement is computed against the width the
        // editor last rendered at, so an unmeasured editor moves the caret through
        // a degenerate visual-line map rather than the one the user is looking at.
        _ = input.height(forWidth: 60, maxRows: 8)
        for _ in 0..<3 { input.handleInput(Self.leftArrow) }   // caret between "rep" and "ort"
        input.insertCommand("read", requiresSlash: true)
        // Not pretty, and deliberately so: every character the user typed is still
        // there and the mistake is visible and trivially undone, where the splice
        // deleted `report` outright and left no evidence it had existed.
        #expect(input.text == "please summarize rep /read ort")
    }

    @Test("A caret after a trailing space gains no second space")
    func keystrokeInsertionAfterSpace() {
        let input = prompt("please ")
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "please /read ")
    }

    @Test("An empty draft inserts exactly the entry")
    func insertionIntoEmptyDraft() {
        let slashed = PromptInput()
        slashed.insertCommand("read", requiresSlash: true)
        #expect(slashed.text == "/read ")

        let bare = PromptInput()
        bare.insertCommand("explore", requiresSlash: false)
        #expect(bare.text == "explore ")
    }

    // MARK: 1a — the two seams the gesture test is built on

    @Test("The token under the caret is what distinguishes the two gestures")
    func tokenUnderTheCaret() {
        #expect(paletteTokenAtCursor(lines: ["please summarize report"], cursorLine: 0, cursorCol: 23) == "report")
        // A caret on a boundary owns no token — there is nothing there to destroy,
        // so the splice and the insert agree.
        #expect(paletteTokenAtCursor(lines: ["please "], cursorLine: 0, cursorCol: 7) == "")
        #expect(paletteTokenAtCursor(lines: ["/re"], cursorLine: 0, cursorCol: 3) == "/re")
        // Mid-token, both directions: the tail counts, or the gesture test would
        // read "/re" as "/r" and still be right by accident.
        #expect(paletteTokenAtCursor(lines: ["a\t/read b"], cursorLine: 0, cursorCol: 4) == "/read")
        // Stale coordinates answer "no token" rather than trapping.
        #expect(paletteTokenAtCursor(lines: ["/re"], cursorLine: 9, cursorCol: 0) == "")
        #expect(paletteTokenAtCursor(lines: [], cursorLine: 0, cursorCol: 0) == "")
    }

    @Test("Inserting at the caret separates itself without eating anything")
    func insertAtCaretSeam() {
        let midSentence = insertAtCursor(
            lines: ["please summarize report"], cursorLine: 0, cursorCol: 23, insertion: "/read")
        #expect(midSentence.lines == ["please summarize report /read "])
        #expect(midSentence.cursorCol == 30)

        // Already on whitespace: one separator, not two.
        let afterSpace = insertAtCursor(lines: ["please "], cursorLine: 0, cursorCol: 7, insertion: "/read")
        #expect(afterSpace.lines == ["please /read "])

        // Start of line: no leading separator at all.
        let atStart = insertAtCursor(lines: ["report"], cursorLine: 0, cursorCol: 0, insertion: "/read")
        #expect(atStart.lines == ["/read report"])

        // An empty document still yields the line the text would live on, because
        // `Editor.applyAutocomplete` rejects an empty `lines` outright.
        let empty = insertAtCursor(lines: [], cursorLine: 0, cursorCol: 0, insertion: "/read")
        #expect(empty.lines == ["/read "])

        // Columns are graphemes: "👍🏽" is one Character and four UTF-16 units.
        let graphemes = insertAtCursor(lines: ["👍🏽 x"], cursorLine: 0, cursorCol: 3, insertion: "/read")
        #expect(graphemes.lines == ["👍🏽 x /read "])
    }

    // MARK: 1b — the `/` gesture still splices

    @Test("A draft of exactly \"/\" is consumed, never doubled")
    func typedSlashIsConsumed() {
        let slashed = prompt("/")
        slashed.insertCommand("read", requiresSlash: true)
        #expect(slashed.text == "/read ")

        // The user's rule 2, on the gesture that produced the report: the `/` that
        // opened the list is eaten by an entry that is named without one.
        let bare = prompt("/")
        bare.insertCommand("explore", requiresSlash: false)
        #expect(bare.text == "explore ")
    }

    @Test("A partially typed command is replaced, not appended to")
    func typedPrefixIsReplaced() {
        let input = prompt("/re")
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "/read ")
    }

    @Test("A partially typed command mid-draft still splices, and the prose survives")
    func typedPrefixMidDraftSplices() {
        let input = prompt("fix the parser /re")
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "fix the parser /read ")
    }

    @Test("Two keystroke insertions in a row are separated, not concatenated")
    func consecutiveInsertions() {
        let input = PromptInput()
        input.insertCommand("read", requiresSlash: true)
        input.insertCommand("grep", requiresSlash: true)
        #expect(input.text == "/read /grep ")
    }

    // MARK: 2 — one row per name, and every row its own identity

    @Test("The default install's plan/review collisions produce one row each")
    func defaultInstallHasNoDuplicateRows() throws {
        let catalog = PaletteCatalog.assemble(
            commands: CommandRegistry.builtIn,
            tools: [],
            agents: try summaries(AgentProfileRegistry.builtIn.profiles)
        )

        // The collision is real out of the box: both registries ship `plan` and
        // `review`. Before the fix each of them appeared twice, once as `/plan`
        // and once as `plan`, which is a list a user cannot choose from.
        for name in ["plan", "review"] {
            let rows = catalog.filter { $0.name.lowercased() == name }
            #expect(rows.count == 1, "\(name) should appear once, saw \(rows.count)")
            #expect(rows.first?.kind == "command")
            #expect(rows.first?.insertionText == "/" + name)
        }
        // An agent that collides with nothing is still offered, bare.
        let explore = try #require(catalog.first { $0.name == "explore" })
        #expect(explore.kind == "agent")
        #expect(explore.insertionText == "explore")
    }

    @Test("De-duplication is case-insensitive and keeps the first source")
    func duplicatesAreFoldedCaseInsensitively() throws {
        let catalog = PaletteCatalog.assemble(
            commands: CommandRegistry(commands: [CommandDescriptor(name: "Plan", description: "The command")]),
            tools: [],
            agents: try summaries([
                AgentProfile(name: "plan", description: "The profile", systemPrompt: "", mode: .plan),
            ])
        )
        #expect(catalog.count == 1)
        #expect(catalog.first?.name == "Plan")
        #expect(catalog.first?.kind == "command")
    }

    @Test("Two rows sharing a name are still two selectable items in the popup")
    func collidingRowsKeepDistinctIdentities() async throws {
        // Assembled by hand rather than through `assemble`, which now folds this
        // pair: the identity has to hold for a collision the catalog never sees —
        // an MCP server is free to name a tool after a command, and a stale
        // catalog can be a keystroke behind the registry.
        let entries = [
            PaletteEntry(name: "plan", requiresSlash: true, kind: "command", description: "Open the workflow"),
            PaletteEntry(name: "plan", requiresSlash: false, kind: "agent", description: "The planning profile"),
        ]
        let provider = SlashCommandProvider(commands: PaletteCatalog.slashCommands(entries))
        let suggestions = try #require(
            await provider.getSuggestions(lines: ["/"], cursorLine: 0, cursorCol: 1, force: false, signal: .none)
        )

        #expect(suggestions.items.map(\.value) == ["/plan", "plan"])

        // Exactly the lookup `ClientApp.reconcileAutocomplete` performs: the row
        // the dialog hands back carries only a value, and the item is resolved
        // from it. Keyed on the bare name both rows resolved to the FIRST item,
        // so choosing the agent inserted `/plan`.
        for chosen in suggestions.items {
            let resolved = try #require(suggestions.items.first { $0.value == chosen.value })
            #expect(resolved.insertion == chosen.insertion)
        }

        let agent = try #require(suggestions.items.first { $0.value == "plan" })
        let result = try #require(
            provider.applyCompletion(lines: ["/"], cursorLine: 0, cursorCol: 1, item: agent, prefix: "/")
        )
        #expect(result.lines == ["plan "])
    }

    // MARK: 3 — typing `/` opens the popup

    @Test("Typing a leading slash asks for completions without Tab")
    func slashOpensTheCompletionPopup() async throws {
        let input = PromptInput()
        input.setAutocompleteProvider(SlashCommandProvider(commands: [
            SlashCommand(name: "read", description: "Read a file", requiresSlash: true, kind: "tool"),
            SlashCommand(name: "explore", description: "Survey", requiresSlash: false, kind: "agent"),
        ]))
        // Installed AFTER the provider: `setAutocompleteProvider` clears any open
        // popup through this same hook, and that nil is not what is under test.
        var batches: [AutocompleteSuggestions?] = []
        input.onAutocomplete = { batches.append($0) }

        input.handleInput(Array("/".utf8))
        await settle(until: { batches.contains(where: { $0 != nil }) })

        let suggestions = try #require(batches.last ?? nil)
        // Both kinds are offered, each labelled with the spelling it will insert —
        // which is the half of the phase that was invisible in `domo` with no
        // flags, because nothing ever asked the provider for them.
        #expect(suggestions.items.map(\.label) == ["/read", "explore"])
    }

    @Test("Ordinary prose asks for nothing")
    func proseDoesNotFireLookups() async {
        let input = PromptInput()
        input.setAutocompleteProvider(SlashCommandProvider(commands: [
            SlashCommand(name: "read", description: "Read a file"),
        ]))
        var calls = 0
        input.onAutocomplete = { _ in calls += 1 }

        for byte in Array("hello there".utf8) { input.handleInput([byte]) }
        await settle(until: { calls > 0 })

        // Not merely "no popup": no task, no provider call. A lookup per keystroke
        // of prose is a `readdir` per keystroke once the file provider is in the
        // chain, which is why the trigger is the slash context and nothing wider.
        #expect(calls == 0)
        #expect(input.text == "hello there")
    }

    @Test("A space ends the command name and closes what typing opened")
    func spaceClosesTheAutomaticPopup() async throws {
        let input = PromptInput()
        input.setAutocompleteProvider(SlashCommandProvider(commands: [
            SlashCommand(name: "read", description: "Read a file"),
        ]))
        var batches: [AutocompleteSuggestions?] = []
        input.onAutocomplete = { batches.append($0) }

        input.handleInput(Array("/".utf8))
        await settle(until: { batches.contains(where: { $0 != nil }) })
        #expect(batches.contains(where: { $0 != nil }))

        input.handleInput(Array(" ".utf8))
        // A popup that outlived its context would sit over a draft that is no
        // longer a command name, eating every key the client routes to it.
        #expect((batches.last ?? nil) == nil)
    }

    @Test("Accepting an automatic completion still obeys the four popup rules")
    func acceptingFromTheAutomaticPopup() async throws {
        let input = PromptInput()
        input.setAutocompleteProvider(SlashCommandProvider(commands: [
            SlashCommand(name: "explore", description: "Survey", requiresSlash: false, kind: "agent"),
        ]))
        var batches: [AutocompleteSuggestions?] = []
        input.onAutocomplete = { batches.append($0) }

        for byte in Array("/ex".utf8) { input.handleInput([byte]) }
        await settle(until: { batches.contains(where: { $0 != nil }) })

        let suggestions = try #require(batches.last ?? nil)
        let explore = try #require(suggestions.items.first)
        input.applyAutocomplete(explore, prefix: suggestions.prefix)
        // Rule 4, end to end through the surface the popup now opens on: the `/`
        // that opened the list is eaten by an entry named without one.
        #expect(input.text == "explore ")
    }
}
