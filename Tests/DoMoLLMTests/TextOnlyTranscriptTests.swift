// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The reduction a metadata request (title, summary) sends instead of a raw
// transcript slice. Each test names the provider rejection it prevents; a
// request that trips any of them comes back as a 400 the user sees as a 500.

import Foundation
import Testing

import DoMoLLM

@Suite("Text-only transcript")
struct TextOnlyTranscriptTests {

    private func assistant(_ text: String) -> Message {
        .assistant(AssistantMessage(
            content: [.text(text)], model: "m", usage: Usage(), stopReason: .stop
        ))
    }

    private func toolCalling(_ text: String?, ids: [String]) -> Message {
        var content: [ContentBlock] = []
        if let text { content.append(.text(text)) }
        content += ids.map { .toolCall(ToolCallBlock(id: $0, name: "echo", arguments: .object([:]))) }
        return .assistant(AssistantMessage(
            content: content, model: "m", usage: Usage(), stopReason: .toolUse
        ))
    }

    private func toolResult(_ id: String) -> Message {
        .tool(ToolResultBlock(toolCallID: id, toolName: "echo", output: "echoed"))
    }

    /// The reported failure: `unexpected tool_use_id found in tool_result blocks`.
    @Test("Tool results are removed even when their call is present")
    func removesToolResults() {
        let result = Message.textOnlyTranscript([
            .user("read the file"),
            toolCalling(nil, ids: ["a", "b"]),
            toolResult("a"),
            toolResult("b"),
            assistant("here is what it says"),
        ])

        #expect(result.count == 2)
        #expect(result.first?.role == .user)
        #expect(!result.contains { if case .tool = $0 { return true } else { return false } })
    }

    /// The sibling rejection: a `tool_use` nothing answers.
    @Test("Tool calls are removed from the assistant message that made them")
    func removesToolCalls() {
        let result = Message.textOnlyTranscript([
            .user("go"),
            toolCalling("working on it", ids: ["a"]),
        ])

        let calls = result.compactMap { message -> [ToolCallBlock]? in
            guard case .assistant(let assistant) = message else { return nil }
            return assistant.toolCalls
        }.flatMap { $0 }
        #expect(calls.isEmpty)
        // The prose it said alongside the call is kept — it is part of the story
        // the title is being written from.
        #expect(result.last?.role == .assistant)
    }

    /// An assistant turn that only called tools has nothing to say, and an empty
    /// message is itself a provider error.
    @Test("A message with no text left is dropped, not sent empty")
    func dropsEmptiedMessages() {
        let result = Message.textOnlyTranscript([
            .user("go"),
            toolCalling(nil, ids: ["a"]),
            toolResult("a"),
            assistant("done"),
        ])

        #expect(result.count == 2)
        #expect(result.allSatisfy { !$0.textForTest.isEmpty })
    }

    /// Dropping a tool-only assistant turn can strand two user messages together,
    /// and several providers require the roles to alternate.
    @Test("Neighbours that end up sharing a role are merged")
    func mergesConsecutiveRoles() {
        let result = Message.textOnlyTranscript([
            .user("first thing"),
            toolCalling(nil, ids: ["a"]),
            toolResult("a"),
            .user("second thing"),
            assistant("ok"),
        ])

        #expect(result.count == 2)
        #expect(result.first?.role == .user)
        let merged = result.first?.textForTest ?? ""
        #expect(merged.contains("first thing"))
        #expect(merged.contains("second thing"))
        #expect(result.last?.role == .assistant)
    }

    /// The first message must be `user`, so a window that opened on the
    /// assistant's side of a turn has to lose it.
    @Test("A leading assistant message is dropped so the list opens on user")
    func dropsLeadingAssistant() {
        let result = Message.textOnlyTranscript([
            assistant("continuing from before"),
            .user("next"),
            assistant("sure"),
        ])

        #expect(result.first?.role == .user)
        #expect(result.count == 2)
    }

    @Test("System messages are dropped — the caller supplies its own")
    func dropsSystem() {
        let result = Message.textOnlyTranscript([
            .system("you are a coding agent"),
            .user("hello"),
        ])

        #expect(result.count == 1)
        #expect(result.first?.role == .user)
    }

    /// Titling an image costs vision tokens on a request whose whole point is to
    /// be cheap, and the caption is what actually describes the session.
    @Test("Images are dropped while their caption survives")
    func dropsImages() {
        let message = Message.user(UserMessage(content: [
            .text("what is this"),
            .image(ImageBlock(mediaType: "image/png", data: Data([0x89, 0x50]))),
        ]))

        let result = Message.textOnlyTranscript([message])

        #expect(result.count == 1)
        #expect(result.first?.textForTest == "what is this")
        let hasImage = result.contains { message in
            guard case .user(let user) = message else { return false }
            return user.content.contains { if case .image = $0 { return true } else { return false } }
        }
        #expect(!hasImage)
    }

    /// Everything can legitimately reduce to nothing — a session whose only turn
    /// was a tool call. An empty list is the honest answer, and the caller must
    /// not send a request at all.
    @Test("A transcript with nothing readable reduces to nothing")
    func reducesToEmpty() {
        let result = Message.textOnlyTranscript([
            toolCalling(nil, ids: ["a"]),
            toolResult("a"),
        ])

        #expect(result.isEmpty)
    }
}

private extension Message {
    /// The text of a message regardless of role, for assertions only.
    var textForTest: String {
        switch self {
        case .user(let user): return user.text
        case .assistant(let assistant): return assistant.text
        case .system(let system): return system.content
        case .tool(let result): return result.output
        }
    }
}
