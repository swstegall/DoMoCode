// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/agent/src/agent-loop.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import DoMoCore
import DoMoLLM

/// Runs the tool calls of one assistant message.
///
/// Three phases per call, ported from pi: **prepare** (resolve the tool, run the
/// before-hook, which may rewrite or reject), **execute** (run the tool), and
/// **finalize** (run the after-hook, which may transform the result). Every path
/// yields a tool-result message, so the transcript is never left with a tool call
/// that has no answer — including on cancellation, where the un-run calls get an
/// aborted result rather than being dropped.
///
/// A value type holding only `Sendable` fields, so its methods can be captured
/// into the child tasks the parallel path spawns.
struct ToolDispatch: Sendable {
    let tools: [any AgentTool]
    let config: AgentLoopConfig
    let sink: any AgentEventSink

    /// A tool call's outcome after all three phases, paired with the call it
    /// answers. `result.isError` is the authoritative error flag.
    struct Finalized: Sendable {
        var toolCall: ToolCallBlock
        var result: AgentToolResult
    }

    /// The result of one call's preparation phase.
    private enum Preparation {
        /// The call resolved to a result without executing — tool not found, a
        /// rejecting before-hook, or cancellation.
        case immediate(AgentToolResult)
        /// The call is ready to execute.
        case prepared(tool: any AgentTool, toolCall: ToolCallBlock, arguments: JSONValue)
    }

    struct Batch: Sendable {
        var messages: [ToolResultBlock]
        /// True only when every finalized result asked to terminate.
        var terminate: Bool
    }

    // MARK: - Entry

    /// Dispatches `toolCalls`, choosing sequential or parallel execution.
    ///
    /// Sequential wins if configured, or if *any* named tool declares
    /// `executionMode == .sequential` — pi's `hasSequentialToolCall`: one tool
    /// that must not run concurrently forces the whole batch to serialize.
    func run(_ toolCalls: [ToolCallBlock], from assistantMessage: AssistantMessage) async -> Batch {
        let hasSequentialTool = toolCalls.contains { call in
            tool(named: call.name)?.executionMode == .sequential
        }
        if config.toolExecution == .sequential || hasSequentialTool {
            return await runSequential(toolCalls, from: assistantMessage)
        }
        return await runParallel(toolCalls, from: assistantMessage)
    }

    /// Refuses every tool call of a message the model truncated at the output
    /// token limit.
    ///
    /// When `stopReason == .length` the streamed argument fragments were cut mid-
    /// flight. DoMoLLM's ``PartialJSON`` then *repairs* each fragment into
    /// syntactically valid JSON, so the finished ``ToolCallBlock/arguments`` parse
    /// and can even satisfy a schema while being silently incomplete — the very
    /// state ``PartialToolCall/argumentsAreComplete`` reports as `false` mid-
    /// stream. The repaired arguments therefore cannot be trusted, and the right
    /// signal is the message-level `.length` stop, not the arguments themselves.
    /// Fail them all so the model re-issues complete calls, exactly as pi does.
    func refuseTruncated(_ toolCalls: [ToolCallBlock], from assistantMessage: AssistantMessage) async -> Batch {
        var messages: [ToolResultBlock] = []
        for call in toolCalls {
            await sink.emit(
                .toolExecutionStart(toolCallID: call.id, toolName: call.name, arguments: JSONValueBox(call.arguments))
            )
            let finalized = Finalized(
                toolCall: call,
                result: AgentToolResult(
                    output: """
                        Tool call "\(call.name)" was not executed: the response hit the output token limit, \
                        so its arguments may be truncated. Re-issue the tool call with complete arguments.
                        """,
                    isError: true
                )
            )
            await emitEnd(finalized)
            messages.append(await emitResultMessage(finalized))
        }
        // A refused batch never terminates: the model is being asked to retry.
        return Batch(messages: messages, terminate: false)
    }

    // MARK: - Sequential

