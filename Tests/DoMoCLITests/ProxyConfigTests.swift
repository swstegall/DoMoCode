// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The configuration half of proxy support: that a machine with nothing
// configured behaves exactly as it did before the feature existed, that the
// ladder runs `DOMOCODE_*` variable → conventional `*_proxy` variable → user
// settings.json, that a project settings.json can switch proxying off and can
// do nothing else, and that a value nobody can dial is reported rather than
// thrown on or silently dropped.

import DoMoCLI
import DoMoCore
import Foundation
import Testing

@Suite("Proxy configuration")
struct ProxyConfigTests {

    private func resolve(
        env: [String: String] = [:],
        project: Settings? = nil,
        user: Settings? = nil
    ) throws -> ResolvedConfiguration {
        try ResolvedConfiguration.resolve(
            cli: CLIOverrides(), environment: env, project: project, user: user)
    }

    /// A value with no host, which no spelling of a proxy can be dialed from —
    /// kept in one place so a disagreement with
    /// ``DoMoCore/ProxyPolicy/endpoint(from:)`` is one edit rather than six.
    private let unusable = "http://"

    private let proxyURL = "http://proxy.example.com:8080"
    private let otherProxyURL = "http://other.example.com:3128"

    // MARK: Nothing configured

    /// The feature must be invisible to everyone who does not need it. A run
    /// with no variables and no settings file has to resolve to "go direct",
    /// which is byte-for-byte what this tool did before proxying existed.
    @Test("An absent configuration proxies nothing and says nothing")
    func absentConfigurationProxiesNothing() throws {
        let config = try resolve()

        #expect(!config.proxy.isConfigured)
        #expect(config.proxy.httpProxy == nil)
        #expect(config.proxy.httpsProxy == nil)
        #expect(config.proxy.noProxy == nil)
        #expect(config.proxy.enabled, "silence is not the same statement as \"off\"")
        #expect(config.warnings.isEmpty)
    }

