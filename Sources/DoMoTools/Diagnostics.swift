// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

// MARK: - Shared diagnostics contract

/// One compiler or language-server error that can be shown to the model.
///
/// The protocol deliberately carries locations as strings rather than making
/// callers agree on a URI type. A CLI compiler may print an absolute path, an
/// LSP may print a URI, and the tool result should preserve whichever spelling
/// the provider used.
public struct CodeDiagnostic: Sendable, Hashable {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let message: String
    public let source: String?

    public init(
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String,
        source: String? = nil
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.source = source
    }

    var locationText: String {
        guard let file else { return "error" }
        var location = file
        if let line {
            location += ":\(line)"
            if let column { location += ":\(column)" }
        }
        return location
    }

    var details: JSONValue {
        .object([
            "file": file.map(JSONValue.string) ?? .null,
            "line": line.map { .int($0) } ?? .null,
            "column": column.map { .int($0) } ?? .null,
            "message": .string(message),
            "source": source.map(JSONValue.string) ?? .null,
        ])
    }
}

/// The outcome of one diagnostics check.
public struct DiagnosticsReport: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case unsupported
        case clean
        case errors
        case unavailable
    }

    public let provider: String
    public let command: String?
    public let status: Status
    /// Errors only. Warnings and informational messages never enter a tool
    /// result, keeping the post-edit block small enough to be useful.
    public let diagnostics: [CodeDiagnostic]
    /// The number found before the provider's cap was applied.
    public let totalDiagnostics: Int
    public let truncated: Bool
    public let exitCode: Int32?
    public let note: String?

    public init(
        provider: String,
        command: String? = nil,
        status: Status,
        diagnostics: [CodeDiagnostic] = [],
        totalDiagnostics: Int? = nil,
        truncated: Bool = false,
        exitCode: Int32? = nil,
        note: String? = nil
    ) {
        self.provider = provider
        self.command = command
        self.status = status
        self.diagnostics = diagnostics
        self.totalDiagnostics = max(totalDiagnostics ?? diagnostics.count, diagnostics.count)
        self.truncated = truncated
        self.exitCode = exitCode
        self.note = note
    }

    /// The structured form stored alongside the ordinary tool details.
    public var details: JSONValue {
        .object([
            "provider": .string(provider),
            "command": command.map(JSONValue.string) ?? .null,
            "status": .string(status.rawValue),
            "errorCount": .int(totalDiagnostics),
            "truncated": .bool(truncated),
            "exitCode": exitCode.map { .int(Int($0)) } ?? .null,
            "diagnostics": .array(diagnostics.map(\.details)),
            "note": note.map(JSONValue.string) ?? .null,
        ])
    }

    /// The model-facing block. Clean and unsupported checks are intentionally
    /// silent: adding "no errors" after every edit consumes context without
    /// changing the model's next action.
    public var modelText: String? {
        switch status {
        case .unsupported, .clean:
            return nil
        case .errors:
            guard !diagnostics.isEmpty else { return nil }
            var lines = [
                "\(provider) found \(totalDiagnostics) error\(totalDiagnostics == 1 ? "" : "s").",
            ]
            lines.append(contentsOf: diagnostics.map { diagnostic in
                "\(diagnostic.locationText): \(diagnostic.message)"
            })
            if truncated {
                lines.append("[Additional diagnostics omitted.]")
            }
            return "<diagnostics>\n" + lines.joined(separator: "\n") + "\n</diagnostics>"
        case .unavailable:
            guard let note, !note.isEmpty else { return nil }
            let commandText = command.map { "\nCommand: \($0)" } ?? ""
            return "<diagnostics>\n\(provider) was unavailable: \(note)\(commandText)\n</diagnostics>"
        }
    }
}

/// The seam shared by the inexpensive CLI checker and the future LSP client.
///
/// A provider owns its project root and execution strategy. The tool layer only
/// supplies the path that just changed, so replacing this with an LSP provider
/// later does not change `write`, `edit`, or their callers.
public protocol DiagnosticsProvider: Sendable {
    @concurrent
    func check(changedPath: FilePath) async -> DiagnosticsReport
}

