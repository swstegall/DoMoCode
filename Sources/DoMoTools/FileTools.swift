// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/read.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// `read` output shape, offset/limit handling, and continuation notices are
// ported from `tools/read.ts`; `write`'s success message from `tools/write.ts`;
// the exact-string-replace edit engine — fuzzy match, uniqueness, overlap and
// no-change detection, error wording — from `tools/edit.ts` and
// `tools/edit-diff.ts`.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

// MARK: - Mutation serialization

extension FileMutationCoordinator {
    /// Runs `body` under the per-path lock, narrowing the coordinator's widened
    /// `throws` back to ``DoMoError`` — the body here only ever fails in that
    /// vocabulary, so the wrap in the second `catch` is unreachable in practice.
    func serialize<T: Sendable>(
        _ path: FilePath,
        tool: String,
        _ body: @Sendable () async throws -> T
    ) async throws(DoMoError) -> T {
        do {
            return try await withMutation(of: path) {
                try await body()
            }
        } catch let error as DoMoError {
            throw error
        } catch {
            throw DoMoError(wrapping: error, as: .toolExecution(tool: tool), "\(tool) \(path)")
        }
    }
}

// MARK: - Read

/// Reads a file: text with offset/limit windowing and truncation, images as
/// attachments, binary refused. A directory is listed, and missing names get a
/// nearby sibling suggestion when one is unambiguous.
public struct ReadTool: Tool {

    public init() {}

    public let name = "read"

    public let description = """
        Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). \
        Images are sent as attachments. For text files, output is truncated to \
        \(OutputTruncation.defaultMaxLines) lines or \(OutputTruncation.defaultMaxBytes / 1024)KB \
        (whichever is hit first). Reading a directory lists its entries. Use offset/limit for \
        large files. When you need the full file, continue with offset until complete. If a \
        path is missing, check the suggested nearby name before trying bash.
        """

