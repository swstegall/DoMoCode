// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Log output must not paint over the full-screen client's frame.
//
// The end-to-end test here is the reproduction that found the defect, kept as a
// regression. It differs from ``FullScreenClientPTYTests`` in exactly one way,
// and that one way is the whole point: those tests give the child a pty for
// stdin/stdout and send its stderr somewhere else, which is precisely the
// arrangement in which this bug is invisible. A user's shell hands the child the
// SAME terminal for all three, so a `warning`-level log line is written straight
// into the alternate-screen frame — over the prompt, because the renderer parks
// the cursor there at the end of every frame, and the cells are never repainted
// because nothing in the renderer's model changed.
//
// Before the fix, driving `domo` this way put a paragraph like
//
//     2026-08-07T13:23:03-0500 warning domo.session-clients: [DoMoCLI] session-client
//     journal could not be replayed and was set aside at …
//
// across rows 22–24 and 27–28 of a thirty-row frame, straddling the prompt.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import SystemPackage
import Testing

@testable import DoMoCLI

@Suite(.serialized)
struct FullScreenLogRoutingTests {

    /// Alt-screen entry — proof the full-screen UI was actually up, so an
    /// assertion that log text is absent is about a frame and not about a client
    /// that never started.
    static let alternateScreen = "\u{1b}[?1049h"

    /// The warning the corrupted session-client journal produces. Matched on its
    /// stable prefix rather than the whole line, which carries a timestamp and a
    /// temp path.
    static let quarantineWarning = "session-client journal could not be replayed"

    // MARK: The reproduction

