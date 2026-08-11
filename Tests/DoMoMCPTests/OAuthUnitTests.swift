// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The socket-free OAuth units: PKCE against the RFC's own vector, the
// WWW-Authenticate parameter scan, the metadata-candidate ladder (whose
// *order* is the ADFS-compatibility guarantee), the redirect-URI gate that
// keeps the login listener off routable interfaces, and form encoding.
//
// No @testable: this target runs in release, so everything exercised here is
// deliberately package-visible or public.

import DoMoMCP
import Foundation
import Testing

@Suite("OAuth PKCE material")
struct OAuthPKCETests {

    /// RFC 7636 appendix B: the one verifier/challenge pair with a published
    /// right answer. If base64url or the hash input convention drifts, this is
    /// the test that says so.
    @Test("The RFC 7636 appendix vector produces the published challenge")
    func rfcVector() {
        let octets: [UInt8] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
            22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121,
        ]
        let pkce = PKCE(verifierBytes: octets)
        #expect(pkce.verifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("A fresh verifier is 86 base64url characters and never repeats")
    func freshVerifier() {
        let a = PKCE()
        let b = PKCE()
        // 64 bytes → ceil(64 * 4 / 3) unpadded = 86 characters, inside the
        // RFC's 43–128 window.
        #expect(a.verifier.count == 86)
        #expect(a.verifier != b.verifier, "two flows must never share a verifier")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!a.challenge.contains("="), "the challenge must be unpadded base64url")
    }

    @Test("State values are distinct per flow")
    func stateUniqueness() {
        #expect(PKCE.randomState() != PKCE.randomState())
    }
}

@Suite("OAuth WWW-Authenticate parsing")
struct OAuthChallengeParsingTests {

    @Test(
        "resource_metadata is found regardless of quoting and neighbors",
        arguments: [
            #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#,
            #"Bearer realm="mcp", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", error="invalid_token""#,
            #"Bearer resource_metadata=https://mcp.example.com/.well-known/oauth-protected-resource"#,
            #"Bearer RESOURCE_METADATA="https://mcp.example.com/.well-known/oauth-protected-resource""#,
        ]
    )
    func findsParameter(header: String) {
        let url = OAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: header)
        #expect(
            url?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource"
        )
    }

    @Test("A challenge without the parameter yields nil")
    func absentParameter() {
        #expect(OAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: #"Bearer realm="mcp""#) == nil)
        #expect(OAuthDiscovery.resourceMetadataURL(fromWWWAuthenticate: "") == nil)
    }
}

@Suite("OAuth metadata-candidate ladder")
struct OAuthMetadataCandidateTests {

    /// The order IS the contract: RFC 8414 spellings first, then the OIDC
    /// spellings, ending on path-appended openid-configuration — the only
    /// document ADFS serves.
    @Test("A pathful issuer produces all four spellings in order")
    func pathfulIssuer() throws {
        let issuer = try #require(URL(string: "https://login.example.corp/adfs"))
        let candidates = OAuthDiscovery.metadataCandidates(for: issuer).map(\.absoluteString)
        #expect(candidates == [
            "https://login.example.corp/.well-known/oauth-authorization-server/adfs",
            "https://login.example.corp/.well-known/oauth-authorization-server",
            "https://login.example.corp/.well-known/openid-configuration/adfs",
            "https://login.example.corp/adfs/.well-known/openid-configuration",
        ])
    }

    @Test("A rootless issuer deduplicates the inserted and root spellings")
    func rootIssuer() throws {
        let issuer = try #require(URL(string: "https://auth.example.com"))
        let candidates = OAuthDiscovery.metadataCandidates(for: issuer).map(\.absoluteString)
        #expect(
            candidates == [
                "https://auth.example.com/.well-known/oauth-authorization-server",
                "https://auth.example.com/.well-known/openid-configuration",
                "https://auth.example.com/.well-known/openid-configuration/",
            ] || candidates == [
                "https://auth.example.com/.well-known/oauth-authorization-server",
                "https://auth.example.com/.well-known/openid-configuration",
            ],
            "path-inserted and root spellings must collapse rather than refetch; got \(candidates)"
        )
    }
}

@Suite("OAuth redirect endpoint gate")
struct OAuthRedirectEndpointTests {

    @Test("Loopback URIs parse with their scheme, port, and path intact")
    func parsesLoopback() throws {
        let https = try OAuthRedirectEndpoint(redirectURI: "https://localhost:8080/redirect")
        #expect(https.useTLS)
        #expect(https.port == 8080)
        #expect(https.path == "/redirect")
        #expect(https.uri == "https://localhost:8080/redirect")

        let http = try OAuthRedirectEndpoint(redirectURI: "http://127.0.0.1:27182/oauth/callback")
        #expect(!http.useTLS)
        #expect(http.port == 27182)
        #expect(http.path == "/oauth/callback")
    }

    @Test(
        "Non-loopback and non-http(s) redirect URIs are refused",
        arguments: [
            "https://example.com/redirect",
            "https://mcp.internal.corp:8080/redirect",
            "ftp://localhost/redirect",
            "not a url",
        ]
    )
    func refusesUnsafe(uri: String) {
        #expect(throws: MCPOAuthError.self) {
            _ = try OAuthRedirectEndpoint(redirectURI: uri)
        }
    }
}

@Suite("OAuth form encoding")
struct OAuthFormEncodingTests {

    @Test("Reserved characters and spaces are escaped the RFC 3986 way")
    func escaping() {
        let encoded = OAuthHTTPTransport.encodeForm([
            ("scope", "openid profile"),
            ("resource", "https://mcp.example.com/mcp"),
            ("odd", "a+b&c=d"),
        ])
        #expect(
            encoded == "scope=openid%20profile"
                + "&resource=https%3A%2F%2Fmcp.example.com%2Fmcp"
                + "&odd=a%2Bb%26c%3Dd"
        )
    }
}
