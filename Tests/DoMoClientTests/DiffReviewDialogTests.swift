// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoGit
import DoMoTUI
import Testing
@testable import DoMoClient

@MainActor
@Suite("Diff review dialog")
struct DiffReviewDialogTests {
    private func diff() -> GitDiff {
        GitDiff(
            base: "0123456789abcdef",
            branch: "main",
            files: [
                GitDiffFile(
                    path: "Sources/very/long/project/Feature.swift",
                    status: .modified,
                    hunks: [
                        GitDiffHunk(
                            header: "@@ -1,2 +1,3 @@",
                            oldStart: 1,
                            oldCount: 2,
                            newStart: 1,
                            newCount: 3,
                            lines: [
                                GitDiffLine(kind: .context, text: "keep"),
                                GitDiffLine(kind: .deletion, text: "old", oldLine: 2),
                                GitDiffLine(kind: .addition, text: "new", newLine: 2),
                            ]
                        ),
                        GitDiffHunk(
                            header: "@@ -20,1 +21,2 @@",
                            oldStart: 20,
                            oldCount: 1,
                            newStart: 21,
                            newCount: 2,
                            lines: [
                                GitDiffLine(kind: .context, text: "later"),
                                GitDiffLine(kind: .addition, text: "extra", newLine: 22),
                            ]
                        ),
                    ]
                ),
                GitDiffFile(
                    path: "README.md",
                    status: .added,
                    hunks: [
                        GitDiffHunk(
                            header: "@@ -0,0 +1,1 @@",
                            oldStart: 0,
                            oldCount: 0,
                            newStart: 1,
                            newCount: 1,
                            lines: [GitDiffLine(kind: .addition, text: "new file", newLine: 1)]
                        ),
                    ]
                ),
            ],
            patch: "patch"
        )
    }

    @Test("width chooses a compact unified or split review layout")
    func widthChoosesLayout() {
        let dialog = DiffReviewDialog(diff: diff())

        let narrow = dialog.render(width: 80)
        #expect(narrow.allSatisfy { visibleWidth($0) <= 80 })
        #expect(narrow.joined(separator: "\n").contains("u split"))

        let wide = dialog.render(width: 120)
        #expect(wide.allSatisfy { visibleWidth($0) <= 120 })
        #expect(wide.joined(separator: "\n").contains("u unified"))
    }

    @Test("file, hunk, review, restore, commit, and close keys reach their actions")
    func keyboardActions() {
        let dialog = DiffReviewDialog(diff: diff())
        var reverted: String?
        var committed = false
        var closed = false
        dialog.onRevert = { reverted = $0 }
        dialog.onCommitMessage = { committed = true }
        dialog.onClose = { closed = true }

        dialog.handleInput([0x1b, 0x5b, 0x42]) // Down: README.md
        dialog.handleInput(Array("r".utf8))
        #expect(dialog.render(width: 80).joined().contains("✓ README.md"))

        dialog.handleInput(Array("v".utf8))
        dialog.handleInput(Array("c".utf8))
        dialog.handleInput([0x1b])

        #expect(reverted == "README.md")
        #expect(committed)
        #expect(closed)
    }

    @Test("hunk navigation selects the next hunk")
    func hunkNavigation() {
        let dialog = DiffReviewDialog(diff: diff())

        dialog.handleInput(Array("]".utf8))

        let lines = dialog.render(width: 80)
        #expect(lines.contains { $0.contains("> @@ -20,1 +21,2 @@") })
        #expect(lines.contains { $0.contains("+extra") })
    }

    @Test("untrusted paths and patch lines are sanitized and clipped")
    func safeRendering() {
        let unsafe = GitDiff(
            base: nil,
            branch: "main",
            files: [
                GitDiffFile(
                    path: "\u{1b}[2Junsafe.swift",
                    status: .modified,
                    hunks: [
                        GitDiffHunk(
                            header: "@@ -1,1 +1,1 @@",
                            oldStart: 1,
                            oldCount: 1,
                            newStart: 1,
                            newCount: 1,
                            lines: [
                                GitDiffLine(kind: .addition, text: "\u{1b}[31mnew\u{1b}[0m", newLine: 1),
                            ]
                        ),
                    ]
                ),
            ],
            patch: ""
        )

        let rendered = DiffReviewDialog(diff: unsafe).render(width: 24)
        #expect(rendered.allSatisfy { visibleWidth($0) <= 24 })
        let text = rendered.joined()
        #expect(!text.contains("\u{1b}[2J"))
        #expect(!text.contains("\u{1b}[31m"))
    }
}
