// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The retry schedule, the notice type, and the clamps around a server-supplied
// `Retry-After`. Everything here is pure: no transport, no clock, no sleep.

import DoMoCore
import Testing

import DoMoLLM

// MARK: - Fixtures

/// The config the shipped defaults describe, with jitter pinned so the table is
/// exact.
private func scheduleConfig(
    base: Duration = .seconds(1),
    cap: Duration = .seconds(60),
    maxRetries: Int = 10
) -> LiteLLMClient.Configuration {
    LiteLLMClient.Configuration(
        maxRetries: maxRetries,
        baseRetryDelay: base,
        maxRetryDelay: cap
    )
}

/// The nominal (unjittered) delay before each of the ten retries.
private let nominalTable: [Duration] = [1, 2, 4, 8, 16, 32, 60, 60, 60, 60].map(Duration.seconds)

// MARK: - Schedule

@Suite("Retry schedule")
struct RetryScheduleTests {

    @Test("The ten-retry table doubles from the base and saturates at the ceiling")
    func exponentialAndCapped() {
        let config = scheduleConfig()
        let actual = (1...10).map { config.retryDelay(attempt: $0, retryAfter: nil, jitter: 1.0) }
        #expect(actual == nominalTable)
    }

    @Test("The jitter floor halves every entry and never goes below it")
    func jitterFloorHalvesTheTable() {
        let config = scheduleConfig()
        let actual = (1...10).map { config.retryDelay(attempt: $0, retryAfter: nil, jitter: 0.5) }
        #expect(actual == nominalTable.map { $0 * 0.5 })
        #expect(actual[0] == .milliseconds(500))
        #expect(actual[9] == .seconds(30))
    }

    /// The ceiling is what makes ten attempts bounded rather than absurd: past
    /// the seventh the nominal delay would be 64s, 128s, 256s, 512s.
    @Test("Past the cap the delay stops growing no matter how high the attempt")
    func capHoldsForAbsurdAttemptNumbers() {
        let config = scheduleConfig()
        for attempt in [7, 10, 31, 64, 1_000, Int.max] {
            #expect(config.retryDelay(attempt: attempt, retryAfter: nil, jitter: 1.0) == .seconds(60))
        }
    }

    @Test("Attempt numbers at or below zero are treated as the first retry")
    func degenerateAttemptNumbers() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 0, retryAfter: nil, jitter: 1.0) == .seconds(1))
        #expect(config.retryDelay(attempt: -5, retryAfter: nil, jitter: 1.0) == .seconds(1))
    }

    @Test("A zero retry budget yields no schedule at all, but the table is still well-formed")
    func zeroBaseDelay() {
        let config = scheduleConfig(base: .zero)
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: 1.0) == .zero)
    }

    /// `DOMOCODE_RETRY_BASE_MS` and `DOMOCODE_RETRY_MAX_MS` accept any
    /// non-negative `Int`, and `Duration * Double` converts through `_Int128`,
    /// which *traps* rather than saturating. An absurd-but-accepted config must
    /// therefore saturate here, in the arithmetic, or it kills the process —
    /// without this the two expectations below do not fail, they crash the
    /// runner ("Double value cannot be converted to _Int128").
    @Test("An absurd base delay saturates at the ceiling instead of trapping")
    func absurdBaseDelaySaturates() {
        let capped = scheduleConfig(base: .milliseconds(Int.max), cap: .seconds(60), maxRetries: 40)
        #expect(capped.retryDelay(attempt: 31, retryAfter: nil, jitter: 1.0) == .seconds(60))
        #expect(capped.retryDelay(attempt: 1, retryAfter: nil, jitter: 1.0) == .seconds(60))

        // Both knobs absurd: the ceiling itself is the answer, still no trap.
        let uncapped = scheduleConfig(base: .milliseconds(Int.max), cap: .milliseconds(Int.max))
        #expect(uncapped.retryDelay(attempt: 31, retryAfter: nil, jitter: 1.0) == .milliseconds(Int.max))
    }

    /// A base above the ceiling is meaningless but configurable; it must read as
    /// the ceiling from the very first retry rather than doubling past it.
    @Test("A base above the ceiling is clamped before it is doubled")
    func baseAboveCeiling() {
        let config = scheduleConfig(base: .seconds(120), cap: .seconds(60))
        #expect((1...5).allSatisfy { config.retryDelay(attempt: $0, retryAfter: nil, jitter: 1.0) == .seconds(60) })
    }

    /// A negative base is not reachable through the CLI parser, which rejects
    /// negatives, but `Configuration` is public and its doubling would overflow.
    @Test("A negative base delay reads as no delay rather than overflowing")
    func negativeBaseDelay() {
        let config = scheduleConfig(base: .seconds(-5))
        #expect(config.retryDelay(attempt: 31, retryAfter: nil, jitter: 1.0) == .zero)
    }
}

