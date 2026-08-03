// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import DoMoCore
import DoMoHarness
import Foundation
import SystemPackage

/// Export one session branch without starting a model or loading project tools.
///
/// The explicit file argument is the safest form for scripts. With no argument,
/// the newest session for the current directory is selected from the configured
/// session directory environment (or the standard `~/.domocode/sessions` path).
public struct ExportCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a session transcript as Markdown or HTML."
    )

    @Argument(help: "Session JSONL path; defaults to the newest session for the current directory.")
    public var sessionPath: String?

    @Option(name: .customLong("output"), help: "Write to this file instead of stdout.")
    public var outputPath: String?

    @Option(name: .customLong("until"), help: "Export the branch ending at this entry id.")
    public var until: String?

    @Flag(name: .customLong("html"), help: "Export a standalone HTML document.")
    public var html = false

    @Flag(name: .customLong("no-reasoning"), help: "Omit assistant reasoning blocks.")
    public var noReasoning = false

    @Flag(name: .customLong("no-tools"), help: "Omit tool calls and tool results.")
    public var noTools = false

    @Flag(name: .customLong("metadata"), help: "Include session and tree metadata.")
    public var metadata = false

    public init() {}

    public func run() async throws {
        let path = try Self.resolveSessionPath(sessionPath)
        let store = try JSONLSessionStore.open(path: path)
        let header = try store.readHeader()
        let tree = try SessionTree.load(from: store)
        let entries = try tree.branch(from: until)
        guard !entries.isEmpty else {
            throw DoMoError(.configuration, "The session contains no entries to export.")
        }

        let options = TranscriptFormatOptions(
            includeReasoning: !noReasoning,
            includeToolCalls: !noTools,
            includeToolResults: !noTools,
            includeMetadata: metadata
        )
        guard !html else {
            throw DoMoError(.configuration, "HTML export is added after the Markdown export slice.")
        }
        let text = TranscriptFormatter.markdown(header: header, entries: entries, options: options)
        try Self.write(text, to: outputPath)
    }

    private static func resolveSessionPath(_ explicit: String?) throws -> FilePath {
        if let explicit {
            let value = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw DoMoError(.configuration, "The export session path cannot be empty.")
            }
            return FilePath(value)
        }

        let environment = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let sessionDirectory: FilePath
        if let configured = environment[EnvName.sessionDir], !configured.isEmpty {
            sessionDirectory = FilePath(configured)
        } else {
            let home = environment["HOME"] ?? NSHomeDirectory()
            sessionDirectory = FilePath(home).appending(".domocode").appending("sessions")
        }
        guard let latest = try JSONLSessionStore.list(cwd: cwd, sessionDirectory: sessionDirectory).last else {
            throw DoMoError(.configuration, "No session found for \(cwd). Pass a session JSONL path to export.")
        }
        return latest.path
    }

    private static func write(_ text: String, to path: String?) throws {
        guard let path else {
            FileHandle.standardOutput.write(Data(text.utf8))
            return
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
