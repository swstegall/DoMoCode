// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Endpoint discovery for the MCP authorization handshake (2025-06-18 spec):
// the 401's WWW-Authenticate names a protected-resource-metadata document
// (RFC 9728), that document names authorization servers, and each server's
// metadata (RFC 8414) names the endpoints. Every hop has a real-world
// fallback, because the ecosystem is older than the spec:
//
// - No WWW-Authenticate pointer → the RFC 9728 default location, formed by
//   path-inserting `/.well-known/oauth-protected-resource` on the server URL.
// - No RFC 8414 document → the OIDC `openid-configuration` spellings, both
//   path-inserted and path-appended. ADFS publishes ONLY the path-appended
//   OIDC form (`/adfs/.well-known/openid-configuration`); the MCP TypeScript
//   SDK grew the same fallback for the same reason.
// - No protected-resource metadata at all → treat the MCP server's own origin
//   as the issuer, the pre-2025 behavior deployed servers still rely on.

import Foundation

/// RFC 8414 / OIDC authorization-server metadata, the fields this client uses.
struct OAuthServerMetadata: Sendable, Codable {
    var issuer: String?
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
    var codeChallengeMethodsSupported: [String]?
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case scopesSupported = "scopes_supported"
    }
}

/// RFC 9728 protected-resource metadata, the fields this client uses.
struct OAuthProtectedResourceMetadata: Sendable, Codable {
    var resource: String?
    var authorizationServers: [String]?
    var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

package enum OAuthDiscovery {

    /// What discovery learned: the endpoints, plus scope guidance when the
    /// resource metadata offered any and the config did not.
    struct Outcome: Sendable {
        var metadata: OAuthServerMetadata
        var scopeHint: String?
    }

    static func discover(
        serverURL: URL,
        wwwAuthenticate: String?,
        transport: OAuthHTTPTransport
    ) async throws -> Outcome {
        // The challenge's own scope attribute (RFC 6750 §3) is the server's
        // most specific statement of what it needs; it outranks the metadata's
        // scopes_supported list below.
        var scopeHint: String? = wwwAuthenticate.flatMap { scope(fromWWWAuthenticate: $0) }
        var issuers: [String] = []

        var resourceMetadataURLs: [URL] = []
        if let header = wwwAuthenticate, let fromHeader = resourceMetadataURL(fromWWWAuthenticate: header) {
            resourceMetadataURLs.append(fromHeader)
        }
        if let defaulted = wellKnown(on: serverURL, suffix: "oauth-protected-resource", pathInserted: true) {
            resourceMetadataURLs.append(defaulted)
        }

        for url in resourceMetadataURLs {
            guard
                let (status, body) = try? await transport.getJSON(url),
                status == 200,
                let metadata = try? JSONDecoder().decode(OAuthProtectedResourceMetadata.self, from: body),
                let servers = metadata.authorizationServers, !servers.isEmpty
            else {
                // Every PRM field is optional, so an error payload or a
                // captive-portal page served with 200 decodes "successfully";
                // requiring a non-empty authorization_servers list keeps the
                // fallback chain alive rather than accepting garbage and
                // abandoning the default well-known location.
                continue
            }
            issuers = servers
            // Only when the challenge did not already name a scope: the
            // per-request scope from the 401 is more specific than the
            // resource's full advertised set.
            if scopeHint == nil, let scopes = metadata.scopesSupported, !scopes.isEmpty {
                scopeHint = scopes.joined(separator: " ")
            }
            break
        }

        // Legacy fallback: no resource metadata anywhere → the server's own
        // origin doubles as the issuer.
        if issuers.isEmpty {
            var origin = URLComponents()
            origin.scheme = serverURL.scheme
            origin.host = serverURL.host
            origin.port = serverURL.port
            if let originURL = origin.url { issuers = [originURL.absoluteString] }
        }

        for issuer in issuers {
            guard let issuerURL = URL(string: issuer) else { continue }
            for candidate in metadataCandidates(for: issuerURL) {
                guard
                    let (status, body) = try? await transport.getJSON(candidate),
                    status == 200,
                    let metadata = try? JSONDecoder().decode(OAuthServerMetadata.self, from: body)
                else { continue }
                return Outcome(metadata: metadata, scopeHint: scopeHint)
            }
        }

        throw MCPOAuthError.discoveryFailed(
            "no authorization-server metadata found for this server; "
                + "set oauth.authorizationEndpoint and oauth.tokenEndpoint explicitly"
        )
    }

    /// The `resource_metadata="…"` parameter of a Bearer challenge, when the
    /// header carries one.
    package static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
        parameter("resource_metadata", in: header).flatMap { URL(string: $0) }
    }