// MARK: - Jitter

@Suite("Retry jitter")
struct RetryJitterTests {

    /// Bounds, not values: the point of jitter is that the value is not pinned.
    @Test("The default jitter draws inside the half-jitter range and actually varies")
    func defaultJitterBounds() {
        let jitter = LiteLLMClient.Configuration().jitter
        var sawLow = false
        var sawHigh = false
        for _ in 0..<1000 {
            let value = jitter()
            #expect(value >= 0.5 && value <= 1.0, "draw \(value) escaped 0.5...1.0")
            if value < 0.9 { sawLow = true }
            if value > 0.6 { sawHigh = true }
        }
        #expect(sawLow, "every draw was >= 0.9 — the default jitter looks pinned")
        #expect(sawHigh, "every draw was <= 0.6 — the default jitter looks pinned")
        #expect(LiteLLMClient.Configuration.defaultJitterRange == 0.5...1.0)
    }

    /// A jitter generator is injectable, therefore it is untrusted.
    ///
    /// A multiplier that is not a number at all is a *caller bug*, and the two
    /// directions it can fail in are not symmetric: rounding it up wastes one
    /// backoff, rounding it down fires the whole ten-attempt budget back to back
    /// at a provider that just said it was overloaded. So a non-finite
    /// multiplier reads as the full delay, never as none.
    @Test("A jitter multiplier outside 0...1 is clamped, never amplified or negated")
    func jitterIsClampedToUnitInterval() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: 5.0) == .seconds(4))
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: .infinity) == .seconds(4))
        // NaN loses every comparison, so a naive clamp passes it through and
        // `Duration * Double` then traps converting it.
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: .nan) == .seconds(4))
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: .signalingNaN) == .seconds(4))
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: -.infinity) == .seconds(4))
        // A *finite* negative is unambiguous arithmetic and still clamps down —
        // but the floor below keeps even that off zero.
        #expect(config.retryDelay(attempt: 3, retryAfter: nil, jitter: -1.0) == .milliseconds(100))
    }

    /// No computed delay may ever be zero while the nominal delay is not, no
    /// matter what the multiplier is: a zero-delay retry is a hot loop of ten
    /// immediate requests, which is the exact behaviour ``minimumRetryAfter``
    /// exists to stop on the server-supplied branch.
    @Test(
        "A computed delay is floored away from zero for every degenerate multiplier",
        arguments: [Double.nan, -.infinity, .infinity, -1.0, -0.0, 0.0, .leastNonzeroMagnitude])
    func computedDelayIsNeverZero(jitter: Double) {
        let config = scheduleConfig()
        let delay = config.retryDelay(attempt: 3, retryAfter: nil, jitter: jitter)
        #expect(delay >= LiteLLMClient.Configuration.minimumRetryAfter, "jitter \(jitter) produced \(delay)")
    }

    /// The floor is a floor, not an inflation: it never raises a delay above the
    /// nominal one the schedule asked for.
    @Test("The zero floor never exceeds the nominal delay it is flooring")
    func floorNeverExceedsNominal() {
        let tiny = scheduleConfig(base: .milliseconds(20))
        #expect(tiny.retryDelay(attempt: 1, retryAfter: nil, jitter: 1.0) == .milliseconds(20))
        #expect(tiny.retryDelay(attempt: 1, retryAfter: nil, jitter: 0.0) == .milliseconds(20))
        #expect(scheduleConfig(base: .zero).retryDelay(attempt: 1, retryAfter: nil, jitter: 0.0) == .zero)
    }

    /// Jitter never applies to a delay the server named.
    @Test("A server-supplied delay is not jittered")
    func retryAfterIsNotJittered() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 3, retryAfter: .seconds(3), jitter: 0.5) == .seconds(3))
        #expect(config.retryDelay(attempt: 9, retryAfter: .seconds(3), jitter: 0.0) == .seconds(3))
    }
}

// MARK: - Retry-After clamping

@Suite("Retry-After clamping")
struct RetryAfterClampTests {

