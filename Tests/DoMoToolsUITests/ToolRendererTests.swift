// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import DoMoTools
import Testing

@testable import DoMoToolsUI

// MARK: - Invariant helper

/// Asserts every line of a rendered result fits `width` — the fatal-width
/// invariant every renderer here must uphold. Measured with ``visibleWidth`` so
/// ANSI styling (zero visible width) is discounted and CJK/emoji count their real
/// cell width.
private func expectAllFit(_ lines: [String], width: Int, _ label: String = "") {
    for (index, line) in lines.enumerated() {
        let measured = visibleWidth(line)
        #expect(measured <= width, "\(label) line \(index) width \(measured) > \(width): \(line.debugDescription)")
    }
}

private func object(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

@Suite("ToolRenderer")
struct ToolRendererTests {

    // MARK: Registry & default

    @Test("An unknown tool falls through to the default renderer")
    func unknownToolUsesDefault() {
        let registry = ToolRendererRegistry.builtin
        let result = ToolResult.text("some output line\nanother line")
        let lines = registry.render(
            toolName: "totally-made-up",
            arguments: object([:]),
            result: result,
            width: 40
        )
        #expect(lines.first == "totally-made-up")
        #expect(lines.contains { $0.contains("some output line") })
        expectAllFit(lines, width: 40, "default")
    }

    @Test("The default renderer truncates a huge dump with a more-lines marker")
    func defaultTruncates() {
        let body = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let registry = ToolRendererRegistry()
        let lines = registry.render(
            toolName: "mystery",
            arguments: object([:]),
            result: .text(body),
            width: 30
        )
        #expect(lines.contains { $0.contains("more lines") })
        // header + 15 preview + marker
        #expect(lines.count == 1 + DefaultToolRenderer.previewLines + 1)
        expectAllFit(lines, width: 30, "default-trunc")
    }

    // MARK: Edit diff

    @Test("An edit renders a coloured add/remove diff within width")
    func editDiff() {
        let old = "alpha\nbeta\ngamma\n"
        let new = "alpha\nBETA\ngamma\n"
        let result = ToolResult.text(
            "Successfully replaced 1 block(s) in file.txt.",
            details: object([
                "replacedBlocks": .int(1),
                "oldContent": .string(old),
                "newContent": .string(new),
            ])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("file.txt")]),
            result: result,
            width: 60,
            theme: .plain
        )
        #expect(lines.first == "edit file.txt")
        // A removed `beta` and an added `BETA` appear as -/+ lines.
        #expect(lines.contains { $0.hasPrefix("-") && $0.contains("beta") })
        #expect(lines.contains { $0.hasPrefix("+") && $0.contains("BETA") })
        // Context line for the unchanged neighbour, not a change marker.
        #expect(lines.contains { $0.hasPrefix(" ") && $0.contains("alpha") })
        expectAllFit(lines, width: 60, "edit")
    }

    @Test("An edit diff with the ANSI theme still fits and carries colour escapes")
    func editDiffAnsiFits() {
        let old = "one\ntwo\nthree\n"
        let new = "one\ntwo-changed\nthree\n"
        let result = ToolResult.text(
            "Successfully replaced 1 block(s) in code.swift.",
            details: object([
                "oldContent": .string(old),
                "newContent": .string(new),
            ])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("code.swift")]),
            result: result,
            width: 24,
            theme: .ansi
        )
        // At least one line carries an SGR escape (colour), proving styling ran.
        #expect(lines.contains { $0.contains("\u{1b}[") })
        expectAllFit(lines, width: 24, "edit-ansi")
    }

    @Test("A multi-line edit shows every changed line")
    func editMultiLine() {
        let old = "a\nb\nc\nd\ne\n"
        let new = "a\nX\nY\nZ\ne\n"
        let result = ToolResult.text(
            "ok",
            details: object(["oldContent": .string(old), "newContent": .string(new)])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("f")]),
            result: result,
            width: 40
        )
        let added = lines.filter { $0.hasPrefix("+") }
        let removed = lines.filter { $0.hasPrefix("-") }
        #expect(added.count == 3)
        #expect(removed.count == 3)
        expectAllFit(lines, width: 40, "edit-multi")
    }

    @Test("A small edit renders the exact same diff as before the cap was added")
    func editDiffPinned() {
        // Pins the collapsed, plain-themed rendering of an ordinary one-line
        // modification: the LCS diff must be byte-for-byte what it was, so the
        // bounding work never perturbs the common case.
        let old = "alpha\nbeta\ngamma\n"
        let new = "alpha\nBETA\ngamma\n"
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("file.txt")]),
            result: ToolResult.text(
                "ok",
                details: object(["oldContent": .string(old), "newContent": .string(new)])
            ),
            width: 60,
            theme: .plain
        )
        #expect(lines == ["edit file.txt", " 1 alpha", "-2 beta", "+2 BETA", " 3 gamma"])
    }

    @Test("A 2000x2000-line replace renders bounded output with a more-lines marker")
    func editOversizedReplaceIsBounded() {
        // Every line distinct on both sides: no common prefix/suffix to trim, so
        // the changed middle is the whole 4000-line combined content — over
        // `maxDiffLCSLines`, forcing the linear fallback rather than a ~400M-int
        // LCS matrix. Must complete without the huge allocation and stay bounded.
        let old = (1...2000).map { "old line \($0)" }.joined(separator: "\n") + "\n"
        let new = (1...2000).map { "new line \($0)" }.joined(separator: "\n") + "\n"
        let result = ToolResult.text(
            "ok",
            details: object(["oldContent": .string(old), "newContent": .string(new)])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("big.txt")]),
            result: result,
            width: 60,
            theme: .plain
        )
        // Header + at most the collapsed budget + one marker: a hard ceiling.
        #expect(lines.count <= 1 + EditToolRenderer.previewLines + 1)
        #expect(lines.first == "edit big.txt")
        #expect(lines.contains { $0.contains("more lines") })
        expectAllFit(lines, width: 60, "edit-oversized")
    }

    @Test("An expanded oversized edit is still bounded by the hard ceiling")
    func editOversizedExpandedIsBounded() {
        let old = (1...2000).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let new = (1...2000).map { "new \($0)" }.joined(separator: "\n") + "\n"
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("big.txt")]),
            result: ToolResult.text(
                "ok",
                details: object(["oldContent": .string(old), "newContent": .string(new)])
            ),
            width: 80,
            theme: .plain,
            expanded: true
        )
        // Expanded shows more than the collapsed preview but never floods.
        #expect(lines.count > 1 + EditToolRenderer.previewLines + 1)
        #expect(lines.count <= 1 + EditToolRenderer.maxExpandedDiffLines + 1)
        #expect(lines.contains { $0.contains("more lines") })
        expectAllFit(lines, width: 80, "edit-oversized-expanded")
    }

    @Test("The oversized fallback collapses interior common lines instead of running LCS")
    func editOversizedFallbackPathExercised() {
        // Shared lines sit in the middle, surrounded by change on both ends, so
        // prefix/suffix trimming cannot reach them. Real LCS would surface them as
        // an interior `.equal` run; the linear fallback does not — it emits one
        // removed run then one added run. Asserting that shape proves the
        // oversized branch, not the quadratic path, produced the diff.
        let shared = (0..<10).map { "shared \($0)" }
        let old = (0..<1200).map { "A\($0)" } + shared + (0..<1200).map { "A2_\($0)" }
        let new = (0..<1200).map { "B\($0)" } + shared + (0..<1200).map { "B2_\($0)" }
        let parts = diffLines(old, new)
        #expect(parts.count == 2)
        #expect(parts.first?.kind == .removed)
        #expect(parts.last?.kind == .added)
        // The shared lines were swept into the removed/added runs, not surfaced.
        #expect(parts.first?.lines.contains("shared 0") == true)
        #expect(!parts.contains { $0.kind == .equal })
    }

    @Test("An oversized edit diff stays within width for CJK/emoji/long content")
    func editOversizedWidthInvariant() {
        // The fallback and cap must still honour the fatal-width invariant for
        // wide glyphs and long paths.
        let longPath = "/deep/" + String(repeating: "日本語ディレクトリ/", count: 12) + "big.txt"
        let old = (1...2000).map { "旧 \($0) 🎉🚀 ASCII こんにちは世界" }.joined(separator: "\n") + "\n"
        let new = (1...2000).map { "新 \($0) 🚀🎉 ASCII さようなら世界" }.joined(separator: "\n") + "\n"
        let result = ToolResult.text(
            "ok",
            details: object(["oldContent": .string(old), "newContent": .string(new)])
        )
        for width in [7, 12, 21, 40, 80] {
            let lines = ToolRendererRegistry.builtin.render(
                toolName: "edit",
                arguments: object(["path": .string(longPath)]),
                result: result,
                width: width,
                theme: .ansi
            )
            #expect(lines.count <= 1 + EditToolRenderer.previewLines + 1)
            expectAllFit(lines, width: width, "edit-oversized-cjk w=\(width)")
        }
    }

    // MARK: Read

    @Test("A huge read is truncated with a more-lines marker and every line fits")
    func readTruncates() {
        let body = (1...400).map { "content of line \($0)" }.joined(separator: "\n")
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .string("big.txt")]),
            result: .text(body),
            width: 50
        )
        #expect(lines.first == "read big.txt")
        #expect(lines.contains { $0.contains("more lines") })
        #expect(lines.count == 1 + ReadToolRenderer.previewLines + 1)
        expectAllFit(lines, width: 50, "read")
    }

    @Test("An expanded read shows every line")
    func readExpanded() {
        let body = (1...30).map { "l\($0)" }.joined(separator: "\n")
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .string("f")]),
            result: .text(body),
            width: 40,
            expanded: true
        )
        #expect(!lines.contains { $0.contains("more lines") })
        #expect(lines.count == 1 + 30)
    }

    @Test("A read shows an offset line-range hint")
    func readLineRange() {
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .string("f"), "offset": .int(20), "limit": .int(5)]),
            result: .text("hello"),
            width: 60
        )
        #expect(lines.first?.contains("from line 20") == true)
        #expect(lines.first?.contains("5 lines") == true)
    }

    // MARK: Write

    @Test("A write shows a confirmation with size")
    func writeConfirmation() {
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "write",
            arguments: object(["path": .string("out.txt")]),
            result: .text("Successfully wrote 128 bytes to out.txt"),
            width: 60
        )
        #expect(lines.first == "write out.txt")
        #expect(lines.contains { $0.contains("128 bytes") })
        expectAllFit(lines, width: 60, "write")
    }

    // MARK: Bash

    @Test("A huge bash output keeps the tail with an earlier-lines marker")
    func bashTailTruncates() {
        let body = (1...200).map { "output \($0)" }.joined(separator: "\n")
        let result = ToolResult(
            content: [.text(body)],
            isError: false,
            details: object(["exitCode": .int(0), "durationMs": .int(1234), "truncated": .bool(false)])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "bash",
            arguments: object(["command": .string("seq 200")]),
            result: result,
            width: 40
        )
        #expect(lines.first == "$ seq 200")
        #expect(lines.contains { $0.contains("earlier lines") })
        // The tail — the last line — must be present.
        #expect(lines.contains { $0.contains("output 200") })
        // Tail-oriented: the very first output line is elided, not shown.
        #expect(!lines.contains { $0 == "output 1" })
        #expect(lines.contains { $0.contains("Took 1.2s") })
        expectAllFit(lines, width: 40, "bash")
    }

    @Test("A failing bash command surfaces its exit status in the body")
    func bashError() {
        // pi does not red-tint a failed command's output — stdout is often the
        // useful part — so the exit status is carried as body text (the tool
        // appends it), which is bash's distinct failure signal.
        let body = "boom\n\nCommand exited with code 2"
        let result = ToolResult(
            content: [.text(body)],
            isError: true,
            details: object(["exitCode": .int(2), "durationMs": .int(50)])
        )
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "bash",
            arguments: object(["command": .string("false")]),
            result: result,
            width: 40,
            theme: .plain
        )
        #expect(lines.first == "$ false")
        #expect(lines.contains { $0.contains("exited with code 2") })
        expectAllFit(lines, width: 40, "bash-error")
    }

    // MARK: Grep / find / ls compact lists

    @Test("Grep shows a compact match list with a header")
    func grepList() {
        let body = "src/a.swift:10: let x = 1\nsrc/b.swift:20: let y = 2"
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "grep",
            arguments: object(["pattern": .string("let"), "path": .string("src")]),
            result: .text(body),
            width: 60
        )
        #expect(lines.first == "grep let in src")
        #expect(lines.contains { $0.contains("a.swift:10") })
        expectAllFit(lines, width: 60, "grep")
    }

    @Test("A grep truncation notice is styled as a warning")
    func grepWarningStyled() {
        let body = "src/a.swift:1: x\n\n[100 matches limit reached. Use limit=200 for more]"
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "grep",
            arguments: object(["pattern": .string("x")]),
            result: .text(body),
            width: 80,
            theme: .ansi
        )
        // The bracketed notice line carries the warning (yellow) SGR code.
        #expect(lines.contains { $0.contains("matches limit") && $0.contains("\u{1b}[33m") })
        expectAllFit(lines, width: 80, "grep-warn")
    }

    @Test("Find lists paths under a header")
    func findList() {
        let body = "src/main.swift\nsrc/util.swift\ntests/t.swift"
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "find",
            arguments: object(["pattern": .string("*.swift")]),
            result: .text(body),
            width: 50
        )
        #expect(lines.first == "find *.swift")
        #expect(lines.count == 1 + 3)
        expectAllFit(lines, width: 50, "find")
    }

    @Test("Ls defaults its path to the current directory")
    func lsDefaultPath() {
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "ls",
            arguments: object([:]),
            result: .text("file.txt\ndir/"),
            width: 40
        )
        #expect(lines.first == "ls .")
        expectAllFit(lines, width: 40, "ls")
    }

    // MARK: Errors

    @Test("An error result is styled distinctly")
    func errorStyled() {
        let result = ToolResult.error("Could not edit file: missing.txt. No such file.")
        let plain = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("missing.txt")]),
            result: result,
            width: 60,
            theme: .plain
        )
        #expect(plain.first == "edit missing.txt")
        #expect(plain.contains { $0.contains("No such file") })

        let ansi = ToolRendererRegistry.builtin.render(
            toolName: "edit",
            arguments: object(["path": .string("missing.txt")]),
            result: result,
            width: 60,
            theme: .ansi
        )
        // The message line is red; the diff colours never appear for an error.
        #expect(ansi.contains { $0.contains("No such file") && $0.contains("\u{1b}[31m") })
        expectAllFit(ansi, width: 60, "error")
    }

    @Test("An invalid (non-string) path argument renders an invalid-arg marker")
    func invalidPathArg() {
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .int(42)]),
            result: .text("x"),
            width: 40
        )
        #expect(lines.first?.contains("[invalid arg]") == true)
    }

    // MARK: CJK / emoji / long paths

    @Test("CJK and emoji output never emits an over-wide line")
    func cjkEmojiFits() {
        let body = (1...50).map { _ in "日本語のテキスト 🎉🚀 mixed with ASCII こんにちは世界" }
            .joined(separator: "\n")
        for width in [8, 13, 20, 41, 80] {
            let lines = ToolRendererRegistry.builtin.render(
                toolName: "bash",
                arguments: object(["command": .string("echo 日本語 🎉")]),
                result: .text(body),
                width: width,
                theme: .ansi
            )
            expectAllFit(lines, width: width, "cjk-emoji w=\(width)")
        }
    }

    @Test("A very long CJK path in a header is clipped to width")
    func longCjkPathClipped() {
        let longPath = "/very/deep/" + String(repeating: "日本語ディレクトリ/", count: 20) + "file.swift"
        for width in [5, 10, 27, 50] {
            let lines = ToolRendererRegistry.builtin.render(
                toolName: "edit",
                arguments: object(["path": .string(longPath)]),
                result: ToolResult.text(
                    "ok",
                    details: object(["oldContent": .string("a\n"), "newContent": .string("b\n")])
                ),
                width: width,
                theme: .ansi
            )
            expectAllFit(lines, width: width, "long-path w=\(width)")
        }
    }

    @Test("An emoji-laden edit diff stays within width at every column budget")
    func emojiDiffFits() {
        let old = "const label = \"hello\";\n"
        let new = "const label = \"🎉 hello 世界 🚀\";\n"
        let result = ToolResult.text(
            "ok",
            details: object(["oldContent": .string(old), "newContent": .string(new)])
        )
        for width in [6, 11, 18, 30, 60] {
            let lines = ToolRendererRegistry.builtin.render(
                toolName: "edit",
                arguments: object(["path": .string("app.js")]),
                result: result,
                width: width,
                theme: .ansi
            )
            expectAllFit(lines, width: width, "emoji-diff w=\(width)")
        }
    }

    // MARK: Embedded newlines in headers

    @Test("A multi-line bash command header stays a single row")
    func multilineCommandHeaderIsOneRow() {
        // A returned array element is one terminal row. The differential renderer
        // writes it verbatim and measures it with `visibleWidth`, which counts a
        // bare `\n` as zero columns — so an embedded newline would pass the width
        // check yet advance the terminal a row, desynchronising cursor accounting.
        // A multi-line `bash` command (heredoc, `&&`-chained script) is the common
        // source, since the header is built straight from the raw argument.
        for width in [12, 40, 200] {
            let lines = ToolRendererRegistry.builtin.render(
                toolName: "bash",
                arguments: object(["command": .string("echo hi\nrm -rf tmp\necho done")]),
                result: .text("hi\ndone"),
                width: width,
                theme: .plain
            )
            for (index, line) in lines.enumerated() {
                #expect(!line.contains("\n"), "w=\(width) line \(index) has embedded newline: \(line.debugDescription)")
                #expect(!line.contains("\r"), "w=\(width) line \(index) has embedded CR: \(line.debugDescription)")
            }
            expectAllFit(lines, width: width, "multiline-cmd w=\(width)")
        }
    }

    @Test("A newline or CR in a path/pattern header is flattened to one row")
    func newlineInPathAndPatternHeaders() {
        let read = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .string("a.txt\nmalicious")]),
            result: .text("x"),
            width: 60
        )
        #expect(read.first == "read a.txt malicious")

        let grep = ToolRendererRegistry.builtin.render(
            toolName: "grep",
            arguments: object(["pattern": .string("foo\nbar"), "path": .string("src")]),
            result: .text("m"),
            width: 60
        )
        #expect(grep.first == "grep foo bar in src")

        let bashCR = ToolRendererRegistry.builtin.render(
            toolName: "bash",
            arguments: object(["command": .string("echo \r hidden")]),
            result: .text("out"),
            width: 60
        )
        #expect(bashCR.first?.contains("\r") == false)
    }

    @Test("The home directory is collapsed to ~ in a header path")
    func homeShortened() {
        let lines = ToolRendererRegistry.builtin.render(
            toolName: "read",
            arguments: object(["path": .string("/Users/me/project/file.txt")]),
            result: .text("x"),
            width: 60,
            homeDirectory: "/Users/me"
        )
        #expect(lines.first == "read ~/project/file.txt")
    }
}

