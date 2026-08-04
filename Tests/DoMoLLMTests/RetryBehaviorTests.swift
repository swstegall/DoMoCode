// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The retry loop driven end to end through a stubbed transport: the ten-attempt
// budget, the sleep budget, `Retry-After` on statuses other than 429, the
// pre-connect asymmetry, the notices the stream carries, the widened
// busy/overloaded wording, and cancellation mid-backoff.
//
// Plain `import DoMoLLM`: everything asserted here is public, so this file also
// builds and runs in release.

import DoMoCore
import Foundation
import HTTPTypes
import Synchronization
import Testing

import DoMoLLM

// MARK: - Fixtures

private let retryContext = Context(systemPrompt: "s", messages: [.user("hi")])

private func frame(_ payload: String) -> [UInt8] { Array("data: \(payload)\n\n".utf8) }
private let done = Array("data: [DONE]\n\n".utf8)

private let okChunks: [[UInt8]] = [
    frame(#"{"id":"x","model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#),
    done,
]

private struct Reply: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var chunks: [[UInt8]] = []

    static func error(_ status: Int, _ body: String, headers: [(String, String)] = []) -> Reply {
        Reply(status: status, headers: headers, chunks: [Array(body.utf8)])
    }
    static let ok = Reply(status: 200, chunks: okChunks)
    /// The non-streaming shape of a good answer.
    static let okComplete = Reply(
        status: 200,
        chunks: [
            Array(
                #"{"id":"r","model":"m","choices":[{"index":0,"message":{"content":"hi"},"finish_reason":"stop"}]}"#
                    .utf8)
        ])
}

/// Replays replies, reusing the last one forever, and counts calls. Optionally
/// throws (rather than answering) for the first `throwFirst` calls, which is how
/// a connection that never produced a head is modelled.
private final class ReplayTransport: StreamingTransport {
    private let queue: Mutex<[Reply]>
    private let remainingThrows: Mutex<Int>
    private let calls = Mutex(0)

    init(_ replies: [Reply], throwFirst: Int = 0) {
        self.queue = Mutex(replies.isEmpty ? [Reply(status: 200)] : replies)
        self.remainingThrows = Mutex(throwFirst)
    }

    var executeCount: Int { calls.withLock { $0 } }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        calls.withLock { $0 += 1 }
        let shouldThrow = remainingThrows.withLock { n -> Bool in
            if n > 0 {
                n -= 1
                return true
            }
            return false
        }
        if shouldThrow { throw DoMoError(.transport, "connection refused") }

        let reply = queue.withLock { q -> Reply in
            let first = q[0]
            if q.count > 1 { q.removeFirst() }
            return first
        }
        var head = HTTPResponse(status: .init(code: reply.status))
        for (name, value) in reply.headers {
            guard let field = HTTPField.Name(name) else { continue }
            head.headerFields.append(HTTPField(name: field, value: value))
        }
        let chunks = reply.chunks
        return StreamingResponse(
            head: head,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            })
    }
}

/// Answers with a head on the first call and throws on every call after it, so
/// `everConnected` is set before the transport starts failing.
private final class ConnectThenDropTransport: StreamingTransport {
    private let calls = Mutex(0)
    private let firstStatus: Int

    init(firstStatus: Int = 503) { self.firstStatus = firstStatus }
    var executeCount: Int { calls.withLock { $0 } }

