// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoGit
import DoMoHarness
import Foundation
import SystemPackage

/// Prints the current working-tree diff without starting an agent session.
///
/// With --session, the recorded session-start HEAD becomes the default base.
/// With --base, callers can review any explicit revision. Both paths use the
/// same DoMoGit facade and therefore the same quoting and non-interactive policy
/// as the full-screen review route.
public struct DiffCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show working-tree changes from HEAD or a session checkpoint."
    )

    @Option(name: .customLong("base"), help: "Git revision to compare against.")
    public var base: String?

    @Option(name: .customLong("session"), help: "Session JSONL path whose start HEAD should be used.")
    public var session: String?

    @Flag(name: .customLong("json"), help: "Emit the parsed diff as JSON.")
    public var json = false

    @Flag(name: .customLong("no-untracked"), help: "Exclude untracked files from the diff.")
    public var noUntracked = false

    public init() {}

    public func run() async throws {
        let cwd = FilePath(FileManager.default.currentDirectoryPath)
        let git = try DoMoGit()
        let sessionBase = try session.map { try Self.sessionStartHead(at: FilePath($0)) }
        let selectedBase = base ?? sessionBase.flatMap { $0 }
        let diff: GitDiff
        if let selectedBase {
            diff = try await git.diff(
                from: selectedBase,
                at: cwd,
                includeUntracked: !noUntracked
            )
        } else {
            diff = try await git.workingTreeDiff(at: cwd, includeUntracked: !noUntracked)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(diff)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        if diff.patch.isEmpty {
            FileHandle.standardOutput.write(Data("No changes.\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data(diff.patch.utf8))
            if !diff.patch.hasSuffix("\n") {
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    private static func sessionStartHead(at path: FilePath) throws -> String? {
        let store = try JSONLSessionStore.open(path: path)
        let tree = try SessionTree.load(from: store)
        return try tree.branch()
            .reversed()
            .compactMap { entry -> String? in
                if case .sessionStart(let head) = entry.payload { return head }
                return nil
            }
            .first
    }
}
