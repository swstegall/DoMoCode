// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// PKCE (RFC 7636) material for the MCP OAuth authorization-code flow.
//
// The verifier is 64 random bytes base64url-encoded — 86 characters, inside
// RFC 7636's 43–128 limit — and the challenge is always S256. The `plain`
// method exists in the RFC for clients that cannot hash; this one can, and
// offering the downgrade would only be a bug waiting for a config to trip it.

import Crypto
import Foundation

/// A verifier/challenge pair, generated fresh per authorization attempt.
public struct PKCE: Sendable {
    /// The `code_verifier` sent to the token endpoint. A secret for the
    /// duration of the flow; never logged, never persisted.
    public let verifier: String

    /// The `code_challenge` sent to the authorization endpoint:
    /// `base64url(SHA256(ascii(verifier)))`.
    public let challenge: String

    /// The only `code_challenge_method` this client offers.
    public static let challengeMethod = "S256"

    public init() {
        self.init(verifierBytes: PKCE.randomBytes(count: 64))
    }

    /// Deterministic entry point so tests can pin the RFC 7636 appendix vector.
    package init(verifierBytes: [UInt8]) {
        let verifier = PKCE.base64URL(verifierBytes)
        self.init(verifier: verifier)
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.base64URL(Array(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random `state` value: 16 bytes base64url, matching the reference flow.
    /// Verified byte-for-byte on the redirect; a mismatch is treated as CSRF.
    public static func randomState() -> String {
        base64URL(randomBytes(count: 16))
    }

    /// Base64url without padding (RFC 4648 §5), the alphabet OAuth expects for
    /// verifier, challenge, and state alike.
    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `SystemRandomNumberGenerator` is documented cryptographically secure on
    /// every supported platform (arc4random / getrandom), so no extra
    /// entropy source is needed.
    static func randomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
