// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import SystemPackage

public enum ResourcePackageKind: String, Sendable, Codable, Hashable, CaseIterable {
    case skill
    case command
    case theme
    case extensionManifest
}

public enum ResourceTrustState: String, Sendable, Codable, Hashable, CaseIterable {
    case untrusted
    case trusted
    case revoked
}

/// Provenance is part of the package identity rather than a display-only note.
/// A caller must provide an immutable GitHub source and pinned revision before a
/// resource can enter the cache.
public struct ResourcePackageManifest: Sendable, Codable, Hashable {
    public var id: String
    public var version: String
    public var kind: ResourcePackageKind
    public var sourceURL: String
    public var repository: String
    public var commit: String
    public var license: String
    public var contentDigest: String
    public var schemaVersion: Int
    public var codeBearing: Bool
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        version: String,
        kind: ResourcePackageKind,
        sourceURL: String,
        repository: String,
        commit: String,
        license: String = "MIT",
        contentDigest: String,
        schemaVersion: Int = 1,
        codeBearing: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.sourceURL = sourceURL
        self.repository = repository
        self.commit = commit
        self.license = license
        self.contentDigest = contentDigest.lowercased()
        self.schemaVersion = schemaVersion
        self.codeBearing = codeBearing
        self.metadata = metadata
    }
}

public struct ResourcePackageRecord: Sendable, Codable, Hashable {
    public let manifest: ResourcePackageManifest
    public var trust: ResourceTrustState
    public let installedAt: String

    public init(
        manifest: ResourcePackageManifest,
        trust: ResourceTrustState = .untrusted,
        installedAt: String
    ) {
        self.manifest = manifest
        self.trust = trust
        self.installedAt = installedAt
    }
}

public struct ResourcePackage: Sendable, Codable, Hashable {
    public var record: ResourcePackageRecord
    public let payload: Data

    public init(record: ResourcePackageRecord, payload: Data) {
        self.record = record
        self.payload = payload
    }
}

public enum ResourcePackageCacheError: Error, Sendable, Equatable {
    case invalidManifest(String)
    case invalidDigest(String)
    case notFound(String)
    case notTrusted(String)
    case revoked(String)
    case corrupt(String)
    case storage(String)
}

