// Copyright (c) 2025 opencode contributors. MIT license.
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Turns a raw tool call into a ``PermissionRequestSpec``. Tool-aware: bash is split
// per sub-command (including nested substitutions) with an arity-prefix "always" glob;
// read/write/edit key on the file path (so the `.env` guard sees a real path and the
// config self-edit guard can fire); an unknown name (an MCP tool) defaults to `*` so it
// is treated like any untrusted call. Reads arguments defensively (the `file_path`/
// `path` alias, string values).

import DoMoCore
import Foundation

/// Builds permission specs from tool calls. Holds the workspace root (to resolve
/// relative paths) and the config-file paths the self-edit guard protects.
public struct PermissionRequestFactory: Sendable {
    private let workingDirectory: String
    /// Absolute, canonicalized paths of the permission/settings/trust files the model
    /// must not silently overwrite (Phase 8a self-edit guard).
    private let protectedPaths: Set<String>
    /// Lowercased basenames + `.domocode` used to config-protect a bash command that
    /// mentions a config file (bash can write via a redirect, bypassing write/edit).
    private let protectedMarkers: [String]

    public init(workingDirectory: String, protectedPaths: Set<String> = []) {
        self.workingDirectory = workingDirectory
        self.protectedPaths = Set(protectedPaths.map { Self.canonical($0) })
        var markers = Set<String>([".domocode"])
        for path in protectedPaths {
            markers.insert((path as NSString).lastPathComponent.lowercased())
        }
        self.protectedMarkers = Array(markers)
    }

    public func make(toolName: String, arguments: JSONValue) -> PermissionRequestSpec {
        switch toolName {
        case "bash":
            return bashSpec(arguments)
        case "write", "edit":
            let path = pathArgument(arguments)
            return PermissionRequestSpec(
                permission: toolName,
                patterns: [path],
                patternAliases: aliases(for: path),
                always: pathGrant(path),
                metadata: ["filepath": .string(path)],
                configProtected: isProtected(path)
            )
        case "read":
            // read keys on the real path so the `.env` secret guard can classify it.
            let path = pathArgument(arguments)
            return PermissionRequestSpec(
                permission: "read",
                patterns: [path],
                patternAliases: aliases(for: path),
                always: pathGrant(path),
                metadata: ["filepath": .string(path)]
            )
        case "ls":
            let path = arguments["path"]?.stringValue ?? "."
            return PermissionRequestSpec(
                permission: "ls",
                patterns: [path],
                patternAliases: aliases(for: path),
                always: pathGrant(path)
            )
        case "webfetch":
            let url = arguments["url"]?.stringValue ?? ""
            return PermissionRequestSpec(
                permission: "webfetch",
                patterns: [url],
                always: [],
                metadata: ["url": .string(url)]
            )
        default:
            // find/grep/todo/etc. and every MCP tool: a coarse `*` resource. Known
            // read-only tools are auto-allowed by the baseline; an unknown MCP name is
            // gated exactly like an untrusted call (default `ask`).
            return PermissionRequestSpec(permission: toolName, patterns: ["*"], always: ["*"])
        }
    }

    /// What "allow always" persists for a path-keyed tool: THAT path, and nothing
    /// wider.
    ///
    /// This used to be `["*"]`. Approving "Allow always" on `edit a.txt` therefore
    /// wrote `edit: {"*": "allow"}` into the user's GLOBAL settings.json — every edit
    /// to every file in every project, forever, from a prompt whose bold line read
    /// `edit  a.txt`. On `read` it was worse: a single "always" on any file disabled
    /// the `.env` secret guard everywhere, which is the one rule the baseline exists
    /// to enforce.
    ///
    /// A narrow grant is honoured by the resolver — ``resolvePermission`` accepts a
    /// saved rule when `wildcardMatch(savedPattern, basePattern)`, and a literal path
    /// matches the baseline's `*` — so this genuinely suppresses the prompt for that
    /// file while leaving every other file gated. The cost is a prompt per new file;
    /// that is the honest price of a grant that means what its label says.
    ///
    /// An empty path grants nothing, and the surfaces hide the "always" row rather
    /// than offering a choice that would silently do nothing.
    ///
    /// A path containing a glob metacharacter grants nothing either, and that is the
    /// load-bearing part. A grant is stored as a *pattern*, and patterns are matched
    /// with ``wildcardMatch``, where `*` and `?` are the two characters left
    /// unescaped. The path comes from the model, and `write` creates whatever file it
    /// is named — so a model that asks to write `*` gets a prompt reading
    /// "Always allow *" which, if approved, persists `{"write": {"*": "allow"}}` to
    /// the global config: exactly the blanket rule scoping this was meant to remove.
    /// `read *.env` is worse, since it disables the secret guard the baseline exists
    /// to enforce. There is no escape syntax to fall back on (`\` is normalised to
    /// `/` on both sides), so such a call simply gets no persistable grant and the
    /// answer degrades to "allow once".
    ///
    /// Only path-keyed tools come through here. `bash` grants are *deliberately*
    /// globs (`git *`), which is why this cannot live at the persistence boundary.
    private func pathGrant(_ path: String) -> [String] {
        // Anchored to the workspace, so the grant is PROJECT-LOCAL by construction.
        //
        // Grants are persisted to the user's GLOBAL settings.json, so a bare relative
        // pattern authorised the same relative path in every other project on the
        // machine — "Always allow src/index.js" in one repo silently covered
        // `src/index.js` in all of them. An absolute pattern cannot travel. It matches
        // because the engine also checks the absolute spelling of every request (see
        // `aliases(for:)`), and it does not weaken the `.env` guard: `wildcardMatch`
        // compiles `*` to `.*` with no path-separator special case, so `*.env` still
        // matches `/abs/project/.env`.
        let anchored = absolutePath(path)
        guard !anchored.isEmpty, !anchored.contains("*"), !anchored.contains("?") else { return [] }
        return [anchored]
    }

