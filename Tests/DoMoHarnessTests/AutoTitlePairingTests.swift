// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The title request is built from a fixed-size TAIL of the conversation, and a
// tail can begin anywhere — including between an assistant message that called a
// tool and the result that answers it. The result then travels with no matching
// call, which the strict providers reject outright:
//
//   messages.0.content.0: unexpected `tool_use_id` found in `tool_result` blocks
//   … Each `tool_result` block must have a corresponding `tool_use` block in the
//   previous message.
//
// That surfaces as `POST /session/:id/title -> 500` and the session never gets a
// name. These tests assert the property that prevents it — every tool result in
// a request is answered by a call in the same request, and every call is
// answered by a result — rather than the size of the window, which is an
// implementation detail.

import Foundation
import Synchronization
import SystemPackage
import Testing

import DoMoAgent
import DoMoCore
import DoMoLLM

@testable import DoMoHarness

/// Answers a tool call on the first request of each turn and plain text on the
/// second, while capturing every `Context` it is handed — so a test can assert
/// on what would have gone over the wire.
private final class CapturingToolResponder: Sendable {
    private let captured = Mutex<[Context]>([])
    private let turn = Mutex<Int>(0)

    var contexts: [Context] { captured.withLock { $0 } }

    func fn() -> AgentStreamFn {
        { [self] context in
            captured.withLock { $0.append(context) }
            let index = turn.withLock { current -> Int in
                let value = current
                current += 1
                return value
            }
            // Alternate: call the tool, then answer in text. A run therefore
            // persists user → assistant(tool_use…) → tool_result… → assistant(text).
            //
            // TWO calls per turn, deliberately. With exactly one the turn is four
            // messages long, a fixed twelve-message tail is always a whole number
            // of turns, and the boundary lands on a `user` message every single
            // time — the one alignment under which this defect cannot appear. Five
            // messages per turn is just as ordinary (a model reads two files
            // before answering) and the tail then routinely opens on a tool
            // result whose call it left behind.
            let message: AssistantMessage
            if index.isMultiple(of: 2) {
                message = AssistantMessage(
                    content: [
                        .toolCall(ToolCallBlock(
                            id: "call-\(index)-a", name: "echo", arguments: .object([:])
                        )),
                        .toolCall(ToolCallBlock(
                            id: "call-\(index)-b", name: "echo", arguments: .object([:])
                        )),
                    ],
                    model: "test-model",
                    usage: Usage(input: 1),
                    stopReason: .toolUse
                )
            } else {
                message = AssistantMessage(
                    content: [.text("answer \(index)")],
                    model: "test-model",
                    usage: Usage(input: 1),
                    stopReason: .stop
                )
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.start(AssistantSnapshot(model: message.model)))
                continuation.yield(.done(message))
                continuation.finish()
            }
        }
    }
}

private struct TitleEchoTool: AgentTool {
    let definition = ToolDefinition(name: "echo", description: "echo", parameters: JSONSchema())
    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        AgentToolResult(output: "echoed")
    }
}

@Suite("Auto-title request pairing")
struct AutoTitlePairingTests {

    private func makeSessionDirectory() throws -> FilePath {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilePath(url.path)
    }

    /// Every `tool_result` whose `tool_use` is absent from the SAME list. A
    /// non-empty answer is precisely what the provider rejects.
    private func orphanedToolResults(in messages: [Message]) -> [String] {
        var offered: Set<String> = []
        var orphans: [String] = []
        for message in messages {
            switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    if case .toolCall(let call) = block { offered.insert(call.id) }
                }
            case .tool(let result):
                if !offered.contains(result.toolCallID) { orphans.append(result.toolCallID) }
            case .user(let user):
                for block in user.content {
                    if case .toolResult(let result) = block, !offered.contains(result.toolCallID) {
                        orphans.append(result.toolCallID)
                    }
                }
            case .system:
                continue
            }
        }
        return orphans
    }

    /// Every `tool_use` nothing answers. The same providers reject this too, so a
    /// repair that fixes one end by breaking the other is not a repair.
    private func unansweredToolCalls(in messages: [Message]) -> [String] {
        var answered: Set<String> = []
        var offered: [String] = []
        for message in messages {
            switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    if case .toolCall(let call) = block { offered.append(call.id) }
                }
            case .tool(let result):
                answered.insert(result.toolCallID)
            case .user(let user):
                for block in user.content {
                    if case .toolResult(let result) = block { answered.insert(result.toolCallID) }
                }
            case .system:
                continue
            }
        }
        return offered.filter { !answered.contains($0) }
    }

    private func buildToolHeavySession(
        turns: Int,
        responder: CapturingToolResponder
    ) async throws -> AgentHarness {
        let harness = try AgentHarness.start(
            cwd: "/work/project",
            sessionDirectory: try makeSessionDirectory(),
            configuration: AgentHarness.Configuration(
                systemPrompt: "You are a test.",
                tools: [TitleEchoTool()],
                model: "test-model",
                streamFn: responder.fn(),
                compaction: CompactionSettings(enabled: false)
            )
        )
        for index in 0..<turns {
            _ = try await harness.run(prompt: "request number \(index)")
        }
        return harness
    }

    // MARK: The defect

    @Test("The title request never carries a tool result whose call it dropped")
    func titleRequestKeepsToolCyclesIntact() async throws {
        // Enough turns that the tail window cannot reach the start of the
        // conversation — the only condition the defect needs.
        let responder = CapturingToolResponder()
        let harness = try await buildToolHeavySession(turns: 9, responder: responder)
        let beforeTitle = responder.contexts.count

        _ = try await harness.autoTitle()

        let context = try #require(
            responder.contexts.dropFirst(beforeTitle).first,
            "the title request was never issued"
        )
        let orphans = orphanedToolResults(in: context.messages)
        #expect(
            orphans.isEmpty,
            """
            \(orphans.count) tool result(s) would reach the provider with no matching call: \
            \(orphans). This is the shape that returns \
            `unexpected tool_use_id found in tool_result blocks`.
            """
        )
    }

    @Test("The title request never carries a tool call nothing answers")
    func titleRequestLeavesNoDanglingCall() async throws {
        let responder = CapturingToolResponder()
        let harness = try await buildToolHeavySession(turns: 9, responder: responder)
        let beforeTitle = responder.contexts.count

        _ = try await harness.autoTitle()

        let context = try #require(responder.contexts.dropFirst(beforeTitle).first)
        let dangling = unansweredToolCalls(in: context.messages)
        #expect(dangling.isEmpty, "unanswered tool calls would reach the provider: \(dangling)")
    }

    @Test("The conversation still reaches the title request")
    func titleRequestCarriesTheConversation() async throws {
        let responder = CapturingToolResponder()
        let harness = try await buildToolHeavySession(turns: 9, responder: responder)
        let beforeTitle = responder.contexts.count

        _ = try await harness.autoTitle()

        let context = try #require(responder.contexts.dropFirst(beforeTitle).first)
        // Guards the lazy repair: dropping every message pairs perfectly and
        // titles nothing.
        let carriesPrompt = context.messages.contains { message in
            guard case .user(let user) = message else { return false }
            return user.text.contains("request number")
        }
        #expect(carriesPrompt, "no conversation text reached the title request")
    }
}
