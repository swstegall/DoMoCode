// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing
@testable import DoMoTUI

// Real byte sequences for the keys the SelectList binds, so the tests exercise
// the actual DoMoTermIO decode path, not a stand-in.
private let upBytes = Array("\u{1b}[A".utf8)
private let downBytes = Array("\u{1b}[B".utf8)
private let enterBytes: [UInt8] = [0x0d]
private let escBytes: [UInt8] = [0x1b]

@MainActor
@Suite("SelectList")
struct SelectListTests {
    private func items(_ values: [String]) -> [SelectItem] {
        values.map { SelectItem(value: $0, label: $0) }
    }

    // MARK: Navigation

    @Test("Down moves the selection and wraps at the bottom")
    func downWraps() {
        let list = SelectList(items: items(["a", "b", "c"]), maxVisible: 5)
        var seen: [String] = []
        list.onSelectionChange = { seen.append($0.value) }

        list.handleInput(downBytes) // a -> b
        list.handleInput(downBytes) // b -> c
        #expect(list.getSelectedItem()?.value == "c")
        list.handleInput(downBytes) // c -> a (wrap)
        #expect(list.getSelectedItem()?.value == "a")
        #expect(seen == ["b", "c", "a"])
    }

    @Test("Up moves the selection and wraps at the top")
    func upWraps() {
        let list = SelectList(items: items(["a", "b", "c"]), maxVisible: 5)
        #expect(list.getSelectedItem()?.value == "a")
        list.handleInput(upBytes) // a -> c (wrap)
        #expect(list.getSelectedItem()?.value == "c")
        list.handleInput(upBytes) // c -> b
        #expect(list.getSelectedItem()?.value == "b")
    }

    @Test("Enter confirms the selected item; Escape cancels")
    func confirmAndCancel() {
        let list = SelectList(items: items(["a", "b", "c"]), maxVisible: 5)
        var confirmed: String?
        var cancelled = false
        list.onSelect = { confirmed = $0.value }
        list.onCancel = { cancelled = true }

        list.handleInput(downBytes) // -> b
        list.handleInput(enterBytes)
        #expect(confirmed == "b")

        list.handleInput(escBytes)
        #expect(cancelled)
    }

    // MARK: Scroll window

    @Test("The scroll window follows the selection down the list")
    func scrollWindowFollows() {
        // 10 items, window of 3. Selecting deep must slide the window so the
        // selection stays visible.
        let list = SelectList(items: items((0..<10).map { "item\($0)" }), maxVisible: 3)
        list.setSelectedIndex(7)
        let lines = list.render(width: 30)
        // The rendered rows must include the selected item, marked with the arrow.
        let selectedRow = lines.first { $0.contains("→") }
        #expect(selectedRow?.contains("item7") == true)
        // Row for item0 (top) must NOT be present — the window scrolled past it.
        #expect(!lines.contains { $0.contains("item0") })
        // A scroll indicator line reports content hidden above and below.
        #expect(lines.contains { $0.contains("more above") })
    }

    @Test("Scroll indicator shows only 'below' at the top and only 'above' at the bottom")
    func scrollIndicatorDirection() {
        let list = SelectList(items: items((0..<10).map { "i\($0)" }), maxVisible: 3)
        list.setSelectedIndex(0)
        let top = list.render(width: 30)
        #expect(top.contains { $0.contains("more below") })
        #expect(!top.contains { $0.contains("more above") })

        list.setSelectedIndex(9)
        let bottom = list.render(width: 30)
        #expect(bottom.contains { $0.contains("more above") })
        #expect(!bottom.contains { $0.contains("more below") })
    }

    // MARK: Filtering

    @Test("A filter narrows the items and resets the selection")
    func filterNarrows() {
        let list = SelectList(items: items(["apple", "apricot", "banana"]), maxVisible: 5)
        list.setSelectedIndex(2) // banana
        list.setFilter("ap")
        // Only the two ap* items remain; selection reset to the first.
        #expect(list.getSelectedItem()?.value == "apple")
        list.handleInput(downBytes)
        #expect(list.getSelectedItem()?.value == "apricot")
        list.handleInput(downBytes) // wrap over just two items
        #expect(list.getSelectedItem()?.value == "apple")
    }

