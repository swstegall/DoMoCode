// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// THE WEDGE, at the layer that causes it.
//
// AsyncHTTPClient's `execute(_:timeout:)` deadline covers only time-to-response-
// HEAD — it cancels its deadline task in a `defer` the instant the head lands —
// and `HTTPClient.Configuration.Timeout.read` defaults to nil. So before
// `idleGuarded`, a gateway that wrote headers and then stopped talking, without
// closing the socket, produced a body stream that never yielded, never threw and
// never finished. `harness.run` never returned, the server's run slot was never
// freed, and every later prompt on that session 409'd: "the session lost the
// ability to query the model and I had to make a new one".
//
// Written against the PUBLIC `idleGuarded`, so it builds under
// `swift test -c release` with no `@testable`.

import DoMoCore
import Foundation
import HTTPTypes
import Testing

import DoMoLLM

@Suite("Stream idle guard")
struct StreamIdleGuardTests {

    /// Drain a guarded stream, returning the chunks it delivered and how it ended.
    private func drain(
        _ stream: AsyncThrowingStream<[UInt8], any Error>
    ) async -> (chunks: [[UInt8]], error: (any Error)?) {
        var chunks: [[UInt8]] = []
        do {
            for try await chunk in stream { chunks.append(chunk) }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }

    // MARK: The bug

    @Test("A stream that stops producing fails instead of hanging")
    func stalledStreamFails() async throws {
        // Two chunks and then silence forever: the head arrived, some body
        // arrived, and then the gateway went quiet without closing.
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield(Array("data: a\n\n".utf8))
            continuation.yield(Array("data: b\n\n".utf8))
            // Deliberately never finished, and the continuation is retained by the
            // stream — this is the "still open, saying nothing" case.
        }

        let start = ContinuousClock.now
        let result = await drain(idleGuarded(upstream, idle: .milliseconds(200), overall: .seconds(30)))
        let elapsed = ContinuousClock.now - start

        #expect(result.chunks.count == 2, "the bytes that DID arrive must still be delivered")
        let error = try #require(result.error as? DoMoError, "the stalled stream did not fail: \(String(describing: result.error))")
        #expect(error.kind == .transport)
        // "timed out" is load-bearing: LiteLLMClient.classifyTransport keys the
        // retryable classification off this wording.
        #expect(error.description.lowercased().contains("timed out"), "message was \(error.description)")
        #expect(error.isRetryable)
        #expect(elapsed < .seconds(3), "took \(elapsed) to notice the stall")
    }

    @Test("The overall deadline fires even while chunks keep arriving")
    func overallDeadlineFires() async throws {
        // A stream that never goes idle but also never ends — a gateway dribbling
        // keepalive comments forever. The idle guard alone would never fire.
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            let producer = Task {
                while !Task.isCancelled {
                    continuation.yield(Array(": keepalive\n\n".utf8))
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }

        let result = await drain(idleGuarded(upstream, idle: .seconds(30), overall: .milliseconds(300)))
        let error = try #require(result.error as? DoMoError)
        #expect(error.kind == .transport)
        #expect(error.description.contains("deadline"), "message was \(error.description)")
        #expect(error.description.lowercased().contains("timed out"))
        #expect(!result.chunks.isEmpty, "chunks delivered before the deadline must not be swallowed")
    }

    // MARK: No false positives

    @Test("A slow but live stream is never cut off")
    func slowLiveStreamSurvives() async throws {
        // A chunk every 40ms for ~1.2s, guarded with a 300ms idle window. Every
        // gap is well inside the window, but the WHOLE stream is four times it —
        // so a guard that measured total elapsed time instead of silence would
        // kill this, and that is the regression this pins.
        let count = 30
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            let producer = Task {
                for index in 0..<count {
                    try? await Task.sleep(for: .milliseconds(40))
                    continuation.yield([UInt8(index)])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }

        let result = await drain(idleGuarded(upstream, idle: .milliseconds(300), overall: .seconds(60)))
        #expect(result.error == nil, "a healthy slow stream was failed: \(String(describing: result.error))")
        #expect(result.chunks.count == count, "delivered \(result.chunks.count) of \(count) chunks")
        #expect(result.chunks.map { $0[0] } == (0..<count).map { UInt8($0) }, "chunks arrived out of order or were dropped")
    }

    @Test("A stream that finishes promptly is not touched by the guard")
    func promptFinishPassesThrough() async throws {
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield([1, 2, 3])
            continuation.yield([4])
            continuation.finish()
        }
        let result = await drain(idleGuarded(upstream, idle: .milliseconds(50), overall: .milliseconds(50)))
        #expect(result.error == nil)
        #expect(result.chunks == [[1, 2, 3], [4]])
    }

    @Test("An empty stream finishes cleanly rather than idling out")
    func emptyStreamFinishes() async throws {
        let upstream = AsyncThrowingStream<[UInt8], any Error> { $0.finish() }
        let result = await drain(idleGuarded(upstream, idle: .milliseconds(50), overall: .seconds(5)))
        #expect(result.error == nil)
        #expect(result.chunks.isEmpty)
    }

    // MARK: Error and cancellation propagation

    @Test("An upstream failure propagates unchanged, not as a timeout")
    func upstreamErrorPropagates() async throws {
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield([9])
            continuation.finish(throwing: DoMoError(.authentication, "bad key"))
        }
        let result = await drain(idleGuarded(upstream, idle: .seconds(5), overall: .seconds(5)))
        let error = try #require(result.error as? DoMoError)
        #expect(error.kind == .authentication, "the guard rewrote a real failure as a timeout")
        #expect(result.chunks == [[9]])
    }

