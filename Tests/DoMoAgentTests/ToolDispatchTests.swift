import DoMoAgent
import DoMoCore
import DoMoLLM
import Synchronization
import Testing

// MARK: - Ordering

@Test func parallelEmitsEndsInCompletionOrderButAppendsInSourceOrder() async {
    // Source order is [slow, fast]. `slow` blocks on a gate that `fast` opens, so
    // `fast` finishes first — completion order [fast, slow] must differ from the
    // transcript's source order [slow, fast].
    let gate = Latch()
    let slow = FakeTool("slow") { _ in
        await gate.wait()
        // Extra yields make it deterministic that `fast` returns to the group first.
        for _ in 0..<50 { await Task.yield() }
        return AgentToolResult(output: "slow ok")
    }
    let fast = FakeTool("fast") { _ in
        gate.open()
        return AgentToolResult(output: "fast ok")
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("slow"), tc("fast")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(
        context: AgentContext(tools: [slow, fast]),
        config: AgentLoopConfig(model: "m", toolExecution: .parallel),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(sink.toolEndOrder == ["fast", "slow"])  // completion order
    #expect(result.toolResults.map(\.toolName) == ["slow", "fast"])  // source order
}

@Test func sequentialRunsInSourceOrder() async {
    let order = Box<[String]>([])
    func recording(_ name: String) -> FakeTool {
        FakeTool(name) { _ in
            order.withLock { $0.append(name) }
            return AgentToolResult(output: "\(name) ok")
        }
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("a"), tc("b"), tc("c")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(
        context: AgentContext(tools: [recording("a"), recording("b"), recording("c")]),
        config: AgentLoopConfig(model: "m", toolExecution: .sequential),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(order.value == ["a", "b", "c"])
    #expect(sink.toolEndOrder == ["a", "b", "c"])
    #expect(result.toolResults.map(\.toolName) == ["a", "b", "c"])
}

@Test func oneSequentialToolForcesTheWholeBatchSequential() async {
    // Even under the default parallel mode, a tool declaring `.sequential`
    // serializes the batch — pi's `hasSequentialToolCall`.
    let active = Box(0)
    let maxActive = Box(0)
    func tool(_ name: String, mode: ToolExecutionMode?) -> FakeTool {
        FakeTool(name, executionMode: mode) { _ in
            let now = active.withLock { count -> Int in
                count += 1
                return count
            }
            maxActive.withLock { peak in peak = max(peak, now) }
            for _ in 0..<20 { await Task.yield() }
            active.withLock { count in count -= 1 }
            return AgentToolResult(output: "\(name) ok")
        }
    }
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("x"), tc("y")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    _ = await runOnce(
        context: AgentContext(tools: [tool("x", mode: .sequential), tool("y", mode: nil)]),
        config: AgentLoopConfig(model: "m", toolExecution: .parallel),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(maxActive.value == 1)
}

// MARK: - Truncated-tool-call refusal

@Test func lengthStopRefusesAllToolCallsWithoutExecuting() async {
    let ran = Box(0)
    let tool = echoTool("write", ran: ran)
    let sink = RecordingSink()
    // The assistant message carries a tool call AND stopReason .length.
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("write")], stopReason: .length),
        assistantTurn(text: "retried", stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: [tool]), sink: sink, streamFn: stream.fn)

    #expect(ran.value == 0)  // the tool never executed
    #expect(result.toolResults.first?.isError == true)
    #expect(result.toolResults.first?.output.contains("output token limit") == true)
    // The run still resolves normally: the model gets a chance to re-issue.
    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.last?.text == "retried")
}

@Test func truncatedArgumentFragmentReportsIncompleteViaTheRightSignal() {
    // The signal behind the `.length` refusal: a fragment cut mid-object parses
    // back — repaired — but is NOT reported complete. This is exactly why the
    // repaired `ToolCallBlock.arguments` cannot be trusted.
    let complete = PartialJSON.parseStreaming(#"{"path":"a.txt"}"#)
    let truncated = PartialJSON.parseStreaming(#"{"path":"a.tx"#)
    #expect(complete.completeness == .complete)
    #expect(truncated.completeness != .complete)
}

// MARK: - Before hook

@Test func beforeHookRejectBlocksExecution() async {
    let ran = Box(0)
    let tool = echoTool("danger", ran: ran)
    let sink = RecordingSink()
    let config = AgentLoopConfig(
        model: "m",
        beforeToolCall: { _ in .reject("not allowed") }
    )
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("danger")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(ran.value == 0)
    #expect(result.toolResults.first?.isError == true)
    #expect(result.toolResults.first?.output == "not allowed")
}

@Test func beforeHookRewritesArguments() async {
    let seen = Box<JSONValue>(.null)
    let tool = FakeTool("echo") { arguments in
        seen.withLock { $0 = arguments }
        return AgentToolResult(output: "ok")
    }
    let sink = RecordingSink()
    let config = AgentLoopConfig(
        model: "m",
        beforeToolCall: { _ in .rewrite(.object(["injected": .bool(true)])) }
    )
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("echo", arguments: .object(["original": .bool(true)]))], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    _ = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(seen.value == .object(["injected": .bool(true)]))
}

@Test func beforeHookProceedLeavesArgumentsUntouched() async {
    let seen = Box<JSONValue>(.null)
    let tool = FakeTool("echo") { arguments in
        seen.withLock { $0 = arguments }
        return AgentToolResult(output: "ok")
    }
    let sink = RecordingSink()
    let config = AgentLoopConfig(model: "m", beforeToolCall: { _ in .proceed })
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("echo", arguments: .object(["kept": .int(1)]))], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    _ = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(seen.value == .object(["kept": .int(1)]))
}

// MARK: - After hook

@Test func afterHookTransformsResult() async {
    let tool = FakeTool("t") { _ in
        AgentToolResult(output: "raw", isError: false, terminate: false, details: .string("original"))
    }
    let sink = RecordingSink()
    let config = AgentLoopConfig(
        model: "m",
        afterToolCall: { _ in
            AfterToolCallResult(output: .set("transformed"), isError: .set(true))
        }
    )
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("t")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(result.toolResults.first?.output == "transformed")
    #expect(result.toolResults.first?.isError == true)
}

@Test func afterHookKeepDistinctFromClear() async {
    // `.keep` preserves details; `.set(.null)` explicitly clears them — the
    // distinction pi's `??` merge cannot express.
    let capturedDetails = Box<[JSONValue]>([])
    let tool = FakeTool("t") { _ in
        AgentToolResult(output: "out", details: .string("keepme"))
    }

    func runWith(_ patch: Patch<JSONValue>) async {
        let sink = RecordingSink()
        let config = AgentLoopConfig(
            model: "m",
            afterToolCall: { _ in AfterToolCallResult(details: patch) }
        )
        let stream = ScriptedStream([
            assistantTurn(toolCalls: [tc("t")], stopReason: .toolUse),
            assistantTurn(stopReason: .stop),
        ])
        _ = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)
        for event in sink.events {
            if case .toolExecutionEnd(_, _, let result, _) = event {
                capturedDetails.withLock { $0.append(result.details) }
            }
        }
    }

    await runWith(.keep)
    await runWith(.set(.null))

    #expect(capturedDetails.value == [.string("keepme"), .null])
}

@Test func afterHookTerminateOverrideEndsRun() async {
    let tool = FakeTool("t") { _ in AgentToolResult(output: "ok") }
    let sink = RecordingSink()
    let config = AgentLoopConfig(
        model: "m",
        afterToolCall: { _ in AfterToolCallResult(terminate: .set(true)) }
    )
    let stream = ScriptedStream([assistantTurn(toolCalls: [tc("t")], stopReason: .toolUse)])

    let result = await runOnce(context: AgentContext(tools: [tool]), config: config, sink: sink, streamFn: stream.fn)

    #expect(result.stopReason == .terminatedByTool)
}

// MARK: - Unknown tool

@Test func unknownToolNameIsAnErrorResult() async {
    let sink = RecordingSink()
    let stream = ScriptedStream([
        assistantTurn(toolCalls: [tc("ghost")], stopReason: .toolUse),
        assistantTurn(stopReason: .stop),
    ])

    let result = await runOnce(context: AgentContext(tools: []), sink: sink, streamFn: stream.fn)

    #expect(result.toolResults.first?.isError == true)
    #expect(result.toolResults.first?.output.contains("ghost") == true)
    #expect(result.stopReason == .completed)
}