    public var parameters: JSONSchema {
        .object(
            .required("path", .string(description: "Path to the file to read (relative or absolute)")),
            .optional("offset", .number(description: "Line number to start reading from (1-indexed)")),
            .optional("limit", .number(description: "Maximum number of lines to read"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let path = try args.requiredString("path", "file_path")
            let offset = try args.optionalInt("offset")
            let limit = try args.optionalInt("limit")
            return try await read(path: path, offset: offset, limit: limit, context: context)
        }
    }

    private func read(
        path: String,
        offset: Int?,
        limit: Int?,
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let filePath = FilePath(path)
        let metadata: FileMetadata
        do {
            metadata = try await context.fileSystem.metadata(filePath)
        } catch {
            if Self.isMissing(error) {
                return ToolResult.error(await Self.missingMessage(path: path, context: context))
            }
            throw error
        }

        if metadata.kind == .directory {
            return try await listDirectory(
                path: path,
                limit: limit ?? 500,
                context: context
            )
        }

        let bytes = try await context.fileSystem.read(filePath)

        switch FileContentProbe.classify(bytes) {
        case .image(let mediaType):
            return ToolResult(content: [
                .text("Read image file [\(mediaType)]"),
                .image(mediaType: mediaType, data: bytes),
            ])
        case .binary(let reason):
            return ToolResult.error(
                "Cannot read \(path): file appears to be binary (\(reason.description)). "
                    + "Use the bash tool to inspect it (for example: file, xxd, or strings)."
            )
        case .text:
            break
        }

        let decoded = try FileContentProbe.decode(bytes, path: filePath)
        let instructions = await Self.nestedInstructions(for: filePath, context: context)
        func withInstructions(_ text: String) -> String {
            guard let instructions else { return text }
            return instructions + "\n\n" + text
        }
        let allLines = decoded.text.components(separatedBy: "\n")
        let totalFileLines = allLines.count

        // pi's `offset ? max(0, offset-1) : 0`: a nil, zero, or negative offset
        // starts at the top; the parameter is 1-indexed, the array is 0-indexed.
        // Written as `> 1` rather than `max(0, offset - 1)` so a hostile `offset`
        // of `Int.min` cannot overflow the subtraction and trap the process.
        let requestedOffset = offset ?? 0
        let startLine = requestedOffset > 1 ? requestedOffset - 1 : 0
        let startLineDisplay = startLine + 1

        guard startLine < allLines.count else {
            return ToolResult.error(
                "Offset \(offset ?? startLineDisplay) is beyond end of file (\(allLines.count) lines total)"
            )
        }

        let selectedContent: String
        var userLimitedLines: Int?
        if let limit {
            // Clamp before adding so an absurd `limit` (e.g. `Int.max`) cannot
            // overflow `startLine + limit` and trap. `startLine < allLines.count`
            // holds from the guard above, so `allLines.count - startLine` is > 0.
            let take = min(max(limit, 0), allLines.count - startLine)
            let endLine = startLine + take
            selectedContent = allLines[startLine..<endLine].joined(separator: "\n")
            userLimitedLines = take
        } else {
            selectedContent = allLines[startLine...].joined(separator: "\n")
        }

        let truncation = OutputTruncation.head(selectedContent)
        let maxBytesSize = OutputTruncation.formatSize(OutputTruncation.defaultMaxBytes)

        if truncation.firstLineExceedsLimit {
            let firstLineSize = OutputTruncation.formatSize(allLines[startLine].utf8.count)
            let text =
                "[Line \(startLineDisplay) is \(firstLineSize), exceeds \(maxBytesSize) limit. "
                + "Use bash: sed -n '\(startLineDisplay)p' \(path) | head -c \(OutputTruncation.defaultMaxBytes)]"
            return ToolResult.text(withInstructions(text), details: Self.truncationDetails(truncation))
        }

        if truncation.truncated {
            let endLineDisplay = startLineDisplay + truncation.outputLines - 1
            let nextOffset = endLineDisplay + 1
            var text = truncation.content
            if truncation.truncatedBy == .lines {
                text +=
                    "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalFileLines). "
                    + "Use offset=\(nextOffset) to continue.]"
            } else {
                text +=
                    "\n\n[Showing lines \(startLineDisplay)-\(endLineDisplay) of \(totalFileLines) "
                    + "(\(maxBytesSize) limit). Use offset=\(nextOffset) to continue.]"
            }
            return ToolResult.text(withInstructions(text), details: Self.truncationDetails(truncation))
        }

        if let userLimitedLines, startLine + userLimitedLines < allLines.count {
            let remaining = allLines.count - (startLine + userLimitedLines)
            let nextOffset = startLine + userLimitedLines + 1
            let text = "\(truncation.content)\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue.]"
            return ToolResult.text(withInstructions(text))
        }

        return ToolResult.text(withInstructions(truncation.content))
    }

    private func listDirectory(
        path: String,
        limit: Int,
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let directory = FilePath(path)
        let display = context.fileSystem.absolutePath(directory).string
        var entries = try await context.fileSystem.list(directory)
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let safeLimit = max(0, limit)
        let visible = Array(entries.prefix(safeLimit))
        var lines = visible.map { entry in
            switch entry.kind {
            case .directory: return entry.name + "/"
            case .symlink: return entry.name + "@"
            case .file: return entry.name
            }
        }
        if entries.count > visible.count {
            lines.append("[\(visible.count) entries shown; use limit=\(max(1, safeLimit * 2)) for more.]")
        }
        let text: String
        if lines.isEmpty {
            text = "Directory \(display) is empty."
        } else {
            text = "Directory \(display):\n" + lines.joined(separator: "\n")
        }
        return ToolResult.text(
            text,
            details: .object([
                "directory": .string(display),
                "entryCount": .int(entries.count),
                "shown": .int(visible.count),
                "truncated": .bool(entries.count > visible.count),
            ])
        )
    }

    private static func isMissing(_ error: any Error) -> Bool {
        guard let domo = error as? DoMoError,
              case .file(_, let errno) = domo.kind
        else { return false }
        return errno == .noSuchFileOrDirectory || errno == .notDirectory
    }

    private static func missingMessage(path: String, context: ToolContext) async -> String {
        if let suggestion = await suggestion(for: path, context: context) {
            return "No such file or directory: \(path). Did you mean \(suggestion)?"
        }
        return "No such file or directory: \(path)"
    }

    private static func suggestion(for path: String, context: ToolContext) async -> String? {
        let absolute = context.fileSystem.absolutePath(FilePath(path))
        guard let requestedName = absolute.lastComponent?.string, !requestedName.isEmpty else { return nil }
        var parent = absolute
        parent.removeLastComponent()
        guard let entries = try? await context.fileSystem.list(parent) else { return nil }
        let target = requestedName.lowercased()
        let threshold = max(2, target.count / 3)
        let ranked = entries.map { entry in
            (entry.name, editDistance(target, entry.name.lowercased()))
        }
        return ranked
            .filter { $0.1 <= threshold }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
            }
            .first?.0
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = leftCharacter == rightCharacter ? 0 : 1
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + substitution
                    )
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func nestedInstructions(for path: FilePath, context: ToolContext) async -> String? {
        guard let canonical = try? await context.fileSystem.canonicalPath(path) else { return nil }
        var directory = canonical
        directory.removeLastComponent()
        var blocks: [(path: String, text: String)] = []
        let root = context.fileSystem.sandbox.root

        while directory.starts(with: root) {
            let instructionsPath = directory.appending("AGENTS.md")
            if (try? await context.fileSystem.exists(instructionsPath)) == true,
               let bytes = try? await context.fileSystem.read(instructionsPath),
               let decoded = try? FileContentProbe.decode(bytes, path: instructionsPath)
            {
                blocks.append((instructionsPath.string, decoded.text))
            }
            if directory == root { break }
            var parent = directory
            parent.removeLastComponent()
            if parent == directory { break }
            directory = parent
        }

        guard !blocks.isEmpty else { return nil }
        return blocks.reversed().map { block in
            "<directory-instructions path=\"\(block.path)\">\n\(block.text)\n</directory-instructions>"
        }.joined(separator: "\n\n")
    }

    static func truncationDetails(_ result: OutputTruncation.Result) -> JSONValue {
        .object([
            "truncated": .bool(result.truncated),
            "truncatedBy": result.truncatedBy.map { .string($0 == .lines ? "lines" : "bytes") } ?? .null,
            "totalLines": .int(result.totalLines),
            "totalBytes": .int(result.totalBytes),
            "outputLines": .int(result.outputLines),
            "outputBytes": .int(result.outputBytes),
            "firstLineExceedsLimit": .bool(result.firstLineExceedsLimit),
        ])
    }
}

// MARK: - Write

/// Writes (or overwrites) a whole file, creating parent directories.
public struct WriteTool: Tool {

