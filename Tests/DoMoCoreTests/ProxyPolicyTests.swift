// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

import DoMoCore

// The rules exercised here are the `no_proxy` convention shared by curl and the
// wider ecosystem, not a private dialect. Each numbered rule in
// `ProxyPolicy.bypasses(host:port:noProxy:)` has its own test below, because the
// failure mode of getting one of them slightly wrong is silent: traffic reaches
// its destination either way, just through a server nobody chose.

// MARK: - Proxy URLs

@Suite("Proxy policy: parsing a proxy URL")
struct ProxyEndpointParsingTests {

    @Test("A full URL parses into host, port and scheme")
    func fullURL() {
        let endpoint = ProxyPolicy.endpoint(from: "http://proxy.example.com:8080")
        #expect(endpoint?.host == "proxy.example.com")
        #expect(endpoint?.port == 8080)
        #expect(endpoint?.isSOCKS == false)
        #expect(endpoint?.username == nil)
        #expect(endpoint?.password == nil)
    }

    @Test("Each scheme supplies its own default port")
    func defaultPorts() {
        #expect(ProxyPolicy.endpoint(from: "http://proxy.example.com")?.port == 80)
        #expect(ProxyPolicy.endpoint(from: "https://proxy.example.com")?.port == 443)
        #expect(ProxyPolicy.endpoint(from: "socks5://proxy.example.com")?.port == 1080)
        #expect(ProxyPolicy.endpoint(from: "socks://proxy.example.com")?.port == 1080)
    }

    @Test("A SOCKS scheme is reported as such")
    func socksScheme() {
        #expect(ProxyPolicy.endpoint(from: "socks5://proxy.example.com:1080")?.isSOCKS == true)
        #expect(ProxyPolicy.endpoint(from: "socks4a://proxy.example.com")?.isSOCKS == true)
        #expect(ProxyPolicy.endpoint(from: "http://proxy.example.com:8080")?.isSOCKS == false)
    }

    @Test("A bare host and port parses, which is how these variables are often set")
    func bareHostPort() {
        let endpoint = ProxyPolicy.endpoint(from: "proxy.example.com:3128")
        #expect(endpoint?.host == "proxy.example.com")
        #expect(endpoint?.port == 3128)
        #expect(endpoint?.isSOCKS == false)
    }

    @Test("A bare host with no port is read as HTTP on port 80")
    func bareHost() {
        let endpoint = ProxyPolicy.endpoint(from: "proxy.example.com")
        #expect(endpoint?.host == "proxy.example.com")
        #expect(endpoint?.port == 80)
    }

    @Test("The scheme and host are lowercased so later comparisons agree")
    func caseIsNormalized() {
        let endpoint = ProxyPolicy.endpoint(from: "HTTP://Proxy.Example.COM:8080")
        #expect(endpoint?.host == "proxy.example.com")
        #expect(endpoint?.port == 8080)
    }

