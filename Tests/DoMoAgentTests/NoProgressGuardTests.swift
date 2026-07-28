// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The runaway guard that replaces the turn limit. `--max-turns` is becoming
// unlimited by default, so this is now the only thing standing between a stuck
// model and an unbounded run. Two properties matter and both are pinned here:
//
//  1. It fires on genuine non-progress — `noProgressLimit` consecutive turns
//     that made the SAME tool calls and got the SAME results — at exactly the
//     limit, not one turn early or late.
//  2. It is INCAPABLE of firing on varied work, however long that work runs.
//     A guard that could stop a legitimate 200-turn refactor would be worse
//     than the cap it replaces, because it would be trusted.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation
import Testing

// MARK: - Support

/// A tool whose output never changes, however many times it is called — the
/// shape a stuck model produces (a failing read, a rejected write, a command
/// that errors the same way every time).
private func constantTool(_ name: String, output: String = "same answer", isError: Bool = false) -> FakeTool {
    FakeTool(name) { _ in AgentToolResult(output: output, isError: isError) }
}

/// A tool whose output changes on every call, so identical CALLS still produce
/// distinguishable turns — a legitimate poll whose answer keeps moving.
private func countingTool(_ name: String) -> FakeTool {
    let calls = Box(0)
    return FakeTool(name) { _ in
        let n = calls.withLock { current -> Int in
            current += 1
            return current
        }
        return AgentToolResult(output: "answer \(n)")
    }
}

/// `count` turns that each issue the identical tool call, with a FRESH call id
/// per turn — which is what real providers do. If the signature kept ids, the
/// guard would never fire in production, so every loop test here varies them.
private func stuckTurns(
    _ count: Int,
    tool: String = "stuck",
    arguments: JSONValue = .object(["path": .string("/nope")])
) -> [[AssemblyEvent]] {
    (0..<count).map { index in
        assistantTurn(
            text: "attempt \(index)",
            toolCalls: [tc(tool, id: "call-\(index)", arguments: arguments)],
            stopReason: .toolUse
        )
    }
}

/// Decodes JSON text so key ORDER is the one the provider actually sent, rather
/// than whatever a Swift dictionary literal happens to hash to.
private func decodedJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func finalTextTurn(_ text: String = "done") -> [AssemblyEvent] {
    assistantTurn(text: text, stopReason: .stop)
}

// MARK: - It fires on genuine non-progress

@Test func noProgressStopsAnIdenticalFailingToolLoop() async {
    let sink = RecordingSink()
    // Far more script than the guard should ever consume.
    let stream = ScriptedStream(stuckTurns(30) + [finalTextTurn()])

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck", output: "no such file", isError: true)]),
        config: AgentLoopConfig(model: "test-model", maxTurns: nil, noProgressLimit: 5),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 5)
    #expect(result.toolResults.count == 5)
}

@Test func noProgressSettlesOnlyAfterTheLastTurnIsFullyEmitted() async {
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(10))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 3),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    // The turn the user can see must be complete before the run settles.
    #expect(Array(sink.kinds.suffix(2)) == ["turnEnd", "agentEnd"])
    #expect(sink.kinds.filter { $0 == "turnStart" }.count == 3)
    #expect(sink.kinds.filter { $0 == "turnEnd" }.count == 3)
    #expect(sink.toolEndOrder.count == 3)
}

@Test func noProgressFiresWhenOnlyTheToolCallIDsDiffer() async {
    // The realistic case: a provider mints a new `toolCallId` every turn. If the
    // signature counted ids, no real loop would ever be caught.
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(20))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 4),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 4)
}

@Test func noProgressIgnoresChangingAssistantTextAroundTheSameToolCall() async {
    // Narrating differently while doing exactly the same thing is not progress.
    let sink = RecordingSink()
    let scripts = (0..<12).map { index in
        assistantTurn(
            text: "let me try again, take \(index)",
            toolCalls: [tc("stuck", id: "call-\(index)", arguments: .object(["q": .int(1)]))],
            stopReason: .toolUse
        )
    }
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 6),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 6)
}

