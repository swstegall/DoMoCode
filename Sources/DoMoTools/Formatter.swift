// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

/// The result of an optional formatter run.
public struct FormatterReport: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case formatted
        case unchanged
        case failed
        case unavailable
    }

    public let provider: String
    public let command: String?
    public let status: Status
    public let changedPath: String
    public let note: String?

    public init(
        provider: String,
        command: String? = nil,
        status: Status,
        changedPath: String,
        note: String? = nil
    ) {
        self.provider = provider
        self.command = command
        self.status = status
        self.changedPath = changedPath
        self.note = note
    }

    public var details: JSONValue {
        .object([
            "provider": .string(provider),
            "command": command.map(JSONValue.string) ?? .null,
            "status": .string(status.rawValue),
            "path": .string(changedPath),
            "note": note.map(JSONValue.string) ?? .null,
        ])
    }

    public var modelText: String? {
        switch status {
        case .formatted:
            return "<formatting>\n\(provider) formatted \(changedPath).\n</formatting>"
        case .unchanged:
            return nil
        case .failed, .unavailable:
            guard let note, !note.isEmpty else { return nil }
            return "<formatting>\n\(provider) could not format \(changedPath): \(note)\n</formatting>"
        }
    }
}

/// The seam for a formatter that runs after a successful file mutation.
public protocol FormatterProvider: Sendable {
    @concurrent
    func format(changedPath: FilePath) async -> FormatterReport
}

/// Runs one explicitly configured project formatter.
///
/// There is no default command. A formatter is an execution path, so callers
/// must opt in by constructing this provider from trusted configuration. When
/// it is used by the built-in file tools, it runs only after the same permission
/// decision that allowed the write or edit; it never bypasses the permission
/// engine with an independent approval path.
public struct CLIFormatter: FormatterProvider {
    public let root: FilePath
    public let shell: any Shell
    public let command: String
    public let environment: ShellEnvironment
    public let timeout: Duration

    public init(
        root: FilePath,
        shell: any Shell,
        command: String,
        environment: ShellEnvironment = .inherit,
        timeout: Duration = .seconds(30)
    ) {
        self.root = root
        self.shell = shell
        self.command = command
        self.environment = environment
        self.timeout = timeout
    }

    @concurrent
    public func format(changedPath: FilePath) async -> FormatterReport {
        let absolute = Self.absolutePath(changedPath, root: root)
        let invocation = Self.invocation(command: command, file: absolute)
        let before = try? Data(contentsOf: URL(fileURLWithPath: absolute))
        let result: ShellResult
        do {
            result = try await shell.run(
                ShellRequest(
                    invocation,
                    workingDirectory: root,
                    environment: environment,
                    standardInput: .none,
                    timeout: timeout
                )
            )
        } catch let error {
            return FormatterReport(
                provider: "cli-formatter",
                command: invocation,
                status: .unavailable,
                changedPath: changedPath.string,
                note: error.description
            )
        }

        guard result.isSuccess else {
            let output = Self.output(result)
            let status = result.timedOut
                ? "command timed out"
                : "command exited with code \(result.exitCode.map(String.init) ?? "unknown")"
            let note = output.isEmpty ? status : "\(status): \(Self.trim(output))"
            return FormatterReport(
                provider: "cli-formatter",
                command: invocation,
                status: .failed,
                changedPath: changedPath.string,
                note: note
            )
        }

        let after = try? Data(contentsOf: URL(fileURLWithPath: absolute))
        return FormatterReport(
            provider: "cli-formatter",
            command: invocation,
            status: before != after ? .formatted : .unchanged,
            changedPath: changedPath.string
        )
    }
}

private extension CLIFormatter {
    static func absolutePath(_ path: FilePath, root: FilePath) -> String {
        if path.string.hasPrefix("/") { return path.string }
        return root.appending(path.string).string
    }

    static func invocation(command: String, file: String) -> String {
        let quoted = shellQuote(file)
        if command.contains("{file}") {
            return command.replacingOccurrences(of: "{file}", with: quoted)
        }
        return "\(command) \(quoted)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func output(_ result: ShellResult) -> String {
        let stdout = result.stdout.text
        let stderr = result.stderr.text
        if stdout.isEmpty { return stderr }
        if stderr.isEmpty { return stdout }
        return stdout + "\n" + stderr
    }

    static func trim(_ text: String) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 2_000 else { return collapsed }
        return String(collapsed.prefix(2_000)) + "…"
    }
}
