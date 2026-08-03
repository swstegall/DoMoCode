import DoMoCore
import DoMoExec
import DoMoTools
import Foundation
import SystemPackage
import Testing

private struct DiagnosticsShell: Shell {
    let result: ShellResult

    @concurrent
    func run(_ request: ShellRequest) async throws(DoMoError) -> ShellResult {
        _ = request
        return result
    }
}

private struct FixedDiagnosticsProvider: DiagnosticsProvider {
    let report: DiagnosticsReport

    @concurrent
    func check(changedPath: FilePath) async -> DiagnosticsReport {
        _ = changedPath
        return report
    }
}

private struct FixedFormatterProvider: FormatterProvider {
    let report: FormatterReport

    @concurrent
    func format(changedPath: FilePath) async -> FormatterReport {
        _ = changedPath
        return report
    }
}

private func diagnosticsResult(
    stdout: String = "",
    stderr: String = "",
    exitCode: Int32 = 0,
    timedOut: Bool = false
) -> ShellResult {
    ShellResult(
        termination: .exited(exitCode),
        stdout: ShellStreamOutput(
            head: Array(stdout.utf8),
            tail: [],
            totalBytes: stdout.utf8.count
        ),
        stderr: ShellStreamOutput(
            head: Array(stderr.utf8),
            tail: [],
            totalBytes: stderr.utf8.count
        ),
        timedOut: timedOut,
        duration: .milliseconds(1),
        processIdentifier: 1
    )
}

@Suite("CLI diagnostics provider")
struct CLIDiagnosticsProviderTests {

    @Test("Swift errors keep their location and warnings are omitted")
    func swiftErrors() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let output = """
            \(fixture.path("Sources/App.swift")):4:8: error: cannot find 'Thing' in scope
            \(fixture.path("Sources/App.swift")):6:1: warning: this is only a warning
            error: emit-module command failed due to signal 9
            """
        let provider = CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(result: diagnosticsResult(stdout: output, exitCode: 1)),
            language: .swift
        )

        let report = await provider.check(changedPath: FilePath("Sources/App.swift"))

        #expect(report.status == .errors)
        #expect(report.diagnostics.count == 2)
        #expect(report.diagnostics[0].file == fixture.path("Sources/App.swift"))
        #expect(report.diagnostics[0].line == 4)
        #expect(report.diagnostics[0].column == 8)
        #expect(report.diagnostics[0].message == "cannot find 'Thing' in scope")
        #expect(report.modelText?.contains("<diagnostics>") == true)
        #expect(report.modelText?.contains("warning") == false)
    }

    @Test("TypeScript diagnostics accept the tsc parenthesized form")
    func typeScriptErrors() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let provider = CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(
                result: diagnosticsResult(
                    stdout: "\(fixture.path("src/main.ts"))(3,12): error TS2304: Cannot find name 'missing'.",
                    exitCode: 2
                )
            ),
            language: .typescript
        )

        let report = await provider.check(changedPath: FilePath("src/main.ts"))

        #expect(report.diagnostics == [
            CodeDiagnostic(
                file: fixture.path("src/main.ts"),
                line: 3,
                column: 12,
                message: "Cannot find name 'missing'.",
                source: "typescript-cli"
            ),
        ])
    }

    @Test("Rust JSON compiler messages use their primary span")
    func rustErrors() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let json = """
            {"reason":"compiler-message","message":{"message":"mismatched types","level":"error","spans":[{"file_name":"src/main.rs","line_start":9,"column_start":5,"is_primary":true}]}}
            """
        let provider = CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(result: diagnosticsResult(stdout: json, exitCode: 101)),
            language: .rust
        )

        let report = await provider.check(changedPath: FilePath("src/main.rs"))

        #expect(report.diagnostics.first?.file == "src/main.rs")
        #expect(report.diagnostics.first?.line == 9)
        #expect(report.diagnostics.first?.column == 5)
        #expect(report.diagnostics.first?.message == "mismatched types")
    }

    @Test("Errors are capped and the report says that more were found")
    func cap() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let output = (1...3)
            .map { "\(fixture.path("Sources/App.swift")):\($0):1: error: failure \($0)" }
            .joined(separator: "\n")
        let provider = CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(result: diagnosticsResult(stderr: output, exitCode: 1)),
            language: .swift,
            maximumErrors: 2
        )

        let report = await provider.check(changedPath: FilePath("Sources/App.swift"))

        #expect(report.diagnostics.count == 2)
        #expect(report.totalDiagnostics == 3)
        #expect(report.truncated)
        #expect(report.modelText?.contains("Additional diagnostics omitted") == true)
    }

    @Test("Successful and unsupported projects do not add model text")
    func silentOutcomes() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let clean = CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(result: diagnosticsResult()),
            language: .swift
        )
        let cleanReport = await clean.check(changedPath: FilePath("main.swift"))
        #expect(cleanReport.status == .clean)
        #expect(cleanReport.modelText == nil)

        let detected = CLIDiagnosticsProvider.detect(at: fixture.root)
        #expect(detected == nil)
        let unsupported = await CLIDiagnosticsProvider(
            root: fixture.root,
            shell: DiagnosticsShell(result: diagnosticsResult(exitCode: 1)),
        ).check(changedPath: FilePath("main.swift"))
        #expect(unsupported.status == .unsupported)
        #expect(unsupported.modelText == nil)
    }

    @Test("write appends a diagnostics block without losing its ordinary details")
    func writeIntegration() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let report = DiagnosticsReport(
            provider: "swift-cli",
            command: "swift build",
            status: .errors,
            diagnostics: [
                CodeDiagnostic(
                    file: "Sources/App.swift",
                    line: 4,
                    column: 8,
                    message: "cannot find Thing",
                    source: "swift-cli"
                ),
            ],
            exitCode: 1
        )
        let context = try await ToolContext.rooted(
            at: fixture.root,
            shell: fixture.context.shell,
            diagnosticsProvider: FixedDiagnosticsProvider(report: report)
        )

        let result = try await WriteTool().execute(
            ["path": "Sources/App.swift", "content": "let value = Thing()"],
            in: context
        )

        #expect(!result.isError)
        #expect(result.text.contains("Successfully wrote"))
        #expect(result.text.contains("<diagnostics>"))
        #expect(result.text.contains("Sources/App.swift:4:8: cannot find Thing"))
        #expect(result.details["diagnostics"]?["provider"]?.stringValue == "swift-cli")
    }
}

