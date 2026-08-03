// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The DEFAULT interactive surface — the full-screen client — driven on a REAL
// pseudo-terminal.
//
// Two things live here because nothing else can see them. The mouse-enable
// sequence is written only when `isatty(STDOUT_FILENO)` holds, so a pipe-driven
// test cannot see the difference `--no-mouse` makes: under a pipe NEITHER run
// emits it, and an assertion of absence passes whatever the flag is wired to.
// And the full-screen client refuses to start without a terminal at all, so the
// one path the user actually complained about — a run cut off at twenty turns in
// the default UI — is unreachable from every other kind of test.
//
// This project has shipped terminal defects twice that only a live tty exposed.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

/// A pseudo-terminal pair: the test holds the master, the child gets the slave.
private final class PseudoTerminal {
    let master: Int32
    let slavePath: String

    init() throws {
        guard let opened = openPTYMaster() else {
            throw MockGatewayError("pty setup failed: \(errno)")
        }
        let fd = opened.master
        master = fd
        slavePath = opened.slaveName
        // Non-blocking, so draining never parks the test on a child that has
        // simply stopped painting.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    /// Everything the child has written so far, appended to `sink`.
    func drain(into sink: inout [UInt8]) {
        var scratch = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = scratch.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sink.append(contentsOf: scratch[0..<count])
        }
    }

    /// Type bytes at the child, exactly as a terminal would.
    func type(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            guard sent > 0 else { return }
            offset += sent
        }
    }

    func closeMaster() {
        closeDescriptor(master)
    }
}

/// `close(2)`, named apart from `FileHandle.close()` so the global is reachable
/// from a class that also has a `close`-shaped method in scope.
private func closeDescriptor(_ fd: Int32) {
    _ = close(fd)
}

@Suite(.serialized)
struct FullScreenClientPTYTests {

    /// Alt-screen entry: the client has started painting, so whatever it was
    /// going to say about the mouse it has already said (the lifecycle writes
    /// `?1049h` first and the mouse enable last, in one `enter()`).
    static let alternateScreen = "\u{1b}[?1049h"
    /// Button-event mouse tracking — the sequence `--no-mouse` exists to suppress.
    static let mouseTracking = "\u{1b}[?1002h"
    /// Every isolated end-to-end workspace is rooted at a `work` directory. The
    /// session row is rendered only after bootstrap has selected that session, so
    /// it is the stable readiness signal between the first frame and prompt input.
    static let openedSessionRow = "work  "

    /// Launch the full-screen client on a pty and return everything it wrote
    /// before it was stopped.
    static func captureClientOutput(extraArguments: [String]) throws -> String {
        let gateway = try MockGateway(chatCompletionBodies: [])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        guard let slave = FileHandle(forUpdatingAtPath: pty.slavePath) else {
            throw MockGatewayError("could not open pty slave \(pty.slavePath)")
        }
        defer { try? slave.close() }

        let process = Process()
        process.executableURL = domoBinaryURL()
        process.arguments = ["--model", "mock-model", "--base-url", gateway.baseURL] + extraArguments
        process.currentDirectoryURL = workspace.workDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
        environment["HOME"] = workspace.homeDirectory.path
        environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
        environment["DOMOCODE_LOG_LEVEL"] = "error"
        // A freshly opened pty reports a 0×0 window; the size resolver falls back
        // to these, which is what gives the renderer a grid to paint.
        environment["COLUMNS"] = "100"
        environment["LINES"] = "30"
        for key in [
            "OPENAI_API_KEY", "LITELLM_API_KEY", "DOMOCODE_MODEL", "DOMOCODE_BASE_URL",
            // Live since the stream idle bound was wired.
            "DOMOCODE_STREAM_TIMEOUT_MS",
            // CI enables this for the test runner, but the macOS release
            // runtime rejects the inherited crash-backtrace hook in this
            // spawned PTY client and aborts before it can accept input.
            "SWIFT_BACKTRACE",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        process.standardInput = slave
        process.standardOutput = slave
        // stderr on its own pipe, so a log line cannot be mistaken for a control
        // sequence the UI wrote.
        process.standardError = Pipe()

        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        var captured: [UInt8] = []
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            pty.drain(into: &captured)
            if String(decoding: captured, as: UTF8.self).contains(Self.alternateScreen) { break }
            usleep(50_000)
        }
        // One last drain: `enter()` writes the whole sequence in one go, but the
        // read that saw `?1049h` may have stopped at a buffer boundary.
        usleep(300_000)
        pty.drain(into: &captured)
        return String(decoding: captured, as: UTF8.self)
    }

    /// The control: with no flag, the client takes the mouse. If this ever stops
    /// holding, the paired assertion below proves nothing.
    @Test
    func theClientTakesTheMouseByDefault() throws {
        let output = try Self.captureClientOutput(extraArguments: [])
        #expect(output.contains(Self.alternateScreen), "the client never entered the alternate screen")
        #expect(output.contains(Self.mouseTracking), "the default client did not enable mouse tracking")
    }

    /// `--no-mouse` reaches the terminal lifecycle: the client paints, and never
    /// claims the mouse, so the terminal's own selection and scrollback survive.
    @Test
    func noMouseFlagLeavesTheMouseToTheTerminal() throws {
        let output = try Self.captureClientOutput(extraArguments: ["--no-mouse"])
        #expect(output.contains(Self.alternateScreen), "the client never entered the alternate screen")
        #expect(!output.contains(Self.mouseTracking), "--no-mouse still enabled mouse tracking")
    }

    // MARK: The DEFAULT interactive surface has no turn limit

