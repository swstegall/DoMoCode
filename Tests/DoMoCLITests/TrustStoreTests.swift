// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import DoMoCore
import Foundation
import SystemPackage
import Testing

@Suite(.serialized)
struct TrustStoreTests {

    /// A throwaway directory tree under the system temp dir, removed on cleanup.
    private func makeTempDirectory() throws -> FilePath {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilePath(url.path)
    }

    // MARK: - projectRequiresTrust

    @Test("a bare directory requires no trust")
    func bareDirectoryNeedsNoTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        #expect(projectRequiresTrust(directory: dir) == false)
    }

    @Test("a directory with .domocode/settings.json requires trust")
    func projectSettingsRequireTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        let projectDir = dir.appending(".domocode")
        try FileManager.default.createDirectory(atPath: projectDir.string, withIntermediateDirectories: true)
        try "{}".write(toFile: projectDir.appending("settings.json").string, atomically: true, encoding: .utf8)
        #expect(projectRequiresTrust(directory: dir) == true)
    }

    @Test("a .domocode directory with no settings.json requires no trust")
    func bareConfigDirNeedsNoTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.appending(".domocode").string, withIntermediateDirectories: true)
        #expect(projectRequiresTrust(directory: dir) == false)
    }

    @Test("project instructions require trust")
    func projectInstructionsRequireTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try "Keep the repository instructions visible."
            .write(toFile: dir.appending("AGENTS.md").string, atomically: true, encoding: .utf8)
        #expect(projectRequiresTrust(directory: dir) == true)
    }

    @Test("an empty prompt-resource directory requires no trust")
    func emptyPromptResourceDirectoryNeedsNoTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(
            atPath: dir.appending(".agents").appending("skills").string,
            withIntermediateDirectories: true
        )
        #expect(projectRequiresTrust(directory: dir) == false)
    }

    @Test("an agent profile directory requires trust when it has data")
    func agentProfileRequiresTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        let agents = dir.appending(".domocode").appending("agents")
        try FileManager.default.createDirectory(atPath: agents.string, withIntermediateDirectories: true)
        try "{}".write(toFile: agents.appending("reviewer.md").string, atomically: true, encoding: .utf8)
        #expect(projectRequiresTrust(directory: dir) == true)
    }

    @Test("each .github prompt-resource directory independently requires trust")
    func gitHubResourcesRequireTrust() throws {
        for subdirectory in ["commands", "skills", "agents"] {
            let dir = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(atPath: dir.string) }
            let root = dir.appending(".github").appending(subdirectory)
            try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
            try "Project-authored prompt content."
                .write(toFile: root.appending("entry.md").string, atomically: true, encoding: .utf8)
            #expect(projectRequiresTrust(directory: dir) == true, "\(subdirectory) must be a trust candidate")
        }
    }

    @Test("a CI-only .github directory requires no trust")
    func ciOnlyGitHubDirectoryNeedsNoTrust() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        let workflows = dir.appending(".github").appending("workflows")
        try FileManager.default.createDirectory(atPath: workflows.string, withIntermediateDirectories: true)
        try "name: CI".write(toFile: workflows.appending("ci.yml").string, atomically: true, encoding: .utf8)
        #expect(projectRequiresTrust(directory: dir) == false)
    }

    // MARK: - Decisions

    @Test("an unrecorded directory has no decision")
    func noDecisionByDefault() throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config.string) }
        let store = TrustStore(configDirectory: config)
        #expect(try store.decision(for: config) == nil)
    }

    @Test("a saved trust decision reads back")
    func savedDecisionRoundTrips() throws {
        let config = try makeTempDirectory()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: config.string)
            try? FileManager.default.removeItem(atPath: project.string)
        }
        let store = TrustStore(configDirectory: config)
        try store.setDecision(true, for: project)
        #expect(try store.decision(for: project) == true)

        // A fresh store over the same file sees it — the decision is durable.
        let reopened = TrustStore(configDirectory: config)
        #expect(try reopened.decision(for: project) == true)
    }

    @Test("the nearest ancestor decision applies to a subdirectory")
    func ancestorDecisionApplies() throws {
        let config = try makeTempDirectory()
        let parent = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: config.string)
            try? FileManager.default.removeItem(atPath: parent.string)
        }
        let child = parent.appending("nested").appending("deep")
        try FileManager.default.createDirectory(atPath: child.string, withIntermediateDirectories: true)

        let store = TrustStore(configDirectory: config)
        try store.setDecision(true, for: parent)
        // No decision on the child itself; the parent's trust covers it.
        #expect(try store.decision(for: child) == true)
    }

    @Test("an explicit distrust is distinct from no decision")
    func distrustIsHonored() throws {
        let config = try makeTempDirectory()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: config.string)
            try? FileManager.default.removeItem(atPath: project.string)
        }
        let store = TrustStore(configDirectory: config)
        try store.setDecision(false, for: project)
        #expect(try store.decision(for: project) == false)
    }

    @Test("a nearer decision overrides an ancestor")
    func nearerDecisionWins() throws {
        let config = try makeTempDirectory()
        let parent = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: config.string)
            try? FileManager.default.removeItem(atPath: parent.string)
        }
        let child = parent.appending("child")
        try FileManager.default.createDirectory(atPath: child.string, withIntermediateDirectories: true)

        let store = TrustStore(configDirectory: config)
        try store.setDecision(true, for: parent)
        try store.setDecision(false, for: child)
        #expect(try store.decision(for: child) == false)
        #expect(try store.decision(for: parent) == true)
    }

    @Test("a malformed trust file throws rather than silently allowing")
    func malformedTrustFileThrows() throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config.string) }
        let store = TrustStore(configDirectory: config)
        try "not json at all".write(toFile: store.path.string, atomically: true, encoding: .utf8)
        #expect(throws: DoMoError.self) {
            _ = try store.decision(for: config)
        }
    }
}
