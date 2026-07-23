// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

import DoMoLLM

/// A recorded stream, replayed frame by frame.
///
/// The fixtures are captured LiteLLM output with ids shortened; the point of
/// driving the assembler through `decode -> ingest` rather than constructing
/// `ChatCompletionChunk` values directly is that a decoding regression and an
/// assembly regression are the same bug from the caller's side.
private func replay(_ frames: [String], into assembly: StreamingAssembly) throws -> [AssemblyEvent] {
    var events: [AssemblyEvent] = []
    for frame in frames {
        events.append(contentsOf: assembly.ingest(try ChatCompletionChunk.decode(sseData: frame)))
    }
    events.append(contentsOf: assembly.finish())
    return events
}

private func textDeltas(_ events: [AssemblyEvent]) -> [String] {
    events.compactMap { event in
        if case .textDelta(_, let delta) = event { return delta }
        return nil
    }
}

private func endedToolCalls(_ events: [AssemblyEvent]) -> [ToolCallBlock] {
    events.compactMap { event in
        if case .toolCallEnd(_, let call, _) = event { return call }
        return nil
    }
}

@Suite("StreamingAssembly — plain text")
struct TextAssemblyTests {

    static let frames = [
        """
        {"id":"chatcmpl-A1","created":1753280411,"model":"gpt-4o-mini","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-A1","created":1753280411,"model":"gpt-4o-mini","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-A1","created":1753280411,"model":"gpt-4o-mini","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"content":", world"},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-A1","created":1753280411,"model":"gpt-4o-mini","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """,
        """
        {"id":"chatcmpl-A1","created":1753280411,"model":"gpt-4o-mini","object":"chat.completion.chunk",\
        "choices":[],"usage":{"prompt_tokens":31,"completion_tokens":9,"total_tokens":40,\
        "prompt_tokens_details":{"cached_tokens":0}}}
        """,
    ]

    @Test("Text deltas concatenate into one block")
    func concatenation() throws {
        let assembly = StreamingAssembly(model: "gpt-4o-mini")
        let events = try replay(Self.frames, into: assembly)

        #expect(textDeltas(events) == ["Hello", ", world"])
        let message = try #require(events.last?.terminalMessage)
        #expect(message.text == "Hello, world")
        #expect(message.content.count == 1)
        #expect(message.stopReason == .stop)
        #expect(message.responseID == "chatcmpl-A1")
        #expect(message.responseModel == nil)
    }

    @Test("An empty content delta does not open a block")
    func emptyDeltaOpensNothing() throws {
        let assembly = StreamingAssembly(model: "gpt-4o-mini")
        let events = assembly.ingest(try ChatCompletionChunk.decode(sseData: Self.frames[0]))
        #expect(events.count == 1)
        #expect(assembly.snapshot.blocks.isEmpty)
    }

    @Test("Usage arrives on the trailing empty-choices frame")
    func trailingUsage() throws {
        let assembly = StreamingAssembly(model: "gpt-4o-mini", rates: ModelCostRates(input: 3, output: 15))
        let events = try replay(Self.frames, into: assembly)
        let message = try #require(events.last?.terminalMessage)

        #expect(message.usage.input == 31)
        #expect(message.usage.output == 9)
        #expect(message.usage.cost.input == Decimal(string: "0.000093"))
        #expect(message.usage.cost.output == Decimal(string: "0.000135"))
        #expect(message.usage.cost.total == Decimal(string: "0.000228"))
    }

    @Test("Snapshots ride on boundaries and terminal events, never on deltas")
    func snapshotPolicy() throws {
        let assembly = StreamingAssembly(model: "gpt-4o-mini")
        let events = try replay(Self.frames, into: assembly)

        let carriers = events.filter { event in
            switch event {
            case .start, .textStart, .textEnd, .done, .failed: return true
            default: return false
            }
        }
        let deltas = events.filter { event in
            if case .textDelta = event { return true }
            return false
        }
        #expect(carriers.count == 4)
        #expect(deltas.count == 2)

        // start, textStart, 2 deltas, textEnd, done.
        #expect(events.count == 6)
    }

    @Test("A chunk reporting another model surfaces the fallback")
    func fallbackModel() throws {
        let assembly = StreamingAssembly(model: "claude-sonnet-4")
        _ = try replay(Self.frames, into: assembly)
        #expect(assembly.snapshot.responseModel == "gpt-4o-mini")
        #expect(assembly.message.effectiveModel == "gpt-4o-mini")
    }
}

@Suite("StreamingAssembly — tool calls")
struct ToolCallAssemblyTests {