    @Test("A trailing path or slash is ignored rather than rejected")
    func pathIsIgnored() {
        #expect(ProxyPolicy.endpoint(from: "http://proxy.example.com:8080/")?.port == 8080)
        #expect(
            ProxyPolicy.endpoint(from: "http://proxy.example.com:8080/pac?x=1")?.host
                == "proxy.example.com"
        )
    }

    @Test("Credentials in a proxy URL are parsed and kept")
    func credentialsAreKept() {
        let endpoint = ProxyPolicy.endpoint(from: "http://alice:s3cret@proxy.example.com:8080")
        #expect(endpoint?.host == "proxy.example.com")
        #expect(endpoint?.port == 8080)
        #expect(endpoint?.username == "alice")
        #expect(endpoint?.password == "s3cret")
    }

    @Test("A percent-encoded credential is decoded")
    func percentEncodedCredentials() {
        let endpoint = ProxyPolicy.endpoint(from: "http://dom%5Calice:p%40ss@proxy.example.com:8080")
        #expect(endpoint?.username == "dom\\alice")
        #expect(endpoint?.password == "p@ss")
        // The host survives an unencoded-looking `@` in the password because the
        // split is on the last one.
        #expect(endpoint?.host == "proxy.example.com")
    }

    @Test("A username with no password parses")
    func usernameOnly() {
        let endpoint = ProxyPolicy.endpoint(from: "http://alice@proxy.example.com:8080")
        #expect(endpoint?.username == "alice")
        #expect(endpoint?.password == nil)
    }

    @Test("An IPv6 proxy literal parses out of its brackets")
    func ipv6ProxyHost() {
        let endpoint = ProxyPolicy.endpoint(from: "http://[fd00::1]:8080")
        #expect(endpoint?.host == "fd00::1")
        #expect(endpoint?.port == 8080)
        #expect(ProxyPolicy.endpoint(from: "http://[fd00::1]")?.port == 80)
    }

    @Test("A malformed proxy setting yields nil rather than trapping")
    func malformedYieldsNil() {
        let unusable = [
            "",
            "   ",
            "http://",
            "://8080",
            "http://proxy.example.com:0",
            "http://proxy.example.com:99999",
            "http://proxy.example.com:http",
            "ftp://proxy.example.com:21",
            "not a proxy at all",
            "http://[fd00::1",
            "http://[not:an:address]:8080",
        ]
        for raw in unusable {
            #expect(ProxyPolicy.endpoint(from: raw) == nil, "expected nil for \(raw)")
        }
    }

    @Test("An endpoint never renders its credentials")
    func credentialsNeverRender() {
        guard let endpoint = ProxyPolicy.endpoint(from: "http://alice:s3cretpassword@proxy.example.com:8080")
        else {
            Issue.record("the proxy URL should have parsed")
            return
        }
        let rendered = "\(endpoint) \(String(describing: endpoint)) \(String(reflecting: endpoint))"
        #expect(!rendered.contains("s3cretpassword"))
        #expect(!rendered.contains("alice"))
        #expect(rendered.contains("proxy.example.com:8080"))
    }
}

// MARK: - no_proxy

@Suite("Proxy policy: the no_proxy convention")
struct ProxyBypassTests {

    // Rule 1

    @Test("Entries split on commas and whitespace, and match case-insensitively")
    func separatorsAndCase() {
        let list = "FOO.example,, \t bar.example\nBaz.example"
        #expect(ProxyPolicy.bypasses(host: "foo.EXAMPLE", port: 443, noProxy: list))
        #expect(ProxyPolicy.bypasses(host: "bar.example", port: 443, noProxy: list))
        #expect(ProxyPolicy.bypasses(host: "BAZ.example", port: 443, noProxy: list))
        #expect(!ProxyPolicy.bypasses(host: "other.example", port: 443, noProxy: list))
    }

    // Rule 2

    @Test("A single asterisk bypasses everything")
    func asteriskBypassesEverything() {
        #expect(ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: "*"))
        #expect(ProxyPolicy.bypasses(host: "10.9.8.7", port: 80, noProxy: "example.com, *"))
    }

    @Test("An asterisk still bypasses when a proxy is explicitly configured")
    func asteriskBeatsAConfiguredProxy() {
        let settings = ProxySettings(
            httpProxy: "http://proxy.example.com:8080",
            httpsProxy: "http://proxy.example.com:8080",
            noProxy: "*"
        )
        #expect(settings.isConfigured)
        #expect(url("https://api.example.com/v1", settings) == nil)
    }

    // Rule 3

    @Test("A leading dot matches the domain itself and any subdomain")
    func leadingDotMatchesApexAndSubdomains() {
        let list = ".example.com"
        #expect(ProxyPolicy.bypasses(host: "example.com", port: 443, noProxy: list))
        #expect(ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: list))
        #expect(ProxyPolicy.bypasses(host: "a.b.example.com", port: 443, noProxy: list))
    }

    @Test("A bare domain matches the same set as one with a leading dot")
    func bareDomainMatchesSubdomains() {
        let list = "example.com"
        #expect(ProxyPolicy.bypasses(host: "example.com", port: 443, noProxy: list))
        #expect(ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: list))
    }

