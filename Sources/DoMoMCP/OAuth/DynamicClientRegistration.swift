// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// RFC 7591 dynamic client registration: how a spec-compliant MCP client gets
// a client id without a human filing a ticket. Registered as a public client
// (`token_endpoint_auth_method: "none"`) asking for exactly the two grants
// the flow uses. Enterprise IdPs that lack a registration endpoint (ADFS)
// never reach this file — they fail earlier with a typed
// `clientRegistrationRequired`, whose remedy is a configured `clientId`.

import Foundation

enum DynamicClientRegistration {

    private struct Request: Encodable {
        var redirectUris: [String]
        var tokenEndpointAuthMethod = "none"
        var grantTypes = ["authorization_code", "refresh_token"]
        var responseTypes = ["code"]
        var clientName = "DoMoCode"
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case redirectUris = "redirect_uris"
            case tokenEndpointAuthMethod = "token_endpoint_auth_method"
            case grantTypes = "grant_types"
            case responseTypes = "response_types"
            case clientName = "client_name"
            case scope
        }
    }

    private struct Response: Decodable {
        var clientId: String
        var clientSecret: String?
        /// Unix seconds; RFC 7591 spells "never" as 0.
        var clientSecretExpiresAt: Double?

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case clientSecret = "client_secret"
            case clientSecretExpiresAt = "client_secret_expires_at"
        }
    }

    static func register(
        endpoint: URL,
        redirectURI: String,
        scope: String?,
        transport: OAuthHTTPTransport
    ) async throws -> OAuthClientRegistration {
        let request = Request(redirectUris: [redirectURI], scope: scope)
        let body = try JSONEncoder().encode(request)
        let (status, data) = try await transport.postJSON(endpoint, body: body)
        guard status == 200 || status == 201 else {
            throw MCPOAuthError.clientRegistrationRequired(
                "the authorization server refused dynamic registration (HTTP \(status)); "
                    + "register a client manually and set oauth.clientId"
            )
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MCPOAuthError.flowFailed("the registration response was not valid JSON")
        }
        return OAuthClientRegistration(
            clientId: response.clientId,
            clientSecret: response.clientSecret,
            clientSecretExpiresAt: (response.clientSecretExpiresAt).flatMap { $0 == 0 ? nil : $0 }
        )
    }
}
