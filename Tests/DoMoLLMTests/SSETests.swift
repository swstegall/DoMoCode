// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

import DoMoLLM

/// One SSE frame on the wire: `data: <payload>\n\n`.
private func frame(_ payload: String) -> [UInt8] {
    Array("data: \(payload)\n\n".utf8)
}

/// A realistic streamed completion, ending with the `[DONE]` sentinel. The
/// content deliberately contains a two-byte scalar (é) and a four-byte scalar
/// (🌍) so a split at any byte boundary can land inside a multi-byte scalar.
private let realisticPayloads: [String] = [
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":"Héllo 🌍"},"finish_reason":null}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
    #"{"id":"chatcmpl-1","model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13}}"#,
]

private var realisticStreamBytes: [UInt8] {
    var bytes: [UInt8] = []
    for payload in realisticPayloads { bytes += frame(payload) }
    bytes += Array("data: [DONE]\n\n".utf8)
    return bytes
}

private func decode(_ chunks: [[UInt8]]) async -> [SSEFrame] {
    let decoder = SSEByteDecoder()
    var frames: [SSEFrame] = []
    for chunk in chunks {
        frames += await decoder.consume(chunk)
    }
    frames += await decoder.finish()
    return frames
}

@Suite("SSE — frame decoding")
struct SSEFrameTests {

    @Test("A whole stream decodes to its data frames plus the DONE sentinel")
    func wholeStream() async {
        let frames = await decode([realisticStreamBytes])
        #expect(frames.count == 5)
        #expect(frames.last == .done)
        let datas = frames.compactMap { frame -> String? in
            if case .data(let d) = frame { return d }
            return nil
        }
        #expect(datas.count == 4)
        #expect(datas[0].contains("Héllo 🌍"))
    }

    @Test("[DONE] is recognized, and a padded sentinel still is")
    func doneSentinel() async {
        #expect(await decode([frame("[DONE]")]) == [.done])
        #expect(await decode([Array("data:  [DONE] \n\n".utf8)]) == [.done])
    }

    @Test("Comment/heartbeat lines produce no frames")
    func heartbeats() async {
        let bytes = Array(": ping\n\n".utf8) + Array(":keep-alive\n".utf8) + frame(#"{"id":"x","choices":[]}"#)
        let frames = await decode([bytes])
        #expect(frames.count == 1)
        if case .data(let d) = frames[0] { #expect(d.contains("\"id\":\"x\"")) } else { Issue.record("expected data") }
    }

    @Test("A multi-line data field concatenates its lines with a newline")
    func multiLineData() async {
        let bytes = Array("data: line one\ndata: line two\n\n".utf8)
        let frames = await decode([bytes])
        #expect(frames == [.data("line one\nline two")])
    }

    @Test("An empty data frame is dropped, not surfaced")
    func emptyDataDropped() async {
        let bytes = Array("data: \n\n".utf8) + frame(#"{"id":"x"}"#)
        let frames = await decode([bytes])
        #expect(frames.count == 1)
    }

    @Test("An error frame passes through as data — sniffing is the client's job")
    func errorFramePassthrough() async {
        let frames = await decode([frame(#"{"error":{"message":"boom","code":"429"}}"#)])
        guard case .data(let d) = frames.first else { Issue.record("expected data frame"); return }
        #expect(d.contains("\"error\""))
        #expect(WireErrorEnvelope.sniff(sseData: d)?.code == "429")
    }
}

@Suite("SSE — chunk boundaries")
struct SSEBoundaryTests {

    @Test("A split at every byte boundary decodes identically, multi-byte scalars included")
    func everyByteBoundary() async {
        let bytes = realisticStreamBytes
        let reference = await decode([bytes])
        #expect(reference.count == 5)

        for split in 1..<bytes.count {
            let chunks = [Array(bytes[0..<split]), Array(bytes[split...])]
            let frames = await decode(chunks)
            #expect(frames == reference, "split at byte \(split) diverged")
        }
    }

    @Test("A single byte at a time decodes the same as one chunk")
    func oneByteAtATime() async {
        let bytes = realisticStreamBytes
        let reference = await decode([bytes])
        let perByte = await decode(bytes.map { [$0] })
        #expect(perByte == reference)
    }

    @Test("A frame with no trailing blank line is flushed by finish()")
    func unterminatedFinalFrame() async {
        // No terminating "\n\n": the last event only dispatches on finish().
        let bytes = Array(#"data: {"id":"x","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#.utf8)
        let frames = await decode([bytes])
        #expect(frames.count == 1)
        guard case .data(let d) = frames[0] else { Issue.record("expected data"); return }
        #expect(d.contains("\"content\":\"hi\""))
    }
}