    func execute(request: HTTPRequest, body: [UInt8]?, timeout: Duration?) async throws -> StreamingResponse {
        let n = calls.withLock { count -> Int in
            count += 1
            return count
        }
        guard n == 1 else { throw DoMoError(.transport, "socket hang up") }
        let head = HTTPResponse(status: .init(code: firstStatus))
        return StreamingResponse(
            head: head,
            body: AsyncThrowingStream { continuation in
                continuation.yield(Array(#"{"error":{"message":"service unavailable"}}"#.utf8))
                continuation.finish()
            })
    }
}

private final class Sleeps: Sendable {
    private let recorded = Mutex<[Duration]>([])
    func record(_ delay: Duration) { recorded.withLock { $0.append(delay) } }
    var all: [Duration] { recorded.withLock { $0 } }
    var count: Int { recorded.withLock { $0.count } }
}

private final class Notices: Sendable {
    private let stored = Mutex<[RetryNotice]>([])
    func add(_ notice: RetryNotice) { stored.withLock { $0.append(notice) } }
    var all: [RetryNotice] { stored.withLock { $0 } }
}

/// The full-jitter-free, sleep-free client every schedule assertion uses.
private func client(
    _ transport: any StreamingTransport,
    maxRetries: Int = 10,
    base: Duration = .seconds(1),
    cap: Duration = .seconds(60),
    preConnect: Int = 1,
    budget: Duration? = nil,
    jitter: Double = 1.0,
    sleeps: Sleeps? = nil
) -> LiteLLMClient {
    var config = LiteLLMClient.Configuration(
        baseURL: "http://localhost:4000/v1",
        apiKey: "sk-test",
        maxRetries: maxRetries,
        baseRetryDelay: base,
        maxRetryDelay: cap,
        maxPreConnectRetries: preConnect,
        retryDelayBudget: budget,
        jitter: { jitter }
    )
    config.sleep = { delay in sleeps?.record(delay) }
    return LiteLLMClient(configuration: config, transport: transport)
}

private func drain(
    _ stream: AsyncThrowingStream<AssemblyEvent, any Error>
) async -> (events: [AssemblyEvent], error: DoMoError?) {
    var events: [AssemblyEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch let error as DoMoError {
        return (events, error)
    } catch {
        return (events, DoMoError(.transport, "unexpected \(error)"))
    }
}

private func retryNotices(_ events: [AssemblyEvent]) -> [RetryNotice] {
    events.compactMap { if case .retrying(let notice) = $0 { notice } else { nil } }
}

// MARK: - The ten-attempt budget

@Suite("Retry budget — streaming")
struct StreamingRetryBudgetTests {

    @Test("A provider that stays overloaded is capped at ten total attempts")
    func tenRetriesFollowTheTable() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"service unavailable"}}"#)])
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 10, "expected at most ten total requests")
        #expect(sleeps.all == [1, 2, 4, 8, 16, 32, 60, 60, 60].map(Duration.seconds))
        #expect(error?.kind == .provider(status: 503, isRetryable: true))
    }

    @Test("The sleep budget stops retrying before it is exceeded, rather than shortening a delay")
    func budgetStopsEarly() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"unavailable"}}"#)])
        let (_, error) = await drain(
            client(transport, budget: .seconds(20), sleeps: sleeps)
                .streamCompletion(model: "m", context: retryContext))

        // 1+2+4+8 = 15 spent; the next delay is 16s and 31s > 20s, so it stops.
        #expect(sleeps.all == [1, 2, 4, 8].map(Duration.seconds))
        #expect(transport.executeCount == 5)
        #expect(error?.kind == .provider(status: 503, isRetryable: true))
    }

    /// The budget must bound the case a retry *count* cannot: a server that
    /// names a long delay every single time.
    @Test("A server naming a long delay every time is bounded by the sleep budget")
    func budgetBoundsRepeatedRetryAfter() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(503, #"{"error":{"message":"unavailable"}}"#, headers: [("retry-after", "60")])
        ])
        let (_, error) = await drain(
            client(transport, budget: .seconds(300), sleeps: sleeps)
                .streamCompletion(model: "m", context: retryContext))

        #expect(sleeps.all == Array(repeating: Duration.seconds(60), count: 5))
        #expect(transport.executeCount == 6)
        #expect(error != nil)
    }

    @Test("A retry budget of zero is a single attempt")
    func zeroBudgetSingleAttempt() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"unavailable"}}"#)])
        let (events, error) = await drain(
            client(transport, maxRetries: 0, sleeps: sleeps)
                .streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 1)
        #expect(sleeps.count == 0)
        #expect(retryNotices(events).isEmpty)
        #expect(error?.kind == .provider(status: 503, isRetryable: true))
    }

    @Test("Recovery on a later attempt stops the schedule where it recovered")
    func recoveryStopsTheSchedule() async {
        let sleeps = Sleeps()
        let fail = Reply.error(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let transport = ReplayTransport([fail, fail, .ok])
        let (events, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        #expect(events.last?.terminalMessage?.text == "ok")
        #expect(sleeps.all == [.seconds(1), .seconds(2)])
        #expect(transport.executeCount == 3)
    }
}

// MARK: - Retry-After on statuses other than 429

@Suite("Retry-After beyond 429")
struct RetryAfterHonouringTests {

    /// Regression: `DoMoError.retryAfter` is only populated for `.rateLimit`, so
    /// a 503's `Retry-After` used to be silently discarded in favour of the
    /// client's own guess.
    @Test("A 503 carrying Retry-After sleeps what the server asked for")
    func retryAfterOn503() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(503, #"{"error":{"message":"unavailable"}}"#, headers: [("retry-after", "7")]), .ok,
        ])
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        #expect(sleeps.all == [.seconds(7)])
        #expect(transport.executeCount == 2)
    }

    @Test("A 529 carrying retry-after-ms sleeps the millisecond value")
    func retryAfterMillisecondsOn529() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(
                529, #"{"type":"error","error":{"type":"overloaded_error"}}"#,
                headers: [("retry-after-ms", "250")]), .ok,
        ])
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        #expect(sleeps.all == [.milliseconds(250)])
    }

    @Test("A hostile Retry-After is clamped to the ceiling, not obeyed")
    func hostileRetryAfterIsClamped() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(503, #"{"error":{"message":"unavailable"}}"#, headers: [("retry-after", "999999999999")]),
            .ok,
        ])
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        #expect(sleeps.all == [.seconds(60)])
    }

    /// `Retry-After: 0` used to mean ten immediate requests at a provider that
    /// had just said it was overloaded.
    @Test("Retry-After: 0 is floored, not a hot loop")
    func zeroRetryAfterIsFloored() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(503, #"{"error":{"message":"unavailable"}}"#, headers: [("retry-after", "0")])
        ])
        _ = await drain(client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(sleeps.all == Array(repeating: Duration.milliseconds(100), count: 9))
        #expect(transport.executeCount == 10)
    }
}

