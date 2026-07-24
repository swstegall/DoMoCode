// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The cell-pixel-size query reply parser (pure) and the ioctl-based query's
// no-terminal path.

import DoMoTermIO
import Foundation
import Testing

@Suite("Cell pixel size")
struct CellPixelSizeTests {
    @Test("A cell-size report parses HEIGHT then WIDTH")
    func parseReport() {
        // ESC [ 6 ; height ; width t  ->  18px tall, 9px wide cell.
        #expect(parseCellPixelSizeReport("\u{1b}[6;18;9t") == CellPixelSize(widthPx: 9, heightPx: 18))
        #expect(parseCellPixelSizeReport("\u{1b}[6;40;20t") == CellPixelSize(widthPx: 20, heightPx: 40))
    }

    @Test("Other XTWINOPS reports and malformed sequences are rejected")
    func rejectsOthers() {
        #expect(parseCellPixelSizeReport("\u{1b}[4;100;200t") == nil)   // text-area report (leading 4)
        #expect(parseCellPixelSizeReport("\u{1b}[8;24;80t") == nil)     // window report (leading 8)
        #expect(parseCellPixelSizeReport("\u{1b}[6;18t") == nil)        // only one param
        #expect(parseCellPixelSizeReport("\u{1b}[6;a;b t") == nil)      // non-numeric
        #expect(parseCellPixelSizeReport("\u{1b}[6;0;0t") == nil)       // zero dimensions
        #expect(parseCellPixelSizeReport("garbage") == nil)
        #expect(parseCellPixelSizeReport("\u{1b}[6;18;9;3t") == nil)    // extra param
    }

    @Test("The query string is the XTWINOPS 16 sequence")
    func queryString() {
        #expect(cellPixelSizeQuery == "\u{1b}[16t")
    }

    @Test("cellPixelSize returns nil for a descriptor with no terminal")
    func noTerminal() {
        // A pipe has no window size, so the ioctl fails and the result is nil
        // rather than a fabricated cell size.
        let pipe = Pipe()
        #expect(TerminalSize.cellPixelSize(fileDescriptor: pipe.fileHandleForReading.fileDescriptor) == nil)
    }
}