// MARK: - Component adapter

@MainActor
@Suite("ToolResultView")
struct ToolResultViewTests {

    @Test("The component renders through the registry at the given width")
    func rendersThroughRegistry() {
        let view = ToolResultView(
            registry: .builtin,
            toolName: "read",
            arguments: .object(["path": .string("f.txt")]),
            result: .text((1...40).map { "line \($0)" }.joined(separator: "\n"))
        )
        let lines = view.render(width: 30)
        #expect(lines.first == "read f.txt")
        for line in lines { #expect(visibleWidth(line) <= 30) }
    }

    @Test("Flipping expanded shows the full body on the next render")
    func expandedToggles() {
        let view = ToolResultView(
            registry: .builtin,
            toolName: "read",
            arguments: .object(["path": .string("f.txt")]),
            result: .text((1...40).map { "line \($0)" }.joined(separator: "\n"))
        )
        let collapsed = view.render(width: 30)
        #expect(collapsed.contains { $0.contains("more lines") })
        view.expanded = true
        let expanded = view.render(width: 30)
        #expect(!expanded.contains { $0.contains("more lines") })
        #expect(expanded.count > collapsed.count)
    }

    @Test("A zero width degrades to a single empty line rather than trapping")
    func zeroWidth() {
        let view = ToolResultView(
            registry: .builtin,
            toolName: "ls",
            arguments: .object([:]),
            result: .text("a\nb")
        )
        #expect(view.render(width: 0) == [""])
    }
}
