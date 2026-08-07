// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Which client a URL leaves on is the entirety of proxy support, and it is
// invisible from the outside: the request is byte-identical either way, only the
// socket differs. So every assertion here is about client *identity* and about
// teardown — no proxy is stood up and no packet leaves the process.
//
// The two things these exist to stop are both worse than having no proxy
// support: `HTTPClient.shared` being shut down, which breaks every unrelated
// caller in the process, and an owned client that nothing shuts down, which
// traps in `HTTPClient.deinit` in debug builds and strands connections in
// release. Every test that could build a client therefore ends by tearing it
// down, and one of them proves the teardown actually reached what it built
// rather than merely emptying a table.
//
// Hosts are all under `.invalid` (RFC 2606), so a routing mistake surfaces as a
// failed expectation rather than as traffic to somebody's real server.

import AsyncHTTPClient
import DoMoCore
import Foundation
import Testing

import DoMoLLM

// MARK: - Fixtures

/// A proxy for everything, spelled the way the conventional environment
/// variables spell it, with two exceptions the `no_proxy` convention understands:
/// one exact host and one domain suffix.
private func proxyEverythingExceptSettings() -> ProxySettings {
    ProxyPolicy.fromEnvironment([
        "http_proxy": "http://proxy.corp.invalid:8080",
        "https_proxy": "http://proxy.corp.invalid:8080",
        "no_proxy": "gateway.corp.invalid,.direct.corp.invalid",
    ])
}

/// A fixture URL that failed to parse, which is a mistake in this file rather
/// than a finding about the code under test — hence its own error, so it reads
/// as such in the failure output.
private struct MalformedFixtureURL: Error {
    let string: String
}

private func url(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw MalformedFixtureURL(string: string) }
    return url
}

// MARK: - Owning nothing when nothing is configured

@Suite("ProxiedHTTPClients with no proxy configured")
struct ProxiedHTTPClientsDirectTests {

    /// The common case by an enormous margin, and the one that must not change:
    /// with nothing configured this hands back the process-wide singleton for
    /// every URL, so a user with no proxy gets exactly the client they got
    /// before any of this existed.
    @Test("Unconfigured settings hand back the shared client for every URL")
    func unconfiguredSettingsHandBackTheSharedClient() async throws {
        let external = try url("https://api.vendor.invalid/v1/chat/completions")
        let intranet = try url("http://service.corp.invalid:8443/mcp")
        let loopback = try url("http://127.0.0.1:4123/mcp")

        for settings in [ProxySettings.disabled, ProxyPolicy.fromEnvironment([:])] {
            // Stated rather than assumed: if `isConfigured` were true here the
            // identity checks below would be testing a different code path than
            // the one they are named for.
            #expect(settings.isConfigured == false)

            let clients = ProxiedHTTPClients(settings: settings)
            #expect(clients.client(for: external) === HTTPClient.shared)
            #expect(clients.client(for: intranet) === HTTPClient.shared)
            #expect(clients.client(for: loopback) === HTTPClient.shared)

            await clients.shutdown()
        }
    }

    /// Teardown with nothing built must be a no-op, not a call into
    /// `HTTPClient.shared.shutdown()`. Repeating it is what an owner that is
    /// unsure whether it already tore down will do.
    @Test("Shutdown is safe and repeatable when nothing was ever built")
    func shutdownIsSafeWhenNothingWasBuilt() async throws {
        let external = try url("https://api.vendor.invalid/")
        let clients = ProxiedHTTPClients(settings: .disabled)
        await clients.shutdown()
        await clients.shutdown()

        // The singleton survived: it is still handed out, which a client that
        // had been torn down could not be.
        #expect(clients.client(for: external) === HTTPClient.shared)
    }
}

// MARK: - Choosing per URL

@Suite("ProxiedHTTPClients routing")
struct ProxiedHTTPClientsRoutingTests {

    /// The whole reason this type exists rather than a single configured client:
    /// one set of settings has to answer differently for two hosts, because
    /// AsyncHTTPClient carries the proxy on the client and cannot be told to
    /// skip it for one request.
    @Test("A proxied host gets an owned client and a no_proxy host stays on the shared one")
    func proxiedAndBypassedHostsGetDifferentClients() async throws {
        let external = try url("https://api.vendor.invalid/v1/chat/completions")
        let exactBypass = try url("https://gateway.corp.invalid/v1/chat/completions")
        let suffixBypass = try url("https://build.direct.corp.invalid/status")

        let clients = ProxiedHTTPClients(settings: proxyEverythingExceptSettings())

        #expect(clients.client(for: external) !== HTTPClient.shared)
        #expect(clients.client(for: exactBypass) === HTTPClient.shared)
        #expect(clients.client(for: suffixBypass) === HTTPClient.shared)

        await clients.shutdown()
    }

