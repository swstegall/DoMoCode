// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The defects a review of the FIX found, each pinned by the scenario that was
// reproduced by running before it was fixed. Two of them were introduced by the
// previous round's fixes, which is the whole argument for reviewing a fix.

import DoMoCore
import DoMoHarness
import DoMoServer
import DoMoTUI
import Testing

@testable import DoMoClient

@Suite("Palette: second-round regressions")
@MainActor
struct PaletteSecondRoundTests {

    // MARK: A path under the caret is not a command gesture

    /// The first fix made palette insertion splice over any token starting with
    /// `/`, to eat the slash the popup was opened with. A path is such a token,
    /// so a draft mentioning `/usr/bin/env` lost it the moment a row was chosen.
    @Test("Inserting beside a path leaves the path intact")
    func pathTokenSurvives() {
        let prompt = PromptInput()
        prompt.setText("check /usr/bin/env")

        prompt.insertCommand("read", requiresSlash: true)

        #expect(prompt.text.contains("/usr/bin/env"))
        #expect(prompt.text.contains("/read"))
    }

    @Test("A dotted path is not a command gesture either")
    func dottedPathSurvives() {
        let prompt = PromptInput()
        prompt.setText("tail /tmp/build.log")

        prompt.insertCommand("read", requiresSlash: true)

        #expect(prompt.text.contains("/tmp/build.log"))
    }

    /// The rule it must NOT break: a bare `/` typed to open the palette is still
    /// consumed, which is the user's own third rule ("if `/` is already there,
    /// one shouldn't be prepended").
    @Test("A bare slash is still the gesture, and is still eaten")
    func bareSlashIsStillConsumed() {
        let prompt = PromptInput()
        prompt.setText("/")

        prompt.insertCommand("read", requiresSlash: true)

        #expect(prompt.text == "/read ")
    }

    /// And the fourth rule: a non-slash entry chosen after typing `/` inserts
    /// bare, eating the slash.
    @Test("A bare-name entry still eats the slash that opened the list")
    func bareEntryStillEatsTheSlash() {
        let prompt = PromptInput()
        prompt.setText("/")

        prompt.insertCommand("explore", requiresSlash: false)

        #expect(prompt.text == "explore ")
    }

    /// A partially typed command name is a gesture too — one segment, no dot.
    @Test("A partially typed command name is replaced, not appended to")
    func partialCommandNameIsReplaced() {
        let prompt = PromptInput()
        prompt.setText("/re")

        prompt.insertCommand("read", requiresSlash: true)

        #expect(prompt.text == "/read ")
    }

    // MARK: An unusable name is not offered

    /// The catalog feeds two insertion paths now, and only one of them
    /// sanitizes. A name that cannot be typed is refused a row rather than being
    /// silently scrubbed into a command that will not resolve.
    @Test("A tool name carrying an escape sequence is never offered")
    func hostileToolNameIsDropped() {
        let catalog = PaletteCatalog.assemble(
            commands: CommandRegistry(commands: []),
            tools: [
                Self.tool("re\u{1b}[2Jad"),
                Self.tool("read"),
            ],
            agents: []
        )

        #expect(catalog.map(\.name) == ["read"])
    }

    /// One shape for every catalog row these tests need; the schema and metadata
    /// are irrelevant to what is being asserted.
    private static func tool(_ name: String) -> ToolCatalogEntry {
        ToolCatalogEntry(
            name: name,
            description: "a tool",
            source: .builtIn,
            inputSchema: .object([:]),
            permission: .allowed
        )
    }

    @Test("A tool name containing a space is never offered")
    func spacedToolNameIsDropped() {
        let catalog = PaletteCatalog.assemble(
            commands: CommandRegistry(commands: []),
            tools: [
                Self.tool("two words")
            ],
            agents: []
        )

        #expect(catalog.isEmpty)
    }
}
