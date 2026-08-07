// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoCore
import Foundation
import Synchronization

/// Picks the `HTTPClient` a request must leave on, and owns every client it had
/// to build to offer that choice.
///
/// This type exists because of a mismatch, not because a proxy needs a factory.
/// The `no_proxy` convention is a **per-host** rule — some destinations go
/// through a corporate HTTP proxy, an intranet host or a loopback port goes
/// direct — while AsyncHTTPClient carries the proxy on the **client**, in
/// `HTTPClient.Configuration.proxy`, with no per-request override. Honouring
/// `no_proxy` therefore means holding more than one client and choosing between
/// them per URL, which is what this does, rather than the one-line configuration
/// change proxy support looks like it should be.
///
/// Two failure modes are worse than shipping no proxy support at all, and the
/// shape here is dictated by avoiding both:
///
/// - **`HTTPClient.shared` must never be shut down.** It is process-wide, and
///   code with nothing to do with proxies holds it. AsyncHTTPClient guards this
///   itself — the singleton is built `canBeShutDown: false` and answers
///   `HTTPClientError.shutdownUnsupported` — but the guarantee here is stronger
///   and cheaper to check: `.shared` is never entered into the owned table, so
///   ``shutdown()`` has no way to reach it.
/// - **An owned client that is never shut down is a crash, not just a leak.**
///   `HTTPClient.deinit` calls `preconditionFailure` in debug builds when the
///   client is still running, and in release it strands connections and a
///   background activity loop that can hold up process exit. So a client is
///   recorded under the same lock that decided to build it, before it is handed
///   to anyone, and ``shutdown()`` covers the entire table.
///
/// When nothing is configured this owns nothing whatsoever and returns
/// `HTTPClient.shared` for every URL, so the overwhelmingly common case behaves
/// exactly as it did before this file existed.
public final class ProxiedHTTPClients: Sendable, CustomStringConvertible {

    /// The clients built so far, and whether teardown has already run.
    ///
    /// One struct behind one lock rather than two independent boxes: the
    /// decision to build a client and the record that it exists must not be
    /// separable, or a client can reach a caller that ``shutdown()`` will miss.
    private struct State {
        var owned: [ProxyEndpoint: HTTPClient] = [:]
        var isShutDown = false
    }

    private let settings: ProxySettings
    private let base: HTTPClient.Configuration
    private let state = Mutex(State())

    /// The most clients this will ever build.
    ///
    /// ``ProxySettings`` can name at most two distinct proxies — one for `http:`
    /// and one for `https:` — so this ceiling is unreachable through the
    /// supported configuration. It is here because each entry costs a connection
    /// pool and a set of event-loop registrations that only ``shutdown()``
    /// releases, and a table keyed on something derived from request URLs must
    /// not be able to grow with them.
    private static let maximumOwnedClients = 2

    /// - Parameters:
    ///   - settings: The resolved proxy configuration. When
    ///     ``DoMoCore/ProxySettings/isConfigured`` is `false` this instance owns
    ///     nothing and every call to ``client(for:)`` answers
    ///     `HTTPClient.shared`.
    ///   - base: The configuration each owned client starts from; only its
    ///     `proxy` field is overwritten. It intentionally defaults to
    ///     AsyncHTTPClient's own default rather than to
    ///     `HTTPClient.Configuration.singletonConfiguration`, whose 90-second
    ///     read timeout would cut a long streamed response short underneath the
    ///     transport's own idle guard. A caller that wants the singleton's
    ///     browser-like behaviour on proxied traffic passes it here.
    public init(settings: ProxySettings, base: HTTPClient.Configuration = .init()) {
        self.settings = settings
        self.base = base
        // A proxy URL is one of the few places a password is routinely typed
        // into an environment variable, and the code most likely to print one is
        // nowhere near here — a connect failure raised inside NIO, quoted into a
        // transport error by a layer that has no idea it is holding a
        // credential. Registering it now is what lets the process-wide scrubber
        // reach those sites. Done whatever `enabled` says, because a disabled
        // proxy URL is still sitting in the environment where something can
        // quote it, and the registry ignores anything too short to be worth
        // replacing, so a password that is also an ordinary word cannot shred an
        // unrelated diagnostic.
        for raw in [settings.httpProxy, settings.httpsProxy] {
            guard let raw, let endpoint = ProxyPolicy.endpoint(from: raw) else { continue }
            Redaction.register(endpoint.password)
        }
    }

    deinit {
        // `HTTPClient.deinit` traps in debug builds on a client that is still
        // running, so dropping this without teardown already crashes — but it
        // crashes inside AsyncHTTPClient, pointing at a client whose owner is
        // not in the backtrace. Failing here first names what actually went
        // wrong: somebody released the factory without awaiting `shutdown()`.
        assert(
            state.withLock { $0.owned.isEmpty },
            "ProxiedHTTPClients was released without awaiting shutdown(); its clients can no longer be torn down."
        )
    }