// MARK: - CLI provider

/// The language families understood by ``CLIDiagnosticsProvider``.
public enum CLIDiagnosticsLanguage: String, Sendable, Hashable {
    case swift
    case typescript
    case rust
}

/// Runs one project-native compiler command and turns its errors into the
/// shared diagnostics contract.
///
/// Detection is intentionally conservative. A `Package.swift`, `tsconfig.json`,
/// or `Cargo.toml` at the project root opts the provider in; an unrelated
/// directory gets an unsupported report and no subprocess. The command runs
/// with the same scrubbed environment as the other model-driven tools.
public struct CLIDiagnosticsProvider: DiagnosticsProvider {
    public let root: FilePath
    public let shell: any Shell
    public let environment: ShellEnvironment
    public let language: CLIDiagnosticsLanguage?
    public let timeout: Duration
    public let maximumErrors: Int

    public init(
        root: FilePath,
        shell: any Shell,
        environment: ShellEnvironment = .inherit,
        language: CLIDiagnosticsLanguage? = nil,
        timeout: Duration = .seconds(60),
        maximumErrors: Int = 20
    ) {
        self.root = root
        self.shell = shell
        self.environment = environment
        self.language = language
        self.timeout = timeout
        self.maximumErrors = max(1, maximumErrors)
    }

    @concurrent
    public func check(changedPath: FilePath) async -> DiagnosticsReport {
        _ = changedPath
        guard let language = language ?? Self.detect(at: root) else {
            return DiagnosticsReport(
                provider: "cli",
                status: .unsupported
            )
        }

        let command = Self.command(for: language)
        let providerName = "\(language.rawValue)-cli"
        let result: ShellResult
        do {
            result = try await shell.run(
                ShellRequest(
                    command,
                    workingDirectory: root,
                    environment: environment,
                    standardInput: .none,
                    timeout: timeout
                )
            )
        } catch let error {
            let message = error.description
            return DiagnosticsReport(
                provider: providerName,
                command: command,
                status: .unavailable,
                note: message
            )
        }

        let output = Self.combinedOutput(result)
        var diagnostics = Self.parse(output, language: language, source: providerName)
        let total = diagnostics.count
        var note: String?

        if !result.isSuccess && diagnostics.isEmpty {
            let message = Self.failureMessage(
                output: output,
                command: command,
                result: result
            )
            diagnostics = [CodeDiagnostic(message: message, source: providerName)]
        }

        if result.timedOut {
            note = "command timed out"
        }

        let visible = Array(diagnostics.prefix(maximumErrors))
        let wasTruncated = result.isTruncated || diagnostics.count > visible.count
        return DiagnosticsReport(
            provider: providerName,
            command: command,
            status: result.isSuccess ? .clean : .errors,
            diagnostics: visible,
            totalDiagnostics: max(total, diagnostics.count),
            truncated: wasTruncated,
            exitCode: result.exitCode,
            note: note
        )
    }

    /// Project detection is separate and pure enough to be pinned by tests.
    public static func detect(at root: FilePath) -> CLIDiagnosticsLanguage? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appending("Package.swift").string) {
            return .swift
        }
        if fileManager.fileExists(atPath: root.appending("tsconfig.json").string) {
            return .typescript
        }
        if fileManager.fileExists(atPath: root.appending("Cargo.toml").string) {
            return .rust
        }
        return nil
    }
}

private extension CLIDiagnosticsProvider {
    static func command(for language: CLIDiagnosticsLanguage) -> String {
        switch language {
        case .swift:
            return "swift build"
        case .typescript:
            return "tsc --noEmit --pretty false"
        case .rust:
            return "cargo check --message-format=json"
        }
    }

    static func combinedOutput(_ result: ShellResult) -> String {
        let stdout = result.stdout.text
        let stderr = result.stderr.text
        if stdout.isEmpty { return stderr }
        if stderr.isEmpty { return stdout }
        return stdout + "\n" + stderr
    }

