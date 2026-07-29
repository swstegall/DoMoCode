// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Dropping a file onto the prompt, at the seam where it is decided whether a
// paste is a drop at all. The rule the whole feature rests on is negative:
// NEVER SILENTLY EAT A PATH THE USER MEANT AS TEXT. Most of these tests are
// therefore about what does NOT become an attachment.

import DoMoLLM
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
@Suite("Prompt drops")
struct PromptDropTests {

    private func paste(_ text: String) -> [UInt8] {
        Array("\u{1b}[200~\(text)\u{1b}[201~".utf8)
    }

    private func attachment(_ id: UInt32, _ path: String, _ name: String) -> PromptAttachment {
        PromptAttachment(
            id: id,
            path: path,
            name: name,
            byteCount: 4,
            image: ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        )
    }

    @Test("A pasted absolute path is handed to the app and nothing is typed")
    func aPathBecomesADrop() {
        let input = PromptInput()
        input.focused = true
        var seen: [(UInt32, [[String]])] = []
        input.onDrop = { token, candidates in seen.append((token, candidates)) }

        input.handleInput(paste("/tmp/shot.png"))

        #expect(seen.count == 1)
        #expect(seen.first?.1.first == ["/tmp/shot.png"])
        #expect(input.text.isEmpty, "the path was typed into the prompt as well as dropped")
    }

    @Test("The raw paste is held against the token so a refusal can put it back")
    func rawTextIsHeld() {
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/shot.png "))

        let issued = try! #require(token)
        #expect(input.pendingDropText(for: issued) == "/tmp/shot.png ")
        input.resolveDrop(token: issued, outcome: .attached([]))
        #expect(input.pendingDropText(for: issued) == nil, "an answered drop still holds its text")
    }

    @Test("A rejected drop puts the paste back verbatim")
    func rejectionRestoresTheText() {
        // The guarantee, stated as a test: a path that is not an image, or is not
        // there, leaves the user with exactly the text they pasted.
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/notes.txt"))
        #expect(input.text.isEmpty)

        input.resolveDrop(
            token: try! #require(token),
            outcome: .rejected(rawText: "/tmp/notes.txt", notice: "not an image")
        )
        #expect(input.text == "/tmp/notes.txt")
        #expect(input.attachments.isEmpty)
    }

    @Test("An attached drop becomes a chip and no text")
    func attachmentBecomesAChip() {
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/shot.png"))
        input.resolveDrop(
            token: try! #require(token),
            outcome: .attached([attachment(1, "/tmp/shot.png", "shot.png")])
        )

        #expect(input.text.isEmpty)
        #expect(input.attachments.count == 1)
        #expect(input.chipRows(width: 40).contains { $0.contains("shot.png") })
    }

    @Test("Prose that mentions a path is inserted verbatim and never offered as a drop")
    func proseIsNotADrop() {
        let input = PromptInput()
        var fired = false
        input.onDrop = { _, _ in fired = true }
        input.handleInput(paste("please read /tmp/a.png and summarise"))

        #expect(!fired, "prose was offered to the app as a drop")
        #expect(input.text == "please read /tmp/a.png and summarise")
    }

    @Test("A relative path is text, not a drop")
    func relativePathsAreText() {
        let input = PromptInput()
        var fired = false
        input.onDrop = { _, _ in fired = true }
        input.handleInput(paste("notes.png"))
        #expect(!fired)
        #expect(input.text == "notes.png")
    }

    @Test("A multi-line paste beginning with a path is a code block, not a drop")
    func multiLinePasteIsText() {
        let input = PromptInput()
        var fired = false
        input.onDrop = { _, _ in fired = true }
        input.handleInput(paste("/usr/bin/env python\nprint(1)\n"))
        #expect(!fired)
        #expect(input.text.contains("print(1)"))
    }

    @Test("With no app to answer, a path is ordinary text")
    func noConsumerMeansNoDrop() {
        // A prompt whose owner cannot resolve a file must not swallow one: there
        // would be nobody to call `resolveDrop`, and the path would vanish.
        let input = PromptInput()
        input.handleInput(paste("/tmp/shot.png"))
        #expect(input.text == "/tmp/shot.png")
    }

