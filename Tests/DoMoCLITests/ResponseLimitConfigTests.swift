// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The configuration half of the adaptive response limit and of gateway
// continuation: that both arrive switched on with no settings file at all, that
// the four-layer precedence holds for every knob that has one, and — the part
// that has bitten this project before — that a bad value produces a warning
// naming the file it is in rather than a thrown error or a silent fall-back.

import DoMoCLI
import DoMoCore
import DoMoHarness
import Foundation
import Testing

@Suite("Response limit and gateway continuation configuration")
struct ResponseLimitConfigTests {

    private func resolve(
        env: [String: String] = [:],
        project: Settings? = nil,
        user: Settings? = nil
    ) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(
            cli: CLIOverrides(), environment: env, project: project, user: user)
    }

    // MARK: On by default

    /// The whole point of the feature is that nobody has to configure it. A
    /// default that only appears once a settings file exists is a default nobody
    /// gets, which is the failure this asserts against.
    @Test("An absent configuration yields the on-by-default settings")
    func absentConfigurationIsOnByDefault() throws {
        let config = try resolve()

        #expect(config.responseLimit.enabled)
        #expect(config.responseLimit.thresholdCharacters == 500)
        #expect(config.responseLimit.jumpPercentage == 10)
        #expect(config.responseLimit.probeEvery == 4)
        #expect(config.responseLimit.minimumThreshold == 200)
        #expect(config.responseLimit.maximumThreshold == 200_000)
        #expect(config.responseLimit.template == "Respond in {limit} characters or less.")

        #expect(config.gatewayContinuation.enabled)
        #expect(config.gatewayContinuation.maxAttempts == 10)
        #expect(config.gatewayContinuation.message == "Refer to previous context and continue.")

        #expect(config.warnings.isEmpty)
    }

    /// The resolver must agree with the policy's own defaults rather than
    /// carrying a second copy of the numbers that could drift from them.
    @Test("The resolved defaults are the settings types' own defaults")
    func defaultsComeFromTheSettingsTypes() throws {
        let config = try resolve()
        #expect(config.responseLimit == ResponseLimitSettings.default)
        #expect(config.gatewayContinuation == GatewayContinuationSettings.default)
    }

    /// Learned ceilings are a fact about the gateway, so they live beside
    /// settings.json and not under the session directory.
    @Test("The learned-threshold file sits in the config directory")
    func statePathIsInTheConfigDirectory() throws {
        let config = try resolve(env: [EnvName.configDir: "/tmp/domocode-config-test"])
        #expect(
            config.responseLimitStatePath.string
                == "/tmp/domocode-config-test/response-limit.json")

        // A session directory pointed somewhere else must not drag it along.
        let split = try resolve(env: [
            EnvName.configDir: "/tmp/domocode-config-test",
            EnvName.sessionDir: "/tmp/somewhere-else",
        ])
        #expect(
            split.responseLimitStatePath.string
                == "/tmp/domocode-config-test/response-limit.json")
    }

    // MARK: Precedence

    @Test("Environment beats project beats user for every knob that has a variable")
    func environmentBeatsProjectBeatsUser() throws {
        let user = Settings(
            responseLimit: ResponseLimitOverrides(
                enabled: false,
                thresholdCharacters: 100,
                jumpPercentage: 1,
                probeEvery: 2
            ),
            gatewayContinuation: GatewayContinuationOverrides(enabled: false, maxAttempts: 1)
        )
        let project = Settings(
            responseLimit: ResponseLimitOverrides(
                enabled: true,
                thresholdCharacters: 200,
                jumpPercentage: 2,
                probeEvery: 3
            ),
            gatewayContinuation: GatewayContinuationOverrides(enabled: true, maxAttempts: 2)
        )

        let fromFiles = try resolve(project: project, user: user)
        #expect(fromFiles.responseLimit.enabled)
        #expect(fromFiles.responseLimit.thresholdCharacters == 200)
        #expect(fromFiles.responseLimit.jumpPercentage == 2)
        #expect(fromFiles.responseLimit.probeEvery == 3)
        #expect(fromFiles.gatewayContinuation.enabled)
        #expect(fromFiles.gatewayContinuation.maxAttempts == 2)
        #expect(fromFiles.warnings.isEmpty)

        let fromEnvironment = try resolve(
            env: [
                EnvName.responseLimit: "false",
                EnvName.responseLimitChars: "900",
                EnvName.responseLimitJumpPercent: "25",
                EnvName.responseLimitProbeEvery: "7",
                EnvName.gatewayContinue: "false",
                EnvName.gatewayContinueMax: "3",
            ],
            project: project,
            user: user
        )
        #expect(!fromEnvironment.responseLimit.enabled)
        #expect(fromEnvironment.responseLimit.thresholdCharacters == 900)
        #expect(fromEnvironment.responseLimit.jumpPercentage == 25)
        #expect(fromEnvironment.responseLimit.probeEvery == 7)
        #expect(!fromEnvironment.gatewayContinuation.enabled)
        #expect(fromEnvironment.gatewayContinuation.maxAttempts == 3)
        #expect(fromEnvironment.warnings.isEmpty)
    }

    /// A layer that states nothing must not overwrite a weaker layer that did.
    /// This is the reason every override field is optional, and the reason a
    /// project file cannot re-enable a feature the user turned off by tuning an
    /// unrelated number.
    @Test("A silent field falls through to the layer below, field by field")
    func silentFieldsFallThrough() throws {
        let user = Settings(
            responseLimit: ResponseLimitOverrides(enabled: false, thresholdCharacters: 100),
            gatewayContinuation: GatewayContinuationOverrides(enabled: false)
        )
        let project = Settings(
            responseLimit: ResponseLimitOverrides(probeEvery: 9),
            gatewayContinuation: GatewayContinuationOverrides(maxAttempts: 5)
        )

        let config = try resolve(project: project, user: user)
        #expect(!config.responseLimit.enabled, "the project tuned a number, it did not re-enable")
        #expect(config.responseLimit.thresholdCharacters == 100)
        #expect(config.responseLimit.probeEvery == 9)
        #expect(config.responseLimit.jumpPercentage == 10, "nobody said, so the default stands")
        #expect(!config.gatewayContinuation.enabled)
        #expect(config.gatewayContinuation.maxAttempts == 5)
    }

    @Test("The three settings-file-only knobs are honoured, project over user")
    func fileOnlyKnobs() throws {
        let user = Settings(
            responseLimit: ResponseLimitOverrides(
                minimumThreshold: 50,
                maximumThreshold: 5_000,
                template: "user says {limit}"
            ),
            gatewayContinuation: GatewayContinuationOverrides(message: "user continues")
        )
        let project = Settings(
            responseLimit: ResponseLimitOverrides(template: "project says {limit}"),
            gatewayContinuation: GatewayContinuationOverrides(message: "project continues")
        )

        let config = try resolve(project: project, user: user)
        #expect(config.responseLimit.minimumThreshold == 50)
        #expect(config.responseLimit.maximumThreshold == 5_000)
        #expect(config.responseLimit.template == "project says {limit}")
        #expect(config.gatewayContinuation.message == "project continues")
        #expect(config.warnings.isEmpty)
    }

    /// An empty string is how a settings file spells "I wrote this key and then
    /// deleted the value"; it is never a setting, and a prompt suffix of `""`
    /// would silently switch the feature off while leaving it enabled.
    @Test("An empty template or message is ignored rather than obeyed")
    func emptyStringsAreIgnored() throws {
        let config = try resolve(
            project: Settings(
                responseLimit: ResponseLimitOverrides(template: ""),
                gatewayContinuation: GatewayContinuationOverrides(message: "")
            ),
            user: Settings(
                responseLimit: ResponseLimitOverrides(template: "user template {limit}"),
                gatewayContinuation: GatewayContinuationOverrides(message: "user message")
            )
        )
        #expect(config.responseLimit.template == "user template {limit}")
        #expect(config.gatewayContinuation.message == "user message")
    }

    @Test(
        "Both boolean knobs accept every spelling of true this codebase already accepts",
        arguments: ["true", "TRUE", "yes", "on", "1"]
    )
    func trueSpellings(word: String) throws {
        let limit = try resolve(
            env: [EnvName.responseLimit: word],
            user: Settings(responseLimit: ResponseLimitOverrides(enabled: false))
        )
        #expect(limit.responseLimit.enabled, "\(word) should read as true")
        #expect(limit.warnings.isEmpty)

        let continuation = try resolve(
            env: [EnvName.gatewayContinue: word],
            user: Settings(gatewayContinuation: GatewayContinuationOverrides(enabled: false))
        )
        #expect(continuation.gatewayContinuation.enabled, "\(word) should read as true")
        #expect(continuation.warnings.isEmpty)
    }

    @Test(
        "Both boolean knobs accept every spelling of false this codebase already accepts",
        arguments: ["false", "False", "no", "off", "0"]
    )
    func falseSpellings(word: String) throws {
        let limit = try resolve(env: [EnvName.responseLimit: word])
        #expect(!limit.responseLimit.enabled, "\(word) should read as false")
        #expect(limit.warnings.isEmpty)

        let continuation = try resolve(env: [EnvName.gatewayContinue: word])
        #expect(!continuation.gatewayContinuation.enabled, "\(word) should read as false")
        #expect(continuation.warnings.isEmpty)
    }

    // MARK: Bad values warn instead of throwing

    /// Neither feature had to be asked for, so neither may cost a session. An
    /// out-of-range value is reported and skipped, exactly as an unparseable
    /// `logLevel` is — never thrown, the way the retry knobs are.
    @Test("An out-of-range value warns and leaves the default standing")
    func outOfRangeResponseLimitValuesWarn() throws {
        let cases: [(overrides: ResponseLimitOverrides, key: String)] = [
            (ResponseLimitOverrides(thresholdCharacters: 0), "responseLimit.thresholdCharacters"),
            (ResponseLimitOverrides(thresholdCharacters: -1), "responseLimit.thresholdCharacters"),
            (ResponseLimitOverrides(jumpPercentage: -1), "responseLimit.jumpPercentage"),
            (ResponseLimitOverrides(jumpPercentage: 10_001), "responseLimit.jumpPercentage"),
            (ResponseLimitOverrides(probeEvery: 0), "responseLimit.probeEvery"),
            (ResponseLimitOverrides(minimumThreshold: 0), "responseLimit.minimumThreshold"),
        ]
        for (overrides, key) in cases {
            let config = try resolve(project: Settings(responseLimit: overrides))
            #expect(config.responseLimit == ResponseLimitSettings.default, "\(key) should not move")
            #expect(config.warnings.count == 1, "\(key) should warn exactly once")
            let warning = config.warnings.first ?? ""
            #expect(warning.contains(key), "the warning must name \(key); got \(warning)")
            #expect(warning.contains("project settings.json"), "got \(warning)")
        }
    }

    @Test(
        "An out-of-range continuation cap warns and leaves the default standing",
        arguments: [-1, 101]
    )
    func outOfRangeMaxAttemptsWarns(attempts: Int) throws {
        let config = try resolve(
            user: Settings(gatewayContinuation: GatewayContinuationOverrides(maxAttempts: attempts))
        )
        #expect(config.gatewayContinuation.maxAttempts == 10)
        #expect(config.warnings.count == 1)
        let warning = config.warnings.first ?? ""
        #expect(warning.contains("gatewayContinuation.maxAttempts"))
        #expect(warning.contains("user settings.json"))
        #expect(warning.contains("between 0 and 100"))
    }

    /// The bounds that have no meaningful ceiling say "at least N" rather than
    /// naming `Int.max`, which would tell a user only that a sentinel exists.
    @Test("A lower-bound-only knob names just its lower bound")
    func lowerBoundOnlyMessage() throws {
        let config = try resolve(project: Settings(responseLimit: ResponseLimitOverrides(probeEvery: 0)))
        let warning = config.warnings.first ?? ""
        #expect(warning.contains("must be at least 1"))
        #expect(!warning.contains("9223372036854775807"))
    }

    @Test("A non-numeric environment value warns and is skipped")
    func nonNumericEnvironmentValueWarns() throws {
        let config = try resolve(env: [EnvName.responseLimitChars: "soon"])
        #expect(config.responseLimit.thresholdCharacters == 500)
        #expect(config.warnings.count == 1)
        let warning = config.warnings.first ?? ""
        #expect(warning.contains(EnvName.responseLimitChars))
        #expect(warning.contains("not an integer"))
    }

    @Test("A non-boolean environment value warns and is skipped")
    func nonBooleanEnvironmentValueWarns() throws {
        let config = try resolve(env: [EnvName.gatewayContinue: "maybe"])
        #expect(config.gatewayContinuation.enabled)
        #expect(config.warnings.count == 1)
        #expect(config.warnings.first?.contains(EnvName.gatewayContinue) == true)
        #expect(config.warnings.first?.contains("true/false") == true)
    }

    /// The house pattern for a rejected value is `logLevel`'s: warn, then let the
    /// next layer answer. A user who set a knob in their settings.json must not
    /// lose it because a stale variable in their shell was misspelled.
    @Test("A rejected environment value falls through to the file layer")
    func rejectedEnvironmentValueFallsThroughToTheFile() throws {
        let config = try resolve(
            env: [EnvName.responseLimitChars: "lots", EnvName.responseLimit: "sure"],
            user: Settings(
                responseLimit: ResponseLimitOverrides(enabled: false, thresholdCharacters: 1_200))
        )
        #expect(config.responseLimit.thresholdCharacters == 1_200)
        #expect(!config.responseLimit.enabled)
        #expect(config.warnings.count == 2)
    }

    @Test("An empty environment variable states nothing and warns about nothing")
    func emptyEnvironmentVariableIsNotAValue() throws {
        let config = try resolve(env: [
            EnvName.responseLimitChars: "",
            EnvName.responseLimit: "",
            EnvName.gatewayContinueMax: "   ",
        ])
        #expect(config.responseLimit == ResponseLimitSettings.default)
        #expect(config.gatewayContinuation == GatewayContinuationSettings.default)
        #expect(config.warnings.isEmpty)
    }

    // MARK: The floor and the ceiling

    /// Stating a ceiling below the floor is a contradiction, and reporting it as
    /// one is more use than silently clamping it somewhere the user did not ask
    /// for.
    @Test("A maximum below the minimum is refused and named")
    func maximumBelowMinimumIsRefused() throws {
        let config = try resolve(
            user: Settings(
                responseLimit: ResponseLimitOverrides(minimumThreshold: 400, maximumThreshold: 100))
        )
        #expect(config.responseLimit.minimumThreshold == 400)
        #expect(config.responseLimit.maximumThreshold == 200_000)
        #expect(config.warnings.count == 1)
        #expect(config.warnings.first?.contains("responseLimit.maximumThreshold") == true)
        #expect(config.warnings.first?.contains("must be at least 400") == true)
    }

    /// When only the floor is raised, past the *default* ceiling, the ceiling
    /// gives way — the floor is the number the user actually wrote down, and the
    /// pair must not be handed on inverted.
    @Test("A floor above the default ceiling raises the ceiling rather than sinking the floor")
    func raisedFloorRaisesTheCeiling() throws {
        let config = try resolve(
            user: Settings(responseLimit: ResponseLimitOverrides(minimumThreshold: 500_000)))
        #expect(config.responseLimit.minimumThreshold == 500_000)
        #expect(config.responseLimit.maximumThreshold == 500_000)
        #expect(config.responseLimit.minimumThreshold <= config.responseLimit.maximumThreshold)
    }

    // MARK: The settings file's wire shape

    /// `Settings.CodingKeys` is written out by hand, so a property added without
    /// its case decodes as `nil` forever and says nothing. This is that guard.
    @Test("Both blocks decode from settings.json under their documented keys")
    func settingsBlocksDecode() throws {
        let json = """
            {
              "responseLimit": {
                "enabled": true,
                "thresholdCharacters": 750,
                "jumpPercentage": 15,
                "probeEvery": 6,
                "minimumThreshold": 300,
                "maximumThreshold": 90000,
                "template": "Keep it under {limit} characters."
              },
              "gatewayContinuation": {
                "enabled": false,
                "maxAttempts": 4,
                "message": "Please continue."
              }
            }
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.responseLimit?.enabled == true)
        #expect(settings.responseLimit?.thresholdCharacters == 750)
        #expect(settings.responseLimit?.jumpPercentage == 15)
        #expect(settings.responseLimit?.probeEvery == 6)
        #expect(settings.responseLimit?.minimumThreshold == 300)
        #expect(settings.responseLimit?.maximumThreshold == 90_000)
        #expect(settings.responseLimit?.template == "Keep it under {limit} characters.")
        #expect(settings.gatewayContinuation?.enabled == false)
        #expect(settings.gatewayContinuation?.maxAttempts == 4)
        #expect(settings.gatewayContinuation?.message == "Please continue.")

        let roundTripped = try JSONDecoder().decode(
            Settings.self, from: JSONEncoder().encode(settings))
        #expect(roundTripped == settings)

        // And the decoded file must actually reach the resolved value.
        let config = try resolve(user: settings)
        #expect(config.responseLimit.thresholdCharacters == 750)
        #expect(config.responseLimit.template == "Keep it under {limit} characters.")
        #expect(!config.gatewayContinuation.enabled)
        #expect(config.gatewayContinuation.maxAttempts == 4)
    }

    /// An omitted block is `nil`, not an empty one: that is what lets the
    /// resolver tell "said nothing" from "said false".
    @Test("An omitted block decodes as nil and changes nothing")
    func omittedBlocksAreNil() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"model":"m"}"#.utf8))
        #expect(settings.responseLimit == nil)
        #expect(settings.gatewayContinuation == nil)

        let config = try resolve(user: settings)
        #expect(config.responseLimit == ResponseLimitSettings.default)
        #expect(config.gatewayContinuation == GatewayContinuationSettings.default)
    }

    /// The names are a documented, permanent surface; a typo here is a knob
    /// nobody can reach and a README that lies.
    @Test("The environment variable names are spelled as the contract states")
    func environmentNames() {
        #expect(EnvName.responseLimit == "DOMOCODE_RESPONSE_LIMIT")
        #expect(EnvName.responseLimitChars == "DOMOCODE_RESPONSE_LIMIT_CHARS")
        #expect(EnvName.responseLimitJumpPercent == "DOMOCODE_RESPONSE_LIMIT_JUMP_PCT")
        #expect(EnvName.responseLimitProbeEvery == "DOMOCODE_RESPONSE_LIMIT_PROBE_EVERY")
        #expect(EnvName.gatewayContinue == "DOMOCODE_GATEWAY_CONTINUE")
        #expect(EnvName.gatewayContinueMax == "DOMOCODE_GATEWAY_CONTINUE_MAX")
    }
}
