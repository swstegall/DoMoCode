// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// What a failure looks like once it is a modal instead of a line by the prompt.
// Reproduced before this component existed, by driving the real client under a
// PTY against a dead gateway: the failure landed only as a transcript row, and
// the retry warning that preceded it was cut mid-word on the transient notice
// line ("Retrying in 544ms (request "). Both are exactly what these tests pin
// down: the detail is wrapped rather than truncated, and it has a surface the
// user can act on.

import DoMoTermIO
import DoMoTUI
import Testing

@testable import DoMoClient

@MainActor
@Suite("Error dialog")
struct ErrorDialogTests {
    private static let enter: [UInt8] = [0x0d]
    private static let escape: [UInt8] = [0x1b]
    private static let down: [UInt8] = [0x1b, 0x5b, 0x42]
    private static let up: [UInt8] = [0x1b, 0x5b, 0x41]
    private static let pageDown = Array("\u{1b}[6~".utf8)
    private static let pageUp = Array("\u{1b}[5~".utf8)

    private static func paragraph(_ marker: String) -> String {
        "The gateway returned 500 for model gpt-4o-mini after 3 attempts. "
            + "The upstream provider reported an internal error and did not say "
            + "whether the request was billed. \(marker)"
    }

    private static func entry(
        _ headline: String = "The gateway returned an error",
        message: String? = nil,
        hint: String? = nil
    ) -> ErrorDialogEntry {
        ErrorDialogEntry(headline: headline, message: message ?? paragraph("END-MARKER"), hint: hint)
    }

    @Test("The detail wraps to the dialog width instead of being cut to one line")
    func wrapsRatherThanTruncating() {
        let dialog = ErrorDialog(
            entry: Self.entry(hint: "Retry, or switch model."),
            keybindings: Keybindings(),
            viewportRows: 20
        )

        let lines = dialog.render(width: 40)

        #expect(lines.allSatisfy { visibleWidth($0) <= 40 })
        #expect(lines.contains { $0.contains("The gateway returned an error") })
        // The words at the START and at the END of the paragraph both survive:
        // a one-line notice keeps the first and loses the second.
        #expect(lines.contains { $0.contains("gateway returned 500") })
        #expect(lines.contains { $0.contains("END-MARKER") })
        #expect(lines.contains { $0.contains("Retry, or switch model.") })
    }

    @Test("Enter closes a lone error and the footer says so")
    func enterCloses() {
        let dialog = ErrorDialog(entry: Self.entry())
        var closed = 0
        dialog.onClose = { closed += 1 }

        #expect(dialog.render(width: 60).last?.contains("Enter to close") == true)

        dialog.handleInput(Self.enter)

        #expect(closed == 1)
        #expect(dialog.isEmpty)
        #expect(dialog.current == nil)
        // Nothing left to draw: the owner dismisses the overlay on `onClose`, and
        // an empty dialog must not paint a stray frame in the meantime.
        #expect(dialog.render(width: 60).isEmpty)
    }

    @Test("Escape closes too, so a wrong key never traps the user")
    func escapeCloses() {
        let dialog = ErrorDialog(entry: Self.entry())
        dialog.enqueue(Self.entry("A second failure", message: "and its detail"))
        var closed = 0
        dialog.onClose = { closed += 1 }

        dialog.handleInput(Self.escape)

        #expect(closed == 1)
        #expect(dialog.pendingCount == 0)
    }

    @Test("A burst queues: Enter advances through it and closes on the last")
    func queueAdvancesRatherThanStackingOrDropping() {
        let dialog = ErrorDialog(entry: Self.entry("First failure", message: "first detail"))
        dialog.enqueue(Self.entry("Second failure", message: "second detail"))
        dialog.enqueue(Self.entry("Third failure", message: "third detail"))
        var closed = 0
        dialog.onClose = { closed += 1 }

        #expect(dialog.pendingCount == 3)
        var lines = dialog.render(width: 80)
        #expect(lines.contains { $0.contains("First failure") })
        #expect(lines.last?.contains("(1 of 3)") == true)
        #expect(lines.last?.contains("Esc closes all") == true)

        dialog.handleInput(Self.enter)
        lines = dialog.render(width: 80)
        // The second error is not stacked on top of the first, and it was not
        // dropped in favour of it either.
        #expect(lines.contains { $0.contains("Second failure") })
        #expect(lines.contains { $0.contains("First failure") } == false)
        #expect(lines.last?.contains("(2 of 3)") == true)
        #expect(closed == 0)

        dialog.handleInput(Self.enter)
        #expect(dialog.render(width: 80).last?.contains("(3 of 3)") == true)
        #expect(closed == 0)

        dialog.handleInput(Self.enter)
        #expect(closed == 1)
        #expect(dialog.isEmpty)
    }

    @Test("A lone error shows no queue counter")
    func singleErrorHasNoCounter() {
        let dialog = ErrorDialog(entry: Self.entry())
        let footer = dialog.render(width: 80).last ?? ""
        #expect(footer.contains("Enter to close"))
        #expect(footer.contains(" of ") == false)
    }

    @Test("A repeat of the same failure folds into the one already waiting")
    func coalescesIdenticalPendingFailures() {
        let repeated = Self.entry("Cannot reach the gateway", message: "Connection refused")
        let dialog = ErrorDialog(entry: repeated)
        for _ in 0..<5 { dialog.enqueue(repeated) }

        #expect(dialog.pendingCount == 1)

        // A repeat AFTER the user dismissed it is new information — the retry
        // failed again — so it must not be swallowed by the same rule.
        dialog.handleInput(Self.enter)
        dialog.enqueue(repeated)
        #expect(dialog.pendingCount == 1)
        #expect(dialog.current == repeated)
    }

