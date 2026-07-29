// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The gesture model behind "let me highlight, right click and copy". The pure
// span/highlight/text functions are pinned in DoMoTUI's ScreenSelectionTests;
// what is asserted here is everything the controller adds on top of them: which
// cells a press/drag/release names, how a click run becomes a word or a line,
// which pane a selection is confined to, and — the part that decides whether
// the feature is usable at all — WHEN a selection stops being valid on a page
// that repaints ten times a second.

import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
@Suite("Selection controller")
struct SelectionControllerTests {

    /// A painted page: every row padded to exactly `width`, which is the shape
    /// `ScreenSurface.lastFrameLines` guarantees and which the controller's width
    /// checks depend on.
    private func page(_ rows: [String], width: Int = 40) -> [String] {
        rows.map { padToWidth($0, width) }
    }

    private func cell(_ row: Int, _ column: Int) -> ScreenCell {
        ScreenCell(row: row, column: column)
    }

    // MARK: Drag

    @Test("A drag across rows copies in stream order, not as a rectangle")
    func dragSelectsInStreamOrder() {
        // A terminal selection is a STREAM: from the middle of one row it takes
        // the REST of that row, all of the rows between, and the START of the
        // last. A rectangle would copy a column of fragments out of prose.
        let frame = page(["alpha bravo", "charlie delta", "echo foxtrot"], width: 20)
        let controller = SelectionController()

        controller.press(at: cell(0, 6), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(2, 4), frame: frame)
        controller.release(at: cell(2, 4), frame: frame)

        #expect(controller.text(from: frame) == "bravo\ncharlie delta\necho")
    }

