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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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

    /// What is on disk right now.
    ///
    /// "Newer than I understand" is kept separate from "absent or corrupt" because
    /// the two want opposite things from the WRITE path: a corrupt file may be
    /// replaced, a file a future build wrote may not.
    private enum StoredState {
        case none
        case current([String])
        case newerVersion
    }

    private func read() -> StoredState {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data)
        else { return .none }
        if file.version > Self.currentVersion { return .newerVersion }
        guard file.version == Self.currentVersion else { return .none }
        return .current(file.entries)
    }

    /// Every entry, OLDEST FIRST — the order ``PromptInput/seedHistory(_:)`` wants.
    ///
    /// Never throws. A missing, unreadable, corrupt or future-versioned file is
    /// simply "no history": losing it is an annoyance, and refusing to start the
    /// client over an annoyance is not a trade worth making.
    func load() -> [String] {
        guard case .current(let entries) = read() else { return [] }
        return Self.sanitize(entries, maxEntries: maxEntries, maxEntryBytes: maxEntryBytes)
    }

    /// Append one prompt.
    ///
    /// Drops a consecutive duplicate of the newest entry — the same rule
    /// `Editor.addToHistory` applies in memory — and trims the oldest past
    /// `maxEntries`. Best effort: a write failure is silent, because a full disk
    /// must not eat a keystroke or pop an error over the transcript.
    ///
    /// A file a NEWER build wrote is left exactly as it is. `load()` reads it as no
    /// history, and rewriting from that empty base would truncate away every entry a
    /// user had — running an old `domo` once after a schema bump would be permanent
    /// data loss, which is a much worse trade than losing one appended prompt.
    func append(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maxEntryBytes,
              !Self.hasForbiddenControls(trimmed)
        else { return }
        let existing: [String]
        switch read() {
        case .newerVersion: return
        case .none: existing = []
        case .current(let stored):
            existing = Self.sanitize(stored, maxEntries: maxEntries, maxEntryBytes: maxEntryBytes)
        }
        var entries = existing
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
        writeOwnerOnly(data)
    }

    /// Replace the file's contents, atomically, mode 0600.
    ///
    /// NOT `Data.write(options: .atomic)`. Foundation's atomic write creates a fresh
    /// temp through `open(2)` at 0666 and renames it into place, so the file came out
    /// 0644 under the usual umask — world-readable, in the same directory where
    /// `JSONLSessionStore` deliberately threads `permissions: .ownerReadWrite` for
    /// exactly this class of content — and it was RE-created on every single append,
    /// so a user who chmodded it back lost that on the next Enter. Prompt text is
    /// where people paste tokens, internal hostnames and paths.
    ///
    /// The temp is created 0600 by `open(2)` itself rather than chmodded afterwards,
    /// so the bytes are never on disk world-readable even for an instant, and
    /// `.usingNewMetadataOnly` is what carries that mode across the replace instead
    /// of inheriting whatever the old file had.
    private func writeOwnerOnly(_ data: Data) {
        // Write THROUGH a symlink, not over it. `replaceItemAt` does not follow one
        // (while the `fileExists` probe below does), so a symlinked history file —
        // an ordinary dotfiles arrangement — took the replace branch, threw, and,
        // because this whole path is best-effort, silently stopped recording
        // forever. Resolving first also stops the plain-write fallback from
        // REPLACING the user's symlink with a regular file, which is what
        // `Data.write(options: .atomic)` did here before any of this.
        let path = resolvingSymlink(path)
        let directory = path.removingLastComponent()
        let temporary = directory.appending(".prompt-history-\(UUID().uuidString).tmp")
        guard let descriptor = try? FileDescriptor.open(
            temporary,
            .writeOnly,
            options: [.create, .truncate, .exclusiveCreate],
            permissions: .ownerReadWrite
        ) else { return }
        do {
            try descriptor.writeAll(data)
            try descriptor.close()
        } catch {
            try? descriptor.close()
            try? FileManager.default.removeItem(atPath: temporary.string)
            return
        }
        guard rename(temporary, to: path) else {
            try? FileManager.default.removeItem(atPath: temporary.string)
            // This is deliberately best-effort: a failed rename loses this append,
            // but never interrupts the interactive client or replaces a symlink with
            // a less secure fallback write.
            return
        }
    }

    /// The same atomic move used by `AtomicFileWrite`, kept best-effort here so a
    /// prompt-history save can never interrupt the interactive client.
    private func rename(_ source: FilePath, to destination: FilePath) -> Bool {
        #if canImport(Darwin)
        return unsafe Darwin.rename(source.string, destination.string) == 0
        #elseif canImport(Glibc)
        return unsafe Glibc.rename(source.string, destination.string) == 0
        #elseif canImport(Musl)
        return unsafe Musl.rename(source.string, destination.string) == 0
        #else
        return false
        #endif
    }

    /// `path` with a final symlink component followed to its target, or `path`
    /// unchanged when it is not a symlink (including when it does not exist yet).
    private func resolvingSymlink(_ path: FilePath) -> FilePath {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.string)
        guard (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink else { return path }
        let resolved = URL(fileURLWithPath: path.string).resolvingSymlinksInPath().path
        return resolved.isEmpty ? path : FilePath(resolved)
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
