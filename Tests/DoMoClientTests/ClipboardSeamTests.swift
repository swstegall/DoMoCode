// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The clipboard seam, and the one property that makes it worth having: what
// crosses it is CLIPBOARD-CLEAN TEXT — no escapes, no pad spaces — so an
// implementation on the other side never has to know it came from a painted
// terminal page. Public API only, so this builds in release without `@testable`.

import DoMoClient
import DoMoTermIO
import DoMoTUI
import Testing

/// Records what a copy asked for, and answers with whatever the test wants.
private actor RecordingClipboard: ClipboardSink {
    private(set) var copied: [String] = []
    private let outcome: ClipboardOutcome

    init(outcome: ClipboardOutcome = .copied("recorder")) {
        self.outcome = outcome
    }

    func copy(_ text: String) async -> ClipboardOutcome {
        copied.append(text)
        return outcome
    }

    func recorded() -> [String] { copied }
}

@Suite("Clipboard seam")
struct ClipboardSeamTests {

    private let escape = "\u{1b}"

    @Test("The no-op sink reports unavailable rather than pretending to have copied")
    func noClipboardSinkIsHonest() async {
        // Over ssh this IS the correct sink, so `unavailable` must be
        // distinguishable from `failed` — one is a fact about the machine, the
        // other is something the user might act on.
        #expect(await NoClipboardSink().copy("anything") == .unavailable)
        #expect(ClipboardOutcome.unavailable != ClipboardOutcome.failed("no helper"))
        #expect(ClipboardOutcome.copied("pbcopy") != ClipboardOutcome.copied("xclip"))
        #expect(ClipboardOutcome.copied("pbcopy") == ClipboardOutcome.copied("pbcopy"))
    }

    @Test("A sink receives exactly what selectionText produced: no ANSI, no trailing pad")
    func whatCrossesTheSeamIsClipboardClean() async {
        // A page as the renderer actually paints it: styled, and padded to the pane
        // width on every row.
        let width = 48
        let frame = [
            padToWidth("\(escape)[2m$ swift build\(escape)[0m", width),
            padToWidth("\(escape)[32mBuild complete!\(escape)[0m", width),
            padToWidth("", width),
        ]
        let selection = ScreenSelection(
            anchor: ScreenCell(row: 0, column: 0),
            focus: ScreenCell(row: 1, column: 15)
        )
        let text = selectionText(frame, selection: selection, columns: 0..<width)

        let sink = RecordingClipboard()
        let outcome = await sink.copy(text)
        #expect(outcome == .copied("recorder"))

        let recorded = await sink.recorded()
        #expect(recorded == ["$ swift build\nBuild complete!"])
        #expect(!recorded[0].contains(escape), "an escape reaching the clipboard would paste as garbage")
        #expect(!recorded[0].hasSuffix(" "), "pad spaces must not reach the clipboard")
    }

    @Test("A failing sink names the mechanism, which is what a status notice needs")
    func failureCarriesAReason() async {
        let sink = RecordingClipboard(outcome: .failed("pbcopy exited 1"))
        #expect(await sink.copy("text") == .failed("pbcopy exited 1"))
    }

    @Test("OSC 52 carries the same bytes the sink was handed")
    func osc52AndTheSinkAgree() async {
        // The two halves of a copy run unconditionally and must not disagree: the
        // terminal-native path and the local helper write identical content, which
        // is why no success handshake is needed between them.
        let frame = [padToWidth("copy me", 20)]
        let selection = ScreenSelection(anchor: ScreenCell(row: 0, column: 0), focus: ScreenCell(row: 0, column: 7))
        let text = selectionText(frame, selection: selection, columns: 0..<20)
        #expect(text == "copy me")

        let sink = RecordingClipboard()
        _ = await sink.copy(text)
        let sequence = try! #require(osc52CopySequence(Array(text.utf8)))
        #expect(String(decoding: sequence, as: UTF8.self) == "\(escape)]52;c;Y29weSBtZQ==\u{07}")
        #expect(await sink.recorded() == [text])
    }

    @Test("An oversized selection is refused by OSC 52 and still handed to the sink")
    func oversizedSelectionFallsBackToTheHelper() async {
        // The refusal is the whole reason the local helper is not optional: a
        // truncated OSC 52 would put a WRONG clipboard on the user's machine.
        let huge = String(repeating: "x", count: osc52PayloadLimit)
        #expect(osc52CopySequence(Array(huge.utf8)) == nil)
        let sink = RecordingClipboard()
        #expect(await sink.copy(huge) == .copied("recorder"))
        #expect(await sink.recorded().first?.count == huge.count)
    }
}
