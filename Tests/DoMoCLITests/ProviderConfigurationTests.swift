// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import DoMoCore
import Foundation
import Testing

@Suite("Provider configuration")
struct ProviderConfigurationTests {
    @Test("legacy LiteLLM settings synthesize a safe default profile and route")
    func legacyDefaultProfile() throws {
        let config = try ResolvedConfiguration.resolve(
            cli: CLIOverrides(),
            environment: [EnvName.baseURL: "http://gateway.test/v1", EnvName.model: "model"],
            project: nil,
            user: nil
        )
        let profile = try #require(config.providerProfiles["default"])
        #expect(profile.adapterID == "litellm")
        #expect(profile.endpoint == "http://gateway.test/v1")
        #expect(profile.defaultModel == "model")
        #expect(config.providerRoutes["default"]?.profileIDs == ["default"])
    }

    @Test("project profile metadata overrides a user profile without exposing values")
    func profileLayering() throws {
        let userProfile = ProviderProfile(
            id: "primary",
            displayName: "User gateway",
            adapterID: "litellm",
            endpoint: "http://user.test/v1",
            credential: ProviderCredentialReference(name: "USER_KEY")
        )
        let projectProfile = ProviderProfile(
            id: "primary",
            displayName: "Project gateway",
            adapterID: "anthropic-messages",
            endpoint: "https://project.test/v1",
            credential: ProviderCredentialReference(name: "PROJECT_KEY")
        )
        let config = try ResolvedConfiguration.resolve(
            cli: CLIOverrides(),
            environment: [:],
            project: Settings(providerProfiles: ["primary": projectProfile]),
            user: Settings(providerProfiles: ["primary": userProfile])
        )
        #expect(config.providerProfiles["primary"] == projectProfile)
        let encoded = try JSONEncoder().encode(config.providerProfiles["primary"])
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("PROJECT_KEY"))
        #expect(!text.contains("secret-value"))
    }
}
