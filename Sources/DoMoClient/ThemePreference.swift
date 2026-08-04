// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoTUI
import Foundation
import SystemPackage

/// The process-wide theme choice for the full-screen client.
///
/// Theme selection is deliberately separate from workspace/session state. A
/// session can move between workspaces and runtimes, but the terminal UI should
/// keep the operator's chosen palette until they select another one. The file is
/// tiny, atomic, and best-effort on read; a damaged preference falls back to the
/// preserved dark default rather than preventing the client from starting.
struct ThemePreferenceStore: Sendable {
    private let path: FilePath?

    init(path: FilePath? = nil) {
        self.path = path
    }

    func load() -> ThemeAppearance {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
              let stored = try? JSONDecoder().decode(StoredTheme.self, from: data),
              let appearance = ThemeAppearance(rawValue: stored.theme)
        else {
            return .dark
        }
        return appearance
    }

    func save(_ appearance: ThemeAppearance) throws(DoMoError) {
        guard let path else { return }
        let data: Data
        do {
            data = try JSONEncoder().encode(StoredTheme(theme: appearance.rawValue))
        } catch {
            throw DoMoError(.configuration, "Could not encode theme preference", cause: error)
        }
        try AtomicFileWrite.replace(
            at: path.string,
            with: String(decoding: data, as: UTF8.self) + "\n"
        )
    }

    private struct StoredTheme: Codable, Sendable {
        let theme: String
    }
}
