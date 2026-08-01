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

@Suite("Prompt history store", .serialized)
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

    @Test("The history file is owner-only, and stays owner-only across appends")
    func promptHistoryFileIsOwnerReadWriteOnly() async throws {
        // The session transcript in the SAME directory is 0600 because it holds
        // exactly this class of content; prompt text is where people paste tokens,
        // internal hostnames and paths. `Data.write(options: .atomic)` renames a
        // fresh 0644 temp over the file on every append, so the mode was re-created
        // world-readable on every Enter and a chmod by hand did not survive one.
        let root = sandbox()
        defer { remove(root) }
        let path = root.appending("h.json")
        let store = PromptHistoryStore(path: path)

        await store.append("first")
        let created = try FileManager.default.attributesOfItem(atPath: path.string)
        #expect(created[.posixPermissions] as? Int == 0o600, "a freshly created file is owner-only")

        // Umask-independent half: a file that IS group/world readable must come back
        // owner-only after the next append, not inherit what was there.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.string)
        await store.append("second")
        let rewritten = try FileManager.default.attributesOfItem(atPath: path.string)
        #expect(rewritten[.posixPermissions] as? Int == 0o600, "an append re-tightens the mode")
        #expect(await store.load() == ["first", "second"], "and the contents survived")

        // No temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.string)
        #expect(leftovers == ["h.json"], "leftovers: \(leftovers)")
    }

    @Test("A file a newer build wrote is left alone, not truncated")
    func promptHistoryDoesNotDestroyAFutureVersionedFile() async throws {
        // `load()` reads a future version as no history, and rewriting from that
        // empty base wiped every entry the user had: running an older `domo` once
        // after a schema bump was permanent data loss.
        let root = sandbox()
        defer { remove(root) }
        let path = root.appending("h.json")
        let original = #"{"version":2,"entries":["precious one","precious two"]}"#
        try Data(original.utf8).write(to: URL(fileURLWithPath: path.string))

        let store = PromptHistoryStore(path: path)
        await store.append("new entry")
        let onDisk = try String(contentsOfFile: path.string, encoding: .utf8)
        #expect(onDisk == original, "the newer file is untouched")
        #expect(await store.load().isEmpty, "and still reads as no history")
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

    @Test("A symlinked history file still records, and still ends up owner-only")
    func promptHistoryFollowsASymlinkedDestination() async throws {
        // The ordinary dotfiles arrangement. `FileManager.replaceItemAt` does NOT
        // follow a symlink even though the `fileExists` probe guarding it does, so
        // this destination took the replace branch, threw, and — because the whole
        // write path is best-effort — silently stopped recording anything, forever.
        let root = sandbox()
        defer { remove(root) }
        let real = root.appending("real.json")
        let link = root.appending("link.json")
        try Data(#"{"version":1,"entries":["old"]}"#.utf8)
            .write(to: URL(fileURLWithPath: real.string))
        try FileManager.default.createSymbolicLink(
            atPath: link.string,
            withDestinationPath: real.string
        )

        let store = PromptHistoryStore(path: link)
        await store.append("new")

        #expect(await store.load() == ["old", "new"], "the append was swallowed")
        let type = try FileManager.default.attributesOfItem(atPath: link.string)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the symlink itself was replaced by a regular file")
        let mode = try FileManager.default.attributesOfItem(atPath: real.string)[.posixPermissions] as? Int
        #expect(mode == 0o600, "the fallback left the file readable by other users")
    }
}