// MARK: - The pre-connect asymmetry

@Suite("Pre-connect retry cap")
struct PreConnectCapTests {

    /// DECISION: raising the retry budget to ten must NOT change what a dead
    /// gateway costs. A failure before any response head keeps its own budget.
    @Test("A gateway that never answers is still capped at one retry with a ten-retry budget")
    func deadGatewayStillFailsFast() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([], throwFirst: .max)
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 2, "expected initial + one retry, got \(transport.executeCount)")
        #expect(error?.kind == .transport)
        #expect(sleeps.count == 1)
    }

    @Test("The pre-connect cap is a knob, not a constant")
    func preConnectCapIsConfigurable() async {
        let transport = ReplayTransport([], throwFirst: .max)
        let (_, error) = await drain(
            client(transport, preConnect: 3).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 4)
        #expect(error?.kind == .transport)
    }

    @Test("A pre-connect cap of zero means one attempt even with retries enabled")
    func preConnectCapZero() async {
        let transport = ReplayTransport([], throwFirst: .max)
        _ = await drain(client(transport, preConnect: 0).streamCompletion(model: "m", context: retryContext))
        #expect(transport.executeCount == 1)
    }

    @Test("A single connection blip still recovers")
    func oneBlipRecovers() async {
        let transport = ReplayTransport([.ok], throwFirst: 1)
        let (events, error) = await drain(
            client(transport).streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        #expect(events.last?.terminalMessage?.text == "ok")
        #expect(transport.executeCount == 2)
    }

    /// The cap must not leak onto an endpoint that has proven it is there. A 503
    /// is an answer, so a socket drop after one earns the full budget.
    @Test("An endpoint that answered once gets the full budget when it later drops")
    func connectedThenDroppedGetsFullBudget() async {
        let sleeps = Sleeps()
        let transport = ConnectThenDropTransport()
        let (_, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 10)
        #expect(sleeps.count == 9)
        #expect(error?.kind == .transport)
    }

    /// A notice from the pre-connect path must say what a user can act on.
    @Test("A pre-connect retry reports itself as a connection problem")
    func preConnectNoticeReason() async {
        let transport = ReplayTransport([], throwFirst: .max)
        let (events, _) = await drain(
            client(transport).streamCompletion(model: "m", context: retryContext))
        let notices = retryNotices(events)

        #expect(notices.count == 1)
        #expect(notices.first?.reason == .transport)
        // The budget it reports is the one actually in force, not `maxRetries`.
        #expect(notices.first?.maxAttempts == 2)
        #expect(notices.first?.summary == "Retrying in 1s (request 2/2) — connection problem")
    }
}

