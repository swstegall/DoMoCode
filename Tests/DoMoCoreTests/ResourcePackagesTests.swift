// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage
import Testing

@Suite("Resource package cache", .serialized)
struct ResourcePackagesTests {
    @Test("installation is content addressed, untrusted, and explicitly activatable")
    func installsAndTrusts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let cache = try ResourcePackageCache(
            directory: directory,
            now: { "2026-01-01T00:00:00Z" }
        )
        let payload = Data("hello".utf8)
        let manifest = ResourcePackageManifest(
            id: "theme/gruvbox",
            version: "1.0.0",
            kind: .theme,
            sourceURL: "https://github.com/example/theme/blob/abc/theme.json",
            repository: "example/theme",
            commit: "abc123",
            contentDigest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        let first = try await cache.install(manifest, payload: payload)
        let second = try await cache.install(manifest, payload: payload)
        #expect(first == second)
        #expect(first.trust == .untrusted)
        #expect(try await cache.list().count == 1)

        await #expect(throws: ResourcePackageCacheError.notTrusted("theme/gruvbox")) {
            _ = try await cache.activate(digest: manifest.contentDigest)
        }
        let trusted = try await cache.setTrust(digest: manifest.contentDigest, state: .trusted)
        #expect(trusted.trust == .trusted)
        #expect(try await cache.activate(digest: manifest.contentDigest).payload == payload)
        _ = try await cache.setTrust(digest: manifest.contentDigest, state: .revoked)
        await #expect(throws: ResourcePackageCacheError.revoked("theme/gruvbox")) {
            _ = try await cache.activate(digest: manifest.contentDigest)
        }
    }

    @Test("the cache rejects non-MIT sources and digest mismatches")
    func rejectsUnsafeManifest() async throws {
        let cache = try ResourcePackageCache(directory: temporaryDirectory())
        let base = ResourcePackageManifest(
            id: "resource",
            version: "1",
            kind: .skill,
            sourceURL: "https://github.com/example/resource",
            repository: "example/resource",
            commit: "abc",
            contentDigest: String(repeating: "0", count: 64)
        )
        await #expect(throws: ResourcePackageCacheError.invalidDigest(
            "Manifest digest does not match the payload."
        )) {
            _ = try await cache.install(base, payload: Data("wrong".utf8))
        }
        await #expect(throws: ResourcePackageCacheError.invalidManifest(
            "Only MIT-licensed resources may enter this cache."
        )) {
            _ = try await cache.install(
                ResourcePackageManifest(
                    id: base.id,
                    version: base.version,
                    kind: base.kind,
                    sourceURL: base.sourceURL,
                    repository: base.repository,
                    commit: base.commit,
                    license: "Apache-2.0",
                    contentDigest: base.contentDigest
                ),
                payload: Data()
            )
        }
    }

    private func temporaryDirectory() -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-resources-\(UUID().uuidString)", isDirectory: true)
                .path
        )
    }
}