// MARK: - The boundary is exact

@Test(arguments: [2, 3, 5, 12])
func noProgressStopsAtExactlyTheLimit(limit: Int) async {
    // limit - 1 identical turns then a final answer: the guard must NOT fire.
    let underSink = RecordingSink()
    let under = ScriptedStream(stuckTurns(limit - 1) + [finalTextTurn()])
    let underResult = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: limit),
        sink: underSink,
        streamFn: under.fn
    )
    #expect(underResult.stopReason == .completed)
    #expect(underResult.assistantMessages.count == limit)

    // limit identical turns: the guard fires on the limit-th, and the final
    // answer that follows in the script is never requested.
    let atSink = RecordingSink()
    let at = ScriptedStream(stuckTurns(limit) + [finalTextTurn()])
    let atResult = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: limit),
        sink: atSink,
        streamFn: at.fn
    )
    #expect(atResult.stopReason == .noProgress)
    #expect(atResult.assistantMessages.count == limit)
    #expect(atResult.assistantMessages.last?.text != "done")
}

// MARK: - It cannot fire on varied work

@Test func variedArgumentsRunFarPastTheLimitUntouched() async {
    // 40 turns of genuinely different work with the guard set to 3. This is the
    // long-refactor case: it must be untouchable.
    let sink = RecordingSink()
    let scripts =
        (0..<40).map { index in
            assistantTurn(
                toolCalls: [tc("work", id: "call-\(index)", arguments: .object(["step": .int(index)]))],
                stopReason: .toolUse
            )
        } + [finalTextTurn()]
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("work")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: nil, noProgressLimit: 3),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 41)
    #expect(result.toolResults.count == 40)
}

@Test func identicalCallsWithMovingResultsAreProgress() async {
    // A poll whose answer keeps changing is work, not a loop — which is exactly
    // why the signature includes tool OUTPUT and not just the call.
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30, tool: "poll") + [finalTextTurn()])

    let result = await runOnce(
        context: AgentContext(tools: [countingTool("poll")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: nil, noProgressLimit: 4),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 31)
}

@Test func aChangedTurnResetsTheStreak() async {
    // 4 identical, 1 different, 4 identical, then an answer — with the guard at
    // 5, nothing may fire, because neither streak ever reached 5.
    let sink = RecordingSink()
    let stuck = JSONValue.object(["path": .string("/nope")])
    let scripts =
        stuckTurns(4, arguments: stuck)
        + [
            assistantTurn(
                toolCalls: [tc("stuck", id: "call-different", arguments: .object(["path": .string("/other")]))],
                stopReason: .toolUse
            )
        ]
        + stuckTurns(4, arguments: stuck)
        + [finalTextTurn()]
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 5),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 10)
}

@Test func aSecondCallInTheBatchMakesTheTurnDifferent() async {
    // Same first call, one extra call appended: not the same turn.
    let sink = RecordingSink()
    let scripts =
        (0..<12).map { index -> [AssemblyEvent] in
            var calls = [tc("stuck", id: "a-\(index)", arguments: .object(["k": .int(1)]))]
            if index.isMultiple(of: 2) {
                calls.append(tc("stuck", id: "b-\(index)", arguments: .object(["k": .int(2)])))
            }
            return assistantTurn(toolCalls: calls, stopReason: .toolUse)
        } + [finalTextTurn()]
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 2),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 13)
}

// MARK: - Argument key order

@Test func argumentKeyOrderCannotDefeatTheGuard() async throws {
    // Providers stream tool arguments as JSON TEXT; the same object can arrive
    // with its keys in any order. Two spellings of the same arguments must be
    // one signature, or the guard is trivially defeated by a reordering model.
    let forward = try decodedJSON(#"{"path":"/nope","limit":10,"deep":{"a":1,"b":2}}"#)
    let reversed = try decodedJSON(#"{"deep":{"b":2,"a":1},"limit":10,"path":"/nope"}"#)
    #expect(forward == reversed)

    let sink = RecordingSink()
    let scripts = (0..<12).map { index in
        assistantTurn(
            toolCalls: [
                tc("stuck", id: "call-\(index)", arguments: index.isMultiple(of: 2) ? forward : reversed)
            ],
            stopReason: .toolUse
        )
    }
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 4),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 4)
}

