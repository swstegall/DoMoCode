// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage
import Testing

import DoMoCore

// MARK: - Fixtures

private func makeTemporaryDirectory() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("response-limit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

/// Runs `prompts` ordinary turns through the policy, asserting that none of them
/// probed. Used to walk the cadence counter up to the point a probe is due
/// without the walk itself hiding an unexpected probe.
private func advance(
    _ state: ResponseLimitState,
    settings: ResponseLimitSettings,
    prompts: Int
) -> ResponseLimitState {
    var current = state
    for _ in 0..<prompts {
        let decision = ResponseLimitPolicy.nextLimit(state: current, settings: settings)
        #expect(decision.isProbe == false)
        current = decision.state
    }
    return current
}

private func write(_ text: String, to path: FilePath) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path.string))
}

// MARK: - The search

@Suite("Adaptive response limit — the search")
struct ResponseLimitPolicyTests {

    @Test("the default response-limit sentence is grammatical and exact")
    func defaultTemplate() {
        #expect(ResponseLimitSettings.defaultTemplate == "Respond in {limit} characters or less.")
        #expect(
            ResponseLimitPolicy.decorated(
                "hello",
                limit: 500,
                template: ResponseLimitSettings.defaultTemplate
            ) == "hello\n\nRespond in 500 characters or less."
        )
    }

    /// The exact sequence the user reported from their gateway, asserted turn by
    /// turn. This is the test that fails if any of the numbered rules drifts.
    @Test("the reported walk-through: 500 seeds, 550 sticks, 605 fails, 577 settles")
    func discoveryWalkthrough() {
        let settings = ResponseLimitSettings()
        var state = ResponseLimitState(threshold: 500)

        // Three ordinary prompts carry the known-good ceiling and do nothing but
        // advance the cadence counter.
        for expected in 1...3 {
            let decision = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
            #expect(decision.limit == 500)
            #expect(decision.isProbe == false)
            #expect(decision.state.promptsSinceProbe == expected)
            state = decision.state
        }

        // The fourth reaches 10% higher.
        let firstProbe = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(firstProbe.limit == 550)
        #expect(firstProbe.isProbe)
        #expect(firstProbe.state.promptsSinceProbe == 0)
        state = firstProbe.state

        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 550,
                wasProbe: true,
                evidence: .delivered,
                responseCharacters: 512
            ),
            state: state,
            settings: settings
        )
        #expect(state.threshold == 550)
        #expect(state.knownBad == nil)
        #expect(state.maxObservedSuccess == 512)
        #expect(state.consecutiveFailures == 0)

        // The next probe reaches 605 and the gateway drops the answer.
        state = advance(state, settings: settings, prompts: 3)
        let secondProbe = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(secondProbe.limit == 605)
        #expect(secondProbe.isProbe)
        state = secondProbe.state

        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 605,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: settings
        )
        #expect(state.knownBad == 605)
        #expect(state.threshold == 550)
        #expect(state.consecutiveFailures == 1)

        // With a bad point known, the probe becomes the midpoint between the two.
        state = advance(state, settings: settings, prompts: 3)
        let thirdProbe = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(thirdProbe.limit == 577)
        #expect(thirdProbe.isProbe)
        state = thirdProbe.state

        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 577,
                wasProbe: true,
                evidence: .delivered,
                responseCharacters: 570
            ),
            state: state,
            settings: settings
        )
        #expect(state.threshold == 577)
        // 605 is still above the new ceiling, so it remains the upper bound.
        #expect(state.knownBad == 605)
        #expect(state.maxObservedSuccess == 570)
    }

    @Test("the cadence decides which prompt probes")
    func cadence() {
        let eager = ResponseLimitSettings(probeEvery: 1)
        let immediate = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 500),
            settings: eager
        )
        #expect(immediate.isProbe)
        #expect(immediate.limit == 550)

        // A zero or negative cadence is read as "every prompt" rather than
        // trapping on a modulus or never probing again.
        let broken = ResponseLimitSettings(probeEvery: 0)
        #expect(
            ResponseLimitPolicy.nextLimit(
                state: ResponseLimitState(threshold: 500),
                settings: broken
            ).isProbe
        )

        let patient = ResponseLimitSettings(probeEvery: 4)
        let waited = advance(ResponseLimitState(threshold: 500), settings: patient, prompts: 3)
        #expect(ResponseLimitPolicy.nextLimit(state: waited, settings: patient).isProbe)
    }

    @Test("a zero jump never probes but still advances the cadence")
    func zeroJumpNeverProbes() {
        let settings = ResponseLimitSettings(jumpPercentage: 0, probeEvery: 1)
        var state = ResponseLimitState(threshold: 500)
        for expected in 1...3 {
            let decision = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
            #expect(decision.isProbe == false)
            #expect(decision.limit == 500)
            #expect(decision.state.promptsSinceProbe == expected)
            state = decision.state
        }
    }

    @Test("the offered limit is clamped into the configured band")
    func clamping() {
        let settings = ResponseLimitSettings(
            probeEvery: 1,
            minimumThreshold: 200,
            maximumThreshold: 600
        )

        // Below the floor: the learned threshold is honoured as state, but never
        // offered as a limit.
        #expect(
            ResponseLimitPolicy.nextLimit(state: ResponseLimitState(threshold: 10), settings: settings)
                .limit == 200
        )

        // A probe that would overshoot the ceiling is capped at it.
        let high = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 590),
            settings: settings
        )
        #expect(high.limit == 600)
        #expect(high.isProbe)

        // A stored threshold above the ceiling is offered as the ceiling, and
        // there is nothing above it left to probe.
        let over = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 5_000),
            settings: settings
        )
        #expect(over.limit == 600)
        #expect(over.isProbe == false)

        // An inverted band cannot invert the clamp.
        let inverted = ResponseLimitSettings(minimumThreshold: 900, maximumThreshold: 100)
        #expect(
            ResponseLimitPolicy.nextLimit(state: ResponseLimitState(threshold: 500), settings: inverted)
                .limit == 900
        )
    }

    @Test("the downward search stops once the midpoint rounds onto the ceiling")
    func binarySearchTerminates() {
        let settings = ResponseLimitSettings(probeEvery: 1)
        var state = ResponseLimitState(threshold: 600)
        state.knownBad = 601

        let decision = ResponseLimitPolicy.nextLimit(state: state, settings: settings)
        #expect(decision.isProbe == false)
        #expect(decision.limit == 600)
        #expect(decision.state.promptsSinceProbe == 1)
    }
}

