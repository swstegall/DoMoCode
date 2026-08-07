// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - A gateway, simulated

/// Walks `turns` prompts through the policy the way the harness does — decide,
/// send, record — and reports where the learned state ended up and how many
/// probes were actually issued along the way.
///
/// The probe count is the load-bearing half. A threshold that merely *looks*
/// plausible can still belong to an alias that has stopped asking questions
/// entirely, which is the failure this file exists for: an exhaustive sweep of
/// the pre-fix policy found 10,062 successful probes that cleared `knownBad`
/// zero times, and 5,000 healthy turns after an outage that issued no probes at
/// all. Only counting them catches that.
///
/// The gateway model is deliberately crude: for `outageTurns` turns nothing
/// comes back at all, and after that every request is answered with exactly
/// `answerCharacters` characters regardless of the limit asked for. That is the
/// user's reported shape — an outage, then a gateway that was never actually
/// refusing on length — and it is the shape under which the ceiling used to be
/// pinned for good.
private func simulate(
    turns: Int,
    from start: ResponseLimitState,
    settings: ResponseLimitSettings,
    answerCharacters: Int,
    outageTurns: Int = 0
) -> (state: ResponseLimitState, probes: Int) {
    var state = start
    var probes = 0
    for turn in 0..<turns {
        let decision = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        state = decision.state
        if decision.isProbe { probes += 1 }
        let refused = turn < outageTurns
        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: decision.limit,
                wasProbe: decision.isProbe,
                // A dead gateway is `refusedPlausiblyForLength`, not
                // `inconclusive`: it was reached and did not deliver, which is
                // exactly the shape a silent length cap takes. This test is
                // about recovering from the *hardest* honest classification, not
                // about dodging the back-off.
                evidence: refused ? .refusedPlausiblyForLength : .delivered,
                responseCharacters: refused ? 0 : answerCharacters
            ),
            state: state,
            settings: settings
        )
    }
    return (state, probes)
}

private func makeTemporaryDirectory() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("response-limit-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

// MARK: - Recovering from an outage

@Suite("Adaptive response limit — the ceiling can climb back")
struct ResponseLimitRecoveryTests {

    /// The reported regression, end to end.
    ///
    /// Two gateway timeouts followed by three hundred healthy turns each
    /// returning four thousand characters used to leave the threshold at 499 —
    /// forever, and persisted — where the identical run without the outage
    /// reached four thousand-odd. Two rules produced that between them: the
    /// back-off wrote `knownBad = 500`, and nothing could ever clear a
    /// `knownBad`, so every subsequent probe was a binary search bounded below a
    /// limit that had already been answered successfully hundreds of times.
    @Test("two timeouts do not cost the ceiling three hundred healthy turns later")
    func outageDoesNotPinTheCeiling() {
        let settings = ResponseLimitSettings()

        // The outage itself: two ordinary failures, so the back-off fires once.
        let backedOff = simulate(
            turns: 2,
            from: ResponseLimitState(threshold: 500),
            settings: settings,
            answerCharacters: 4_000,
            outageTurns: 2
        )
        #expect(backedOff.state.threshold == 450, "the 10% step is the whole cost")
        #expect(
            backedOff.state.knownBad == nil,
            "a gateway that was down says nothing about which limits are reachable"
        )

        let recovered = simulate(
            turns: 300,
            from: backedOff.state,
            settings: settings,
            answerCharacters: 4_000
        )
        let control = simulate(
            turns: 300,
            from: ResponseLimitState(threshold: 500),
            settings: settings,
            answerCharacters: 4_000
        )

        #expect(recovered.state.knownBad == nil)
        #expect(recovered.state.consecutiveFailures == 0)
        // 3_000 rather than an exact figure: the point is the order of
        // magnitude. The pre-fix run settled at 499 and could not move, and any
        // value up here means the search climbed back through the back-off and
        // kept going.
        #expect(recovered.state.threshold > 3_000)
        #expect(control.state.threshold > 3_000)
        #expect(recovered.probes > 20, "a recovered alias keeps asking questions")
    }

    /// The second reproduction: a long outage, then five thousand perfectly
    /// healthy turns that used to issue ZERO probes because the failed probes
    /// during the outage left a `knownBad` the search had converged onto and
    /// nothing could retire.
    @Test("five thousand healthy turns after a forty-turn outage probe again")
    func healthyTurnsAfterALongOutageProbeAgain() {
        let settings = ResponseLimitSettings()

        let outage = simulate(
            turns: 40,
            from: ResponseLimitState(threshold: 500),
            settings: settings,
            answerCharacters: 4_000,
            outageTurns: 40
        )
        // The back-off walks the threshold down toward the floor during a long
        // outage; that is by design and is meant to be cheap to undo.
        #expect(outage.state.threshold <= 500)

        let healthy = simulate(
            turns: 5_000,
            from: outage.state,
            settings: settings,
            answerCharacters: 4_000
        )
        #expect(healthy.probes > 0, "zero probes is the frozen-search signature")
        #expect(healthy.state.threshold > 3_000)
        #expect(healthy.state.knownBad == nil)
    }
}