    private func runSequential(
        _ toolCalls: [ToolCallBlock],
        from assistantMessage: AssistantMessage
    ) async -> Batch {
        var finalized: [Finalized] = []
        var messages: [ToolResultBlock] = []

        for call in toolCalls {
            await sink.emit(
                .toolExecutionStart(toolCallID: call.id, toolName: call.name, arguments: JSONValueBox(call.arguments))
            )

            let outcome: Finalized
            // A cancelled run still owes every call a result; run none of the
            // remaining tools, answer each with an aborted result instead.
            if Task.isCancelled {
                outcome = Finalized(toolCall: call, result: Self.abortedResult(for: call))
            } else {
                switch await prepare(call, from: assistantMessage) {
                case .immediate(let result):
                    outcome = Finalized(toolCall: call, result: result)
                case .prepared(let tool, let toolCall, let arguments):
                    outcome = await executeAndFinalize(
                        tool: tool,
                        toolCall: toolCall,
                        arguments: arguments,
                        from: assistantMessage
                    )
                }
            }

            await emitEnd(outcome)
            messages.append(await emitResultMessage(outcome))
            finalized.append(outcome)
        }

        return Batch(messages: messages, terminate: Self.shouldTerminate(finalized))
    }

    // MARK: - Parallel

    /// One slot in the source-ordered batch: either resolved during preparation
    /// or deferred to the concurrent execution phase.
    private enum Slot {
        case done(Finalized)
        case deferred(tool: any AgentTool, toolCall: ToolCallBlock, arguments: JSONValue)
    }

    private func runParallel(
        _ toolCalls: [ToolCallBlock],
        from assistantMessage: AssistantMessage
    ) async -> Batch {
        // Phase A — prepare every call in source order. Immediate outcomes emit
        // their end here (pi emits an immediate's `tool_execution_end`
        // synchronously); deferred ones wait for phase B.
        var slots: [Slot] = []
        for call in toolCalls {
            await sink.emit(
                .toolExecutionStart(toolCallID: call.id, toolName: call.name, arguments: JSONValueBox(call.arguments))
            )
            if Task.isCancelled {
                let outcome = Finalized(toolCall: call, result: Self.abortedResult(for: call))
                await emitEnd(outcome)
                slots.append(.done(outcome))
                continue
            }
            switch await prepare(call, from: assistantMessage) {
            case .immediate(let result):
                let outcome = Finalized(toolCall: call, result: result)
                await emitEnd(outcome)
                slots.append(.done(outcome))
            case .prepared(let tool, let toolCall, let arguments):
                slots.append(.deferred(tool: tool, toolCall: toolCall, arguments: arguments))
            }
        }

        // Phase B — execute deferred calls concurrently. Collect in COMPLETION
        // order (that is when the group yields), emitting each end as it lands,
        // so the UI sees tools finish in real time.
        var finishedByIndex: [Int: Finalized] = [:]
        await withTaskGroup(of: (Int, Finalized).self) { group in
            for (index, slot) in slots.enumerated() {
                guard case .deferred(let tool, let toolCall, let arguments) = slot else { continue }
                group.addTask {
                    let outcome = await executeAndFinalize(
                        tool: tool,
                        toolCall: toolCall,
                        arguments: arguments,
                        from: assistantMessage
                    )
                    return (index, outcome)
                }
            }
            for await (index, outcome) in group {
                await emitEnd(outcome)
                finishedByIndex[index] = outcome
            }
        }

        // Phase C — walk slots in SOURCE order to build the transcript, so the
        // conversation is deterministic regardless of who finished first.
        var messages: [ToolResultBlock] = []
        var finalized: [Finalized] = []
        for (index, slot) in slots.enumerated() {
            let outcome: Finalized
            switch slot {
            case .done(let done): outcome = done
            case .deferred:
                // Every deferred slot was filled by the group above.
                guard let done = finishedByIndex[index] else { continue }
                outcome = done
            }
            messages.append(await emitResultMessage(outcome))
            finalized.append(outcome)
        }

        return Batch(messages: messages, terminate: Self.shouldTerminate(finalized))
    }