    public init() {}

    public let name = "write"

    public let description =
        "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. "
        + "Automatically creates parent directories."

    public var parameters: JSONSchema {
        .object(
            .required("path", .string(description: "Path to the file to write (relative or absolute)")),
            .required("content", .string(description: "Content to write to the file"))
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let path = try args.requiredString("path", "file_path")
            let content = try args.requiredString("content")
            let filePath = FilePath(path)
            let data = Data(content.utf8)

            return try await context.mutations.serialize(filePath, tool: name) {
                try await context.fileSystem.write(filePath, data)
                // pi reports `content.length`, a UTF-16 count mislabeled "bytes";
                // the actual byte count is both correct and identical for ASCII.
                return ToolResult.text("Successfully wrote \(data.count) bytes to \(path)")
            }
        }
    }
}

// MARK: - Edit

/// Applies one or more exact-string replacements to a file.
public struct EditTool: Tool {

    public init() {}

    public let name = "edit"

    public let description =
        "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, "
        + "non-overlapping region of the original file. If two changes affect the same block or nearby "
        + "lines, merge them into one edit instead of emitting overlapping edits. Do not include large "
        + "unchanged regions just to connect distant changes."

    public var parameters: JSONSchema {
        let replaceEdit = JSONSchema.object(
            .required(
                "oldText",
                .string(
                    description:
                        "Exact text for one targeted replacement. It must be unique in the original file "
                        + "and must not overlap with any other edits[].oldText in the same call."
                )
            ),
            .required("newText", .string(description: "Replacement text for this targeted edit."))
        )
        return .object(
            .required("path", .string(description: "Path to the file to edit (relative or absolute)")),
            .required(
                "edits",
                .array(
                    of: replaceEdit,
                    description:
                        "One or more targeted replacements. Each edit is matched against the original file, "
                        + "not incrementally. Do not include overlapping or nested edits. If two changes touch "
                        + "the same block or nearby lines, merge them into one edit instead."
                )
            )
        )
    }

