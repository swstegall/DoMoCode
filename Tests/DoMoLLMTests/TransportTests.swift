// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import HTTPTypes
import Testing

import DoMoLLM

/// The production transport makes real network syscalls, so these tests are
/// about failure timing rather than protocol behavior — that is covered by the
/// injected-transport tests elsewhere.
@Suite("AsyncHTTPClientTransport connect deadline")
struct TransportConnectDeadlineTests {

    /// A gateway that never answers must fail fast rather than hang until the
    /// 600s streaming deadline. `192.0.2.1` is TEST-NET-1 (RFC 5737) and is
    /// guaranteed non-routable, so a connect attempt either hangs — where the
    /// connect deadline fires — or is rejected as unreachable, which errors even
    /// sooner. Either way the call must return well inside a second with a
    /// transport error, not approach the overall deadline.
    @Test("An unresponsive host fails fast with a transport error")
    func unresponsiveHostFailsFast() async throws {
        let transport = AsyncHTTPClientTransport(connectTimeout: .milliseconds(200))

        var request = HTTPRequest(method: .post, scheme: "http", authority: "192.0.2.1:81", path: "/v1/chat/completions")
        request.headerFields[.contentType] = "application/json"

        let start = ContinuousClock.now
        await #expect(throws: DoMoError.self) {
            let response = try await transport.execute(
                request: request,
                body: Array(#"{"model":"m","messages":[]}"#.utf8),
                timeout: .seconds(600)
            )
            // If a connection somehow succeeded, draining the body is what would
            // otherwise block; force the failure to surface here rather than hang.
            for try await _ in response.body {}
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(10), "failed after \(elapsed); the connect deadline did not bound it")
    }

    /// The error a caller sees must be classified transport, so the retry loop
    /// and the CLI treat it as a connectivity problem rather than something fatal.
    @Test("The failure is classified as transport")
    func failureIsTransport() async {
        let transport = AsyncHTTPClientTransport(connectTimeout: .milliseconds(200))
        var request = HTTPRequest(method: .post, scheme: "http", authority: "192.0.2.1:81", path: "/v1/chat/completions")
        request.headerFields[.contentType] = "application/json"

        do {
            let response = try await transport.execute(request: request, body: Array("{}".utf8), timeout: .seconds(600))
            for try await _ in response.body {}
            Issue.record("expected the unreachable host to throw")
        } catch let error as DoMoError {
            #expect(error.kind == .transport)
            #expect(error.isRetryable)
        } catch {
            Issue.record("expected DoMoError, got \(error)")
        }
    }
}
