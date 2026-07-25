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

    /// The `permission` config in a settings.json, order preserved. Empty when the
    /// file is absent, unreadable, or has no `permission` key.
    private static func loadConfig(_ path: String) -> PermissionConfig {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return [] }
        return permissionConfig(fromSettingsText: text)
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

    /// A persister that writes "allow always" grants into the GLOBAL user
    /// settings.json (so a grant survives restarts and applies across projects,
    /// matching kilocode). Best-effort: a failed write must never crash the session,
    /// and the in-memory grant still holds for the rest of it.
    static func persister(configDirectory: String) -> @Sendable (Ruleset) async -> Void {
        let path = userSettingsPath(configDirectory)
        return { grants in
            guard !grants.isEmpty else { return }
            let existing = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? "{}"
            let updated = settingsText(existing, mergingGrants: grants)
            try? FileManager.default.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
            try? updated.write(toFile: path, atomically: true, encoding: .utf8)
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
