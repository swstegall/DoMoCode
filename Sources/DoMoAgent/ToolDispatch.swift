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

    /// A tool call's outcome after all lifecycle phases, paired with the call it
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
        /// The call is ready to execute, carrying only observational metadata
        /// accumulated before invocation.
        case prepared(
            tool: any AgentTool,
            toolCall: ToolCallBlock,
            arguments: JSONValue,
            metadata: [String: JSONValue]
        )
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
                await observeCancellation(for: call, metadata: [:])
                outcome = Finalized(toolCall: call, result: Self.abortedResult(for: call))
            } else {
                switch await prepare(call, from: assistantMessage) {
                case .immediate(let result):
                    outcome = Finalized(toolCall: call, result: result)
                case .prepared(let tool, let toolCall, let arguments, let metadata):
                    outcome = await executeAndFinalize(
                        tool: tool,
                        toolCall: toolCall,
                        arguments: arguments,
                        metadata: metadata,
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
        case deferred(
            tool: any AgentTool,
            toolCall: ToolCallBlock,
            arguments: JSONValue,
            metadata: [String: JSONValue]
        )
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
                await observeCancellation(for: call, metadata: [:])
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
            case .prepared(let tool, let toolCall, let arguments, let metadata):
                slots.append(.deferred(tool: tool, toolCall: toolCall, arguments: arguments, metadata: metadata))
            }
        }

        // Phase B — execute deferred calls concurrently. Collect in COMPLETION
        // order (that is when each task yields), emitting each end as it lands,
        // so the UI sees tools finish in real time. Unstructured tasks keep the
        // results concurrent without putting their optimized teardown through a
        // task-group frame.
        var finishedByIndex: [Int: Finalized] = [:]
        let (outcomes, outcomeContinuation) = AsyncStream.makeStream(of: (Int, Finalized).self)
        var tasks: [(index: Int, task: Task<Finalized, Never>)] = []
        for (index, slot) in slots.enumerated() {
            guard case .deferred(let tool, let toolCall, let arguments, let metadata) = slot else { continue }
            let task = Task {
                await executeAndFinalize(
                    tool: tool,
                    toolCall: toolCall,
                    arguments: arguments,
                    metadata: metadata,
                    from: assistantMessage
                )
            }
            tasks.append((index: index, task: task))
            Task {
                let outcome = await task.value
                outcomeContinuation.yield((index, outcome))
            }
        }
        if tasks.isEmpty { outcomeContinuation.finish() }

        var iterator = outcomes.makeAsyncIterator()
        while let (index, outcome) = await iterator.next() {
            await emitEnd(outcome)
            finishedByIndex[index] = outcome
            if finishedByIndex.count == tasks.count {
                outcomeContinuation.finish()
            }
        }
        for (index, task) in tasks {
            task.cancel()
            let outcome = await task.value
            // Cancellation can make the outcome stream's iterator return nil
            // before its final yield is observed. The task still owns the
            // authoritative result, so collect it here instead of dropping the
            // tool-result block from the canceled transcript.
            if finishedByIndex[index] == nil {
                await emitEnd(outcome)
                finishedByIndex[index] = outcome
            }
        }
        outcomeContinuation.finish()

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
            let result = AgentToolResult(output: "Tool \(toolCall.name) not found", isError: true)
            await observeLifecycle(
                stage: .resolved,
                toolCall: toolCall,
                arguments: toolCall.arguments,
                metadata: [:]
            )
            await observeFailure(
                for: toolCall,
                arguments: toolCall.arguments,
                result: result,
                metadata: [:],
                reason: "Tool \(toolCall.name) not found"
            )
            return .immediate(result)
        }

        var arguments = toolCall.arguments
        var metadata: [String: JSONValue] = [:]
        switch await lifecycleDecision(
            stage: .resolved,
            toolCall: toolCall,
            arguments: arguments,
            metadata: metadata
        ) {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            let result = AgentToolResult(output: reason, isError: true)
            await observeFailure(
                for: toolCall,
                arguments: arguments,
                result: result,
                metadata: metadata,
                reason: reason
            )
            return .immediate(result)
        }

        switch await lifecycleDecision(
            stage: .preflight,
            toolCall: toolCall,
            arguments: arguments,
            metadata: metadata
        ) {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            let result = AgentToolResult(output: reason, isError: true)
            await observeFailure(
                for: toolCall,
                arguments: arguments,
                result: result,
                metadata: metadata,
                reason: reason
            )
            return .immediate(result)
        }

        var permissionRejection: String?
        if let beforeToolCall = config.beforeToolCall {
            let decision = await beforeToolCall(
                BeforeToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, arguments: arguments)
            )
            // The hook is responsible for honoring cancellation; the loop double-
            // checks after it returns, matching pi's post-hook `signal.aborted`.
            if Task.isCancelled {
                await observeCancellation(for: toolCall, arguments: arguments, metadata: metadata)
                return .immediate(Self.abortedResult(for: toolCall))
            }
            switch decision.decision {
            case .reject(let reason):
                permissionRejection = reason
            case .proceed(let argumentsPatch):
                arguments = argumentsPatch.apply(to: arguments)
            }
        }

        if Task.isCancelled {
            await observeCancellation(for: toolCall, arguments: arguments, metadata: metadata)
            return .immediate(Self.abortedResult(for: toolCall))
        }

        let lifecyclePermission = await lifecycleDecision(
            stage: .permission,
            toolCall: toolCall,
            arguments: arguments,
            metadata: metadata
        )
        switch lifecyclePermission {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            if permissionRejection == nil { permissionRejection = reason }
        }

        if let permissionRejection {
            let result = AgentToolResult(output: permissionRejection, isError: true)
            await observeFailure(
                for: toolCall,
                arguments: arguments,
                result: result,
                metadata: metadata,
                reason: permissionRejection
            )
            return .immediate(result)
        }

        return .prepared(tool: tool, toolCall: toolCall, arguments: arguments, metadata: metadata)
    }

    /// Executes a prepared call and runs the after-hook. Never throws: a tool's
    /// error is already a result, and its one legal throw — cancellation — is
    /// turned into an aborted result rather than allowed to escape, which is what
    /// keeps a cancelled run's transcript well-formed.
    private func executeAndFinalize(
        tool: any AgentTool,
        toolCall: ToolCallBlock,
        arguments: JSONValue,
        metadata: [String: JSONValue],
        from assistantMessage: AssistantMessage
    ) async -> Finalized {
        var metadata = metadata
        switch await lifecycleDecision(
            stage: .invoke,
            toolCall: toolCall,
            arguments: arguments,
            metadata: metadata
        ) {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            let result = AgentToolResult(output: reason, isError: true)
            await observeFailure(
                for: toolCall,
                arguments: arguments,
                result: result,
                metadata: metadata,
                reason: reason
            )
            return Finalized(toolCall: toolCall, result: result)
        }

        var result: AgentToolResult
        var terminalFailure: (stage: ToolLifecycleStage, reason: String)?
        do {
            result = try await tool.execute(arguments)
        } catch {
            if error.isCancellation {
                result = Self.abortedResult(for: toolCall)
                terminalFailure = (.cancellation, "Tool call \(toolCall.name) was cancelled.")
            } else {
                result = AgentToolResult(output: error.description, isError: true)
                terminalFailure = (.failure, error.description)
            }
        }

        switch await lifecycleDecision(
            stage: .result,
            toolCall: toolCall,
            arguments: arguments,
            result: result,
            metadata: metadata
        ) {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            if terminalFailure == nil { terminalFailure = (.failure, reason) }
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

        switch await lifecycleDecision(
            stage: .postflight,
            toolCall: toolCall,
            arguments: arguments,
            result: result,
            metadata: metadata
        ) {
        case .allow(let additions):
            metadata = Self.merging(metadata, additions)
        case .reject(let reason):
            if terminalFailure == nil { terminalFailure = (.failure, reason) }
        }

        if let terminalFailure {
            await observeLifecycle(
                stage: terminalFailure.stage,
                toolCall: toolCall,
                arguments: arguments,
                result: result,
                metadata: metadata,
                failureReason: terminalFailure.reason
            )
        }

        return Finalized(toolCall: toolCall, result: result)
    }

    // MARK: - Helpers

    private func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.definition.name == name }
    }

    private func lifecycleDecision(
        stage: ToolLifecycleStage,
        toolCall: ToolCallBlock,
        arguments: JSONValue,
        result: AgentToolResult? = nil,
        metadata: [String: JSONValue],
        failureReason: String? = nil
    ) async -> ToolLifecycleDecision {
        guard let hook = config.toolLifecycle else { return .proceed }
        let event = ToolLifecycleEvent(
            stage: stage,
            toolCallID: toolCall.id,
            toolName: toolCall.name,
            arguments: arguments,
            result: result,
            metadata: metadata,
            failureReason: failureReason
        )
        let timeout = config.toolLifecycleTimeout
        guard timeout > .zero else {
            return .reject("Tool lifecycle hook timed out before \(stage.rawValue).")
        }

        return await withTaskGroup(of: ToolLifecycleDecision.self) { group in
            group.addTask { await hook(event) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .reject("Tool lifecycle hook timed out at \(stage.rawValue).")
                } catch {
                    return .proceed
                }
            }
            let decision = await group.next() ?? .proceed
            group.cancelAll()
            return decision
        }
    }

    private func observeLifecycle(
        stage: ToolLifecycleStage,
        toolCall: ToolCallBlock,
        arguments: JSONValue,
        result: AgentToolResult? = nil,
        metadata: [String: JSONValue],
        failureReason: String? = nil
    ) async {
        _ = await lifecycleDecision(
            stage: stage,
            toolCall: toolCall,
            arguments: arguments,
            result: result,
            metadata: metadata,
            failureReason: failureReason
        )
    }

    private func observeFailure(
        for toolCall: ToolCallBlock,
        arguments: JSONValue,
        result: AgentToolResult,
        metadata: [String: JSONValue],
        reason: String
    ) async {
        await observeLifecycle(
            stage: .failure,
            toolCall: toolCall,
            arguments: arguments,
            result: result,
            metadata: metadata,
            failureReason: reason
        )
    }

    private func observeCancellation(
        for toolCall: ToolCallBlock,
        arguments: JSONValue? = nil,
        metadata: [String: JSONValue]
    ) async {
        await observeLifecycle(
            stage: .cancellation,
            toolCall: toolCall,
            arguments: arguments ?? toolCall.arguments,
            metadata: metadata,
            failureReason: "Tool call \(toolCall.name) was cancelled."
        )
    }

    private static func merging(
        _ original: [String: JSONValue],
        _ additions: [String: JSONValue]
    ) -> [String: JSONValue] {
        original.merging(additions) { _, replacement in replacement }
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
