// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import Testing

import DoMoLLM

/// A minimal-but-real PNG signature. Small enough to assert its exact base64,
/// which is what a stable on-disk shape has to guarantee.
private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
private let pngBase64 = pngBytes.base64EncodedString()

@Suite("Image content — persistence shape")
struct ImageContentTests {

    @Test("ImageBlock serializes its bytes as a base64 string and round-trips")
    func imageBlockRoundTrip() throws {
        let block = ImageBlock(mediaType: "image/png", data: pngBytes)
        let data = try JSONEncoder().encode(block)
        let json = try JSONValue(parsing: data)

        // The stable contract: a base64 string, not Foundation's default array
        // of byte integers.
        #expect(json["mediaType"] == "image/png")
        #expect(json["data"] == .string(pngBase64))

        #expect(try JSONDecoder().decode(ImageBlock.self, from: data) == block)
    }

    @Test("dataURL is the OpenAI inline form")
    func dataURL() {
        let block = ImageBlock(mediaType: "image/png", data: pngBytes)
        #expect(block.dataURL == "data:image/png;base64,\(pngBase64)")
    }

    @Test("Invalid base64 image data is rejected rather than silently emptied")
    func imageBlockRejectsInvalidBase64() {
        let bad = Data(#"{"mediaType":"image/png","data":"not valid base64 !!!"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ImageBlock.self, from: bad)
        }
    }

    @Test("A ContentBlock.image round-trips through the persistence encoder shape")
    func contentBlockImageRoundTrip() throws {
        let block = ContentBlock.image(ImageBlock(mediaType: "image/png", data: pngBytes))
        let data = try JSONEncoder().encode(block)
        let json = try JSONValue(parsing: data)

        #expect(json["type"] == "image")
        #expect(json["mediaType"] == "image/png")
        #expect(json["data"] == .string(pngBase64))

        #expect(try JSONDecoder().decode(ContentBlock.self, from: data) == block)
    }

    @Test("A user message carrying text and an image round-trips")
    func userMessageWithImageRoundTrip() throws {
        let message = Message.user(
            UserMessage(content: [
                .text("look at this"),
                .image(ImageBlock(mediaType: "image/png", data: pngBytes)),
            ])
        )
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(Message.self, from: data) == message)
    }

    @Test("A tool result with no images omits the images key, staying byte-compatible")
    func toolResultWithoutImagesOmitsKey() throws {
        let block = ToolResultBlock(toolCallID: "c1", toolName: "read", output: "hi")
        let json = try JSONValue(parsing: try JSONEncoder().encode(block))
        #expect(json["images"] == nil)
        #expect(json["toolCallId"] == "c1")
    }

    @Test("A tool result decodes from a pre-image line with no images key")
    func toolResultDecodesLegacyLine() throws {
        let legacy = Data(#"{"toolCallId":"c1","toolName":"read","output":"hi","isError":false}"#.utf8)
        let block = try JSONDecoder().decode(ToolResultBlock.self, from: legacy)
        #expect(block.images.isEmpty)
        #expect(block.output == "hi")
    }

    @Test("A tool result with images round-trips and emits the images key")
    func toolResultWithImagesRoundTrip() throws {
        let block = ToolResultBlock(
            toolCallID: "c1",
            toolName: "screenshot",
            output: "",
            images: [ImageBlock(mediaType: "image/png", data: pngBytes)]
        )
        let data = try JSONEncoder().encode(block)
        let json = try JSONValue(parsing: data)
        #expect(json["images"]?[0]?["data"] == .string(pngBase64))
        #expect(try JSONDecoder().decode(ToolResultBlock.self, from: data) == block)
    }
}
