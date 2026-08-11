// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The self-signed certificate behind an `https://localhost` OAuth redirect.
//
// Plain-HTTP loopback is the ecosystem norm (RFC 8252, VS Code, every CLI
// surveyed), and DoMoCode uses it whenever the redirect URI says `http`. But
// some enterprise registrations pin an `https://localhost:<port>` redirect and
// validate it exactly, so the listener must be able to serve TLS on loopback.
// Nothing about that TLS is a trust statement — the browser will warn once and
// the user proceeds — it only satisfies the registered scheme.
//
// Generated in-process with swift-certificates rather than by shelling out to
// a host `openssl`: no host-tool dependency, no argv quoting, and the same
// code path on macOS and Linux. P-256/ECDSA because every modern browser
// accepts it and the key generates instantly.
//
// The pair is cached (0600) beside the token store and reused until its final
// day, so the browser's one-time "proceed anyway" decision keeps working
// across runs instead of reappearing per login.

import Crypto
import DoMoCore
import Foundation
import SwiftASN1
import X509

/// A PEM certificate/key pair for the loopback TLS listener.
public struct LoopbackTLSIdentity: Sendable, Hashable {
    public let certificatePEM: String
    public let privateKeyPEM: String

    public init(certificatePEM: String, privateKeyPEM: String) {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
    }
}

public enum SelfSignedCertificate {
    /// How long a freshly generated certificate lives. A year, matching the
    /// reference tooling; regeneration is silent, the only cost is one new
    /// browser warning.
    static let lifetime: TimeInterval = 365 * 24 * 3600

    /// Reuse threshold: a cached certificate that expires within a day is
    /// replaced now rather than mid-flow.
    static let reuseMargin: TimeInterval = 24 * 3600

    /// The cached identity in `directory`, generated (and cached) when
    /// missing, unreadable, or nearly expired. Valid for `localhost`,
    /// `127.0.0.1`, and `::1` — the only names a loopback redirect can use.
    public static func loopbackIdentity(
        in directory: String,
        now: Date = Date()
    ) throws -> LoopbackTLSIdentity {
        let certificatePath = directory + "/localhost.pem"
        let keyPath = directory + "/localhost.key"

        if let cached = try? cachedIdentity(
            certificatePath: certificatePath,
            keyPath: keyPath,
            now: now
        ) {
            return cached
        }

        let identity = try generate(now: now)
        try AtomicFileWrite.replace(at: keyPath, with: identity.privateKeyPEM)
        try AtomicFileWrite.replace(at: certificatePath, with: identity.certificatePEM)
        return identity
    }

    static func generate(now: Date) throws -> LoopbackTLSIdentity {
        let key = P256.Signing.PrivateKey()
        let certificateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("localhost")
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certificateKey.publicKey,
            // Backdated slightly so a clock a few minutes ahead of ours does
            // not reject a certificate born "in the future".
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(lifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(
                    BasicConstraints.notCertificateAuthority
                )
                SubjectAlternativeNames([
                    .dnsName("localhost"),
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
                    .ipAddress(
                        ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
                    ),
                ])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: certificateKey
        )
        return LoopbackTLSIdentity(
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: key.pemRepresentation
        )
    }

    /// The cached pair, or nil (throwing is also treated as nil by the
    /// caller) when either file is missing, the certificate does not parse,
    /// or it is too close to expiry to trust for one more flow.
    private static func cachedIdentity(
        certificatePath: String,
        keyPath: String,
        now: Date
    ) throws -> LoopbackTLSIdentity? {
        guard
            let certificateData = FileManager.default.contents(atPath: certificatePath),
            let keyData = FileManager.default.contents(atPath: keyPath)
        else { return nil }
        let certificatePEM = String(decoding: certificateData, as: UTF8.self)
        let privateKeyPEM = String(decoding: keyData, as: UTF8.self)
        let certificate = try Certificate(pemEncoded: certificatePEM)
        guard certificate.notValidAfter > now.addingTimeInterval(reuseMargin) else { return nil }
        // The key must still parse as the kind we generate; a corrupt or
        // hand-edited key fails here and the pair regenerates as one unit.
        _ = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        return LoopbackTLSIdentity(certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM)
    }
}