    @concurrent
    public func execute(
        _ arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        try await ToolResult.capturing(tool: name) {
            let args = try ArgumentReader(tool: name, arguments: arguments)
            let path = try args.requiredString("path", "file_path")
            let edits = try Self.prepareEdits(args)
            guard !edits.isEmpty else {
                return ToolResult.error("Edit tool input is invalid. edits must contain at least one replacement.")
            }
            return try await edit(path: path, edits: edits, context: context)
        }
    }

    /// Ports pi's `prepareArguments` + `getRenderablePreviewInput`: a legacy
    /// top-level `oldText`/`newText` pair becomes a trailing edit, and an `edits`
    /// that arrived as a JSON *string* (Opus 4.6, GLM-5.1) is parsed back to an
    /// array.
    private static func prepareEdits(_ args: ArgumentReader) throws(DoMoError) -> [EditEngine.Edit] {
        var editsValue = args.value("edits")
        if case .string(let raw)? = editsValue,
            let parsed = try? JSONValue(parsing: raw),
            parsed.arrayValue != nil
        {
            editsValue = parsed
        }

        var edits: [EditEngine.Edit] = []
        if case .array(let items)? = editsValue {
            for (index, item) in items.enumerated() {
                guard let old = item["oldText"]?.stringValue, let new = item["newText"]?.stringValue else {
                    throw args.fault("edits[\(index)] must have string oldText and newText")
                }
                edits.append(EditEngine.Edit(oldText: old, newText: new))
            }
        }

        if let old = args.value("oldText")?.stringValue, let new = args.value("newText")?.stringValue {
            edits.append(EditEngine.Edit(oldText: old, newText: new))
        }
        return edits
    }

