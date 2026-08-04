// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// One line of "what is this tool call actually doing", derived from the arguments
// the `tool_start` frame already carries. The transcript used to show only the
// tool's NAME, which makes every `edit` look like every other `edit` — and makes a
// call that is merely slow indistinguishable from one that is stuck. Naming the
// target is the cheapest possible fix for that.
//
// Tool-aware, mirroring `DoMoPermissions.PermissionRequestFactory`: the same
// argument a call is *gated* on is the one worth showing, so the transcript row and
// the approval modal name the same thing.

import DoMoCore
import DoMoTUI

/// A compact, single-line summary of a tool call's arguments — the file path, the
/// shell command, the search pattern — or an empty string when there is nothing
/// worth saying.
///
/// Never returns a multi-line string: a newline in a shell command (a heredoc, a
/// multi-line script) is folded to `⏎` so the row stays one line and the caller's
/// width budget holds.
nonisolated func toolCallDetail(name: String, arguments: JSONValue) -> String {
    let raw: String
    switch name {
    case "bash":
        raw = arguments["command"]?.stringValue ?? ""
    case "read", "write", "edit":
        raw = pathArgument(arguments)
    case "apply_patch":
        raw = patchPaths(arguments)
    case "websearch":
        raw = arguments["query"]?.stringValue ?? ""
    case "ls":
        raw = arguments["path"]?.stringValue ?? "."
    case "grep":
        let pattern = arguments["pattern"]?.stringValue ?? ""
        let path = arguments["path"]?.stringValue
        raw = [pattern, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  in  ")
    case "find":
        let pattern = arguments["pattern"]?.stringValue ?? arguments["glob"]?.stringValue ?? ""
        let path = arguments["path"]?.stringValue
        raw = [pattern, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  in  ")
    default:
        // An unknown built-in or any MCP tool: show its scalar arguments as
        // `key=value`, in sorted order so the row is stable frame to frame.
        raw = genericSummary(arguments)
    }
    // Tool arguments are model-controlled, so the summary is untrusted text like any
    // other: an `ESC[2J` in a "path" would otherwise wipe the page from the row that
    // is supposed to be telling you what the tool is about to do.
    return sanitizeUntrustedText(collapseToOneLine(raw))
}

/// The `path` / `file_path` argument, defensively — the tool layer accepts both
/// spellings, so the summary must too or an `edit` row reads blank.
private func pathArgument(_ arguments: JSONValue) -> String {
    arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue ?? ""
}

private func patchPaths(_ arguments: JSONValue) -> String {
    let patch = arguments["patch"]?.stringValue ?? ""
    let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
    var paths: [String] = []
    for line in patch.components(separatedBy: .newlines) {
        for marker in markers where line.hasPrefix(marker) {
            let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
    }
    return paths.isEmpty ? "patch" : paths.joined(separator: ", ")
}

/// `key=value` for the scalar arguments, sorted by key. Nested objects and arrays
/// are reported by shape (`edits[2]`) rather than dumped: the row has one line.
private func genericSummary(_ arguments: JSONValue) -> String {
    guard let object = arguments.objectValue, !object.isEmpty else { return "" }
    var parts: [String] = []
    for key in object.keys.sorted() {
        guard let value = object[key] else { continue }
        switch value {
        case .string(let text):
            parts.append("\(key)=\(collapseToOneLine(text))")
        case .int(let number):
            parts.append("\(key)=\(number)")
        case .double(let number):
            parts.append("\(key)=\(number)")
        case .bool(let flag):
            parts.append("\(key)=\(flag)")
        case .array(let items):
            parts.append("\(key)[\(items.count)]")
        case .object, .null:
            continue
        }
    }
    return parts.joined(separator: "  ")
}