    /// The client to use for `url` — proxied or direct, per the `no_proxy` rules
    /// in ``DoMoCore/ProxyPolicy``.
    ///
    /// Safe to call concurrently. It takes a lock rather than being an actor
    /// because every caller is synchronous: an actor would force `await` into
    /// request-construction paths that have no other reason to suspend.
    ///
    /// The returned client is owned by this instance and must not be shut down
    /// by the caller. A direct answer is `HTTPClient.shared`, which cannot be
    /// shut down at all.
    public func client(for url: URL) -> HTTPClient {
        guard settings.isConfigured, let endpoint = ProxyPolicy.endpoint(for: url, settings: settings) else {
            return .shared
        }
        return state.withLock { state -> HTTPClient in
            if let existing = state.owned[endpoint] { return existing }
            // Past teardown there is no owner left to shut a new client down,
            // and past the ceiling a new entry would be one nothing bounded.
            // Direct is the only safe answer in both cases: handing back one of
            // the clients already built would send a request — and its
            // `Authorization` header — through a proxy the user configured for
            // something else, which is worse than a connection error they can
            // see and fix.
            guard !state.isShutDown, state.owned.count < Self.maximumOwnedClients else { return .shared }
            let client = HTTPClient(configuration: configuration(for: endpoint))
            state.owned[endpoint] = client
            return client
        }
    }

    /// Shuts down every client this built. Idempotent, and a no-op when nothing
    /// was ever built.
    ///
    /// After this returns, ``client(for:)`` answers `HTTPClient.shared` for
    /// every URL: a request made after teardown goes direct — and most likely
    /// fails — rather than silently resurrecting a client that nothing would
    /// then be responsible for closing.
    public func shutdown() async {
        let owned = state.withLock { state -> [HTTPClient] in
            state.isShutDown = true
            let built = Array(state.owned.values)
            // Emptied here, so a second call has nothing left to shut down and
            // cannot hit `HTTPClientError.alreadyShutdown` on the same client.
            state.owned.removeAll()
            return built
        }
        for client in owned {
            // Nothing above this can act on a teardown failure, and throwing
            // into a shutdown path leaves the remaining clients running. Every
            // client gets its call regardless of what the previous one did.
            try? await client.shutdown()
        }
    }

    /// A rendering safe to put in a log line, an error or a bug report.
    ///
    /// Built from the parsed host and port rather than from the configured
    /// string, because `http://user:password@proxy.example.com:8080` is an
    /// ordinary way to write a proxy variable and the userinfo half of it must
    /// never reach a reader. The result still goes through
    /// ``DoMoCore/Redaction/diagnostic(_:)``, which costs nothing on a cold path
    /// and covers a host name that was itself registered as a secret.
    public var description: String {
        guard settings.isConfigured else { return "ProxiedHTTPClients(direct)" }
        var authorities: [String] = []
        for raw in [settings.httpProxy, settings.httpsProxy] {
            guard let raw, let endpoint = ProxyPolicy.endpoint(from: raw) else { continue }
            let authority = "\(endpoint.isSOCKS ? "socks" : "http")://\(endpoint.host):\(endpoint.port)"
            guard !authorities.contains(authority) else { continue }
            authorities.append(authority)
        }
        // Enabled with nothing parseable in it routes nothing, and saying so is
        // more use to a reader than an empty list they have to interpret.
        guard !authorities.isEmpty else { return "ProxiedHTTPClients(direct)" }
        return Redaction.diagnostic("ProxiedHTTPClients(via: \(authorities.joined(separator: ", ")))")
    }

    // MARK: - Client construction

    private func configuration(for endpoint: ProxyEndpoint) -> HTTPClient.Configuration {
        var configuration = base
        configuration.proxy = Self.proxy(for: endpoint)
        return configuration
    }

    /// Built without importing NIO: `.server` and `.socksServer` are reached by
    /// member syntax, the same way ``AsyncHTTPClientTransport`` reaches NIO's
    /// currency types, because this target does not declare NIOCore as a direct
    /// dependency.
    private static func proxy(for endpoint: ProxyEndpoint) -> HTTPClient.Configuration.Proxy {
        guard !endpoint.isSOCKS else {
            // Assigning `authorization` on a SOCKS proxy trips a `precondition`
            // inside AsyncHTTPClient — it has no SOCKS authentication — so
            // credentials on a `socks://` URL are dropped rather than sent
            // somewhere that would take the process down. The connection is
            // then refused by the proxy, which is a diagnosable failure.
            return .socksServer(host: endpoint.host, port: endpoint.port)
        }
        guard let username = endpoint.username else {
            return .server(host: endpoint.host, port: endpoint.port)
        }
        // A proxy URL may carry a username with no password at all
        // (`http://user@proxy:8080`); the empty half still has to be sent, or
        // the `CONNECT` goes out unauthenticated and fails with a 407 that says
        // nothing about the credential having been thrown away here.
        return .server(
            host: endpoint.host,
            port: endpoint.port,
            authorization: .basic(username: username, password: endpoint.password ?? "")
        )
    }
}
