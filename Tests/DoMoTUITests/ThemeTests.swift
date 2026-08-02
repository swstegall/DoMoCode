// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI
import Foundation
import Testing

@MainActor
@Suite("Theme values")
struct ThemeTests {
    @Test("hex colours accept short and full forms")
    func hexForms() {
        #expect(ThemeColor(specification: "#abc") == .rgb(red: 0xaa, green: 0xbb, blue: 0xcc))
        #expect(ThemeColor(specification: "#102030") == .rgb(red: 0x10, green: 0x20, blue: 0x30))
        #expect(ThemeColor(specification: "ansi:42") == .ansiIndex(42))
        #expect(ThemeColor(specification: "none") == .inherit)
        #expect(ThemeColor(specification: "#12") == nil)
    }

    @Test("inheritance and Codable preserve the theme spelling")
    func inheritanceAndCodable() throws {
        #expect(ThemeColor.none.resolved(over: .ansiIndex(7)) == .ansiIndex(7))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let color = ThemeColor.rgb(red: 1, green: 2, blue: 3)
        let decoded = try decoder.decode(ThemeColor.self, from: encoder.encode(color))
        #expect(decoded == color)
        #expect(ThemeColor.none.foreground() == "")
        #expect(ThemeColor.ansiIndex(7).foreground() == "\u{1b}[38;5;7m")
    }

    @Test("dark and light palettes expose different accents")
    func appearancePalettes() {
        #expect(Theme.standard.palette(for: .dark).accent != Theme.standard.palette(for: .light).accent)
    }
}
