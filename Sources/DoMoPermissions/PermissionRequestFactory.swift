// Copyright (c) 2025 opencode contributors. MIT license.
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Turns a raw tool call into a ``PermissionRequestSpec``. Tool-aware: bash is split
// per sub-command with an arity-prefix "always" glob; read/write/edit key on the file
// path (so the `.env` guard sees a real path and the config self-edit guard can fire);
// an unknown name (an MCP tool) defaults to `*` so it is treated like any untrusted
// call. Reads arguments defensively (the `file_path`/`path` alias, string values).

import DoMoCore
import Foundation

/// Builds permission specs from tool calls. Holds the workspace root (to resolve
/// relative paths) and the absolute config-file paths the self-edit guard protects.
public struct PermissionRequestFactory: Sendable {
    private let workingDirectory: String
    /// Absolute paths of the permission/settings/trust files the model must not
    /// silently overwrite via `write`/`edit` (Phase 8a self-edit guard).
    private let protectedPaths: Set<String>

    public init(workingDirectory: String, protectedPaths: Set<String> = []) {
        self.workingDirectory = workingDirectory
        self.protectedPaths = protectedPaths
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
                always: ["*"],
                metadata: ["filepath": .string(path)],
                configProtected: isProtected(path)
            )
        case "read":
            // read keys on the real path so the `.env` secret guard can classify it.
            let path = pathArgument(arguments)
            return PermissionRequestSpec(permission: "read", patterns: [path], always: ["*"], metadata: ["filepath": .string(path)])
        case "ls":
            let path = arguments["path"]?.stringValue ?? "."
            return PermissionRequestSpec(permission: "ls", patterns: [path], always: ["*"])
        default:
            // find/grep/todo/etc. and every MCP tool: a coarse `*` resource. Known
            // read-only tools are auto-allowed by the baseline; an unknown MCP name is
            // gated exactly like an untrusted call (default `ask`).
            return PermissionRequestSpec(permission: toolName, patterns: ["*"], always: ["*"])
        }
    }

    private func bashSpec(_ arguments: JSONValue) -> PermissionRequestSpec {
        let command = arguments["command"]?.stringValue ?? ""
        let subcommands = ShellCommand.split(command)
        // Each sub-command is checked separately, so a `rm *` deny catches a chained
        // `echo hi && rm -rf /` that a single whole-string pattern would miss.
        let patterns = subcommands.isEmpty ? [command] : subcommands
        var always: [String] = []
        var seen: Set<String> = []
        for pattern in patterns {
            let glob = bashAlwaysGlob(ShellCommand.tokenize(pattern))
            if seen.insert(glob).inserted { always.append(glob) }
        }
        return PermissionRequestSpec(
            permission: "bash",
            patterns: patterns,
            always: always,
            metadata: ["command": .string(command)]
        )
    }

    /// The `path` / `file_path` argument, defensively (mirrors the tool layer's alias).
    private func pathArgument(_ arguments: JSONValue) -> String {
        arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue ?? ""
    }

    /// Whether a write/edit target is a protected config file. Resolves a relative
    /// path against the workspace and collapses `.`/`..` before the membership check.
    /// (Symlinks are not resolved — a deliberate v1 limitation.)
    private func isProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let base = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let resolved = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
        return protectedPaths.contains(resolved)
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
    ]
}
