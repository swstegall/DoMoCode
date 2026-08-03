// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing

@Suite("VT screen")
struct VTScreenTests {

    @Test("Cursor movement and erasure interpret foreign ANSI output")
    func cursorAndErase() {
        var screen = VTScreen(columns: 16, rows: 3)
        screen.feed("login")
        screen.feed("\u{1b}[2;4Hready")
        #expect(screen.line(0) == "login")
        #expect(screen.line(1) == "   ready")
        screen.feed("\u{1b}[2K")
        #expect(screen.line(1).isEmpty)
    }

    @Test("Split UTF-8, SGR, OSC titles, and alternate screens are modeled")
    func parserStateSurvivesChunks() {
        var screen = VTScreen(columns: 12, rows: 2)
        let check = Array("✅".utf8)
        screen.feed([0x1b, 0x5d, 0x30, 0x3b])
        screen.feed(Array("Sign in".utf8) + [0x07])
        screen.feed([0x1b, 0x5b, 0x33, 0x31, 0x6d] + Array("red".utf8) + [0x1b, 0x5b, 0x30, 0x6d])
        screen.feed(Array(" ".utf8) + Array(check.prefix(1)))
        screen.feed(Array(check.dropFirst()))

        // The title is exposed separately from the screen text, so OSC is not
        // accidentally presented as model-visible prompt content.
        #expect(screen.title == "Sign in")
        #expect(screen.line(0).hasPrefix("red ✅"))
        #expect(screen.cell(row: 0, column: 0)?.style.foreground == .indexed(1))
        #expect(screen.cell(row: 0, column: 3)?.style == .plain)

        screen.feed("\u{1b}[?1049hother\u{1b}[?25l")
        #expect(screen.alternateScreen)
        #expect(screen.line(0) == "other")
        #expect(!screen.cursorVisible)
        screen.feed("\u{1b}[?1049l")
        #expect(!screen.alternateScreen)
        #expect(screen.line(0).hasPrefix("red ✅"))
    }

    @Test("Scrolling and line editing keep the cursor inside the bounded grid")
    func scrollingAndEditing() {
        var screen = VTScreen(columns: 8, rows: 2)
        screen.feed("one\r\ntwo\r\nthree")
        #expect(screen.line(0) == "two")
        #expect(screen.line(1) == "three")
        screen.feed("\u{1b}[1;1H\u{1b}[P")
        #expect(screen.line(0) == "wo")
        #expect(screen.cursor.row >= 0 && screen.cursor.row < 2)
        #expect(screen.cursor.column >= 0 && screen.cursor.column < 8)
    }
}