/// A reviewable, content-addressed cache for data resources. Installation only
/// writes bytes and metadata; it never interprets a skill, launches an
/// extension, or marks a package trusted. Callers must explicitly approve a
/// digest before ``activate(digest:)`` will return it.
public actor ResourcePackageCache {
    public let directory: FilePath

    private let now: @Sendable () -> String

    public init(
        directory: FilePath,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: directory.string,
                withIntermediateDirectories: true
            )
        } catch {
            throw ResourcePackageCacheError.storage(Redaction.diagnostic(String(describing: error)))
        }
        self.directory = directory
        self.now = now
    }

    /// Installs one immutable payload under its SHA-256 digest. Reinstalling
    /// the same digest is idempotent and preserves its existing trust state.
    public func install(
        _ manifest: ResourcePackageManifest,
        payload: Data
    ) throws -> ResourcePackageRecord {
        try Self.validate(manifest)
        let actualDigest = ResourceSHA256.hex(payload)
        guard actualDigest == manifest.contentDigest.lowercased() else {
            throw ResourcePackageCacheError.invalidDigest(
                "Manifest digest does not match the payload."
            )
        }

        let digest = actualDigest
        let packageDirectory = packageDirectory(for: digest)
        let recordPath = recordPath(for: digest)
        let payloadPath = payloadPath(for: digest)
        if FileManager.default.fileExists(atPath: recordPath.string),
           FileManager.default.fileExists(atPath: payloadPath.string) {
            let existing = try load(digest: digest)
            guard existing.record.manifest == manifest else {
                throw ResourcePackageCacheError.corrupt(digest)
            }
            return existing.record
        }

        do {
            try FileManager.default.createDirectory(
                atPath: packageDirectory.string,
                withIntermediateDirectories: true
            )
            try payload.write(to: URL(fileURLWithPath: payloadPath.string), options: .atomic)
            let record = ResourcePackageRecord(
                manifest: manifest,
                installedAt: now()
            )
            try Self.encode(record).write(
                to: URL(fileURLWithPath: recordPath.string),
                options: .atomic
            )
            return record
        } catch let error as ResourcePackageCacheError {
            throw error
        } catch {
            throw ResourcePackageCacheError.storage(Redaction.diagnostic(String(describing: error)))
        }
    }

    public func load(digest: String) throws -> ResourcePackage {
        let normalized = try Self.validatedDigest(digest)
        let recordURL = URL(fileURLWithPath: recordPath(for: normalized).string)
        let payloadURL = URL(fileURLWithPath: payloadPath(for: normalized).string)
        guard FileManager.default.fileExists(atPath: recordURL.path),
              FileManager.default.fileExists(atPath: payloadURL.path)
        else {
            throw ResourcePackageCacheError.notFound(normalized)
        }

        do {
            let record = try Self.decode(
                ResourcePackageRecord.self,
                from: Data(contentsOf: recordURL)
            )
            let payload = try Data(contentsOf: payloadURL)
            guard record.manifest.contentDigest.lowercased() == ResourceSHA256.hex(payload) else {
                throw ResourcePackageCacheError.corrupt(normalized)
            }
            return ResourcePackage(record: record, payload: payload)
        } catch let error as ResourcePackageCacheError {
            throw error
        } catch {
            throw ResourcePackageCacheError.corrupt(normalized)
        }
    }

    /// Marks a digest trusted or revoked. This is the only operation that can
    /// change a package's trust state after installation.
    @discardableResult
    public func setTrust(
        digest: String,
        state: ResourceTrustState
    ) throws -> ResourcePackageRecord {
        let normalized = try Self.validatedDigest(digest)
        var package = try load(digest: normalized)
        package.record.trust = state
        do {
            try Self.encode(package.record).write(
                to: URL(fileURLWithPath: recordPath(for: normalized).string),
                options: .atomic
            )
        } catch {
            throw ResourcePackageCacheError.storage(Redaction.diagnostic(String(describing: error)))
        }
        return package.record
    }

    /// Returns only a package that an explicit trust decision has approved.
    /// Revocation is checked separately so diagnostics can explain the reason.
    public func activate(digest: String) throws -> ResourcePackage {
        let package = try load(digest: digest)
        switch package.record.trust {
        case .trusted:
            return package
        case .untrusted:
            throw ResourcePackageCacheError.notTrusted(package.record.manifest.id)
        case .revoked:
            throw ResourcePackageCacheError.revoked(package.record.manifest.id)
        }
    }

    public func list() throws -> [ResourcePackageRecord] {
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.string)
            return try entries
                .filter { Self.isDigest($0) }
                .sorted()
                .map { try load(digest: $0).record }
        } catch let error as ResourcePackageCacheError {
            throw error
        } catch {
            throw ResourcePackageCacheError.storage(Redaction.diagnostic(String(describing: error)))
        }
    }

    private func packageDirectory(for digest: String) -> FilePath {
        directory.appending(digest)
    }

    private func recordPath(for digest: String) -> FilePath {
        packageDirectory(for: digest).appending("record.json")
    }

    private func payloadPath(for digest: String) -> FilePath {
        packageDirectory(for: digest).appending("payload.bin")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func validate(_ manifest: ResourcePackageManifest) throws(ResourcePackageCacheError) {
        let fields: [(String, String)] = [
            ("id", manifest.id),
            ("version", manifest.version),
            ("repository", manifest.repository),
            ("commit", manifest.commit),
        ]
        for (name, value) in fields where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .invalidManifest("Resource \(name) must not be empty.")
        }
        guard let url = URL(string: manifest.sourceURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com")
        else {
            throw .invalidManifest("Resource source must be an HTTPS GitHub URL.")
        }
        guard manifest.license.trimmingCharacters(in: .whitespacesAndNewlines) == "MIT" else {
            throw .invalidManifest("Only MIT-licensed resources may enter this cache.")
        }
        guard manifest.schemaVersion > 0 else {
            throw .invalidManifest("Resource schemaVersion must be positive.")
        }
        guard !manifest.commit.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" }) else {
            throw .invalidManifest("Resource commit must be a pinned identifier.")
        }
        _ = try validatedDigest(manifest.contentDigest)
    }

    private static func validatedDigest(_ digest: String) throws(ResourcePackageCacheError) -> String {
        let normalized = digest.lowercased()
        guard isDigest(normalized) else {
            throw .invalidDigest(digest)
        }
        return normalized
    }

    private static func isDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

/// Small dependency-free SHA-256 implementation used only for cache identity.
/// Keeping this in Core avoids making resource installation depend on a crypto
/// package or treating a transitive dependency as part of the public contract.
private enum ResourceSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let s0 = words[index - 15].rotateRight(7)
                    ^ words[index - 15].rotateRight(18)
                    ^ (words[index - 15] >> 3)
                let s1 = words[index - 2].rotateRight(17)
                    ^ words[index - 2].rotateRight(19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]
            for index in 0..<64 {
                let sum1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }

        return hash.map { value in
            let high = String(format: "%08x", value)
            return high
        }.joined()
    }
}

private extension UInt32 {
    func rotateRight(_ count: UInt32) -> UInt32 {
        (self >> count) | (self << (32 - count))
    }
}
