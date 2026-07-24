// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Adversarial coverage for the Phase 5.5 image foundation: the invariants a
// maintainer integrating this must not break, probed at the edges the primary
// suites leave open.

import DoMoCore
import Foundation
import Testing

import DoMoLLM

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let pngBase64 = png.base64EncodedString()
private let pngDataURL = "data:image/png;base64,\(pngBase64)"

@Suite("Image foundation — adversarial invariants")
struct AdversarialImageTests {

    private func encoded(_ request: ChatCompletionRequest) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONValue(parsing: try encoder.encode(request))
    }

    // (A) A response arrives with `content` as a plain string; decoding leaves
    // `contentParts` nil, so re-encoding must yield a string again, never the
    // typed parts array. This is the round-trip the wire-key reuse threatens.
    @Test("A decoded string-content message re-encodes as a string, not an array")
    func decodeEncodeKeepsStringContent() throws {
        let message = try JSONDecoder().decode(
            WireMessage.self,
            from: Data(#"{"role":"user","content":"hi"}"#.utf8)
        )
        #expect(message.contentParts == nil)
        let json = try JSONValue(parsing: try JSONEncoder().encode(message))
        #expect(json["content"] == "hi")
    }

    // (A′) An assistant tool-call turn arrives with content: null; the explicit-
    // null contract must survive a decode→encode untouched — not collapse to an
    // omitted key nor to an array.
    @Test("A decoded null-content assistant message re-encodes as explicit null")
    func decodeEncodeKeepsNullContent() throws {
        let message = try JSONDecoder().decode(
            WireMessage.self,
            from: Data(#"{"role":"assistant","content":null,"tool_calls":[]}"#.utf8)
        )
        #expect(message.content == nil)
        #expect(message.contentParts == nil)
        let json = try JSONValue(parsing: try JSONEncoder().encode(message))
        #expect(json["content"] == .null)
    }

    // (B) The whole point of ImageBlock's hand-written Codable: it must not
    // depend on the encoder's dataEncodingStrategy. Force the array-of-integers
    // strategy that a default `Data` would honor and confirm the field stays a
    // base64 string, and that the value still decodes back.
    @Test("ImageBlock stays base64 even under an encoder set to .deferredToData")
    func imageBlockIgnoresDataEncodingStrategy() throws {
        let block = ImageBlock(mediaType: "image/png", data: png)
        let encoder = JSONEncoder()
        encoder.dataEncodingStrategy = .deferredToData
        let data = try encoder.encode(block)
        let json = try JSONValue(parsing: data)
        #expect(json["data"] == .string(pngBase64))

        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .deferredToData
        #expect(try decoder.decode(ImageBlock.self, from: data) == block)
    }

    // (C) Byte-stability, the strongest form: a tool-result line written before
    // images existed must re-serialize byte-for-byte identical under the
    // sorted-keys persistence encoder. Key-absence alone is too weak a claim.
    @Test("A legacy tool-result line survives decode→encode byte-identical")
    func legacyToolResultByteIdentical() throws {
        // Field order chosen to match the encoder's sorted-key output so an
        // unchanged round-trip is a literal string equality.
        let legacy = #"{"isError":false,"output":"hi","toolCallId":"c1","toolName":"read"}"#
        let block = try JSONDecoder().decode(ToolResultBlock.self, from: Data(legacy.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(block), as: UTF8.self)
        #expect(reencoded == legacy)
    }

    // (D) An image with no accompanying text must not emit an empty `text`
    // part — the parts array is the image alone.
    @Test("An image-only user turn emits a single image part, no empty text run")
    func imageOnlyUserTurn() throws {
        let context = Context(
            messages: [
                .user(UserMessage(content: [.image(ImageBlock(mediaType: "image/png", data: png))]))
            ]
        )
        let content = try encoded(ChatCompletionRequest(model: "m", context: context))["messages"]?[0]?["content"]
        #expect(content?[0]?["type"] == "image_url")
        #expect(content?[0]?["image_url"]?["url"] == .string(pngDataURL))
        // Exactly one element: no [1], and certainly no text part.
        #expect(content?[1] == nil)
    }

    // (E) Order preservation across multiple images, in both the user-parts path
    // and the tool hoist. A set-like collapse or a reversal would corrupt which
    // image the model is told about.
    @Test("Multiple images keep their order in the user parts array")
    func multipleImagesOrderedInUserParts() throws {
        let a = ImageBlock(mediaType: "image/png", data: Data([0x01]))
        let b = ImageBlock(mediaType: "image/jpeg", data: Data([0x02]))
        let context = Context(messages: [.user(UserMessage(content: [.text("two"), .image(a), .image(b)]))])
        let content = try encoded(ChatCompletionRequest(model: "m", context: context))["messages"]?[0]?["content"]
        #expect(content?[0]?["text"] == "two")
        #expect(content?[1]?["image_url"]?["url"] == .string(a.dataURL))
        #expect(content?[2]?["image_url"]?["url"] == .string(b.dataURL))
        #expect(content?[3] == nil)
    }

    @Test("Multiple tool-result images keep their order in the hoisted user message")
    func multipleImagesOrderedInHoist() throws {
        let a = ImageBlock(mediaType: "image/png", data: Data([0x01]))
        let b = ImageBlock(mediaType: "image/png", data: Data([0x02]))
        let wire = WireMessage.encoding(
            .tool(ToolResultBlock(toolCallID: "c1", toolName: "shot", output: "", images: [a, b]))
        )
        #expect(wire.count == 2)
        let content = try JSONValue(parsing: try JSONEncoder().encode(wire[1]))["content"]
        #expect(content?[0]?["type"] == "text")
        #expect(content?[1]?["image_url"]?["url"] == .string(a.dataURL))
        #expect(content?[2]?["image_url"]?["url"] == .string(b.dataURL))
    }

    // (F) A `.tool` message carrying images is a persisted transcript line; it
    // must round-trip through Message's own Codable, not just ToolResultBlock's.
    @Test("A .tool message with images round-trips through Message Codable")
    func toolMessageWithImagesRoundTrips() throws {
        let message = Message.tool(
            ToolResultBlock(
                toolCallID: "c1",
                toolName: "shot",
                output: "see image",
                images: [ImageBlock(mediaType: "image/png", data: png)]
            )
        )
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(Message.self, from: data) == message)
    }

    // (G) The parts Codable is claimed symmetric though production never decodes
    // it; prove the image_url decode arm actually reconstructs the url so a
    // future reader can rely on it.
    @Test("A WirePart image_url round-trips through its own Codable")
    func wirePartImageURLRoundTrips() throws {
        let part = WirePart.imageURL(url: pngDataURL)
        let data = try JSONEncoder().encode(part)
        #expect(try JSONDecoder().decode(WirePart.self, from: data) == part)
        // And an unknown part type is rejected, not silently swallowed.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WirePart.self, from: Data(#"{"type":"video"}"#.utf8))
        }
    }
}
