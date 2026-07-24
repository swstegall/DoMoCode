// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/bash.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// bash/grep/find/ls result rendering. The bash `$ command` header, the
// head/tail preview keeping the last `BASH_PREVIEW_LINES` and the muted duration
// footer are from `tools/bash.ts`. The grep/find/ls compact result lists and
// their per-tool preview budgets (15/20/20) are from `tools/grep.ts`,
// `tools/find.ts` and `tools/ls.ts`. The truncation notices those tools append
// to their text are surfaced as-is (recognized by their bracketed shape and
// styled distinctly), rather than rebuilt from `details`, because DoMoTools
// bakes them into the result text the model already reads.

import DoMoCore
import DoMoTUI
import DoMoTools

// MARK: - Bash

/// Renders a `bash` result: a `$ command` header, a head/tail-bounded preview of
/// the output (the last lines, where a command's result usually is), and a muted
/// duration footer.
public struct BashToolRenderer: ToolRenderer {
    /// pi's `BASH_PREVIEW_LINES`.
    static let previewLines = 5

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let command = argString(request.arguments, "command")
        let commandDisplay: String
        if let command {
            commandDisplay = command.isEmpty ? theme.muted("...") : command
        } else {
            commandDisplay = theme.error("[invalid arg]")
        }
        var header = theme.title("$ \(commandDisplay)")
        if let timeout = argInt(request.arguments, "timeout") {
            header += " " + theme.muted("(timeout \(timeout)s)")
        }
        let headerLine = clip(header, to: request.width)

        var lines = [headerLine]
        lines.append(
            contentsOf: tailBodyLines(
                request.result.text,
                width: request.width,
                maxLines: Self.previewLines,
                expanded: request.expanded,
                theme: theme
            )
        )

        // The exit status is already in the body text (the tool appends it); the
        // duration is only in `details`, so surface it as a muted footer.
        if let durationMs = request.result.details["durationMs"]?.intValue {
            lines.append(clip(theme.muted("Took \(formatDuration(durationMs))"), to: request.width))
        }
        return lines
    }
}

/// Milliseconds as `1.2s`, matching pi's `formatDuration`. Formatted by hand
/// rather than with `String(format:)`, whose varargs initializer is `unsafe`
/// under `.strictMemorySafety()`.
private nonisolated func formatDuration(_ milliseconds: Int) -> String {
    let tenths = (milliseconds + 50) / 100
    return "\(tenths / 10).\(tenths % 10)s"
}

// MARK: - Grep

/// Renders a `grep` result: a `grep <pattern>` header and a compact list of
/// matches, truncated to a bounded preview.
public struct GrepToolRenderer: ToolRenderer {
    /// pi shows 15 lines of a collapsed grep.
    static let previewLines = 15

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        searchRender(
            request,
            title: "grep",
            primaryKeys: ["pattern"],
            maxLines: Self.previewLines
        )
    }
}

// MARK: - Find

/// Renders a `find` result: a `find <pattern>` header and a compact list of
/// paths, truncated to a bounded preview.
public struct FindToolRenderer: ToolRenderer {
    /// pi shows 20 lines of a collapsed find.
    static let previewLines = 20

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        searchRender(
            request,
            title: "find",
            primaryKeys: ["pattern"],
            maxLines: Self.previewLines
        )
    }
}

// MARK: - Ls

/// Renders an `ls` result: an `ls <path>` header and a compact directory
/// listing, truncated to a bounded preview.
public struct LsToolRenderer: ToolRenderer {
    /// pi shows 20 lines of a collapsed ls.
    static let previewLines = 20

    public init() {}

    public func render(_ request: ToolRenderRequest) -> [String] {
        let theme = request.theme
        let rawPath = argString(request.arguments, "path")
        let headerLine = clip(
            theme.title("ls") + " "
                + renderToolPath(rawPath, theme: theme, home: request.homeDirectory, emptyFallback: "."),
            to: request.width
        )
        if request.result.isError {
            return [headerLine] + errorLines(request)
        }
        return [headerLine]
            + bodyLines(
                request.result.text,
                width: request.width,
                maxLines: Self.previewLines,
                expanded: request.expanded,
                theme: theme
            )
    }
}

// MARK: - Shared search rendering

/// The header-plus-compact-list shape grep and find share: a `<title> <primary>`
/// header (the primary is the search pattern, styled as an argument) over a
/// bounded list of the tool's text output.
private nonisolated func searchRender(
    _ request: ToolRenderRequest,
    title: String,
    primaryKeys: [String],
    maxLines: Int
) -> [String] {
    let theme = request.theme
    let primary = firstArg(request.arguments, primaryKeys)
    let primaryDisplay: String
    if let primary {
        primaryDisplay = primary.isEmpty ? theme.muted("...") : theme.accent(primary)
    } else {
        primaryDisplay = theme.error("[invalid arg]")
    }
    var header = theme.title(title) + " " + primaryDisplay
    if let path = argString(request.arguments, "path"), !path.isEmpty {
        header += " " + theme.muted("in \(shortenPath(path, home: request.homeDirectory))")
    }
    let headerLine = clip(header, to: request.width)

    if request.result.isError {
        return [headerLine] + errorLines(request)
    }
    return [headerLine]
        + bodyLines(
            request.result.text,
            width: request.width,
            maxLines: maxLines,
            expanded: request.expanded,
            theme: theme
        )
}

/// The string value at the first present key among `keys`, or `nil`.
private nonisolated func firstArg(_ arguments: JSONValue, _ keys: [String]) -> String? {
    for key in keys {
        guard let value = arguments[key], value != .null else { continue }
        return value.stringValue
    }
    return nil
}
