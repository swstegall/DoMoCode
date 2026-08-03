// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Assembles the permission engine for a run: loads the `permission` block from the
// user and project settings.json files (order-preserving — precedence is
// last-match-wins), layers them over the built-in baseline, and builds the tool-aware
// factory (including the config files the self-edit guard protects). Each surface
// supplies its own prompter; this only builds the shared ruleset + factory.

import DoMoAgent
import DoMoCore
import DoMoPermissions
import Foundation
import Synchronization

enum PermissionSetup {
    static func projectSettingsPath(_ workingDirectory: String) -> String {
        workingDirectory + "/.domocode/settings.json"
    }
    static func userSettingsPath(_ configDirectory: String) -> String {
        configDirectory + "/settings.json"
    }
    static func trustPath(_ configDirectory: String) -> String {
        configDirectory + "/trust.json"
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The lock file guarding a read-modify-write of `settingsPath`.
    ///
    /// Derived with ``FileLock/lockPath(forDocumentAt:)``, which follows a symlinked
    /// leaf exactly the way ``AtomicFileWrite`` follows it, so a dotfiles-symlinked
    /// settings.json is locked where it is written. Two processes reaching the same
    /// file by different *parent* spellings (`/tmp` versus `/private/tmp`, `$HOME`
    /// versus its real location) already exclude each other without any help here:
    /// `flock(2)` locks an inode, and both spellings name the same one.
    ///
    /// It used to be `URL.resolvingSymlinksInPath()`, which is not the same function.
    /// That one resolves a symlink only once the target exists, so for a settings.json
    /// symlinked at a file no grant had created yet the lock lived on
    /// `.settings.json.lock` before the first save and on `.real.json.lock` after it —
    /// and the second writer to arrive took a lock file the first writer was not
    /// holding.
    ///
    /// The lock is a sidecar (`.settings.json.lock`), never settings.json itself:
    /// locking the document means opening it `O_CREAT`, and a 0-byte settings.json
    /// left behind by an aborted merge is a hard failure on every later launch.
    static func settingsLockPath(_ settingsPath: String) -> String {
        FileLock.lockPath(forDocumentAt: settingsPath)
    }

    /// The `permission` config in a settings.json, order preserved, together with the
    /// diagnostic that explains an empty result when the file itself is the reason.
    ///
    /// A `nil` diagnostic covers both "loaded cleanly" and "there is no such file":
    /// an absent settings.json is the overwhelmingly common case and is not news. A
    /// file that exists but will not parse is news, because Foundation reads `model`
    /// and `baseUrl` out of those same bytes quite happily — so without this the user
    /// sees a completely normal session in which none of their permission rules are
    /// in effect and no grant they make is ever saved.
    static func configAndDiagnostic(_ path: String) -> (config: PermissionConfig, diagnostic: ConfigDiagnostic?) {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return ([], nil)
        }
        do {
            return (try permissionConfig(parsingSettingsText: text, file: path), nil)
        } catch {
            return ([], error)
        }
    }

    /// The `permission` config in a settings.json, reporting a parse failure on
    /// stderr rather than swallowing it.
    ///
    /// Reported, not thrown: a broken permission block must not stop the CLI from
    /// starting. The run continues under the built-in baseline, which is the
    /// restrictive direction.
    private static func loadConfig(_ path: String) -> PermissionConfig {
        let (config, diagnostic) = configAndDiagnostic(path)
        if let diagnostic { reportOnce(diagnostic, path: path) }
        return config
    }

    /// Settings files already complained about.
    ///
    /// A single `-p` run resolves the ruleset twice (once inside ``headlessHook``,
    /// once to decide MCP tool visibility), which is four `loadConfig` calls over two
    /// files. Without this, one stray comma prints the same multi-line diagnostic
    /// four times before the model has said anything.
    private static let reportedPaths = Mutex<Set<String>>([])

    private static func reportOnce(_ diagnostic: ConfigDiagnostic, path: String) {
        guard reportedPaths.withLock({ $0.insert(path).inserted }) else { return }
        warn(
            "ignoring the permission block in \(path) — the file will not parse, so none of "
                + "its rules are in effect:\n\(diagnostic)"
        )
    }

