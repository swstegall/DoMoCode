// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The credential store's promises, each pinned: owner-only modes from the
// first byte (0600 on create, preserved when the user chose something else —
// probed with 0640 because no common umask produces it by accident), server-
// URL binding so a config edit can never send server A's token to server B,
// a corrupt document that reads as "log in again" rather than a crash, and
// the ADFS retention rule callers rely on living where the merge happens.

import DoMoMCP
import Foundation
import Testing

/// Self-removing scratch directory, the ShellTests pattern.
private final class ScratchDirectory: Sendable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "domocode-oauth-store-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The permission bits of `path`, masked to what chmod controls.
private func posixMode(of path: String) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o7777 }
}

private func setMode(_ mode: Int, of path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

@Suite("OAuth token store")
struct OAuthTokenStoreTests {

    private func makeCredential(
        serverURL: String = "https://mcp.example.com/mcp",
        accessToken: String = "access-token-value-1234",
        refreshToken: String? = "refresh-token-value-1234"
    ) -> OAuthStoredCredential {
        OAuthStoredCredential(
            serverURL: serverURL,
            tokens: OAuthTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: 4_000_000_000
            ),
            client: OAuthClientRegistration(clientId: "client-1")
        )
    }

    @Test("A store created by the first save is owner-only")
    func createdOwnerOnly() async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "jira", serverURL: "https://mcp.example.com/mcp") { _ in
            self.makeCredential()
        }
        #expect(try posixMode(of: store.path) == 0o600)
    }

    @Test("An existing store keeps its mode across saves", arguments: [0o600, 0o640])
    func preservesMode(mode: Int) async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "jira", serverURL: "https://mcp.example.com/mcp") { _ in
            self.makeCredential()
        }
        try setMode(mode, of: store.path)
        _ = try await store.mutate(forKey: "jira", serverURL: "https://mcp.example.com/mcp") { _ in
            self.makeCredential(accessToken: "access-token-value-5678")
        }
        #expect(try posixMode(of: store.path) == mode)
    }

    @Test("A credential round-trips through disk")
    func roundTrip() async throws {
        let scratch = try ScratchDirectory()
        let serverURL = "https://mcp.example.com/mcp"
        let saved = makeCredential(serverURL: serverURL)
        do {
            let store = OAuthTokenStore(directory: scratch.path)
            _ = try await store.mutate(forKey: "jira", serverURL: serverURL) { _ in saved }
        }
        // A second store instance — the next run — reads the same entry.
        let reopened = OAuthTokenStore(directory: scratch.path)
        let loaded = await reopened.credential(forKey: "jira", serverURL: serverURL)
        #expect(loaded == saved)
    }

    @Test("A server-URL change reads as no credential at all")
    func serverURLBinding() async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "jira", serverURL: "https://mcp.example.com/mcp") { _ in
            self.makeCredential()
        }
        let other = await store.credential(forKey: "jira", serverURL: "https://other.example.com/mcp")
        #expect(other == nil, "a token minted for one server must never be offered for another")
        // And the mutate path sees nil too, so a flow for the new URL starts clean.
        _ = try await store.mutate(
            forKey: "jira",
            serverURL: "https://other.example.com/mcp"
        ) { current in
            #expect(current == nil)
            return current
        }
    }

    @Test("Removing tokens keeps the client registration")
    func removeTokensKeepsClient() async throws {
        let scratch = try ScratchDirectory()
        let serverURL = "https://mcp.example.com/mcp"
        let store = OAuthTokenStore(directory: scratch.path)
        _ = try await store.mutate(forKey: "jira", serverURL: serverURL) { _ in
            self.makeCredential(serverURL: serverURL)
        }
        try await store.removeTokens(forKey: "jira", serverURL: serverURL)
        let remaining = await store.credential(forKey: "jira", serverURL: serverURL)
        #expect(remaining?.tokens == nil, "invalid_grant must drop the dead grant")
        #expect(remaining?.client?.clientId == "client-1", "the client identity survives it")
    }

    @Test("A corrupt store reads as empty and recovers on the next save")
    func corruptRecovery() async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        let serverURL = "https://mcp.example.com/mcp"
        try "{ not json".write(toFile: store.path, atomically: true, encoding: .utf8)
        let loaded = await store.credential(forKey: "jira", serverURL: serverURL)
        #expect(loaded == nil, "corruption must read as 'log in again', not crash")
        _ = try await store.mutate(forKey: "jira", serverURL: serverURL) { _ in
            self.makeCredential(serverURL: serverURL)
        }
        let recovered = await store.credential(forKey: "jira", serverURL: serverURL)
        #expect(recovered != nil)
    }

    @Test("Two keys never see each other's entries")
    func keyNamespacing() async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        let serverURL = "https://mcp.example.com/mcp"
        _ = try await store.mutate(forKey: "jira", serverURL: serverURL) { _ in
            self.makeCredential(serverURL: serverURL, accessToken: "access-token-for-jira-1")
        }
        _ = try await store.mutate(forKey: "wiki", serverURL: serverURL) { _ in
            self.makeCredential(serverURL: serverURL, accessToken: "access-token-for-wiki-1")
        }
        let jira = await store.credential(forKey: "jira", serverURL: serverURL)
        let wiki = await store.credential(forKey: "wiki", serverURL: serverURL)
        #expect(jira?.tokens?.accessToken == "access-token-for-jira-1")
        #expect(wiki?.tokens?.accessToken == "access-token-for-wiki-1")
    }

    @Test("The persisted document is a cache-keyed map bound to the server URL")
    func documentShape() async throws {
        let scratch = try ScratchDirectory()
        let store = OAuthTokenStore(directory: scratch.path)
        let serverURL = "https://mcp.example.com/mcp"
        _ = try await store.mutate(forKey: "jira", serverURL: serverURL) { _ in
            self.makeCredential(serverURL: serverURL, accessToken: "access-token-doc-000042")
        }
        let contents = try #require(FileManager.default.contents(atPath: store.path))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: contents) as? [String: Any]
        )
        // Namespaced by cache key, each entry carrying its serverURL binding
        // and the token material — the exact shape the read path relies on.
        let entry = try #require(decoded["jira"] as? [String: Any])
        #expect(entry["serverURL"] as? String == serverURL)
        let tokens = try #require(entry["tokens"] as? [String: Any])
        #expect(tokens["accessToken"] as? String == "access-token-doc-000042")
        // The document is the secret layer — tokens belong here — but must
        // never carry a ready-to-paste `Bearer ` header line.
        #expect(!String(decoding: contents, as: UTF8.self).contains("Bearer "))
        // No stray files beside it (a torn temp, a second document).
        let files = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { !$0.hasPrefix(".") }
        #expect(files == ["tokens.json"])
    }
}
