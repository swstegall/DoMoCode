// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoAgent
import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import SystemPackage

/// The result of validating a trajectory and materializing its branch.
public struct ReplayReport: Sendable, Hashable, Codable {
    public let sourcePath: String
    public let branchPath: String
    public let untilEntryID: String
    public let recordedToolCalls: Int

    public init(
        sourcePath: String,
        branchPath: String,
        untilEntryID: String,
        recordedToolCalls: Int
    ) {
        self.sourcePath = sourcePath
        self.branchPath = branchPath
        self.untilEntryID = untilEntryID
        self.recordedToolCalls = recordedToolCalls
    }
}

/// Shared implementation for the `replay` subcommand and root `--replay` form.
///
/// It reads the selected branch, validates every recorded tool trajectory by
/// consuming a ``ReplayToolExecutor``, then creates a normal branched session.
/// The resulting JSONL file is therefore immediately usable by `--resume` or
/// `--session`; no model, provider, or local tool process is started here.
enum ReplaySupport {
    static func perform(
        sessionPath: String?,
        until: String?,
        configuredSessionDirectory: FilePath
    ) async throws -> ReplayReport {
        let explicitPath = sessionPath != nil
        let sourcePath = try resolveSessionPath(
            sessionPath,
            configuredSessionDirectory: configuredSessionDirectory
        )
        let store = try JSONLSessionStore.open(path: sourcePath)
        let tree = try SessionTree.load(from: store)
        let target = try targetEntryID(until, leafID: tree.leafID)
        let branch = try tree.branch(from: target)
        guard !branch.isEmpty else {
            throw DoMoError(.configuration, "The session contains no entries to replay.")
        }

        // Replay the persisted message entries as a lossless trajectory. A
        // context projection would intentionally omit pre-compaction calls,
        // which is correct for a model request but wrong for validating a
        // recorded execution stream.
        let messages = branch.compactMap { entry -> Message? in
            guard case .message(let message) = entry.payload else { return nil }
            return message
        }
        let executor = try ReplayToolExecutor(messages: messages)
        let recordedToolCalls = try await executor.replayAll().count

        // Explicit paths may come from a session directory other than the
        // current environment. Infer that directory from the standard
        // `<session-root>/<sanitized-cwd>/<file>` layout so the new branch is
        // beside its source. The latest-session form already has the configured
        // root and needs no inference.
        let branchDirectory = explicitPath
            ? sourcePath.removingLastComponent().removingLastComponent()
            : configuredSessionDirectory
        let forked = try store.createBranchedSession(
            leafID: target,
            sessionDirectory: branchDirectory
        )
        return ReplayReport(
            sourcePath: sourcePath.string,
            branchPath: forked.path.string,
            untilEntryID: target,
            recordedToolCalls: recordedToolCalls
        )
    }

    static func defaultSessionDirectory(environment: [String: String]) -> FilePath {
        if let configured = environment[EnvName.sessionDir], !configured.isEmpty {
            return FilePath(configured)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return FilePath(home).appending(".domocode").appending("sessions")
    }

    static func write(_ report: ReplayReport, asJSON: Bool) throws {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let text = """
            Replay validated \(report.recordedToolCalls) recorded tool call(s) through \(report.untilEntryID).
            Created branch: \(report.branchPath)
            Resume it with: domo --session \"\(report.branchPath)\"

            """
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func resolveSessionPath(
        _ explicit: String?,
        configuredSessionDirectory: FilePath
    ) throws -> FilePath {
        if let explicit {
            let value = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw DoMoError(.configuration, "The replay session path cannot be empty.")
            }
            return FilePath(value)
        }

        let cwd = FileManager.default.currentDirectoryPath
        guard let latest = try JSONLSessionStore.list(
            cwd: cwd,
            sessionDirectory: configuredSessionDirectory
        ).last else {
            throw DoMoError(.configuration, "No session found for \(cwd) to replay.")
        }
        return latest.path
    }

    private static func targetEntryID(_ requested: String?, leafID: String?) throws -> String {
        if let requested {
            let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw DoMoError(.configuration, "--until requires a non-empty session entry id.")
            }
            return value
        }
        guard let leafID else {
            throw DoMoError(.configuration, "The session contains no entries to replay.")
        }
        return leafID
    }
}

/// Validate a recorded trajectory and create a live branch at a selected entry.
public struct ReplayCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Validate a session trajectory and branch from an entry."
    )

    @Argument(help: "Session JSONL path; defaults to the newest session for the current directory.")
    public var sessionPath: String?

    @Option(name: .customLong("until"), help: "Branch at this entry id; defaults to the session leaf.")
    public var until: String?

    @Flag(name: .customLong("json"), help: "Emit the branch report as JSON.")
    public var json = false

    public init() {}

    public func run() async throws {
        let report = try await ReplaySupport.perform(
            sessionPath: sessionPath,
            until: until,
            configuredSessionDirectory: ReplaySupport.defaultSessionDirectory(
                environment: ProcessInfo.processInfo.environment
            )
        )
        try ReplaySupport.write(report, asJSON: json)
    }
}