    /// The user's complaint was about the FULL-SCREEN client, which is what `domo`
    /// with no flags runs — and that path reaches the turn bound through a
    /// different chain than `-p` does (`runClient` → `buildServerRuntime` →
    /// `ServerRuntime.Config`). A print-mode test cannot cover it, and the client
    /// needs a real terminal to start at all, so it is driven here on a pty.
    ///
    /// Twenty-five turns of varied tool work: with the old default this stopped
    /// dead at twenty, mid-task, with nothing but `idle (max_turns_reached)` in a
    /// status line.
    @Test
    func fullScreenClientRunsPastTwentyTurns() throws {
        let turns = 25
        let gateway = try MockGateway(
            chatCompletionBodies: TurnLimitEndToEndTests.variedScript(turns: turns, finalText: "all done.")
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try TurnLimitEndToEndTests.workspaceWithDirectories(turns)
        defer { workspace.cleanUp() }

        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        guard let slave = FileHandle(forUpdatingAtPath: pty.slavePath) else {
            throw MockGatewayError("could not open pty slave \(pty.slavePath)")
        }
        defer { try? slave.close() }

        let process = try Self.launchClient(
            arguments: ["--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            slave: slave
        )
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        var captured: [UInt8] = []
        // Wait for the UI to exist before typing at it.
        let ready = Self.poll(timeout: .seconds(20)) {
            pty.drain(into: &captured)
            let output = String(decoding: captured, as: UTF8.self)
            return output.contains(Self.alternateScreen) && output.contains(Self.openedSessionRow)
        }
        #expect(ready, "the full-screen client never opened its session")

        // The pty buffers the line until the client is ready to read it, so write
        // the prompt and submit exactly once. Re-sending Enter while the first
        // request is still in flight can queue a second copy of the prompt on a
        // slower runner, making this test count input timing instead of turns.
        pty.type("walk every directory\r")
        let accepted = Self.poll(timeout: .seconds(20)) {
            pty.drain(into: &captured)
            return gateway.requestCount > 0
        }
        #expect(accepted, "the prompt was never accepted")

        // 25 tool turns plus the final text turn. The old default stopped at 20.
        let finished = Self.poll(timeout: .seconds(60)) {
            pty.drain(into: &captured)
            return gateway.requestCount >= turns + 1
        }
        #expect(finished, "the run stopped after \(gateway.requestCount) turns")
        #expect(gateway.requestCount == turns + 1)
    }

    /// …and a genuinely stuck run in that same UI still stops.
    ///
    /// Removing the turn cap is only safe because something else bounds a runaway,
    /// so the two halves are asserted against the same binary on the same
    /// terminal. Fifteen identical `ls` turns are scripted; the guard's default is
    /// twelve consecutive identical turns, so the client's run ends there — with
    /// no `--max-turns` anywhere — and the session goes back to accepting prompts.
    @Test
    func fullScreenClientStopsAStuckRun() throws {
        let gateway = try MockGateway(
            chatCompletionBodies: (0..<15).map { TurnLimitEndToEndTests.toolCallTurn(id: "same\($0)", path: ".") }
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "hello.txt", contents: "hi\n")

        let pty = try PseudoTerminal()
        defer { pty.closeMaster() }
        guard let slave = FileHandle(forUpdatingAtPath: pty.slavePath) else {
            throw MockGatewayError("could not open pty slave \(pty.slavePath)")
        }
        defer { try? slave.close() }

        let process = try Self.launchClient(
            arguments: ["--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace,
            slave: slave
        )
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        var captured: [UInt8] = []
        let ready = Self.poll(timeout: .seconds(20)) {
            pty.drain(into: &captured)
            let output = String(decoding: captured, as: UTF8.self)
            return output.contains(Self.alternateScreen) && output.contains(Self.openedSessionRow)
        }
        #expect(ready, "the full-screen client never opened its session")

        pty.type("keep listing\r")
        let accepted = Self.poll(timeout: .seconds(20)) {
            pty.drain(into: &captured)
            return gateway.requestCount > 0
        }
        #expect(accepted, "the prompt was never accepted")

        let stopped = Self.poll(timeout: .seconds(30)) {
            pty.drain(into: &captured)
            return gateway.requestCount >= 12
        }
        #expect(stopped, "the stuck run never reached the guard (\(gateway.requestCount) turns)")
        // And it STAYS stopped — the guard ended the run rather than merely slowing
        // it, so the remaining three scripted turns are never asked for.
        _ = Self.poll(timeout: .seconds(3)) { pty.drain(into: &captured); return false }
        #expect(gateway.requestCount == 12, "the run did not stop at the guard")
    }

    /// Poll `condition` until it holds or the deadline passes.
    static func poll(timeout: Duration, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    /// Spawn `domo` with the given arguments, wired to `slave` as its terminal.
    static func launchClient(arguments: [String], workspace: Workspace, slave: FileHandle) throws -> Process {
        let process = Process()
        process.executableURL = domoBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = workspace.workDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
        environment["HOME"] = workspace.homeDirectory.path
        environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
        environment["DOMOCODE_LOG_LEVEL"] = "error"
        environment["COLUMNS"] = "100"
        environment["LINES"] = "30"
        for key in [
            "OPENAI_API_KEY", "LITELLM_API_KEY", "DOMOCODE_MODEL", "DOMOCODE_BASE_URL",
            // Live since the stream idle bound was wired.
            "DOMOCODE_STREAM_TIMEOUT_MS",
            // Keep test-runner diagnostics out of the optimized application
            // child; see the matching environment cleanup above.
            "SWIFT_BACKTRACE",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        // Keep child diagnostics out of the pty transcript, but surface them in
        // the test runner. A release-only child crash otherwise looks exactly
        // like an input or gateway hang because the error pipe is never read.
        process.standardError = FileHandle.standardError
        try process.run()
        return process
    }
}