    @Test("Suffix matching happens on a label boundary, so notexample.com does not match")
    func suffixMatchingRespectsLabelBoundary() {
        #expect(!ProxyPolicy.bypasses(host: "notexample.com", port: 443, noProxy: "example.com"))
        #expect(!ProxyPolicy.bypasses(host: "notexample.com", port: 443, noProxy: ".example.com"))
        // And the match has to be a suffix, not merely present.
        #expect(
            !ProxyPolicy.bypasses(host: "example.com.other.test", port: 443, noProxy: "example.com")
        )
    }

    @Test("A fully-qualified trailing dot still matches")
    func trailingDotIsNormalized() {
        #expect(ProxyPolicy.bypasses(host: "api.example.com.", port: 443, noProxy: "example.com"))
    }

    // Rule 4

    @Test("An entry with a port restricts the bypass to that port")
    func portSpecificEntry() {
        #expect(ProxyPolicy.bypasses(host: "intranet.example", port: 8080, noProxy: "intranet.example:8080"))
        #expect(
            !ProxyPolicy.bypasses(host: "intranet.example", port: 443, noProxy: "intranet.example:8080")
        )
    }

    @Test("An entry with no port matches any port")
    func portlessEntryMatchesAnyPort() {
        #expect(ProxyPolicy.bypasses(host: "intranet.example", port: 443, noProxy: "intranet.example"))
        #expect(ProxyPolicy.bypasses(host: "intranet.example", port: 9443, noProxy: "intranet.example"))
    }

    // Rule 5

    @Test("An IP literal matches exactly and nothing else")
    func ipLiteralMatchesExactly() {
        #expect(ProxyPolicy.bypasses(host: "10.1.2.3", port: 443, noProxy: "10.1.2.3"))
        #expect(!ProxyPolicy.bypasses(host: "10.1.2.4", port: 443, noProxy: "10.1.2.3"))
    }

    @Test("A CIDR range covers the addresses inside it and no others")
    func cidrRange() {
        #expect(ProxyPolicy.bypasses(host: "10.4.5.6", port: 443, noProxy: "10.0.0.0/8"))
        #expect(!ProxyPolicy.bypasses(host: "11.4.5.6", port: 443, noProxy: "10.0.0.0/8"))
        // A boundary that a byte-aligned implementation gets right by accident
        // and a bit-aligned one has to actually compute.
        #expect(ProxyPolicy.bypasses(host: "172.20.0.1", port: 443, noProxy: "172.16.0.0/12"))
        #expect(!ProxyPolicy.bypasses(host: "172.32.0.1", port: 443, noProxy: "172.16.0.0/12"))
        #expect(ProxyPolicy.bypasses(host: "192.168.1.9", port: 443, noProxy: "192.168.1.0/24"))
        #expect(!ProxyPolicy.bypasses(host: "192.168.2.9", port: 443, noProxy: "192.168.1.0/24"))
    }

    @Test("A zero-length prefix covers the whole address family")
    func zeroLengthPrefix() {
        #expect(ProxyPolicy.bypasses(host: "203.0.113.7", port: 443, noProxy: "0.0.0.0/0"))
    }

    @Test("An IPv6 CIDR range works the same way")
    func ipv6CIDR() {
        #expect(ProxyPolicy.bypasses(host: "fd12::1", port: 443, noProxy: "fd00::/8"))
        #expect(!ProxyPolicy.bypasses(host: "fe00::1", port: 443, noProxy: "fd00::/8"))
        #expect(ProxyPolicy.bypasses(host: "2001:db8::1", port: 443, noProxy: "2001:db8::/32"))
        #expect(!ProxyPolicy.bypasses(host: "2001:db9::1", port: 443, noProxy: "2001:db8::/32"))
    }

    @Test("An IPv6 literal matches with or without brackets, in any spelling")
    func ipv6Literal() {
        #expect(ProxyPolicy.bypasses(host: "[fd00::1]", port: 443, noProxy: "fd00::1"))
        #expect(ProxyPolicy.bypasses(host: "fd00::1", port: 443, noProxy: "[fd00::1]"))
        #expect(ProxyPolicy.bypasses(host: "[fd00::1]", port: 443, noProxy: "fd00:0:0:0:0:0:0:1"))
        #expect(!ProxyPolicy.bypasses(host: "[fd00::2]", port: 443, noProxy: "fd00::1"))
    }

    @Test("A bracketed IPv6 entry may still carry a port")
    func bracketedIPv6WithPort() {
        #expect(ProxyPolicy.bypasses(host: "fd00::1", port: 8080, noProxy: "[fd00::1]:8080"))
        #expect(!ProxyPolicy.bypasses(host: "fd00::1", port: 443, noProxy: "[fd00::1]:8080"))
    }

    @Test("A malformed entry is ignored rather than trapping or matching everything")
    func malformedEntriesFailClosed() {
        let unusable = [
            "10.0.0.0/abc",
            "10.0.0.0/33",
            "10.0.0.0/8/8",
            "not-an-address/8",
            "fd00::/999",
            "/8",
            "10.0.0.0/",
        ]
        for entry in unusable {
            #expect(
                !ProxyPolicy.bypasses(host: "10.4.5.6", port: 443, noProxy: entry),
                "expected no match for \(entry)"
            )
            #expect(
                !ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: entry),
                "expected no match for \(entry)"
            )
        }
    }

    @Test("A name entry never matches an address by suffix")
    func nameEntryDoesNotMatchAnAddress() {
        #expect(!ProxyPolicy.bypasses(host: "10.4.5.6", port: 443, noProxy: "5.6"))
        #expect(!ProxyPolicy.bypasses(host: "10.4.5.6", port: 443, noProxy: ".6"))
    }

    // Rule 7

    @Test("An absent or empty list bypasses nothing")
    func emptyListBypassesNothing() {
        #expect(!ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: nil))
        #expect(!ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: ""))
        #expect(!ProxyPolicy.bypasses(host: "api.example.com", port: 443, noProxy: "  ,\t "))
        #expect(!ProxyPolicy.bypasses(host: "10.4.5.6", port: 443, noProxy: nil))
    }
}