    /// A client per request would be a connection pool per request. Two hosts
    /// that resolve to the same proxy must share one.
    @Test("Hosts that resolve to the same proxy share a single client")
    func oneEndpointIsBuiltOnce() async throws {
        let first = try url("https://api.vendor.invalid/v1/chat/completions")
        let second = try url("https://models.vendor.invalid/v1/embeddings")

        let clients = ProxiedHTTPClients(settings: proxyEverythingExceptSettings())

        let a = clients.client(for: first)
        let b = clients.client(for: second)
        let again = clients.client(for: first)

        #expect(a !== HTTPClient.shared)
        #expect(a === b)
        #expect(a === again)

        await clients.shutdown()
    }

    /// `http_proxy` and `https_proxy` are allowed to name different hosts, and
    /// the proxy is a property of the client, so this is the case that forces a
    /// second one. It is also the case that pins the ceiling's off-by-one: two
    /// is exactly the number this must still be willing to build.
    @Test("A distinct proxy per scheme gets its own client")
    func perSchemeProxiesGetSeparateClients() async throws {
        let insecure = try url("http://api.vendor.invalid/v1/chat/completions")
        let secure = try url("https://api.vendor.invalid/v1/chat/completions")

        let clients = ProxiedHTTPClients(settings: ProxyPolicy.fromEnvironment([
            "http_proxy": "http://proxy-a.corp.invalid:3128",
            "https_proxy": "http://proxy-b.corp.invalid:8080",
        ]))

        let viaA = clients.client(for: insecure)
        let viaB = clients.client(for: secure)

        #expect(viaA !== HTTPClient.shared)
        #expect(viaB !== HTTPClient.shared)
        #expect(viaA !== viaB)
        // Still one apiece: the second lookup must not have built a third.
        #expect(clients.client(for: insecure) === viaA)
        #expect(clients.client(for: secure) === viaB)

        await clients.shutdown()
    }

    /// Loopback must go direct whatever the settings say. This application's
    /// default mode is a terminal client talking to a server it spawned on
    /// loopback: routing that through a proxy breaks the program outright, and
    /// no proxy could reach the port anyway. Asserted here, at the layer that
    /// hands out the client, and not only in the policy's own tests.
    @Test("A loopback endpoint is never proxied, even with a proxy for everything")
    func loopbackIsNeverProxied() async throws {
        let byAddress = try url("http://127.0.0.1:4123/mcp")
        let byName = try url("http://localhost:4123/mcp")
        let byIPv6 = try url("http://[::1]:4123/mcp")
        let external = try url("https://api.vendor.invalid/")

        // No `no_proxy` at all: the bypass has to come from the loopback rule.
        let clients = ProxiedHTTPClients(settings: ProxyPolicy.fromEnvironment([
            "all_proxy": "http://proxy.corp.invalid:8080",
        ]))

        #expect(clients.client(for: byAddress) === HTTPClient.shared)
        #expect(clients.client(for: byName) === HTTPClient.shared)
        #expect(clients.client(for: byIPv6) === HTTPClient.shared)
        // The premise: these settings really do proxy something, so the three
        // expectations above are not passing because nothing is routed at all.
        #expect(clients.client(for: external) !== HTTPClient.shared)

        await clients.shutdown()
    }
}

// MARK: - Teardown

@Suite("ProxiedHTTPClients teardown")
struct ProxiedHTTPClientsShutdownTests {