    /// Bedrock behind LiteLLM: the first tool-call index is 1, and the set is
    /// not dense — this turn uses 1 and 3.
    static let frames = [
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant",\
        "content":null},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "tool_calls":[{"index":1,"id":"tooluse_ZK1a","type":"function",\
        "function":{"name":"read","arguments":""}}]},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "tool_calls":[{"index":1,"function":{"arguments":"{\\"path\\": \\"RE"}}]},\
        "finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "tool_calls":[{"index":3,"id":"tooluse_QP7b","type":"function",\
        "function":{"name":"list","arguments":""}}]},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "tool_calls":[{"index":1,"function":{"arguments":"ADME.md\\"}"}}]},\
        "finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":null,\
        "tool_calls":[{"index":3,"function":{"arguments":"{\\"dir\\": \\".\\"}"}}]},\
        "finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[{"index":0,"delta":{},\
        "finish_reason":"tool_calls"}]}
        """,
        """
        {"id":"chatcmpl-B2","created":1753280500,"model":"bedrock/claude-sonnet-4",\
        "object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":2048,\
        "completion_tokens":73,"total_tokens":2121,"prompt_tokens_details":{"cached_tokens":1900}}}
        """,
    ]

    @Test("Fragments key off delta index, which starts at 1 and skips 2")
    func nonDenseIndices() throws {
        let assembly = StreamingAssembly(model: "bedrock/claude-sonnet-4")
        let events = try replay(Self.frames, into: assembly)

        #expect(assembly.partialToolCalls.keys.sorted() == [1, 3])
        #expect(assembly.partialToolCalls[1]?.name == "read")
        #expect(assembly.partialToolCalls[3]?.name == "list")
        // Block order is arrival order, which is not the stream index.
        #expect(assembly.partialToolCalls[1]?.blockIndex == 0)
        #expect(assembly.partialToolCalls[3]?.blockIndex == 1)

        let calls = endedToolCalls(events)
        #expect(calls.count == 2)
        #expect(calls[0] == ToolCallBlock(id: "tooluse_ZK1a", name: "read", arguments: ["path": "README.md"]))
        #expect(calls[1] == ToolCallBlock(id: "tooluse_QP7b", name: "list", arguments: ["dir": "."]))
    }

    @Test("content: null never opens a text block")
    func nullContentOpensNothing() throws {
        let assembly = StreamingAssembly(model: "bedrock/claude-sonnet-4")
        let events = try replay(Self.frames, into: assembly)
        let message = try #require(events.last?.terminalMessage)

        #expect(message.text.isEmpty)
        #expect(message.content.allSatisfy { $0.toolCallBlock != nil })
        #expect(message.stopReason == .toolUse)
        #expect(message.failure == nil)
    }

    @Test("Arguments are previewable mid-stream and marked incomplete")
    func livePreview() throws {
        let assembly = StreamingAssembly(model: "bedrock/claude-sonnet-4")
        for frame in Self.frames.prefix(3) {
            _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: frame))
        }

        let call = try #require(assembly.partialToolCalls[1])
        #expect(call.argumentFragment == #"{"path": "RE"#)
        #expect(call.arguments["path"] == "RE")
        #expect(!call.argumentsAreComplete)
        #expect(call.argumentsCompleteness == .repaired)

        _ = try replay(Array(Self.frames.dropFirst(3)), into: assembly)
        let finished = try #require(assembly.partialToolCalls[1])
        #expect(finished.arguments["path"] == "README.md")
        #expect(finished.argumentsAreComplete)
    }

    @Test("Usage from the trailing frame reaches the finished message")
    func usage() throws {
        let assembly = StreamingAssembly(model: "bedrock/claude-sonnet-4")
        let events = try replay(Self.frames, into: assembly)
        let message = try #require(events.last?.terminalMessage)
        #expect(message.usage.cacheRead == 1900)
        #expect(message.usage.input == 148)
        #expect(message.usage.output == 73)
    }

    @Test("A fragment with no index attaches to the call it continues")
    func indexOmittedOnContinuation() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(
            ChatCompletionChunk(
                choices: [
                    ChunkChoice(
                        delta: ChunkDelta(
                            toolCalls: [
                                WireToolCallDelta(
                                    index: 5,
                                    id: "call_a",
                                    function: .init(name: "read", arguments: "{\"p\":")
                                )
                            ]
                        )
                    )
                ]
            )
        )
        // No index, but the id has been seen.
        _ = assembly.ingest(
            ChatCompletionChunk(
                choices: [
                    ChunkChoice(delta: ChunkDelta(toolCalls: [WireToolCallDelta(id: "call_a", function: .init(arguments: "1"))]))
                ]
            )
        )
        // Neither index nor id: the most recently touched call is the only guess.
        _ = assembly.ingest(
            ChatCompletionChunk(
                choices: [
                    ChunkChoice(delta: ChunkDelta(toolCalls: [WireToolCallDelta(function: .init(arguments: "}"))]))
                ]
            )
        )

        #expect(assembly.partialToolCalls.keys.sorted() == [5])
        let call = try #require(assembly.partialToolCalls[5])
        #expect(call.argumentFragment == #"{"p":1}"#)
        #expect(call.argumentsAreComplete)
    }

    @Test("An id arriving after the first fragment is still adopted")
    func lateID() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(
            ChatCompletionChunk(
                choices: [ChunkChoice(delta: ChunkDelta(toolCalls: [WireToolCallDelta(index: 0, function: .init(arguments: "{}"))]))]
            )
        )
        _ = assembly.ingest(
            ChatCompletionChunk(
                choices: [ChunkChoice(delta: ChunkDelta(toolCalls: [WireToolCallDelta(index: 0, id: "late", function: .init(name: "read"))]))]
            )
        )
        #expect(assembly.partialToolCalls[0]?.id == "late")
        #expect(assembly.partialToolCalls[0]?.name == "read")
    }
}

@Suite("StreamingAssembly — interleaving")
struct InterleavedAssemblyTests {

    static let frames = [
        """
        {"id":"chatcmpl-C3","model":"gpt-4o","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"role":"assistant","content":"Let me "},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-C3","model":"gpt-4o","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"content":null,"tool_calls":[{"index":0,"id":"call_x",\
        "type":"function","function":{"name":"read","arguments":"{\\"path\\":"}}]},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-C3","model":"gpt-4o","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"content":"check the file"},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-C3","model":"gpt-4o","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,\
        "function":{"arguments":"\\"a.txt\\"}"}}]},"finish_reason":null}]}
        """,
        """
        {"id":"chatcmpl-C3","model":"gpt-4o","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """,
    ]

    @Test("Text resumes into its original block after a tool-call delta")
    func interleaved() throws {
        let assembly = StreamingAssembly(model: "gpt-4o")
        let events = try replay(Self.frames, into: assembly)
        let message = try #require(events.last?.terminalMessage)

        #expect(message.content.count == 2)
        #expect(message.text == "Let me check the file")
        #expect(message.toolCalls == [ToolCallBlock(id: "call_x", name: "read", arguments: ["path": "a.txt"])])

        // The text block opened first, so it stays first.
        #expect(message.content[0].textBlock != nil)
        #expect(message.content[1].toolCallBlock != nil)
    }

    @Test("Block indices in delta events point at the right block throughout")
    func blockIndices() throws {
        let assembly = StreamingAssembly(model: "gpt-4o")
        let events = try replay(Self.frames, into: assembly)

        var textIndices: Set<Int> = []
        var toolIndices: Set<Int> = []
        for event in events {
            switch event {
            case .textDelta(let index, _): textIndices.insert(index)
            case .toolCallDelta(let index, _): toolIndices.insert(index)
            default: continue
            }
        }
        #expect(textIndices == [0])
        #expect(toolIndices == [1])
    }
}

