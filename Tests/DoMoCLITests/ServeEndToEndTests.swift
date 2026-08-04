// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `domo --serve`, driven over the wire.
//
// "There is no turn limit by default, in EVERY mode — interactive, -p and --serve
// alike" is a claim `--help` and the README both make, and it fans out to four
// separate call sites. Two of them run the real binary against the claim: `-p`
// through the print-mode tests and the full-screen client through the pty test.
// The `--serve` leg — `runServer`'s `buildServerRuntime(…, maxTurns: turnLimit)`
// — had nothing behind it at all, so hardcoding a `20` there changed no test's
// verdict while quietly reinstating exactly the cap the user asked to have
// removed. That is what this file covers.
//
// The fourth, `--inline`, is still only HALF covered, and this comment used to
// call it pinned: the REPL tests hand `InteractiveMode.make` a `maxTurns` of
// their own, which pins what the REPL does with a bound but not what the COMMAND
// passes it. (``SurfaceWiringTests`` now drives that surface on a pty for the
// per-alias arguments; adding `--max-turns` to that run is how this leg would be
// closed.)
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
// `URLSession`, `URLRequest` and `HTTPURLResponse` live in FoundationNetworking
// on Linux and in Foundation on Darwin, so the import is conditional.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

// MARK: - What the developer's shell may not decide

/// The isolation every spawned `domo` in this target runs under.
///
/// This is a test OF a test helper because the helper's failure mode is
/// invisible from the tests that use it: a leaked variable does not make
/// anything red, it makes an assertion pass for a reason that is not the code
/// under test. Both cases below were observed, not imagined — an exported
/// `DOMOCODE_REASONING_EFFORT=high` kept
/// ``SurfaceWiringTests/theDefaultSurfaceBillsAtTheConfiguredRatesAndReportsTheDeclaredWindow()``
/// green with the per-alias plumbing deleted, and an exported
/// `DOMOCODE_SMALL_MODEL` failed a compaction test whose premise is that nothing
/// named a small model.
@Suite
struct ChildEnvironmentIsolationTests {

    /// Nothing that CONFIGURES a run survives from the parent's environment, and
    /// everything the child needs to RUN does. (`HOME` is read by the resolver and
    /// does survive — as the workspace's own, which is the isolation, not a leak.)
    ///
    /// The inherited dictionary is supplied rather than read from `ProcessInfo`
    /// on purpose: `setenv` in a test process is visible to every other test in
    /// it, so the one thing this must not do to prove a variable is stripped is
    /// export it.
    @Test
    func noDomocodeVariableSurvivesFromTheParentShell() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let developersShell = [
            // The two the reviewer actually proved.
            "DOMOCODE_REASONING_EFFORT": "high",
            "DOMOCODE_SMALL_MODEL": "leaked-small-model",
            // And the rest of the resolver's surface, none of which was stripped
            // by the five-name list this replaced.
            "DOMOCODE_SESSION_DIR": "/somewhere/of/their/own",
            "DOMOCODE_AUTH_HEADER": "X-Leaked",
            "DOMOCODE_MAX_RETRIES": "9",
            "DOMOCODE_TIMEOUT_MS": "1",
            "OPENAI_API_KEY": "sk-the-developers-real-key",
            "LITELLM_API_KEY": "sk-also-real",
            // What the child needs to load a Swift runtime and find a binary.
            "PATH": "/usr/bin:/bin",
            "DYLD_LIBRARY_PATH": "/toolchain/lib",
        ]
        let environment = isolatedChildEnvironment(inherited: developersShell, workspace: workspace)

        for name in [
            "DOMOCODE_REASONING_EFFORT", "DOMOCODE_SMALL_MODEL", "DOMOCODE_SESSION_DIR",
            "DOMOCODE_AUTH_HEADER", "DOMOCODE_MAX_RETRIES", "DOMOCODE_TIMEOUT_MS",
            "OPENAI_API_KEY", "LITELLM_API_KEY",
        ] {
            #expect(environment[name] == nil, "\(name) reached the child from the developer's shell")
        }

        // CONTROL: the sweep is a sweep of the RESOLVER's variables, not of the
        // environment. A helper that returned an empty dictionary would "pass"
        // every assertion above and leave every end-to-end test unable to start
        // the binary at all.
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["DYLD_LIBRARY_PATH"] == "/toolchain/lib")
        #expect(environment["DOMOCODE_CONFIG_DIR"] == workspace.configDirectory.path)
        #expect(environment["HOME"] == workspace.homeDirectory.path)
        #expect(environment["DOMOCODE_API_KEY"] == "sk-mock-test-key")
        #expect(environment["DOMOCODE_LOG_LEVEL"] == "error")
    }

    /// A variable the TEST set outlives the sweep.
    ///
    /// The sweep runs over the inherited environment and the overrides are
    /// applied after it, which is the order that lets a test say
    /// `DOMOCODE_LOG_LEVEL: ""` (the redaction test's way of stopping the
    /// environment layer from short-circuiting a settings warning) or shrink the
    /// retry backoff. Applied in the other order, every such test would be
    /// silently disarmed.
    @Test
    func aCallersOwnVariablesAreAppliedAfterTheSweep() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }

        let environment = isolatedChildEnvironment(
            inherited: ["DOMOCODE_RETRY_BASE_MS": "60000"],
            workspace: workspace,
            extra: ["DOMOCODE_RETRY_BASE_MS": "5", "DOMOCODE_LOG_LEVEL": "", "MY_HELPER_TOKEN": "value"]
        )

        #expect(environment["DOMOCODE_RETRY_BASE_MS"] == "5", "the caller's value did not outrank the sweep")
        #expect(environment["DOMOCODE_LOG_LEVEL"] == "")
        #expect(environment["MY_HELPER_TOKEN"] == "value")
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
    private let clientID = "serve-process-test"
    private let clientOwner = "serve-process-test"

    init(arguments: [String], workspace: Workspace) throws {
        process.executableURL = domoBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = workspace.workDirectory

        // Isolated the same way `runDomo`'s child is, through the same function:
        // a served run resolves the same settings from the same environment, and
        // the surface-wiring tests that drive this class assert on numbers a
        // stray `DOMOCODE_*` variable in the developer's shell could otherwise
        // supply. See ``isolatedChildEnvironment(inherited:workspace:extra:)``.
        process.environment = isolatedChildEnvironment(workspace: workspace)

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
        let attachment = try JSONSerialization.data(withJSONObject: [
            "clientID": clientID,
            "owner": clientOwner,
            "requestAuthority": true,
        ])
        let (attachmentData, attachmentStatus) = try await send(
            ready,
            method: "POST",
            path: "/session/\(id)/client/attach",
            body: attachment
        )
        guard attachmentStatus == 200 else {
            throw MockGatewayError(
                "POST client attach -> \(attachmentStatus): \(String(decoding: attachmentData, as: UTF8.self))"
            )
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
        request.setValue(clientID, forHTTPHeaderField: "x-domocode-client-id")
        request.setValue(clientOwner, forHTTPHeaderField: "x-domocode-client-owner")
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
