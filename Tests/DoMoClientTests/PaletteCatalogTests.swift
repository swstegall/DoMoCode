// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The unified palette's catalog: what goes in it, how a chosen row survives the
// round trip through a `SelectItem`'s single `String`, and what happens to text
// an MCP server chose.
//
// Driven through `PaletteCatalog`'s public seam rather than through `ClientApp`,
// which is `@MainActor` and needs a live surface, a runtime and a terminal to say
// anything at all. Every rule asserted here is one the app then only has to route.

import DoMoCore
import DoMoHarness
import DoMoServer
import DoMoTUI
import Foundation
import Testing

import DoMoClient

@Suite("Palette catalog")
struct PaletteCatalogTests {
    // MARK: Fixtures

    /// The wire shape of an agent profile, encoded and decoded rather than
    /// constructed: `AgentProfileSummary`'s memberwise initializer is not part of
    /// its published contract, and going through JSON also asserts that the
    /// summary the server serves is the summary this client can read.
    private struct AgentWire: Encodable {
        var name: String
        var description: String?
        var mode: String
        var source: String
    }

    private func agent(
        _ name: String,
        description: String? = nil,
        mode: String = "build",
        source: String = "project"
    ) throws -> AgentProfileSummary {
        let data = try JSONEncoder().encode(
            AgentWire(name: name, description: description, mode: mode, source: source)
        )
        return try JSONDecoder().decode(AgentProfileSummary.self, from: data)
    }

    private func tool(
        _ name: String,
        description: String? = nil,
        source: ToolCatalogSource = .mcp,
        permission: ToolPermissionState = .allowed,
        hiddenReason: String? = nil
    ) -> ToolCatalogEntry {
        ToolCatalogEntry(
            name: name,
            description: description,
            source: source,
            inputSchema: .object([:]),
            permission: permission,
            hiddenReason: hiddenReason
        )
    }

    private func commands(_ descriptors: [CommandDescriptor]) -> CommandRegistry {
        CommandRegistry(commands: descriptors)
    }

    private func entry(_ catalog: [PaletteEntry], named name: String) -> PaletteEntry? {
        catalog.first { $0.name == name }
    }

    // MARK: Assembly

    @Test("Commands, tools and agents land in one catalog with their own slash rule")
    func assemblesEveryKind() throws {
        let catalog = PaletteCatalog.assemble(
            commands: commands([
                CommandDescriptor(name: "compact", description: "Compact the context", kind: .local),
            ]),
            tools: [tool("read", description: "Read a file")],
            agents: [try agent("explore", description: "Read-only explorer")]
        )

        #expect(catalog.count == 3)

        let command = try #require(entry(catalog, named: "compact"))
        #expect(command.requiresSlash)
        #expect(command.kind == "command")
        #expect(command.insertionText == "/compact")

        let readTool = try #require(entry(catalog, named: "read"))
        #expect(readTool.requiresSlash)
        #expect(readTool.kind == "tool")
        #expect(readTool.insertionText == "/read")

        // The user's rule, at the source: an agent is named in prose, so it must
        // never acquire a slash on its way to the prompt.
        let profile = try #require(entry(catalog, named: "explore"))
        #expect(!profile.requiresSlash)
        #expect(profile.kind == "agent")
        #expect(profile.insertionText == "explore")
    }

    @Test("A hidden tool is not offered")
    func hiddenToolsExcluded() {
        let catalog = PaletteCatalog.assemble(
            commands: commands([]),
            tools: [
                tool("read", description: "Read a file"),
                tool("write", description: "Write a file", hiddenReason: "plan mode forbids writes"),
            ],
            agents: []
        )

        #expect(catalog.map(\.name) == ["read"])
    }

