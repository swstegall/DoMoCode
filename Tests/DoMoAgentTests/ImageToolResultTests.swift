// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

import DoMoAgent
import DoMoLLM

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@Suite("Tool-result images")
struct ImageToolResultTests {

    @Test("AgentToolResult carries images and leaves text-only results empty")
    func agentToolResultStoresImages() {
        let withImage = AgentToolResult(
            output: "",
            images: [ImageBlock(mediaType: "image/png", data: png)]
        )
        #expect(withImage.images.count == 1)
        #expect(withImage.images.first?.mediaType == "image/png")

        #expect(AgentToolResult(output: "text").images.isEmpty)
    }

    @Test("Images a tool produces survive the dispatch path into the tool-result block")
    func imagesThreadedThroughDispatch() async throws {
        let tool = FakeTool("screenshot") { _ in
            AgentToolResult(
                output: "",
                images: [ImageBlock(mediaType: "image/png", data: png)]
            )
        }
        let sink = RecordingSink()
        let stream = ScriptedStream([
            assistantTurn(toolCalls: [tc("screenshot")], stopReason: .toolUse),
            assistantTurn(text: "done", stopReason: .stop),
        ])

        let result = await runOnce(context: AgentContext(tools: [tool]), sink: sink, streamFn: stream.fn)

        #expect(result.stopReason == .completed)
        let block = try #require(result.toolResults.first)
        #expect(block.toolName == "screenshot")
        #expect(block.images.count == 1)
        #expect(block.images.first?.data == png)
    }
}
