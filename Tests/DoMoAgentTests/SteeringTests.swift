import DoMoAgent
import DoMoCore
import DoMoLLM
import Synchronization
import Testing

extension AgentRunResult {
    var userTexts: [String] {
        messages.compactMap { if case .user(let message) = $0 { message.text } else { nil } }
    }
}

// MARK: - Steering

@Test func steeringMessageInjectedAtTurnStart() async {
    // Steering is polled once before the run and after every turn. Deliver it
    // only on the poll that follows the first turn, so it lands between turn 1
    // and turn 2.
    let pollCount = Box(0)
    let steering: @Sendable () async -> [Message] = {
        let n = pollCount.withLock { $0 += 1; return $0 }
        return n == 2 ? [.user("steer")] : []
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(text: "first", stopReason: .stop),
        assistantTurn(text: "second", stopReason: .stop),
    ])

    let result = await runOnce(
        config: AgentLoopConfig(model: "m", getSteeringMessages: steering),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.userTexts == ["go", "steer"])
    #expect(result.assistantMessages.map(\.text) == ["first", "second"])
}

@Test func steeringPolledInitiallyIsInjectedBeforeFirstResponse() async {
    let pollCount = Box(0)
    let steering: @Sendable () async -> [Message] = {
        let n = pollCount.withLock { $0 += 1; return $0 }
        return n == 1 ? [.user("preface")] : []
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "hi", stopReason: .stop)])

    let result = await runOnce(
        config: AgentLoopConfig(model: "m", getSteeringMessages: steering),
        sink: sink,
        streamFn: stream.fn
    )

    // The preface is injected in the first (prompt) turn, after the prompt.
    #expect(result.userTexts == ["go", "preface"])
}

// MARK: - Follow-up

@Test func followUpResumesAWouldStopLoop() async {
    let delivered = Box(false)
    let followUp: @Sendable () async -> [Message] = {
        let already = delivered.withLock { current -> Bool in
            let was = current
            current = true
            return was
        }
        return already ? [] : [.user("more")]
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(text: "first", stopReason: .stop),
        assistantTurn(text: "second", stopReason: .stop),
    ])

    let result = await runOnce(
        config: AgentLoopConfig(model: "m", getFollowUpMessages: followUp),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.userTexts == ["go", "more"])
    #expect(result.assistantMessages.map(\.text) == ["first", "second"])
}

@Test func terminatingBatchThenFollowUpCompletesCleanly() async {
    // A tool terminates on turn 1, but a follow-up resumes the loop and turn 2
    // finishes cleanly with no tool calls. The final stop reason must reflect
    // the last turn (`.completed`), not the earlier terminating batch — the
    // `lastBatchTerminated` flag must not go stale across the resume.
    let terminating = FakeTool("stop") { _ in
        AgentToolResult(output: "stopping", terminate: true)
    }
    let delivered = Box(false)
    let followUp: @Sendable () async -> [Message] = {
        let already = delivered.withLock { current -> Bool in
            let was = current
            current = true
            return was
        }
        return already ? [] : [.user("more")]
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("stop")], stopReason: .toolUse),
        assistantTurn(text: "all done", stopReason: .stop),
    ])

    let result = await runOnce(
        context: AgentContext(tools: [terminating]),
        config: AgentLoopConfig(model: "m", getFollowUpMessages: followUp),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.assistantMessages.last?.text == "all done")
    #expect(result.stopReason == .completed)
}

@Test func noFollowUpEndsTheRun() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "only", stopReason: .stop)])

    let result = await runOnce(
        config: AgentLoopConfig(model: "m", getFollowUpMessages: { [] }),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 1)
}

// MARK: - shouldStopAfterTurn

