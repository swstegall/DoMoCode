// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Where MCP OAuth credentials live between runs: one 0600 JSON document under
// the config directory, keyed by cache key (defaulting to the server name),
// never settings.json — settings is contractually the non-secret layer.
//
// Every entry is bound to the server URL it was minted for. A config edit that
// points the same name at a different server silently invalidates the entry
// rather than sending server A's bearer token to server B.
//
// Writes go through `FileLock` + `AtomicFileWrite`: the file is created 0600
// before a byte of secret touches disk, replaced by rename so a reader never
// sees a torn document, and cross-process read-modify-write is serialized on
// the standard sidecar lock. Every secret that passes through here is
// registered with the redaction vault on the way, so a token echoed into any
// diagnostic is scrubbed even when the echo is unrecognizable as a header.

import DoMoCore
import Foundation
import SystemPackage

/// The token material from one successful exchange or refresh.
public struct OAuthTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    /// Unix seconds when the access token expires; absent when the server
    /// declined to say (RFC 6749 §5.1). An absent expiry is treated as
    /// *usable* — the 401 refresh-and-replay path detects the real expiry —
    /// because treating unknown as expired would refresh (or, without a refresh
    /// token, fail) on every single request.
    public var expiresAt: Double?
    /// Unix seconds when the *refresh* token expires. Non-standard but ADFS
    /// reports it (`refresh_token_expires_in`), and it is the difference
    /// between a silent refresh and a surprise browser round-trip.
    public var refreshTokenExpiresAt: Double?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Double? = nil,
        refreshTokenExpiresAt: Double? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scope = scope
    }
}

/// A client identity obtained through RFC 7591 dynamic registration (or copied
/// from explicit config so the whole credential round-trips as one record).
public struct OAuthClientRegistration: Sendable, Hashable, Codable {
    public var clientId: String
    /// Some registrars issue secrets even to native clients. Stored here —
    /// 0600, outside settings — and sent only with the token requests.
    public var clientSecret: String?
    /// Unix seconds; an expired secret triggers re-registration.
    public var clientSecretExpiresAt: Double?

    public init(clientId: String, clientSecret: String? = nil, clientSecretExpiresAt: Double? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.clientSecretExpiresAt = clientSecretExpiresAt
    }
}

/// Everything persisted for one cache key.
public struct OAuthStoredCredential: Sendable, Hashable, Codable {
    /// The MCP server URL this credential was minted for; the read path
    /// refuses to return the entry for any other URL.
    public var serverURL: String
    public var tokens: OAuthTokens?
    public var client: OAuthClientRegistration?

    public init(serverURL: String, tokens: OAuthTokens? = nil, client: OAuthClientRegistration? = nil) {
        self.serverURL = serverURL
        self.tokens = tokens
        self.client = client
    }
}

/// The file-backed credential store. One instance per `MCPManager`; safe
/// against other processes via the file lock, against sibling tasks by being
/// an actor.
public actor OAuthTokenStore {
    /// The document all credentials live in.
    public nonisolated let path: String

    public init(directory: String) {
        self.path = directory + "/tokens.json"
        // The directory holds only secrets (tokens, the loopback key), so it
        // is owner-only from the start — `AtomicFileWrite` guarantees 0600 on
        // the FILES, but the enclosing directory it lazily creates would
        // otherwise be 0755 under the common umask. Best-effort: a failure
        // here surfaces as the write's own errno later.
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// The credential for `key`, or nil when there is none *for this server
    /// URL* — a URL mismatch reads as absent rather than as somebody else's
    /// token.
    public func credential(forKey key: String, serverURL: String) -> OAuthStoredCredential? {
        guard let entry = loadAll()[key], entry.serverURL == serverURL else { return nil }
        return entry
    }

    /// Read-modify-write under the cross-process lock. `body` sees the entry
    /// as it is on disk *now* (nil when absent or URL-mismatched) and returns
    /// what should be stored (nil removes the entry).
    public func mutate(
        forKey key: String,
        serverURL: String,
        _ body: @Sendable (OAuthStoredCredential?) throws -> OAuthStoredCredential?
    ) async throws -> OAuthStoredCredential? {
        let outcome = try await FileLock.withLock(
            at: FileLock.lockPath(forDocumentAt: path),
            timeout: .seconds(10)
        ) {
            var all = self.loadAll()
            let current = all[key].flatMap { $0.serverURL == serverURL ? $0 : nil }
            let replacement = try body(current)
            if var replacement {
                replacement.serverURL = serverURL
                all[key] = replacement
            } else {
                all[key] = nil
            }
            try self.persist(all)
            return replacement
        }
        switch outcome {
        case .ran(let value):
            return value
        case .cancelled:
            throw CancellationError()
        case .contended:
            throw DoMoError(
                .file(path: FilePath(path), errno: nil),
                "the MCP OAuth token store is locked by another process"
            )
        }
    }

    /// Drops the tokens for `key` (keeping any client registration): the
    /// response to `invalid_grant`, where the identity is fine but the grant
    /// is dead.
    public func removeTokens(forKey key: String, serverURL: String) async throws {
        _ = try await mutate(forKey: key, serverURL: serverURL) { current in
            guard var current else { return nil }
            current.tokens = nil
            return current
        }
    }

    /// Serializes an async critical section on a per-`key` lock file, for
    /// flows that must not run twice across processes (an interactive login,
    /// a refresh). Scoped to the key so one server's browser login does not
    /// stall another server's silent refresh. The body re-reads through this
    /// store, so a peer that finished the same work first is observed rather
    /// than repeated. Excludes same-process tasks too — `flock` is per open
    /// descriptor, and each acquire opens its own.
    public func withExclusiveFlow<T: Sendable>(
        key: String,
        timeout: Duration = .seconds(300),
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        // The key becomes part of a filename, so reduce it to a safe token; a
        // collision after reduction only over-serializes, never mixes state.
        let safeKey = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let outcome = try await FileLock.withLock(
            at: FileLock.lockPath(forDocumentAt: path + "." + String(safeKey) + ".flow"),
            timeout: timeout,
            body
        )
        switch outcome {
        case .ran(let value):
            return value
        case .cancelled:
            throw CancellationError()
        case .contended:
            throw DoMoError(
                .file(path: FilePath(path), errno: nil),
                "another process is already logging in to this MCP server"
            )
        }
    }

    // MARK: - Disk

    private func loadAll() -> [String: OAuthStoredCredential] {
        guard let data = FileManager.default.contents(atPath: path),
              let all = try? JSONDecoder().decode([String: OAuthStoredCredential].self, from: data)
        else { return [:] }
        // A corrupt or unreadable store reads as empty: the recovery is a
        // fresh login, not a crash. Registration happens on *every* load so a
        // token is in the vault before any code path can quote it.
        registerSecrets(in: all)
        return all
    }

    private func persist(_ all: [String: OAuthStoredCredential]) throws {
        registerSecrets(in: all)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)
        try AtomicFileWrite.replace(
            at: path,
            with: String(decoding: data, as: UTF8.self)
        )
    }

    private nonisolated func registerSecrets(in all: [String: OAuthStoredCredential]) {
        for entry in all.values {
            Redaction.register(entry.tokens?.accessToken)
            Redaction.register(entry.tokens?.refreshToken)
            Redaction.register(entry.client?.clientSecret)
        }
    }
}