// MARK: - Learning from an outcome

@Suite("Adaptive response limit — recording outcomes")
struct ResponseLimitRecordTests {

    /// A *delivered* short answer, not ``ResponseLimitEvidence/inconclusive``:
    /// the gateway answered, so the turn is evidence — it just happens to be
    /// evidence that stops short of the ceiling and therefore moves nothing.
    @Test("a short but successful answer proves nothing about the ceiling")
    func shortSuccessIsInconclusive() {
        var state = ResponseLimitState(threshold: 500)
        state.consecutiveFailures = 1

        let after = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 550,
                wasProbe: true,
                evidence: .delivered,
                responseCharacters: 120
            ),
            state: state,
            settings: .default
        )
        #expect(after.threshold == 500)
        #expect(after.knownBad == nil)
        #expect(after.maxObservedSuccess == 120)
        #expect(after.consecutiveFailures == 0)
    }

    @Test("a failed probe records the bad point and leaves the ceiling alone")
    func failedProbeRecordsKnownBad() {
        var state = ResponseLimitState(threshold: 500)
        state.knownBad = 900

        let lowered = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 605,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: .default
        )
        #expect(lowered.knownBad == 605)
        #expect(lowered.threshold == 500)
        #expect(lowered.consecutiveFailures == 1)

        // A higher failure never raises an established bad point.
        let unchanged = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 1_200,
                wasProbe: true,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: lowered,
            settings: .default
        )
        #expect(unchanged.knownBad == 605)
        #expect(unchanged.consecutiveFailures == 2)
        #expect(unchanged.threshold == 500)
    }

    @Test("two ordinary failures in a row back the ceiling off by ten percent")
    func twoFailureBackoff() {
        var state = ResponseLimitState(threshold: 500)
        let failure = ResponseLimitOutcome(
            offeredLimit: 500,
            wasProbe: false,
            evidence: .refusedPlausiblyForLength,
            responseCharacters: 0
        )

        state = ResponseLimitPolicy.record(failure, state: state, settings: .default)
        #expect(state.threshold == 500)
        #expect(state.knownBad == nil)
        #expect(state.consecutiveFailures == 1)

        state = ResponseLimitPolicy.record(failure, state: state, settings: .default)
        // The back-off moves the threshold and nothing else. It used to also
        // write `knownBad = 500` here, which capped every future probe below a
        // limit that was already known to work and — because nothing could clear
        // a bad point — did so permanently. The 10% step on its own is
        // recoverable; the bound was not.
        #expect(state.knownBad == nil)
        #expect(state.threshold == 450)
        #expect(state.consecutiveFailures == 0)
    }

    @Test("a success between two failures stops the back-off")
    func successBreaksTheFailureRun() {
        var state = ResponseLimitState(threshold: 500)
        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 500,
                wasProbe: false,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: .default
        )
        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 500,
                wasProbe: false,
                evidence: .delivered,
                responseCharacters: 40
            ),
            state: state,
            settings: .default
        )
        #expect(state.consecutiveFailures == 0)

        state = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 500,
                wasProbe: false,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: .default
        )
        #expect(state.threshold == 500)
        #expect(state.consecutiveFailures == 1)
    }

    @Test("the back-off never falls through the floor")
    func backoffRespectsFloor() {
        var state = ResponseLimitState(threshold: 410)
        state.consecutiveFailures = 1

        let after = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 410,
                wasProbe: false,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: 0
            ),
            state: state,
            settings: ResponseLimitSettings(minimumThreshold: 400)
        )
        // (410 * 9) / 10 is 369, which is below the floor.
        #expect(after.threshold == 400)
    }

    @Test("a probe that succeeds at or above the known-bad point re-opens the search")
    func successClearsStaleKnownBad() {
        var state = ResponseLimitState(threshold: 500)
        state.knownBad = 600

        let after = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: 700,
                wasProbe: true,
                evidence: .delivered,
                responseCharacters: 690
            ),
            state: state,
            settings: .default
        )
        #expect(after.threshold == 700)
        #expect(after.knownBad == nil)
    }

    @Test("absurd settings and states clamp instead of trapping")
    func absurdInputsDoNotTrap() {
        let huge = ResponseLimitSettings(jumpPercentage: 10_000_000, probeEvery: 1)

        let fromSmall = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 500),
            settings: huge
        )
        #expect(fromSmall.isProbe)
        #expect(fromSmall.limit == 200_000)

        // 500 * 10_000_000 fits; Int.max * 10_000_000 does not, and the
        // saturating multiply is what keeps this a clamp rather than a crash.
        let fromMax = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: Int.max),
            settings: huge
        )
        #expect(fromMax.limit == 200_000)
        #expect(fromMax.isProbe == false)

        let fromOne = ResponseLimitPolicy.nextLimit(
            state: ResponseLimitState(threshold: 1),
            settings: huge
        )
        #expect(fromOne.limit == 100_001)

        // A negative percentage is read as zero rather than shrinking the probe
        // below the threshold.
        let negative = ResponseLimitSettings(jumpPercentage: -50, probeEvery: 1)
        #expect(
            ResponseLimitPolicy.nextLimit(
                state: ResponseLimitState(threshold: 500),
                settings: negative
            ).isProbe == false
        )

        // Every counter and bound at its extreme, in both entry points.
        var extreme = ResponseLimitState(threshold: Int.max)
        extreme.knownBad = Int.min
        extreme.promptsSinceProbe = Int.max
        extreme.consecutiveFailures = Int.max

        #expect(ResponseLimitPolicy.nextLimit(state: extreme, settings: huge).limit == 200_000)

        let recorded = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: Int.max,
                wasProbe: false,
                evidence: .refusedPlausiblyForLength,
                responseCharacters: Int.max
            ),
            state: extreme,
            settings: huge
        )
        #expect(recorded.threshold == 200_000)

        let succeeded = ResponseLimitPolicy.record(
            ResponseLimitOutcome(
                offeredLimit: Int.max,
                wasProbe: true,
                evidence: .delivered,
                responseCharacters: Int.max
            ),
            state: extreme,
            settings: huge
        )
        #expect(succeeded.threshold == 200_000)
        #expect(succeeded.maxObservedSuccess == Int.max)
    }
}

