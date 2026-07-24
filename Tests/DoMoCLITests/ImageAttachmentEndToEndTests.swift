// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Phase 5.5 exit criterion, exercised for real: the compiled `domo` binary is
// driven with `-p ... --image <file>` over a loopback socket against a mock
// gateway, and the captured request body is asserted to carry the image as an
// OpenAI `image_url` data-URL content part. Nothing is stubbed — this proves the
// whole attach path, from a file on disk through the wire encoder to the gateway.

import DoMoCore
import Foundation
import Testing

@Suite(.serialized)
struct ImageAttachmentEndToEndTests {

    /// One turn: the assistant streams a short final text and stops. No tool call —
    /// this exercises the request the *user* turn produces, which is where the image
    /// rides.
    static let finalTextTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"I see it."},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":4,"total_tokens":46}}

        data: [DONE]


        """#

    /// A 16-byte PNG the media-type sniffer accepts: the 8-byte signature, then an
    /// `IHDR` chunk length of 13, then the `IHDR` tag — exactly what `isPNG`
    /// requires, with no `acTL`, so it is not read as animated.
    static let pngBytes: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    ]

    /// Turn 1: the assistant calls `read` on the PNG (id + name on the first
    /// fragment, arguments across a second), then a `tool_calls` finish.
    static let readImageToolTurn = #"""
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_read_1","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\": \"shot.png\"}"}}]},"finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":42,"completion_tokens":8,"total_tokens":50}}

        data: [DONE]


        """#

    @Test
    func imageAttachmentReachesGatewayAsImageURLPart() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let png = Data(Self.pngBytes)
        let imageURL = workspace.workDirectory.appendingPathComponent("shot.png")
        try png.write(to: imageURL)

        let result = try runDomo(
            arguments: [
                "-p", "what is this?", "--image", imageURL.path,
                "--model", "mock-model", "--base-url", gateway.baseURL,
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 1)

        // The user turn's `content` is a typed part array: a text part carrying the
        // prompt and an image part carrying the exact base64 data URL of the bytes
        // on disk — proof the attachment traversed the whole path and was not
        // flattened to text. Parsed as JSON so the assertion is on values, not on
        // the encoder's `\/`-escaping of the media type's slash.
        let body = gateway.requests[0].body
        let json = try JSONValue(parsing: Data(body.utf8))
        let content = json["messages"]?[1]?["content"]
        #expect(content?[0]?["type"]?.stringValue == "text", "body: \(body)")
        #expect(content?[0]?["text"]?.stringValue == "what is this?", "body: \(body)")
        #expect(content?[1]?["type"]?.stringValue == "image_url", "body: \(body)")
        #expect(
            content?[1]?["image_url"]?["url"]?.stringValue
                == "data:image/png;base64,\(png.base64EncodedString())",
            "body: \(body)"
        )
    }

    @Test
    func toolProducedImageIsHoistedToTheModel() async throws {
        let gateway = try MockGateway(chatCompletionBodies: [Self.readImageToolTurn, Self.finalTextTurn])
        gateway.start()
        defer { gateway.stop() }

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let png = Data(Self.pngBytes)
        try png.write(to: workspace.workDirectory.appendingPathComponent("shot.png"))

        let result = try runDomo(
            arguments: [
                "-p", "read shot.png and describe it", "--model", "mock-model",
                "--base-url", gateway.baseURL,
            ],
            workspace: workspace
        )

        #expect(result.exitCode == 0, "stderr: \(result.standardError)")
        #expect(gateway.requestCount == 2)

        // The second request — sent after `read` returned the image — carries a
        // synthetic user message with the image as an `image_url` part (the OpenAI
        // `tool` role cannot hold image parts). This proves the whole tool→model
        // image path: the read tool's attachment survived the `RegistryTool`
        // adapter and was hoisted on the wire rather than flattened to text.
        let secondBody = gateway.requests[1].body
        #expect(secondBody.contains(#""type":"image_url""#), "second body: \(secondBody)")
        #expect(secondBody.contains(png.base64EncodedString()), "second body: \(secondBody)")
    }

    @Test
    func imageWithoutPromptIsAUsageError() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let imageURL = workspace.workDirectory.appendingPathComponent("shot.png")
        try Data(Self.pngBytes).write(to: imageURL)

        // No `-p`: the flag has no prompt to attach to, and interactive sessions use
        // `@path`, so this is a usage error rather than a silently ignored argument.
        let result = try runDomo(
            arguments: ["--image", imageURL.path, "--model", "mock-model"],
            workspace: workspace
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains("--image requires -p"),
            "stderr: \(result.standardError)"
        )
    }

    @Test
    func nonImageAttachmentIsRejected() async throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        try workspace.writeFile(named: "notes.txt", contents: "just text\n")
        let txtURL = workspace.workDirectory.appendingPathComponent("notes.txt")

        // The media type is sniffed from the bytes, not the extension, so a text
        // file named anything is refused with a message rather than sent as an
        // image the model would reject.
        let result = try runDomo(
            arguments: ["-p", "look", "--image", txtURL.path, "--model", "mock-model"],
            workspace: workspace
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains("not a supported image"),
            "stderr: \(result.standardError)"
        )
    }
}
