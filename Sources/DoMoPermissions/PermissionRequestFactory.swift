// Copyright (c) 2025 opencode contributors. MIT license.
// https://github.com/anomalyco/opencode/blob/def14d96ef897ed60fd6039e9ac96a63314642ad/packages/opencode/src/permission/index.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Turns a raw tool call into a ``PermissionRequestSpec``. Tool-aware: bash is split
// per sub-command (including nested substitutions) with an arity-prefix "always" glob;
// read/write/edit key on the file path (so the `.env` guard sees a real path and the
// config self-edit guard can fire); an unknown name (normally an MCP tool) is scoped
// to the exact canonical argument payload rather than a blanket `*` grant. Reads
// arguments defensively (the `file_path`/`path` alias, string values).

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
        case "apply_patch":
            let paths = patchPaths(arguments)
            return PermissionRequestSpec(
                permission: toolName,
                patterns: paths,
                always: paths.flatMap { pathGrant($0) },
                metadata: ["filepaths": .array(paths.map { .string($0) })],
                configProtected: paths.contains(where: { isProtected($0) })
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
        case "websearch":
            let query = arguments["query"]?.stringValue ?? ""
            return PermissionRequestSpec(
                permission: "websearch",
                patterns: [query],
                always: [],
                metadata: ["query": .string(query)]
            )
        case "mcp_resource":
            let action = arguments["action"]?.stringValue?.lowercased() ?? ""
            let server = arguments["server"]?.stringValue ?? ""
            let uri = arguments["uri"]?.stringValue ?? ""
            let target = [action, server, uri].filter { !$0.isEmpty }.joined(separator: ":")
            return PermissionRequestSpec(
                permission: "mcp_resource",
                patterns: [target.isEmpty ? "*" : target],
                always: [],
                metadata: [
                    "action": .string(action),
                    "server": .string(server),
                    "uri": .string(uri),
                ]
            )
        case "skill":
            let name = arguments["name"]?.stringValue ?? ""
            return PermissionRequestSpec(
                permission: "skill",
                patterns: [name],
                always: name.isEmpty ? [] : [name],
                metadata: ["name": .string(name)]
            )
        case "background_process":
            let action = arguments["action"]?.stringValue ?? ""
            let target = arguments["command"]?.stringValue
                ?? arguments["id"]?.stringValue
                ?? "*"
            return PermissionRequestSpec(
                permission: "background_process",
                patterns: [action.isEmpty ? target : "\(action) \(target)"],
                always: [],
                metadata: [
                    "action": .string(action),
                    "command": arguments["command"] ?? .null,
                    "id": arguments["id"] ?? .null,
                ]
            )
        case "memory":
            let action = arguments["action"]?.stringValue?.lowercased() ?? ""
            if action == "list" {
                return PermissionRequestSpec(
                    permission: "memory.read",
                    patterns: ["*"],
                    always: ["*"]
                )
            }
            return PermissionRequestSpec(
                permission: "memory.write",
                patterns: ["*"],
                always: ["*"]
            )
        default:
            // Known read-only tools are auto-allowed by the baseline. Unknown names
            // (including namespaced MCP tools) are gated exactly like an untrusted
            // call, but an "allow always" grant is for this exact argument payload,
            // not the whole tool. The encoded form is opaque to glob matching: a model
            // supplied `*` or `?` can never turn the saved rule into a wildcard.
            let pattern = argumentGrant(arguments)
            return PermissionRequestSpec(permission: toolName, patterns: [pattern], always: [pattern])
        }
    }

    /// A stable, glob-inert resource for an unknown/MCP tool invocation. JSONValue's
    /// encoder sorts object keys, so the same semantic arguments produce the same
    /// grant across processes; base64url keeps wildcard metacharacters out of the
    /// persisted permission pattern.
    private func argumentGrant(_ arguments: JSONValue) -> String {
        let canonical = (try? arguments.encodedString()) ?? "null"
        let encoded = Data(canonical.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "arguments:" + encoded
    }

    /// Returns the primary tool request plus one external-directory request for
    /// every path-like bash argument that leaves the workspace. Keeping these
    /// requests separate is important: a saved bash prefix grant must not also
    /// authorize an unrelated absolute path.
    public func makeAll(toolName: String, arguments: JSONValue) -> [PermissionRequestSpec] {
        if toolName == "apply_patch" {
            return patchSpecs(arguments)
        }
        let primary = make(toolName: toolName, arguments: arguments)
        guard toolName == "bash",
              let command = arguments["command"]?.stringValue
        else { return [primary] }

        var specs = [primary]
        var seen: Set<String> = []
        for path in externalPaths(in: command) where seen.insert(path).inserted {
            specs.append(
                PermissionRequestSpec(
                    permission: "external_directory",
                    patterns: [path],
                    always: [path],
                    metadata: [
                        "filepath": .string(path),
                        "command": .string(command),
                    ]
                )
            )
        }
        return specs
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

    private func externalPaths(in command: String) -> [String] {
        var paths: [String] = []
        for fragment in ShellCommand.split(command) {
            var tokens = ShellCommand.stripEnvAssignments(ShellCommand.tokenize(fragment))
            guard !tokens.isEmpty else { continue }
            tokens.removeFirst() // The executable itself is not a data directory.

            var expectsRedirectTarget = false
            for token in tokens {
                let value = unquote(token)
                if expectsRedirectTarget {
                    expectsRedirectTarget = false
                    if let path = externalPath(value) { paths.append(path) }
                    continue
                }
                if value == ">" || value == ">>" || value == "<" || value == "<<" ||
                    value == "2>" || value == "2>>"
                {
                    expectsRedirectTarget = true
                    continue
                }
                if let redirect = redirectTarget(value) {
                    if let path = externalPath(redirect) { paths.append(path) }
                    continue
                }
                if value.hasPrefix("-") {
                    if let equals = value.firstIndex(of: "=") {
                        let suffix = String(value[value.index(after: equals)...])
                        if let path = externalPath(suffix) { paths.append(path) }
                    }
                    continue
                }
                if let path = externalPath(value) { paths.append(path) }
            }
        }
        return paths
    }

    private func externalPath(_ value: String) -> String? {
        guard looksLikePath(value) else { return nil }
        let expanded = NSString(string: value).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
            .standardizedFileURL
        let path = url.path
        let root = URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL.path
        guard path != root, !path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return path
    }

    private func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            || value.hasPrefix("~/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
            || value.contains("/")
    }

    private func redirectTarget(_ value: String) -> String? {
        for marker in [">>", "2>", "1>", "<"] where value.hasPrefix(marker) {
            let target = String(value.dropFirst(marker.count))
            return target.isEmpty ? nil : target
        }
        return nil
    }

    private func unquote(_ token: String) -> String {
        var value = token
        if value.count >= 2,
           (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("\"") && value.hasSuffix("\""))
        {
            value.removeFirst()
            value.removeLast()
        }
        return value.replacingOccurrences(of: "\\\\", with: "")
    }

    /// The `path` / `file_path` argument, defensively (mirrors the tool layer's alias).
    private func pathArgument(_ arguments: JSONValue) -> String {
        arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue ?? ""
    }

    /// The patch parser lives in DoMoTools, so the permission layer only reads
    /// its file-operation headers. Unknown or malformed patches still produce
    /// a prompt, while every recognized path receives its own deny/allow check.
    private func patchPaths(_ arguments: JSONValue) -> [String] {
        let patch = arguments["patch"]?.stringValue ?? ""
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        var paths: [String] = []
        var seen: Set<String> = []
        for line in patch.components(separatedBy: .newlines) {
            for marker in markers where line.hasPrefix(marker) {
                let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
            }
        }
        return paths.isEmpty ? [patch.isEmpty ? "" : "<unparsed patch>"] : paths
    }

    private func patchSpecs(_ arguments: JSONValue) -> [PermissionRequestSpec] {
        patchPaths(arguments).map { path in
            PermissionRequestSpec(
                permission: "apply_patch",
                patterns: [path],
                patternAliases: aliases(for: path),
                always: pathGrant(path),
                metadata: ["filepath": .string(path)],
                configProtected: isProtected(path)
            )
        }
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
        PermissionConfigEntry(permission: "session_recall", value: .action(.allow)),
        PermissionConfigEntry(permission: "memory.read", value: .action(.allow)),
        PermissionConfigEntry(permission: "question", value: .action(.ask)),
        PermissionConfigEntry(permission: "webfetch", value: .action(.ask)),
        PermissionConfigEntry(permission: "websearch", value: .action(.ask)),
        PermissionConfigEntry(permission: "mcp_resource", value: .action(.ask)),
        PermissionConfigEntry(permission: "skill", value: .action(.allow)),
        PermissionConfigEntry(permission: "doom_loop", value: .action(.ask)),
    ]
}
