// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Choosing an entry from the palette and having it land in the prompt CORRECTLY
// SPELLED. The bug these pin: the palette is opened by typing `/`, so that `/` is
// still in the draft when the choice comes back, and the old insertion appended
// `"/" + name` to it — `//read `, which is not a tool and dies at the parser.
//
// The four rules the user asked for are all one rule here (replace the token under
// the caret), so each is stated as its own test: whatever an implementation does to
// one of them, it must not quietly trade it against another.

import Foundation
import Testing

@testable import DoMoClient

/// The left arrow, the only way to put the caret anywhere but the end of the
/// document from outside `PromptInput` — which is the point, since the insertion
/// is defined relative to the caret.
private let leftArrow: [UInt8] = Array("\u{1b}[D".utf8)

@MainActor
@Suite("Prompt command insertion")
struct PromptInsertionTests {

    // MARK: The four rules

    @Test("A slash command chosen from an empty draft inserts once")
    func slashEntryFromAnEmptyDraft() {
        let input = PromptInput()
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "/read ")
    }

    @Test("The `/` that opened the palette is overwritten, never doubled")
    func theOpeningSlashIsNotDoubled() {
        // The reported defect, verbatim: `/` then choosing `/read` gave `//read `.
        let input = PromptInput()
        input.handleInput(Array("/".utf8))
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "/read ")
    }

    @Test("A bare entry chosen after a `/` eats the `/`")
    func aBareEntryEatsTheSlash() {
        // An agent is invoked by name. The `/` was only ever the gesture that
        // opened the palette, so it must not survive into the message.
        let input = PromptInput()
        input.handleInput(Array("/".utf8))
        input.insertCommand("explore", requiresSlash: false)
        #expect(input.text == "explore ")
    }

    @Test("A bare entry chosen from an empty draft keeps its bare name")
    func aBareEntryFromAnEmptyDraft() {
        let input = PromptInput()
        input.insertCommand("explore", requiresSlash: false)
        #expect(input.text == "explore ")
    }

    // MARK: What the splice must not destroy

    @Test("Words already written before the token survive the insertion")
    func earlierWordsSurvive() {
        let input = PromptInput()
        input.handleInput(Array("summarise the diff then /re".utf8))
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "summarise the diff then /read ")
    }

    @Test("A word after the caret on the same line survives the insertion")
    func laterWordsOnTheSameLineSurvive() {
        // Only the shape is pinned, not the exact run of spaces between the
        // command and the following word: whether the splice leaves one space or
        // two in front of a word that already had one belongs to
        // `spliceTokenAtCursor` and is pinned by its own tests. What belongs HERE
        // is that the following word is still there at all and that the command
        // came out with exactly one slash.
        let input = PromptInput()
        input.setText("/re tail")
        for _ in 0..<5 { input.handleInput(leftArrow) }   // caret just after "/re"
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text.hasPrefix("/read"))
        #expect(input.text.hasSuffix("tail"))
        #expect(!input.text.contains("//"))
    }

    @Test("The caret lands after the inserted command, not at the end of the draft")
    func theCaretStaysWhereTheSpliceHappened() {
        // This is the whole reason the insertion goes through `applyAutocomplete`
        // instead of `setText`: `setText` re-anchors the caret to the end of the
        // DOCUMENT, so the next thing typed would land on the last line
        // ("/read \ntailx") rather than after the command the user just chose.
        let input = PromptInput()
        input.setText("/re\ntail")
        for _ in 0..<5 { input.handleInput(leftArrow) }   // (1,4) → (1,0) → (0,3)
        input.insertCommand("read", requiresSlash: true)
        input.handleInput(Array("x".utf8))
        #expect(input.text == "/read x\ntail")
    }

    @Test("A multi-line draft is spliced on the caret's line only")
    func onlyTheCaretsLineChanges() {
        let input = PromptInput()
        input.setText("first line\nsecond /re")
        input.insertCommand("read", requiresSlash: true)
        #expect(input.text == "first line\nsecond /read ")
    }

    // MARK: The wrapper the existing call sites use

    @Test("insertToolCommand still spells a tool `/name` and still appends")
    func toolWrapperKeepsItsSpelling() {
        // The tool catalog inserts one command, then possibly a second one after
        // it. The caret is left after a trailing space, so the second insertion
        // finds an empty token there and writes into it rather than over the first.
        let input = PromptInput()
        input.insertToolCommand("read")
        #expect(input.text == "/read ")
        input.insertToolCommand("grep")
        #expect(input.text == "/read /grep ")
    }

    // MARK: Names that are not well formed

    @Test("A name that already carries its slash is not given a second one")
    func aPreSlashedNameIsNotDoubled() {
        let input = PromptInput()
        input.insertCommand("/read", requiresSlash: true)
        #expect(input.text == "/read ")
    }

    @Test("An empty or slash-only name leaves the draft untouched")
    func anEmptyNameChangesNothing() {
        let input = PromptInput()
        input.setText("keep me")
        input.insertCommand("   ", requiresSlash: true)
        #expect(input.text == "keep me")
        input.insertCommand("/", requiresSlash: true)
        #expect(input.text == "keep me")
        input.insertCommand("", requiresSlash: false)
        #expect(input.text == "keep me")
    }

    @Test("An escape sequence in a name never reaches the document")
    func controlCharactersAreStripped() {
        // Tool names come off an MCP server. The draft is repainted into a live
        // terminal, so an unsanitized name is an injection with a UI, not a
        // cosmetic problem.
        let input = PromptInput()
        input.insertCommand("read\u{1b}[31m", requiresSlash: true)
        #expect(!input.text.contains("\u{1b}"))
        #expect(input.text == "/read[31m ")
    }

    @Test("A newline in a name cannot put a line break inside a line")
    func newlinesInANameAreFolded() {
        // `Editor` addresses its buffer as lines of `Character` and joins them
        // with `\n` on the way out, so a literal newline spliced INTO a line is an
        // invariant violation rather than a line break.
        let input = PromptInput()
        input.insertCommand("read\nnow", requiresSlash: true)
        #expect(!input.text.contains("\n"))
        #expect(input.text == "/read now ")
    }
}
