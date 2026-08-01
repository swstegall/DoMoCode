// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The two files DoMoCode reads, modifies and writes back — settings.json (permission
// grants) and trust.json (project trust decisions) — under concurrency, symlinks and
// non-default modes.
//
// Every test here is about a failure that leaves a perfectly valid file behind. A lost
// update is not corruption: `rename(2)` guarantees the document is whole, so the only
// symptom of losing a grant is being asked again for a permission that was granted
// "always", and the only symptom of losing a trust decision is being asked to trust a
// directory that was already trusted. Nothing logs, nothing crashes, and no amount of
// staring at the resulting file shows anything wrong with it.
//
// Note for anyone tempted to cover this by driving the binary: `domo -p` can NEVER
// persist a grant. The headless prompter returns `.once` even under `--yolo`, and
// `.once` is not "always", so the persist closure is never called. Only an interactive
// run or `--serve` reaches this code.

import DoMoCore
import DoMoPermissions
import Foundation
import SystemPackage
import Testing

// `@testable` for `PermissionSetup`, which is internal to DoMoCLI. `Settings` and
// `TrustStore` are public and would not need it.
@testable import DoMoCLI

// MARK: - Fixtures

/// A throwaway directory tree under the system temp dir.
private func makeTempDirectory() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("domocode-settings-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func grant(_ pattern: String) -> Ruleset {
    [PermissionRule(permission: "bash", pattern: pattern, action: .allow)]
}

/// The bash patterns recorded in a settings.json, in file order.
private func grantedPatterns(inSettingsAt path: String) throws -> [String] {
    let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    return fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: "/home/tester").map(\.pattern)
}

private func posixMode(of path: String) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o7777 }
}