// MARK: - Notices on the stream

@Suite("Retry notices")
struct RetryNoticeStreamTests {

    @Test("Every retry yields a notice carrying its place in the schedule")
    func noticesMatchTheTable() async {
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"service unavailable"}}"#)])
        let (events, _) = await drain(
            client(transport).streamCompletion(model: "m", context: retryContext))
        let notices = retryNotices(events)

        #expect(notices.count == 9)
        #expect(notices.map(\.attempt) == Array(1...9))
        #expect(notices.allSatisfy { $0.maxAttempts == 10 })
        #expect(notices.map(\.delay) == [1, 2, 4, 8, 16, 32, 60, 60, 60].map(Duration.seconds))
        #expect(notices.allSatisfy { $0.reason == .overloaded })
        #expect(notices[3].summary == "Retrying in 8s (request 5/10) — provider busy")
        #expect(notices[0].message.contains("service unavailable"))
    }

    /// Every retry happens before a stream exists, so a notice must reach the
    /// consumer strictly ahead of the first `.start`. A consumer that guards on
    /// "have we started yet" — the agent loop does — drops every notice placed
    /// after that guard, which is every notice this feature exists for.
    @Test("A notice arrives strictly before the first .start")
    func noticePrecedesTheFirstStart() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"nope"}}"#), .ok])
        let (events, error) = await drain(
            client(transport, maxRetries: 2, sleeps: sleeps)
                .streamCompletion(model: "m", context: retryContext))

        #expect(error == nil)
        let shape: [String] = events.compactMap {
            switch $0 {
            case .retrying: "notice"
            case .start: "start"
            default: nil
            }
        }
        #expect(shape == ["notice", "start"])
        #expect(sleeps.count == 1)
        // And the notice is not a content event: it carries no snapshot and is
        // not terminal, so folding it into a message is impossible by shape.
        let first = events.first
        #expect(first?.terminalMessage == nil)
        if case .retrying = first {} else { Issue.record("the first event was not a retry notice") }
    }

    @Test("A 429 reports itself as rate limited")
    func rateLimitedNotice() async {
        let transport = ReplayTransport([
            .error(429, #"{"error":{"message":"too many requests"}}"#, headers: [("retry-after", "3")]), .ok,
        ])
        let (events, _) = await drain(
            client(transport).streamCompletion(model: "m", context: retryContext))
        let notices = retryNotices(events)

        #expect(notices.count == 1)
        #expect(notices[0].reason == .rateLimited)
        #expect(notices[0].delay == .seconds(3))
        #expect(notices[0].summary == "Retrying in 3s (request 2/10) — rate limited")
    }

    @Test("A notice's provider text is truncated, not pasted whole into a status line")
    func noticeMessageIsTruncated() async {
        let long = String(repeating: "z", count: 5000)
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"\#(long)"}}"#)])
        let (events, _) = await drain(
            client(transport, maxRetries: 1).streamCompletion(model: "m", context: retryContext))
        let notices = retryNotices(events)

        #expect(notices.count == 1)
        #expect(notices[0].message.count < 300)
        #expect(notices[0].message.contains("truncated"))
    }

    @Test("A non-retryable failure yields no notice at all")
    func noNoticeWhenNotRetrying() async {
        let transport = ReplayTransport([.error(401, #"{"error":{"message":"bad key"}}"#)])
        let (events, error) = await drain(
            client(transport).streamCompletion(model: "m", context: retryContext))

        #expect(retryNotices(events).isEmpty)
        #expect(error?.kind == .authentication)
        #expect(transport.executeCount == 1)
    }
}

// MARK: - Classification

@Suite("Busy and overloaded classification")
struct BusyClassificationTests {

    /// LiteLLM wraps an upstream 5xx in its own 400 often enough that the status
    /// alone is not sufficient — these are only caught by wording.
    @Test(
        "A 400 whose body says the provider is busy is retried",
        arguments: [
            #"{"error":{"message":"litellm.APIError: The server is busy, please try again later"}}"#,
            #"{"error":{"message":"Model is at capacity right now"}}"#,
            #"{"error":{"message":"The service is temporarily unavailable"}}"#,
            #"{"error":{"message":"No healthy deployment available"}}"#,
            #"{"error":{"message":"All deployments are rate limited"}}"#,
            #"{"error":{"message":"litellm.APIError: AnthropicException - 529 overloaded_error"}}"#,
            #"{"error":{"message":"Please try again shortly"}}"#,
            #"{"error":{"message":"We are experiencing high load, try again in a moment"}}"#,
        ]
    )
    func busyBodiesAreRetried(body: String) async {
        let transport = ReplayTransport([.error(400, body)])
        let (_, error) = await drain(
            client(transport, maxRetries: 2).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 3, "\(body) was not retried")
        #expect(error?.isRetryable == true)
    }

    /// The guard on the widened wording: a genuinely malformed request must
    /// still fail on the first attempt rather than burn the whole budget.
    ///
    /// Every case below was *measured* burning all ten retries (~243s of
    /// backoff) against an earlier, looser pattern table, so each one is a
    /// regression pin, not a hypothetical:
    ///
    /// - a byte count or a token count that happens to contain a status-shaped
    ///   digit run (`5529341`, `65290`, `5502341`) — the bare `529`/`502`
    ///   substrings,
    /// - an Anthropic request id, which routinely contains one (`req_011CQ529xyz`),
    /// - a `code` field, which `WireError.summary` folds into the match text,
    /// - remedy prose on a permanently-fatal request (`please try again`),
    /// - user or tool content echoed back into the message (`'busy'`,
    ///   `'capacity'`), which a bare `\busy\b` matched.
    @Test(
        "A plain bad request is never retried",
        arguments: [
            #"{"error":{"type":"invalid_request_error","message":"Unknown parameter: 'foo'"}}"#,
            #"{"error":{"message":"tool_use ids must be unique"}}"#,
            #"{"error":{"message":"messages: at least one message is required"}}"#,
            #"{"error":{"message":"messages.0.content.1.image: image exceeds 5 MB maximum: 5529341 bytes"}}"#,
            #"{"error":{"message":"messages.0.content.1.image: image exceeds 5 MB maximum: 5502341 bytes"}}"#,
            #"{"error":{"message":"Invalid value for 'max_tokens': 65290"}}"#,
            #"{"error":{"message":"Unknown parameter 'foo' (request id req_011CQ529xyz)"}}"#,
            #"{"message":"Bad request","code":5290}"#,
            #"{"error":{"message":"Invalid tool name in messages.2: 'busy' is not a registered tool"}}"#,
            #"{"error":{"message":"Unknown field 'capacity' in tool input schema"}}"#,
            #"{"error":{"message":"Your request body is malformed: check your parameters and please try again"}}"#,
        ]
    )
    func plainBadRequestsAreNotRetried(body: String) async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(400, body)])
        let (events, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 1, "\(body) was retried")
        #expect(sleeps.count == 0)
        #expect(retryNotices(events).isEmpty)
        #expect(error?.isRetryable == false)
    }

    /// The headline case, and the reason the pattern table is not allowed to be
    /// generous: a mistyped model name is the single most common user error
    /// there is, and it must surface immediately rather than after ten retries
    /// and four minutes of backoff.
    @Test("A typo'd model name fails on the first attempt, not after the whole budget")
    func typoedModelNameIsNotRetried() async {
        let sleeps = Sleeps()
        let body = #"""
            {"error":{"type":"not_found_error","message":"model 'claude-sonnet-9' not found. Please try again with a valid model name."}}
            """#
        let transport = ReplayTransport([.error(404, body)])
        let (events, error) = await drain(
            client(transport, sleeps: sleeps).streamCompletion(model: "claude-sonnet-9", context: retryContext))

        #expect(transport.executeCount == 1)
        #expect(sleeps.all.isEmpty)
        #expect(retryNotices(events).isEmpty)
        #expect(error?.kind == .provider(status: 404, isRetryable: false))
        #expect(error?.message.contains("claude-sonnet-9") == true)
    }

    /// The other half of the same contract: tightening the wording must not
    /// cost a genuinely transient answer its retries.
    @Test(
        "A busy answer phrased differently is still retried",
        arguments: [
            #"{"error":{"message":"Our servers are busy right now"}}"#,
            #"{"error":{"message":"The model is currently busy"}}"#,
            #"{"error":{"message":"Deployment is over capacity"}}"#,
            #"{"error":{"message":"litellm.APIError: AnthropicException - Error code: 502 Bad Gateway"}}"#,
            #"{"error":{"message":"upstream returned 503 while proxying"}}"#,
        ]
    )
    func busyWordingVariantsAreRetried(body: String) async {
        let transport = ReplayTransport([.error(400, body)])
        let (_, error) = await drain(
            client(transport, maxRetries: 2).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 3, "\(body) was not retried")
        #expect(error?.isRetryable == true)
    }

    @Test("Anthropic's 529 overloaded_error is retried and keeps its wording")
    func anthropic529() async {
        let body = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let transport = ReplayTransport([.error(529, body)])
        let (_, error) = await drain(
            client(transport, maxRetries: 2).streamCompletion(model: "m", context: retryContext))

        #expect(transport.executeCount == 3)
        #expect(error?.kind == .provider(status: 529, isRetryable: true))
        #expect(error?.message.contains("overloaded_error") == true)
    }

    @Test("503 and 429 are both retried; a status the widening did not touch is not")
    func statusRetryability() {
        #expect(DoMoError.isRetryableStatus(429))
        #expect(DoMoError.isRetryableStatus(503))
        #expect(DoMoError.isRetryableStatus(529))
        #expect(DoMoError.isRetryableStatus(425))
        #expect(!DoMoError.isRetryableStatus(400))
        #expect(!DoMoError.isRetryableStatus(404))
        #expect(!DoMoError.isRetryableStatus(422))
    }

    /// Widening the retryable wording must not make a permanent failure look
    /// transient. Overflow is tested first, quota second, and both return early.
    @Test("Quota and overflow still win over the widened busy wording")
    func quotaAndOverflowWin() async {
        let quota = ReplayTransport([
            .error(429, #"{"error":{"message":"insufficient_quota — please try again later"}}"#)
        ])
        let (_, quotaError) = await drain(
            client(quota).streamCompletion(model: "m", context: retryContext))
        #expect(quotaError?.kind == .quotaExhausted)
        #expect(quota.executeCount == 1)

        let overflow = ReplayTransport([
            .error(
                400,
                #"{"error":{"message":"This model's maximum context length is 8192 tokens; please try again"}}"#)
        ])
        let (_, overflowError) = await drain(
            client(overflow).streamCompletion(model: "m", context: retryContext))
        #expect(overflowError?.kind == .contextOverflow)
        #expect(overflow.executeCount == 1)
    }
}

// MARK: - Non-streaming

@Suite("Retry budget — complete()")
struct CompleteRetryTests {

    @Test("complete() reports every retry and follows the same table")
    func completeReportsRetries() async {
        let sleeps = Sleeps()
        let notices = Notices()
        let transport = ReplayTransport([.error(502, #"{"error":{"message":"bad gateway"}}"#)])
        do {
            _ = try await client(transport, sleeps: sleeps).complete(
                model: "m", context: retryContext, onRetry: { notices.add($0) })
            Issue.record("expected a throw")
        } catch let error as DoMoError {
            #expect(error.kind == .provider(status: 502, isRetryable: true))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        #expect(transport.executeCount == 10)
        #expect(sleeps.all == [1, 2, 4, 8, 16, 32, 60, 60, 60].map(Duration.seconds))
        #expect(notices.all.map(\.attempt) == Array(1...9))
        #expect(notices.all.allSatisfy { $0.reason == .overloaded })
    }

    @Test("complete() honours the sleep budget")
    func completeHonoursBudget() async {
        let sleeps = Sleeps()
        let transport = ReplayTransport([.error(502, #"{"error":{"message":"bad gateway"}}"#)])
        _ = try? await client(transport, budget: .seconds(20), sleeps: sleeps).complete(
            model: "m", context: retryContext)

        #expect(sleeps.all == [1, 2, 4, 8].map(Duration.seconds))
        #expect(transport.executeCount == 5)
    }

    /// Before this change `complete()` had no pre-connect cap at all, so a ten
    /// retry budget would have meant eleven dead connects.
    @Test("complete() caps a pre-connect failure the same way the stream does")
    func completeCapsPreConnect() async {
        let transport = ReplayTransport([], throwFirst: .max)
        _ = try? await client(transport).complete(model: "m", context: retryContext)
        #expect(transport.executeCount == 2)
    }

    @Test("complete() honours a Retry-After on a 503")
    func completeHonoursRetryAfter() async throws {
        let sleeps = Sleeps()
        let transport = ReplayTransport([
            .error(503, #"{"error":{"message":"unavailable"}}"#, headers: [("retry-after", "4")]),
            .okComplete,
        ])
        let message = try await client(transport, sleeps: sleeps).complete(model: "m", context: retryContext)

        #expect(message.text == "hi")
        #expect(sleeps.all == [.seconds(4)])
    }

    /// A cancellation landing in the backoff used to escape as a raw
    /// `CancellationError` while one landing in the transport was already a
    /// `DoMoError(.cancelled)`. Callers should only have one shape to recognize.
    @Test("A cancellation during complete()'s backoff surfaces as a classified cancellation")
    func completeCancellationIsClassified() async {
        var config = LiteLLMClient.Configuration(maxRetries: 5, retryDelayBudget: nil)
        config.sleep = { _ in throw CancellationError() }
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"unavailable"}}"#)])
        let subject = LiteLLMClient(configuration: config, transport: transport)

        do {
            _ = try await subject.complete(model: "m", context: retryContext)
            Issue.record("expected a throw")
        } catch let error as DoMoError {
            #expect(error.kind == .cancelled)
            #expect(error.isCancellation)
        } catch {
            Issue.record("expected a DoMoError, got \(error)")
        }
        #expect(transport.executeCount == 1)
    }
}

// MARK: - Cancellation

/// Sleeps for real, and records whether the sleep ended early (interrupted) or
/// ran to completion. That distinction is the whole test: a consumer returning
/// promptly proves nothing if the producer is still parked on a 60s timer.
private final class InterruptibleSleeper: Sendable {
    private let started = Mutex(0)
    private let interrupted = Mutex(0)
    private let completed = Mutex(0)

    var startCount: Int { started.withLock { $0 } }
    var interruptCount: Int { interrupted.withLock { $0 } }
    var completedCount: Int { completed.withLock { $0 } }

    func sleep(_ delay: Duration) async throws {
        started.withLock { $0 += 1 }
        do {
            try await Task.sleep(for: delay)
            completed.withLock { $0 += 1 }
        } catch {
            interrupted.withLock { $0 += 1 }
            throw error
        }
    }
}

@Suite("Cancellation wins over backoff")
struct BackoffCancellationTests {

    /// Ten retries make the worst-case backoff minutes long. If cancellation did
    /// not interrupt the sleep, Escape would leave the user watching a spinner
    /// for the rest of the schedule — which is the bug the ten-retry budget
    /// would otherwise have introduced.
    @Test("Aborting during a sixty-second backoff returns at once and does not wait it out", .timeLimit(.minutes(1)))
    func cancellationInterruptsTheBackoff() async {
        let sleeper = InterruptibleSleeper()
        var config = LiteLLMClient.Configuration(
            maxRetries: 10,
            baseRetryDelay: .seconds(60),
            maxRetryDelay: .seconds(600),
            retryDelayBudget: nil,
            jitter: { 1.0 }
        )
        config.sleep = { try await sleeper.sleep($0) }
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"unavailable"}}"#)])
        let subject = LiteLLMClient(configuration: config, transport: transport)

        let consumer = Task { () -> Int in
            var seen = 0
            do {
                for try await event in subject.streamCompletion(model: "m", context: retryContext) {
                    if case .retrying = event { seen += 1 }
                }
            } catch {
                // Cancellation reaching the consumer is fine and expected.
            }
            return seen
        }

        // Wait for the producer to be parked in the backoff.
        let deadline = ContinuousClock.now + .seconds(10)
        while sleeper.startCount == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(sleeper.startCount == 1, "the producer never reached its backoff")

        let start = ContinuousClock.now
        consumer.cancel()
        let noticesSeen = await consumer.value
        let consumerElapsed = ContinuousClock.now - start

        // The producer must ALSO come back, not just the consumer: poll for the
        // sleep to report itself interrupted rather than completed.
        let unblockDeadline = ContinuousClock.now + .seconds(5)
        while sleeper.interruptCount == 0 && ContinuousClock.now < unblockDeadline {
            await Task.yield()
        }
        let totalElapsed = ContinuousClock.now - start

        #expect(consumerElapsed < .seconds(2), "the consumer waited \(consumerElapsed)")
        #expect(totalElapsed < .seconds(5), "the producer waited \(totalElapsed)")
        #expect(sleeper.interruptCount == 1, "the backoff sleep was not interrupted")
        #expect(sleeper.completedCount == 0, "the backoff sleep ran to completion")
        #expect(sleeper.startCount == 1, "a retry was attempted after cancellation")
        #expect(transport.executeCount == 1, "the request was reissued after cancellation")
        #expect(noticesSeen == 1)
    }

    /// The same guarantee stated on the sleeper's contract: a throw from the
    /// injected sleep aborts the turn instead of retrying through it.
    @Test("A sleeper that throws ends the stream as aborted rather than retrying")
    func throwingSleeperAborts() async {
        var config = LiteLLMClient.Configuration(maxRetries: 10, retryDelayBudget: nil)
        config.sleep = { _ in throw CancellationError() }
        let transport = ReplayTransport([.error(503, #"{"error":{"message":"unavailable"}}"#)])
        let (events, error) = await drain(
            LiteLLMClient(configuration: config, transport: transport)
                .streamCompletion(model: "m", context: retryContext))

        #expect(error == nil, "an abort is not a failure")
        #expect(transport.executeCount == 1)
        #expect(retryNotices(events).count == 1)
        #expect(events.last?.terminalMessage?.stopReason == .aborted)
    }
}
