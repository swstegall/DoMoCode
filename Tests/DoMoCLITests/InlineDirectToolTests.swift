// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The inline REPL's direct tool path, driven end to end through the same injected
// seams the rest of the REPL is tested through: scripted keystrokes in, a captured
// byte stream replayed into a VT oracle out, and a real loopback gateway that
// answers if — and only if — something wrongly turns a `/tool` line into a model
// turn.
//
// The defect these pin: this phase put every live tool into the inline `/` popup,
// and choosing `/read` inserted a line whose only possible outcome was "Unknown
// command /read" — `PromptCommandProcessor` knows command names, and the inline
// REPL had no direct-tool route at all. The popup advertised a dead end.
//
// Two properties are worth more than the individual assertions and are each
// checked more than once below:
//
//   * A `/name` that names NO tool must still print exactly the error it always
//     printed. The failure mode being guarded against is the tempting one — treat
//     an unrecognised slash line as prose and send it — which turns a typo into a
//     model turn (and a bill) instead of into a correction.
//   * A direct tool must reach the gateway ZERO times. Every test therefore stands
//     up a `MockGateway` with a scripted reply it must never serve: `requestCount`
//     is the assertion, and the reply's text on screen would be the smoking gun.

// `@testable` reaches one internal: ``InteractiveCoordinator``, whose `slashName`
// is the grammar both the refusal path and the run path read a submitted line
// with. It is internal by design — the coordinator is the REPL's private state
// machine — and the alternative to pinning it here is pinning it only through a
// live terminal, which is how a parser like this ends up with no test at all.
@testable import DoMoCLI
import DoMoLLM
import DoMoTermIO
import DoMoTUI
import Foundation
import Testing

// MARK: - Helpers

/// Deliberately distinct from the identically-shaped helpers in the other inline
/// end-to-end file: both are file-private, and keeping the names apart means a
/// later reader can never wonder which one a call resolves to.
private func inlineBytes(_ string: String) -> [UInt8] { Array(string.utf8) }