    /// The other spellings of `path` that name the same file, for the engine to check
    /// alongside the model's own spelling.
    private func aliases(for path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let anchored = absolutePath(path)
        return anchored.isEmpty || anchored == path ? [] : [anchored]
    }

    /// `path` resolved against the workspace and lexically standardised (`.` and `..`
    /// folded, a leading `./` dropped). Deliberately NOT symlink-resolved: a grant
    /// must not change meaning because a symlink was re-pointed, and on macOS that
    /// would also rewrite `/tmp` to `/private/tmp` inconsistently.
    private func absolutePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let base = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }

    private func bashSpec(_ arguments: JSONValue) -> PermissionRequestSpec {
        let command = arguments["command"]?.stringValue ?? ""
        let subcommands = ShellCommand.split(command)
        // Each sub-command is checked separately, so a `rm *` deny catches a chained
        // or substituted `rm -rf /` that a single whole-string pattern would miss.
        let patterns = subcommands.isEmpty ? [command] : subcommands
        var always: [String] = []
        var seen: Set<String> = []
        for pattern in patterns {
            // Drop leading `NAME=value` assignments so `FOO=bar rm x` grants `rm *`.
            let tokens = ShellCommand.stripEnvAssignments(ShellCommand.tokenize(pattern))
            let glob = bashAlwaysGlob(tokens)
            if seen.insert(glob).inserted { always.append(glob) }
        }
        // bash can write a config file via a redirect (`echo … > settings.json`),
        // which no write/edit guard sees; treat a command that names a protected file
        // as config-protected (force a prompt, no "always").
        let protectedBash = mentionsProtected(command)
        return PermissionRequestSpec(
            permission: "bash",
            patterns: patterns,
            always: protectedBash ? [] : always,
            metadata: ["command": .string(command)],
            configProtected: protectedBash
        )
    }

    /// The `path` / `file_path` argument, defensively (mirrors the tool layer's alias).
    private func pathArgument(_ arguments: JSONValue) -> String {
        arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue ?? ""
    }

    /// Whether a write/edit target is a protected config file. Resolves a relative
    /// path against the workspace, follows symlinks in existing components, and
    /// compares case-/unicode-insensitively (macOS's default filesystem is
    /// case-insensitive, so `Settings.json` must not slip past `settings.json`).
    private func isProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let base = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let url = URL(fileURLWithPath: path, relativeTo: base)
        // Check both the lexical and the symlink-resolved forms.
        let candidates = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        return candidates.contains { protectedPaths.contains(Self.canonical($0)) }
    }

    /// Whether a bash command text names any protected config file (over-approximate).
    private func mentionsProtected(_ command: String) -> Bool {
        let lower = command.lowercased()
        return protectedMarkers.contains { lower.contains($0) }
    }

    /// A path normalized for the case-insensitive membership test: symlink-resolved,
    /// case-folded, and unicode-precomposed.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

/// The default baseline permission config (the user's Phase 8 choice): ask for
/// everything, auto-allow the read-only tools, and keep the `.env` secret guard on
/// `read`. User config (settings.json) merges after this, session grants after that.
public func defaultBaselinePermissionConfig() -> PermissionConfig {
    [
        PermissionConfigEntry(permission: "*", value: .action(.ask)),
        PermissionConfigEntry(
            permission: "read",
            value: .map([
                PatternRule(pattern: "*", action: .allow),
                PatternRule(pattern: "*.env", action: .ask),
                PatternRule(pattern: "*.env.*", action: .ask),
                PatternRule(pattern: "*.env.example", action: .allow),
            ])
        ),
        PermissionConfigEntry(permission: "ls", value: .action(.allow)),
        PermissionConfigEntry(permission: "find", value: .action(.allow)),
        PermissionConfigEntry(permission: "grep", value: .action(.allow)),
        PermissionConfigEntry(permission: "glob", value: .action(.allow)),
        PermissionConfigEntry(permission: "todowrite", value: .action(.allow)),
        PermissionConfigEntry(permission: "finish", value: .action(.allow)),
        PermissionConfigEntry(permission: "question", value: .action(.ask)),
        PermissionConfigEntry(permission: "webfetch", value: .action(.ask)),
        PermissionConfigEntry(permission: "doom_loop", value: .action(.ask)),
    ]
}
