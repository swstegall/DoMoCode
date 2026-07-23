import DoMoAgent
import DoMoCore
import DoMoLLM
import Synchronization
import Testing

// MARK: - Shared test support

/// A `Sendable` mutable cell for recording from inside `@Sendable` tool closures
/// without threading an actor through every fake.
final class Box<T: Sendable>: Sendable {
    private let storage: Mutex<T>
    init(_ value: T) { storage = Mutex(value) }
    var value: T { storage.withLock { $0 } }
    func withLock<R>(_ body: (inout sending T) -> sending R) -> sending R { storage.withLock(body) }
}

/// An async, one-shot gate. Opening it releases every current and future waiter.
/// Built on a `Mutex` and `CheckedContinuation`; the lock is never held across a
/// resume.
final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.open = true
            let pending = current.waiters
            current.waiters = []
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        if state.withLock({ $0.open }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { current -> Bool in
                if current.open { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Records every emitted event in arrival order, under a lock.
final class RecordingSink: AgentEventSink {
    private let storage = Mutex<[AgentEvent]>([])
    func emit(_ event: AgentEvent) async { storage.withLock { $0.append(event) } }
    var events: [AgentEvent] { storage.withLock { $0 } }
    var kinds: [String] { events.map(\.kind) }
    /// Tool names in `toolExecutionEnd` (completion) order.
    var toolEndOrder: [String] {
        events.compactMap { if case .toolExecutionEnd(_, let name, _, _) = $0 { name } else { nil } }
    }
}

/// A stream function that replays a canned script per call, one script per turn.
final class ScriptedStream: Sendable {
    private let scripts: Mutex<[[AssemblyEvent]]>
    init(_ scripts: [[AssemblyEvent]]) { self.scripts = Mutex(scripts) }

    var fn: AgentStreamFn {
        { [self] _ in
            let script = scripts.withLock { current -> [AssemblyEvent] in
                current.isEmpty ? [] : current.removeFirst()
            }
            return AsyncThrowingStream { continuation in
                for event in script { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

/// Builds the minimal event script for one assistant turn.
func assistantTurn(
    text: String? = nil,
    toolCalls: [ToolCallBlock] = [],
    stopReason: StopReason,
    model: String = "test-model"
) -> [AssemblyEvent] {
    var content: [ContentBlock] = []
    if let text { content.append(.text(text)) }
    for call in toolCalls { content.append(.toolCall(call)) }
    let message = AssistantMessage(content: content, model: model, stopReason: stopReason)
    let terminal: AssemblyEvent = message.failure == nil ? .done(message) : .failed(message)
    return [.start(AssistantSnapshot(model: model)), terminal]
}

func tc(_ name: String, id: String? = nil, arguments: JSONValue = .object([:])) -> ToolCallBlock {
    ToolCallBlock(id: id ?? "\(name)-id", name: name, arguments: arguments)
}

/// A configurable fake tool whose behavior is a closure.
///
/// The closure is untyped-`throws` (not `throws(DoMoError)`): a multi-statement
/// closure does not reliably infer a typed thrown type from a typed-throws
/// parameter, so `execute` converts at the boundary — the same pattern the
/// built-in tools use.
struct FakeTool: AgentTool {
    let definition: ToolDefinition
    let executionMode: ToolExecutionMode?
    private let body: @Sendable (JSONValue) async throws -> AgentToolResult

    init(
        _ name: String,
        executionMode: ToolExecutionMode? = nil,
        body: @escaping @Sendable (JSONValue) async throws -> AgentToolResult
    ) {
        self.definition = ToolDefinition(name: name, description: name, parameters: JSONSchema())
        self.executionMode = executionMode
        self.body = body
    }

    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        do {
            return try await body(arguments)
        } catch let error as DoMoError {
            throw error
        } catch {
            throw DoMoError(wrapping: error, as: .toolExecution(tool: definition.name), "fake tool threw")
        }
    }
}

/// A tool that just echoes its name, recording that it ran.
func echoTool(_ name: String, executionMode: ToolExecutionMode? = nil, ran: Box<Int>? = nil) -> FakeTool {
    FakeTool(name, executionMode: executionMode) { _ in
        ran?.withLock { $0 += 1 }
        return AgentToolResult(output: "\(name) ok")
    }
}

extension AgentEvent {
    /// A compact label for order assertions.
    var kind: String {
        switch self {
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .turnStart: "turnStart"
        case .turnEnd: "turnEnd"
        case .messageStart(let message): "messageStart(\(message.role.rawValue))"
        case .messageUpdate: "messageUpdate"
        case .messageEnd(let message): "messageEnd(\(message.role.rawValue))"
        case .toolExecutionStart(_, let name, _): "toolStart(\(name))"
        case .toolExecutionEnd(_, let name, _, _): "toolEnd(\(name))"
        }
    }
}

extension AgentRunResult {
    var toolResults: [ToolResultBlock] {
        messages.compactMap { if case .tool(let block) = $0 { block } else { nil } }
    }
    var assistantMessages: [AssistantMessage] {
        messages.compactMap { if case .assistant(let message) = $0 { message } else { nil } }
    }
}

func runOnce(
    prompt: String = "go",
    context: AgentContext = AgentContext(),
    config: AgentLoopConfig = AgentLoopConfig(model: "test-model"),
    sink: any AgentEventSink,
    streamFn: AgentStreamFn
) async -> AgentRunResult {
    await runAgentLoop(
        prompts: [.user(prompt)],
        context: context,
        config: config,
        sink: sink,
        streamFn: streamFn
    )
}

// MARK: - Turn loop

@Test func singleTurnNoToolCallsCompletes() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "hello", stopReason: .stop)])

    let result = await runOnce(sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 1)
    #expect(result.assistantMessages.first?.text == "hello")
    #expect(
        sink.kinds == [
            "agentStart", "turnStart",
            "messageStart(user)", "messageEnd(user)",
            "messageStart(assistant)", "messageEnd(assistant)",
            "turnEnd", "agentEnd",
        ]
    )
}

@Test func oneToolCallThenStop() async {
    let ran = Box(0)
    let tool = echoTool("read", ran: ran)
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("read")], stopReason: .toolUse),
        assistantTurn(text: "done", stopReason: .stop),
    ])

    let result = await runOnce(
        context: AgentContext(tools: [tool]),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(ran.value == 1)
    #expect(result.toolResults.map(\.toolName) == ["read"])
    #expect(result.toolResults.first?.output == "read ok")
    // Two turns: the second gets an explicit turnStart.
    #expect(sink.kinds.filter { $0 == "turnStart" }.count == 2)
}

