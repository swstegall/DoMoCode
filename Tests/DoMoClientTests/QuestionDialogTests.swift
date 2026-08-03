// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoServer
import DoMoTUI
import Testing
@testable import DoMoClient

@MainActor
@Suite("Question dialog")
struct QuestionDialogTests {
    @Test("single-choice prompts submit the highlighted option")
    func singleChoice() {
        let dialog = QuestionDialog(questions: [ServerQuestionPrompt(
            question: "Which format?",
            options: [ServerQuestionOption(label: "JSON"), ServerQuestionOption(label: "SQLite")]
        )])
        var submitted: [ServerQuestionAnswer]?
        dialog.onSubmit = { submitted = $0 }

        dialog.handleInput([0x1b, 0x5b, 0x42]) // Down
        dialog.handleInput([0x0d]) // Enter

        #expect(submitted == [ServerQuestionAnswer(selectedLabels: ["SQLite"])])
    }

    @Test("multiple-choice prompts keep selected options in display order")
    func multipleChoice() {
        let dialog = QuestionDialog(questions: [ServerQuestionPrompt(
            question: "Which formats?",
            options: [
                ServerQuestionOption(label: "JSON"),
                ServerQuestionOption(label: "SQLite"),
                ServerQuestionOption(label: "CSV"),
            ],
            allowsMultiple: true
        )])
        var submitted: [ServerQuestionAnswer]?
        dialog.onSubmit = { submitted = $0 }

        dialog.handleInput([0x20]) // select JSON
        dialog.handleInput([0x1b, 0x5b, 0x42]) // Down
        dialog.handleInput([0x20]) // select SQLite
        dialog.handleInput([0x0d]) // Enter

        #expect(submitted == [ServerQuestionAnswer(selectedLabels: ["JSON", "SQLite"])])
    }

    @Test("question text is sanitized and clipped to the overlay width")
    func safeRendering() {
        let dialog = QuestionDialog(questions: [ServerQuestionPrompt(
            header: "\u{1b}[2J Header",
            question: "\u{1b}[31m" + String(repeating: "long ", count: 30),
            options: [ServerQuestionOption(label: "\u{1b}[?25lChoice", description: "description")]
        )])

        let lines = dialog.render(width: 24)
        #expect(lines.allSatisfy { visibleWidth($0) <= 24 })
        #expect(lines.joined().contains("\u{1b}[2J") == false)
        #expect(lines.joined().contains("\u{1b}[31m") == false)
    }
}