// MARK: - Failures that are not evidence

@Suite("Adaptive response limit — inconclusive failures")
struct ResponseLimitInconclusiveTests {

    /// An expired token, a 429, a quota rejection, a tool that threw and a run
    /// the user cancelled all reach the policy as the same case, and it has to
    /// be a true no-op — not "counted but not acted on". Any counter this moved
    /// would be read by a later rule, which is how a morning of 401s used to
    /// walk the ceiling to the floor two failures at a time.
    @Test("an auth failure and a cancelled run change nothing whatsoever")
    func inconclusiveOutcomesAreANoOp() {
        var state = ResponseLimitState(threshold: 500)
        state.knownBad = 605
        state.maxObservedSuccess = 540
        state.promptsSinceProbe = 2
        state.consecutiveFailures = 1
        state.successesSinceKnownBad = 7

        for wasProbe in [true, false] {
            var walked = state
            for turn in 1...50 {
                walked = ResponseLimitPolicy.record(
                    ResponseLimitOutcome(
                        offeredLimit: 605,
                        wasProbe: wasProbe,
                        evidence: .inconclusive,
                        responseCharacters: 0
                    ),
                    state: walked,
                    settings: .default
                )
                #expect(walked == state, "turn \(turn), wasProbe \(wasProbe)")
            }
        }
    }

    /// Fifty inconclusive turns in a row are exactly the run that used to be
    /// expensive: twenty-five back-offs, each 10%, straight down to the floor.
    @Test("a long run of inconclusive failures never reaches the back-off")
    func inconclusiveFailuresNeverBackOff() {
        var state = ResponseLimitState(threshold: 500)
        for _ in 0..<50 {
            state = ResponseLimitPolicy.record(
                ResponseLimitOutcome(
                    offeredLimit: 500,
                    wasProbe: false,
                    evidence: .inconclusive,
                    responseCharacters: 0
                ),
                state: state,
                settings: .default
            )
        }
        #expect(state.threshold == 500)
        #expect(state.consecutiveFailures == 0)
        #expect(state.knownBad == nil)
    }

    @Test("the controller does not even touch the store for an inconclusive turn")
    func controllerSkipsTheStore() async throws {
        let store = InMemoryResponseLimitStore()
        let controller = ResponseLimitController(
            settings: ResponseLimitSettings(probeEvery: 1),
            store: store
        )
        let decorated = await controller.decorate("go", model: "alias")
        let ticket = try #require(decorated.ticket)
        let before = store.load()

        for _ in 0..<40 {
            await controller.record(ticket, evidence: .inconclusive, responseCharacters: 0)
        }
        // Byte-identical, not merely equivalent: the store merges what it is
        // handed, so a write of state read moments earlier would revert whatever
        // a concurrently settling turn had learned about the same alias.
        #expect(store.load() == before)
        #expect(await controller.currentThreshold(model: "alias") == 500)
    }
}

// MARK: - Retiring a bad point

@Suite("Adaptive response limit — the bad point expires")
struct ResponseLimitReprobeTests {

