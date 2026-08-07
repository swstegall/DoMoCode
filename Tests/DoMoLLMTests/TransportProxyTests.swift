// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import AsyncHTTPClient
import DoMoCore
import Foundation
import Testing

import DoMoLLM

/// Which client the production transport picks for a URL is the entirety of
/// proxy support, and it is otherwise invisible: the request looks identical
/// either way, only the socket it leaves on differs. These assert on client
/// identity, so the routing rules are pinned without a proxy to connect to and
/// without a packet leaving the process.
@Suite("AsyncHTTPClientTransport proxy routing")
struct TransportProxyRoutingTests {

    /// Hosts that resolve nowhere, so a mistake in the code under test surfaces
    /// as a failed expectation rather than as real traffic to somebody's server.
    private static let gatewayURL = URL(string: "https://gateway.corp.invalid/v1/chat/completions")
    private static let externalURL = URL(string: "https://api.vendor.invalid/v1/chat/completions")
    private static let loopbackURL = URL(string: "http://127.0.0.1:4123/v1/chat/completions")

    /// A proxy for everything except one gateway host and one domain suffix,
    /// spelled the way the conventional environment variables spell it.
    private static func proxiedSettings() -> ProxySettings {
        ProxyPolicy.fromEnvironment([
            "http_proxy": "http://proxy.corp.invalid:8080",
            "https_proxy": "http://proxy.corp.invalid:8080",
            "no_proxy": "gateway.corp.invalid,.direct.corp.invalid",
        ])
    }

    /// The default initializer is what `LiteLLMClient` builds when nobody asked
    /// for anything else, and it must stay exactly what it was before proxy
    /// support existed: the process-wide singleton, for every URL.
    @Test("With no proxy plumbing at all, every request stays on the shared client")
    func defaultTransportUsesTheSharedClient() throws {
        let transport = AsyncHTTPClientTransport()
        let gateway = try #require(Self.gatewayURL)
        let external = try #require(Self.externalURL)
        let loopback = try #require(Self.loopbackURL)

        #expect(transport.httpClient(for: gateway) === HTTPClient.shared)
        #expect(transport.httpClient(for: external) === HTTPClient.shared)
        #expect(transport.httpClient(for: loopback) === HTTPClient.shared)
    }

    /// An environment with none of the conventional variables set must behave as
    /// if nothing were routed at all — otherwise merely wiring the resolver in
    /// would change how every request is made for users who have no proxy.
    @Test("An unconfigured environment still hands back the shared client")
    func unconfiguredEnvironmentUsesTheSharedClient() async throws {
        let settings = ProxyPolicy.fromEnvironment([:])
        #expect(settings.isConfigured == false)

        let proxies = ProxiedHTTPClients(settings: settings)
        let transport = AsyncHTTPClientTransport(proxies: proxies)
        let gateway = try #require(Self.gatewayURL)
        let external = try #require(Self.externalURL)

        #expect(transport.httpClient(for: gateway) === HTTPClient.shared)
        #expect(transport.httpClient(for: external) === HTTPClient.shared)

        await proxies.shutdown()
    }

    /// The positive direction: a host the proxy applies to must not be sent on
    /// the singleton, which carries no proxy and would connect straight out —
    /// the exact failure a network-gated endpoint shows as a hung connection.
    @Test("A proxied host leaves on an owned client, and on the same one each time")
    func proxiedHostUsesAnOwnedClient() async throws {
        let proxies = ProxiedHTTPClients(settings: Self.proxiedSettings())
        let transport = AsyncHTTPClientTransport(proxies: proxies)
        let external = try #require(Self.externalURL)

        let first = transport.httpClient(for: external)
        let second = transport.httpClient(for: external)

        #expect(first !== HTTPClient.shared)
        // A second client for the same endpoint would mean a second event-loop
        // group and a pool that never reuses an already-warm connection.
        #expect(first === second)

        await proxies.shutdown()
    }

    /// The gateway gets no special treatment: it is matched against `no_proxy`
    /// like any other host, because a gateway reachable only inside a network is
    /// precisely what those entries are written for.
    @Test("A no_proxy entry sends the gateway direct, by the same rule as any host")
    func noProxyHostGoesDirect() async throws {
        let proxies = ProxiedHTTPClients(settings: Self.proxiedSettings())
        let transport = AsyncHTTPClientTransport(proxies: proxies)
        let gateway = try #require(Self.gatewayURL)
        let subdomain = try #require(URL(string: "https://models.direct.corp.invalid/v1/models"))
        let external = try #require(Self.externalURL)

        #expect(transport.httpClient(for: gateway) === HTTPClient.shared)
        // A leading-dot entry covers subdomains, so this one is direct as well.
        #expect(transport.httpClient(for: subdomain) === HTTPClient.shared)
        // A host the entries do not name is still proxied, so neither assertion
        // above can be passing merely because everything goes direct.
        #expect(transport.httpClient(for: external) !== HTTPClient.shared)

        await proxies.shutdown()
    }

    /// This tool's ordinary mode is a terminal client talking to a server it
    /// spawned on loopback. Routing that through a proxy breaks the program
    /// outright, and no proxy could reach it anyway, so loopback goes direct
    /// even though the `no_proxy` value here never mentions it.
    @Test("Loopback goes direct even when no_proxy does not list it")
    func loopbackAlwaysGoesDirect() async throws {
        let proxies = ProxiedHTTPClients(settings: Self.proxiedSettings())
        let transport = AsyncHTTPClientTransport(proxies: proxies)
        let numeric = try #require(Self.loopbackURL)
        let named = try #require(URL(string: "http://localhost:4123/v1/models"))
        let sixth = try #require(URL(string: "http://[::1]:4123/v1/models"))

        #expect(transport.httpClient(for: numeric) === HTTPClient.shared)
        #expect(transport.httpClient(for: named) === HTTPClient.shared)
        #expect(transport.httpClient(for: sixth) === HTTPClient.shared)

        await proxies.shutdown()
    }

    /// An injected client is a deliberate override — a caller that already built
    /// the client it wants, or a test standing in for one. Routing some of its
    /// requests elsewhere would silently defeat it.
    @Test("An injected client serves every URL, proxied host or not")
    func injectedClientIsNeverRouted() async throws {
        let owned = HTTPClient()
        let transport = AsyncHTTPClientTransport(client: owned)
        let external = try #require(Self.externalURL)
        let loopback = try #require(Self.loopbackURL)

        #expect(transport.httpClient(for: external) === owned)
        #expect(transport.httpClient(for: loopback) === owned)

        // Dropping an owned client without shutting it down leaks its
        // event-loop group and can hang the test process on exit.
        try await owned.shutdown()
    }
}