    @Test("The no-match message never exceeds a narrow width budget")
    func noMatchFitsNarrowWidth() {
        // Regression: the 22-column message was previously emitted verbatim,
        // producing an over-wide (renderer-fatal) line in any narrower viewport.
        let list = SelectList(items: items(["apple", "banana"]), maxVisible: 5)
        list.setFilter("zzz")
        for width in 1...25 {
            let lines = list.render(width: width)
            for line in lines {
                #expect(visibleWidth(line) <= width,
                        "no-match over budget at width \(width): \(visibleWidth(line))")
            }
        }
    }

    @Test("Every item row fits, including a width-1 viewport and CJK content")
    func itemRowsFitEveryWidth() {
        // Regression: the fixed 2-column selection prefix overran a width-1 line.
        let cjk = SelectList(
            items: (0..<8).map {
                SelectItem(value: "命令\($0)你好世界", label: "命令\($0)你好世界",
                           description: "説明\($0)非常に長い説明文です")
            },
            maxVisible: 4)
        for width in 1...60 {
            cjk.setSelectedIndex(5)
            for line in cjk.render(width: width) {
                #expect(visibleWidth(line) <= width,
                        "item row over budget at width \(width): \(visibleWidth(line))")
            }
        }
    }

    @Test("A filter matching nothing renders the no-match message")
    func filterNoMatch() {
        let list = SelectList(items: items(["apple", "banana"]), maxVisible: 5)
        list.setFilter("zzz")
        let lines = list.render(width: 30)
        #expect(lines.count == 1)
        #expect(lines[0].contains("No matching"))
        #expect(list.getSelectedItem() == nil)
    }

    // MARK: Width budget

    @Test("Every rendered line fits the width budget, including descriptions")
    func rendersWithinWidth() {
        let long = String(repeating: "x", count: 80)
        var built: [SelectItem] = []
        for i in 0..<12 {
            built.append(SelectItem(
                value: "command-\(i)-\(long)",
                label: "command-\(i)-\(long)",
                description: "A very long description that would overflow: \(long)"
            ))
        }
        let list = SelectList(items: built, maxVisible: 5)
        for width in [10, 20, 41, 60, 100] {
            list.setSelectedIndex(6)
            for line in list.render(width: width) {
                #expect(visibleWidth(line) <= width, "line over budget at width \(width): \(visibleWidth(line))")
            }
        }
    }

    @Test("Rendered lines fit the width through the screen oracle")
    func widthThroughOracle() throws {
        let built = (0..<8).map {
            SelectItem(value: "opt\($0)", label: "Option \($0)", description: "does thing \($0)")
        }
        let list = SelectList(items: built, maxVisible: 4)
        list.setSelectedIndex(5)

        let oracle = ScreenOracle(rows: 8, cols: 44)
        let target = CaptureTarget(columns: 44, rows: 8)
        let tui = TUI(target: target)
        tui.addChild(list)
        try oracle.drive(tui, from: target)

        // No cell beyond the last column should ever be written by the list —
        // the oracle would show wrap artifacts. Assert each row fits 44 columns.
        for r in 0..<8 {
            #expect(visibleWidth(oracle.row(r)) <= 44)
        }
        // The selected option is on screen.
        #expect(oracle.screen.contains { $0.contains("Option 5") })
    }

    // MARK: Empty list

    @Test("Cancel still fires when the list is empty")
    func emptyCancel() {
        let list = SelectList(items: [], maxVisible: 5)
        var cancelled = false
        list.onCancel = { cancelled = true }
        list.handleInput(downBytes) // no crash on empty
        list.handleInput(escBytes)
        #expect(cancelled)
    }
}