    /// The `scope="…"` parameter of a Bearer challenge (RFC 6750 §3): the
    /// server telling the client exactly which scope the request needed. The
    /// highest-priority scope hint when present.
    package static func scope(fromWWWAuthenticate header: String) -> String? {
        parameter("scope", in: header)
    }

    /// A small auth-param scanner rather than a full RFC 7235 parser: find the
    /// key case-insensitively at a parameter boundary, take its (possibly
    /// quoted) value. It works over `[Unicode.Scalar]` so no `String.Index` is
    /// ever taken from one string and used on another (the round-one bug), and
    /// it enforces two boundaries a naive scan misses: the key must START at
    /// the beginning or just after a delimiter (so `myscope` does not match
    /// `scope`), and quoted spans are skipped whole (so a `scope=` sequence
    /// inside another parameter's quoted value is not mistaken for the key).
    package static func parameter(_ name: String, in header: String) -> String? {
        let scalars = Array(header.unicodeScalars)
        let target = Array(name.lowercased().unicodeScalars)
        guard !target.isEmpty else { return nil }
        let delimiters: Set<Unicode.Scalar> = [" ", "\t", ","]

        // Optional whitespace around '=' is BWS = *( SP / HTAB ) per RFC 7235.
        let blankSpace: Set<Unicode.Scalar> = [" ", "\t"]

        var i = 0
        while i < scalars.count {
            // Skip a quoted span entirely — nothing inside it is a key. A
            // backslash escapes the next scalar (RFC 7235 quoted-pair), so an
            // escaped quote does not end the span and desync the scan.
            if scalars[i] == "\"" {
                i += 1
                while i < scalars.count, scalars[i] != "\"" {
                    i += (scalars[i] == "\\" && i + 1 < scalars.count) ? 2 : 1
                }
                i += 1
                continue
            }
            let atBoundary = i == 0 || delimiters.contains(scalars[i - 1])
            if atBoundary, matchesKey(target, in: scalars, at: i) {
                var j = i + target.count
                while j < scalars.count, blankSpace.contains(scalars[j]) { j += 1 }
                if j < scalars.count, scalars[j] == "=" {
                    j += 1
                    while j < scalars.count, blankSpace.contains(scalars[j]) { j += 1 }
                    var value = String.UnicodeScalarView()
                    if j < scalars.count, scalars[j] == "\"" {
                        j += 1
                        while j < scalars.count, scalars[j] != "\"" {
                            // Unescape a quoted-pair: emit the escaped scalar,
                            // not the backslash.
                            if scalars[j] == "\\", j + 1 < scalars.count {
                                value.append(scalars[j + 1])
                                j += 2
                            } else {
                                value.append(scalars[j])
                                j += 1
                            }
                        }
                    } else {
                        while j < scalars.count, !delimiters.contains(scalars[j]) { value.append(scalars[j]); j += 1 }
                    }
                    let result = String(value)
                    return result.isEmpty ? nil : result
                }
            }
            i += 1
        }
        return nil
    }

    /// ASCII-case-insensitive prefix match of `target` (already lowercased)
    /// against `scalars` starting at `i`.
    private static func matchesKey(_ target: [Unicode.Scalar], in scalars: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + target.count <= scalars.count else { return false }
        for k in 0..<target.count {
            let scalar = scalars[i + k]
            let lowered: Unicode.Scalar
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                lowered = Unicode.Scalar(scalar.value + 0x20)!
            } else {
                lowered = scalar
            }
            if lowered != target[k] { return false }
        }
        return true
    }

    /// The RFC 8414 candidate list for one issuer, in the order the MCP
    /// TypeScript SDK settled on: OAuth metadata (path-inserted, then root),
    /// then the OIDC spellings (path-inserted, then path-appended — the only
    /// one ADFS serves).
    package static func metadataCandidates(for issuer: URL) -> [URL] {
        var candidates: [URL] = []
        func append(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }
        append(wellKnown(on: issuer, suffix: "oauth-authorization-server", pathInserted: true))
        append(wellKnown(on: issuer, suffix: "oauth-authorization-server", pathInserted: false))
        append(wellKnown(on: issuer, suffix: "openid-configuration", pathInserted: true))
        append(issuer.appendingPathComponent(".well-known/openid-configuration"))
        return candidates
    }

    /// `https://host/.well-known/<suffix><path>` (path-inserted, RFC 8414) or
    /// `https://host/.well-known/<suffix>` (root).
    private static func wellKnown(on url: URL, suffix: String, pathInserted: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        let path = url.path == "/" ? "" : url.path
        components.path = "/.well-known/\(suffix)" + (pathInserted ? path : "")
        return components.url
    }
}