// MARK: - Decoration

@Suite("Adaptive response limit — prompt decoration")
struct ResponseLimitDecorationTests {

    @Test("decoration appends the sentence and replaces a previous one")
    func decorationIsIdempotent() {
        let template = ResponseLimitSettings.defaultTemplate

        let once = ResponseLimitPolicy.decorated("Explain the parser.", limit: 500, template: template)
        #expect(once == "Explain the parser.\n\nRespond in 500 characters or less.")

        #expect(ResponseLimitPolicy.decorated(once, limit: 500, template: template) == once)

        // A different limit from an earlier turn is still recognised as ours.
        #expect(
            ResponseLimitPolicy.decorated(once, limit: 550, template: template)
                == "Explain the parser.\n\nRespond in 550 characters or less."
        )

        // Only the trailing sentence is touched; the body's own blank lines stay.
        #expect(
            ResponseLimitPolicy.decorated("first\n\nsecond", limit: 500, template: template)
                == "first\n\nsecond\n\nRespond in 500 characters or less."
        )

        // Trailing whitespace around a previous sentence does not hide it.
        #expect(
            ResponseLimitPolicy.decorated(
                "hello\n\nRespond in 500 characters or less.  \n",
                limit: 500,
                template: template
            ) == "hello\n\nRespond in 500 characters or less."
        )
    }

    @Test("an image-only prompt still carries the sentence, and carries only it")
    func emptyPromptIsStillDecorated() {
        let template = ResponseLimitSettings.defaultTemplate
        let sentence = "Respond in 500 characters or less."
        #expect(ResponseLimitPolicy.decorated("", limit: 500, template: template) == sentence)
        #expect(ResponseLimitPolicy.decorated("   \n\n ", limit: 500, template: template) == sentence)
    }

    @Test("a template with no token is appended literally and still de-duplicated")
    func tokenlessTemplate() {
        let template = "Keep it short."
        let once = ResponseLimitPolicy.decorated("hello", limit: 500, template: template)
        #expect(once == "hello\n\nKeep it short.")
        #expect(ResponseLimitPolicy.decorated(once, limit: 900, template: template) == once)
    }

    @Test("prose that only resembles the sentence survives")
    func nearMissSurvives() {
        let template = ResponseLimitSettings.defaultTemplate
        let text = "Respond in less than five hundred characters or less."
        #expect(
            ResponseLimitPolicy.decorated(text, limit: 500, template: template)
                == text + "\n\nRespond in 500 characters or less."
        )

        // The same sentence in the MIDDLE of a prompt is the user's text, not
        // ours, and only the last line is ever removed.
        let embedded = "Respond in less than 500 characters or less.\nand then explain why"
        #expect(
            ResponseLimitPolicy.decorated(embedded, limit: 500, template: template)
                == embedded + "\n\nRespond in 500 characters or less."
        )
    }

    @Test("a template ending in the token still round-trips")
    func templateEndingInToken() {
        let template = "Character budget: {limit}"
        let once = ResponseLimitPolicy.decorated("go", limit: 500, template: template)
        #expect(once == "go\n\nCharacter budget: 500")
        #expect(
            ResponseLimitPolicy.decorated(once, limit: 700, template: template)
                == "go\n\nCharacter budget: 700"
        )
    }
}