@Test func shouldStopAfterTurnEndsRunBeforePollingQueues() async {
    let steeringPolls = Box(0)
    let sink = RecordingSink()
    // Two turns are scripted, but the hook stops after the first.
    let stream = ScriptedStream([
        assistantTurn(text: "first", stopReason: .stop),
        assistantTurn(text: "second", stopReason: .stop),
    ])
    let config = AgentLoopConfig(
        model: "m",
        getSteeringMessages: {
            steeringPolls.withLock { $0 += 1 }
            return []
        },
        shouldStopAfterTurn: { _ in true }
    )

    let result = await runOnce(config: config, sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .stoppedByHook)
    #expect(result.assistantMessages.map(\.text) == ["first"])
    // Only the initial pre-loop poll happened; the hook exits before the
    // post-turn steering poll.
    #expect(steeringPolls.value == 1)
}

@Test func shouldStopAfterTurnReceivesTheTurnData() async {
    let observed = Box<[String]>([])
    let tool = echoTool("t")
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(text: "hi", toolCalls: [tc("t")], stopReason: .toolUse)])
    let config = AgentLoopConfig(
        model: "m",
        shouldStopAfterTurn: { turn in
            observed.withLock { $0.append("\(turn.message.text)|\(turn.toolResults.count)") }
            return true
        }
    )

    _ = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(observed.value == ["hi|1"])
}

// MARK: - Cancellation

@Test func cancellationDuringToolExecutionProducesAbortedResult() async {
    let started = Latch()
    let hang = FakeTool("hang") { _ in
        started.open()
        while !Task.isCancelled { await Task.yield() }
        throw DoMoError(.cancelled, "cancelled")
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("hang")], stopReason: .toolUse)])

    let task = Task { await runOnce(context: AgentContext(tools: [hang]), sink: sink, streamFn: stream.fn) }
    await started.wait()
    task.cancel()
    let result = await task.value

    #expect(result.stopReason == .aborted)
    #expect(result.toolResults.contains { $0.isError && $0.output.contains("aborted") })
    // A synthesized aborted assistant message closes the transcript.
    #expect(result.assistantMessages.last?.stopReason == .aborted)
    // agent_end is still the final emitted event — no CancellationError escaped.
    #expect(sink.kinds.last == "agentEnd")
}

@Test func cancellationDuringStreamProducesAbortedMessage() async {
    let started = Latch()
    let streamFn: AgentStreamFn = { _ in
        AsyncThrowingStream { continuation in
            let producer = Task {
                continuation.yield(.start(AssistantSnapshot(model: "m")))
                started.open()
                while !Task.isCancelled { await Task.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    let sink = RecordingSink()

    let task = Task { await runOnce(sink: sink, streamFn: streamFn) }
    await started.wait()
    task.cancel()
    let result = await task.value

    #expect(result.stopReason == .aborted)
    #expect(result.assistantMessages.last?.stopReason == .aborted)
    #expect(sink.kinds.last == "agentEnd")
}

// MARK: - Sink backpressure

/// A sink that fails the test if two emissions are ever in flight at once.
final class BackpressureSink: AgentEventSink {
    private struct State {
        var events: [AgentEvent] = []
        var active = 0
        var overlapped = false
    }
    private let state = Mutex(State())

    func emit(_ event: AgentEvent) async {
        state.withLock { current in
            current.active += 1
            if current.active > 1 { current.overlapped = true }
        }
        // Suspend so a concurrent emitter, if any existed, would overlap here.
        await Task.yield()
        state.withLock { current in
            current.active -= 1
            current.events.append(event)
        }
    }

    var overlapped: Bool { state.withLock { $0.overlapped } }
    var kinds: [String] { state.withLock { $0.events.map(\.kind) } }
}

@Test func sinkEmissionsAreSerializedEvenDuringParallelTools() async {
    let sink = BackpressureSink()
    let tools: [any AgentTool] = [echoTool("a"), echoTool("b"), echoTool("c")]
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("a"), tc("b"), tc("c")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    _ = await runAgentLoop(
        prompts: [.user("go")],
        context: AgentContext(tools: tools),
        config: AgentLoopConfig(model: "m", toolExecution: .parallel),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(sink.overlapped == false)
    #expect(sink.kinds.first == "agentStart")
    #expect(sink.kinds.last == "agentEnd")
}