// MARK: - Loopback

@Suite("Proxy policy: loopback is never proxied")
struct ProxyLoopbackTests {

    @Test("Every spelling of loopback bypasses with no list at all")
    func loopbackWithNoList() {
        let loopback = [
            "localhost",
            "LOCALHOST",
            "api.localhost",
            "127.0.0.1",
            "127.13.14.15",
            "::1",
            "[::1]",
            "0:0:0:0:0:0:0:1",
            "::ffff:127.0.0.1",
        ]
        for host in loopback {
            #expect(
                ProxyPolicy.bypasses(host: host, port: 4711, noProxy: nil),
                "expected \(host) to be treated as loopback"
            )
        }
    }

    @Test("Loopback bypasses even when the list names something else entirely")
    func loopbackBeatsAnUnrelatedList() {
        #expect(ProxyPolicy.bypasses(host: "127.0.0.1", port: 4711, noProxy: "example.com"))
        #expect(ProxyPolicy.bypasses(host: "localhost", port: 4711, noProxy: "example.com,10.0.0.0/8"))
        #expect(ProxyPolicy.bypasses(host: "::1", port: 4711, noProxy: "example.com"))
    }

    @Test("A locally spawned server is reached directly through a configured proxy")
    func loopbackIsDirectThroughAConfiguredProxy() {
        // The default mode of this application is a client talking to a server
        // it spawned on the loopback interface. A proxy in the environment must
        // not be able to break that.
        let settings = ProxySettings(
            httpProxy: "http://proxy.example.com:8080",
            httpsProxy: "http://proxy.example.com:8080",
            noProxy: "example.com"
        )
        #expect(url("http://127.0.0.1:4711/v1/session", settings) == nil)
        #expect(url("http://localhost:4711/v1/session", settings) == nil)
        #expect(url("http://[::1]:4711/v1/session", settings) == nil)
        // …while a genuinely remote host still goes through it.
        #expect(url("https://api.other.test/v1", settings)?.host == "proxy.example.com")
    }

    @Test("A host that merely ends in something loopback-like is not loopback")
    func notLoopback() {
        #expect(!ProxyPolicy.bypasses(host: "notlocalhost", port: 443, noProxy: nil))
        #expect(!ProxyPolicy.bypasses(host: "localhost.example.com", port: 443, noProxy: nil))
        #expect(!ProxyPolicy.bypasses(host: "128.0.0.1", port: 443, noProxy: nil))
        #expect(!ProxyPolicy.bypasses(host: "::2", port: 443, noProxy: nil))
    }
}

// MARK: - Choosing an endpoint

@Suite("Proxy policy: choosing an endpoint for a URL")
struct ProxyEndpointSelectionTests {

    @Test("Each scheme uses its own variable")
    func schemeChoosesTheVariable() {
        let settings = ProxySettings(
            httpProxy: "http://plain.example.com:8080",
            httpsProxy: "http://secure.example.com:8443"
        )
        #expect(url("http://api.example.test/v1", settings)?.host == "plain.example.com")
        #expect(url("https://api.example.test/v1", settings)?.host == "secure.example.com")
    }

