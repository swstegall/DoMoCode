// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import HTTPTypes
import Synchronization
import Testing

import DoMoLLM

private final class ModelInfoTransport: StreamingTransport {
    private struct Reply: Sendable {
        var status: Int
        var body: String
    }

    private let replies: Mutex<[Reply]>
    private let paths = Mutex<[String]>([])

    init(replies: [(status: Int, body: String)]) {
        self.replies = Mutex(replies.map { Reply(status: $0.status, body: $0.body) })
    }

    var requestedPaths: [String] { paths.withLock { $0 } }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        paths.withLock { $0.append(request.url?.path ?? "") }
        let reply = replies.withLock { queue -> Reply in
            let reply = queue.first ?? Reply(status: 404, body: "")
            if queue.count > 1 { queue.removeFirst() }
            return reply
        }
        let stream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            if !reply.body.isEmpty { continuation.yield(Array(reply.body.utf8)) }
            continuation.finish()
        }
        return StreamingResponse(
            head: HTTPResponse(status: .init(code: reply.status)),
            body: stream
        )
    }
}

@Suite("LiteLLM model pricing")
struct ModelPricingTests {
    @Test("decodes model info prices into per-million token rates")
    func decodesPricingRows() async throws {
        let transport = ModelInfoTransport(replies: [(
            200,
            #"{"data":[{"model_name":"gpt-4o","model_info":{"input_cost_per_token":0.000005,"output_cost_per_token":"0.000015","cache_read_input_token_cost":0.000001,"max_input_tokens":128000}}]}"#
        )])
        let client = LiteLLMClient(
            configuration: .init(baseURL: "http://localhost:4000/v1", apiKey: "test"),
            transport: transport
        )

        let catalog = try await client.listModelPricing()
        let entry = try #require(catalog.entry(for: "gpt-4o"))
        #expect(entry.contextWindow == 128_000)
        #expect(entry.rates?.base.input == Decimal(string: "5"))
        #expect(entry.rates?.base.output == Decimal(string: "15"))
        #expect(entry.rates?.base.cacheRead == Decimal(string: "1"))
        #expect(transport.requestedPaths == ["/model/info"])
    }

    @Test("treats unsupported pricing endpoints as an empty optional catalog")
    func unsupportedEndpointIsNonFatal() async throws {
        let transport = ModelInfoTransport(replies: [(404, ""), (405, "")])
        let client = LiteLLMClient(
            configuration: .init(baseURL: "http://localhost:4000/v1"),
            transport: transport
        )

        let catalog = try await client.listModelPricing()
        #expect(catalog.entries.isEmpty)
        #expect(transport.requestedPaths == ["/model/info", "/v1/model/info"])
    }
}