// MARK: - The default is live

@Test func theDefaultLimitIsLiveWithoutBeingAskedFor() async {
    // The headline effect of this wave: `--max-turns` becomes unlimited, so the
    // DEFAULT `noProgressLimit` is the only thing bounding a stuck run. Every
    // other test here names a limit explicitly, which pins the mechanism but not
    // the value that actually ships. A config that names no limit must still be
    // guarded, and at 12.
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(40))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model"),  // no noProgressLimit:
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 12)
}

// MARK: - Turning it off

@Test func nilNoProgressLimitDisablesTheGuardEntirely() async {
    // The two guards are independent: with the detector off, only `maxTurns`
    // can end this run.
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: 8, noProgressLimit: nil),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .maxTurnsReached)
    #expect(result.assistantMessages.count == 8)
}

@Test(arguments: [0, 1, -1])
func aLimitBelowTwoIsClampedToTwoRatherThanDisablingTheGuard(limit: Int) async {
    // One turn is not a repetition of anything, so a limit below 2 cannot be
    // honoured literally — "stop at the first tool call" would fire on perfectly
    // varied work. But this is the only bound on a run once `maxTurns` is nil, so
    // it must fail CLOSED: a nonsense or over-strict limit clamps UP to the
    // strictest meaningful value (2), never off. `nil` is the only disable.
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: 6, noProgressLimit: limit),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 2)
}

@Test func aClampedLimitStillCannotFireOnVariedWork() async {
    // Clamping up must not make the guard trigger-happy: even at its strictest,
    // two turns of DIFFERENT work are not a repetition.
    let sink = RecordingSink()
    let scripts =
        (0..<20).map { index in
            assistantTurn(
                toolCalls: [tc("work", id: "call-\(index)", arguments: .object(["step": .int(index)]))],
                stopReason: .toolUse
            )
        } + [finalTextTurn()]
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("work")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: nil, noProgressLimit: 1),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 21)
}

// MARK: - Turns with no tool calls

@Test func turnsWithNoToolCallsNeverCountAsRepetition() async {
    // A turn with no tool calls ends the inner loop unless steering or a
    // follow-up injected new work — i.e. unless something OUTSIDE the model
    // acted. That is a human or a host driving the run, not a model spinning,
    // so such turns clear the streak rather than counting toward it. With the
    // guard at 2, counting them would stop this run at turn 2.
    let remaining = Box(4)
    let steering: @Sendable () async -> [Message] = {
        let more = remaining.withLock { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        return more ? [.user("keep going")] : []
    }
    let sink = RecordingSink()
    let stream = ScriptedStream((0..<8).map { finalTextTurn("thought \($0)") })

    let result = await runOnce(
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 2, getSteeringMessages: steering),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.assistantMessages.count == 4)
}

@Test func aToolFreeTurnBetweenIdenticalTurnsBreaksTheStreak() async {
    // Same shape as above, but the model interleaves real (identical) tool work
    // with tool-free turns. The tool turns are identical and there are more than
    // `noProgressLimit` of them in the run — but never `noProgressLimit` in a
    // ROW, so the guard must stay silent.
    let remaining = Box(8)
    let steering: @Sendable () async -> [Message] = {
        let more = remaining.withLock { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        return more ? [.user("keep going")] : []
    }
    let sink = RecordingSink()
    let scripts = (0..<9).map { index -> [AssemblyEvent] in
        index.isMultiple(of: 2)
            ? assistantTurn(
                toolCalls: [tc("stuck", id: "call-\(index)", arguments: .object(["k": .int(1)]))],
                stopReason: .toolUse
            )
            : finalTextTurn("thinking \(index)")
    }
    let stream = ScriptedStream(scripts)

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 2, getSteeringMessages: steering),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .completed)
    #expect(result.toolResults.count >= 4)
}