    /// A `warning` log emitted while the full-screen client owns the terminal
    /// reaches the run's log file, and NOT the frame.
    ///
    /// The trigger is a session-client journal whose contents are not JSON. The
    /// ledger sets such a journal aside and reports it through `onQuarantine`,
    /// which ``DoMoCodeCommand`` logs at `warning` — the default level, so no
    /// log-level knob has to be set for this to fire. It is replayed lazily, on
    /// the first attach, which happens when the client opens its session: i.e.
    /// after the alternate screen is up and the first frame is painted.
    ///
    /// The order of the assertions matters. The log file is checked FIRST, and
    /// the absence of the text on the terminal is only meaningful because of it:
    /// a child that crashed before logging anything would satisfy "not in the
    /// frame" while proving nothing at all.
    @Test
    func aWarningWhileTheClientOwnsTheTerminalGoesToTheLogFileNotTheFrame() throws {
        let gateway = try MockGateway(chatCompletionBodies: [])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try Self.writeCorruptClientLedger(in: workspace)

        guard let pty = LogRoutingPseudoTerminal() else {
            // No pty in this sandbox; the same reason ``openPTYMaster`` returns
            // nil rather than trapping.
            return
        }
        defer { pty.closeMaster() }
        guard let slave = FileHandle(forUpdatingAtPath: pty.slavePath) else {
            throw MockGatewayError("could not open pty slave \(pty.slavePath)")
        }
        defer { try? slave.close() }

        let process = try Self.launchClientWithStderrOnTheTerminal(
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

        let logFile = workspace.configDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(
                FullScreenLogRedirect.logFileName(processID: process.processIdentifier)
            )

        var captured: [UInt8] = []
        let reported = Self.poll(timeout: .seconds(30)) {
            // Drain as we wait, so the pty buffer never fills and stalls the
            // child mid-frame.
            pty.drain(into: &captured)
            let logged = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            return logged.contains(Self.quarantineWarning)
        }
        #expect(
            reported,
            "the quarantine warning never reached \(logFile.path) — the run may not have logged at all"
        )

        // Give anything still in flight a moment to land on the terminal, so the
        // absence below is not merely a race won.
        _ = Self.poll(timeout: .seconds(2)) {
            pty.drain(into: &captured)
            return false
        }
        let frame = String(decoding: captured, as: UTF8.self)
        #expect(frame.contains(Self.alternateScreen), "the full-screen client never opened")
        #expect(
            !frame.contains(Self.quarantineWarning),
            "the log line was painted into the frame"
        )
        // The whole `[DoMoCLI] domo.session-clients` shape, not just this one
        // message: nothing swift-log formats belongs on the alternate screen.
        #expect(!frame.contains("domo.session-clients"), "a log label was painted into the frame")
    }

    // MARK: The gate

    /// Two descriptors on the same terminal are recognised as such — the
    /// condition under which a write to stderr lands on the frame.
    @Test
    func theSameTerminalTwiceSharesATerminal() throws {
        guard let pty = LogRoutingPseudoTerminal() else { return }
        defer { pty.closeMaster() }
        let first = open(pty.slavePath, O_RDWR | O_NOCTTY)
        let second = open(pty.slavePath, O_RDWR | O_NOCTTY)
        defer {
            if first >= 0 { _ = close(first) }
            if second >= 0 { _ = close(second) }
        }
        try #require(first >= 0 && second >= 0)
        #expect(FullScreenLogRedirect.sharesTerminal(first, second))
    }

    /// A descriptor that is not a terminal never shares one — which is the whole
    /// gate, and therefore the guarantee that `-p` and `--json` are untouched: a
    /// piped or redirected run cannot reach the redirect at all, whatever else
    /// changes around it.
    @Test
    func aRedirectedDescriptorSharesNoTerminal() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("captured-stderr").path
        let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { if file >= 0 { _ = close(file) } }
        try #require(file >= 0)

        #expect(!FullScreenLogRedirect.sharesTerminal(file, file))

        guard let pty = LogRoutingPseudoTerminal() else { return }
        defer { pty.closeMaster() }
        let terminal = open(pty.slavePath, O_RDWR | O_NOCTTY)
        defer { if terminal >= 0 { _ = close(terminal) } }
        try #require(terminal >= 0)
        // `domo 2>run.log` in a terminal: stdout is the tty, stderr is not, and
        // the operator asked for that. Leave it alone.
        #expect(!FullScreenLogRedirect.sharesTerminal(terminal, file))
    }

    /// Nothing is redirected in a process that never started a full-screen
    /// client, so there is no log path to advertise. (Also the invariant the
    /// error dialog's hint depends on: a non-`nil` path means the diagnostics
    /// really are in a file rather than on the user's screen.)
    @Test
    func nothingIsRedirectedByDefault() {
        #expect(FullScreenLogRedirect.currentLogPath == nil)
    }

    // MARK: Housekeeping

    /// One file per run, named by pid, under `<config-dir>/logs`.
    @Test
    func theLogPathIsPerRunUnderTheConfigDirectory() {
        let directory = FullScreenLogRedirect.logDirectory(configDirectory: FilePath("/tmp/cfg"))
        #expect(directory == FilePath("/tmp/cfg/logs"))
        #expect(FullScreenLogRedirect.logFileName(processID: 4321) == "fullscreen-4321.log")
        #expect(FullScreenLogRedirect.isLogFileName("fullscreen-4321.log"))
        #expect(!FullScreenLogRedirect.isLogFileName("settings.json"))
    }

    /// Pruning keeps the newest few and deletes the rest, so a user who never
    /// looks does not accumulate one file per session forever.
    ///
    /// The pids are above every platform's `pid_max` (macOS caps at 99998, Linux
    /// at 2²² with the default `kernel.pid_max`), because the pruner spares a log
    /// whose process still exists — and a test that used low numbers would keep
    /// `fullscreen-1.log` on a CI container running as root, where `kill(1, 0)`
    /// succeeds.
    @Test
    func pruningKeepsTheNewestLogsAndNothingElse() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        for index in 0..<8 {
            let url = directory.appendingPathComponent(Self.deadRunLogName(index))
            try "run \(index)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index))],
                ofItemAtPath: url.path
            )
        }
        // A file that is not one of ours. The pruner deletes things in a
        // directory the user owns, so it must never widen past its own scheme.
        let bystander = directory.appendingPathComponent("notes.txt")
        try "keep me\n".write(to: bystander, atomically: true, encoding: .utf8)

        FullScreenLogRedirect.pruneOldLogs(in: FilePath(directory.path), keeping: 3)

        let remaining = Set(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        )
        #expect(
            remaining == [
                Self.deadRunLogName(5), Self.deadRunLogName(6), Self.deadRunLogName(7), "notes.txt",
            ]
        )
    }

    /// The file the current run is writing to survives the prune whatever its
    /// modification time says — a coarse or skewed clock must not be able to
    /// delete the log out from under the live redirect.
    @Test
    func pruningNeverDeletesTheRunsOwnLog() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        for index in 0..<4 {
            let url = directory.appendingPathComponent(Self.deadRunLogName(index))
            try "run \(index)\n".write(to: url, atomically: true, encoding: .utf8)
            // The current run's file is deliberately the OLDEST by mtime.
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(index == 0 ? -600 : Double(index))],
                ofItemAtPath: url.path
            )
        }
        let mine = FilePath(directory.appendingPathComponent(Self.deadRunLogName(0)).path)

        FullScreenLogRedirect.pruneOldLogs(in: FilePath(directory.path), keeping: 1, except: mine)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(remaining.contains(Self.deadRunLogName(0)))
        #expect(remaining.contains(Self.deadRunLogName(3)))
        #expect(remaining.count == 2)
    }

    /// A log belonging to a process that is STILL RUNNING is never pruned, even
    /// when it is the oldest thing in the directory.
    ///
    /// The other `domo` that has been open all afternoon has the oldest log by
    /// mtime precisely because it wrote its startup lines hours ago. Unlinking it
    /// would not fail or even be noticed — its descriptor stays valid — and that
    /// session's diagnostics would simply stop existing.
    @Test
    func pruningSparesALogWhoseProcessIsStillRunning() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // This test process is, by construction, alive.
        let live = directory.appendingPathComponent(
            FullScreenLogRedirect.logFileName(processID: getpid())
        )
        try "still running\n".write(to: live, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: live.path
        )
        let dead = directory.appendingPathComponent(Self.deadRunLogName(1))
        try "long gone\n".write(to: dead, atomically: true, encoding: .utf8)

        FullScreenLogRedirect.pruneOldLogs(in: FilePath(directory.path), keeping: 0)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(remaining == [live.lastPathComponent])
    }

    /// A file name the scheme cannot attribute to a run is not the pruner's to
    /// delete.
    @Test
    func aLogNameWithoutAProcessIDIsNotAttributed() {
        #expect(FullScreenLogRedirect.processID(inLogFileName: "fullscreen-4321.log") == 4321)
        #expect(FullScreenLogRedirect.processID(inLogFileName: "fullscreen-old.log") == nil)
        #expect(FullScreenLogRedirect.processID(inLogFileName: "notes.txt") == nil)
    }

    // MARK: Support

    /// A log file name for a process that certainly does not exist: above
    /// `pid_max` on every platform this runs on, so the pruner's liveness check
    /// cannot spare it and the test measures ordering rather than the pid table.
    static func deadRunLogName(_ index: Int) -> String {
        FullScreenLogRedirect.logFileName(processID: Int32(9_000_000 + index))
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A session-client journal whose CONTENT is bad. The ledger quarantines it
    /// and reports it at `warning` on the first attach — which is while the
    /// client is painting.
    static func writeCorruptClientLedger(in workspace: Workspace) throws {
        let directory = workspace.workDirectory
            .appendingPathComponent(".domocode", isDirectory: true)
            .appendingPathComponent("clients", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{ this is not json\n".write(
            to: directory.appendingPathComponent("session-clients.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Spawn `domo` with all three standard descriptors on the pty — the shape a
    /// shell gives it, and the only shape in which this defect exists.
    static func launchClientWithStderrOnTheTerminal(
        arguments: [String],
        workspace: Workspace,
        slave: FileHandle
    ) throws -> Process {
        let process = Process()
        process.executableURL = domoBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = workspace.workDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
        environment["HOME"] = workspace.homeDirectory.path
        environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
        environment["COLUMNS"] = "100"
        environment["LINES"] = "30"
        for key in [
            "OPENAI_API_KEY", "LITELLM_API_KEY", "DOMOCODE_MODEL", "DOMOCODE_BASE_URL",
            "DOMOCODE_STREAM_TIMEOUT_MS",
            // The sibling pty tests pin this to `error`; this one must NOT, because
            // the whole subject is what a `warning` does. The resolved default is
            // warning, so removing it is the assertion.
            "DOMOCODE_LOG_LEVEL",
            // CI enables this for the test runner, and the release runtime rejects
            // the inherited crash-backtrace hook in a spawned pty client.
            "SWIFT_BACKTRACE",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        try process.run()
        return process
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
}

/// A pty pair: the test holds the master, the child gets the slave.
///
/// A second copy of ``FullScreenClientPTYTests``'s helper because that one is
/// file-private, and the two suites are `.serialized` independently.
private final class LogRoutingPseudoTerminal {
    let master: Int32
    let slavePath: String

    init?() {
        guard let opened = openPTYMaster() else { return nil }
        master = opened.master
        slavePath = opened.slaveName
        // Non-blocking, so draining never parks on a child that has simply
        // stopped painting.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
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

    func closeMaster() {
        _ = close(master)
    }
}
