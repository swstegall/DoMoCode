import DoMoCore
import DoMoLLM
import DoMoHarness
import Foundation
import Testing

@Suite("Transcript formatter")
struct TranscriptFormatterTests {
    @Test("Markdown keeps conversational order and tool trajectory")
    func formatsConversation() {
        let assistant = AssistantMessage(
            content: [
                .reasoning(ReasoningBlock(text: "inspect the file")),
                .text("I found the relevant command."),
                .toolCall(ToolCallBlock(
                    id: "call-1",
                    name: "bash",
                    arguments: ["cmd": "printf hi"]
                )),
            ],
            model: "test-model",
            stopReason: .toolUse
        )
        let messages: [Message] = [
            .user("Please inspect it."),
            .assistant(assistant),
            .tool(ToolResultBlock(
                toolCallID: "call-1",
                toolName: "bash",
                output: "hi",
                images: [ImageBlock(mediaType: "image/png", data: Data([1, 2, 3]))]
            )),
            .assistant(AssistantMessage(content: [.text("Done.")], model: "test-model")),
        ]

        let markdown = TranscriptFormatter.markdown(messages: messages)
        #expect(markdown.contains("## User\n\nPlease inspect it."))
        #expect(markdown.contains("### Reasoning\n\ninspect the file"))
        #expect(markdown.contains("### Tool call: `bash` (call-1)"))
        #expect(markdown.contains("\"cmd\" : \"printf hi\""))
        #expect(markdown.contains("### Tool result: `bash`"))
        #expect(markdown.contains("hi"))
        #expect(markdown.contains("[Image 1: `image/png`, 3 bytes]"))
        #expect(markdown.range(of: "Please inspect it.")!.lowerBound < markdown.range(of: "Done.")!.lowerBound)
    }

    @Test("Options can produce a compact copy without reasoning or tools")
    func omitsOptionalContent() {
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [
                    .reasoning(ReasoningBlock(text: "hidden")),
                    .text("visible"),
                    .toolCall(ToolCallBlock(id: "c", name: "read")),
                ],
                model: "m",
                stopReason: .toolUse
            )),
            .tool(ToolResultBlock(toolCallID: "c", toolName: "read", output: "also hidden")),
        ]

        let markdown = TranscriptFormatter.markdown(
            messages: messages,
            options: TranscriptFormatOptions(
                includeReasoning: false,
                includeToolCalls: false,
                includeToolResults: false
            )
        )
        #expect(markdown.contains("visible"))
        #expect(!markdown.contains("hidden"))
        #expect(!markdown.contains("Tool call"))
        #expect(!markdown.contains("Tool result"))
    }

    @Test("Code fences grow past fences printed by tool output")
    func protectsFences() {
        let output = "before\n````\nafter"
        let markdown = TranscriptFormatter.markdown(messages: [
            .tool(ToolResultBlock(toolCallID: "c", toolName: "bash", output: output))
        ])
        #expect(markdown.contains("`````text"))
        #expect(markdown.contains(output))
    }

    @Test("Session export includes header and selected metadata")
    func formatsSessionMetadata() {
        let header = SessionHeader(
            id: "session-1",
            timestamp: "2026-08-03T12:00:00Z",
            cwd: "/tmp/project"
        )
        let entries = [
            SessionTreeEntry(
                id: "start",
                parentId: nil,
                timestamp: header.timestamp,
                payload: .sessionStart(head: "abc123")
            ),
            SessionTreeEntry(
                id: "user",
                parentId: "start",
                timestamp: header.timestamp,
                payload: .message(.user("hello"))
            ),
        ]

        let markdown = TranscriptFormatter.markdown(
            header: header,
            entries: entries,
            options: TranscriptFormatOptions(includeMetadata: true)
        )
        #expect(markdown.hasPrefix("# DoMoCode session"))
        #expect(markdown.contains("Git HEAD: `abc123`"))
        #expect(markdown.contains("## User\n\nhello"))
    }

    @Test("Session export includes bounded recovery metadata without making it a message")
    func formatsRecoveryMetadata() {
        let envelope = RecoveryEnvelope(
            originalKind: "provider",
            status: 503,
            error: "upstream\nfailed",
            diagnosis: "retry later\nwithout changing the prompt"
        )
        let entry = SessionTreeEntry(
            id: "recovery",
            parentId: nil,
            timestamp: "2026-08-03T12:00:00Z",
            payload: .recovery(envelope)
        )

        let markdown = TranscriptFormatter.markdown(
            entries: [entry],
            options: TranscriptFormatOptions(includeMetadata: true)
        )
        #expect(markdown.contains("## Recovery"))
        #expect(markdown.contains("Status: `503`"))
        #expect(markdown.contains("Error: upstream failed"))
        #expect(markdown.contains("Diagnosis: retry later without changing the prompt"))
    }
}
