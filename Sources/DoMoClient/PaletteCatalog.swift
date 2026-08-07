// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Everything the palette and the `/` popup can offer, in one list.
//
// The palette used to show a fixed set of client ACTIONS and nothing else, while
// the `/` popup showed the command registry and nothing else — so a tool the
// runtime could actually run, and an agent profile the workspace defines, were
// reachable only by typing their names from memory. Worse, the two surfaces
// disagreed about what a name even means: a command is spelled `/compact`, an
// agent is spelled `explore`, and a list that cannot say which produced the
// `//read` the user reported.
//
// So an entry carries the ONE fact that decides its spelling — `requiresSlash` —
// beside its name, and every surface derives what it shows from that rather than
// prepending a slash and hoping. `kind` is display-only grouping.
//
// Untrusted text discipline. A tool name and a tool description can come from an
// MCP server the user merely configured, and they reach a frame row. `assemble`
// therefore folds and sanitizes every DESCRIPTION as it builds the catalog, and
// ``PaletteCatalog/item(for:)`` sanitizes again over the composed label — which
// is where the NAME finally appears. The name itself is stored verbatim, because
// it is also the identity the runtime has to resolve when the command is sent;
// the one place it becomes terminal bytes is the insertion, and the caller
// sanitizes it there (`ClientApp.insertPaletteCommand`).

import DoMoCore
import DoMoHarness
import DoMoServer
import DoMoTUI

/// One insertable thing: a command, a tool, an agent, or a promoted skill.
///
/// `name` is the runtime's spelling, verbatim — never a display string.
/// `requiresSlash` is the whole point of the type: `/read` is a command the
/// server expands, `explore` is an agent named in prose, and the palette must
/// insert exactly one of those two spellings without the caller guessing.
public struct PaletteEntry: Sendable, Hashable {
    public var name: String
    public var requiresSlash: Bool
    /// A display group — "command", "tool", "agent", "skill", "action". Free-form
    /// on purpose: it is shown, never switched on.
    public var kind: String
    /// The row's one-line detail, already folded to a single line and stripped of
    /// control characters by ``PaletteCatalog/assemble(commands:tools:agents:)``.
    public var description: String?

    public init(name: String, requiresSlash: Bool, kind: String, description: String? = nil) {
        self.name = name
        self.requiresSlash = requiresSlash
        self.kind = kind
        self.description = description
    }

    /// The text the user will see land in the prompt: `/read`, or `explore`.
    public var insertionText: String {
        requiresSlash ? "/" + name : name
    }
}

/// What one palette row means once it is chosen.
///
/// The palette mixes two populations in one list — client actions that run code
/// here, and catalog entries that only put text in the prompt — and a
/// ``SelectItem`` carries a single `String`. Encoding the distinction into that
/// string keeps the dialog generic; decoding it in one place keeps the two from
/// being told apart by guesswork at the call site.
public enum PaletteSelection: Sendable, Hashable {
    case action(String)
    case insert(name: String, requiresSlash: Bool)
}

/// Assembly, encoding and row composition for the unified palette. Pure: no IO,
/// no actor, so a test can assert the catalog without a server.
public enum PaletteCatalog {
    /// The prefix that marks a row as a client action rather than an insertion.
    public static let actionPrefix = "action:"
    /// The prefix that marks a row as an insertion. Followed by `0`/`1` for
    /// `requiresSlash`, a colon, and then the name — everything after that second
    /// colon, so a name that itself contains a colon round-trips intact.
    public static let insertPrefix = "insert:"

    // MARK: Assembly

    /// Build the catalog from the three sources the client can see.
    ///
    /// Order is source order rather than one alphabetical soup: commands, then
    /// tools, then agents. The searchable dialog filters across all of them, and
    /// an unfiltered list that keeps its groups is the one a user can skim.
    ///
    /// Hidden tools are dropped. `hiddenReason != nil` means the runtime will not
    /// offer the tool to the next model request at all, so listing it would be an
    /// offer this client cannot honour — the tool catalog dialog shows them
    /// because inspecting *why* a tool is unavailable is its job; inserting one is
    /// not.
    ///
    /// De-duplicated on the pair that decides the inserted text, first wins, so a
    /// tool that shares a name with a command does not produce two identical rows.
    public static func assemble(
        commands: CommandRegistry,
        tools: [ToolCatalogEntry],
        agents: [AgentProfileSummary]
    ) -> [PaletteEntry] {
        var entries: [PaletteEntry] = []
        entries.reserveCapacity(commands.commands.count + tools.count + agents.count)

        for descriptor in commands.commands {
            entries.append(PaletteEntry(
                name: descriptor.name,
                requiresSlash: true,
                kind: "command",
                description: detail(
                    prose: descriptor.description,
                    argumentHint: descriptor.argumentHint,
                    trailing: [descriptor.source.rawValue]
                )
            ))
        }
        for tool in tools where tool.hiddenReason == nil {
            entries.append(PaletteEntry(
                name: tool.name,
                requiresSlash: true,
                kind: "tool",
                description: detail(
                    prose: tool.description,
                    argumentHint: nil,
                    trailing: [tool.source.rawValue, tool.permission.rawValue]
                )
            ))
        }
        for agent in agents {
            entries.append(PaletteEntry(
                name: agent.name,
                requiresSlash: false,
                kind: "agent",
                description: detail(
                    prose: agent.description,
                    argumentHint: nil,
                    trailing: [agent.mode, agent.source]
                )
            ))
        }

        var seen: Set<String> = []
        var unique: [PaletteEntry] = []
        unique.reserveCapacity(entries.count)
        for entry in entries {
            let key = encode(.insert(name: entry.name, requiresSlash: entry.requiresSlash))
            guard seen.insert(key).inserted else { continue }
            unique.append(entry)
        }
        return unique
    }