    /// Every other setting in the file is unrelated to the proxy, so a settings
    /// file that says nothing about it must not acquire one by being present.
    @Test("A settings file that mentions no proxy leaves the proxy alone")
    func unrelatedSettingsDoNotConfigureAProxy() throws {
        let config = try resolve(
            project: Settings(model: "project-model"),
            user: Settings(baseURL: "http://gateway.example.com:4000/v1", model: "user-model")
        )
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.isEmpty)
    }

    // MARK: The ladder

    /// The conventional spellings are what an intranet workstation already has
    /// exported, so honoring them is the whole point of reading the environment
    /// at all.
    @Test("The conventional variables are honored with no settings file")
    func conventionalVariablesAreHonored() throws {
        let config = try resolve(env: [
            "https_proxy": proxyURL,
            "http_proxy": otherProxyURL,
            "no_proxy": ".intranet.example,10.0.0.0/8",
        ])
        #expect(config.proxy.httpsProxy == proxyURL)
        #expect(config.proxy.httpProxy == otherProxyURL)
        #expect(config.proxy.noProxy == ".intranet.example,10.0.0.0/8")
        #expect(config.proxy.isConfigured)
        #expect(config.warnings.isEmpty)
    }

    @Test("The DOMOCODE variables beat the conventional ones, field by field")
    func domocodeVariablesBeatTheConventionalOnes() throws {
        let config = try resolve(env: [
            "https_proxy": otherProxyURL,
            "http_proxy": otherProxyURL,
            "no_proxy": "conventional.example",
            EnvName.httpsProxy: proxyURL,
            EnvName.noProxy: ".intranet.example",
        ])
        #expect(config.proxy.httpsProxy == proxyURL)
        #expect(config.proxy.noProxy == ".intranet.example")
        // Untouched by the DOMOCODE layer, so the conventional value still
        // stands: these are independent fields, not one all-or-nothing source.
        #expect(config.proxy.httpProxy == otherProxyURL)
        #expect(config.warnings.isEmpty)
    }

    @Test("The user settings file is the last layer before no proxy at all")
    func userSettingsAreTheLastLayer() throws {
        let config = try resolve(
            user: Settings(
                proxy: ProxyOverrides(
                    httpProxy: proxyURL,
                    httpsProxy: proxyURL,
                    noProxy: ".intranet.example"
                )
            )
        )
        #expect(config.proxy.httpProxy == proxyURL)
        #expect(config.proxy.httpsProxy == proxyURL)
        #expect(config.proxy.noProxy == ".intranet.example")
        #expect(config.warnings.isEmpty)
    }

    /// A variable exported in the user's own shell is the most deliberate
    /// statement available, so it outranks the file they wrote once.
    @Test("Both environment layers beat the user settings file")
    func environmentBeatsUserSettings() throws {
        let user = Settings(
            proxy: ProxyOverrides(
                httpProxy: otherProxyURL,
                httpsProxy: otherProxyURL,
                noProxy: "file.example"
            )
        )

        let conventional = try resolve(
            env: ["https_proxy": proxyURL, "no_proxy": "env.example"], user: user)
        #expect(conventional.proxy.httpsProxy == proxyURL)
        #expect(conventional.proxy.noProxy == "env.example")
        #expect(conventional.proxy.httpProxy == otherProxyURL, "the file still answers for http:")

        let domocode = try resolve(env: [EnvName.httpsProxy: proxyURL], user: user)
        #expect(domocode.proxy.httpsProxy == proxyURL)
        #expect(domocode.warnings.isEmpty)
    }

    // MARK: A project settings file may only tighten

    /// This is the security rule the feature turns on. A settings file arrives
    /// with whatever was cloned; one that could name the host every request is
    /// routed through would be reading the prompts, the file contents and the
    /// `Authorization` header of the whole session.
    @Test("Every proxy key a project states is ignored and named")
    func projectProxyKeysAreIgnoredAndNamed() throws {
        let config = try resolve(
            project: Settings(
                proxy: ProxyOverrides(
                    enabled: true,
                    httpProxy: otherProxyURL,
                    httpsProxy: otherProxyURL,
                    noProxy: "project.example"
                )
            ),
            user: Settings(
                proxy: ProxyOverrides(httpsProxy: proxyURL, noProxy: "user.example"))
        )

        #expect(config.proxy.httpsProxy == proxyURL, "the user's file is the one that answers")
        #expect(config.proxy.httpProxy == nil, "a project may not introduce one")
        #expect(config.proxy.noProxy == "user.example")

        #expect(config.warnings.count == 4)
        for key in ["proxy.enabled", "proxy.httpProxy", "proxy.httpsProxy", "proxy.noProxy"] {
            let named = config.warnings.filter { $0.contains("\"\(key)\"") }
            #expect(named.count == 1, "exactly one warning must name \(key)")
            #expect(named.first?.contains("project settings.json") == true)
        }
    }

    /// Tightening is the one direction a repository is trusted in: switching
    /// proxying off cannot redirect anything to a host of its choosing.
    @Test("A project may switch proxying off, and that is not a complaint")
    func projectMayDisable() throws {
        let config = try resolve(
            env: ["https_proxy": proxyURL],
            project: Settings(proxy: ProxyOverrides(enabled: false)),
            user: Settings(proxy: ProxyOverrides(httpProxy: proxyURL))
        )
        #expect(!config.proxy.enabled)
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.isEmpty, "a project doing the one thing it may do says nothing")
    }

    /// Re-enabling a proxy the user switched off restores a route they
    /// deliberately removed, which is the widening direction spelled differently.
    @Test("A project may not switch proxying back on")
    func projectMayNotReEnable() throws {
        let config = try resolve(
            env: ["https_proxy": proxyURL],
            project: Settings(proxy: ProxyOverrides(enabled: true)),
            user: Settings(proxy: ProxyOverrides(enabled: false))
        )
        #expect(!config.proxy.enabled)
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.count == 1)
        #expect(config.warnings.first?.contains("\"proxy.enabled\"") == true)
    }

    /// The tightening sits below the variable, not beneath everything: a user
    /// who exports this has said something about this run that a cloned file
    /// does not get to answer.
    @Test("DOMOCODE_PROXY_ENABLED outranks a project's switch-off")
    func domocodeEnabledOutranksAProjectDisable() throws {
        let config = try resolve(
            env: [EnvName.proxyEnabled: "1", "https_proxy": proxyURL],
            project: Settings(proxy: ProxyOverrides(enabled: false))
        )
        #expect(config.proxy.enabled)
        #expect(config.proxy.httpsProxy == proxyURL)
        #expect(config.warnings.isEmpty)
    }

    // MARK: Switching it off

    /// Nothing downstream should have to ask two questions to learn that a
    /// request goes direct, so a disabled proxy carries no URL to reach for.
    @Test("Switching proxying off drops the URLs rather than parking them")
    func disablingDropsTheURLs() throws {
        let config = try resolve(
            env: [EnvName.proxyEnabled: "0", "https_proxy": proxyURL, "no_proxy": "x.example"],
            user: Settings(proxy: ProxyOverrides(httpProxy: proxyURL))
        )
        #expect(!config.proxy.enabled)
        #expect(!config.proxy.isConfigured)
        #expect(config.proxy.httpProxy == nil)
        #expect(config.proxy.httpsProxy == nil)
        #expect(config.proxy.noProxy == nil)
    }

    @Test("The user settings file can switch proxying off on its own")
    func userSettingsCanDisable() throws {
        let config = try resolve(
            env: ["https_proxy": proxyURL],
            user: Settings(proxy: ProxyOverrides(enabled: false))
        )
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.isEmpty)
    }

    @Test(
        "The switch accepts every spelling of false this codebase already accepts",
        arguments: ["false", "False", "no", "off", "0"]
    )
    func falseSpellings(word: String) throws {
        let config = try resolve(env: [EnvName.proxyEnabled: word, "https_proxy": proxyURL])
        #expect(!config.proxy.isConfigured, "\(word) should read as false")
        #expect(config.warnings.isEmpty)
    }

    // MARK: Bad values warn instead of throwing

    /// Nobody has to set a proxy variable, so nobody may lose a session to a
    /// typo in one. The house pattern is `logLevel`'s: name the thing that has
    /// to be edited, then let the next layer answer.
    @Test("An unusable proxy URL warns and falls through to the layer below")
    func unusableURLWarnsAndFallsThrough() throws {
        let config = try resolve(
            env: [EnvName.httpsProxy: unusable],
            user: Settings(proxy: ProxyOverrides(httpsProxy: proxyURL))
        )
        #expect(config.proxy.httpsProxy == proxyURL)
        #expect(config.warnings.count == 1)
        let warning = config.warnings.first ?? ""
        #expect(warning.contains(EnvName.httpsProxy))
        #expect(warning.contains("not a usable proxy URL"))
    }

    @Test("An unusable conventional variable is named by its own spelling")
    func unusableConventionalVariableIsNamed() throws {
        let config = try resolve(env: ["https_proxy": unusable])
        #expect(config.proxy.httpsProxy == nil)
        #expect(config.warnings.count == 1)
        #expect(config.warnings.first?.contains("https_proxy") == true)
    }

    @Test("An unusable value in the user settings file names the key and the file")
    func unusableUserSettingValueIsNamed() throws {
        let config = try resolve(user: Settings(proxy: ProxyOverrides(httpProxy: unusable)))
        #expect(config.proxy.httpProxy == nil)
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.count == 1)
        let warning = config.warnings.first ?? ""
        #expect(warning.contains("\"proxy.httpProxy\""))
        #expect(warning.contains("user settings.json"))
    }

    /// `all_proxy` answers for both schemes, so one bad value there must not be
    /// reported once per scheme under a single name.
    @Test("One malformed all_proxy is one complaint, not two")
    func malformedAllProxyIsReportedOnce() throws {
        let config = try resolve(env: ["all_proxy": unusable])
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.count == 1)
        #expect(config.warnings.first?.contains("all_proxy") == true)
    }

    @Test("A non-boolean switch warns and leaves the layer below standing")
    func nonBooleanSwitchWarns() throws {
        let config = try resolve(
            env: [EnvName.proxyEnabled: "maybe", "https_proxy": proxyURL],
            user: Settings(proxy: ProxyOverrides(enabled: false))
        )
        #expect(!config.proxy.enabled, "the user's file still answers")
        #expect(config.warnings.count == 1)
        let warning = config.warnings.first ?? ""
        #expect(warning.contains(EnvName.proxyEnabled))
        #expect(warning.contains("true/false"))
    }

    /// An empty variable is how a shell spells one it exports and never sets;
    /// the convention reads it as absent, and so must this.
    @Test("Empty variables state nothing and warn about nothing")
    func emptyVariablesStateNothing() throws {
        let config = try resolve(env: [
            EnvName.httpProxy: "",
            EnvName.httpsProxy: "   ",
            EnvName.noProxy: "",
            EnvName.proxyEnabled: "",
        ])
        #expect(!config.proxy.isConfigured)
        #expect(config.proxy.enabled)
        #expect(config.warnings.isEmpty)
    }

    /// A proxy URL is one of the few settings that routinely carries a
    /// credential. A warning is a line that reaches stderr and a log file, so
    /// none of them may quote the value that was rejected or ignored.
    @Test("No warning echoes a proxy credential")
    func warningsNeverEchoAProxyCredential() throws {
        let secretive = "http://operator:hunter2@proxy.example.com:8080"
        let config = try resolve(
            project: Settings(proxy: ProxyOverrides(httpProxy: secretive, httpsProxy: unusable)),
            user: Settings(proxy: ProxyOverrides(httpProxy: secretive))
        )
        #expect(!config.warnings.isEmpty, "the project's keys must have been reported")
        for warning in config.warnings {
            #expect(!warning.contains("hunter2"), "a password reached a warning: \(warning)")
            #expect(!warning.contains("operator"))
        }
    }

    // MARK: What the resolved value means downstream

    /// This program's default mode is a terminal client talking to a server it
    /// spawned on loopback. Routing that through a proxy breaks the whole
    /// program, and no proxy could reach it in any case.
    @Test("A loopback URL is direct even with a proxy configured and no bypass list")
    func loopbackIsNeverProxied() throws {
        let config = try resolve(env: [
            "http_proxy": proxyURL,
            "https_proxy": proxyURL,
        ])
        #expect(config.proxy.isConfigured)

        for address in [
            "http://localhost:4000/v1",
            "http://127.0.0.1:4000/v1",
            "http://[::1]:4000/v1",
        ] {
            let url = try #require(URL(string: address))
            #expect(
                ProxyPolicy.endpoint(for: url, settings: config.proxy) == nil,
                "\(address) must be reached directly")
        }

        let intranet = try #require(URL(string: "http://build.intranet.example/api"))
        #expect(ProxyPolicy.endpoint(for: intranet, settings: config.proxy) != nil)
    }

    /// The bypass list has to survive resolution intact, because it is the only
    /// thing that keeps a network-gated endpoint reachable once a proxy exists.
    @Test("The bypass list reaches the resolved settings and is honored")
    func bypassListSurvivesResolution() throws {
        let config = try resolve(env: [
            "https_proxy": proxyURL,
            "no_proxy": ".intranet.example",
        ])
        let bypassed = try #require(URL(string: "https://mcp.intranet.example/rpc"))
        let proxied = try #require(URL(string: "https://api.example.com/v1"))
        #expect(ProxyPolicy.endpoint(for: bypassed, settings: config.proxy) == nil)
        #expect(ProxyPolicy.endpoint(for: proxied, settings: config.proxy) != nil)
    }

    // MARK: The settings file's wire shape

    /// `Settings.CodingKeys` is written out by hand, so a property added without
    /// its case decodes as `nil` forever and says nothing. This is that guard.
    @Test("The proxy block decodes from settings.json under its documented keys")
    func proxyBlockDecodes() throws {
        let json = """
            {
              "proxy": {
                "enabled": true,
                "httpProxy": "http://proxy.example.com:8080",
                "httpsProxy": "http://proxy.example.com:8443",
                "noProxy": ".intranet.example, 10.0.0.0/8"
              }
            }
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.proxy?.enabled == true)
        #expect(settings.proxy?.httpProxy == "http://proxy.example.com:8080")
        #expect(settings.proxy?.httpsProxy == "http://proxy.example.com:8443")
        #expect(settings.proxy?.noProxy == ".intranet.example, 10.0.0.0/8")

        let roundTripped = try JSONDecoder().decode(
            Settings.self, from: JSONEncoder().encode(settings))
        #expect(roundTripped == settings)

        // And the decoded file must actually reach the resolved value.
        let config = try resolve(user: settings)
        #expect(config.proxy.httpProxy == "http://proxy.example.com:8080")
        #expect(config.proxy.httpsProxy == "http://proxy.example.com:8443")
        #expect(config.proxy.noProxy == ".intranet.example, 10.0.0.0/8")
    }

    /// An omitted block is `nil`, not an empty one: that is what lets the
    /// resolver tell "said nothing" from "said false".
    @Test("An omitted proxy block decodes as nil and changes nothing")
    func omittedProxyBlockIsNil() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"model":"m"}"#.utf8))
        #expect(settings.proxy == nil)

        let config = try resolve(user: settings)
        #expect(!config.proxy.isConfigured)
        #expect(config.warnings.isEmpty)
    }

    /// The names are a documented, permanent surface; a typo here is a knob
    /// nobody can reach and a README that lies.
    @Test("The environment variable names are spelled as the contract states")
    func environmentNames() {
        #expect(EnvName.httpProxy == "DOMOCODE_HTTP_PROXY")
        #expect(EnvName.httpsProxy == "DOMOCODE_HTTPS_PROXY")
        #expect(EnvName.noProxy == "DOMOCODE_NO_PROXY")
        #expect(EnvName.proxyEnabled == "DOMOCODE_PROXY_ENABLED")
    }
}