    /// The guarantee ``AsyncHTTPClientTransport`` documents — dropping the consumer
    /// aborts the underlying request — has to survive the extra hop, or every
    /// abandoned turn leaks a connection into async-http-client's per-host pool.
    @Test("Cancelling the consumer terminates the upstream")
    func cancellingConsumerTerminatesUpstream() async throws {
        let terminated = TerminationFlag()
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield([1])
            continuation.onTermination = { _ in terminated.fire() }
        }
        let guarded = idleGuarded(upstream, idle: .seconds(30), overall: .seconds(30))

        let consumer = Task {
            for try await _ in guarded {}
        }
        // Let the first chunk land so the consumer is genuinely parked on `next()`.
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        _ = try? await consumer.value

        var waited = Duration.zero
        while !terminated.isSet, waited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        #expect(terminated.isSet, "the upstream was left running after the consumer went away")
    }

    @Test("A degenerate idle window does not spin or hang")
    func zeroIdleWindowStillTerminates() async throws {
        // `idle: .zero` must not turn the watchdog into a busy loop; it just fails
        // the stream at the first tick.
        let upstream = AsyncThrowingStream<[UInt8], any Error> { _ in }
        let start = ContinuousClock.now
        let result = await drain(idleGuarded(upstream, idle: .zero, overall: .seconds(30)))
        #expect(result.error is DoMoError)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    // MARK: The production wiring

    @Test("The transport's default idle window is two minutes")
    func defaultIdleTimeoutIsGenerous() {
        // Tight enough that a wedged socket is caught inside one coffee break;
        // loose enough that a long reasoning block behind a keepalive-eating proxy
        // is not a false positive.
        #expect(AsyncHTTPClientTransport.defaultIdleTimeout == .seconds(120))
    }

    // MARK: Disabling the silence bound

    @Test("A nil idle window lets a silent stream run to the overall deadline")
    func nilIdleDisablesTheSilenceCheck() async throws {
        // What `DOMOCODE_STREAM_TIMEOUT_MS=0` resolves to. The stream must NOT be
        // cut at a silence boundary — only the overall deadline may end it.
        let upstream = AsyncThrowingStream<[UInt8], any Error> { continuation in
            continuation.yield(Array("data: a\n\n".utf8))
            // Then silence, forever, with the socket still open.
        }

        let start = ContinuousClock.now
        let result = await drain(idleGuarded(upstream, idle: nil, overall: .milliseconds(400)))
        let elapsed = ContinuousClock.now - start

        #expect(result.chunks.count == 1)
        let error = try #require(result.error as? DoMoError)
        #expect(error.kind == .transport)
        // The message must name the deadline that actually fired. With the silence
        // bound expressed as `idle == overall` instead of nil, the idle branch wins
        // the tick and tells an operator who DISABLED it that it fired.
        #expect(
            error.message.contains("deadline"),
            "disabled silence bound reported as a stall: \(error.message)")
        #expect(!error.message.contains("no data for"))
        #expect(elapsed >= .milliseconds(400))
    }

    @Test("A zero idle timeout on the transport means disabled, never fail-instantly")
    func zeroIdleTimeoutIsTheDisableSentinel() async throws {
        // The sentinel's meaning lives in `AsyncHTTPClientTransport.execute`, so a
        // resolver-level assertion cannot see it: deleting the reinterpretation
        // leaves every configuration test green while every request fails
        // milliseconds after the response head. This pins the mapping itself.
        let disabled = AsyncHTTPClientTransport(idleTimeout: .zero)
        #expect(disabled.idleWindow(for: .seconds(600)) == nil)

        let normal = AsyncHTTPClientTransport(idleTimeout: .seconds(45))
        #expect(normal.idleWindow(for: .seconds(600)) == .seconds(45))
    }
}

/// A `Sendable` one-shot flag for observing an `onTermination` callback.
private final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func fire() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
