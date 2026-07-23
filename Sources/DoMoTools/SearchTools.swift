// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/ls.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// `ls` listing and truncation from `tools/ls.ts`; `find`'s `fd` invocation and
// relativization from `tools/find.ts`; `grep`'s ripgrep `--json` handling,
// match/context formatting and line truncation from `tools/grep.ts`. Where pi
// shells out to `fd`/`rg` unconditionally (downloading them if missing), this
// falls back to a `FileWalker`-based pure-Swift search when the binary is not
// installed — the tools do not assume it exists.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

// MARK: - Shared helpers

/// Whether a failure is "the path is not there", the case the search tools turn
/// into a `Path not found` message rather than propagating. Accepts `any Error`
/// so it works from both typed- and untyped-throws catch sites.
private func isNotFound(_ error: any Error) -> Bool {
    guard let domo = error as? DoMoError, case .file(_, let errno) = domo.kind else { return false }
    return errno == .noSuchFileOrDirectory || errno == .notDirectory
}

/// Re-expresses `path` relative to `base`, forward-slashed. Falls back to the
/// basename when `path` is not under `base`.
private func relativizePosix(_ path: String, to base: String) -> String {
    if path == base { return "" }
    let prefix = base.hasSuffix("/") ? base : base + "/"
    if path.hasPrefix(prefix) {
        return String(path.dropFirst(prefix.count))
    }
    return FilePath(path).lastComponent?.string ?? path
}

/// The output-capture budget for an internal `rg`/`fd` run.
///
/// ``Shell`` only offers a head+tail byte window, and a truncated middle would
/// corrupt `rg --json`'s newline-delimited records. A large head with no tail
/// keeps the records from the start intact — which is exactly the order results
/// are consumed in, since both tools are capped by result count. pi instead
/// kills the child once the cap is reached; without an argv-level exec seam that
/// early kill is not available here, so the budget is the bound.
private let searchOutputLimits = ShellOutputLimits(head: 16 * 1024 * 1024, tail: 0)