@MainActor
private func inlineWaitUntil(
    timeout: Duration = .seconds(15),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// True when any row of the replayed screen — scrollback included, since the
/// transcript scrolls — contains `needle`.
@MainActor
private func inlineScreenContains(
    _ target: CaptureTarget,
    rows: Int,
    cols: Int,
    _ needle: String
) -> Bool {
    let oracle = ScreenOracle(rows: rows, cols: cols)
    oracle.feed(target.snapshot())
    if oracle.transcript.contains(where: { $0.contains(needle) }) { return true }
    return oracle.screen.contains { $0.contains(needle) }
}

/// A throwaway working tree, session directory and config directory, so the tests
/// never read the developer's real `~/.domocode` — which, for the permission test
/// below, would mean a previously persisted "always allow" grant deciding the
/// outcome instead of the baseline ruleset.
private struct InlineToolTree {
    let root: URL
    let work: URL
    let sessions: URL

    init() throws {
        let manager = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-direct-tool-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for directory in [work, sessions] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeFile(_ name: String, _ contents: String) throws {
        try contents.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct InlineDirectToolTests {

    /// The reply the gateway is armed with and must never be asked for. Its text is
    /// asserted ABSENT wherever a model turn would be the defect.
    static let unwantedTurn = #"""
        data: {"id":"c1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"THE MODEL ANSWERED."},"finish_reason":null}]}

        data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]


        """#

    /// The whole point: a tool chosen from the popup and submitted RUNS, in process,
    /// and its result is drawn in the transcript by the same `ToolResultView` a
    /// model-issued call would be drawn by.
    @Test
    func directToolCommandRunsTheToolWithoutAModelTurn() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.unwantedTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try InlineToolTree()
        defer { tree.cleanUp() }
        // One distinctive word, so the assertion cannot be satisfied by anything the
        // renderer or the prompt echo puts on screen.
        try tree.writeFile("notes.txt", "DIRECTTOOLRANHERE\n")

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 80, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // The trailing argument puts a space in the line, which closes the `/` popup
        // — so Enter submits rather than accepting a completion.
        inputCont.yield(inlineBytes("/read notes.txt"))
        let typed = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "notes.txt") }
        #expect(typed, "the command never reached the editor")
        inputCont.yield(inlineBytes("\r"))

        let ran = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "DIRECTTOOLRANHERE")
        }
        #expect(ran, "the direct tool never ran — the file's content is not in the transcript")
        #expect(
            !inlineScreenContains(target, rows: rows, cols: cols, "Unknown command"),
            "the tool ran but the dead-end error was printed anyway"
        )
        #expect(gateway.requestCount == 0, "a direct tool command must not contact the gateway")

        inputCont.finish()
        try await runTask.value
    }

    /// The other half of the contract, and the one a careless fix breaks: a slash
    /// name that matches neither a command nor a tool is a TYPO. It keeps printing
    /// the error it always printed, and it must not be sent to the model.
    @Test
    func slashNameMatchingNoToolStillPrintsTheCommandError() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.unwantedTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try InlineToolTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 80, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        // A name no fuzzy filter can match, so no completion popup is up to swallow
        // the Enter that submits it.
        inputCont.yield(inlineBytes("/zzznotatool"))
        let typed = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "zzznotatool") }
        #expect(typed, "the command never reached the editor")
        inputCont.yield(inlineBytes("\r"))

        let refused = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "Unknown command /zzznotatool")
        }
        #expect(refused, "a typo must still be reported, not quietly sent to the model")
        #expect(
            !inlineScreenContains(target, rows: rows, cols: cols, "THE MODEL ANSWERED"),
            "a typo became a model turn"
        )
        #expect(gateway.requestCount == 0)

        inputCont.finish()
        try await runTask.value
    }

    /// The direct path runs through the SAME permission gate a model-issued call
    /// runs through: `bash` is `ask` under the baseline ruleset, so the approval
    /// modal has to appear before anything executes, and rejecting it has to come
    /// back as an error result the transcript draws — not as a crash and not as a
    /// silently-executed command.
    @Test
    func directToolCommandGoesThroughThePermissionGate() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.unwantedTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try InlineToolTree()
        defer { tree.cleanUp() }

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 80, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(inlineBytes("/bash echo"))
        let typed = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "/bash echo") }
        #expect(typed, "the command never reached the editor")
        inputCont.yield(inlineBytes("\r"))

        let modalUp = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "Allow bash") }
        #expect(modalUp, "a direct tool call skipped the approval modal")

        // Ctrl-C rejects outright, the modal's most direct answer.
        inputCont.yield([0x03])
        let refused = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "rejected") }
        #expect(refused, "the rejection never reached the transcript as a tool result")
        #expect(gateway.requestCount == 0)

        inputCont.finish()
        try await runTask.value
    }

    /// A command that cannot be PARSED — the tool exists, the arguments do not fit
    /// its schema — is reported as an error row and the REPL keeps running. The
    /// direct path throws for exactly this case (the dispatcher turns tool failures
    /// into results, but the parser throws before there is a call to dispatch), so
    /// this pins that the throw is rendered rather than escaping the run task.
    @Test
    func unparsableDirectToolCommandBecomesAnErrorRow() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.unwantedTurn])
        gateway.start()
        defer { gateway.stop() }

        let tree = try InlineToolTree()
        defer { tree.cleanUp() }
        try tree.writeFile("notes.txt", "DIRECTTOOLRANHERE\n")

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 80, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(inlineBytes("/read --nosuchflag notes.txt"))
        let typed = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "nosuchflag") }
        #expect(typed, "the command never reached the editor")
        inputCont.yield(inlineBytes("\r"))

        let reported = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "unknown argument")
        }
        #expect(reported, "the parse failure was not reported")
        #expect(
            !inlineScreenContains(target, rows: rows, cols: cols, "DIRECTTOOLRANHERE"),
            "an unparsable command must not run the tool anyway"
        )
        #expect(gateway.requestCount == 0)

        // The session is still alive: a second, well-formed command runs.
        inputCont.yield(inlineBytes("/read notes.txt"))
        let retyped = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "read notes.txt")
        }
        #expect(retyped, "the second command never reached the editor")
        inputCont.yield(inlineBytes("\r"))
        let ran = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "DIRECTTOOLRANHERE")
        }
        #expect(ran, "the REPL did not survive the parse failure")

        inputCont.finish()
        try await runTask.value
    }

    /// A direct tool submitted while a turn is in flight is REFUSED, not steered.
    /// The harness owns one turn at a time, so the alternative to a refusal is the
    /// line arriving at the model as a message — the same dead end in a new
    /// disguise. The gateway here hangs deliberately, so the turn really is live
    /// when the second line is submitted.
    @Test
    func directToolCommandIsRefusedWhileATurnIsInFlight() async throws {
        let gateway = try HangingGateway(firstDelta: "partial-answer")
        gateway.start()
        defer { gateway.stop() }

        let tree = try InlineToolTree()
        defer { tree.cleanUp() }
        try tree.writeFile("notes.txt", "DIRECTTOOLRANHERE\n")

        let mode = try await InteractiveMode.make(
            clientConfiguration: LiteLLMClient.Configuration(baseURL: gateway.baseURL, apiKey: "sk-test"),
            model: "mock-model",
            workingDirectory: tree.work.path,
            sessionDirectory: tree.sessions.path,
            configDirectory: tree.root.path
        )

        let cols = 100, rows = 24
        let target = CaptureTarget(columns: cols, rows: rows)
        let (input, inputCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (resize, _) = AsyncStream.makeStream(of: TerminalSize.self)
        let runTask = Task { @MainActor in
            try await mode.run(target: target, input: input, resize: resize, lifecycle: NoopLifecycle())
        }

        inputCont.yield(inlineBytes("do something long"))
        inputCont.yield(inlineBytes("\r"))
        let started = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "partial-answer")
        }
        #expect(started, "the turn never began, so there is nothing to be busy with")

        inputCont.yield(inlineBytes("/read notes.txt"))
        let typed = await inlineWaitUntil { inlineScreenContains(target, rows: rows, cols: cols, "notes.txt") }
        #expect(typed, "the command never reached the editor")
        inputCont.yield(inlineBytes("\r"))

        let refused = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "cannot run while a turn is in flight")
        }
        #expect(refused, "a direct tool submitted mid-turn was not refused")
        #expect(
            !inlineScreenContains(target, rows: rows, cols: cols, "DIRECTTOOLRANHERE"),
            "the tool ran while the harness was already running a turn"
        )

        inputCont.yield(inlineBytes("\u{1b}"))
        let interrupted = await inlineWaitUntil {
            inlineScreenContains(target, rows: rows, cols: cols, "interrupted")
        }
        #expect(interrupted, "Escape did not abort the hanging turn")

        inputCont.finish()
        try await runTask.value
    }

    // MARK: The grammar the two paths share

    /// `slashName` is what decides, synchronously and before anything is consumed,
    /// whether a submitted line is even a candidate for the direct path. It has to
    /// agree exactly with `PromptCommandProcessor`'s own reading of the same line —
    /// a disagreement is a line refused as busy on one path and expanded as a
    /// prompt on the other.
    @Test
    func slashNameReadsTheSameTokenTheResolverDoes() {
        #expect(InteractiveCoordinator.slashName(in: "/read notes.txt") == "read")
        #expect(InteractiveCoordinator.slashName(in: "  /read  notes.txt  ") == "read")
        #expect(InteractiveCoordinator.slashName(in: "/read") == "read")
        // Case is preserved, because tools are matched case-SENSITIVELY: `/Read`
        // must remain a typo rather than quietly becoming `read`.
        #expect(InteractiveCoordinator.slashName(in: "/Read x") == "Read")
        #expect(InteractiveCoordinator.slashName(in: "read notes.txt") == nil)
        #expect(InteractiveCoordinator.slashName(in: "/") == nil)
        #expect(InteractiveCoordinator.slashName(in: "/ read") == nil)
        #expect(InteractiveCoordinator.slashName(in: "") == nil)
        #expect(InteractiveCoordinator.slashName(in: "please /read this") == nil)
    }
}
