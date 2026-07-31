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
    /// Derived from the **symlink-resolved** settings path, not the path as written,
    /// so two processes that reach the same file by different names — a dotfiles
    /// symlink, `/tmp` versus `/private/tmp`, `$HOME` versus its real location —
    /// still contend for one lock instead of each taking their own and both winning.
    ///
    /// The lock is a sidecar (`.settings.json.lock`), never settings.json itself:
    /// locking the document means opening it `O_CREAT`, and a 0-byte settings.json
    /// left behind by an aborted merge is a hard failure on every later launch.
    static func settingsLockPath(_ settingsPath: String) -> String {
        FileLock.sidecarPath(for: URL(fileURLWithPath: settingsPath).resolvingSymlinksInPath().path)
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
    static func resolvedRuleset(workingDirectory: String, configDirectory: String, homeDirectory: String) -> Ruleset {
        let baseline = fromConfig(defaultBaselinePermissionConfig(), homeDirectory: homeDirectory)
        let user = fromConfig(loadConfig(userSettingsPath(configDirectory)), homeDirectory: homeDirectory)
        let project = fromConfig(loadConfig(projectSettingsPath(workingDirectory)), homeDirectory: homeDirectory)
        return merge(baseline, user, project)
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

    /// Why a persist attempt did not save. Returned rather than thrown so the body of
    /// the ``FileLock/withLock(at:timeout:_:)`` call stays non-throwing and the lock's
    /// own `nil` (contention) is not confused with a failure inside it.
    private enum PersistOutcome: Sendable {
        case saved
        case failed(String)
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
    /// reports "busy", which would be a lie. It is belt and braces rather than a fix
    /// on its own, because ``FileLock/withLock(at:timeout:_:)`` also creates its own
    /// parent; stated here so the ordering is a decision and not an accident.
    static func persistGrants(_ grants: Ruleset, settingsPath path: String, configDirectory: String) async {
        try? FileManager.default.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)

        let outcome = await FileLock.withLock(at: settingsLockPath(path)) { () -> PersistOutcome in
            let existing: String
            if FileManager.default.fileExists(atPath: path) {
                // Present but unreadable: report it rather than clobbering the user's
                // settings with "{}" plus one grant.
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
                // Foundation does happen to carry an *existing* file's mode across on
                // Darwin (`replaceItemAt` copies metadata), so the mode-preservation
                // tests would pass either way here. That is an implementation detail
                // of one platform's replace, not a promise — which is exactly why the
                // guarantee lives in `AtomicFileWrite` instead of being inherited.
                try AtomicFileWrite.replace(at: path, with: updated)
            } catch {
                // Interpolated rather than `.message`: this `do` block sits inside a
                // closure whose context type is `throws`, so the catch binds
                // `any Error` and `DoMoError`'s one-line `description` is the right
                // rendering anyway.
                return .failed("\(error)")
            }
            return .saved
        }

        switch outcome {
        case .some(.saved):
            return
        case .some(.failed(let reason)):
            warn(
                "could not save the permission grant to \(path): \(reason)\n"
                    + "The grant applies for the rest of this session only."
            )
        case .none:
            warn(
                "could not save the permission grant: another process is writing \(path).\n"
                    + "The grant applies for the rest of this session only."
            )
        }
    }

    /// The pieces a surface needs to build its own gated engine: the resolved
    /// ruleset, the tool-aware factory, and the config persister.
    static func runtime(
        workingDirectory: String,
        configDirectory: String,
        homeDirectory: String
    ) -> (ruleset: Ruleset, factory: PermissionRequestFactory, persist: @Sendable (Ruleset) async -> Void) {
        (
            resolvedRuleset(workingDirectory: workingDirectory, configDirectory: configDirectory, homeDirectory: homeDirectory),
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
        yolo: Bool
    ) -> BeforeToolCallHook {
        let engine = PermissionEngine(
            ruleset: resolvedRuleset(
                workingDirectory: workingDirectory,
                configDirectory: configDirectory,
                homeDirectory: homeDirectory
            ),
            prompt: headlessPrompter(yolo: yolo)
        )
        return permissionHook(
            engine: engine,
            factory: factory(workingDirectory: workingDirectory, configDirectory: configDirectory),
            sessionID: "print"
        )
    }
}