    private func edit(
        path: String,
        edits: [EditEngine.Edit],
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let filePath = FilePath(path)
        return try await context.mutations.serialize(filePath, tool: name) {
            let bytes: Data
            do {
                bytes = try await context.fileSystem.read(filePath)
            } catch {
                if DoMoError.isCancellation(error) { throw error }
                let reason = (error as? DoMoError)?.rootCause ?? String(describing: error)
                return ToolResult.error("Could not edit file: \(path). \(reason).")
            }

            let decoded: DecodedText
            switch FileContentProbe.classify(bytes) {
            case .text:
                decoded = try FileContentProbe.decode(bytes, path: filePath)
            case .image(let mediaType):
                return ToolResult.error("Could not edit file: \(path). File is an image (\(mediaType)), not text.")
            case .binary(let reason):
                return ToolResult.error("Could not edit file: \(path). File is binary (\(reason.description)), not text.")
            }

            let (baseContent, newContent) = try EditEngine.applyEdits(
                normalizedContent: decoded.normalizedToLF,
                edits: edits,
                path: path
            )
            try await context.fileSystem.write(filePath, decoded.reencoding(newContent))

            let details: JSONValue = .object([
                "replacedBlocks": .int(edits.count),
                "oldContent": .string(baseContent),
                "newContent": .string(newContent),
            ])
            return ToolResult.text("Successfully replaced \(edits.count) block(s) in \(path).", details: details)
        }
    }
}

// MARK: - Edit engine

/// The exact-string-replace primitive behind ``EditTool``.
///
/// A faithful port of pi's `applyEditsToNormalizedContent` (`edit-diff.ts`):
/// exact match first, then a fuzzy fallback that NFKC-normalizes and strips
/// trailing whitespace so a model's near-miss still lands, with uniqueness,
/// overlap and no-change checks and the exact error wording the model is tuned
/// against.
///
/// Everything runs over `[Character]`. pi indexes JS strings by UTF-16 unit;
/// grapheme offsets differ, but every index, length and line span here is
/// derived from the *same* `[Character]` view, so the arithmetic stays internally
/// consistent and the result is identical.
enum EditEngine {

    private enum MatchStrategy: CaseIterable {
        case exact
        case fuzzy
        case horizontalWhitespace
        case indentation

        var usesFuzzyBase: Bool { self != .exact }

        func normalize(_ text: String) -> String {
            switch self {
            case .exact:
                return text
            case .fuzzy:
                return EditEngine.normalizeForFuzzyMatch(text)
            case .horizontalWhitespace:
                return EditEngine.normalizeHorizontalWhitespace(text)
            case .indentation:
                return EditEngine.normalizeIndentation(text)
            }
        }
    }

    struct Edit: Sendable, Hashable {
        var oldText: String
        var newText: String
    }

    private struct Replacement {
        var editIndex: Int
        var matchIndex: Int
        var matchLength: Int
        var newText: [Character]
    }

    /// Matches every edit against the same original content, then applies them.
    /// Returns the LF-normalized before/after pair the caller re-encodes and the
    /// renderer diffs.
    static func applyEdits(
        normalizedContent: String,
        edits: [Edit],
        path: String
    ) throws(DoMoError) -> (base: String, new: String) {
        let total = edits.count
        let normalized = edits.map { Edit(oldText: normalizeToLF($0.oldText), newText: normalizeToLF($0.newText)) }

        for (index, edit) in normalized.enumerated() where edit.oldText.isEmpty {
            throw emptyOldTextError(path: path, index: index, total: total)
        }

        let contentChars = Array(normalizedContent)
        let resolution = try resolve(
            content: normalizedContent,
            edits: normalized,
            path: path
        )
        let base = resolution.base

        var matched: [Replacement] = []
        for (index, edit) in normalized.enumerated() {
            let oldText = resolution.strategy.normalize(edit.oldText)
            let oldChars = Array(oldText)
            let match = resolution.matches[index]
            guard match.found else { throw notFoundError(path: path, index: index, total: total) }
            try rejectDisproportionateMatch(
                content: base,
                oldText: oldChars,
                match: match,
                path: path,
                index: index,
                total: total
            )
            let occurrences = countOccurrences(
                content: base,
                oldText: oldChars,
                strategy: .exact
            )
            if occurrences > 1 {
                throw duplicateError(path: path, index: index, total: total, occurrences: occurrences)
            }
            matched.append(
                Replacement(
                    editIndex: index,
                    matchIndex: match.index,
                    matchLength: match.matchLength,
                    newText: Array(edit.newText)
                )
            )
        }

        matched.sort { $0.matchIndex < $1.matchIndex }
        for i in 1..<matched.count {
            let previous = matched[i - 1]
            let current = matched[i]
            if previous.matchIndex + previous.matchLength > current.matchIndex {
                throw overlapError(path: path, first: previous.editIndex, second: current.editIndex)
            }
        }

        let newChars: [Character] =
            resolution.strategy.usesFuzzyBase
            ? try applyPreservingUnchangedLines(original: contentChars, base: base, replacements: matched)
            : applyReplacements(base, matched)
        let newContent = String(newChars)

        if normalizedContent == newContent {
            throw noChangeError(path: path, total: total)
        }
        return (normalizedContent, newContent)
    }