/// Splits a captured stream's retained bytes into non-empty lines.
///
/// A line left partial by the head budget is only reachable for `rg --json`
/// (fd is bounded by `--max-results`), where a truncated JSON record fails to
/// parse and is skipped downstream, so dropping empties is enough here.
private func completeLines(_ stream: ShellStreamOutput) -> [String] {
    String(decoding: stream.bytes, as: UTF8.self)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

// MARK: - ls

/// Lists a directory's immediate entries, dotfiles included, directories marked.
public struct LsTool: Tool {

    public init() {}

    public let name = "ls"

    private static let defaultLimit = 500

    public let description = """
        List directory contents. Returns entries sorted alphabetically, with '/' suffix for \
        directories. Includes dotfiles. Output is truncated to \(defaultLimit) entries or \
        \(OutputTruncation.defaultMaxBytes / 1024)KB (whichever is hit first).
        """

    public var parameters: JSONSchema {
        .object(
            .optional("path", .string(description: "Directory to list (default: current directory)")),
            .optional("limit", .number(description: "Maximum number of entries to return (default: 500)"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let requested = (try args.optionalString("path")) ?? "."
            let limit = (try args.optionalInt("limit")) ?? Self.defaultLimit
            return try await list(requested.isEmpty ? "." : requested, limit: limit, context: context)
        }
    }

    private func list(_ requested: String, limit: Int, context: ToolContext) async throws(DoMoError) -> ToolResult {
        let directory = FilePath(requested)
        let display = context.fileSystem.absolutePath(directory).string

        let info: FileMetadata
        do {
            info = try await context.fileSystem.metadata(directory)
        } catch {
            if isNotFound(error) { return ToolResult.error("Path not found: \(display)") }
            throw error
        }
        guard info.kind != .file else {
            return ToolResult.error("Not a directory: \(display)")
        }

        var entries = try await context.fileSystem.list(directory)
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var results: [String] = []
        var entryLimitReached = false
        for entry in entries {
            guard results.count < limit else {
                entryLimitReached = true
                break
            }
            switch entry.kind {
            case .directory:
                results.append(entry.name + "/")
            case .file:
                results.append(entry.name)
            case .symlink:
                // pi follows the link to stat it, marks a link-to-directory with
                // `/`, and silently drops a broken link (its stat throws).
                guard
                    let target = try? await context.base.canonicalPath(entry.path),
                    let targetInfo = try? await context.base.metadata(target)
                else { continue }
                results.append(entry.name + (targetInfo.kind == .directory ? "/" : ""))
            }
        }

        guard !results.isEmpty else {
            return ToolResult.text("(empty directory)")
        }

        let truncation = OutputTruncation.head(results.joined(separator: "\n"), maxLines: .max)
        var output = truncation.content
        var notices: [String] = []
        if entryLimitReached {
            notices.append("\(limit) entries limit reached. Use limit=\(limit * 2) for more")
        }
        if truncation.truncated {
            notices.append("\(OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)) limit reached")
        }
        if !notices.isEmpty {
            output += "\n\n[\(notices.joined(separator: ". "))]"
        }

        let details: JSONValue = .object([
            "entryLimitReached": entryLimitReached ? .int(limit) : .null,
            "truncated": .bool(truncation.truncated),
        ])
        return ToolResult.text(output, details: details)
    }
}

// MARK: - find

/// Finds files by glob, via `fd` when installed and a `FileWalker` otherwise.
public struct FindTool: Tool {

    public init() {}

    public let name = "find"

    private static let defaultLimit = 1000

    public let description = """
        Search for files by glob pattern. Returns matching file paths relative to the search \
        directory. Respects .gitignore. Output is truncated to \(defaultLimit) results or \
        \(OutputTruncation.defaultMaxBytes / 1024)KB (whichever is hit first).
        """

    public var parameters: JSONSchema {
        .object(
            .required(
                "pattern",
                .string(description: "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'")
            ),
            .optional("path", .string(description: "Directory to search in (default: current directory)")),
            .optional("limit", .number(description: "Maximum number of results (default: 1000)"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let pattern = try args.requiredString("pattern")
            let searchDir = (try args.optionalString("path")) ?? "."
            let limit = (try args.optionalInt("limit")) ?? Self.defaultLimit

            let requested = FilePath(searchDir.isEmpty ? "." : searchDir)
            let display = context.fileSystem.absolutePath(requested).string
            let resolved: FilePath
            do {
                // Resolve through the *sandboxed* filesystem, which rebases a
                // relative path onto the sandbox root before canonicalizing — the
                // sandbox alone would resolve `.` against the process cwd.
                resolved = try await context.fileSystem.canonicalPath(requested)
            } catch {
                if isNotFound(error) { return ToolResult.error("Path not found: \(display)") }
                throw error
            }

            let relatives: [String]
            if let fd = context.toolLocator.locate("fd") {
                relatives = try await findWithFd(fd, pattern: pattern, root: resolved, limit: limit, context: context)
            } else {
                relatives = try await findWithWalker(pattern: pattern, root: resolved, limit: limit, context: context)
            }

            guard !relatives.isEmpty else {
                return ToolResult.text("No files found matching pattern")
            }
            return Self.formatResults(relatives, limit: limit)
        }
    }

    private func findWithFd(
        _ fd: FilePath,
        pattern: String,
        root: FilePath,
        limit: Int,
        context: ToolContext
    ) async throws(DoMoError) -> [String] {
        var arguments = ["--glob", "--color=never", "--hidden"]
        if !(await isInsideGitRepository(root, base: context.base)) {
            arguments.append("--no-require-git")
        }
        arguments.append(contentsOf: ["--max-results", String(limit)])

        // fd matches the basename unless --full-path is set, in which case a
        // path-shaped pattern needs a leading **/ to match anywhere in the tree.
        var effectivePattern = pattern
        if pattern.contains("/") {
            arguments.append("--full-path")
            if !pattern.hasPrefix("/") && !pattern.hasPrefix("**/") && pattern != "**" {
                effectivePattern = "**/\(pattern)"
            }
        }
        arguments.append(contentsOf: ["--", effectivePattern, root.string])

        let command = ([singleQuoted(fd.string)] + arguments.map(singleQuoted)).joined(separator: " ")
        let result = try await context.shell.run(
            ShellRequest(
                command,
                workingDirectory: context.workingDirectory,
                environment: context.environment,
                limits: searchOutputLimits
            )
        )

        let lines = completeLines(result.stdout)
        if lines.isEmpty, let code = result.exitCode, code != 0 {
            let message = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DoMoError(.toolExecution(tool: name), message.isEmpty ? "fd exited with code \(code)" : message)
        }
        return lines.map { relativizePosix($0.trimmingCharacters(in: .whitespaces), to: root.string) }
    }

    private func findWithWalker(
        pattern: String,
        root: FilePath,
        limit: Int,
        context: ToolContext
    ) async throws(DoMoError) -> [String] {
        let glob = GitignorePattern(line: pattern)
        var options = FileWalker.Options()
        options.includeHidden = true
        options.includeDirectories = true
        options.respectIgnoreFiles = true
        options.maximumResults = 100_000
        let outcome = try await FileWalker(fileSystem: context.fileSystem, options: options).walk(root)

        var matches: [String] = []
        for entry in outcome.entries {
            guard matches.count < limit else { break }
            let isDirectory = entry.metadata.kind == .directory
            if let glob, glob.matches(entry.relativePath, isDirectory: isDirectory) {
                matches.append(entry.relativePath)
            }
        }
        return matches
    }

    private static func formatResults(_ relatives: [String], limit: Int) -> ToolResult {
        let resultLimitReached = relatives.count >= limit
        let truncation = OutputTruncation.head(relatives.joined(separator: "\n"), maxLines: .max)
        var output = truncation.content
        var notices: [String] = []
        if resultLimitReached {
            notices.append("\(limit) results limit reached. Use limit=\(limit * 2) for more, or refine pattern")
        }
        if truncation.truncated {
            notices.append("\(OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)) limit reached")
        }
        if !notices.isEmpty {
            output += "\n\n[\(notices.joined(separator: ". "))]"
        }
        let details: JSONValue = .object([
            "resultLimitReached": resultLimitReached ? .int(limit) : .null,
            "truncated": .bool(truncation.truncated),
        ])
        return ToolResult.text(output, details: details)
    }
}

/// Whether any ancestor of `path` (up to the filesystem root) holds a `.git`.
/// fd is git-aware inside a repo and needs `--no-require-git` outside one.
private func isInsideGitRepository(_ path: FilePath, base: some FileSystem) async -> Bool {
    var current = path
    while true {
        if (try? await base.exists(current.appending(".git"))) == true { return true }
        var parent = current
        parent.removeLastComponent()
        if parent.isEmpty || parent.string == current.string { return false }
        current = parent
    }
}

// MARK: - grep

/// Searches file contents, via `ripgrep` when installed and a `FileWalker` +
/// `NSRegularExpression` scan otherwise.
public struct GrepTool: Tool {

    public init() {}

    public let name = "grep"

    private static let defaultLimit = 100

    public let description = """
        Search file contents for a pattern. Returns matching lines with file paths and line numbers. \
        Respects .gitignore. Output is truncated to \(defaultLimit) matches or \
        \(OutputTruncation.defaultMaxBytes / 1024)KB (whichever is hit first). Long lines are \
        truncated to \(OutputTruncation.grepMaxLineLength) chars.
        """

    public var parameters: JSONSchema {
        .object(
            .required("pattern", .string(description: "Search pattern (regex or literal string)")),
            .optional("path", .string(description: "Directory or file to search (default: current directory)")),
            .optional("glob", .string(description: "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'")),
            .optional("ignoreCase", .boolean(description: "Case-insensitive search (default: false)")),
            .optional(
                "literal",
                .boolean(description: "Treat pattern as literal string instead of regex (default: false)")
            ),
            .optional(
                "context",
                .number(description: "Number of lines to show before and after each match (default: 0)")
            ),
            .optional("limit", .number(description: "Maximum number of matches to return (default: 100)"))
        )
    }

    /// One raw match, before formatting.
    private struct Match {
        var path: FilePath
        var displayPath: String
        var lineNumber: Int
        var lineText: String?
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let pattern = try args.requiredString("pattern")
            let searchDir = (try args.optionalString("path")) ?? "."
            let glob = try args.optionalString("glob")
            let ignoreCase = (try args.optionalBool("ignoreCase")) ?? false
            let literal = (try args.optionalBool("literal")) ?? false
            let contextLines = max(0, (try args.optionalInt("context")) ?? 0)
            let limit = max(1, (try args.optionalInt("limit")) ?? Self.defaultLimit)

            let requested = FilePath(searchDir.isEmpty ? "." : searchDir)
            let display = context.fileSystem.absolutePath(requested).string
            let resolved: FilePath
            let info: FileMetadata
            do {
                // See FindTool: resolve through the sandboxed filesystem so a
                // relative path rebases onto the sandbox root, not the cwd.
                resolved = try await context.fileSystem.canonicalPath(requested)
                info = try await context.base.metadata(resolved)
            } catch {
                if isNotFound(error) { return ToolResult.error("Path not found: \(display)") }
                throw error
            }
            let isDirectory = info.kind == .directory

            var linesTruncated = false
            let matches: [Match]
            var matchLimitReached = false
            if let rg = context.toolLocator.locate("rg") {
                let outcome = try await grepWithRipgrep(
                    rg, pattern: pattern, root: resolved, isDirectory: isDirectory,
                    glob: glob, ignoreCase: ignoreCase, literal: literal, limit: limit, context: context
                )
                if let error = outcome.error { return error }
                matches = outcome.matches
                matchLimitReached = outcome.limitReached
            } else {
                let outcome = try await grepWithWalker(
                    pattern: pattern, root: resolved, isDirectory: isDirectory,
                    glob: glob, ignoreCase: ignoreCase, literal: literal, limit: limit, context: context
                )
                if let error = outcome.error { return error }
                matches = outcome.matches
                matchLimitReached = outcome.limitReached
            }

            guard !matches.isEmpty else {
                return ToolResult.text("No matches found")
            }

            var outputLines: [String] = []
            var fileCache: [String: [String]] = [:]
            for match in matches {
                if contextLines == 0, let lineText = match.lineText {
                    let sanitized = Self.sanitizeMatchLine(lineText)
                    let truncated = OutputTruncation.truncateLine(sanitized)
                    if truncated.wasTruncated { linesTruncated = true }
                    outputLines.append("\(match.displayPath):\(match.lineNumber): \(truncated.text)")
                } else {
                    let lines = await Self.fileLines(match.path, cache: &fileCache, context: context)
                    let block = Self.formatBlock(
                        displayPath: match.displayPath, lines: lines,
                        lineNumber: match.lineNumber, contextLines: contextLines
                    )
                    if block.truncated { linesTruncated = true }
                    outputLines.append(contentsOf: block.lines)
                }
            }

            let truncation = OutputTruncation.head(outputLines.joined(separator: "\n"), maxLines: .max)
            var output = truncation.content
            var notices: [String] = []
            if matchLimitReached {
                notices.append("\(limit) matches limit reached. Use limit=\(limit * 2) for more, or refine pattern")
            }
            if truncation.truncated {
                notices.append("\(OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)) limit reached")
            }
            if linesTruncated {
                notices.append(
                    "Some lines truncated to \(OutputTruncation.grepMaxLineLength) chars. Use read tool to see full lines"
                )
            }
            if !notices.isEmpty {
                output += "\n\n[\(notices.joined(separator: ". "))]"
            }

            let details: JSONValue = .object([
                "matchLimitReached": matchLimitReached ? .int(limit) : .null,
                "truncated": .bool(truncation.truncated),
                "linesTruncated": .bool(linesTruncated),
            ])
            return ToolResult.text(output, details: details)
        }
    }

    // MARK: ripgrep

    private struct GrepOutcome {
        var matches: [Match] = []
        var limitReached = false
        var error: ToolResult?
    }

    private func grepWithRipgrep(
        _ rg: FilePath,
        pattern: String,
        root: FilePath,
        isDirectory: Bool,
        glob: String?,
        ignoreCase: Bool,
        literal: Bool,
        limit: Int,
        context: ToolContext
    ) async throws(DoMoError) -> GrepOutcome {
        var arguments = ["--json", "--line-number", "--color=never", "--hidden"]
        if ignoreCase { arguments.append("--ignore-case") }
        if literal { arguments.append("--fixed-strings") }
        if let glob { arguments.append(contentsOf: ["--glob", glob]) }
        arguments.append(contentsOf: ["--", pattern, root.string])

        let command = ([singleQuoted(rg.string)] + arguments.map(singleQuoted)).joined(separator: " ")
        let result = try await context.shell.run(
            ShellRequest(
                command,
                workingDirectory: context.workingDirectory,
                environment: context.environment,
                limits: searchOutputLimits
            )
        )

        var outcome = GrepOutcome()
        for line in completeLines(result.stdout) {
            guard outcome.matches.count < limit else {
                outcome.limitReached = true
                break
            }
            guard let event = try? JSONValue(parsing: line), event["type"]?.stringValue == "match" else { continue }
            guard
                let filePath = event["data"]?["path"]?["text"]?.stringValue,
                let lineNumber = event["data"]?["line_number"]?.intValue
            else { continue }
            let path = FilePath(filePath)
            outcome.matches.append(
                Match(
                    path: path,
                    displayPath: isDirectory ? relativizePosix(filePath, to: root.string) : (path.lastComponent?.string ?? filePath),
                    lineNumber: lineNumber,
                    lineText: event["data"]?["lines"]?["text"]?.stringValue
                )
            )
            if outcome.matches.count >= limit { outcome.limitReached = true }
        }

        // rg exits 1 for "no matches" and 2 for a real error (bad regex,
        // unreadable path); pi treats only the latter as a failure.
        if outcome.matches.isEmpty, let code = result.exitCode, code != 0, code != 1 {
            let message = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            outcome.error = ToolResult.error(message.isEmpty ? "ripgrep exited with code \(code)" : message)
        }
        return outcome
    }

    // MARK: pure-Swift fallback

    private func grepWithWalker(
        pattern: String,
        root: FilePath,
        isDirectory: Bool,
        glob: String?,
        ignoreCase: Bool,
        literal: Bool,
        limit: Int,
        context: ToolContext
    ) async throws(DoMoError) -> GrepOutcome {
        let regexPattern = literal ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        var regexOptions: NSRegularExpression.Options = []
        if ignoreCase { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: regexOptions) else {
            return GrepOutcome(error: ToolResult.error("Invalid regex pattern: \(pattern)"))
        }

        var targets: [(path: FilePath, display: String)] = []
        if isDirectory {
            let globPattern = glob.flatMap { GitignorePattern(line: $0) }
            var options = FileWalker.Options()
            options.includeHidden = true
            options.respectIgnoreFiles = true
            options.includeDirectories = false
            options.maximumResults = 100_000
            let outcome = try await FileWalker(fileSystem: context.fileSystem, options: options).walk(root)
            for entry in outcome.entries {
                if let globPattern, !globPattern.matches(entry.relativePath, isDirectory: false) { continue }
                targets.append((entry.metadata.path, entry.relativePath))
            }
        } else {
            targets = [(root, root.lastComponent?.string ?? root.string)]
        }

        var outcome = GrepOutcome()
        for target in targets {
            if outcome.matches.count >= limit {
                outcome.limitReached = true
                break
            }
            guard let bytes = try? await context.base.read(target.path) else { continue }
            guard case .text = FileContentProbe.classify(bytes) else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if outcome.matches.count >= limit {
                    outcome.limitReached = true
                    break
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    outcome.matches.append(
                        Match(path: target.path, displayPath: target.display, lineNumber: index + 1, lineText: line)
                    )
                }
            }
        }
        return outcome
    }

    // MARK: Formatting

    /// pi's per-match sanitization: fold CRLF to LF, drop stray CR, strip one
    /// trailing newline.
    private static func sanitizeMatchLine(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    private static func fileLines(
        _ path: FilePath,
        cache: inout [String: [String]],
        context: ToolContext
    ) async -> [String] {
        if let cached = cache[path.string] { return cached }
        let lines: [String]
        if let bytes = try? await context.base.read(path) {
            let text = String(decoding: bytes, as: UTF8.self)
            lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        } else {
            lines = []
        }
        cache[path.string] = lines
        return lines
    }

    private static func formatBlock(
        displayPath: String,
        lines: [String],
        lineNumber: Int,
        contextLines: Int
    ) -> (lines: [String], truncated: Bool) {
        guard !lines.isEmpty else {
            return (["\(displayPath):\(lineNumber): (unable to read file)"], false)
        }
        let start = contextLines > 0 ? max(1, lineNumber - contextLines) : lineNumber
        // Clamp before adding so an absurd `context` (e.g. `Int.max`) cannot
        // overflow `lineNumber + contextLines` and trap the process.
        let end: Int
        if contextLines > 0 {
            end = contextLines >= lines.count - lineNumber ? lines.count : lineNumber + contextLines
        } else {
            end = lineNumber
        }
        guard start <= end else {
            return (["\(displayPath):\(lineNumber): "], false)
        }
        var block: [String] = []
        var truncated = false
        for current in start...end {
            let raw = current - 1 < lines.count ? lines[current - 1] : ""
            let sanitized = raw.replacingOccurrences(of: "\r", with: "")
            let line = OutputTruncation.truncateLine(sanitized)
            if line.wasTruncated { truncated = true }
            if current == lineNumber {
                block.append("\(displayPath):\(current): \(line.text)")
            } else {
                block.append("\(displayPath)-\(current)- \(line.text)")
            }
        }
        return (block, truncated)
    }
}