    @Test("A server delay above the ceiling is clamped to it")
    func clampedHigh() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 1, retryAfter: .seconds(600), jitter: 1.0) == .seconds(60))
    }

    /// `Retry-After` is text from the far side of a wire, so the high clamp is a
    /// safety property, not a policy one. `parseRetryAfter` already saturates the
    /// value into something `Duration` survives; the schedule then pins it to the
    /// ceiling so a hostile header cannot freeze a turn for a century.
    @Test("A hostile Retry-After cannot produce an unbounded sleep")
    func hostileRetryAfter() {
        let config = scheduleConfig()
        let parsed = DoMoError.parseRetryAfter(retryAfter: "1e300")
        #expect(parsed != nil)
        #expect(config.retryDelay(attempt: 1, retryAfter: parsed, jitter: 1.0) == .seconds(60))

        let parsedMS = DoMoError.parseRetryAfter(retryAfter: nil, retryAfterMilliseconds: "99999999999999999999")
        #expect(config.retryDelay(attempt: 1, retryAfter: parsedMS, jitter: 1.0) == .seconds(60))
    }

    /// The low clamp is what stops `Retry-After: 0` becoming ten immediate
    /// requests at a provider that just said it was overloaded.
    @Test("A zero or negative server delay is floored, not honoured literally")
    func flooredAwayFromZero() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 1, retryAfter: .zero, jitter: 1.0) == .milliseconds(100))
        #expect(LiteLLMClient.Configuration.minimumRetryAfter == .milliseconds(100))
        // `parseRetryAfter` clamps a negative to zero; the schedule then floors it.
        let negative = DoMoError.parseRetryAfter(retryAfter: "-30")
        #expect(negative == .zero)
        #expect(config.retryDelay(attempt: 1, retryAfter: negative, jitter: 1.0) == .milliseconds(100))
    }

    /// The floor must not destroy the precision `retry-after-ms` exists for.
    @Test("A sub-second server delay above the floor is preserved exactly")
    func subSecondPrecisionSurvives() {
        let config = scheduleConfig()
        #expect(config.retryDelay(attempt: 1, retryAfter: .milliseconds(200), jitter: 1.0) == .milliseconds(200))
        #expect(config.retryDelay(attempt: 1, retryAfter: .milliseconds(100), jitter: 1.0) == .milliseconds(100))
        #expect(config.retryDelay(attempt: 1, retryAfter: .milliseconds(99), jitter: 1.0) == .milliseconds(100))
    }
}

// MARK: - Defaults

@Suite("Retry defaults")
struct RetryDefaultsTests {

    @Test("Retry counts normalize to total requests without exceeding the hard ceiling")
    func normalizedAttemptBudget() {
        #expect(LiteLLMClient.Configuration(maxRetries: 0).maxAttempts == 1)
        #expect(LiteLLMClient.Configuration(maxRetries: 3).maxAttempts == 4)
        #expect(LiteLLMClient.Configuration(maxRetries: 9).maxAttempts == 10)
        #expect(LiteLLMClient.Configuration(maxRetries: 100).maxAttempts == 10)
        #expect(LiteLLMClient.Configuration(maxRetries: 100, maxPreConnectRetries: 100).maxPreConnectAttempts == 10)
        #expect(LiteLLMClient.Configuration(maxRetries: 3, maxPreConnectRetries: 0).maxPreConnectAttempts == 1)
    }

    @Test("The shipped client defaults are the ten-retry budget")
    func shippedDefaults() {
        let config = LiteLLMClient.Configuration()
        #expect(config.maxRetries == 10)
        #expect(config.maxAttempts == 10)
        #expect(config.baseRetryDelay == .seconds(1))
        #expect(config.maxRetryDelay == .seconds(60))
        #expect(config.maxPreConnectRetries == 1)
        #expect(config.maxPreConnectAttempts == 2)
        #expect(config.retryDelayBudget == .seconds(300))
    }

    /// The whole point of the budget: ten `Retry-After: 60`s would otherwise be
    /// ten minutes of silence.
    @Test("The default budget cuts the tail off the worst-case table")
    func budgetCutsTheTail() {
        let config = LiteLLMClient.Configuration()
        var spent = Duration.zero
        var taken = 0
        for attempt in 1...config.maxRetries {
            let delay = config.retryDelay(attempt: attempt, retryAfter: nil, jitter: 1.0)
            guard let budget = config.retryDelayBudget, spent + delay <= budget else { break }
            spent += delay
            taken += 1
        }
        // 1+2+4+8+16+32+60+60+60 = 243; the tenth 60 would reach 303 > 300.
        #expect(taken == 9)
        #expect(spent == .seconds(243))
    }
}

// MARK: - RetryNotice

@Suite("RetryNotice")
struct RetryNoticeTests {

