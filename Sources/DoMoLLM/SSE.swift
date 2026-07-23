// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import EventSource
import Foundation

// MARK: - Frames

/// One decoded frame of an OpenAI-compatible SSE stream.
///
/// The stream is textbook SSE — `data: {json}\n\n` per frame — with one wart the
/// specification does not cover: OpenAI terminates with the literal
/// `data: [DONE]`, which is not JSON and not an event. It is surfaced as its own
/// case so the client stops reading rather than trying to decode it as a chunk.
public enum SSEFrame: Sendable, Hashable {
    /// A `data:` payload that still has to be interpreted — a chunk, or an error
    /// object under a committed 200. Never empty and never `[DONE]`.
    case data(String)

    /// The `[DONE]` sentinel. The turn is over; nothing meaningful follows.
    case done
}

// MARK: - Decoder

/// Incrementally turns transport byte chunks into ``SSEFrame``s.
///
/// The line-and-field parsing is delegated to `mattt/EventSource`'s transport-
/// free `Parser`, driven a byte at a time. That parser is the reason a frame
/// split across two transport chunks — including a split that lands in the middle
/// of a multi-byte UTF-8 scalar — reassembles correctly: it buffers raw bytes
/// until a line terminator and only then decodes, so no chunk boundary is ever
/// visible to a `data:` field. Comments (`:` heartbeats), CR / LF / CRLF line
/// endings, a leading BOM, and multi-line `data:` fields are all the parser's
/// job, not this type's.
///
/// What this type adds on top is the two pieces of the contract SSE itself does
/// not define: recognising `[DONE]`, and dropping the empty keep-alive frames
/// LiteLLM occasionally emits. Error sniffing stays at the client, which is the
/// layer that also holds the HTTP status the error has to be reconciled with.
public struct SSEByteDecoder: Sendable {
    private let parser = EventSource.Parser()

    public init() {}

    /// Feeds one transport chunk and returns whatever complete frames it closed.
    ///
    /// A chunk that completes no event returns `[]`; the parser keeps the partial
    /// line until more bytes arrive.
    public func consume(_ bytes: [UInt8]) async -> [SSEFrame] {
        var frames: [SSEFrame] = []
        for byte in bytes {
            await parser.consume(byte)
            while let event = await parser.getNextEvent() {
                if let frame = Self.frame(from: event) { frames.append(frame) }
            }
        }
        return frames
    }

    /// Flushes any event the stream left pending because the body ended without a
    /// trailing blank line. A frame that was fully received but unterminated is
    /// dispatched here; a frame cut off mid-line surfaces as its own (likely
    /// undecodable) payload, which the client turns into a failed turn.
    public func finish() async -> [SSEFrame] {
        await parser.finish()
        var frames: [SSEFrame] = []
        while let event = await parser.getNextEvent() {
            if let frame = Self.frame(from: event) { frames.append(frame) }
        }
        return frames
    }

    private static func frame(from event: EventSource.Event) -> SSEFrame? {
        let data = event.data
        // `[DONE]` is compared after trimming: it rides in a `data:` field whose
        // leading space the parser already stripped, but a stray trailing space
        // from a lenient proxy must not turn the sentinel into a decode attempt.
        if data == "[DONE]" || data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return .done
        }
        // An empty data payload is a keep-alive, not a chunk. Decoding it would
        // throw; passing it on would look like a truncated turn.
        if data.isEmpty { return nil }
        return .data(data)
    }
}