    private struct Match {
        var found: Bool
        var index: Int
        var matchLength: Int
    }

    private struct Resolution {
        var strategy: MatchStrategy
        var base: [Character]
        var matches: [Match]
    }

    /// Resolve every edit against one shared representation. Trying the whole
    /// batch under one strategy is important: mixing offsets from different
    /// normalizations would make overlap checks and line preservation unsound.
    private static func resolve(
        content: String,
        edits: [Edit],
        path: String
    ) throws(DoMoError) -> Resolution {
        for strategy in MatchStrategy.allCases {
            let base = Array(strategy.normalize(content))
            let matches = edits.map { edit -> Match in
                let old = Array(strategy.normalize(edit.oldText))
                guard let index = indexOfSubsequence(base, old, from: 0) else {
                    return Match(found: false, index: -1, matchLength: 0)
                }
                return Match(found: true, index: index, matchLength: old.count)
            }
            if matches.allSatisfy(\.found) {
                return Resolution(strategy: strategy, base: base, matches: matches)
            }
        }
        // Match the existing single-edit/multi-edit error wording at the call
        // site, while still keeping the strategy search private.
        let missingIndex = edits.firstIndex { edit in
            !MatchStrategy.allCases.contains { strategy in
                let base = Array(strategy.normalize(content))
                let old = Array(strategy.normalize(edit.oldText))
                return indexOfSubsequence(base, old, from: 0) != nil
            }
        } ?? 0
        throw notFoundError(path: path, index: missingIndex, total: edits.count)
    }

    // MARK: Normalization

