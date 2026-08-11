// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The loopback TLS identity: generated valid for exactly the names a
// loopback redirect can use, cached owner-only, reused while healthy, and
// replaced as one unit when close to expiry — so the browser's one-time
// trust decision survives across runs but a mid-flow expiry cannot happen.

import DoMoMCP
import Foundation
import SwiftASN1
import Testing
import X509

private final class ScratchDirectory: Sendable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "domocode-oauth-cert-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func posixMode(of path: String) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o7777 }
}

@Suite("Self-signed loopback certificate")
struct SelfSignedCertificateTests {

    @Test("A generated certificate names localhost and both loopback addresses")
    func namesAndShape() throws {
        let scratch = try ScratchDirectory()
        let identity = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        let certificate = try Certificate(pemEncoded: identity.certificatePEM)

        #expect(certificate.subject.description.contains("localhost"))
        #expect(certificate.issuer == certificate.subject, "self-signed means issuer == subject")

        let san = try #require(
            try certificate.extensions.subjectAlternativeNames,
            "the SAN extension is what browsers actually check"
        )
        let names = Array(san)
        #expect(names.contains(.dnsName("localhost")))
        #expect(names.count == 3, "localhost + 127.0.0.1 + ::1, nothing else")

        // The IP SANs are the entries that make an https://127.0.0.1 or
        // https://[::1] redirect validate — assert their exact octets, not
        // just that three names exist.
        let ipOctets = names.compactMap { name -> [UInt8]? in
            if case .ipAddress(let octets) = name { return Array(octets.bytes) }
            return nil
        }
        #expect(ipOctets.contains([127, 0, 0, 1]), "the IPv4 loopback SAN")
        #expect(
            ipOctets.contains([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
            "the IPv6 loopback SAN"
        )

        let now = Date()
        #expect(certificate.notValidBefore < now, "backdated so clock skew cannot reject it")
        #expect(certificate.notValidAfter > now.addingTimeInterval(300 * 24 * 3600))
    }

    @Test("The cached pair is owner-only on disk")
    func cachedModes() throws {
        let scratch = try ScratchDirectory()
        _ = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        #expect(try posixMode(of: scratch.path + "/localhost.pem") == 0o600)
        #expect(try posixMode(of: scratch.path + "/localhost.key") == 0o600)
    }

    @Test("A healthy cached pair is reused, byte for byte")
    func cacheReuse() throws {
        let scratch = try ScratchDirectory()
        let first = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        let second = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        #expect(first == second, "regenerating would re-trigger the browser trust warning")
    }

    @Test("A pair near expiry is replaced rather than trusted for one more flow")
    func expiryReplacement() throws {
        let scratch = try ScratchDirectory()
        let first = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        // Ask again from a vantage point 364.9 days later: inside the 24h
        // reuse margin, so the cached pair must be replaced.
        let nearExpiry = Date().addingTimeInterval(364.9 * 24 * 3600)
        let second = try SelfSignedCertificate.loopbackIdentity(in: scratch.path, now: nearExpiry)
        #expect(first != second)
    }

    @Test("A corrupt cached key regenerates the pair as one unit")
    func corruptKeyRegenerates() throws {
        let scratch = try ScratchDirectory()
        let first = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        try "not a key".write(toFile: scratch.path + "/localhost.key", atomically: true, encoding: .utf8)
        let second = try SelfSignedCertificate.loopbackIdentity(in: scratch.path)
        #expect(second != first)
        #expect(second.certificatePEM != first.certificatePEM, "a cert without its key is useless")
    }
}
