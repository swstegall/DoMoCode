// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI
import Testing

@Suite("Theme documents")
struct ThemeDocumentTests {
    @Test("custom theme documents round trip and resolve inherited backgrounds")
    func roundTripAndFallback() throws {
        let document = ThemeDocument(
            id: "custom",
            displayName: "Custom",
            theme: Theme(
                dark: ThemePalette(
                    foreground: .rgb(red: 0xf0, green: 0xf0, blue: 0xf0),
                    background: .rgb(red: 0x10, green: 0x10, blue: 0x10)
                ),
                light: ThemePalette(
                    foreground: .rgb(red: 0x20, green: 0x20, blue: 0x20),
                    background: .rgb(red: 0xf0, green: 0xf0, blue: 0xf0)
                )
            )
        )
        let encoded = try ThemeDocumentCodec.encode(document)
        let decoded = try ThemeDocumentCodec.decode(encoded)
        #expect(decoded == document)
        #expect(decoded.resolvedTheme().dark.background == document.theme.dark.background)
        #expect(decoded.resolvedTheme().light.accent != .inherit)
    }

    @Test("low contrast themes are refused and RGB palettes adapt to indexed terminals")
    func validatesContrastAndCapabilities() {
        let inaccessible = ThemeDocument(
            id: "low",
            displayName: "Low",
            theme: Theme(
                dark: ThemePalette(
                    foreground: .rgb(red: 0x20, green: 0x20, blue: 0x20),
                    background: .rgb(red: 0x22, green: 0x22, blue: 0x22)
                ),
                light: ThemePalette(
                    foreground: .rgb(red: 0x20, green: 0x20, blue: 0x20),
                    background: .rgb(red: 0x22, green: 0x22, blue: 0x22)
                )
            )
        )
        #expect(throws: ThemeDocumentError.self) {
            _ = try ThemeDocumentCodec.validate(inaccessible)
        }

        let adapted = Theme.standard.palette(for: .dark).adapted(
            for: ThemeRenderCapabilities(trueColor: false)
        )
        if case .ansiIndex = adapted.foreground {
            // expected indexed fallback
        } else {
            Issue.record("RGB theme color was not adapted for an indexed terminal")
        }
    }
}