@Test func steeringOnEveryTurnDoesNotBuyTheModelMoreRope() async {
    // The counterpart to the two tests above, and the case they leave uncovered:
    // a human typing a correction between EVERY pair of identical tool turns.
    // Steering is deliberately not a reset. A model that keeps making the same
    // call with the same result while being corrected is the stuck case, not the
    // exception to it — and if steering did reset the streak, any embedder that
    // injects a message every turn (a periodic status line, a nagging prompt)
    // would silently disable the only bound this run has.
    let steering: @Sendable () async -> [Message] = { [.user("stop doing that")] }
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 3, getSteeringMessages: steering),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 3)
}

// MARK: - Interaction with the other stop reasons

@Test func maxTurnsStillWinsWhenItComesFirst() async {
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(model: "test-model", maxTurns: 3, noProgressLimit: 10),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .maxTurnsReached)
    #expect(result.assistantMessages.count == 3)
}

@Test func aStopHookIsNotConsultedOnTheTurnThatTripsTheGuard() async {
    // The guard settles the run BEFORE `shouldStopAfterTurn` runs, so on the
    // turn that trips it the hook is never asked: the run is already decided and
    // `.noProgress` wins the reason over `.stoppedByHook`. Four turns run; the
    // hook sees the first three. Both numbers are asserted below so the
    // off-by-one is legible here rather than inferred from another test.
    let seen = Box(0)
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(30))

    let result = await runOnce(
        context: AgentContext(tools: [constantTool("stuck")]),
        config: AgentLoopConfig(
            model: "test-model",
            noProgressLimit: 4,
            shouldStopAfterTurn: { _ in
                seen.withLock { $0 += 1 }
                return false
            }
        ),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 4)
    #expect(seen.value == 3)
}

@Test func aTerminatingBatchBeatsTheGuardOnTheTurnThatWouldTripIt() async {
    // A `finish`/`submit`-style tool that reports the same output every time and
    // sets `terminate` when it decides to stop: `terminate` is not part of the
    // signature (it is not model-visible work), so the terminating turn looks
    // identical to the ones before it. The run ended the way it was asked to —
    // reporting `.noProgress` would flip print mode's exit code from 0 to 3.
    let calls = Box(0)
    let submit = FakeTool("submit") { _ in
        let n = calls.withLock { current -> Int in
            current += 1
            return current
        }
        return AgentToolResult(output: "working", terminate: n >= 4)
    }
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(10, tool: "submit"))

    let result = await runOnce(
        context: AgentContext(tools: [submit]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 4),
        sink: sink,
        streamFn: stream.fn
    )

    #expect(result.stopReason == .terminatedByTool)
    #expect(result.assistantMessages.count == 4)
}