@Suite("StreamingAssembly — reasoning")
struct ReasoningAssemblyTests {

    @Test("Reasoning accumulates into its own block and records its field name")
    func reasoningBlock() throws {
        let frames = [
            """
            {"id":"chatcmpl-D4","model":"deepseek-r1","object":"chat.completion.chunk",\
            "choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"The user "},\
            "finish_reason":null}]}
            """,
            """
            {"id":"chatcmpl-D4","model":"deepseek-r1","object":"chat.completion.chunk",\
            "choices":[{"index":0,"delta":{"reasoning_content":"wants a file."},"finish_reason":null}]}
            """,
            """
            {"id":"chatcmpl-D4","model":"deepseek-r1","object":"chat.completion.chunk",\
            "choices":[{"index":0,"delta":{"content":"Sure."},"finish_reason":"stop"}]}
            """,
        ]
        let assembly = StreamingAssembly(model: "deepseek-r1")
        let message = try #require(try replay(frames, into: assembly).last?.terminalMessage)

        let reasoning = try #require(message.content.first?.reasoningBlock)
        #expect(reasoning.text == "The user wants a file.")
        #expect(reasoning.signature == "reasoning_content")
        #expect(message.text == "Sure.")
    }

    @Test("Duplicated reasoning fields are counted once")
    func duplicateFieldsCountedOnce() throws {
        let frame = """
            {"id":"x","model":"m","choices":[{"index":0,"delta":{"reasoning_content":"abc",\
            "reasoning":"abc"},"finish_reason":null}]}
            """
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: frame))
        #expect(assembly.snapshot.blocks.count == 1)
        if case .reasoning(let block) = assembly.snapshot.blocks[0] {
            #expect(block.text == "abc")
        } else {
            Issue.record("expected a reasoning block")
        }
    }

    @Test("Thinking blocks decode but change nothing")
    func thinkingBlocksAreDecoration() throws {
        let chunk = try ChatCompletionChunk.decode(
            sseData: """
                {"id":"x","choices":[{"index":0,"delta":{"content":"hi","thinking_blocks":\
                [{"type":"thinking","thinking":"...","signature":"abc"}]},"finish_reason":"stop"}]}
                """
        )
        #expect(chunk.choices[0].delta?.thinkingBlocks?.count == 1)
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(chunk)
        #expect(assembly.snapshot.blocks.count == 1)
    }
}

