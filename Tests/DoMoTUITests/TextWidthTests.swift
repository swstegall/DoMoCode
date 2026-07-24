// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import Testing

// MARK: - Width

@Suite("visibleWidth / graphemeWidth")
struct TextWidthTests {
    @Test("ASCII is one column per character")
    func ascii() {
        #expect(visibleWidth("") == 0)
        #expect(visibleWidth("hello") == 5)
        #expect(visibleWidth("a b c") == 5)
        #expect(graphemeWidth("a") == 1)
    }

    @Test("CJK ideographs are two columns each")
    func cjk() {
        // Each of these is a single grapheme cluster of East Asian Width "Wide".
        #expect(Array("你好").count == 2)
        #expect(graphemeWidth("你") == 2)
        #expect(visibleWidth("你好") == 4)
        #expect(visibleWidth("a你b") == 4)
    }

    @Test("A ZWJ family emoji is one cluster measured wide")
    func zwjEmoji() {
        let family = "👨‍👩‍👧‍👦"
        // One extended grapheme cluster despite being seven scalars joined by ZWJ.
        #expect(Array(family).count == 1)
        #expect(family.unicodeScalars.count > 1)
        #expect(graphemeWidth(Character(family)) == 2)
        #expect(visibleWidth(family) == 2)
    }

    @Test("A regional-indicator flag is one cluster, two columns")
    func flag() {
        #expect(Array("🇺🇸").count == 1)
        #expect(graphemeWidth("🇺🇸") == 2)
    }

    @Test("Combining marks are zero width")
    func combiningMarks() {
        // A lone combining acute accent contributes nothing.
        #expect(graphemeWidth("\u{301}") == 0)
        // Attached to a base it forms one width-1 cluster, not 1 + 0 counted twice.
        let combined: Character = "e\u{301}"
        #expect(combined.unicodeScalars.count == 2)
        #expect(graphemeWidth(combined) == 1)
        #expect(visibleWidth("cafe\u{301}") == 4)
    }

    @Test("Default-ignorable and zero-width scalars measure zero")
    func zeroWidthScalars() {
        #expect(graphemeWidth("\u{200B}") == 0)  // ZERO WIDTH SPACE
        #expect(graphemeWidth("\u{200D}") == 0)  // ZERO WIDTH JOINER
        #expect(graphemeWidth("\u{FEFF}") == 0)  // ZERO WIDTH NO-BREAK SPACE
        #expect(graphemeWidth("\u{2060}") == 0)  // WORD JOINER (default-ignorable)
    }

    @Test("Tabs are three columns, matching pi's fixed expansion")
    func tabs() {
        #expect(graphemeWidth("\t") == tabColumnWidth)
        #expect(visibleWidth("\t") == 3)
        #expect(visibleWidth("a\tb") == 5)
    }

    @Test("SGR codes do not count toward width")
    func sgrIsInvisible() {
        #expect(visibleWidth("\u{1b}[31mred\u{1b}[0m") == visibleWidth("red"))
        #expect(visibleWidth("\u{1b}[1;38;5;240mstyled\u{1b}[0m") == 6)
        // Cursor and erase CSI codes strip too.
        #expect(visibleWidth("\u{1b}[2KAB\u{1b}[H") == 2)
    }

    @Test("OSC 8 hyperlink wrappers do not count toward width")
    func osc8Hyperlink() {
        let link = "\u{1b}]8;;https://example.com\u{07}click\u{1b}]8;;\u{07}"
        #expect(visibleWidth(link) == 5)
    }
}

// MARK: - Slicing

@Suite("sliceByColumn / truncateToWidth / padToWidth")
struct TextSlicingTests {
    @Test("Plain column slice")
    func plainSlice() {
        #expect(sliceByColumn("hello", from: 1, to: 4) == "ell")
        #expect(sliceByColumn("hello", from: 0, to: 5) == "hello")
        #expect(sliceByColumn("hello", from: 3, to: 99) == "lo")
        #expect(sliceByColumn("hello", from: 2, to: 2) == "")
    }