private func setMode(_ mode: Int, of path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

// MARK: - settings.json

@Suite("settings.json grant persistence", .serialized)
struct SettingsPersistenceTests {

    @Test("every one of eight concurrent grants survives")
    func concurrentGrantsAllSurvive() async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        let persist = PermissionSetup.persister(configDirectory: config)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { await persist(grant("cmd\(index) *")) }
            }
        }

        let found = try grantedPatterns(inSettingsAt: path)
        for index in 0..<8 {
            #expect(found.contains("cmd\(index) *"), "grant \(index) was lost; the file holds \(found)")
        }
    }

    /// The deterministic half of the lock story. The concurrency test above depends on
    /// the scheduler actually interleaving; this one does not — it takes the lock and
    /// checks that the persister respects it, so deleting the lock fails this every
    /// time on every machine.
    @Test("the persister respects a lock somebody else is holding, and writes once it is free")
    func persisterHonorsAHeldLock() async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        let persist = PermissionSetup.persister(configDirectory: config)

        let held = try await FileLock.withLock(at: PermissionSetup.settingsLockPath(path)) {
            () async -> Bool in
            await persist(grant("git *"))
            return true
        }
        #expect(held == .ran(true), "the test could not take the lock it needs to hold, so it proved nothing")
        #expect(
            try grantedPatterns(inSettingsAt: path).isEmpty,
            "the persister wrote while another holder had the lock"
        )

        // And the refusal above was contention, not a broken persister.
        await persist(grant("git *"))
        #expect(try grantedPatterns(inSettingsAt: path) == ["git *"])
    }

    /// A held lock and a lock that cannot be opened at all used to be the same
    /// `nil`, so both were reported as "another process is writing \(path)" — which
    /// for the second is a lie that sends the user looking for a `domo` that is not
    /// running instead of at the thing standing in the lock file's place.
    @Test("contention and an unopenable lock are told apart")
    func contentionIsDistinguishedFromABrokenLock() async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)

        // Genuine contention: somebody else is holding the very lock the persist wants.
        let whileHeld = try await FileLock.withLock(at: PermissionSetup.settingsLockPath(path)) {
            () async -> PermissionSetup.PersistResult in
            await PermissionSetup.persistGrants(
                grant("git *"), settingsPath: path, configDirectory: config)
        }
        #expect(whileHeld == .ran(.contended))
        #expect(FileManager.default.fileExists(atPath: path) == false, "it wrote anyway")

        // Not contention: a directory sitting where the lock file goes, so `open` fails
        // EISDIR and no wait would ever have helped.
        let broken = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: broken) }
        let brokenPath = PermissionSetup.userSettingsPath(broken)
        try FileManager.default.createDirectory(
            atPath: PermissionSetup.settingsLockPath(brokenPath), withIntermediateDirectories: true)

        let result = await PermissionSetup.persistGrants(
            grant("git *"), settingsPath: brokenPath, configDirectory: broken)

        guard case .lockUnopenable = result else {
            Issue.record("an unopenable lock was reported as \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: brokenPath) == false, "it wrote anyway")
    }

    /// The lock has to name the same file before and after the first save, and
    /// `URL.resolvingSymlinksInPath()` did not: it resolves a symlink only once the
    /// target exists, and the first save is what creates the target. So writer A
    /// locked `.settings.json.lock`, created the target inside its critical section,
    /// and writer B — arriving one instant later — locked `.real.json.lock` and
    /// read-modify-wrote right alongside it.
    @Test("the settings lock does not move when a dangling symlink's target appears")
    func settingsLockIsStableAcrossADanglingSymlink() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dotfiles = root + "/dotfiles"
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let target = dotfiles + "/settings.json"
        let link = PermissionSetup.userSettingsPath(config)
        // Dangling: the dotfiles repository has no settings.json yet.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        // What writer A computed before anything existed.
        let before = PermissionSetup.settingsLockPath(link)
        await PermissionSetup.persister(configDirectory: config)(grant("git *"))
        #expect(FileManager.default.fileExists(atPath: target), "the first save did not create it")
        #expect(PermissionSetup.settingsLockPath(link) == before, "the lock moved under the holder")

        // And writer B, entering now, contends with the lock A is still holding.
        let second = try await FileLock.withLock(at: before) {
            () async -> PermissionSetup.PersistResult in
            await PermissionSetup.persistGrants(
                grant("npm *"), settingsPath: link, configDirectory: config)
        }
        #expect(second == .ran(.contended))
        #expect(
            try grantedPatterns(inSettingsAt: target) == ["git *"],
            "the second writer wrote inside the first one's critical section"
        )
    }

    @Test("a settings.json that is a symlink is written THROUGH, not replaced")
    func writesThroughASymlink() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = root + "/dotfiles"
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let target = real + "/settings.json"
        try #"{"model":"gpt-x"}"#.write(toFile: target, atomically: true, encoding: .utf8)
        let link = PermissionSetup.userSettingsPath(config)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        await PermissionSetup.persister(configDirectory: config)(grant("git *"))

        // Foundation's atomic write replaces the link with a regular file, which
        // detaches a dotfiles-managed config from its repository without a word.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
        #expect(try grantedPatterns(inSettingsAt: target) == ["git *"])
    }

    /// 0600 is the mode a user reaches for; 0640 is the one that could not have been
    /// arrived at by accident, since no common umask produces it.
    ///
    /// Honest about what this catches: on Darwin, Foundation's atomic write *also*
    /// passes this, because `replaceItemAt` copies the old file's metadata onto the
    /// replacement. What it pins is the guarantee `AtomicFileWrite` documents, on
    /// every platform — including the ones whose atomic write is a plain
    /// write-temp-and-rename. The mode regression that is measurable on Darwin today
    /// is in ``createsANewFileOwnerOnly``.
    @Test("an existing file keeps its mode", arguments: [0o600, 0o640])
    func preservesAnExistingMode(_ mode: Int) async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        try setMode(mode, of: path)

        await PermissionSetup.persister(configDirectory: config)(grant("git *"))

        #expect(try posixMode(of: path) == mode)
        #expect(try grantedPatterns(inSettingsAt: path) == ["git *"], "the grant was not written at all")
    }

    /// The measured Foundation regression: `String.write(toFile:atomically:)` creates
    /// at 0644 under the common umask, so the first "Allow always" a user ever clicks
    /// leaves world-readable the one file that names their API-key variable and
    /// records every permission decision they have made.
    @Test("a settings.json created by a grant is owner-only")
    func createsANewFileOwnerOnly() async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)

        await PermissionSetup.persister(configDirectory: config)(grant("git *"))

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try posixMode(of: path) == 0o600)
    }

    @Test("the config directory does not have to exist yet")
    func createsTheConfigDirectory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Never created: the lock file lives here too, so this is the case that fails
        // if the directory is created after the lock is taken instead of before.
        let config = root + "/never-created"

        await PermissionSetup.persister(configDirectory: config)(grant("git *"))

        #expect(try grantedPatterns(inSettingsAt: PermissionSetup.userSettingsPath(config)) == ["git *"])
    }

    // MARK: The trailing comma, end to end

    @Test("a trailing-comma settings.json loads both its settings and its permission block")
    func trailingCommaLoadsBothHalves() throws {
        let configDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: configDirectory) }
        let path = PermissionSetup.userSettingsPath(configDirectory)
        let text = """
            {
              "model": "gpt-x",
              "permission": {
                "bash": { "git *": "allow" },
              },
            }
            """
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(text.utf8))
        #expect(decoded.model == "gpt-x", "Foundation has always read this file; the premise is wrong")

        let loaded = PermissionSetup.configAndDiagnostic(path)
        #expect(loaded.diagnostic == nil)
        #expect(fromConfig(loaded.config, homeDirectory: "/home/tester").map(\.pattern) == ["git *"])
    }

    @Test("a trailing comma no longer silently refuses every grant, forever")
    func trailingCommaStillAcceptsGrants() async throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        try """
            {
              "model": "gpt-x",
              "permission": { "bash": { "*": "ask" } },
            }
            """.write(toFile: path, atomically: true, encoding: .utf8)

        await PermissionSetup.persister(configDirectory: config)(grant("git *"))

        #expect(try grantedPatterns(inSettingsAt: path) == ["*", "git *"])
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(text.utf8)).model == "gpt-x")
    }

    // MARK: Reporting

    @Test("an unparseable settings.json is reported rather than read as an empty config")
    func unparseableFileIsReported() throws {
        let config = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: config) }
        let path = PermissionSetup.userSettingsPath(config)
        let text = """
            {
              "model": "gpt-x",
              "permission": { "bash": { "git *": allow } }
            }
            """
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        let loaded = PermissionSetup.configAndDiagnostic(path)
        #expect(loaded.config.isEmpty)
        let reported = try #require(loaded.diagnostic, "a broken permission block must be reported, not swallowed")
        #expect(reported.file == path)
        #expect(reported.keyPath == ["permission", "bash", "git *"])
        #expect(reported.location?.line == 3)
    }

    @Test("an absent settings.json is not news")
    func absentFileIsNotReported() throws {
        let configDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: configDirectory) }
        let loaded = PermissionSetup.configAndDiagnostic(PermissionSetup.userSettingsPath(configDirectory))
        #expect(loaded.config.isEmpty)
        #expect(loaded.diagnostic == nil)
    }
}

