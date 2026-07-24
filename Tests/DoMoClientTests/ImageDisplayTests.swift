// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// Phase 7.5d: image bytes flow from the wire into the transcript and out to the
// renderer. The EventStore sources image blocks from user + tool messages; the
// TranscriptView renders them as image visual rows on a graphics terminal (else a
// text fallback); the TranscriptNode places them into the CellBuffer's image layer.

import DoMoLLM
import DoMoServer
import DoMoTermGraphics
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
@Suite("Image display wiring")
struct ImageDisplayTests {
    private func png(width: Int, height: Int) -> ImageBlock {
        func be(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        }
        var bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52]
        bytes += be(width) + be(height)
        return ImageBlock(mediaType: "image/png", data: Data(bytes))
    }

    private func isImage(_ item: TranscriptItem) -> Bool {
        if case .image = item { return true }
        return false
    }

    @Test("Seeding a user message with an image adds an image item alongside the text")
    func seedUserImage() {
        let store = EventStore()
        store.seed([.user(UserMessage(content: [.text("look"), .image(png(width: 100, height: 50))]))])
        #expect(store.transcript.contains { if case .user("look") = $0 { true } else { false } })
        #expect(store.transcript.contains(where: isImage))
    }

    @Test("A tool result's images appear after the tool row")
    func toolImages() {
        let store = EventStore()
        let block = ToolResultBlock(toolCallID: "t1", toolName: "screenshot", output: "ok", images: [png(width: 40, height: 40)])
        store.seed([.tool(block)])
        #expect(store.transcript.contains { if case .tool(name: "screenshot", _, _, _) = $0 { true } else { false } })
        #expect(store.transcript.contains(where: isImage))
    }

    @Test("Live user and tool image events add image items")
    func liveImages() {
        let store = EventStore()
        store.apply(.messageStart(.user(UserMessage(content: [.image(png(width: 10, height: 10))]))))
        store.apply(.toolStart(id: "t", name: "s", arguments: .object([:])))
        store.apply(.toolEnd(id: "t", name: "s", output: "", isError: false, imageCount: 1))
        store.apply(.messageEnd(.tool(ToolResultBlock(toolCallID: "t", toolName: "s", output: "", images: [png(width: 20, height: 20)]))))
        #expect(store.transcript.filter(isImage).count == 2)
    }

    @Test("visualRows renders an image row on a graphics terminal and a fallback otherwise")
    func visualRowsImage() {
        let view = TranscriptView()
        view.items = [.image(png(width: 90, height: 45), imageId: 42)]
        let kitty = view.visualRows(width: 40, capabilities: TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true), cell: .default)
        #expect(kitty.contains { if case .image = $0 { true } else { false } })
        let plain = view.visualRows(width: 40, capabilities: TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false), cell: .default)
        #expect(plain.allSatisfy { if case .text = $0 { true } else { false } })
        #expect(plain.contains { if case .text(let line) = $0 { line.contains("Image") } else { false } })
    }

    @Test("TranscriptNode places an image into the CellBuffer's image layer")
    func nodePlacesImage() {
        let view = TranscriptView()
        view.items = [.image(png(width: 90, height: 45), imageId: 42)]
        let node = TranscriptNode(
            view: view,
            capabilities: TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true),
            cell: .default
        )
        // Viewport tall enough to hold the whole image (a 90×45 image is 10 cell
        // rows at width 40); the tail-clip otherwise scrolls the image's anchor off.
        var buffer = CellBuffer(width: 40, height: 30)
        node.place(in: Rect(x: 0, y: 0, width: 40, height: 30), into: &buffer)
        #expect(!buffer.images.isEmpty)
        #expect(buffer.images.first?.imageId == 42)
    }
}