    @Test("Dragging upward selects exactly what dragging downward selects")
    func dragDirectionDoesNotMatter() {
        let frame = page(["alpha bravo", "charlie delta"], width: 20)
        let down = SelectionController()
        down.press(at: cell(0, 6), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        down.drag(to: cell(1, 7), frame: frame)
        down.release(at: cell(1, 7), frame: frame)

        let up = SelectionController()
        up.press(at: cell(1, 7), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        up.drag(to: cell(0, 6), frame: frame)
        up.release(at: cell(0, 6), frame: frame)

        #expect(down.text(from: frame) == up.text(from: frame))
        #expect(down.text(from: frame) == "bravo\ncharlie")
    }

    @Test("Copied rows carry no escapes and no trailing padding")
    func copiedTextIsPlainAndUnpadded() {
        // Every frame row is blank-padded to the page width and most carry SGR
        // colour. Neither belongs on a clipboard: the padding pastes sixty
        // trailing spaces per line and the escapes paste as garbage.
        let frame = page(["\u{1b}[1;33mwarning\u{1b}[0m: disk", "ok"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 2), frame: frame)
        controller.release(at: cell(1, 2), frame: frame)

        let text = try! #require(controller.text(from: frame))
        #expect(text == "warning: disk\nok")
        #expect(!text.contains("\u{1b}"))
        #expect(!text.contains("  "))
    }

    @Test("A plain click leaves no selection at all")
    func plainClickLeavesNoPhantomCell() {
        // A press and release in one place must not leave a one-cell highlight
        // behind, and must not make the next right-click copy one character.
        let frame = page(["alpha bravo"], width: 20)
        let controller = SelectionController()
        controller.press(at: cell(0, 3), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        controller.release(at: cell(0, 3), frame: frame)

        #expect(controller.selection == nil)
        #expect(controller.text(from: frame) == nil)
        #expect(controller.decorate(frame) == frame)
    }

    @Test("Motion with no button held does not resurrect a finished selection")
    func motionAfterReleaseIsIgnored() {
        let frame = page(["alpha bravo charlie"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(0, 5), frame: frame)
        controller.release(at: cell(0, 5), frame: frame)
        let frozen = controller.selection

        controller.drag(to: cell(0, 19), frame: frame)
        #expect(controller.selection == frozen, "a motion report after the button came up extended the selection")
    }

    // MARK: Shift-extend

    @Test("Shift-click keeps the anchor and moves only the focus")
    func shiftClickExtends() {
        let frame = page(["alpha bravo charlie delta"], width: 40)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<40, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(0, 5), frame: frame)
        controller.release(at: cell(0, 5), frame: frame)
        #expect(controller.text(from: frame) == "alpha")

        controller.press(at: cell(0, 19), columns: 0..<40, frame: frame, shiftExtend: true, now: Date())
        controller.release(at: cell(0, 19), frame: frame)
        #expect(controller.selection?.anchor == cell(0, 0))
        #expect(controller.text(from: frame) == "alpha bravo charlie")
    }

    @Test("Shift-click with nothing selected starts an ordinary selection")
    func shiftClickWithNoSelectionIsAPlainPress() {
        let frame = page(["alpha bravo"], width: 20)
        let controller = SelectionController()
        controller.press(at: cell(0, 2), columns: 0..<20, frame: frame, shiftExtend: true, now: Date())
        controller.drag(to: cell(0, 5), frame: frame)
        controller.release(at: cell(0, 5), frame: frame)
        #expect(controller.text(from: frame) == "pha")
    }

    // MARK: Click runs

    @Test("Two fast clicks take the word, three take the row's content")
    func doubleAndTripleClick() {
        let frame = page(["alpha bravo charlie"], width: 40)
        let controller = SelectionController()
        let start = Date()

        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start)
        controller.release(at: cell(0, 7), frame: frame)
        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.1))
        controller.release(at: cell(0, 7), frame: frame)
        #expect(controller.text(from: frame) == "bravo")

        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.2))
        controller.release(at: cell(0, 7), frame: frame)
        // Column 0 through the last non-blank, so leading indentation survives a
        // triple-click and the trailing pad does not.
        #expect(controller.text(from: frame) == "alpha bravo charlie")

        // The count wraps: a fourth click starts a fresh run rather than leaving
        // the user stuck on line-select.
        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.3))
        controller.release(at: cell(0, 7), frame: frame)
        #expect(controller.selection == nil, "the fourth click should behave like a first one")
    }

    @Test("Two slow clicks are two clicks, not a double-click")
    func slowClicksDoNotSelectAWord() {
        let frame = page(["alpha bravo charlie"], width: 40)
        let controller = SelectionController()
        let start = Date()
        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start)
        controller.release(at: cell(0, 7), frame: frame)
        controller.press(
            at: cell(0, 7),
            columns: 0..<40,
            frame: frame,
            shiftExtend: false,
            now: start.addingTimeInterval(SelectionController.multiClickInterval + 0.1)
        )
        controller.release(at: cell(0, 7), frame: frame)
        #expect(controller.selection == nil)
    }

    @Test("Two fast clicks in DIFFERENT cells are not a double-click")
    func doubleClickNeedsTheSameCell() {
        let frame = page(["alpha bravo charlie"], width: 40)
        let controller = SelectionController()
        let start = Date()
        controller.press(at: cell(0, 2), columns: 0..<40, frame: frame, shiftExtend: false, now: start)
        controller.release(at: cell(0, 2), frame: frame)
        controller.press(at: cell(0, 7), columns: 0..<40, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.1))
        controller.release(at: cell(0, 7), frame: frame)
        #expect(controller.selection == nil)
    }

    @Test("A double-click on blank space selects the blank run, not the row")
    func doubleClickPastContent() {
        let frame = page(["ab   cd"], width: 20)
        let controller = SelectionController()
        let start = Date()
        controller.press(at: cell(0, 3), columns: 0..<20, frame: frame, shiftExtend: false, now: start)
        controller.release(at: cell(0, 3), frame: frame)
        controller.press(at: cell(0, 3), columns: 0..<20, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.1))
        controller.release(at: cell(0, 3), frame: frame)
        #expect(controller.text(from: frame) == "")
        #expect(controller.selection != nil, "the whitespace run is still a selection")
    }

    // MARK: Panes

    @Test("A selection is confined to the pane the drag began in")
    func selectionIsClampedToThePane() {
        // The sidebar and the transcript share every row. Without the column
        // window a drag down the transcript would slice the session list into
        // every copied line.
        let frame = page(["sidebar-a  | transcript one", "sidebar-b  | transcript two"], width: 40)
        let controller = SelectionController()
        let transcript = 13..<40

        // A press left of the window is pulled into it, so an off-by-one report
        // during a resize cannot escape the pane.
        controller.press(at: cell(0, 0), columns: transcript, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 40), frame: frame)
        controller.release(at: cell(1, 40), frame: frame)

        let text = try! #require(controller.text(from: frame))
        #expect(text == "transcript one\ntranscript two")
        #expect(!text.contains("sidebar"))
    }

    @Test("A triple-click in a pane takes that pane's row, from its own first column")
    func tripleClickIsPaneRelative() {
        let frame = page(["sidebar-a  | transcript one"], width: 40)
        let controller = SelectionController()
        let start = Date()
        for offset in [0.0, 0.1, 0.2] {
            controller.press(
                at: cell(0, 20),
                columns: 13..<40,
                frame: frame,
                shiftExtend: false,
                now: start.addingTimeInterval(offset)
            )
            controller.release(at: cell(0, 20), frame: frame)
        }
        #expect(controller.text(from: frame) == "transcript one")
    }

    @Test("A double-click cannot pull a word out of the neighbouring pane")
    func doubleClickIsPaneRelative() {
        // No blank column between the panes: the word run would otherwise walk
        // straight across the boundary.
        let frame = page(["leftmostright"], width: 20)
        let controller = SelectionController()
        let start = Date()
        controller.press(at: cell(0, 10), columns: 8..<20, frame: frame, shiftExtend: false, now: start)
        controller.release(at: cell(0, 10), frame: frame)
        controller.press(at: cell(0, 10), columns: 8..<20, frame: frame, shiftExtend: false, now: start.addingTimeInterval(0.1))
        controller.release(at: cell(0, 10), frame: frame)
        // The word runs across the boundary; only the pane's half comes back.
        #expect(controller.text(from: frame) == "right")
    }

    // MARK: Invalidation

    @Test("A spinner tick elsewhere on the page does not drop the selection")
    func selectionSurvivesAnUnrelatedRepaint() {
        // The whole point of comparing only the SELECTED rows. This app repaints
        // at 10 Hz while a turn runs; invalidating on any frame change would
        // destroy every selection about 100 ms after it was made.
        let frame = page(["history one", "history two", "history three", "⠋ thinking…"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 11), frame: frame)
        controller.release(at: cell(1, 11), frame: frame)

        var ticked = frame
        ticked[3] = padToWidth("⠙ thinking…", 30)
        #expect(controller.validate(against: ticked))
        #expect(controller.text(from: ticked) == "history one\nhistory two")
    }

    @Test("A selected row that changes underneath clears the selection")
    func selectionDiesWhenItsOwnRowsChange() {
        // The alternative is worse than losing it: a highlight over one thing and
        // a clipboard full of another, with nothing to say so.
        let frame = page(["history one", "history two", "streaming tail"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(1, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(2, 9), frame: frame)
        controller.release(at: cell(2, 9), frame: frame)

        var streamed = frame
        streamed[2] = padToWidth("streaming tail plus more", 30)
        #expect(controller.validate(against: streamed) == false)
        #expect(controller.selection == nil)
        #expect(controller.decorate(streamed) == streamed)
    }

    @Test("A change in colour alone, with the same text, keeps the selection")
    func restylingIsNotAContentChange() {
        // Rows are compared escape-STRIPPED, so a row that merely stopped being
        // dim is the same text and the selection over it is still meaningful.
        let frame = page(["history one", "history two"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(0, 11), frame: frame)
        controller.release(at: cell(0, 11), frame: frame)

        var restyled = frame
        restyled[0] = "\u{1b}[2m" + padToWidth("history one", 30) + "\u{1b}[0m"
        #expect(controller.validate(against: restyled))
        #expect(controller.text(from: restyled) == "history one")
    }

    @Test("A resize clears the selection even when the selected rows survive it")
    func resizeClearsTheSelection() {
        let frame = page(["history one", "history two"], width: 30)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<30, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 11), frame: frame)
        controller.release(at: cell(1, 11), frame: frame)

        // Narrower page, same text on both selected rows: only the shape check
        // catches this, and without it the column window would point off the page.
        #expect(controller.validate(against: page(["history one", "history two"], width: 24)) == false)
        #expect(controller.selection == nil)
    }

    @Test("A page that grew or shrank a row clears the selection")
    func rowCountChangeClearsTheSelection() {
        let frame = page(["a", "b", "c"], width: 10)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<10, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 1), frame: frame)
        controller.release(at: cell(1, 1), frame: frame)

        #expect(controller.validate(against: page(["a", "b", "c", "d"], width: 10)) == false)
        #expect(controller.selection == nil)
    }

    @Test("Validating with nothing selected is not a failure")
    func validateWithNoSelection() {
        let controller = SelectionController()
        #expect(controller.validate(against: page(["a"], width: 10)))
    }

    // MARK: Decoration

    @Test("Decoration highlights the selected span and nothing else")
    func decorateHighlightsOnlyTheSelection() {
        let frame = page(["alpha bravo", "charlie", "delta"], width: 20)
        let controller = SelectionController()
        controller.press(at: cell(0, 6), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(1, 3), frame: frame)
        controller.release(at: cell(1, 3), frame: frame)

        let decorated = controller.decorate(frame)
        #expect(decorated[0].contains("\u{1b}[7m"), "row 0 should carry reverse video")
        #expect(decorated[1].contains("\u{1b}[7m"))
        // Byte-identical outside the selection, or the differential renderer
        // repaints the whole page ten times a second for a two-row highlight.
        #expect(decorated[2] == frame[2])
    }

    @Test("Decoration never changes a row's width")
    func decoratePreservesEveryRowWidth() {
        // `AltScreenCore.frame` throws on an over-wide row and the driver
        // escalates that to ending the session, so a highlight that added a
        // column would hang up on the user the first time they dragged across a
        // CJK glyph.
        let rows = ["plain ascii", "日本語のテキスト", "emoji 👍🏽 here", "\u{1b}[31mred\u{1b}[0m text"]
        for width in [12, 20, 40] {
            let frame = page(rows, width: width)
            for startColumn in 0..<width {
                let controller = SelectionController()
                controller.press(at: cell(0, startColumn), columns: 0..<width, frame: frame, shiftExtend: false, now: Date())
                controller.drag(to: cell(3, max(0, width - 1)), frame: frame)
                controller.release(at: cell(3, max(0, width - 1)), frame: frame)
                let decorated = controller.decorate(frame)
                #expect(decorated.count == frame.count)
                for (index, row) in decorated.enumerated() {
                    #expect(
                        visibleWidth(row) == width,
                        "w=\(width) start=\(startColumn) row=\(index) measured \(visibleWidth(row))"
                    )
                }
            }
        }
    }

    @Test("Clearing removes the highlight and the copy alike")
    func clearRemovesEverything() {
        let frame = page(["alpha bravo"], width: 20)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<20, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(0, 5), frame: frame)
        controller.release(at: cell(0, 5), frame: frame)
        #expect(controller.selection != nil)

        controller.clear()
        #expect(controller.selection == nil)
        #expect(controller.text(from: frame) == nil)
        #expect(controller.decorate(frame) == frame)
    }

    @Test("An empty frame is survivable at every entry point")
    func emptyFrameIsSafe() {
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 0..<10, frame: [], shiftExtend: false, now: Date())
        #expect(controller.selection == nil)
        controller.drag(to: cell(0, 5), frame: [])
        controller.release(at: cell(0, 5), frame: [])
        #expect(controller.text(from: []) == nil)
        #expect(controller.decorate([]) == [])
    }

    @Test("A degenerate pane window selects nothing")
    func emptyPaneWindowSelectsNothing() {
        let frame = page(["alpha"], width: 10)
        let controller = SelectionController()
        controller.press(at: cell(0, 0), columns: 5..<5, frame: frame, shiftExtend: false, now: Date())
        controller.drag(to: cell(0, 4), frame: frame)
        controller.release(at: cell(0, 4), frame: frame)
        #expect(controller.selection == nil)
    }
}

