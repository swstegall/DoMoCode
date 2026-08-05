// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

/// The process-independent model preference used by the full-screen client.
///
/// A model selection is a user setting, not session transcript state. The serving
/// runtime remains authoritative for whether an ID is usable; this file only
/// remembers the last successfully selected ID so the client can apply it when a
/// different session is opened.
struct ModelPreferenceStore: Sendable {
    private let path: FilePath?

    init(path: FilePath? = nil) {
        self.path = path
    }

    func load() -> String? {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
              let stored = try? JSONDecoder().decode(StoredModel.self, from: data),
              !stored.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return stored.model
    }

    func save(_ model: String) throws(DoMoError) {
        guard let path else { return }
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DoMoError(.configuration, "Could not save an empty model preference")
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(StoredModel(model: value))
        } catch {
            throw DoMoError(.configuration, "Could not encode model preference", cause: error)
        }
        try AtomicFileWrite.replace(
            at: path.string,
            with: String(decoding: data, as: UTF8.self) + "\n"
        )
    }

    private struct StoredModel: Codable, Sendable {
        let model: String
    }
}