    @Test("A row's detail carries the source, the permission and the argument hint")
    func detailCarriesProvenance() throws {
        let catalog = PaletteCatalog.assemble(
            commands: commands([
                CommandDescriptor(
                    name: "review",
                    description: "Review the diff",
                    argumentHint: "[path]",
                    source: .project
                ),
            ]),
            tools: [tool("bash", description: "Run a command", source: .builtIn, permission: .requiresApproval)],
            agents: [try agent("explore", description: "Read-only explorer", mode: "plan", source: "user")]
        )

        let command = try #require(entry(catalog, named: "review")?.description)
        #expect(command == "[path] — Review the diff · project")

        let bash = try #require(entry(catalog, named: "bash")?.description)
        #expect(bash == "Run a command · builtIn · requiresApproval")

        let profile = try #require(entry(catalog, named: "explore")?.description)
        #expect(profile == "Read-only explorer · plan · user")
    }

    @Test("A command and a tool of the same name produce one row")
    func duplicatesCollapse() {
        let catalog = PaletteCatalog.assemble(
            commands: commands([CommandDescriptor(name: "diff", description: "Review changes", kind: .local)]),
            tools: [tool("diff", description: "A tool that also answers to diff")],
            agents: []
        )

        #expect(catalog.count == 1)
        // First wins, and the command is first: it is the one the runtime expands.
        #expect(catalog.first?.kind == "command")
    }

    // CHANGED when the palette's de-duplication moved from the
    // (name, requiresSlash) PAIR to the name alone. This suite used to assert
    // that a command and an agent sharing a name both survived "because the
    // spelling differs". They do not, and must not: the built-in registries ship
    // `plan` and `review` in BOTH, so every default install listed each of them
    // twice — two rows reading `/plan` and `plan`, indistinguishable to anyone who
    // has not read this file. The pair key was the reason.
    @Test("An agent that shares a name with a command is folded into it")
    func sameNameFoldsToTheCommand() throws {
        let catalog = PaletteCatalog.assemble(
            commands: commands([CommandDescriptor(name: "plan", description: "Plan the work")]),
            tools: [],
            agents: [try agent("plan", description: "The planning profile")]
        )

        #expect(catalog.count == 1)
        // Command over agent: `/plan` is what the runtime expands out of the
        // prompt, while the profile of that name is reached by the mode switch and
        // by the subagent tool rather than by being typed.
        #expect(catalog.map(\.insertionText) == ["/plan"])
        #expect(catalog.first?.kind == "command")
    }

    @Test("Names that differ only in case are one entry")
    func caseInsensitiveDuplicatesCollapse() {
        let catalog = PaletteCatalog.assemble(
            commands: commands([CommandDescriptor(name: "Review", description: "Review the diff")]),
            tools: [tool("review", description: "A tool spelled in lower case")],
            agents: []
        )

        #expect(catalog.count == 1)
        #expect(catalog.first?.name == "Review")
    }

    // MARK: Row values

    @Test("An action row round-trips")
    func actionRoundTrip() throws {
        let value = PaletteCatalog.encode(.action("edit-dialog"))
        #expect(value == "action:edit-dialog")

        let decoded = try #require(PaletteCatalog.decode(value))
        #expect(decoded == PaletteSelection.action("edit-dialog"))
    }

    @Test("An insertion row round-trips, slash rule included")
    func insertionRoundTrip() throws {
        let slashed = PaletteCatalog.encode(.insert(name: "read", requiresSlash: true))
        let bare = PaletteCatalog.encode(.insert(name: "explore", requiresSlash: false))
        #expect(slashed == "insert:1:read")
        #expect(bare == "insert:0:explore")

        let decodedSlashed = try #require(PaletteCatalog.decode(slashed))
        let decodedBare = try #require(PaletteCatalog.decode(bare))
        #expect(decodedSlashed == PaletteSelection.insert(name: "read", requiresSlash: true))
        #expect(decodedBare == PaletteSelection.insert(name: "explore", requiresSlash: false))
    }

    @Test("A name containing colons survives the encoding")
    func colonsInNamesSurvive() throws {
        // An MCP server picks its own tool names; `server:tool` is a shape they
        // really use, and a decoder that split on every colon would insert the
        // wrong half of it.
        let value = PaletteCatalog.encode(.insert(name: "mcp:files:read", requiresSlash: true))
        let decoded = try #require(PaletteCatalog.decode(value))
        #expect(decoded == PaletteSelection.insert(name: "mcp:files:read", requiresSlash: true))
    }

