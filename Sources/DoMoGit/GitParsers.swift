// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// Parses Git's machine-oriented status output. The status command uses NUL
/// separators so paths containing spaces or newlines never become ambiguous.
enum GitStatusParser {
    static func parse(_ bytes: [UInt8]) -> GitStatus {
        let raw = String(decoding: bytes, as: UTF8.self)
        var branch: String?
        var ahead: Int?
        var behind: Int?
        var recordStart = raw.startIndex

        if raw.hasPrefix("## ") {
            let separators = [raw.firstIndex(of: "\0"), raw.firstIndex(of: "\n")]
                .compactMap { $0 }
            let separator = separators.min()
            let header = separator.map { String(raw[..<$0]) } ?? raw
            let parsed = parseBranch(header)
            branch = parsed.name
            ahead = parsed.ahead
            behind = parsed.behind
            if let separator {
                recordStart = raw.index(after: separator)
            }
        }

        let records = raw[recordStart...]
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var files: [GitFileStatus] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }
            let chars = Array(record)
            let x = String(chars[0])
            let y = String(chars[1])
            let path = String(record.dropFirst(3))
            var oldPath: String?
            if (x == "R" || y == "R" || x == "C" || y == "C"), index + 1 < records.count {
                oldPath = records[index + 1]
                index += 1
            }
            files.append(
                GitFileStatus(
                    path: path,
                    oldPath: oldPath,
                    indexStatus: x,
                    workTreeStatus: y,
                    kind: kind(x: x, y: y)
                )
            )
            index += 1
        }
        return GitStatus(branch: branch, ahead: ahead, behind: behind, files: files)
    }

    private struct Branch {
        var name: String?
        var ahead: Int?
        var behind: Int?
    }

    private static func parseBranch(_ line: String) -> Branch {
        let value = String(line.dropFirst(3))
        if value.hasPrefix("No commits yet on ") {
            return Branch(name: String(value.dropFirst("No commits yet on ".count)), ahead: nil, behind: nil)
        }
        if value == "Initial commit on " {
            return Branch(name: nil, ahead: nil, behind: nil)
        }
        let parts = value.components(separatedBy: " [")
        let rawName = parts.first ?? value
        let name = rawName == "HEAD (no branch)" ? nil : rawName
        var ahead: Int?
        var behind: Int?
        if parts.count > 1 {
            let counts = parts[1].dropLast(1).split(separator: ",")
            for count in counts {
                let fields = count.split(separator: " ")
                guard fields.count == 2, let number = Int(fields[1]) else { continue }
                if fields[0] == "ahead" { ahead = number }
                if fields[0] == "behind" { behind = number }
            }
        }
        return Branch(name: name, ahead: ahead, behind: behind)
    }

    private static func kind(x: String, y: String) -> GitFileStatus.Kind {
        if x == "?" && y == "?" { return .untracked }
        if x == "!" && y == "!" { return .ignored }
        if x == "U" || y == "U" { return .conflicted }
        if x == "R" || y == "R" { return .renamed }
        if x == "C" || y == "C" { return .copied }
        if x == "A" || y == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "M" || y == "M" { return .modified }
        return .unknown
    }
}

/// Parses the human-readable unified patch emitted with --no-color. The parser
/// keeps the raw patch on GitDiff as the lossless fallback, while exposing enough
/// structure for hunk navigation and per-file review state.
enum GitDiffParser {
    private struct HunkBuilder {
        var header: String
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var oldCursor: Int
        var newCursor: Int
        var lines: [GitDiffLine] = []
    }

    private struct FileBuilder {
        var path = ""
        var oldPath: String?
        var hunks: [HunkBuilder] = []
        var binary = false
    }

    static func parse(_ patch: String, status: GitStatus) -> [GitDiffFile] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var current: FileBuilder?
        var parsed: [GitDiffFile] = []