    @Test("Strict slicing never splits a wide cluster at the boundary")
    func strictWideBoundary() {
        // "a你b": a@0, 你@1-2 (wide), b@3.
        let strict = sliceWithWidth("a你b", from: 0, to: 2, strict: true)
        #expect(strict.text == "a")
        #expect(strict.width == 1)  // the wide char would reach column 3, so it is dropped

        // A window that fully contains the wide char keeps it.
        #expect(sliceByColumn("a你b", from: 1, to: 3, strict: true) == "你")
    }

    @Test("Non-strict slicing keeps a straddling wide cluster and overhangs")
    func nonStrictOverhang() {
        let loose = sliceWithWidth("a你b", from: 0, to: 2, strict: false)
        #expect(loose.text == "a你")
        #expect(loose.width == 3)  // one column past the requested two
    }

    @Test("A slice preserves the SGR state active at its start")
    func slicePreservesStyle() {
        let styled = "\u{1b}[31mABCDE\u{1b}[0m"
        let piece = sliceByColumn(styled, from: 1, to: 4)
        // The red opened before column 1 is carried in, so the slice is still red.
        #expect(piece.contains("\u{1b}[31m"))
        #expect(visibleWidth(piece) == 3)
        #expect(piece.hasSuffix("BCD") || piece.contains("BCD"))
    }

    @Test("Checked slice throws on an over-wide non-strict result")
    func checkedSliceThrows() {
        #expect(throws: DoMoError.self) {
            try checkedSliceByColumn("a你b", from: 0, to: 2, strict: false)
        }
        // Strict fits by construction, so the same window does not throw.
        #expect(throws: Never.self) {
            _ = try checkedSliceByColumn("a你b", from: 0, to: 2, strict: true)
        }
    }

    @Test("Checked slice reports the malformedResponse kind")
    func checkedSliceKind() {
        do {
            _ = try checkedSliceByColumn("你", from: 0, to: 1, strict: false)
            Issue.record("expected a throw")
        } catch {
            #expect(error.kind == .malformedResponse)
        }
    }

    @Test("Truncation appends an ellipsis only when content is dropped")
    func truncate() {
        #expect(truncateToWidth("hi", 8) == "hi")
        let cut = truncateToWidth("hello world", 8)
        #expect(visibleWidth(cut) == 8)
        #expect(cut.contains("..."))
        #expect(cut.contains("hello"))
        #expect(!cut.contains("world"))
    }

    @Test("Truncation drops rather than splits a wide cluster at the budget")
    func truncateWide() {
        // Total width 9 > 8, so it truncates. Keep budget = 8 - 3(ellipsis) = 5:
        // A@0 B@1 你@2-3 keep (width 4), next 你 would reach column 6 > 5, so it is
        // dropped whole rather than halved.
        let cut = truncateToWidth("AB你你你X", 8)
        #expect(visibleWidth(cut) <= 8)
        #expect(cut.contains("AB你"))
        #expect(!cut.contains("你你"))
    }

    @Test("Padding fills to the requested width")
    func pad() {
        #expect(truncateToWidth("hi", 5, pad: true) == "hi   ")
        #expect(padToWidth("hi", 5) == "hi   ")
        #expect(padToWidth("hello", 3) == "hello")  // pad never truncates
        #expect(visibleWidth(padToWidth("你", 5)) == 5)
    }

    @Test("Checked padding throws when the text already overflows")
    func checkedPadThrows() throws {
        #expect(throws: DoMoError.self) {
            try padToWidthChecked("hello", 3)
        }
        #expect(try padToWidthChecked("hi", 5) == "hi   ")
    }

    @Test("requireVisibleWidth throws over budget and returns the width within")
    func requireWidth() throws {
        #expect(throws: DoMoError.self) {
            try requireVisibleWidth("hello", atMost: 3)
        }
        #expect(try requireVisibleWidth("hello", atMost: 5) == 5)
        #expect(try requireVisibleWidth("你好", atMost: 4) == 4)
    }
}
