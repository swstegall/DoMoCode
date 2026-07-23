// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/trust-manager.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import Foundation
import SystemPackage

// MARK: - Trust-requiring project resources

/// Whether `directory` carries project-local resources that must be gated behind
/// project trust before a run may act on them.
///
/// This is pi's `hasTrustRequiringProjectResources`, narrowed to the one project
/// resource DoMoCode actually loads today: `<cwd>/.domocode/settings.json`. That
/// file can silently change the model, the proxy base URL, the API-key env name,
/// and the session directory — i.e. it can redirect where the agent talks and
/// where it writes — so a repository must not get to supply it without the user
/// having said "I trust this directory".
///
/// A bare `.domocode` directory (or one holding only a `sessions/` cache) does
/// *not* count, matching pi: trust guards *input* the project would inject, not
/// the mere presence of the config folder. As DoMoCode grows project-local skills
/// or prompt files, add their names here — the check is the single gate every
/// such resource passes through.
public func projectRequiresTrust(directory: FilePath) -> Bool {
    let projectSettings = directory.appending(".domocode").appending("settings.json")
    return FileManager.default.fileExists(atPath: projectSettings.string)
}

// MARK: - Trust store

/// A record of which project directories the user has decided to trust (or
/// explicitly distrust), keyed by resolved absolute path.
///
/// Ported from pi's `ProjectTrustStore`: a single JSON object at
/// `<configDir>/trust.json` mapping a canonical directory path to a boolean
/// decision, with the *nearest* saved decision on the current-or-ancestor path
/// winning. Trusting `/work` therefore trusts `/work/repo` unless `/work/repo`
/// carries its own decision.
///
/// It stores **only** a path and a yes/no bit — never a secret, never anything
/// about what runs. It is the input-loading guard pi's security model describes,
/// not a sandbox: a trusted directory may still do anything the user's account
/// can, which is why the decision is the user's to make explicitly.
///
/// The read is *strict* on purpose (contrast the tolerant session-entry read): a
/// trust file that will not parse is a security-relevant surprise, and silently
/// treating a corrupt store as "empty" would downgrade every saved decision to
/// "no record" — turning a recorded *distrust* into a fresh prompt. Failing loud
/// is the safe direction for a trust boundary.
public struct TrustStore: Sendable {
    /// The `trust.json` this store reads and writes.
    public let path: FilePath

    public init(configDirectory: FilePath) {
        self.path = configDirectory.appending("trust.json")
    }

    /// The nearest saved decision for `directory` or any ancestor, or `nil` when
    /// no decision has been recorded on the path at all.
    ///
    /// `nil` is distinct from `false`: `nil` means "never asked" (a caller may
    /// prompt, or in non-interactive mode refuse-with-instructions), while
    /// `false` means "explicitly distrusted" and a caller should honor it.
    public func decision(for directory: FilePath) throws(DoMoError) -> Bool? {
        let table = try load()
        var current = Self.canonical(directory)
        while true {
            if let decision = table[current] { return decision }
            let parent = Self.parent(of: current)
            if parent == current { return nil }
            current = parent
        }
    }

    /// Records `trusted` for `directory` (canonicalized), creating `trust.json`
    /// and its parent directory if needed. A prior decision for the exact path is
    /// overwritten; ancestor decisions are left untouched.
    public func setDecision(_ trusted: Bool, for directory: FilePath) throws(DoMoError) {
        var table = try load()
        table[Self.canonical(directory)] = trusted
        try save(table)
    }

    // MARK: - File I/O

    private func load() throws(DoMoError) -> [String: Bool] {
        let url = URL(fileURLWithPath: path.string)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Absent is the common case: no decision has ever been saved.
            return [:]
        }
        do {
            // A trust file is a flat object of path → bool. `null` (pi's "cleared"
            // sentinel) decodes as an absent key here, which is the same as no
            // decision — DoMoCode never writes `null`, but tolerating it keeps a
            // pi-written store readable.
            return try JSONDecoder().decode([String: Bool].self, from: data)
        } catch {
            throw DoMoError(
                .configuration,
                "Could not parse trust store \(path.string). Fix or remove it to re-establish project trust.",
                cause: error
            )
        }
    }

    private func save(_ table: [String: Bool]) throws(DoMoError) {
        let directory = Self.parent(of: path.string)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw DoMoError(.file(path: FilePath(directory), errno: nil), "Could not create config directory", cause: error)
        }

        let encoder = JSONEncoder()
        // Sorted keys so the file is stable across writes and reviewable in a
        // diff — the same reason the session wire sorts its keys.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(table)
            try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
        } catch {
            throw DoMoError(.file(path: path, errno: nil), "Could not write trust store", cause: error)
        }
    }

    // MARK: - Path normalization

    /// The canonical key for a directory: an absolute path with symlinks and
    /// `.`/`..` resolved, so two spellings of the same directory (a symlinked
    /// `/tmp` vs `/private/tmp`, a relative vs absolute cwd) collapse to one key
    /// and cannot each carry a divergent decision.
    static func canonical(_ directory: FilePath) -> String {
        let resolved = URL(fileURLWithPath: directory.string).resolvingSymlinksInPath().path
        return resolved.isEmpty ? "/" : resolved
    }

    /// The parent directory path, or the input itself at a filesystem root — the
    /// termination signal for the ancestor walk.
    private static func parent(of pathString: String) -> String {
        let url = URL(fileURLWithPath: pathString)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