@MainActor
@Suite("Pane bounds")
struct PaneBoundsTests {

    @Test("Pane bounds agree with the hit test, cell for cell")
    func boundsMatchTheHitTest() {
        // Two derivations of the same rectangle drift. This is the assertion that
        // says they have not: every cell inside a pane's bounds must hit-test to
        // that pane.
        for promptRows in [1, 3, 7] {
            let layout = ClientLayout(width: 100, height: 24, promptRows: promptRows)
            for pane in [ClientLayout.Pane.sidebar, .transcript, .mainFooter] {
                let bounds = layout.bounds(of: pane)
                for row in bounds.rows {
                    for column in bounds.columns {
                        #expect(
                            layout.pane(atColumn: column, row: row) == pane,
                            "promptRows=\(promptRows) (\(column),\(row)) claims \(pane)"
                        )
                    }
                }
            }
        }
    }

    @Test("Pane bounds are derived from the current prompt height")
    func boundsFollowTheFooter() {
        let layout = ClientLayout(width: 100, height: 24, promptRows: 5)
        #expect(layout.bounds(of: .sidebar) == ClientLayout.PaneBounds(columns: 0..<25, rows: 0..<24))
        #expect(layout.bounds(of: .transcript) == ClientLayout.PaneBounds(columns: 25..<100, rows: 0..<18))
        #expect(layout.bounds(of: .mainFooter) == ClientLayout.PaneBounds(columns: 25..<100, rows: 18..<24))
    }

    @Test("The three panes tile the screen with no gap and no overlap")
    func boundsTileTheScreen() {
        for (width, height) in [(100, 24), (40, 10), (20, 5), (400, 60)] {
            let layout = ClientLayout(width: width, height: height, promptRows: 2)
            var covered = Set<[Int]>()
            for pane in [ClientLayout.Pane.sidebar, .transcript, .mainFooter] {
                let bounds = layout.bounds(of: pane)
                for row in bounds.rows {
                    for column in bounds.columns {
                        #expect(covered.insert([column, row]).inserted, "(\(column),\(row)) is in two panes")
                    }
                }
            }
            #expect(covered.count == width * height, "\(width)x\(height): \(covered.count) cells covered")
        }
    }

    @Test("A screen narrower than the sidebar produces no negative range")
    func degenerateSizes() {
        let layout = ClientLayout(width: 10, height: 3)
        for pane in [ClientLayout.Pane.sidebar, .transcript, .mainFooter] {
            let bounds = layout.bounds(of: pane)
            #expect(bounds.columns.lowerBound <= bounds.columns.upperBound)
            #expect(bounds.rows.lowerBound <= bounds.rows.upperBound)
        }
    }
}