    // MARK: - Phases

    private func prepare(_ toolCall: ToolCallBlock, from assistantMessage: AssistantMessage) async -> Preparation {
        guard let tool = tool(named: toolCall.name) else {
            return .immediate(AgentToolResult(output: "Tool \(toolCall.name) not found", isError: true))
        }

        var arguments = toolCall.arguments
        if let beforeToolCall = config.beforeToolCall {
            let decision = await beforeToolCall(
                BeforeToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, arguments: arguments)
            )
            // The hook is responsible for honoring cancellation; the loop double-
            // checks after it returns, matching pi's post-hook `signal.aborted`.
            if Task.isCancelled { return .immediate(Self.abortedResult(for: toolCall)) }
            switch decision.decision {
            case .reject(let reason):
                return .immediate(AgentToolResult(output: reason, isError: true))
            case .proceed(let argumentsPatch):
                arguments = argumentsPatch.apply(to: arguments)
            }
        }
        if Task.isCancelled { return .immediate(Self.abortedResult(for: toolCall)) }

        return .prepared(tool: tool, toolCall: toolCall, arguments: arguments)
    }

    /// Executes a prepared call and runs the after-hook. Never throws: a tool's
    /// error is already a result, and its one legal throw — cancellation — is
    /// turned into an aborted result rather than allowed to escape, which is what
    /// keeps a cancelled run's transcript well-formed.
    private func executeAndFinalize(
        tool: any AgentTool,
        toolCall: ToolCallBlock,
        arguments: JSONValue,
        from assistantMessage: AssistantMessage
    ) async -> Finalized {
        var result: AgentToolResult
        do {
            result = try await tool.execute(arguments)
        } catch {
            result =
                error.isCancellation
                ? Self.abortedResult(for: toolCall)
                : AgentToolResult(output: error.description, isError: true)
        }

        if let afterToolCall = config.afterToolCall {
            let override = await afterToolCall(
                AfterToolCallContext(
                    assistantMessage: assistantMessage,
                    toolCall: toolCall,
                    arguments: arguments,
                    result: result,
                    isError: result.isError
                )
            )
            result = AgentToolResult(
                output: override.output.apply(to: result.output),
                isError: override.isError.apply(to: result.isError),
                terminate: override.terminate.apply(to: result.terminate),
                details: override.details.apply(to: result.details)
            )
        }

        return Finalized(toolCall: toolCall, result: result)
    }

    // MARK: - Helpers

    private func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.definition.name == name }
    }

    private func emitEnd(_ finalized: Finalized) async {
        await sink.emit(
            .toolExecutionEnd(
                toolCallID: finalized.toolCall.id,
                toolName: finalized.toolCall.name,
                result: finalized.result,
                isError: finalized.result.isError
            )
        )
    }

    /// Builds the tool-result message and emits its start/end. Returns the block
    /// for the caller to append to the transcript, mirroring pi's split between
    /// emitting the message and pushing it into `newMessages`.
    private func emitResultMessage(_ finalized: Finalized) async -> ToolResultBlock {
        let block = ToolResultBlock(
            toolCallID: finalized.toolCall.id,
            toolName: finalized.toolCall.name,
            output: finalized.result.output,
            isError: finalized.result.isError,
            images: finalized.result.images
        )
        await sink.emit(.messageStart(.tool(block)))
        await sink.emit(.messageEnd(.tool(block)))
        return block
    }

    /// Early termination happens only when the batch is non-empty and *every*
    /// finalized result asked for it — pi's `shouldTerminateToolBatch`. One tool
    /// wanting to stop is a hint; unanimity is the rule.
    private static func shouldTerminate(_ finalized: [Finalized]) -> Bool {
        !finalized.isEmpty && finalized.allSatisfy { $0.result.terminate }
    }

    private static func abortedResult(for toolCall: ToolCallBlock) -> AgentToolResult {
        AgentToolResult(output: "Tool call \"\(toolCall.name)\" was aborted.", isError: true)
    }
}