    @Test("a converged search re-opens after reprobeAfterSuccesses delivered turns")
    func convergedSearchReopens() {
        let settings = ResponseLimitSettings(probeEvery: 1, reprobeAfterSuccesses: 5)
        var state = ResponseLimitState(threshold: 600)
        state.knownBad = 601

        // Converged: the midpoint between 600 and 601 rounds onto 600, so there
        // is nothing strictly above the threshold left to ask for. Before the
        // expiry this was the end of the alias' search.
        #expect(ResponseLimitPolicy.nextLimit(state: state, settings: settings).isProbe == false)

        let delivered = ResponseLimitOutcome(
            offeredLimit: 600,
            wasProbe: false,
            evidence: .delivered,
            responseCharacters: 900
        )
        for turn in 1...4 {
            state = ResponseLimitPolicy.record(delivered, state: state, settings: settings)
            #expect(state.knownBad == 601, "\(turn) turns is not yet the evidence asked for")
            #expect(state.successesSinceKnownBad == turn)
            #expect(state.threshold == 600, "a non-probe never moves the ceiling")
        }

        state = ResponseLimitPolicy.record(delivered, state: state, settings: settings)
        #expect(state.knownBad == nil)
        #expect(state.successesSinceKnownBad == 0, "no bound, no clock")

        let reopened = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(reopened.isProbe)
        #expect(reopened.limit == 660, "the upward search resumes at jumpPercentage")
    }

    /// The expiry must not interrupt a search that is still narrowing, or the
    /// binary search would never get to finish and the alias would keep
    /// re-asking a question it was two probes away from answering.
    @Test("a bound the search is still narrowing toward does not expire")
    func liveSearchKeepsItsBound() {
        let settings = ResponseLimitSettings(reprobeAfterSuccesses: 5)
        var state = ResponseLimitState(threshold: 500)
        state.knownBad = 900

        let delivered = ResponseLimitOutcome(
            offeredLimit: 500,
            wasProbe: false,
            evidence: .delivered,
            responseCharacters: 600
        )
        for _ in 0..<100 {
            state = ResponseLimitPolicy.record(delivered, state: state, settings: settings)
        }
        // The midpoint is still 700, well above the threshold.
        #expect(state.knownBad == 900)
        #expect(state.successesSinceKnownBad == 100)
    }

    /// A freshly recorded bound gets a fresh clock. Inheriting the previous
    /// bound's count would retire a bound recorded seconds ago on the strength
    /// of turns delivered before it existed.
    @Test("recording a new bad point restarts the expiry clock")
    func aNewBoundRestartsTheClock() {
        let settings = ResponseLimitSettings(probeEvery: 1, reprobeAfterSuccesses: 5)
        var state = ResponseLimitState(threshold: 500)
        state.knownBad = 900
        state.successesSinceKnownBad = 4

        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 700,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: settings
        )
        #expect(state.knownBad == 700)
        #expect(state.successesSinceKnownBad == 0)
    }

    /// A bound recorded during an outage that then converges is exactly the
    /// 10,062-probe sweep's dead end. It has to come back on its own.
    @Test("a failed probe during an outage does not end the search for good")
    func aFailedProbeIsNotPermanent() {
        let settings = ResponseLimitSettings(probeEvery: 1, reprobeAfterSuccesses: 3)
        var state = ResponseLimitState(threshold: 500)

        let probe = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(probe.limit == 550)
        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: probe.limit,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: probe.state,
            settings: settings
        )
        #expect(state.knownBad == 550)

        // The downward search converges on 549 and then has nothing to ask.
        let healthy = simulate(
            turns: 200,
            from: state,
            settings: settings,
            answerCharacters: 4_000
        )
        #expect(healthy.state.knownBad == nil, "the bound retired once it stopped narrowing")
        #expect(healthy.state.threshold > 3_000, "and the upward search resumed")
    }
}

// MARK: - The floor

@Suite("Adaptive response limit — the floor is not absorbing")
struct ResponseLimitFloorTests {

