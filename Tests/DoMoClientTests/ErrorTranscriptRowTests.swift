// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `TranscriptItem.error` is the seam a persistent, scrollable failure row lands
// on. Nothing produces the case yet, so this file pins the RENDERING contract —
// that the row is red, that it wraps rather than overflowing the pane, and that
// its gateway-controlled message cannot smuggle an escape sequence into the
// frame. A row nobody produces still has to be correct the day someone does.

import DoMoTermGraphics
import DoMoTUI
import Testing

@testable import DoMoClient

@MainActor
private func rows(_ item: TranscriptItem, width: Int) -> [String] {
    let view = TranscriptView()
    view.items = [item]
    // `render` drops the trailing blank spacer the view puts between items.
    return view.render(width: width).dropLast()
}

@Suite("The error transcript row")
@MainActor
struct ErrorTranscriptRowTests {

    @Test("A row is a red headline, the message, and a dim hint")
    func shape() {
        let out = rows(
            .error(headline: "Out of quota", message: "402 payment required", hint: "Top up."),
            width: 60
        )
        #expect(out.count == 3)
        #expect(out[0].contains("✗ Out of quota"))
        #expect(out[0].contains("\u{1b}[1;31m"), "the headline must be bold red")
        #expect(out[1].contains("402 payment required"))
        #expect(out[1].contains("\u{1b}[31m"), "the message must be red")
        #expect(out[2].contains("→ Top up."))
        #expect(out[2].contains("\u{1b}[2m"), "the hint must be dim")
    }

    @Test("A missing hint costs a row rather than an empty one")
    func hintlessRow() {
        let out = rows(.error(headline: "Something went wrong", message: "boom", hint: nil), width: 40)
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.isEmpty })
    }

    @Test("A message with no text of its own still renders its headline")
    func emptyMessage() {
        let out = rows(.error(headline: "Cancelled", message: "", hint: nil), width: 40)
        #expect(out.count == 1)
        #expect(out[0].contains("✗ Cancelled"))
    }

    @Test("Every row fits the pane, at every width, for a long message")
    func neverOverflows() {
        let long = String(repeating: "the gateway returned an error ", count: 20)
        for width in [1, 2, 3, 8, 20, 41, 80] {
            let out = rows(
                .error(headline: "The gateway returned an error", message: long, hint: "Retry."),
                width: width
            )
            for line in out {
                #expect(visibleWidth(line) <= width, "width \(width) overflowed: \(visibleWidth(line))")
            }
        }
    }

    @Test("A long message wraps rather than being cut to one line")
    func wraps() {
        let long = String(repeating: "x", count: 200)
        let out = rows(.error(headline: "h", message: long, hint: nil), width: 20)
        #expect(out.count > 5, "the message must wrap, not truncate")
        // Two-space indent under the headline, same as tool output. The indent is
        // dropped below width 4, where it would not fit — see `errorRows`.
        #expect(out.dropFirst().allSatisfy { $0.hasPrefix("  ") })
        #expect(rows(.error(headline: "h", message: long, hint: nil), width: 3)
            .dropFirst().allSatisfy { !$0.hasPrefix(" ") })
    }

    @Test("A gateway cannot smuggle an escape sequence through any of the three parts")
    func sanitizesUntrustedText() {
        let out = rows(
            .error(
                headline: "head\u{1b}[2Jline",
                message: "mess\u{1b}[2Jage",
                hint: "hi\u{1b}[2Jnt"
            ),
            width: 60
        )
        let joined = out.joined()
        #expect(!joined.contains("\u{1b}[2J"))
        // The app's OWN styling escapes are still there — what must not survive is
        // an ESC introducer that came from the far side of the wire.
        #expect(joined.contains("\u{1b}[1;31m"))
    }

    @Test("A zero-width pane renders nothing rather than a malformed row")
    func degenerateWidth() {
        #expect(rows(.error(headline: "h", message: "m", hint: "x"), width: 0).isEmpty)
    }
}