// MARK: - trust.json

@Suite("trust store writes", .serialized)
struct TrustStoreLockTests {

    @Test("every one of four concurrent trust decisions survives")
    func concurrentDecisionsAllSurvive() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = TrustStore(configDirectory: FilePath(root + "/config"))
        let projects = (0..<4).map { FilePath(root + "/project\($0)") }

        // Throwing group: a lock timeout must surface as the test's failure, not be
        // swallowed into "the decision is missing" three lines later.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for project in projects {
                group.addTask { try store.setDecision(true, for: project) }
            }
            try await group.waitForAll()
        }

        for project in projects {
            #expect(try store.decision(for: project) == true, "the decision for \(project) was lost")
        }
    }

    /// As with settings.json: the deterministic half. Removing the lock makes this
    /// `setDecision` succeed, and the expectation fails.
    @Test("setDecision reports contention instead of racing")
    func setDecisionThrowsWhenTheLockIsHeld() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let store = TrustStore(configDirectory: FilePath(config))
        let project = FilePath(root + "/project")

        let held = try await FileLock.withLock(at: store.lockPath) { () -> Bool in
            #expect(throws: DoMoError.self) {
                try store.setDecision(true, for: project)
            }
            return true
        }
        #expect(held == .ran(true), "the test could not take the lock it needs to hold, so it proved nothing")
        #expect(try store.decision(for: project) == nil, "the decision was written despite the held lock")

        // And the refusal was contention, not a broken store.
        try store.setDecision(true, for: project)
        #expect(try store.decision(for: project) == true)
    }

    /// The same moving-lock defect as settings.json, and worse here: `setDecision`
    /// does not merely lose a decision when it takes the wrong lock, it *succeeds*
    /// under somebody else's — bypassing the "a lock timeout is a real error here"
    /// guarantee its own documentation makes, rather than degrading it.
    ///
    /// `URL.resolvingSymlinksInPath()` resolves a symlink only once the target
    /// exists, and the first `setDecision` is what creates the target. So the lock
    /// path before the first write and after it were two different files.
    @Test("the trust lock does not move when a dangling symlink's target appears")
    func trustLockIsStableAcrossADanglingSymlink() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dotfiles = root + "/dotfiles"
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let store = TrustStore(configDirectory: FilePath(config))
        let target = dotfiles + "/trust.json"
        // Dangling: the dotfiles repository has no trust.json yet.
        try FileManager.default.createSymbolicLink(
            atPath: store.path.string, withDestinationPath: target)

        // What a second process computed before any decision had been written.
        let before = store.lockPath
        try store.setDecision(true, for: FilePath(root + "/first"))
        #expect(FileManager.default.fileExists(atPath: target), "the first write did not create it")
        #expect(store.lockPath == before, "the lock moved under the holder")

        // So a writer entering now contends with the lock the first one holds.
        let held = try await FileLock.withLock(at: before) { () -> Bool in
            #expect(throws: DoMoError.self) {
                try store.setDecision(true, for: FilePath(root + "/second"))
            }
            return true
        }
        #expect(held == .ran(true), "the test could not take the lock it needs to hold")
        #expect(
            try store.decision(for: FilePath(root + "/second")) == nil,
            "the write went through under another holder's lock"
        )
        #expect(try store.decision(for: FilePath(root + "/first")) == true)
    }

    /// A trust.json symlinked into a dotfiles directory that does not exist yet: the
    /// lock is a sibling of the *target*, so nothing has created the directory it
    /// belongs in. Locking has to create it, exactly as `FileLock.withLock` does,
    /// or a first run fails a write that has nothing wrong with it.
    @Test("a symlinked store whose target directory is missing still records a decision")
    func createsTheLockDirectoryForASymlinkedStore() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let store = TrustStore(configDirectory: FilePath(config))
        // Neither the target nor its directory exists.
        try FileManager.default.createSymbolicLink(
            atPath: store.path.string, withDestinationPath: root + "/dotfiles/trust.json")

        try store.setDecision(true, for: FilePath(root + "/project"))

        #expect(try store.decision(for: FilePath(root + "/project")) == true)
        #expect(FileManager.default.fileExists(atPath: root + "/dotfiles/trust.json"))
    }

    @Test("an existing trust.json keeps its mode", arguments: [0o600, 0o640])
    func preservesAnExistingMode(_ mode: Int) throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = TrustStore(configDirectory: FilePath(root + "/config"))
        try store.setDecision(true, for: FilePath(root + "/first"))
        try setMode(mode, of: store.path.string)

        try store.setDecision(true, for: FilePath(root + "/second"))

        #expect(try posixMode(of: store.path.string) == mode)
        #expect(try store.decision(for: FilePath(root + "/first")) == true, "the earlier decision was dropped")
        #expect(try store.decision(for: FilePath(root + "/second")) == true)
    }

    @Test("a trust.json created by a decision is owner-only")
    func createsANewFileOwnerOnly() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = TrustStore(configDirectory: FilePath(root + "/config"))
        try store.setDecision(true, for: FilePath(root + "/project"))
        #expect(try posixMode(of: store.path.string) == 0o600)
    }

    @Test("a trust.json that is a symlink is written THROUGH, not replaced")
    func writesThroughASymlink() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = root + "/dotfiles"
        let config = root + "/config"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let target = real + "/trust.json"
        try "{}".write(toFile: target, atomically: true, encoding: .utf8)
        let link = config + "/trust.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let store = TrustStore(configDirectory: FilePath(config))
        try store.setDecision(true, for: FilePath(root + "/project"))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
        let written = try String(contentsOf: URL(fileURLWithPath: target), encoding: .utf8)
        #expect(written.contains("project"), "the decision did not reach the symlink's target: \(written)")
    }
}
