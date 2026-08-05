// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage
import Testing

@testable import DoMoClient

@Suite("Model preference")
struct ModelPreferenceTests {
    @Test("the selected model survives a new client preference store")
    func savesAndLoadsModel() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-model-" + UUID().uuidString + ".json")
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }

        let store = ModelPreferenceStore(path: path)
        #expect(store.load() == nil)
        try store.save("openai/gpt-5")

        #expect(ModelPreferenceStore(path: path).load() == "openai/gpt-5")
        let contents = try String(contentsOfFile: path.string, encoding: .utf8)
        #expect(contents.contains("openai/gpt-5"))
    }

    @Test("an empty or malformed preference is ignored")
    func invalidPreferenceFallsBack() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-model-invalid-" + UUID().uuidString + ".json")
                .path
        )
        defer { try? FileManager.default.removeItem(atPath: path.string) }
        try Data(#"{"model":"  "}"#.utf8).write(to: URL(fileURLWithPath: path.string))
        #expect(ModelPreferenceStore(path: path).load() == nil)
    }
}
