// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Prompt history that survives the process, keyed by WORKSPACE.
//
// The editor already keeps 100 prompts in memory and walks them with the arrows;
// what it could not do is remember them across a restart, which is the half of
// "let me see what I asked before" that actually matters — the previous run is
// exactly the one you want to look back at.
//
// It is an `actor` rather than a struct with a lock because both of its operations
// happen at moments that must not stall a frame: the load runs at startup, in the
// background job the client already has, and the append runs on every submit. A
// read-modify-write of one file from two of those at once is a lost entry.

import DoMoHarness
import Foundation
import SystemPackage

/// Per-workspace prompt history on disk.
///
/// It lives beside the workspace's sessions — `<sessionDirectory>/--<cwd>--/` —
/// which is the directory layout `JSONLSessionStore` already established, and never
/// inside the project, so a repository cannot plant one. Nothing project-supplied is
/// ever written into it, only the user's own keystrokes.
///
/// The READ is still hardened. A history entry goes straight into the editor and
/// from there to the model, so a corrupt or hostile config tree is the one remaining
/// vector, and an entry carrying an escape sequence would be replayed into the
/// terminal the moment the arrow key recalled it.
public actor PromptHistoryStore {
    private let path: FilePath
    private let maxEntries: Int
    private let maxEntryBytes: Int

    init(path: FilePath, maxEntries: Int = 200, maxEntryBytes: Int = 4096) {
        self.path = path
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
    }

    /// `<sessionDirectory>/--<sanitized cwd>--/prompt-history.json`.
    public nonisolated static func defaultPath(sessionDirectory: FilePath, cwd: String) -> FilePath {
        sessionDirectory
            .appending(workspaceDirectoryName(forCwd: cwd))
            .appending("prompt-history.json")
    }

    /// The workspace directory's name.
    ///
    /// Delegated to `JSONLSessionStore` rather than re-derived: the history file has
    /// to land INSIDE the directory the sessions already use, and two copies of an
    /// encoding rule are two things to keep in step.
    nonisolated static func workspaceDirectoryName(forCwd cwd: String) -> String {
        JSONLSessionStore.sanitizedDirectoryName(forCwd: cwd)
    }

    private struct StoredFile: Codable {
        var version: Int
        var entries: [String]
    }

    private static let currentVersion = 1

    /// Every entry, OLDEST FIRST — the order ``PromptInput/seedHistory(_:)`` wants.
    ///
    /// Never throws. A missing, unreadable, corrupt or future-versioned file is
    /// simply "no history": losing it is an annoyance, and refusing to start the
    /// client over an annoyance is not a trade worth making.
    func load() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              file.version == Self.currentVersion
        else { return [] }
        return Self.sanitize(file.entries, maxEntries: maxEntries, maxEntryBytes: maxEntryBytes)
    }

    /// Append one prompt.
    ///
    /// Drops a consecutive duplicate of the newest entry — the same rule
    /// `Editor.addToHistory` applies in memory — and trims the oldest past
    /// `maxEntries`. Best effort: a write failure is silent, because a full disk
    /// must not eat a keystroke or pop an error over the transcript.
    func append(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maxEntryBytes,
              !Self.hasForbiddenControls(trimmed)
        else { return }
        var entries = load()
        if entries.last == trimmed { return }
        entries.append(trimmed)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }

        let directory = path.removingLastComponent()
        try? FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        // Stable and reviewable, the way the trust store writes: this file is one a
        // user may well open to see what it has been keeping.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(
            StoredFile(version: Self.currentVersion, entries: entries)
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
    }

    /// Drop anything that must never reach the editor or the model, then keep only
    /// the newest `maxEntries`.
    nonisolated static func sanitize(
        _ entries: [String],
        maxEntries: Int,
        maxEntryBytes: Int
    ) -> [String] {
        var kept = entries.filter {
            !$0.isEmpty && $0.utf8.count <= maxEntryBytes && !hasForbiddenControls($0)
        }
        if kept.count > maxEntries { kept.removeFirst(kept.count - maxEntries) }
        return kept
    }

    /// Whether a string carries a control character other than a newline.
    ///
    /// Newlines are the whole point now — a multi-line prompt has to come back as
    /// one. Everything else, including the C1 range a UTF-8 decoder can produce from
    /// a two-byte escape, is refused: recalling an entry writes it into a live
    /// terminal.
    nonisolated static func hasForbiddenControls(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            let value = scalar.value
            if value == 0x0a { continue }
            if value < 0x20 || value == 0x7f || (value >= 0x80 && value <= 0x9f) { return true }
        }
        return false
    }
}
