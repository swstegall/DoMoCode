// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The OAuth failure taxonomy. Deliberately separate from `MCPError`: these
// arise before or between MCP requests, and each case is a *reason* the user
// can act on, not a protocol status. Messages never carry tokens, codes,
// verifiers, or URLs with credentials in them — they are written to be safe
// to print, and everything printed still passes through `Redaction`.

/// Why an OAuth flow could not produce a usable access token.
public enum MCPOAuthError: Error, Sendable {
    /// The `oauth` config block is contradictory or incomplete in a way
    /// discovery cannot repair.
    case configuration(String)

    /// Endpoint discovery failed: no protected-resource metadata, no
    /// authorization-server metadata, and no explicit endpoints configured.
    case discoveryFailed(String)

    /// The authorization server offers no dynamic registration and no
    /// `clientId` was configured — the user must register a client manually.
    case clientRegistrationRequired(String)

    /// The redirect port is already bound. Its own case because the remedy
    /// (close the other program, or change the registered redirect) is unlike
    /// any other failure here.
    case portInUse(Int)

    /// The user (or the IdP) declined: the callback carried an OAuth error.
    case authorizationDenied(error: String, description: String?)

    /// No callback arrived in time — an abandoned browser tab must not hang
    /// the agent forever.
    case timedOut(String)

    /// A valid token exists only through a browser round-trip, and this call
    /// site is not allowed to start one (mid-session, or non-interactive).
    case interactionRequired(String)

    /// The token endpoint refused the exchange or refresh.
    case tokenEndpoint(status: Int, error: String?, description: String?)

    /// Anything else that broke the flow, described safely.
    case flowFailed(String)
}

extension MCPOAuthError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .configuration(let detail):
            return "OAuth configuration error: \(detail)"
        case .discoveryFailed(let detail):
            return "OAuth discovery failed: \(detail)"
        case .clientRegistrationRequired(let detail):
            return "OAuth client registration required: \(detail)"
        case .portInUse(let port):
            return "OAuth login listener port \(port) is already in use; "
                + "close whatever is bound to it or configure a different registered redirect URI"
        case .authorizationDenied(let error, let description):
            let suffix = description.map { ": \($0)" } ?? ""
            return "authorization was denied (\(error)\(suffix))"
        case .timedOut(let detail):
            return "OAuth login timed out: \(detail)"
        case .interactionRequired(let detail):
            return "interactive login required: \(detail)"
        case .tokenEndpoint(let status, let error, let description):
            var parts = ["token endpoint returned HTTP \(status)"]
            if let error { parts.append(error) }
            if let description { parts.append(description) }
            return parts.joined(separator: ": ")
        case .flowFailed(let detail):
            return "OAuth flow failed: \(detail)"
        }
    }
}