    @Test("A malformed value decodes to nothing rather than to something plausible")
    func malformedValuesRefused() {
        #expect(PaletteCatalog.decode("read") == nil)
        #expect(PaletteCatalog.decode("insert:") == nil)
        #expect(PaletteCatalog.decode("insert:2:read") == nil)
        #expect(PaletteCatalog.decode("insert:1read") == nil)
        #expect(PaletteCatalog.decode("insert:1:") == nil)
        #expect(PaletteCatalog.decode("action:") == nil)
    }

    // MARK: Untrusted text

    // `@MainActor` for the `SelectItem` half of the assertions only: `DoMoTUI`
    // is built with `.defaultIsolation(MainActor.self)`, so touching a row's
    // `label` is a main-actor read even in a test that never draws anything.
    @Test("Control characters from an MCP server never reach a palette row")
    @MainActor
    func mcpTextIsSanitized() throws {
        let hostileName = "re\u{1b}[2Jad"
        let catalog = PaletteCatalog.assemble(
            commands: commands([]),
            tools: [tool(hostileName, description: "wipes\u{1b}[2J the\nscreen")],
            agents: []
        )

        // CONTRACT CHANGE. This used to assert that the row survived with its
        // name verbatim, on the reasoning that "the surfaces that print it
        // sanitize as they print". That stopped being true when the `/` popup
        // started opening by itself in the full-screen client: its accept path
        // splices `AutocompleteItem.insertion` straight into the editor buffer
        // and has no sanitizer of its own. A name that cannot be typed is now
        // refused a row outright — refusing beats scrubbing, because a scrubbed
        // name is a command that will not resolve, which fails later and less
        // legibly than never being offered.
        #expect(catalog.isEmpty)

        // A well-formed name alongside it still gets its row, and its PROSE —
        // which is display text and may legitimately contain anything — is still
        // folded to one sanitized line.
        let mixed = PaletteCatalog.assemble(
            commands: commands([]),
            tools: [
                tool(hostileName, description: "wipes the screen"),
                tool("read", description: "reads\u{1b}[2J a\nfile"),
            ],
            agents: []
        )
        let row = try #require(mixed.first)
        #expect(mixed.count == 1)
        #expect(row.name == "read")
        let detail = try #require(row.description)
        #expect(detail.unicodeScalars.allSatisfy { $0.value != 0x1b })
        #expect(detail.unicodeScalars.allSatisfy { $0.value != 0x0a })

        let item = PaletteCatalog.item(for: row)
        #expect(item.label == "/read")
        let decoded = try #require(PaletteCatalog.decode(item.value))
        #expect(decoded == PaletteSelection.insert(name: "read", requiresSlash: true))
    }

    @Test("A row shows the insertion text as the user will see it")
    @MainActor
    func rowsShowTheirSpelling() throws {
        let slashed = PaletteCatalog.item(
            for: PaletteEntry(name: "read", requiresSlash: true, kind: "tool", description: "Read a file · mcp")
        )
        let bare = PaletteCatalog.item(
            for: PaletteEntry(name: "explore", requiresSlash: false, kind: "agent", description: "Explorer · project")
        )

        #expect(slashed.label == "/read")
        #expect(slashed.description == "tool · Read a file · mcp")
        #expect(bare.label == "explore")
        #expect(bare.description == "agent · Explorer · project")
    }

    // MARK: The `/` popup

    @Test("The popup's commands carry the same slash rule and kind as the palette")
    func slashCommandsMirrorTheCatalog() throws {
        let catalog = PaletteCatalog.assemble(
            commands: commands([CommandDescriptor(name: "compact", description: "Compact the context")]),
            tools: [tool("read", description: "Read a file")],
            agents: [try agent("explore", description: "Read-only explorer")]
        )
        let slash = PaletteCatalog.slashCommands(catalog)

        #expect(slash.map(\.name) == catalog.map(\.name))
        #expect(slash.map(\.requiresSlash) == [true, true, false])
        #expect(slash.compactMap(\.kind) == ["command", "tool", "agent"])
        // The hint is already folded into the description; carrying it twice
        // would print it twice in the popup's second column.
        #expect(slash.allSatisfy { $0.argumentHint == nil })
    }
}