    static func parse(
        _ output: String,
        language: CLIDiagnosticsLanguage,
        source: String
    ) -> [CodeDiagnostic] {
        var parsed: [CodeDiagnostic] = []
        var seen = Set<CodeDiagnostic>()
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let diagnostic: CodeDiagnostic?
            switch language {
            case .swift:
                diagnostic = parseSwift(line, source: source)
            case .typescript:
                diagnostic = parseTypeScript(line, source: source)
            case .rust:
                diagnostic = parseRust(line, source: source)
            }
            if let diagnostic, seen.insert(diagnostic).inserted {
                parsed.append(diagnostic)
            }
        }
        return parsed
    }

    static func parseSwift(_ line: String, source: String) -> CodeDiagnostic? {
        if let captures = captures(
            pattern: #"^(.+?):([0-9]+):([0-9]+):\s+error:\s+(.*)$"#,
            in: line
        ),
            let lineNumber = Int(captures[1]),
            let column = Int(captures[2])
        {
            return CodeDiagnostic(
                file: captures[0],
                line: lineNumber,
                column: column,
                message: captures[3],
                source: source
            )
        }
        guard let captures = captures(pattern: #"^error:\s+(.*)$"#, in: line) else { return nil }
        return CodeDiagnostic(message: captures[0], source: source)
    }

    static func parseTypeScript(_ line: String, source: String) -> CodeDiagnostic? {
        if let captures = captures(
            pattern: #"^(.+?)\(([0-9]+),([0-9]+)\):\s+error(?:\s+TS[0-9]+)?:\s+(.*)$"#,
            in: line
        ),
            let lineNumber = Int(captures[1]),
            let column = Int(captures[2])
        {
            return CodeDiagnostic(
                file: captures[0],
                line: lineNumber,
                column: column,
                message: captures[3],
                source: source
            )
        }
        if let captures = captures(
            pattern: #"^(.+?):([0-9]+):([0-9]+)\s+-\s+error(?:\s+TS[0-9]+)?:\s+(.*)$"#,
            in: line
        ),
            let lineNumber = Int(captures[1]),
            let column = Int(captures[2])
        {
            return CodeDiagnostic(
                file: captures[0],
                line: lineNumber,
                column: column,
                message: captures[3],
                source: source
            )
        }
        guard let captures = captures(pattern: #"^error\s+TS[0-9]+:\s+(.*)$"#, in: line) else {
            return nil
        }
        return CodeDiagnostic(message: captures[0], source: source)
    }

    static func parseRust(_ line: String, source: String) -> CodeDiagnostic? {
        guard let value = try? JSONValue(parsing: line),
              value["reason"]?.stringValue == "compiler-message",
              value["message"]?["level"]?.stringValue == "error",
              let message = value["message"]?["message"]?.stringValue
        else { return nil }

        var file: String?
        var lineNumber: Int?
        var column: Int?
        if let spans = value["message"]?["spans"]?.arrayValue {
            let span = spans.first { $0["is_primary"]?.boolValue == true } ?? spans.first
            file = span?["file_name"]?.stringValue
            lineNumber = span?["line_start"]?.intValue
            column = span?["column_start"]?.intValue
        }
        return CodeDiagnostic(
            file: file,
            line: lineNumber,
            column: column,
            message: message,
            source: source
        )
    }

    static func failureMessage(output: String, command: String, result: ShellResult) -> String {
        if result.timedOut {
            return "\(command) timed out before it produced a parseable compiler error."
        }
        let errorLines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.localizedCaseInsensitiveContains("error") }
        if let first = errorLines.first {
            return trimMessage(first)
        }
        if let code = result.exitCode {
            return "\(command) exited with code \(code) without a parseable compiler error."
        }
        return "\(command) failed without a parseable compiler error."
    }

    static func trimMessage(_ message: String) -> String {
        let limit = 2_000
        guard message.count > limit else { return message }
        return String(message.prefix(limit)) + "…"
    }

    static func captures(pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let capture = match.range(at: index)
            guard capture.location != NSNotFound, let swiftRange = Range(capture, in: line) else {
                return nil
            }
            return String(line[swiftRange])
        }
    }
}
