// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one-shot loopback listener an OAuth redirect lands on.
//
// Bound to 127.0.0.1 only, alive for exactly one flow, and torn down the
// moment a valid callback (or the timeout) arrives. The listener registers
// *before* the browser opens — the reverse order is a race the user wins only
// on a slow IdP.
//
// State discipline: a request whose `state` does not match this flow's is
// answered with a 400 page and *ignored* — it does not complete the wait,
// because letting it would hand a CSRF attacker a denial-of-service on the
// login, and letting it complete "successfully" would hand them worse. Only
// the timeout or a state-matched callback ends the flow.
//
// TLS is optional and config-driven: an `https` redirect URI (required by
// registrations that refuse plain-HTTP loopback, ADFS-class) serves the
// generated self-signed certificate; an `http` one — the RFC 8252 norm every
// surveyed client uses — binds plain HTTP.

import DoMoCore
import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import Logging
import NIOCore
import NIOSSL
import SystemPackage

/// What the authorization server sent back through the browser.
public struct OAuthCallbackOutcome: Sendable {
    /// The authorization code, when the server granted one.
    public let code: String?
    /// OAuth error identifier (`access_denied`, …) when it refused.
    public let error: String?
    public let errorDescription: String?
}

/// A parsed redirect URI: where to bind and what path to answer.
public struct OAuthRedirectEndpoint: Sendable, Hashable {
    public let useTLS: Bool
    public let port: Int
    public let path: String
    /// The interface the listener binds — the same loopback family the
    /// redirect names, so an `[::1]` redirect is served on the IPv6 loopback
    /// rather than an IPv4 socket the browser never reaches.
    public let bindHost: String
    /// The redirect URI exactly as configured — what goes in the authorize
    /// request and the token exchange, byte-for-byte.
    public let uri: String

    /// Accepts only loopback redirect URIs: `localhost`, `127.0.0.1`, or
    /// `[::1]`, scheme http or https. Anything else is a config error — this
    /// listener must never bind a routable interface.
    public init(redirectURI: String) throws {
        guard
            let url = URL(string: redirectURI),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else {
            throw MCPOAuthError.configuration(
                "oauth.redirectUri must be an http(s) URL, got '\(redirectURI)'"
            )
        }
        switch host {
        case "localhost", "127.0.0.1":
            self.bindHost = "127.0.0.1"
        case "::1":
            self.bindHost = "::1"
        default:
            throw MCPOAuthError.configuration(
                "oauth.redirectUri must be a loopback address (localhost, 127.0.0.1, or [::1]); "
                    + "'\(host)' would make the login listener reachable from the network"
            )
        }
        self.useTLS = scheme == "https"
        self.port = url.port ?? (useTLS ? 443 : 80)
        self.path = url.path.isEmpty ? "/" : url.path
        self.uri = redirectURI
    }
}

public enum OAuthLoopbackListener {