@Test func aRunThatKeepsRepeatingAfterATerminatingTurnIsStillCaught() async {
    // The terminate exemption must not be a way to stay unbounded: a follow-up
    // that resumes the run past a terminating batch restarts the streak, and the
    // guard fires again on the next `limit` identical turns.
    let followUps = Box(1)
    let resume: @Sendable () async -> [Message] = {
        let more = followUps.withLock { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        return more ? [.user("keep going")] : []
    }
    let calls = Box(0)
    let submit = FakeTool("submit") { _ in
        let n = calls.withLock { current -> Int in
            current += 1
            return current
        }
        return AgentToolResult(output: "working", terminate: n == 2)
    }
    let sink = RecordingSink()
    let stream = ScriptedStream(stuckTurns(20, tool: "submit"))

    let result = await runOnce(
        context: AgentContext(tools: [submit]),
        config: AgentLoopConfig(model: "test-model", noProgressLimit: 3, getFollowUpMessages: resume),
        sink: sink,
        streamFn: stream.fn
    )

    // Turns 1-2 run (2 terminates), the follow-up resumes, turns 3-5 repeat and
    // the guard fires on the third of those.
    #expect(result.stopReason == .noProgress)
    #expect(result.assistantMessages.count == 5)
}

// MARK: - The signature itself

@Test func turnSignatureDistinguishesArgumentsOutputsAndErrors() {
    let base = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "read", arguments: .object(["path": .string("a")]))],
        results: [ToolResultBlock(toolCallID: "1", toolName: "read", output: "x", isError: false)]
    )

    let differentArguments = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "read", arguments: .object(["path": .string("b")]))],
        results: [ToolResultBlock(toolCallID: "1", toolName: "read", output: "x", isError: false)]
    )
    let differentName = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "write", arguments: .object(["path": .string("a")]))],
        results: [ToolResultBlock(toolCallID: "1", toolName: "read", output: "x", isError: false)]
    )
    let differentOutput = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "read", arguments: .object(["path": .string("a")]))],
        results: [ToolResultBlock(toolCallID: "1", toolName: "read", output: "y", isError: false)]
    )
    let differentErrorFlag = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "read", arguments: .object(["path": .string("a")]))],
        results: [ToolResultBlock(toolCallID: "1", toolName: "read", output: "x", isError: true)]
    )

    #expect(base != differentArguments)
    #expect(base != differentName)
    #expect(base != differentOutput)
    #expect(base != differentErrorFlag)
}

@Test func turnSignatureIgnoresCallIDsAndRespectsOrder() {
    let first = TurnToolSignature(
        calls: [
            ToolCallBlock(id: "call_abc", name: "read", arguments: .object(["path": .string("a")])),
            ToolCallBlock(id: "call_def", name: "read", arguments: .object(["path": .string("b")])),
        ],
        results: [
            ToolResultBlock(toolCallID: "call_abc", toolName: "read", output: "1"),
            ToolResultBlock(toolCallID: "call_def", toolName: "read", output: "2"),
        ]
    )
    // Same work, entirely different ids: one signature.
    let renamed = TurnToolSignature(
        calls: [
            ToolCallBlock(id: "call_zzz", name: "read", arguments: .object(["path": .string("a")])),
            ToolCallBlock(id: "call_yyy", name: "read", arguments: .object(["path": .string("b")])),
        ],
        results: [
            ToolResultBlock(toolCallID: "call_zzz", toolName: "read", output: "1"),
            ToolResultBlock(toolCallID: "call_yyy", toolName: "read", output: "2"),
        ]
    )
    // Same calls in the other order: a different turn. Order is meaning here —
    // read-then-write is not write-then-read.
    let reordered = TurnToolSignature(
        calls: [
            ToolCallBlock(id: "call_abc", name: "read", arguments: .object(["path": .string("b")])),
            ToolCallBlock(id: "call_def", name: "read", arguments: .object(["path": .string("a")])),
        ],
        results: [
            ToolResultBlock(toolCallID: "call_abc", toolName: "read", output: "2"),
            ToolResultBlock(toolCallID: "call_def", toolName: "read", output: "1"),
        ]
    )

    #expect(first == renamed)
    #expect(first != reordered)
    #expect(first.calls.count == 2)
    #expect(first.results.count == 2)
}

@Test func turnSignatureIsUnaffectedByArgumentKeyOrder() throws {
    let forward = try decodedJSON(#"{"a":1,"b":[1,{"x":true,"y":null}],"c":"s"}"#)
    let reversed = try decodedJSON(#"{"c":"s","b":[1,{"y":null,"x":true}],"a":1}"#)

    let first = TurnToolSignature(
        calls: [ToolCallBlock(id: "1", name: "t", arguments: forward)],
        results: [ToolResultBlock(toolCallID: "1", toolName: "t", output: "o")]
    )
    let second = TurnToolSignature(
        calls: [ToolCallBlock(id: "2", name: "t", arguments: reversed)],
        results: [ToolResultBlock(toolCallID: "2", toolName: "t", output: "o")]
    )

    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
}
