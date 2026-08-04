// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI
import Foundation
import SystemPackage
import Testing

@testable import DoMoClient

@Suite("Theme preference")
struct ThemePreferenceTests {
    @Test("the selected theme survives a new client preference store")
    func savesAndLoadsTheme() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-theme-" + UUID().uuidString + ".json")
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let store = ThemePreferenceStore(path: path)
        #expect(store.load() == .dark)
        try store.save(.solarizedLight)

        #expect(ThemePreferenceStore(path: path).load() == .solarizedLight)
        let contents = try String(contentsOfFile: path.string, encoding: .utf8)
        #expect(contents.contains("solarized-light"))
    }

    @Test("an invalid preference falls back to the preserved dark default")
    func invalidPreferenceFallsBack() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-theme-invalid-" + UUID().uuidString + ".json")
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }
        try Data(#"{"theme":"not-a-theme"}"#.utf8).write(to: URL(fileURLWithPath: path.string))

        #expect(ThemePreferenceStore(path: path).load() == .dark)
    }
}