    @Test("There is no fallback from one scheme's proxy to the other's")
    func noCrossSchemeFallback() {
        let httpOnly = ProxySettings(httpProxy: "http://plain.example.com:8080")
        #expect(url("https://api.example.test/v1", httpOnly) == nil)

        let httpsOnly = ProxySettings(httpsProxy: "http://secure.example.com:8443")
        #expect(url("http://api.example.test/v1", httpsOnly) == nil)
    }

    @Test("Disabled settings never select a proxy")
    func disabledSelectsNothing() {
        var settings = ProxySettings(
            enabled: false,
            httpProxy: "http://proxy.example.com:8080",
            httpsProxy: "http://proxy.example.com:8080"
        )
        #expect(url("https://api.example.test/v1", settings) == nil)
        #expect(!settings.isConfigured)

        settings.enabled = true
        #expect(url("https://api.example.test/v1", settings)?.host == "proxy.example.com")
    }

    @Test("A scheme this policy does not proxy is left alone")
    func unknownSchemeIsDirect() {
        let settings = ProxySettings(
            httpProxy: "http://proxy.example.com:8080",
            httpsProxy: "http://proxy.example.com:8080"
        )
        #expect(url("ws://api.example.test/socket", settings) == nil)
        #expect(url("file:///tmp/thing", settings) == nil)
    }

    @Test("The scheme's default port is what a port-specific bypass is matched against")
    func defaultPortIsUsedForBypassMatching() {
        let matching = ProxySettings(
            httpsProxy: "http://proxy.example.com:8080",
            noProxy: "intranet.example:443"
        )
        #expect(url("https://intranet.example/v1", matching) == nil)

        let notMatching = ProxySettings(
            httpsProxy: "http://proxy.example.com:8080",
            noProxy: "intranet.example:8443"
        )
        #expect(url("https://intranet.example/v1", notMatching)?.host == "proxy.example.com")
        #expect(url("https://intranet.example:8443/v1", notMatching) == nil)
    }

    @Test("An unparseable proxy setting selects nothing rather than throwing")
    func unparseableSettingSelectsNothing() {
        let settings = ProxySettings(httpsProxy: "ftp://proxy.example.com:21")
        #expect(url("https://api.example.test/v1", settings) == nil)
    }

    @Test("An intranet host inside a bypassed range is reached directly")
    func intranetRangeIsDirect() {
        let settings = ProxySettings(
            httpProxy: "http://proxy.example.com:8080",
            httpsProxy: "http://proxy.example.com:8080",
            noProxy: "10.0.0.0/8,.intranet.example"
        )
        #expect(url("http://10.20.30.40:9000/health", settings) == nil)
        #expect(url("https://build.intranet.example/api", settings) == nil)
        #expect(url("https://api.public.test/v1", settings)?.host == "proxy.example.com")
    }
}

// MARK: - Environment

@Suite("Proxy policy: resolving from the environment")
struct ProxyEnvironmentTests {

    @Test("An empty environment configures nothing")
    func emptyEnvironment() {
        let settings = ProxyPolicy.fromEnvironment([:])
        #expect(settings.httpProxy == nil)
        #expect(settings.httpsProxy == nil)
        #expect(settings.noProxy == nil)
        #expect(!settings.isConfigured)
    }

    @Test("Each conventional variable is read")
    func conventionalVariables() {
        let settings = ProxyPolicy.fromEnvironment([
            "http_proxy": "http://plain.example.com:8080",
            "https_proxy": "http://secure.example.com:8443",
            "no_proxy": ".intranet.example",
        ])
        #expect(settings.httpProxy == "http://plain.example.com:8080")
        #expect(settings.httpsProxy == "http://secure.example.com:8443")
        #expect(settings.noProxy == ".intranet.example")
        #expect(settings.isConfigured)
    }

    @Test("The uppercase spelling is read when the lowercase one is absent")
    func uppercaseSpelling() {
        let settings = ProxyPolicy.fromEnvironment([
            "HTTP_PROXY": "http://plain.example.com:8080",
            "HTTPS_PROXY": "http://secure.example.com:8443",
            "NO_PROXY": ".intranet.example",
        ])
        #expect(settings.httpProxy == "http://plain.example.com:8080")
        #expect(settings.httpsProxy == "http://secure.example.com:8443")
        #expect(settings.noProxy == ".intranet.example")
    }

    @Test("Lowercase wins when both spellings are set")
    func lowercaseWins() {
        let settings = ProxyPolicy.fromEnvironment([
            "http_proxy": "http://lower.example.com:8080",
            "HTTP_PROXY": "http://upper.example.com:8080",
            "no_proxy": "lower.example",
            "NO_PROXY": "upper.example",
        ])
        #expect(settings.httpProxy == "http://lower.example.com:8080")
        #expect(settings.noProxy == "lower.example")
    }