        func finish(_ builder: FileBuilder) -> GitDiffFile? {
            guard !builder.path.isEmpty else { return nil }
            let status = status.files.first(where: { $0.path == builder.path })?.kind ?? .modified
            let hunks = builder.hunks.map {
                GitDiffHunk(
                    header: $0.header,
                    oldStart: $0.oldStart,
                    oldCount: $0.oldCount,
                    newStart: $0.newStart,
                    newCount: $0.newCount,
                    lines: $0.lines
                )
            }
            return GitDiffFile(
                path: builder.path,
                oldPath: builder.oldPath,
                status: status,
                hunks: hunks,
                binary: builder.binary
            )
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let current, let file = finish(current) { parsed.append(file) }
                current = FileBuilder()
                let (oldPath, newPath) = diffHeaderPaths(String(line.dropFirst(11)))
                current?.oldPath = oldPath
                current?.path = newPath
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("--- ") {
                let value = path(from: String(line.dropFirst(4)))
                if value != "/dev/null" { current?.oldPath = value }
                continue
            }
            if line.hasPrefix("+++ ") {
                let value = path(from: String(line.dropFirst(4)))
                if value != "/dev/null" { current?.path = value }
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.binary = true
                continue
            }
            if line.hasPrefix("@@ "), let header = parseHunk(line) {
                current?.hunks.append(
                    HunkBuilder(
                        header: line,
                        oldStart: header.oldStart,
                        oldCount: header.oldCount,
                        newStart: header.newStart,
                        newCount: header.newCount,
                        oldCursor: header.oldStart,
                        newCursor: header.newStart
                    )
                )
                continue
            }
            guard !current!.hunks.isEmpty else { continue }
            guard let marker = line.first else { continue }
            let text = String(line.dropFirst())
            let hunkIndex = current!.hunks.count - 1
            switch marker {
            case " ":
                let hunk = current!.hunks[hunkIndex]
                current!.hunks[hunkIndex].lines.append(
                    GitDiffLine(
                        kind: .context,
                        text: text,
                        oldLine: hunk.oldCursor,
                        newLine: hunk.newCursor
                    )
                )
                current!.hunks[hunkIndex].oldCursor += 1
                current!.hunks[hunkIndex].newCursor += 1
            case "+":
                let hunk = current!.hunks[hunkIndex]
                current!.hunks[hunkIndex].lines.append(
                    GitDiffLine(kind: .addition, text: text, newLine: hunk.newCursor)
                )
                current!.hunks[hunkIndex].newCursor += 1
            case "-":
                let hunk = current!.hunks[hunkIndex]
                current!.hunks[hunkIndex].lines.append(
                    GitDiffLine(kind: .deletion, text: text, oldLine: hunk.oldCursor)
                )
                current!.hunks[hunkIndex].oldCursor += 1
            case "\\":
                current!.hunks[hunkIndex].lines.append(
                    GitDiffLine(kind: .metadata, text: line)
                )
            default:
                continue
            }
        }
        if let current, let file = finish(current) { parsed.append(file) }

        var byPath = Dictionary(uniqueKeysWithValues: parsed.map { ($0.path, $0) })
        for file in status.files where file.kind != .ignored && byPath[file.path] == nil {
            byPath[file.path] = GitDiffFile(
                path: file.path,
                oldPath: file.oldPath,
                status: file.kind
            )
        }
        var result: [GitDiffFile] = []
        for file in status.files where file.kind != .ignored {
            if let parsed = byPath[file.path] { result.append(parsed) }
        }
        result.append(contentsOf: parsed.filter { parsedFile in
            status.files.allSatisfy { statusFile in statusFile.path != parsedFile.path }
        })
        return result
    }

    private static func diffHeaderPaths(_ value: String) -> (String?, String) {
        guard let separator = value.range(of: " b/") else { return (nil, path(from: value)) }
        let old = String(value[..<separator.lowerBound])
        let new = String(value[separator.upperBound...])
        return (path(from: old), path(from: "b/" + new))
    }

    private static func path(from raw: String) -> String {
        var value = raw
        if value.hasPrefix("a/") || value.hasPrefix("b/") { value.removeFirst(2) }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func parseHunk(_ line: String) -> (
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int
    )? {
        let fields = line.split(separator: " ")
        guard fields.count >= 3 else { return nil }

        func parseRange(_ value: Substring) -> (Int, Int)? {
            let body = value.dropFirst()
            let parts = body.split(separator: ",", maxSplits: 1).map(String.init)
            guard let start = Int(parts[0]) else { return nil }
            return (start, parts.count == 2 ? Int(parts[1]) ?? 1 : 1)
        }

        guard let old = parseRange(fields[1]), let new = parseRange(fields[2]) else {
            return nil
        }
        return (old.0, old.1, new.0, new.1)
    }
}