    /// A warning on stderr.
    ///
    /// stderr and never stdout: `-p --output-format json` writes one JSON document to
    /// stdout, and a warning mixed into it breaks every consumer that pipes it.
    private static func warn(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data("domocode: \(text)\n".utf8))
    }

    /// The resolved ruleset: baseline first, then the user's global permission,
    /// then the project's (which wins — matching how every other setting layers
    /// project over user, gated by project trust). The engine appends session grants.
    static func resolvedRuleset(
        workingDirectory: String,
        configDirectory: String,
        homeDirectory: String,
        mode: AgentMode = .build,
        planPath: String? = nil,
        profileRules: Ruleset = [],
        modeRules: Ruleset = []
    ) -> Ruleset {
        let baseline = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: homeDirectory)
        let user = fromConfig(loadConfig(userSettingsPath(configDirectory)), homeDirectory: homeDirectory)
        let project = fromConfig(loadConfig(projectSettingsPath(workingDirectory)), homeDirectory: homeDirectory)
        let layered = merge(baseline, user, project, profileRules)
        let resolvedPlanPath = planPath ?? AgentModePolicy.planPath(
            workingDirectory: workingDirectory,
            sessionID: "current"
        )
        return merge(
            layered,
            AgentModePolicy.rules(for: mode, planPath: resolvedPlanPath, additional: modeRules)
        )
    }

    /// The MCP tools the model should actually SEE, given the resolved ruleset: a tool
    /// whose permission resolves to a broad `deny` is hidden from both the advertised tool
    /// set and the system-prompt tool list (Phase 8d visibility), not merely blocked at
    /// call time. Only MCP tool names are candidates — built-ins are never hidden by this
    /// path (a broad `*: deny` still gates them at the call, but they stay visible).
    static func visibleMCPTools(_ mcpTools: [any AgentTool], ruleset: Ruleset) -> [any AgentTool] {
        guard !mcpTools.isEmpty else { return mcpTools }
        let hidden = disabledTools(mcpTools.map(\.definition.name), ruleset)
        guard !hidden.isEmpty else { return mcpTools }
        return mcpTools.filter { !hidden.contains($0.definition.name) }
    }

    /// The config files a `write`/`edit` must never silently overwrite (the model
    /// widening its own permissions). Absolute, standardized for the factory's check.
    static func protectedPaths(workingDirectory: String, configDirectory: String) -> Set<String> {
        Set(
            [
                projectSettingsPath(workingDirectory),
                userSettingsPath(configDirectory),
                trustPath(configDirectory),
            ].map(standardized)
        )
    }

    static func factory(workingDirectory: String, configDirectory: String) -> PermissionRequestFactory {
        PermissionRequestFactory(
            workingDirectory: workingDirectory,
            protectedPaths: protectedPaths(workingDirectory: workingDirectory, configDirectory: configDirectory)
        )
    }

    /// What happened inside the lock. Returned rather than thrown so the body of the
    /// ``FileLock/withLock(at:timeout:_:)`` call stays non-throwing and a failure
    /// inside the critical section is not confused with the lock's own outcomes.
    private enum WriteOutcome: Sendable {
        case saved
        case failed(String)
    }

    /// What a whole persist attempt did, including why it did not save.
    ///
    /// Returned as well as warned about because the four not-saved cases get four
    /// different sentences and a test has no other way to tell them apart — stderr is
    /// not capturable in-process. They were once a single `nil`, so a lock file the
    /// process could not open (0400, ENOTDIR, a read-only mount, a directory in the
    /// lock's place) was reported as "another process is writing", which is a lie that
    /// sends the user hunting for a second `domo`.
    ///
    /// Production callers ignore it; the warning on stderr is the user-facing half.
    enum PersistResult: Sendable, Equatable {
        /// The grants are in the file.
        case saved
        /// The lock was held, but the read-merge-write inside it failed.
        case writeFailed(String)
        /// Another holder had the lock for the whole timeout.
        case contended
        /// The task was cancelled while waiting for the lock.
        case cancelled
        /// The lock file itself could not be opened; nothing was attempted.
        case lockUnopenable(String)
    }

    /// A persister that writes "allow always" grants into the GLOBAL user
    /// settings.json (so a grant survives restarts and applies across projects,
    /// matching kilocode).
    ///
    /// The session is never failed by a failed save — the in-memory grant still holds
    /// for the rest of it — but the user is *told*. Silence here was the whole bug: a
    /// settings.json with one trailing comma refused every grant forever, and the only
    /// symptom was being asked again for a permission that had just been granted
    /// "always".
    static func persister(configDirectory: String) -> @Sendable (Ruleset) async -> Void {
        let path = userSettingsPath(configDirectory)
        return { grants in
            guard !grants.isEmpty else { return }
            await persistGrants(grants, settingsPath: path, configDirectory: configDirectory)
        }
    }

    /// Merges `grants` into the settings.json at `path` under a cross-process lock,
    /// reporting on stderr when it could not be done.
    ///
    /// The whole read → merge → write is inside the lock. Unguarded, the window is a
    /// textbook lost update: A reads S0, B reads S0, A writes S0+gA, B writes S0+gB,
    /// and gA is gone. `rename(2)` makes each write atomic, so the file is never torn
    /// — the result is a perfectly valid settings.json that is simply missing a grant.
    /// The race is not only across processes: `ServerRuntime` builds one
    /// `PermissionEngine` per session over a single shared persist closure, so one
    /// `domo --serve` can lose a grant to itself. That is why the lock is `flock(2)`
    /// on a descriptor rather than a POSIX record lock, which a single process is
    /// granted twice.
    ///
    /// The directory is created **before** the lock rather than between the read and
    /// the write, where it used to sit: the lock file lives in that directory, and on
    /// a first run there is no config directory at all — a lock that cannot be created
    /// would fail the save on a machine where nothing is wrong. It is belt and braces
    /// rather than a fix on its own, because ``FileLock/withLock(at:timeout:_:)`` also
    /// creates its own parent; stated here so the ordering is a decision and not an
    /// accident.
    ///
    /// The four ways this can fail are four different sentences, and ``PersistResult``
    /// is what keeps them apart. "Another process is writing" is said only when that is
    /// actually what happened.
    @discardableResult
    static func persistGrants(
        _ grants: Ruleset,
        settingsPath path: String,
        configDirectory: String
    ) async -> PersistResult {
        try? FileManager.default.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)

        let lock = settingsLockPath(path)
        let outcome: FileLock.Outcome<WriteOutcome>
        do {
            outcome = try await FileLock.withLock(at: lock) { () -> WriteOutcome in
                let existing: String
                if FileManager.default.fileExists(atPath: path) {
                    // Present but unreadable: report it rather than clobbering the
                    // user's settings with "{}" plus one grant.
                    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
                        return .failed("it could not be read")
                    }
                    existing = text
                } else {
                    existing = "{}"
                }

                let updated: String
                do {
                    updated = try settingsText(parsing: existing, mergingGrants: grants, file: path)
                } catch {
                    return .failed("\(error)")
                }

                do {
                    // `AtomicFileWrite`, not `String.write(toFile:atomically:)`. Two
                    // behaviours were measured on Darwin 27 / Swift 6.3.3 under umask
                    // 022, not assumed:
                    //
                    //  - Foundation CREATES the file at 0644, so the first grant a user
                    //    ever makes leaves their settings.json world-readable — and this
                    //    is the file holding `apiKeyEnv` and every permission decision.
                    //  - Foundation REPLACES a symlink with a regular file, so a
                    //    settings.json symlinked out of a dotfiles repository is silently
                    //    detached from it by one saved grant.
                    //
                    // Foundation does happen to carry an *existing* file's mode across
                    // on Darwin (`replaceItemAt` copies metadata), so the
                    // mode-preservation tests would pass either way here. That is an
                    // implementation detail of one platform's replace, not a promise —
                    // which is exactly why the guarantee lives in `AtomicFileWrite`
                    // instead of being inherited.
                    try AtomicFileWrite.replace(at: path, with: updated)
                } catch {
                    // Interpolated rather than `.message`: `DoMoError`'s one-line
                    // `description` is the right rendering for a warning either way.
                    return .failed("\(error)")
                }
                return .saved
            }
        } catch {
            // Not contention: the lock file could not be opened at all. Saying
            // "another process is writing" here would send the user looking for a
            // second `domo` instead of at the 0400 lock file, the read-only mount, or
            // the directory sitting where the lock belongs — and the `errno` that names
            // which of those it is rides along in the error.
            warn(
                "could not save the permission grant to \(path): its lock file could not be opened — \(error)\n"
                    + "The grant applies for the rest of this session only."
            )
            return .lockUnopenable("\(error)")
        }

        switch outcome {
        case .ran(.saved):
            return .saved
        case .ran(.failed(let reason)):
            warn(
                "could not save the permission grant to \(path): \(reason)\n"
                    + "The grant applies for the rest of this session only."
            )
            return .writeFailed(reason)
        case .contended:
            warn(
                "could not save the permission grant: another process is writing \(path).\n"
                    + "The grant applies for the rest of this session only."
            )
            return .contended
        case .cancelled:
            // Rare by construction: an uncontended acquire succeeds even in a cancelled
            // task, so this needs a peer holding the lock *and* a shutdown at the same
            // moment. Still said out loud, because the grant is gone either way.
            warn(
                "could not save the permission grant to \(path): the save was cancelled "
                    + "while waiting for another process to finish writing.\n"
                    + "The grant applies for the rest of this session only."
            )
            return .cancelled
        }
    }

    /// The pieces a surface needs to build its own gated engine: the resolved
    /// ruleset, the tool-aware factory, and the config persister.
    static func runtime(
        workingDirectory: String,
        configDirectory: String,
        homeDirectory: String,
        mode: AgentMode = .build,
        planPath: String? = nil,
        profileRules: Ruleset = [],
        modeRules: Ruleset = []
    ) -> (ruleset: Ruleset, factory: PermissionRequestFactory, persist: @Sendable (Ruleset) async -> Void) {
        (
            resolvedRuleset(
                workingDirectory: workingDirectory,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory,
                mode: mode,
                planPath: planPath,
                profileRules: profileRules,
                modeRules: modeRules
            ),
            factory(workingDirectory: workingDirectory, configDirectory: configDirectory),
            persister(configDirectory: configDirectory)
        )
    }

    /// The headless prompter: never blocks. A tool that resolves to `ask` is rejected
    /// with a model-visible reason unless `--yolo` auto-approves it for this call.
    static func headlessPrompter(yolo: Bool) -> PermissionPrompter {
        { _ in
            yolo
                ? .once
                : .reject(
                    message:
                        "This tool call needs interactive approval. Re-run without -p to approve it, or pass --yolo to auto-approve tool calls in headless mode."
                )
        }
    }

    /// The complete before-tool-call gate for a headless (`-p`) run.
    static func headlessHook(
        workingDirectory: String,
        configDirectory: String,
        homeDirectory: String,
        yolo: Bool,
        mode: AgentMode = .build,
        planPath: String? = nil,
        profileRules: Ruleset = [],
        modeRules: Ruleset = []
    ) -> BeforeToolCallHook {
        let engine = PermissionEngine(
            ruleset: resolvedRuleset(
                workingDirectory: workingDirectory,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory,
                mode: mode,
                planPath: planPath,
                profileRules: profileRules,
                modeRules: modeRules
            ),
            prompt: headlessPrompter(yolo: yolo)
        )
        return permissionHook(
            engine: engine,
            factory: factory(workingDirectory: workingDirectory, configDirectory: configDirectory),
            sessionID: "print"
        )
    }

    /// The headless no-progress decision. It uses the same baseline and user
    /// rules as tool permissions, but never blocks: `--yolo` answers once and a
    /// normal print run rejects the escalation so a script cannot hang waiting
    /// for a prompt that has no terminal UI.
    static func headlessNoProgressHook(
        workingDirectory: String,
        configDirectory: String,
        homeDirectory: String,
        yolo: Bool,
        mode: AgentMode = .build,
        planPath: String? = nil,
        profileRules: Ruleset = [],
        modeRules: Ruleset = []
    ) -> @Sendable (TurnResult) async -> Bool {
        let engine = PermissionEngine(
            ruleset: resolvedRuleset(
                workingDirectory: workingDirectory,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory,
                mode: mode,
                planPath: planPath,
                profileRules: profileRules,
                modeRules: modeRules
            ),
            prompt: headlessPrompter(yolo: yolo)
        )
        return doomLoopHook(engine: engine, sessionID: "print")
    }
}