    @Test("all_proxy is the fallback for both schemes")
    func allProxyFallback() {
        let settings = ProxyPolicy.fromEnvironment(["all_proxy": "socks5://proxy.example.com:1080"])
        #expect(settings.httpProxy == "socks5://proxy.example.com:1080")
        #expect(settings.httpsProxy == "socks5://proxy.example.com:1080")
        #expect(ProxyPolicy.endpoint(from: settings.httpsProxy ?? "")?.isSOCKS == true)
    }

    @Test("A scheme-specific variable wins over all_proxy for that scheme only")
    func schemeSpecificBeatsAllProxy() {
        let settings = ProxyPolicy.fromEnvironment([
            "all_proxy": "socks5://everything.example.com:1080",
            "https_proxy": "http://secure.example.com:8443",
        ])
        #expect(settings.httpsProxy == "http://secure.example.com:8443")
        #expect(settings.httpProxy == "socks5://everything.example.com:1080")
    }

    @Test("An empty value means not set")
    func emptyValueMeansNotSet() {
        let settings = ProxyPolicy.fromEnvironment([
            "http_proxy": "",
            "https_proxy": "   ",
            "no_proxy": "",
        ])
        #expect(settings.httpProxy == nil)
        #expect(settings.httpsProxy == nil)
        #expect(settings.noProxy == nil)
        #expect(!settings.isConfigured)
    }

    @Test("An emptied lowercase variable falls through to the uppercase one")
    func emptyLowercaseFallsThrough() {
        let settings = ProxyPolicy.fromEnvironment([
            "http_proxy": "",
            "HTTP_PROXY": "http://upper.example.com:8080",
        ])
        #expect(settings.httpProxy == "http://upper.example.com:8080")
    }

    @Test("Surrounding whitespace is trimmed off a value")
    func valuesAreTrimmed() {
        let settings = ProxyPolicy.fromEnvironment(["http_proxy": "  http://plain.example.com:8080\n"])
        #expect(settings.httpProxy == "http://plain.example.com:8080")
    }
}

// MARK: - Settings

@Suite("Proxy policy: settings")
struct ProxySettingsTests {

    @Test("The disabled value configures nothing")
    func disabledValue() {
        #expect(!ProxySettings.disabled.enabled)
        #expect(!ProxySettings.disabled.isConfigured)
    }

    @Test("Settings with no proxy URL are not configured")
    func noURLIsNotConfigured() {
        #expect(!ProxySettings().isConfigured)
        #expect(!ProxySettings(noProxy: "example.com").isConfigured)
        #expect(!ProxySettings(httpProxy: "   ").isConfigured)
        #expect(ProxySettings(httpProxy: "http://proxy.example.com:8080").isConfigured)
        #expect(ProxySettings(httpsProxy: "http://proxy.example.com:8080").isConfigured)
    }

    @Test("Disabling wins over a configured URL")
    func disablingWins() {
        let settings = ProxySettings(enabled: false, httpProxy: "http://proxy.example.com:8080")
        #expect(!settings.isConfigured)
    }

    @Test("A partial settings object decodes, defaulting what it omits")
    func partialDecode() throws {
        let json = Data(#"{"noProxy":".intranet.example"}"#.utf8)
        let settings = try JSONDecoder().decode(ProxySettings.self, from: json)
        #expect(settings.enabled)
        #expect(settings.httpProxy == nil)
        #expect(settings.httpsProxy == nil)
        #expect(settings.noProxy == ".intranet.example")
    }

    @Test("Settings survive a coding round trip")
    func codingRoundTrip() throws {
        let original = ProxySettings(
            enabled: true,
            httpProxy: "http://plain.example.com:8080",
            httpsProxy: "http://secure.example.com:8443",
            noProxy: ".intranet.example,10.0.0.0/8"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Helpers

/// Resolves the proxy for a URL string, so each expectation reads as one line.
private func url(_ string: String, _ settings: ProxySettings) -> ProxyEndpoint? {
    guard let parsed = URL(string: string) else {
        Issue.record("test URL did not parse: \(string)")
        return nil
    }
    return ProxyPolicy.endpoint(for: parsed, settings: settings)
}