    /// The assertion that matters is not "shutdown returned" but "the clients it
    /// handed out are actually down" — emptying the table would satisfy a weaker
    /// test while leaving live clients behind to trap in `deinit`.
    /// AsyncHTTPClient answers `alreadyShutdown` for a second teardown, so asking
    /// for one is a direct read of the client's state.
    @Test("Shutdown reaches every client it built, and repeats harmlessly")
    func shutdownReachesEveryClientItBuilt() async throws {
        let insecure = try url("http://api.vendor.invalid/v1/chat/completions")
        let secure = try url("https://api.vendor.invalid/v1/chat/completions")

        let clients = ProxiedHTTPClients(settings: ProxyPolicy.fromEnvironment([
            "http_proxy": "http://proxy-a.corp.invalid:3128",
            "https_proxy": "http://proxy-b.corp.invalid:8080",
        ]))
        let viaA = clients.client(for: insecure)
        let viaB = clients.client(for: secure)

        await clients.shutdown()
        await clients.shutdown()

        await #expect(throws: HTTPClientError.alreadyShutdown) { try await viaA.shutdown() }
        await #expect(throws: HTTPClientError.alreadyShutdown) { try await viaB.shutdown() }
    }

    /// A request arriving after teardown must go direct rather than quietly
    /// building a client that nothing is left to close — the exact shape that
    /// turns a tidy exit into a hang.
    @Test("After shutdown the factory hands back the shared client rather than building another")
    func noClientIsBuiltAfterShutdown() async throws {
        let external = try url("https://api.vendor.invalid/v1/chat/completions")

        let clients = ProxiedHTTPClients(settings: proxyEverythingExceptSettings())
        await clients.shutdown()

        #expect(clients.client(for: external) === HTTPClient.shared)
        // And the answer stays direct, so nothing accumulated on the way out.
        #expect(clients.client(for: external) === HTTPClient.shared)

        await clients.shutdown()
    }
}

// MARK: - Credentials

@Suite("ProxiedHTTPClients credential handling")
struct ProxiedHTTPClientsCredentialTests {

    /// Spelled uniquely to this file so registering it in the process-wide vault
    /// cannot perturb another suite, and long enough to clear the registry's
    /// minimum length.
    private static let proxyPassword = "zqx-domolproxy-secret-40913"
    private static let proxyUser = "zqx-domolproxy-account"

    private static func credentialledSettings() -> ProxySettings {
        ProxyPolicy.fromEnvironment([
            "https_proxy": "http://\(proxyUser):\(proxyPassword)@proxy.corp.invalid:8080",
        ])
    }

    /// A proxy variable is one of the few places a password is routinely typed
    /// into the environment, and the rendered form of this type is the obvious
    /// thing to paste into a bug report.
    @Test("A password in a proxy URL never reaches the rendered description")
    func credentialsNeverRender() async throws {
        let clients = ProxiedHTTPClients(settings: Self.credentialledSettings())
        let rendered = String(describing: clients)

        #expect(rendered.contains("proxy.corp.invalid:8080"), "the host is what makes this useful: \(rendered)")
        #expect(!rendered.contains(Self.proxyPassword))
        #expect(!rendered.contains(Self.proxyUser))

        await clients.shutdown()
    }

    /// The description is under this file's control; a connect failure raised
    /// inside the HTTP stack and quoted into an error by a layer that has no
    /// idea it is holding a credential is not. Registering the password is what
    /// covers those sites, and the text below deliberately carries no URL and no
    /// header marker, so only the literal registry can catch it — a pattern rule
    /// firing would make this pass without proving anything.
    @Test("The proxy password is registered, so an unrecognizable quotation of it is still scrubbed")
    func credentialsAreRegisteredForDiagnostics() async throws {
        let clients = ProxiedHTTPClients(settings: Self.credentialledSettings())

        let quoted = "the proxy refused the credential \(Self.proxyPassword) on CONNECT"
        let scrubbed = Redaction.diagnostic(quoted)

        #expect(!scrubbed.contains(Self.proxyPassword))
        #expect(scrubbed.contains("refused the credential"), "over-redacted the surrounding text: \(scrubbed)")

        await clients.shutdown()
    }

    /// Credentials must not stop the routing decision from being made — a
    /// proxied host still gets an owned client, and a bypassed one still does
    /// not, however the proxy URL is written. The loopback URL is `https:` on
    /// purpose: these settings proxy only `https:`, so an `http:` one would take
    /// the direct path for the wrong reason and prove nothing.
    @Test("Credentials in the proxy URL do not disturb routing")
    func credentialsDoNotDisturbRouting() async throws {
        let external = try url("https://api.vendor.invalid/v1/chat/completions")
        let loopback = try url("https://localhost:4123/mcp")

        let clients = ProxiedHTTPClients(settings: Self.credentialledSettings())

        #expect(clients.client(for: external) !== HTTPClient.shared)
        #expect(clients.client(for: loopback) === HTTPClient.shared)

        await clients.shutdown()
    }
}
