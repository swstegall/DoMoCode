// Copyright (c) 2025 opencode contributors. MIT license.
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The request/decision vocabulary the engine speaks to a surface. A `spec` is what
// the tool-aware factory produces from a tool call; the engine turns an unresolved
// `spec` into a `PermissionRequest` (with an id) it hands to the surface's prompter,
// and returns a `PermissionDecision` to the loop.

import DoMoCore

/// What a tool call resolves to before evaluation — produced by
/// ``PermissionRequestFactory``. `patterns` are the concrete resources this call
/// touches (each checked against the ruleset); `always` are the broader globs to
/// persist if the user picks "allow always"; `configProtected` forces a prompt even
/// under a broad allow and suppresses "always" (the self-edit guard).
public struct PermissionRequestSpec: Sendable, Hashable {
    public var permission: String
    public var patterns: [String]
    public var always: [String]
    public var metadata: [String: JSONValue]
    public var configProtected: Bool

    public init(
        permission: String,
        patterns: [String],
        always: [String],
        metadata: [String: JSONValue] = [:],
        configProtected: Bool = false
    ) {
        self.permission = permission
        self.patterns = patterns
        self.always = always
        self.metadata = metadata
        self.configProtected = configProtected
    }
}

/// A prompt a surface must answer — the `spec` plus the engine-assigned `id` and
/// `sessionID` used to correlate the reply (load-bearing for the server round-trip).
/// `disableAlways` tells the UI to hide the "allow always" option (config-protected).
public struct PermissionRequest: Sendable, Hashable {
    public var id: String
    public var sessionID: String
    public var permission: String
    public var patterns: [String]
    public var always: [String]
    public var metadata: [String: JSONValue]
    public var disableAlways: Bool

    public init(
        id: String,
        sessionID: String,
        permission: String,
        patterns: [String],
        always: [String],
        metadata: [String: JSONValue],
        disableAlways: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.permission = permission
        self.patterns = patterns
        self.always = always
        self.metadata = metadata
        self.disableAlways = disableAlways
    }
}

/// A surface's answer to a ``PermissionRequest``. Ports opencode's `Reply` (once /
/// always / reject), carrying an optional correction message on reject.
public enum PermissionReply: Sendable, Hashable {
    /// Allow this one call.
    case once
    /// Allow and persist a grant for the `always` globs.
    case always
    /// Deny; `message`, if present, is fed back to the model as the reason.
    case reject(message: String?)
}

/// The engine's verdict to the loop.
public enum PermissionDecision: Sendable, Hashable {
    case allow
    case deny(reason: String)
}

/// How a surface prompts the user and awaits a reply. Injected per surface: print
/// returns a policy answer without blocking; the REPL suspends on a modal overlay;
/// the server round-trips over SSE/REST.
public typealias PermissionPrompter = @Sendable (PermissionRequest) async -> PermissionReply
