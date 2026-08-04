// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A small, native patch surface for models that are better at emitting a
// unified patch than a JSON list of exact replacements. The parser deliberately
// accepts the stable `*** Begin Patch` format and delegates update matching to
// the same safety-checked edit engine as `edit`.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// Applies a bounded, sandboxed `*** Begin Patch` document.
///
/// Update hunks are converted to exact replacements and run through
/// ``EditEngine``. Add and delete operations use the same sandbox and per-path
/// mutation coordinator as `write` and `edit`. A patch can name several files;
/// operations stop at the first failure so a malformed later operation is not
/// silently ignored.
public struct ApplyPatchTool: Tool {

    public init() {}

    public let name = "apply_patch"

    public let description =
        "Apply a multi-file patch using the `*** Begin Patch` format. "
        + "Update hunks must include context or removed text and are matched safely against the original file. "
        + "Add File and Delete File operations are supported. Paths stay inside the workspace sandbox."

    public var parameters: JSONSchema {
        .object(
            .required(
                "patch",
                .string(
                    description:
                        "A patch document beginning with `*** Begin Patch` and ending with `*** End Patch`."
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
            let patch = try args.requiredString("patch")
            let operations = try PatchParser.parse(patch)
            guard !operations.isEmpty else {
                return ToolResult.error("apply_patch: the patch does not contain any file operations.")
            }

            var changedPaths: [FilePath] = []
            var updated = 0
            var added = 0
            var deleted = 0

            for operation in operations {
                let result: ToolResult
                let changedPath: FilePath
                switch operation {
                case .update(let path, let edits):
                    changedPath = FilePath(path)
                    result = try await Self.update(
                        path: path,
                        edits: edits,
                        context: context
                    )
                    updated += 1
                case .add(let path, let content):
                    changedPath = FilePath(path)
                    result = try await Self.add(
                        path: path,
                        content: content,
                        context: context
                    )
                    added += 1
                case .delete(let path):
                    changedPath = FilePath(path)
                    result = try await Self.delete(path: path, context: context)
                    deleted += 1
                }

                guard !result.isError else { return result }
                changedPaths.append(changedPath)
            }

            let pathNames = changedPaths.map { JSONValue.string($0.string) }
            var result = ToolResult.text(
                "Applied patch to \(changedPaths.count) file\(changedPaths.count == 1 ? "" : "s").",
                details: .object([
                    "files": .array(pathNames),
                    "updated": .int(updated),
                    "added": .int(added),
                    "deleted": .int(deleted),
                ])
            )
            for path in changedPaths {
                result = await context.addingDiagnostics(to: result, changedPath: path)
            }
            return result
        }
    }

    private static func update(
        path: String,
        edits: [EditEngine.Edit],
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let filePath = FilePath(path)
        return try await context.mutations.serialize(filePath, tool: "apply_patch") {
            let bytes: Data
            do {
                bytes = try await context.fileSystem.read(filePath)
            } catch {
                if DoMoError.isCancellation(error) { throw error }
                let reason = (error as? DoMoError)?.rootCause ?? String(describing: error)
                return ToolResult.error("Could not update file: \(path). \(reason).")
            }

            let decoded: DecodedText
            switch FileContentProbe.classify(bytes) {
            case .text:
                decoded = try FileContentProbe.decode(bytes, path: filePath)
            case .image(let mediaType):
                return ToolResult.error(
                    "Could not update file: \(path). File is an image (\(mediaType)), not text."
                )
            case .binary(let reason):
                return ToolResult.error(
                    "Could not update file: \(path). File is binary (\(reason.description)), not text."
                )
            }

            let (_, newContent) = try EditEngine.applyEdits(
                normalizedContent: decoded.normalizedToLF,
                edits: edits,
                path: path
            )
            try await context.fileSystem.write(filePath, decoded.reencoding(newContent))
            return ToolResult.text("Updated \(path) with \(edits.count) hunk\(edits.count == 1 ? "" : "s").")
        }
    }

    private static func add(
        path: String,
        content: String,
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let filePath = FilePath(path)
        return try await context.mutations.serialize(filePath, tool: "apply_patch") {
            if try await context.fileSystem.exists(filePath) {
                return ToolResult.error("Could not add file: \(path) already exists.")
            }
            try await context.fileSystem.write(filePath, Data(content.utf8))
            return ToolResult.text("Added \(path).")
        }
    }

    private static func delete(
        path: String,
        context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        let filePath = FilePath(path)
        return try await context.mutations.serialize(filePath, tool: "apply_patch") {
            let metadata: FileMetadata
            do {
                metadata = try await context.fileSystem.metadata(filePath)
            } catch {
                if DoMoError.isCancellation(error) { throw error }
                let reason = (error as? DoMoError)?.rootCause ?? String(describing: error)
                return ToolResult.error("Could not delete file: \(path). \(reason).")
            }
            guard metadata.kind != .directory else {
                return ToolResult.error("Could not delete file: \(path) is a directory.")
            }
            try await context.fileSystem.delete(filePath, recursive: false, force: false)
            return ToolResult.text("Deleted \(path).")
        }
    }
}

private enum PatchOperation: Sendable {
    case update(path: String, edits: [EditEngine.Edit])
    case add(path: String, content: String)
    case delete(path: String)
}

private enum PatchParser {

    static func parse(_ raw: String) throws(DoMoError) -> [PatchOperation] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.first == "*** Begin Patch" else {
            throw fault("patch must begin with `*** Begin Patch`.")
        }

        guard let end = lines.firstIndex(of: "*** End Patch"), end > 1 else {
            throw fault("patch must end with `*** End Patch`.")
        }
        guard lines[(end + 1)...].allSatisfy(\.isEmpty) else {
            throw fault("patch contains content after `*** End Patch`.")
        }

        var operations: [PatchOperation] = []
        var index = 1
        while index < end {
            let line = lines[index]
            if line.isEmpty {
                index += 1
                continue
            }
            if let path = path(in: line, marker: "*** Update File: ") {
                index += 1
                let edits = try parseUpdate(lines, index: &index, end: end)
                operations.append(.update(path: path, edits: edits))
                continue
            }
            if let path = path(in: line, marker: "*** Add File: ") {
                index += 1
                let content = try parseAdd(lines, index: &index, end: end, path: path)
                operations.append(.add(path: path, content: content))
                continue
            }
            if let path = path(in: line, marker: "*** Delete File: ") {
                index += 1
                guard index == end || isFileHeader(lines[index]) else {
                    throw fault("delete operation for \(path) must not contain hunk lines.")
                }
                operations.append(.delete(path: path))
                continue
            }
            throw fault("expected an Update File, Add File, or Delete File operation; got `\(line)`." )
        }
        return operations
    }

    private static func parseUpdate(
        _ lines: [String],
        index: inout Int,
        end: Int
    ) throws(DoMoError) -> [EditEngine.Edit] {
        var edits: [EditEngine.Edit] = []
        while index < end, !isFileHeader(lines[index]) {
            guard lines[index].hasPrefix("@@") else {
                throw fault("expected an `@@` hunk header in an Update File operation.")
            }
            index += 1

            var oldLines: [String] = []
            var newLines: [String] = []
            while index < end, !isFileHeader(lines[index]), !lines[index].hasPrefix("@@") {
                let line = lines[index]
                if line == "\\ No newline at end of file" {
                    index += 1
                    continue
                }
                guard let prefix = line.first else {
                    throw fault("patch hunk lines must begin with a space, `-`, or `+`.")
                }
                let text = String(line.dropFirst())
                switch prefix {
                case " ":
                    oldLines.append(text)
                    newLines.append(text)
                case "-":
                    oldLines.append(text)
                case "+":
                    newLines.append(text)
                default:
                    throw fault("patch hunk lines must begin with a space, `-`, or `+`.")
                }
                index += 1
            }

            guard !oldLines.isEmpty else {
                throw fault("an update hunk must include context or removed text; empty insertions are ambiguous.")
            }
            let oldText = oldLines.joined(separator: "\n")
            let newText = newLines.joined(separator: "\n")
            edits.append(EditEngine.Edit(oldText: oldText, newText: newText))
        }

        guard !edits.isEmpty else {
            throw fault("an Update File operation must contain at least one hunk.")
        }
        return edits
    }

    private static func parseAdd(
        _ lines: [String],
        index: inout Int,
        end: Int,
        path: String
    ) throws(DoMoError) -> String {
        var contentLines: [String] = []
        while index < end, !isFileHeader(lines[index]) {
            let line = lines[index]
            guard line.first == "+" else {
            throw fault("added file \(path) must contain only `+`-prefixed content lines.")
            }
            contentLines.append(String(line.dropFirst()))
            index += 1
        }
        return contentLines.joined(separator: "\n")
    }

    private static func isFileHeader(_ line: String) -> Bool {
        line.hasPrefix("*** Update File: ")
            || line.hasPrefix("*** Add File: ")
            || line.hasPrefix("*** Delete File: ")
    }

    private static func path(in line: String, marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func fault(_ message: String) -> DoMoError {
        DoMoError(.toolExecution(tool: "apply_patch"), "apply_patch: \(message)")
    }
}