@Suite("StreamingAssembly — termination")
struct TerminationTests {

    @Test("An unknown finish_reason terminates as a failure carrying the raw token")
    func unknownFinishReason() throws {
        let frames = [
            """
            {"id":"chatcmpl-E5","model":"together/qwen3","object":"chat.completion.chunk",\
            "choices":[{"index":0,"delta":{"role":"assistant","content":"partial"},"finish_reason":null}]}
            """,
            Fixtures.unknownFinishChunk,
        ]
        let assembly = StreamingAssembly(model: "together/qwen3")
        let events = try replay(frames, into: assembly)
        let message = try #require(events.last?.terminalMessage)

        #expect(message.stopReason == .unknown("eos"))
        #expect(message.errorMessage == "Provider finish_reason: eos")
        #expect(message.text == "partial")
        #expect(message.failure != nil)
        if case .failed = try #require(events.last) {} else { Issue.record("expected .failed") }
    }

    @Test("An error frame under a committed 200 fails the turn immediately")
    func midStreamError() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.contentChunk))
        let events = assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.errorFrame))
        let message = try #require(events.last?.terminalMessage)

        #expect(message.stopReason == .error)
        #expect(message.errorMessage?.contains("RateLimitError") == true)
        #expect(message.errorMessage?.contains("code: 429") == true)
        // Content that did arrive is kept.
        #expect(message.text == "Hello")
        #expect(assembly.isTerminated)
        // A late frame cannot resurrect the turn.
        #expect(assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.contentChunk)).isEmpty)
        #expect(assembly.finish().isEmpty)
    }

    @Test("A stream that ends without a finish_reason is a failure")
    func missingFinishReason() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.contentChunk))
        #expect(!assembly.hasFinishReason)

        let events = assembly.finish()
        let message = try #require(events.last?.terminalMessage)
        #expect(message.stopReason == .error)
        #expect(message.errorMessage == "Stream ended without finish_reason")
        #expect(message.text == "Hello")
    }

    @Test("Aborting keeps what arrived and reports cancellation")
    func abort() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.contentChunk))
        let events = assembly.abort()
        let message = try #require(events.last?.terminalMessage)

        #expect(message.stopReason == .aborted)
        #expect(message.text == "Hello")
        #expect(message.failure?.isCancellation == true)
    }

    @Test("A client-side DoMoError terminates the turn in its own taxonomy")
    func clientFailure() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(try ChatCompletionChunk.decode(sseData: Fixtures.contentChunk))
        let events = assembly.fail(DoMoError(.transport, "socket hang up"))
        let message = try #require(events.last?.terminalMessage)
        #expect(message.stopReason == .error)
        #expect(message.errorMessage?.contains("socket hang up") == true)
    }

    @Test("finish() is idempotent")
    func idempotentFinish() throws {
        let assembly = StreamingAssembly(model: "m")
        _ = assembly.ingest(
            try ChatCompletionChunk.decode(
                sseData: #"{"id":"x","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#
            )
        )
        #expect(!assembly.finish().isEmpty)
        #expect(assembly.finish().isEmpty)
        #expect(assembly.snapshot.isFinished)
    }

    @Test("A stream with no chunks at all still produces a terminal message")
    func emptyStream() throws {
        let assembly = StreamingAssembly(model: "m")
        let events = assembly.finish()
        let message = try #require(events.last?.terminalMessage)
        #expect(message.content.isEmpty)
        #expect(message.stopReason == .error)
        if case .start = try #require(events.first) {} else { Issue.record("expected .start") }
    }

    @Test("Every block is closed before the terminal event")
    func blocksClosedBeforeTerminal() throws {
        let assembly = StreamingAssembly(model: "gpt-4o")
        let events = try replay(InterleavedAssemblyTests.frames, into: assembly)

        let closeIndices = events.indices.filter { index in
            switch events[index] {
            case .textEnd, .reasoningEnd, .toolCallEnd: return true
            default: return false
            }
        }
        let terminalIndex = try #require(events.indices.last { events[$0].isTerminal })
        #expect(closeIndices.count == 2)
        #expect(closeIndices.allSatisfy { $0 < terminalIndex })
    }
}