    /// The one-line detail a row carries beside its kind.
    ///
    /// The argument hint is folded into the prose with the same `hint — desc`
    /// composition ``SlashCommandProvider`` uses, because ``PaletteEntry`` has no
    /// place of its own for a hint and dropping it would make the popup's second
    /// column less useful than the one it replaces. The trailing parts are the
    /// provenance — for a tool, the difference between a built-in and something an
    /// MCP server named, which is exactly what a user needs to judge a row they
    /// did not write.
    private static func detail(prose: String?, argumentHint: String?, trailing: [String]) -> String? {
        let text = sanitizeUntrustedText(collapseToOneLine(prose ?? ""))
        let hint = sanitizeUntrustedText(collapseToOneLine(argumentHint ?? ""))
        var parts: [String] = []
        if !hint.isEmpty {
            parts.append(text.isEmpty ? hint : hint + " — " + text)
        } else if !text.isEmpty {
            parts.append(text)
        }
        for part in trailing where !part.isEmpty {
            parts.append(sanitizeUntrustedText(collapseToOneLine(part)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Row values

    /// Encode a selection into a ``SelectItem/value``.
    public static func encode(_ selection: PaletteSelection) -> String {
        switch selection {
        case .action(let id):
            return actionPrefix + id
        case .insert(let name, let requiresSlash):
            return insertPrefix + (requiresSlash ? "1" : "0") + ":" + name
        }
    }

    /// Decode a ``SelectItem/value``, or nil when it is neither shape.
    ///
    /// Strict on purpose. A malformed `insert:` value must not silently become an
    /// action id and run something the user did not choose; the caller decides
    /// what to do with nil.
    public static func decode(_ value: String) -> PaletteSelection? {
        if value.hasPrefix(actionPrefix) {
            let id = String(value.dropFirst(actionPrefix.count))
            return id.isEmpty ? nil : .action(id)
        }
        guard value.hasPrefix(insertPrefix) else { return nil }
        var rest = value.dropFirst(insertPrefix.count)
        guard let flag = rest.first, flag == "0" || flag == "1" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == ":" else { return nil }
        // Everything after the flag's colon is the name, colons included: an MCP
        // server chooses its own tool names and this is not the place to refuse one.
        let name = String(rest.dropFirst())
        guard !name.isEmpty else { return nil }
        return .insert(name: name, requiresSlash: flag == "1")
    }

    /// The palette row for a catalog entry.
    ///
    /// The label is the insertion text as the user will see it — `/read`, not
    /// `read` — so the list answers the "does this get a slash?" question before
    /// the user presses Enter rather than after. Sanitized here because this is
    /// where the NAME becomes a frame row.
    /// `@MainActor` because `SelectItem` is: `DoMoTUI` is built with
    /// `.defaultIsolation(MainActor.self)`, so building one of its rows is a
    /// main-actor call even though nothing here touches the screen. Every caller
    /// is already on the main actor (the client app builds the palette from its
    /// own `@MainActor` methods), so this costs nothing at the call sites.
    @MainActor
    public static func item(for entry: PaletteEntry) -> SelectItem {
        var rowDescription = entry.kind
        if let description = entry.description, !description.isEmpty {
            rowDescription += " · " + description
        }
        return SelectItem(
            value: encode(.insert(name: entry.name, requiresSlash: entry.requiresSlash)),
            label: sanitizeUntrustedText(collapseToOneLine(entry.insertionText)),
            description: sanitizeUntrustedText(collapseToOneLine(rowDescription))
        )
    }

    /// The `/` popup's view of the same catalog.
    ///
    /// `argumentHint` is deliberately nil: the hint is already folded into
    /// ``PaletteEntry/description`` by ``detail(prose:argumentHint:trailing:)``,
    /// and passing it twice would print it twice. The kind is left for
    /// ``SlashCommandProvider`` to prefix, which is where every producer's rows
    /// get the same treatment.
    public static func slashCommands(_ entries: [PaletteEntry]) -> [SlashCommand] {
        entries.map {
            SlashCommand(
                name: $0.name,
                description: $0.description,
                argumentHint: nil,
                requiresSlash: $0.requiresSlash,
                kind: $0.kind
            )
        }
    }
}
