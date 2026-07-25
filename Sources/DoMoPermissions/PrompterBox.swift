// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A late-bound prompter. The interactive REPL builds its harness (and thus the
// permission hook) before the coordinator that owns the approval overlay exists, so
// the engine is built with a box the coordinator fills in once it is up. Until set,
// the box refuses (a request that arrives before the UI is ready is denied, never
// hung). Thread-safe: the engine reads it from its actor, the coordinator sets it
// from the main actor.

import Synchronization

/// Holds the surface's ``PermissionPrompter``, settable after the engine is built.
public final class PrompterBox: Sendable {
    private let stored = Mutex<PermissionPrompter?>(nil)

    public init() {}

    /// Install the prompter (called once, when the surface's UI is ready).
    public func set(_ prompter: @escaping PermissionPrompter) {
        stored.withLock { $0 = prompter }
    }

    /// The engine's prompter: forwards to the installed one, or refuses if none is set.
    public func prompt(_ request: PermissionRequest) async -> PermissionReply {
        guard let prompter = stored.withLock({ $0 }) else {
            return .reject(message: "No approval interface is available.")
        }
        return await prompter(request)
    }
}
