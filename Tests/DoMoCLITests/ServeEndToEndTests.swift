// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `domo --serve`, driven over the wire.
//
// "There is no turn limit by default, in EVERY mode — interactive, -p and --serve
// alike" is a claim `--help` and the README both make, and it fans out to four
// separate call sites. Three of them were pinned: `-p` by the print-mode tests,
// the full-screen client by the pty test, `--inline` by the REPL tests. The
// fourth — `runServer`'s `buildServerRuntime(…, maxTurns: turnLimit)` — had
// nothing behind it at all, so hardcoding a `20` there changed no test's verdict
// while quietly reinstating exactly the cap the user asked to have removed.
//
// This drives the real binary over the same HTTP surface the client uses: create
// a session, POST a prompt, and watch a twenty-five-turn run finish. An
// unverified promise in `--help` is worse than no promise, so the leg is covered
// rather than the sentence deleted.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct ServeEndToEndTests {

    /// THE UNPINNED LEG. Twenty-five turns of varied tool work through `--serve`,
    /// with no `--max-turns` anywhere: the run reaches its final answer.
    ///
    /// Twenty-five is chosen against the old default of twenty, so a reinstated cap
    /// shows up as a run that stops five turns short rather than as a slow test.
    @Test
    func serveRunsPastTwentyTurns() async throws {
        let turns = 25
        let gateway = try MockGateway(
            chatCompletionBodies: TurnLimitEndToEndTests.variedScript(turns: turns, finalText: "all done.")
        )
        gateway.start()
        defer { gateway.stop() }

        let workspace = try TurnLimitEndToEndTests.workspaceWithDirectories(turns)
        defer { workspace.cleanUp() }

        let server = try ServeProcess(
            arguments: ["--serve", "--port", "0", "--model", "mock-model", "--base-url", gateway.baseURL],
            workspace: workspace
        )
        defer { server.terminate() }

        let ready = try #require(
            await server.waitUntilListening(timeout: .seconds(60)),
            "domo --serve never announced a bound port. stderr: \(server.capturedStandardError)"
        )

        let sessionID = try await server.createSession(ready)
        try await server.startPrompt(ready, sessionID: sessionID, prompt: "walk every directory")

        // 25 tool turns plus the final text turn. With a cap of 20 the run stops at
        // 20 and this never reaches the target.
        let finished = await Self.poll(timeout: .seconds(60)) { gateway.requestCount >= turns + 1 }
        #expect(
            finished,
            "the served run stopped after \(gateway.requestCount) turns. stderr: \(server.capturedStandardError)"
        )
        #expect(gateway.requestCount == turns + 1)

        // And it stopped because it FINISHED, not because something else bounded it:
        // the server reports the session idle and the final answer is in its
        // transcript.
        let settled = await Self.poll(timeout: .seconds(30)) {
            (try? await server.isRunning(ready, sessionID: sessionID)) == false
        }
        #expect(settled, "the served run never settled")
        let messages = try await server.messages(ready, sessionID: sessionID)
        #expect(messages.contains("all done."), "the served run produced no final answer")
    }

    /// Poll an async condition until it holds or the deadline passes.
    static func poll(timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}

// MARK: - The served process

/// A running `domo --serve`, plus the loopback client calls a test needs to drive
/// it.
///
/// The server never exits on its own, so its stderr is drained continuously
/// through a readability handler rather than read to EOF — reading to EOF is what
/// `runDomo` can do only because the child it runs terminates.
final class ServeProcess: @unchecked Sendable {

    /// The two facts the server prints to stderr before it can be talked to.
    struct Ready: Sendable {
        let port: Int
        let token: String
    }

    private let process = Process()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var standardErrorText = ""

    init(arguments: [String], workspace: Workspace) throws {
        process.executableURL = domoBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = workspace.workDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
        environment["HOME"] = workspace.homeDirectory.path
        environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
        environment["DOMOCODE_LOG_LEVEL"] = "error"
        for key in [
            "OPENAI_API_KEY", "LITELLM_API_KEY", "DOMOCODE_MODEL", "DOMOCODE_BASE_URL",
            // Live since the stream idle bound was wired.
            "DOMOCODE_STREAM_TIMEOUT_MS",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.standardErrorText += text
            self.lock.unlock()
        }

        try process.run()
    }

    var capturedStandardError: String {
        lock.lock()
        defer { lock.unlock() }
        return standardErrorText
    }

    func terminate() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    // MARK: Readiness

    /// Wait for both stderr announcements — the bearer token and the ACTUAL bound
    /// port, which with `--port 0` is only knowable from the process itself.
    func waitUntilListening(timeout: Duration) async -> Ready? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let ready = Self.parseReady(capturedStandardError) { return ready }
            if !process.isRunning { return Self.parseReady(capturedStandardError) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.parseReady(capturedStandardError)
    }

    static func parseReady(_ stderr: String) -> Ready? {
        var token: String?
        var port: Int?
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            if let range = line.range(of: "Authorization: Bearer ") {
                token = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if let range = line.range(of: "listening on http://127.0.0.1:") {
                let tail = line[range.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                port = Int(digits)
            }
        }
        guard let token, !token.isEmpty, let port, port > 0 else { return nil }
        return Ready(port: port, token: token)
    }

    // MARK: The HTTP surface the client uses

    func createSession(_ ready: Ready) async throws -> String {
        let (data, response) = try await send(ready, method: "POST", path: "/session", body: nil)
        guard response == 201 else {
            throw MockGatewayError("POST /session -> \(response): \(String(decoding: data, as: UTF8.self))")
        }
        let json = try JSONValue(parsing: data)
        guard let id = json["id"]?.stringValue else {
            throw MockGatewayError("POST /session had no id: \(String(decoding: data, as: UTF8.self))")
        }
        return id
    }

    func startPrompt(_ ready: Ready, sessionID: String, prompt: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        let (data, response) = try await send(ready, method: "POST", path: "/session/\(sessionID)/prompt", body: body)
        guard response == 202 else {
            throw MockGatewayError("POST prompt -> \(response): \(String(decoding: data, as: UTF8.self))")
        }
    }

    func isRunning(_ ready: Ready, sessionID: String) async throws -> Bool {
        let (data, response) = try await send(ready, method: "GET", path: "/session/\(sessionID)/status", body: nil)
        guard response == 200 else {
            throw MockGatewayError("GET status -> \(response): \(String(decoding: data, as: UTF8.self))")
        }
        return try JSONValue(parsing: data)["running"]?.boolValue ?? true
    }

    /// The session transcript, as raw JSON — enough to assert the final answer is
    /// in it without duplicating the server's message DTOs here.
    func messages(_ ready: Ready, sessionID: String) async throws -> String {
        let (data, response) = try await send(ready, method: "GET", path: "/session/\(sessionID)/messages", body: nil)
        guard response == 200 else {
            throw MockGatewayError("GET messages -> \(response): \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func send(
        _ ready: Ready,
        method: String,
        path: String,
        body: Data?
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(ready.port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(ready.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