    @Test("Every terminal's spelling of a dropped path reaches the app")
    func allSpellingsParse() {
        for spelling in [
            "/tmp/holiday snap.png",
            "/tmp/holiday\\ snap.png ",
            "'/tmp/holiday snap.png'",
            "file:///tmp/holiday%20snap.png",
        ] {
            let input = PromptInput()
            var candidates: [[String]] = []
            input.onDrop = { _, received in candidates = received }
            input.handleInput(paste(spelling))
            #expect(!candidates.isEmpty, "no candidates for \(spelling)")
            #expect(
                candidates.contains { $0 == ["/tmp/holiday snap.png"] },
                "\(spelling) never offered the real path: \(candidates)"
            )
            #expect(input.text.isEmpty, "\(spelling) leaked into the prompt")
        }
    }

    @Test("A stale answer is dropped rather than applied to a document that moved on")
    func staleResolutionIsIgnored() {
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/shot.png"))
        let issued = try! #require(token)

        input.clear()   // the user gave up and cleared the box
        input.resolveDrop(token: issued, outcome: .rejected(rawText: "/tmp/shot.png", notice: "gone"))
        #expect(input.text.isEmpty, "a stale drop wrote into a cleared prompt")

        // And an answer cannot be applied twice.
        input.handleInput(paste("/tmp/second.png"))
        let second = try! #require(token)
        input.resolveDrop(token: second, outcome: .attached([attachment(2, "/tmp/second.png", "second.png")]))
        input.resolveDrop(token: second, outcome: .attached([attachment(3, "/tmp/third.png", "third.png")]))
        #expect(input.attachments.count == 1)
    }

    @Test("Backspace on an empty prompt pops the newest chip")
    func backspaceRemovesTheLastChip() {
        let input = PromptInput()
        input.addAttachment(attachment(1, "/tmp/a.png", "a.png"))
        input.addAttachment(attachment(2, "/tmp/b.png", "b.png"))
        input.handleInput([0x7f])
        #expect(input.attachments.map(\.name) == ["a.png"])
    }

    @Test("Submitting carries the attachments and clears them")
    func submitCarriesAttachments() {
        let input = PromptInput()
        var submitted: (String, [PromptAttachment])?
        input.onSubmit = { text, attachments in submitted = (text, attachments) }
        input.addAttachment(attachment(1, "/tmp/a.png", "a.png"))
        input.handleInput(Array("look".utf8))
        input.handleInput([0x0d])

        #expect(submitted?.0 == "look")
        #expect(submitted?.1.count == 1)
        #expect(input.attachments.isEmpty, "the chips outlived the send")
    }

    @Test("A refused send puts the chips back with the text")
    func restorePutsChipsBack() {
        let input = PromptInput()
        input.restore("look", attachments: [attachment(1, "/tmp/a.png", "a.png")])
        #expect(input.text == "look")
        #expect(input.attachments.count == 1)
    }

    // MARK: Enter while a drop is still being read

    @Test("Enter is refused while a drop is unanswered, and the text is kept")
    func submitWaitsForAPendingDrop() {
        // THE WINDOW. A drop swallows the paste and is answered one whole
        // multi-megabyte read later. Sending in between used to clear
        // `pendingDrops`, which made the answer stale — the images never reached
        // the prompt, the model got a message with no picture in it, and the
        // status line said "attached 1 image" anyway.
        let input = PromptInput()
        input.focused = true
        var submitted: [(String, [PromptAttachment])] = []
        var deferrals = 0
        var token: UInt32?
        input.onSubmit = { text, attachments in submitted.append((text, attachments)) }
        input.onDrop = { received, _ in token = received }
        input.onSubmitDeferredForDrop = { deferrals += 1 }

        input.handleInput(paste("/tmp/shot.png"))
        let issued = try! #require(token)
        input.handleInput(Array("describe this".utf8))
        input.handleInput([0x0d])   // Enter, mid-read

        #expect(submitted.isEmpty, "a message was sent while its picture was still loading")
        #expect(deferrals == 1, "the refusal was silent")
        #expect(input.text == "describe this", "the typed text was destroyed by the refusal")

        // The answer is still LIVE, because the send did not clear the token.
        #expect(input.resolveDrop(token: issued, outcome: .attached([attachment(1, "/tmp/shot.png", "shot.png")])))
        #expect(input.attachments.map(\.name) == ["shot.png"])

        // And the very next Enter sends the whole thing.
        input.handleInput([0x0d])
        #expect(submitted.count == 1)
        #expect(submitted.first?.0 == "describe this")
        #expect(submitted.first?.1.count == 1, "the image did not ride the message")
    }

    @Test("A drop answered after the prompt was cleared reports that it was NOT applied")
    func abandonedDropIsReportedAsSuch() {
        // The half of the window that survives the Enter guard: a session opened
        // under the drop clears the prompt. `resolveDrop` must say `false` so the
        // app cannot post "attached 1 image" about a chip that does not exist.
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/shot.png"))
        let issued = try! #require(token)

        input.clear()
        let live = input.resolveDrop(
            token: issued, outcome: .attached([attachment(1, "/tmp/shot.png", "shot.png")]))
        #expect(!live, "a stale answer claimed it had been applied")
        #expect(input.attachments.isEmpty)
    }

    @Test("A live answer reports that it WAS applied")
    func liveDropReportsLive() {
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/shot.png"))
        #expect(input.resolveDrop(
            token: try! #require(token),
            outcome: .attached([attachment(1, "/tmp/shot.png", "shot.png")])
        ))
    }

    @Test("A partial answer stages the chips and puts back only the refused paths")
    func partialOutcomeKeepsWhatLoaded() {
        let input = PromptInput()
        var token: UInt32?
        input.onDrop = { received, _ in token = received }
        input.handleInput(paste("/tmp/a.png /tmp/notes.txt"))

        #expect(input.resolveDrop(
            token: try! #require(token),
            outcome: .partial(
                attached: [attachment(1, "/tmp/a.png", "a.png")],
                text: "/tmp/notes.txt"
            )
        ))
        #expect(input.attachments.map(\.name) == ["a.png"])
        #expect(input.text == "/tmp/notes.txt", "the refused path did not come back as text")
    }
}