// MARK: - Persistence

@Suite("Adaptive response limit — persistence")
struct ResponseLimitStoreTests {

    @Test("the file store round-trips a document at mode 0600")
    func fileStoreRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appending("response-limit.json")
        let store = FileResponseLimitStore(path: path)

        #expect(store.load().models.isEmpty)

        var state = ResponseLimitState(threshold: 550)
        state.knownBad = 605
        state.maxObservedSuccess = 540
        state.promptsSinceProbe = 2
        state.consecutiveFailures = 1
        store.save(ResponseLimitDocument(models: ["alias": state]))

        let loaded = store.load()
        #expect(loaded.version == ResponseLimitDocument.currentVersion)
        #expect(loaded.models["alias"] == state)

        let attributes = try FileManager.default.attributesOfItem(atPath: path.string)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint32Value == 0o600)
    }

    @Test("a save merges rather than replaces, so a peer's alias survives")
    func fileStoreSaveMerges() throws {
        let path = try makeTemporaryDirectory().appending("response-limit.json")
        let store = FileResponseLimitStore(path: path)

        store.save(ResponseLimitDocument(models: ["alias": ResponseLimitState(threshold: 550)]))
        store.save(ResponseLimitDocument(models: ["other": ResponseLimitState(threshold: 300)]))

        let merged = store.load()
        #expect(merged.models.count == 2)
        #expect(merged.models["alias"]?.threshold == 550)
        #expect(merged.models["other"]?.threshold == 300)

        // The in-memory double has to answer the same way or it is not a double.
        let memory = InMemoryResponseLimitStore()
        memory.save(ResponseLimitDocument(models: ["alias": ResponseLimitState(threshold: 550)]))
        memory.save(ResponseLimitDocument(models: ["other": ResponseLimitState(threshold: 300)]))
        #expect(memory.load().models.count == 2)
    }

    @Test("a corrupt, truncated or future document loads as empty rather than throwing")
    func brokenDocumentsLoadEmpty() throws {
        let directory = try makeTemporaryDirectory()

        let truncated = directory.appending("truncated.json")
        try write(#"{"version":1,"models":{"alias":{"thresho"#, to: truncated)
        #expect(FileResponseLimitStore(path: truncated).load().models.isEmpty)

        let garbage = directory.appending("garbage.json")
        try write("not json at all", to: garbage)
        #expect(FileResponseLimitStore(path: garbage).load().models.isEmpty)

        let empty = directory.appending("empty.json")
        try write("", to: empty)
        #expect(FileResponseLimitStore(path: empty).load().models.isEmpty)

        // A version this build does not understand is not guessed at.
        let future = directory.appending("future.json")
        try write(#"{"version":99,"models":{"alias":{"threshold":900}}}"#, to: future)
        #expect(FileResponseLimitStore(path: future).load().models.isEmpty)

        // A record with no threshold is not a partial record, it is not a record.
        let thresholdless = directory.appending("thresholdless.json")
        try write(#"{"version":1,"models":{"alias":{"knownBad":900}}}"#, to: thresholdless)
        #expect(FileResponseLimitStore(path: thresholdless).load().models.isEmpty)

        // An absent file is the ordinary first run, not a fault.
        #expect(FileResponseLimitStore(path: directory.appending("absent.json")).load().models.isEmpty)
    }

    @Test("a hand-written minimal record loads with its counters defaulted")
    func minimalDocumentLoads() throws {
        let path = try makeTemporaryDirectory().appending("minimal.json")
        try write(#"{"models":{"alias":{"threshold":900}}}"#, to: path)

        let loaded = FileResponseLimitStore(path: path).load()
        #expect(loaded.models["alias"]?.threshold == 900)
        #expect(loaded.models["alias"]?.knownBad == nil)
        #expect(loaded.models["alias"]?.promptsSinceProbe == 0)
        #expect(loaded.models["alias"]?.consecutiveFailures == 0)
        #expect(loaded.models["alias"]?.maxObservedSuccess == 0)
    }

    @Test("settings decode from a partial object without losing the other fields")
    func settingsDecodePartially() throws {
        let data = Data(#"{"thresholdCharacters":900}"#.utf8)
        let settings = try JSONDecoder().decode(ResponseLimitSettings.self, from: data)
        #expect(settings.thresholdCharacters == 900)
        #expect(settings.enabled)
        #expect(settings.probeEvery == ResponseLimitSettings.default.probeEvery)
        #expect(settings.template == ResponseLimitSettings.defaultTemplate)

        let encoded = try JSONEncoder().encode(settings)
        let round = try JSONDecoder().decode(ResponseLimitSettings.self, from: encoded)
        #expect(round == settings)
    }
}

// MARK: - Controller

@Suite("Adaptive response limit — controller")
struct ResponseLimitControllerTests {

    @Test("the controller decorates, tickets and persists what it learned")
    func controllerRoundTrip() async throws {
        let store = InMemoryResponseLimitStore()
        let controller = ResponseLimitController(
            settings: ResponseLimitSettings(probeEvery: 1),
            store: store
        )

        let decorated = await controller.decorate("Summarise the file.", model: "alias")
        let ticket = try #require(decorated.ticket)
        #expect(ticket.model == "alias")
        #expect(ticket.limit == 550)
        #expect(ticket.isProbe)
        #expect(decorated.text == "Summarise the file.\n\nRespond in 550 characters or less.")
        // The cadence is persisted before the turn runs, not after it settles.
        #expect(store.load().models["alias"]?.promptsSinceProbe == 0)

        await controller.record(ticket, evidence: .delivered, responseCharacters: 540)
        #expect(await controller.currentThreshold(model: "alias") == 550)

        // A resubmitted prompt carries one sentence, at the new limit.
        let again = await controller.decorate(decorated.text, model: "alias")
        #expect(again.text == "Summarise the file.\n\nRespond in 605 characters or less.")
    }

    @Test("a disabled controller changes nothing and issues no ticket")
    func disabledController() async {
        let controller = ResponseLimitController(
            settings: ResponseLimitSettings(enabled: false),
            store: InMemoryResponseLimitStore()
        )
        let result = await controller.decorate("Explain.", model: "alias")
        #expect(result.text == "Explain.")
        #expect(result.ticket == nil)

        let live = await controller.settings
        #expect(live.enabled == false)
    }

    @Test("each alias learns on its own")
    func aliasesAreIndependent() async throws {
        let controller = ResponseLimitController(
            settings: ResponseLimitSettings(probeEvery: 1),
            store: InMemoryResponseLimitStore()
        )

        let first = await controller.decorate("go", model: "fast")
        let fastTicket = try #require(first.ticket)
        await controller.record(fastTicket, evidence: .delivered, responseCharacters: 600)

        let second = await controller.decorate("go", model: "slow")
        let slowTicket = try #require(second.ticket)
        await controller.record(
            slowTicket,
            evidence: .refusedPlausiblyForLength,
            responseCharacters: 0
        )

        #expect(await controller.currentThreshold(model: "fast") == 550)
        #expect(await controller.currentThreshold(model: "slow") == 500)
        #expect(await controller.currentThreshold(model: "unseen") == 500)
    }

    @Test("learning survives a new controller over the same file")
    func learningSurvivesAcrossControllers() async throws {
        let path = try makeTemporaryDirectory().appending("response-limit.json")
        let settings = ResponseLimitSettings(probeEvery: 1)

        let first = ResponseLimitController(settings: settings, store: FileResponseLimitStore(path: path))
        let decorated = await first.decorate("Go.", model: "alias")
        let ticket = try #require(decorated.ticket)
        await first.record(ticket, evidence: .delivered, responseCharacters: 600)

        let second = ResponseLimitController(settings: settings, store: FileResponseLimitStore(path: path))
        #expect(await second.currentThreshold(model: "alias") == 550)
    }
}