@Suite("CLI formatter")
struct CLIFormatterTests {

    @Test("runs the trusted command with a shell-quoted file path")
    func formatsChangedFile() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("main.swift", "let value = 1\n")
        let script = try fixture.write(
            "format.sh",
            "#!/bin/sh\nprintf 'formatted\\n' > \"$1\"\n"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script
        )

        let formatter = CLIFormatter(
            root: fixture.root,
            shell: fixture.context.shell,
            command: "\(script) {file}",
            timeout: .seconds(2)
        )
        let report = await formatter.format(changedPath: FilePath("main.swift"))

        #expect(report.status == .formatted)
        #expect(try String(contentsOfFile: fixture.path("main.swift"), encoding: .utf8) == "formatted\n")
        #expect(report.modelText?.contains("formatted") == true)
    }

    @Test("formatting and diagnostics share the mutation result")
    func mutationIntegrationKeepsBothReports() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let context = try await ToolContext.rooted(
            at: fixture.root,
            shell: fixture.context.shell,
            diagnosticsProvider: FixedDiagnosticsProvider(
                report: DiagnosticsReport(
                    provider: "swift-cli",
                    status: .clean
                )
            ),
            formatterProvider: FixedFormatterProvider(
                report: FormatterReport(
                    provider: "swift-format",
                    status: .formatted,
                    changedPath: "main.swift"
                )
            )
        )

        let result = try await WriteTool().execute(
            ["path": "main.swift", "content": "let value = 1\n"],
            in: context
        )

        #expect(result.text.contains("<formatting>"))
        #expect(result.details["formatting"]?["provider"]?.stringValue == "swift-format")
        #expect(result.details["diagnostics"]?["provider"]?.stringValue == "swift-cli")
    }
}
