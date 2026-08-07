// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The process-wide half of the adaptive response limit: that the CLI builds ONE
// controller, that it is pointed at the state file the configuration named, and
// that every surface reading `ProcessHarnessDefaults.current` gets that same
// instance rather than one of its own.
//
// The identity assertion is the load-bearing one. A second controller in the same
// process is not a crash and not a wrong answer on any single turn — both copies
// keep decorating prompts with plausible numbers — it is a slow loss of everything
// the probing learned, because each writes the shared state file from its own
// half of the evidence. Nothing else in the suite would notice.
//
// What is deliberately NOT asserted here: that the limit sentence reaches the
// wire. That belongs to the harness, which does the decorating, and to the
// end-to-end runs that drive the real binary.

import DoMoCLI
import DoMoCore
import DoMoHarness
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct ProcessHarnessDefaultsTests {

    /// A configuration resolved against an isolated config directory, so the state
    /// file this writes cannot be the developer's real `~/.domocode/response-limit.json`.
    private func resolve(configDirectory: URL) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(
            cli: CLIOverrides(),
            environment: [EnvName.configDir: configDirectory.path],
            project: nil,
            user: nil
        )
    }

    private func makeConfigDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-response-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Installation

    @Test("install publishes one controller that every surface reads")
    func installPublishesASingleController() throws {
        let directory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = try resolve(configDirectory: directory)
        let installed = ProcessHarnessDefaults.install(for: configuration)

        // Two independent reads, because a surface reads this where it happens to
        // build its harness rather than once at startup — a `current` that rebuilt
        // per access would satisfy a single read and still give `-p` and the REPL
        // two controllers.
        let firstRead = ProcessHarnessDefaults.current
        let secondRead = ProcessHarnessDefaults.current

        #expect(installed.responseLimit != nil)
        #expect(firstRead.responseLimit === installed.responseLimit)
        #expect(secondRead.responseLimit === installed.responseLimit)
        #expect(secondRead.gatewayContinuation == configuration.gatewayContinuation)
    }

    @Test("nothing installed means nothing decorates")
    func theUnconfiguredDefaultsDecorateNothing() {
        // A harness built outside a `domo` invocation — a test, an embedding, and
        // `--replay`, which returns before any configuration is resolved — must
        // send the prompt as written. Decoration changes what is persisted to the
        // session file, so the un-installed answer is "don't".
        #expect(ProcessHarnessDefaults.unconfigured.responseLimit == nil)
        #expect(ProcessHarnessDefaults.unconfigured.gatewayContinuation == .default)
    }

    // MARK: The state file

    @Test("the controller learns into the configured state path")
    func theControllerWritesTheConfiguredStateFile() async throws {
        let directory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = try resolve(configDirectory: directory)
        #expect(configuration.responseLimitStatePath == FilePath(directory.path).appending("response-limit.json"))

        let controller = ProcessHarnessDefaults.makeResponseLimitController(for: configuration)
        let threshold = configuration.responseLimit.thresholdCharacters
        #expect(await controller.currentThreshold(model: "alias-under-test") == threshold)

        let decorated = await controller.decorate("hello", model: "alias-under-test")
        let ticket = try #require(decorated.ticket)
        #expect(ticket.model == "alias-under-test")
        // The seed threshold, not a probe: the cadence has not come round yet on the
        // very first prompt of a fresh state file.
        #expect(ticket.limit == threshold)
        #expect(ticket.isProbe == false)
        // Asserted as "the original text plus something naming the limit" rather
        // than against the template's exact wording, which is a configurable string.
        #expect(decorated.text.hasPrefix("hello"))
        #expect(decorated.text.contains(String(threshold)))

        await controller.record(ticket, succeeded: true, responseCharacters: threshold + 100)

        // A non-probe success does not move the ceiling — it only confirms it.
        #expect(await controller.currentThreshold(model: "alias-under-test") == threshold)
        #expect(FileManager.default.fileExists(atPath: configuration.responseLimitStatePath.string))
    }

    @Test("a fresh controller reads back what the previous process learned")
    func learnedStateSurvivesANewController() async throws {
        let directory = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = try resolve(configDirectory: directory)
        let first = ProcessHarnessDefaults.makeResponseLimitController(for: configuration)
        let threshold = configuration.responseLimit.thresholdCharacters

        // Drive the cadence far enough to reach a probe, then confirm it, which is
        // the one outcome that moves the ceiling.
        var moved = threshold
        for _ in 0..<(configuration.responseLimit.probeEvery + 1) {
            let decorated = await first.decorate("hello", model: "alias-under-test")
            guard let ticket = decorated.ticket else { continue }
            await first.record(ticket, succeeded: true, responseCharacters: ticket.limit)
            moved = await first.currentThreshold(model: "alias-under-test")
        }
        #expect(moved > threshold)

        // The next `domo` process builds its controller the same way and must start
        // from what this one learned rather than from the seed.
        let second = ProcessHarnessDefaults.makeResponseLimitController(for: configuration)
        #expect(await second.currentThreshold(model: "alias-under-test") == moved)
        // A model nobody has probed still starts at the configured seed.
        #expect(await second.currentThreshold(model: "never-seen") == threshold)
    }
}