    @Test("A retry storm is bounded, and the overflow is counted rather than hidden")
    func boundsTheQueue() {
        let dialog = ErrorDialog()
        for index in 0..<(ErrorDialog.maxPending + 7) {
            dialog.enqueue(Self.entry("Failure \(index)", message: "detail \(index)"))
        }

        #expect(dialog.pendingCount == ErrorDialog.maxPending)
        #expect(dialog.suppressedCount == 7)
        #expect(dialog.render(width: 100).last?.contains("7 more in the transcript") == true)
    }

    @Test("Long detail scrolls, with the range and a visible 'more' affordance")
    func scrolls() {
        let long = (1...40).map { "line \($0) of the provider's complaint" }.joined(separator: "\n")
        let dialog = ErrorDialog(entry: Self.entry(message: long), viewportRows: 8)

        var lines = dialog.render(width: 60)
        #expect(lines.count == 8)
        #expect(lines.contains { $0.contains("line 1 of") })
        #expect(lines.contains { $0.contains("line 40 of") } == false)
        #expect(lines.last?.contains("more below") == true)
        #expect(lines.last?.contains("1-7/") == true)

        dialog.handleInput(Self.pageDown)
        lines = dialog.render(width: 60)
        #expect(lines.contains { $0.contains("line 1 of") } == false)

        dialog.handleInput(Array("G".utf8))
        lines = dialog.render(width: 60)
        #expect(lines.contains { $0.contains("line 40 of") })
        #expect(lines.last?.contains("more above") == true)

        // Past the end stays at the end rather than scrolling into blank rows.
        dialog.handleInput(Self.pageDown)
        dialog.handleInput(Self.down)
        #expect(dialog.render(width: 60).contains { $0.contains("line 40 of") })

        dialog.handleInput(Array("g".utf8))
        #expect(dialog.render(width: 60).contains { $0.contains("line 1 of") })

        dialog.handleInput(Self.pageUp)
        dialog.handleInput(Self.up)
        #expect(dialog.render(width: 60).last?.contains("1-7/") == true)
    }

    @Test("Scrolling one error does not carry over to the next")
    func scrollResetsPerError() {
        let long = (1...30).map { "alpha \($0)" }.joined(separator: "\n")
        let dialog = ErrorDialog(entry: Self.entry("First", message: long), viewportRows: 8)
        dialog.enqueue(Self.entry("Second", message: (1...30).map { "beta \($0)" }.joined(separator: "\n")))

        // Render first: the scroll clamp is against the height the LAST render
        // produced, so a key pressed before anything was drawn has nothing to
        // move against and this would otherwise assert on a no-op.
        #expect(dialog.render(width: 60).contains { $0.contains("alpha 1") })
        dialog.handleInput(Array("G".utf8))
        #expect(dialog.render(width: 60).contains { $0.contains("alpha 30") })

        dialog.handleInput(Self.enter)

        let lines = dialog.render(width: 60)
        #expect(lines.contains { $0.contains("beta 1") })
        #expect(lines.contains { $0.contains("beta 30") } == false)
    }

    @Test("Provider prose cannot drive the terminal")
    func sanitizesEveryString() {
        let dialog = ErrorDialog(
            entry: ErrorDialogEntry(
                headline: "Bad \u{1b}[2Jheadline",
                message: "detail with \u{1b}[31mred\u{1b}[0m and a \rcarriage return",
                hint: "hint \u{1b}]0;title\u{07}too"
            ),
            viewportRows: 20
        )

        let lines = dialog.render(width: 60)
        for line in lines {
            #expect(line.contains("\u{1b}[2J") == false)
            #expect(line.contains("\u{1b}[31m") == false)
            #expect(line.contains("\u{1b}]0;") == false)
            #expect(line.contains("\r") == false)
        }
        #expect(lines.contains { $0.contains("carriage return") })
    }

    @Test("A failure after the queue drained starts a fresh burst")
    func numbersEachBurstFromOne() {
        let dialog = ErrorDialog(entry: Self.entry("First", message: "one"))
        dialog.enqueue(Self.entry("Second", message: "two"))
        dialog.handleInput(Self.enter)
        dialog.handleInput(Self.enter)

        dialog.enqueue(Self.entry("Later", message: "three"))
        dialog.enqueue(Self.entry("Later still", message: "four"))

        #expect(dialog.render(width: 80).last?.contains("(1 of 2)") == true)
    }

    @Test("Every row stays inside a hostile width")
    func staysInsideNarrowWidths() {
        let dialog = ErrorDialog(
            entry: Self.entry(hint: "Check network connectivity; this request can be retried."),
            viewportRows: 6
        )
        for width in [1, 2, 5, 13, 31] {
            let lines = dialog.render(width: width)
            #expect(lines.allSatisfy { visibleWidth($0) <= width })
            #expect(lines.count <= 6)
        }
        #expect(dialog.render(width: 0).isEmpty)
    }

    @Test("A resize that rewraps shorter never leaves the view scrolled past the end")
    func clampsOffsetAfterResize() {
        let long = (1...30).map { "row \($0)" }.joined(separator: "\n")
        let dialog = ErrorDialog(entry: Self.entry(message: long), viewportRows: 8)

        _ = dialog.render(width: 20)
        dialog.handleInput(Array("G".utf8))
        // Wide enough that far fewer rows are needed: the old offset now points
        // past the end, and an unclamped slice would render blank or trap.
        let lines = dialog.render(width: 400)
        #expect(lines.count > 1)
        #expect(lines.contains { $0.contains("row 30") })
    }
}
