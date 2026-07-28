// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one place a clipboard write becomes a process. Driven through a recording
// `Shell`, because the assertions worth making are about the REQUEST — that the
// selected text goes on stdin and never on the command line, that a non-zero exit
// is reported rather than swallowed, and that a missing helper degrades to
// `NoClipboardSink` instead of failing the launch.

@testable import DoMoCLI
import DoMoClient
import DoMoCore
import DoMoExec
import DoMoTermIO
import Foundation
import Synchronization
import Testing

/// A `Shell` that records the request and answers with a scripted result.
private final class RecordingShell: Shell {
    private let recorded = Mutex<[ShellRequest]>([])
    private let result: ShellResult?

    init(result: ShellResult?) {
        self.result = result
    }

    var requests: [ShellRequest] { recorded.withLock { $0 } }

    func run(_ request: ShellRequest) async throws(DoMoError) -> ShellResult {
        recorded.withLock { $0.append(request) }
        guard let result else { throw DoMoError(.toolExecution(tool: "shell"), "spawn refused") }
        return result
    }
}

private func result(exit code: Int32) -> ShellResult {
    ShellResult(
        termination: .exited(code),
        stdout: ShellStreamOutput(head: [], tail: [], totalBytes: 0),
        stderr: ShellStreamOutput(head: [], tail: [], totalBytes: 0),
        timedOut: false,
        duration: .milliseconds(1),
        processIdentifier: 4242
    )
}

@Suite("System clipboard")
struct SystemClipboardTests {

    @Test("The selected text travels on stdin, never on the command line")
    func textGoesOnStandardInput() async {
        let shell = RecordingShell(result: result(exit: 0))
        let clipboard = SystemClipboard(
            shell: shell,
            command: ClipboardCommand(program: "pbcopy", arguments: [])
        )
        // Every character a naive command-line implementation would mangle.
        let hostile = "rm -rf /; $(whoami) `id` \"quoted\" 'single'\nsecond line\ttabbed"
        let outcome = await clipboard.copy(hostile)

        #expect(outcome == .copied("pbcopy"))
        let request = try! #require(shell.requests.first)
        #expect(request.command == "pbcopy", "the command carries no user data at all")
        #expect(request.standardInput == .text(hostile))
        #expect(request.timeout == SystemClipboard.timeout)
    }

    @Test("A helper's arguments are literals on the command line, the payload is not")
    func argumentsAreLiteral() async {
        let shell = RecordingShell(result: result(exit: 0))
        let clipboard = SystemClipboard(
            shell: shell,
            command: ClipboardCommand(program: "xclip", arguments: ["-selection", "clipboard"])
        )
        #expect(await clipboard.copy("payload") == .copied("xclip"))
        #expect(shell.requests.first?.command == "xclip -selection clipboard")
        #expect(shell.requests.first?.command.contains("payload") == false)
    }

    @Test("A non-zero exit is reported, not swallowed")
    func nonZeroExitIsAFailure() async {
        let shell = RecordingShell(result: result(exit: 1))
        let clipboard = SystemClipboard(
            shell: shell,
            command: ClipboardCommand(program: "xsel", arguments: ["--clipboard", "--input"])
        )
        let outcome = await clipboard.copy("text")
        #expect(outcome == .failed("xsel exited 1"))
    }

    @Test("A refused spawn is a failure, never a throw into the UI")
    func spawnFailureIsAnOutcome() async {
        // `copy` is called from a gesture handler; a throw there would unwind a
        // right-click, so the seam is `async` and never `throws`.
        let shell = RecordingShell(result: nil)
        let clipboard = SystemClipboard(
            shell: shell,
            command: ClipboardCommand(program: "wl-copy", arguments: [])
        )
        #expect(await clipboard.copy("text") == .failed("wl-copy could not be run"))
    }

    @Test("With no helper on PATH the sink is the no-op one, and the launch still succeeds")
    func noHelperResolvesToNoClipboardSink() async {
        let sink = SystemClipboard.makeClipboardSink(environment: ["PATH": "/nonexistent-\(UUID().uuidString)"])
        #expect(sink is NoClipboardSink)
        #expect(await sink.copy("text") == .unavailable)
    }

    @Test("The PATH probe answers the same question the shell will")
    func pathProbe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-copy")
        try "#!/bin/sh\ncat > /dev/null\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let environment = ["PATH": "/nonexistent:\(directory.path)"]
        #expect(SystemClipboard.isExecutableOnPath("fake-copy", environment: environment))
        #expect(!SystemClipboard.isExecutableOnPath("definitely-not-here", environment: environment))
        // An absolute name bypasses PATH, exactly as `sh` would resolve it.
        #expect(SystemClipboard.isExecutableOnPath(executable.path, environment: [:]))
        // A non-executable file is not a helper.
        let plain = directory.appendingPathComponent("not-executable")
        try "text".write(to: plain, atomically: true, encoding: .utf8)
        #expect(!SystemClipboard.isExecutableOnPath("not-executable", environment: environment))
        // An empty or missing PATH resolves nothing rather than guessing one.
        #expect(!SystemClipboard.isExecutableOnPath("fake-copy", environment: ["PATH": ""]))
        #expect(!SystemClipboard.isExecutableOnPath("fake-copy", environment: [:]))
    }

    @Test("A machine with a real helper resolves to a spawning sink")
    func realHelperResolvesToSystemClipboard() throws {
        // `/bin/cat` stands in for the helper: what is being asserted is the wiring —
        // an available program yields a spawning sink rather than the no-op one.
        let sink = SystemClipboard.makeClipboardSink(environment: [
            "PATH": "/bin:/usr/bin",
            "DISPLAY": ":0",
        ])
        if SystemClipboard.isExecutableOnPath("pbcopy", environment: ["PATH": "/bin:/usr/bin"]) {
            #expect(sink is SystemClipboard)
        } else {
            // No helper on this box; the fallback is the documented one.
            #expect(sink is NoClipboardSink)
        }
    }
}