@Test func manyToolCallsAppendInSourceOrder() async {
    let tools: [any AgentTool] = [echoTool("a"), echoTool("b"), echoTool("c")]
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("a"), tc("b"), tc("c")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: tools), sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .completed)
    #expect(result.toolResults.map(\.toolName) == ["a", "b", "c"])
}

@Test func toolErrorBecomesErrorResultAndLoopContinues() async {
    let failing = FakeTool("boom") { _ in
        AgentToolResult(output: "it failed", isError: true)
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("boom")], stopReason: .toolUse),
        assistantTurn(text: "recovered", stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: [failing]), sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .completed)
    #expect(result.toolResults.first?.isError == true)
    #expect(result.toolResults.first?.output == "it failed")
    #expect(result.assistantMessages.last?.text == "recovered")
}

@Test func errorStopReasonEndsRun() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "", stopReason: .error)])

    let result = await runOnce(sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .errored)
    // Well-formed transcript: exactly one assistant message, no dangling tool calls.
    #expect(result.assistantMessages.count == 1)
    #expect(result.assistantMessages.first?.stopReason == .error)
    #expect(sink.kinds.last == "agentEnd")
    #expect(sink.kinds.contains("turnEnd"))
}

@Test func streamThrowingBecomesErroredRun() async {
    let sink = RecordingSink()
    let throwingFn: AgentStreamFn = { _ in
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DoMoError(.transport, "socket hang up"))
        }
    }

    let result = await runOnce(sink: sink, streamFn: throwingFn)

    #expect(result.stopReason == .errored)
    #expect(result.assistantMessages.first?.stopReason == .error)
    #expect(result.assistantMessages.first?.errorMessage?.contains("socket hang up") == true)
}

@Test func streamEndingWithoutTerminalIsErrored() async {
    let sink = RecordingSink()
    let emptyFn: AgentStreamFn = { _ in
        AsyncThrowingStream { $0.finish() }
    }

    let result = await runOnce(sink: sink, streamFn: emptyFn)

    #expect(result.stopReason == .errored)
    #expect(result.assistantMessages.first?.stopReason == .error)
}

@Test func maxTurnsBoundsTheRun() async {
    // Every turn requests a tool, so without a bound the loop never stops.
    let tool = echoTool("loop")
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse),
        assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse),
        assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse),
        assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse),
        assistantTurn(toolCalls: [tc("loop")], stopReason: .toolUse),
    ])

    let result = await runOnce(
        context: AgentContext(tools: [tool]),
        config: AgentLoopConfig(model: "test-model", maxTurns: 3),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .maxTurnsReached)
    #expect(result.assistantMessages.count == 3)
}

@Test func toolTerminateHintEndsRun() async {
    let terminating = FakeTool("stop") { _ in
        AgentToolResult(output: "stopping", terminate: true)
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("stop")], stopReason: .toolUse)])

    let result = await runOnce(context: AgentContext(tools: [terminating]), sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .terminatedByTool)
    #expect(result.toolResults.first?.output == "stopping")
}

@Test func preExistingContextIsNotReturnedButIsSentToModel() async {
    let seenMessageCount = Box(0)
    let countingFn: AgentStreamFn = { context in
        seenMessageCount.withLock { $0 = context.messages.count }
        return AsyncThrowingStream { continuation in
            for event in assistantTurn(text: "hi", stopReason: .stop) { continuation.yield(event) }
            continuation.finish()
        }
    }
    let sink = RecordingSink()
    let context = AgentContext(messages: [.user("earlier"), .assistant(AssistantMessage(model: "m"))])

    let result = await runAgentLoop(
        prompts: [.user("now")],
        context: context,
        config: AgentLoopConfig(model: "m"),
        sink: sink,
        streamFn: countingFn
    )

    // Model saw pre-existing 2 + prompt 1 = 3 messages.
    #expect(seenMessageCount.value == 3)
    // Returned messages are only this run's: prompt + assistant.
    #expect(result.messages.count == 2)
}