    /// Runs the listener for one flow: binds, reports readiness (with the
    /// actual port, which matters when 0 was configured — the test seam),
    /// waits for the state-matched callback, answers the browser, shuts down.
    ///
    /// - Returns: the callback's outcome; the *caller* decides whether an
    ///   OAuth error outcome is fatal (it is).
    public static func capture(
        endpoint: OAuthRedirectEndpoint,
        expectedState: String,
        tlsIdentity: LoopbackTLSIdentity?,
        timeout: Duration,
        onListening: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> OAuthCallbackOutcome {
        let (callbacks, callbackContinuation) = AsyncStream.makeStream(of: OAuthCallbackOutcome.self)

        let router = Router(context: BasicRequestContext.self)
        let expectedPath = endpoint.path
        router.get(RouterPath(expectedPath)) { request, _ -> Response in
            let query = request.uri.queryParameters
            guard query["state"].map(String.init) == expectedState else {
                // Wrong or missing state: answer, log nothing sensitive, and
                // keep waiting. See the header — this must not end the flow.
                return Self.page(
                    status: .badRequest,
                    title: "Login rejected",
                    body: "The state parameter did not match this login attempt. "
                        + "If you did not just try to log in, you can close this tab."
                )
            }
            if let error = query["error"] {
                let outcome = OAuthCallbackOutcome(
                    code: nil,
                    error: String(error),
                    errorDescription: query["error_description"].map { String($0) }
                )
                callbackContinuation.yield(outcome)
                // The server-supplied error identifier is attacker-influenced
                // (the authorization server is discovered from the untrusted
                // MCP server's metadata), so it is deliberately NOT echoed into
                // the page — the terminal reports the specifics, redacted. The
                // page stays static to keep this loopback origin free of
                // reflected markup.
                return Self.page(
                    status: .badRequest,
                    title: "Login failed",
                    body: "The authorization server refused the login. "
                        + "You can close this tab; the terminal has the details."
                )
            }
            guard let code = query["code"] else {
                return Self.page(
                    status: .badRequest,
                    title: "Login incomplete",
                    body: "The redirect carried neither a code nor an error. "
                        + "You can close this tab; the terminal will report the failure."
                )
            }
            callbackContinuation.yield(
                OAuthCallbackOutcome(code: String(code), error: nil, errorDescription: nil)
            )
            return Self.page(
                status: .ok,
                title: "Login complete",
                body: "You can close this tab and return to the terminal."
            )
        }

        let server: HTTPServerBuilder
        if endpoint.useTLS {
            guard let tlsIdentity else {
                throw MCPOAuthError.configuration(
                    "an https redirect URI needs a TLS identity for the loopback listener"
                )
            }
            let certificates = try NIOSSLCertificate.fromPEMBytes(
                Array(tlsIdentity.certificatePEM.utf8)
            )
            let key = try NIOSSLPrivateKey(
                bytes: Array(tlsIdentity.privateKeyPEM.utf8),
                format: .pem
            )
            server = try .tls(
                .http1(),
                tlsConfiguration: .makeServerConfiguration(
                    certificateChain: certificates.map { .certificate($0) },
                    privateKey: .privateKey(key)
                )
            )
        } else {
            server = .http1()
        }

        // Hummingbird's default logger prints to stdout, which belongs to the
        // TUI. The listener stays silent; the provider narrates the flow.
        let application = Application(
            router: router,
            server: server,
            configuration: .init(
                address: .hostname(endpoint.bindHost, port: endpoint.port),
                serverName: "domocode-oauth"
            ),
            onServerRunning: { channel in
                await onListening?(channel.localAddress?.port ?? endpoint.port)
            },
            logger: Logger(label: "domocode.mcp.oauth") { _ in SwiftLogNoOpLogHandler() }
        )

        return try await withThrowingTaskGroup(of: OAuthCallbackOutcome.self) { group in
            group.addTask {
                do {
                    // Do NOT let runService install the default SIGINT/SIGTERM
                    // trap: on Darwin swift-service-lifecycle sets those to
                    // SIG_IGN and never restores them, which would strip the
                    // whole `domo` process of its kill-ability for the rest of
                    // the run. Task-group cancellation already tears the server
                    // down, so the trap buys nothing.
                    try await application.runService(gracefulShutdownSignals: [])
                } catch let error as IOError where error.errnoCode == Errno.addressInUse.rawValue {
                    throw MCPOAuthError.portInUse(endpoint.port)
                }
                // A server that stops because the flow was cancelled is a
                // cancellation, not a malfunction; only an unexpected early
                // stop is a flow failure.
                try Task.checkCancellation()
                throw MCPOAuthError.flowFailed("the login callback listener stopped early")
            }
            group.addTask {
                var iterator = callbacks.makeAsyncIterator()
                guard let outcome = await iterator.next() else {
                    try Task.checkCancellation()
                    throw MCPOAuthError.flowFailed("the login callback stream closed early")
                }
                return outcome
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPOAuthError.timedOut(
                    "no login callback arrived within \(Int(timeout.components.seconds))s"
                )
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else {
                throw MCPOAuthError.flowFailed("the login flow ended without an outcome")
            }
            // The outcome is secured (the timeout can no longer win — we do not
            // consult the group again), so the server is still bound for one
            // last moment: give the success/error response time to flush to the
            // browser before the deferred cancelAll tears the connection down.
            // A callback that arrives in the final 250ms before the deadline is
            // therefore never discarded, and cancellation during the grace is
            // swallowed rather than losing the code.
            try? await Task.sleep(for: .milliseconds(250))
            return outcome
        }
    }

    /// A small, self-contained page; no external assets, readable in both
    /// color schemes.
    private static func page(status: HTTPResponse.Status, title: String, body: String) -> Response {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title><style>
        body { font-family: -apple-system, system-ui, sans-serif; display: grid; place-items: center;
               min-height: 90vh; background: #f6f6f4; color: #1a1a18; }
        @media (prefers-color-scheme: dark) { body { background: #1e1e1c; color: #e8e8e4; } }
        main { text-align: center; max-width: 28rem; }
        </style></head><body><main><h2>\(title)</h2><p>\(body)</p></main></body></html>
        """
        return Response(
            status: status,
            headers: [.contentType: "text/html; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: html))
        )
    }
}