    static func normalizeToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// NFKC, strip trailing whitespace per line, and fold smart quotes, Unicode
    /// dashes and exotic spaces to ASCII. Ported from `normalizeForFuzzyMatch`.
    static func normalizeForFuzzyMatch(_ text: String) -> String {
        let composed = text.precomposedStringWithCompatibilityMapping
        let trimmed = composed.components(separatedBy: "\n")
            .map { line -> String in
                var characters = Array(line)
                while let last = characters.last, last.isWhitespace { characters.removeLast() }
                return String(characters)
            }
            .joined(separator: "\n")

        var scalars = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x2018, 0x2019, 0x201A, 0x201B:
                scalars.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F:
                scalars.append("\"")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
                scalars.append("-")
            case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Collapses only horizontal whitespace. Newlines remain structural so a
    /// short model-emitted spacing difference cannot jump across a line boundary.
    private static func normalizeHorizontalWhitespace(_ text: String) -> String {
        normalizeForFuzzyMatch(text)
            .components(separatedBy: "\n")
            .map { line in
                var result = ""
                var inWhitespace = false
                for character in line {
                    if character == " " || character == "\t" {
                        inWhitespace = true
                    } else {
                        if inWhitespace, !result.isEmpty { result.append(" ") }
                        result.append(character)
                        inWhitespace = false
                    }
                }
                return result
            }
            .joined(separator: "\n")
    }

    /// Removes leading indentation after the safer normalizations. This is the
    /// last fallback, because it deliberately treats differently nested code as
    /// equivalent; duplicate and disproportionate-match checks still run before
    /// any replacement is accepted.
    private static func normalizeIndentation(_ text: String) -> String {
        normalizeHorizontalWhitespace(text)
            .components(separatedBy: "\n")
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }) }
            .map(String.init)
            .joined(separator: "\n")
    }

    // MARK: Matching

    private static func countOccurrences(
        content: [Character],
        oldText: [Character],
        strategy: MatchStrategy
    ) -> Int {
        let normalizedContent = Array(strategy.normalize(String(content)))
        let normalizedOld = Array(strategy.normalize(String(oldText)))
        guard !normalizedOld.isEmpty else { return 0 }
        var count = 0
        var cursor = 0
        while let index = indexOfSubsequence(normalizedContent, normalizedOld, from: cursor) {
            count += 1
            cursor = index + normalizedOld.count
        }
        return count
    }

    /// Reject a fuzzy result whose accepted span is wildly larger than the
    /// meaningful text the model supplied. This guard is intentionally before
    /// duplicate/overlap/application logic and applies to exact results too;
    /// future strategies cannot bypass it by being added ahead of the cascade.
    private static func rejectDisproportionateMatch(
        content: [Character],
        oldText: [Character],
        match: Match,
        path: String,
        index: Int,
        total: Int
    ) throws(DoMoError) {
        guard match.found else { return }
        let upper = match.index + match.matchLength
        guard match.index >= 0, upper <= content.count else {
            throw notFoundError(path: path, index: index, total: total)
        }
        let search = String(content[match.index..<upper])
        let old = String(oldText)
        let oldLines = old.components(separatedBy: "\n").count
        let searchLines = search.components(separatedBy: "\n").count
        if searchLines >= max(oldLines + 3, oldLines * 2)
            || (oldLines > 1
                && search.trimmingCharacters(in: .whitespacesAndNewlines).count
                    > max(
                        old.trimmingCharacters(in: .whitespacesAndNewlines).count + 500,
                        old.trimmingCharacters(in: .whitespacesAndNewlines).count * 4
                    )) {
            throw disproportionateError(path: path, index: index, total: total)
        }
    }

    private static func indexOfSubsequence(_ haystack: [Character], _ needle: [Character], from: Int) -> Int? {
        guard !needle.isEmpty else { return from }
        guard needle.count <= haystack.count else { return nil }
        var start = from
        let last = haystack.count - needle.count
        while start <= last {
            var offset = 0
            while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return start }
            start += 1
        }
        return nil
    }

    // MARK: Applying

    private static func applyReplacements(
        _ content: [Character],
        _ replacements: [Replacement],
        offset: Int = 0
    ) -> [Character] {
        var result = content
        for replacement in replacements.reversed() {
            let lower = replacement.matchIndex - offset
            let upper = lower + replacement.matchLength
            result.replaceSubrange(lower..<upper, with: replacement.newText)
        }
        return result
    }

    /// Overlays fuzzy-space replacements onto the original content so only the
    /// lines an edit actually touches are rewritten from the normalized base;
    /// every other line keeps its original bytes. Ported from
    /// `applyReplacementsPreservingUnchangedLines`.
    private static func applyPreservingUnchangedLines(
        original: [Character],
        base: [Character],
        replacements: [Replacement]
    ) throws(DoMoError) -> [Character] {
        let originalLines = splitLinesWithEndings(original)
        let baseLines = lineSpans(base)
        guard originalLines.count == baseLines.count else {
            throw DoMoError(
                .toolExecution(tool: "edit"),
                "Cannot preserve unchanged lines because the base content has a different line count."
            )
        }

        struct Group {
            var startLine: Int
            var endLine: Int
            var replacements: [Replacement]
        }

        var groups: [Group] = []
        for replacement in replacements.sorted(by: { $0.matchIndex < $1.matchIndex }) {
            let range = try replacementLineRange(baseLines, replacement)
            if var current = groups.last, range.startLine < current.endLine {
                current.endLine = max(current.endLine, range.endLine)
                current.replacements.append(replacement)
                groups[groups.count - 1] = current
            } else {
                groups.append(Group(startLine: range.startLine, endLine: range.endLine, replacements: [replacement]))
            }
        }

        var originalLineIndex = 0
        var result: [Character] = []
        for group in groups {
            for index in originalLineIndex..<group.startLine { result += originalLines[index] }
            let startOffset = baseLines[group.startLine].start
            let endOffset = baseLines[group.endLine - 1].end
            result += applyReplacements(Array(base[startOffset..<endOffset]), group.replacements, offset: startOffset)
            originalLineIndex = group.endLine
        }
        for index in originalLineIndex..<originalLines.count { result += originalLines[index] }
        return result
    }

    private static func replacementLineRange(
        _ lines: [(start: Int, end: Int)],
        _ replacement: Replacement
    ) throws(DoMoError) -> (startLine: Int, endLine: Int) {
        let replacementStart = replacement.matchIndex
        let replacementEnd = replacement.matchIndex + replacement.matchLength

        var startLine = -1
        for (index, line) in lines.enumerated() where replacementStart >= line.start && replacementStart < line.end {
            startLine = index
            break
        }
        guard startLine != -1 else {
            throw DoMoError(.toolExecution(tool: "edit"), "Replacement range is outside the base content.")
        }

        var endLine = startLine
        while endLine < lines.count && lines[endLine].end < replacementEnd { endLine += 1 }
        guard endLine < lines.count else {
            throw DoMoError(.toolExecution(tool: "edit"), "Replacement range is outside the base content.")
        }
        return (startLine, endLine + 1)
    }

    /// Splits into lines that keep their trailing `\n`. Ports the
    /// `/[^\n]*\n|[^\n]+/g` behavior.
    private static func splitLinesWithEndings(_ characters: [Character]) -> [[Character]] {
        var result: [[Character]] = []
        var current: [Character] = []
        for character in characters {
            current.append(character)
            if character == "\n" {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func lineSpans(_ characters: [Character]) -> [(start: Int, end: Int)] {
        var offset = 0
        return splitLinesWithEndings(characters).map { line in
            let span = (start: offset, end: offset + line.count)
            offset += line.count
            return span
        }
    }

    // MARK: Errors

    private static func fault(_ message: String) -> DoMoError {
        DoMoError(.toolExecution(tool: "edit"), message)
    }

    private static func notFoundError(path: String, index: Int, total: Int) -> DoMoError {
        total == 1
            ? fault(
                "Could not find the exact text in \(path). "
                + "The old text must match exactly including all whitespace and newlines.")
            : fault(
                "Could not find edits[\(index)] in \(path). "
                + "The oldText must match exactly including all whitespace and newlines.")
    }

    private static func duplicateError(path: String, index: Int, total: Int, occurrences: Int) -> DoMoError {
        total == 1
            ? fault(
                "Found \(occurrences) occurrences of the text in \(path). "
                + "The text must be unique. Please provide more context to make it unique.")
            : fault(
                "Found \(occurrences) occurrences of edits[\(index)] in \(path). "
                + "Each oldText must be unique. Please provide more context to make it unique.")
    }

    private static func emptyOldTextError(path: String, index: Int, total: Int) -> DoMoError {
        total == 1
            ? fault("oldText must not be empty in \(path).")
            : fault("edits[\(index)].oldText must not be empty in \(path).")
    }

    private static func noChangeError(path: String, total: Int) -> DoMoError {
        total == 1
            ? fault(
                "No changes made to \(path). The replacement produced identical content. "
                + "This might indicate an issue with special characters or the text not existing as expected.")
            : fault("No changes made to \(path). The replacements produced identical content.")
    }

    private static func disproportionateError(path: String, index: Int, total: Int) -> DoMoError {
        let target = total == 1 ? "the replacement" : "edits[\(index)]"
        return fault(
            "Refused \(target) in \(path): the fuzzy match covered a disproportionately large block. "
                + "Provide more exact surrounding context before editing."
        )
    }

    private static func overlapError(path: String, first: Int, second: Int) -> DoMoError {
        fault("edits[\(first)] and edits[\(second)] overlap in \(path). Merge them into one edit or target disjoint regions.")
    }
}
