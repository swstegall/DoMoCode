// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The byte-accumulating SSE reassembler: a frame — and any multibyte character in
// it — must survive being chopped at arbitrary transport boundaries.

import DoMoServer
import Foundation
import Testing

@testable import DoMoClient

@Suite("SSE frame decoder")
struct SSEFrameDecoderTests {
    private func frameBytes(_ event: ServerEvent) throws -> [UInt8] {
        let json = try JSONEncoder().encode(event)
        return Array("data: ".utf8) + Array(json) + [0x0a, 0x0a]
    }

    @Test("A multibyte character split across chunks is decoded intact")
    func splitMultibyteCharacter() throws {
        let bytes = try frameBytes(.messageDelta(text: "hi 🎉 café 世界", reasoning: nil))
        // Push one byte at a time — this guarantees every multibyte character is
        // split across push() calls, the exact condition that corrupts a per-chunk
        // String decode.
        var decoder = SSEFrameDecoder()
        var events: [ServerEvent] = []
        for byte in bytes { events += decoder.push([byte]) }

        #expect(events.count == 1)
        guard case .messageDelta(let text, _) = events.first else {
            Issue.record("expected a messageDelta, got \(String(describing: events.first))")
            return
        }
        #expect(text == "hi 🎉 café 世界")
    }

    @Test("Two frames delivered in one chunk both decode")
    func twoFramesOneChunk() throws {
        let bytes = try frameBytes(.agentStart) + frameBytes(.agentEnd(reason: "completed"))
        var decoder = SSEFrameDecoder()
        let events = decoder.push(bytes)
        #expect(events.count == 2)
        #expect(events[0] == .agentStart)
        #expect(events[1] == .agentEnd(reason: "completed"))
    }

    @Test("The blank-line separator split across chunks still frames correctly")
    func separatorSplitAcrossChunks() throws {
        let bytes = try frameBytes(.turnStart)
        var decoder = SSEFrameDecoder()
        // Split BETWEEN the two trailing newlines.
        let head = Array(bytes.dropLast(1))
        let tail = Array(bytes.suffix(1))
        var events = decoder.push(head)
        #expect(events.isEmpty)          // separator not yet complete
        events = decoder.push(tail)
        #expect(events == [.turnStart])
    }

    @Test("Malformed, comment, and non-data lines are skipped, not fatal")
    func malformedSkipped() throws {
        var decoder = SSEFrameDecoder()
        let junk = Array("data: {not json}\n\n".utf8)
            + Array(": a comment\n\n".utf8)
            + Array("event: foo\n\n".utf8)
        var events = decoder.push(junk)
        #expect(events.isEmpty)          // all skipped, no crash
        // A valid frame after the junk still decodes.
        events = decoder.push(try frameBytes(.heartbeat))
        #expect(events == [.heartbeat])
    }
}
