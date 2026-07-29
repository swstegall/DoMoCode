// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Prompt history on disk: that it survives the process, that it stays bounded,
// that it lands in the SAME workspace directory the sessions use, and — the part
// that is security rather than convenience — that nothing it hands back can repaint
// the terminal it is recalled into.

import Foundation
import SystemPackage
import Testing

@testable import DoMoClient

@Suite("Prompt history store")
struct PromptHistoryTests {
    /// A throwaway directory, in the pattern the client's integration tests use.
    private func sandbox() -> FilePath {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-prompt-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FilePath(root.path)
    }

    private func remove(_ path: FilePath) {
        try? FileManager.default.removeItem(atPath: path.string)
    }

    @Test("History persists, stays oldest-first, and is bounded to its cap")
    func promptHistoryPersistsBoundedAndOldestFirst() async {
        let root = sandbox()
        defer { remove(root) }
        let store = PromptHistoryStore(path: root.appending("h.json"), maxEntries: 200)

        for index in 1...250 { await store.append("entry \(index)") }
        let loaded = await store.load()
        #expect(loaded.count == 200)
        #expect(loaded.last == "entry 250", "the newest entry is last")
        #expect(loaded.first == "entry 51", "the oldest 50 fell off the front")
    }

    @Test("Only CONSECUTIVE duplicates are dropped")
    func promptHistoryDedupsConsecutiveDuplicatesOnly() async {
        let root = sandbox()
        defer { remove(root) }
        let store = PromptHistoryStore(path: root.appending("h.json"))

        for entry in ["a", "a", "b", "a"] { await store.append(entry) }
        #expect(await store.load() == ["a", "b", "a"])
    }

    @Test("A hostile or oversized entry never comes back out")
    func promptHistoryRejectsControlCharactersAndOversizeEntries() async throws {
        let root = sandbox()
        defer { remove(root) }
        let path = root.appending("h.json")

        // Hand-written, because the vector is a file the client did not write: a
        // recalled entry goes straight into a live terminal.
        let entries = [
            "\u{1b}[31mred",                      // an escape sequence
            String(repeating: "x", count: 10_000),   // past the per-entry bound
            "line one\nline two",                  // legitimate, and multi-line
        ]
        let payload: [String: Any] = ["version": 1, "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: path.string))

        let store = PromptHistoryStore(path: path)
        #expect(await store.load() == ["line one\nline two"], "newlines survive; escapes do not")
    }

    @Test("A missing or corrupt file reads as no history, and never throws")
    func promptHistoryToleratesMissingAndCorruptFiles() async throws {
        let root = sandbox()
        defer { remove(root) }

        let missing = PromptHistoryStore(path: root.appending("nope.json"))
        #expect(await missing.load().isEmpty)

        let corruptPath = root.appending("bad.json")
        try Data("{{{".utf8).write(to: URL(fileURLWithPath: corruptPath.string))
        let corrupt = PromptHistoryStore(path: corruptPath)
        #expect(await corrupt.load().isEmpty)

        // A file from a future version is not read as an empty history AND not read
        // as entries this build does not understand.
        let futurePath = root.appending("future.json")
        try Data(#"{"version":99,"entries":["x"]}"#.utf8)
            .write(to: URL(fileURLWithPath: futurePath.string))
        #expect(await PromptHistoryStore(path: futurePath).load().isEmpty)
    }

    @Test("The history file lands inside the workspace's own session directory")
    func promptHistoryWorkspaceDirectoryMatchesTheSessionLayout() {
        #expect(PromptHistoryStore.workspaceDirectoryName(forCwd: "/home/u/p") == "--home-u-p--")
        #expect(
            PromptHistoryStore.defaultPath(sessionDirectory: FilePath("/s"), cwd: "/home/u/p").string
                == "/s/--home-u-p--/prompt-history.json"
        )
    }

    @Test("An append that cannot be written is silent, not fatal")
    func promptHistoryAppendIsBestEffort() async {
        // A path whose parent cannot be created. Losing history must never cost a
        // keystroke or raise an error over the transcript.
        let store = PromptHistoryStore(path: FilePath("/dev/null/nested/h.json"))
        await store.append("hello")
        #expect(await store.load().isEmpty)
    }

    @Test("A control character never reaches the store on the way in either")
    func promptHistoryRefusesToWriteControlCharacters() async {
        let root = sandbox()
        defer { remove(root) }
        let store = PromptHistoryStore(path: root.appending("h.json"))
        await store.append("clean")
        await store.append("dirty \u{1b}[2J")
        #expect(await store.load() == ["clean"])
    }
}