    @Test("The summary reads as a status line")
    func summary() {
        let notice = RetryNotice(
            attempt: 4, maxAttempts: 10, delay: .seconds(8), reason: .overloaded, message: "overloaded_error")
        #expect(notice.summary == "Retrying in 8s (request 5/10) — provider busy")
    }

    @Test("Each reason has its own user-facing wording")
    func reasonLabels() {
        #expect(RetryNotice.Reason.overloaded.label == "provider busy")
        #expect(RetryNotice.Reason.rateLimited.label == "rate limited")
        #expect(RetryNotice.Reason.transport.label == "connection problem")
        let limited = RetryNotice(
            attempt: 1, maxAttempts: 10, delay: .seconds(3), reason: .rateLimited, message: "")
        #expect(limited.summary == "Retrying in 3s (request 2/10) — rate limited")
    }

    @Test(
        "Durations format short",
        arguments: [
            (Duration.milliseconds(0), "0ms"),
            (Duration.milliseconds(100), "100ms"),
            (Duration.milliseconds(500), "500ms"),
            (Duration.milliseconds(999), "999ms"),
            (Duration.seconds(1), "1s"),
            (Duration.milliseconds(1500), "1.5s"),
            (Duration.milliseconds(1450), "1.5s"),
            (Duration.milliseconds(1440), "1.4s"),
            (Duration.seconds(8), "8s"),
            (Duration.seconds(60), "60s"),
        ]
    )
    func formatted(pair: (Duration, String)) {
        #expect(RetryNotice.formatted(pair.0) == pair.1)
    }

    /// The formatter reads a `Duration` that can come from a `Retry-After`
    /// header, so it must saturate rather than trap.
    @Test("A saturated duration formats instead of trapping")
    func formattedSaturates() {
        let huge = Duration.seconds(Double(Int64.max).nextDown)
        _ = RetryNotice.formatted(huge)
        #expect(RetryNotice.formatted(.nanoseconds(1)) == "0ms")
        #expect(RetryNotice.formatted(.seconds(-5)) == "0ms")
    }

    @Test("The reason a classified error implies")
    func reasonForError() {
        #expect(RetryNotice.reason(for: DoMoError(.rateLimit(retryAfter: nil), "429")) == .rateLimited)
        #expect(RetryNotice.reason(for: DoMoError(.transport, "reset")) == .transport)
        #expect(
            RetryNotice.reason(for: DoMoError(.provider(status: 529, isRetryable: true), "overloaded"))
                == .overloaded)
    }

    /// `AssemblyEvent` is `Sendable, Hashable`; this is what keeps it that way.
    @Test("A retry notice rides the assembly event stream as a Hashable value")
    func hashableOnTheEventStream() {
        let notice = RetryNotice(
            attempt: 1, maxAttempts: 10, delay: .seconds(1), reason: .overloaded, message: "busy")
        let event = AssemblyEvent.retrying(notice)
        #expect(event == AssemblyEvent.retrying(notice))
        #expect(Set([event, AssemblyEvent.retrying(notice)]).count == 1)
        // Non-terminal: a consumer folding events into a message must not see one.
        #expect(event.terminalMessage == nil)
        #expect(event.isTerminal == false)
    }
}

// MARK: - Millisecond projection

@Suite("Duration to milliseconds")
struct WholeMillisecondsTests {

    @Test("Whole milliseconds truncate toward zero and never trap")
    func projection() {
        #expect(DoMoError.wholeMilliseconds(.seconds(1)) == 1000)
        #expect(DoMoError.wholeMilliseconds(.milliseconds(1500)) == 1500)
        #expect(DoMoError.wholeMilliseconds(.microseconds(999)) == 0)
        #expect(DoMoError.wholeMilliseconds(.zero) == 0)
        #expect(DoMoError.wholeMilliseconds(.milliseconds(-1500)) == -1500)
        // Integer division truncates toward zero; it does not floor. The doc
        // comment used to say "rounds down", which is only true above zero.
        #expect(DoMoError.wholeMilliseconds(.microseconds(-999)) == 0)
        #expect(DoMoError.wholeMilliseconds(.microseconds(-1500)) == -1)
    }

    /// The naive `components.seconds * 1000` traps here. That is the whole
    /// reason this function exists.
    @Test("A duration whose millisecond count overflows Int64 saturates")
    func saturates() {
        #expect(DoMoError.wholeMilliseconds(.seconds(Double(Int64.max).nextDown)) == Int.max)
        #expect(DoMoError.wholeMilliseconds(.seconds(-Double(Int64.max).nextDown)) == Int.min)
    }
}
