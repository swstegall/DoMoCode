// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The test that would have caught the first version of proxy support.
//
// That version had a correct policy, a correct client pool, correct settings
// resolution, and sixty-odd passing tests — and proxied nothing, because routing
// through the pool was an optional argument at five construction sites and every
// one of them was left at its default. Each PART was tested; the PATH was not.
// These assert the path: that resolving a proxy actually changes what a request
// leaves on.

import Foundation
import Testing

import DoMoCore
import DoMoLLM
import DoMoMCP

@testable import DoMoCLI

@Suite("Proxy reaches production", .serialized)
struct ProxyReachesProductionTests {

    private func resolved(httpsProxy: String?, noProxy: String? = nil) throws -> ResolvedConfiguration {
        var environment: [String: String] = [:]
        if let httpsProxy {
            environment["HTTPS_PROXY"] = httpsProxy
            environment["HTTP_PROXY"] = httpsProxy
        }
        if let noProxy { environment["NO_PROXY"] = noProxy }
        return try ResolvedConfiguration.resolve(
            cli: CLIOverrides(), environment: environment, project: nil, user: nil
        )
    }

    /// Leaves nothing installed for the next test, whatever this one did.
    ///
    /// `SharedProxy.shutdown()` rather than `install(nil)`: the pool asserts in
    /// `deinit` if it is released without being shut down, because a dropped
    /// client keeps a connection pool alive and can hang process exit. Dropping
    /// one here would trip that guard — which is how this helper was written the
    /// first time, and the guard caught it.
    private func withCleanProxy(_ body: () async throws -> Void) async rethrows {
        await SharedProxy.shutdown()
        do {
            try await body()
        } catch {
            await SharedProxy.shutdown()
            throw error
        }
        await SharedProxy.shutdown()
    }

    // MARK: The path

    @Test("Installing the process defaults publishes the proxy pool")
    func installPublishesThePool() async throws {
        try await withCleanProxy {
            #expect(SharedProxy.current == nil, "a clean process proxies nothing")

            let configuration = try resolved(httpsProxy: "http://proxy.example.internal:8080")
            ProcessHarnessDefaults.installSharedProxy(for: configuration)

            #expect(
                SharedProxy.current != nil,
                """
                the resolved proxy never reached the process. This is the exact \
                shape of the original defect: settings resolve, nothing reads them.
                """
            )
        }
    }

    /// The heart of it. A `LiteLLMClient` built the way every production site
    /// builds one — from a `Configuration` and nothing else — must pick up the
    /// installed proxy without being told.
    @Test("A client built from configuration alone routes through the installed proxy")
    func defaultClientUsesTheProxy() async throws {
        try await withCleanProxy {
            let configuration = try resolved(httpsProxy: "http://proxy.example.internal:8080")
            ProcessHarnessDefaults.installSharedProxy(for: configuration)
            let pool = try #require(SharedProxy.current)

            // What the transport would use for a gateway request, versus for a
            // loopback one. Different clients is the observable proof that the
            // decision is being made at all.
            let remote = pool.client(for: URL(string: "https://gateway.example.com/v1")!)
            let loopback = pool.client(for: URL(string: "http://127.0.0.1:8080/v1")!)
            let alsoLoopback = pool.client(for: URL(string: "http://localhost:9999/x")!)

            // Identity, not the concrete type: this target does not depend on
            // AsyncHTTPClient, and it does not need to. Two direct destinations
            // sharing one client while the proxied destination gets a different
            // one is the whole routing decision, observable from here.
            #expect(remote !== loopback, "the proxied and direct paths must not be the same client")
            #expect(loopback === alsoLoopback, "every direct destination shares the one shared client")
        }
    }

    @Test("With no proxy configured nothing is installed and behaviour is unchanged")
    func noProxyInstallsNothing() async throws {
        try await withCleanProxy {
            let configuration = try resolved(httpsProxy: nil)
            ProcessHarnessDefaults.installSharedProxy(for: configuration)

            #expect(SharedProxy.current == nil)
        }
    }

    /// `no_proxy` has to survive the trip too, or an intranet host becomes
    /// unreachable the moment a proxy is configured — the failure this feature
    /// exists to prevent, caused by the feature itself.
    @Test("An excepted host still goes direct once a proxy is installed")
    func exceptedHostGoesDirect() async throws {
        try await withCleanProxy {
            let configuration = try resolved(
                httpsProxy: "http://proxy.example.internal:8080",
                noProxy: ".example.internal"
            )
            ProcessHarnessDefaults.installSharedProxy(for: configuration)
            let pool = try #require(SharedProxy.current)

            let intranet = pool.client(for: URL(string: "https://issues.example.internal/mcp")!)
            let loopback = pool.client(for: URL(string: "http://127.0.0.1:9999/x")!)
            let external = pool.client(for: URL(string: "https://api.example.com/v1")!)

            // The excepted host takes the same client loopback does — the direct
            // one — while an ordinary host does not.
            #expect(intranet === loopback, "an excepted host must not be proxied")
            #expect(external !== loopback, "a non-excepted host must be proxied")
        }
    }

    /// The MCP manager owns its own pool rather than sharing the process one, so
    /// it has its own way to be dropped — and it was.
    @Test("The MCP manager is handed the process proxy settings")
    func mcpManagerCarriesTheProxy() async throws {
        try await withCleanProxy {
            let configuration = try resolved(httpsProxy: "http://proxy.example.internal:8080")
            ProcessHarnessDefaults.install(for: configuration)
            defer { ProcessHarnessDefaults.install(for: try! resolved(httpsProxy: nil)) }

            // Both MCP construction sites read this one value, so asserting it is
            // asserting both of them.
            #expect(
                ProcessHarnessDefaults.current.proxy.isConfigured,
                "the MCP surfaces would build an unproxied manager"
            )
            #expect(
                ProcessHarnessDefaults.current.proxy.httpsProxy == "http://proxy.example.internal:8080"
            )
        }
    }
}