    /// A limit clamped up to the floor and then refused must not record the
    /// floor as unreachable: the threshold can never go below the floor either,
    /// so `knownBad == threshold == minimum` offers no candidate at all and the
    /// alias would be stuck at the minimum for the life of the state file.
    @Test("a refusal at the floor records no bad point")
    func refusalAtTheFloorRecordsNothing() {
        let settings = ResponseLimitSettings(probeEvery: 1, minimumThreshold: 200)
        let decision = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 10),
            settings: settings
        )
        #expect(decision.limit == 200, "a sub-floor threshold is still offered as the floor")
        #expect(decision.isProbe)

        let after = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: decision.limit,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: decision.state,
            settings: settings
        )
        #expect(after.knownBad == nil)
    }

    /// A state file written by the build that did record the floor loads with
    /// `knownBad == threshold == minimum`. It must thaw rather than needing the
    /// user to find and delete `response-limit.json`.
    @Test("a state frozen at the floor by an older build thaws")
    func aFrozenStateThaws() {
        let settings = ResponseLimitSettings(probeEvery: 1, reprobeAfterSuccesses: 3)
        var frozen = ResponseLimitState(threshold: 200)
        frozen.knownBad = 200

        #expect(ResponseLimitPolicy.nextLimit(state: frozen, settings: settings).isProbe == false)

        let delivered = ResponseLimitOutcome(
            offeredLimit: 200,
            wasProbe: false,
            evidence: .delivered,
            responseCharacters: 250
        )
        for _ in 0..<3 {
            frozen = ResponseLimitPolicy.record(delivered, state: frozen, settings: settings)
        }
        #expect(frozen.knownBad == nil)

        let thawed = ResponseLimitPolicy.nextLimit(state: frozen, settings: settings)
        #expect(thawed.isProbe)
        #expect(thawed.limit == 220)
    }

    /// The whole trip: floor, outage over, climb back.
    @Test("an alias driven to the floor climbs off it")
    func theFloorIsEscapable() {
        let settings = ResponseLimitSettings(minimumThreshold: 200)
        var floored = ResponseLimitState(threshold: 200)
        floored.knownBad = 200

        let healthy = simulate(
            turns: 1_000,
            from: floored,
            settings: settings,
            answerCharacters: 4_000
        )
        #expect(healthy.probes > 0)
        #expect(healthy.state.threshold > 1_000)
    }
}

// MARK: - Persisting what the expiry needs

@Suite("Adaptive response limit — expiry state on disk")
struct ResponseLimitExpiryPersistenceTests {

    @Test("the expiry clock round-trips, and a pre-expiry file reads as zero")
    func expiryClockPersists() throws {
        let directory = try makeTemporaryDirectory()

        let path = directory.appending("response-limit.json")
        let store = FileResponseLimitStore(path: path)
        var state = ResponseLimitState(threshold: 600)
        state.knownBad = 601
        state.successesSinceKnownBad = 12
        store.save(ResponseLimitDocument(models: ["alias": state]))
        #expect(store.load().models["alias"] == state)

        // Written by a build that had no expiry. Zero is the right reading:
        // the bound gets the full grace from here rather than retiring on the
        // first healthy turn after the upgrade.
        let legacy = directory.appending("legacy.json")
        try Data(#"{"version":1,"models":{"alias":{"threshold":600,"knownBad":601}}}"#.utf8)
            .write(to: URL(fileURLWithPath: legacy.string))
        let loaded = FileResponseLimitStore(path: legacy).load()
        #expect(loaded.models["alias"]?.successesSinceKnownBad == 0)
        #expect(loaded.models["alias"]?.knownBad == 601)
    }

    @Test("reprobeAfterSuccesses defaults to 25 and survives a partial settings object")
    func reprobeSettingDecodes() throws {
        #expect(ResponseLimitSettings.default.reprobeAfterSuccesses == 25)

        let partial = try JSONDecoder().decode(
            ResponseLimitSettings.self,
            from: Data(#"{"thresholdCharacters":900}"#.utf8)
        )
        #expect(partial.reprobeAfterSuccesses == 25)

        let stated = try JSONDecoder().decode(
            ResponseLimitSettings.self,
            from: Data(#"{"reprobeAfterSuccesses":3}"#.utf8)
        )
        #expect(stated.reprobeAfterSuccesses == 3)

        let round = try JSONDecoder().decode(
            ResponseLimitSettings.self,
            from: JSONEncoder().encode(stated)
        )
        #expect(round == stated)
    }
}
