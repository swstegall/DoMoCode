// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Settings

/// Which HTTP proxy, if any, this process should route a request through.
///
/// The shape follows the conventional environment variables — `http_proxy`,
/// `https_proxy`, `no_proxy` — because that is the vocabulary a user on a
/// network with a corporate HTTP proxy already has, and inventing a second one
/// would mean a machine that works for `curl` and not for this tool.
///
/// A value type with no IO of its own: it is resolved once from the environment
/// and the settings files, then handed to whatever builds clients. Nothing here
/// opens a socket, and nothing here reads `ProcessInfo` — see
/// ``ProxyPolicy/fromEnvironment(_:)``, which takes the environment as an
/// argument so the whole policy stays testable and order-independent.
public struct ProxySettings: Sendable, Hashable, Codable {
    /// Whether proxying happens at all. Defaults to on, since the settings only
    /// have an effect when a proxy URL is present anyway; `false` is the switch
    /// that makes this tool go direct on a machine whose environment says
    /// otherwise.
    public var enabled: Bool
    /// The proxy for `http:` URLs, e.g. `http://proxy.example.com:8080`.
    public var httpProxy: String?
    /// The proxy for `https:` URLs. Separate from ``httpProxy`` because the two
    /// conventional variables are separate and a deployment is entitled to set
    /// only one of them.
    public var httpsProxy: String?
    /// Hosts that must be reached directly, comma and/or whitespace separated.
    /// See ``ProxyPolicy/bypasses(host:port:noProxy:)`` for the exact rules —
    /// they are the `no_proxy` convention, not a private dialect.
    public var noProxy: String?

    public init(
        enabled: Bool = true,
        httpProxy: String? = nil,
        httpsProxy: String? = nil,
        noProxy: String? = nil
    ) {
        self.enabled = enabled
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
    }

    /// Proxying off entirely. The state every caller must behave under exactly
    /// as it did before proxy support existed.
    public static let disabled = ProxySettings(enabled: false)

    /// Whether anything here could ever route a request through a proxy.
    ///
    /// The load-bearing use is a client factory deciding whether it needs to own
    /// a second `HTTPClient` at all: false here must mean "own nothing, hand
    /// back the shared client", so a whitespace-only proxy string has to read as
    /// absent rather than as a configured proxy with an unusable URL.
    public var isConfigured: Bool {
        guard enabled else { return false }
        return ProxySettings.isPresent(httpProxy) || ProxySettings.isPresent(httpsProxy)
    }

    private static func isPresent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case httpProxy
        case httpsProxy
        case noProxy
    }

    /// Decodes field by field, defaulting anything absent.
    ///
    /// Not the synthesized initializer, which would require every key: a user
    /// writing only `{"noProxy": "intranet.example"}` into a settings file means
    /// "change one thing", and refusing the whole object over the three keys
    /// they did not write would take the session down over a proxy preference.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ProxySettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        httpProxy = try container.decodeIfPresent(String.self, forKey: .httpProxy)
        httpsProxy = try container.decodeIfPresent(String.self, forKey: .httpsProxy)
        noProxy = try container.decodeIfPresent(String.self, forKey: .noProxy)
    }
}

/// One resolved proxy server: where to connect, and with what credential.
///
/// Deliberately not a `URL`. The transport needs the parts separately, and
/// carrying the string form around is how a password ends up in a log line.
public struct ProxyEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    /// Whether this is a SOCKS proxy rather than an HTTP one. The two are
    /// configured differently by the transport, and the scheme is the only
    /// place that distinction is written down.
    public var isSOCKS: Bool

    public init(
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        isSOCKS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.isSOCKS = isSOCKS
    }
}

extension ProxyEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    /// Host and port only.
    ///
    /// Written out rather than left to the default reflection, which prints
    /// every stored property — including ``password``. A proxy URL with a
    /// credential in it is a credential the user typed into a settings file, and
    /// the fastest route from there into a log file, a crash report or an error
    /// banner is one interpolation of this value by a caller who never thought
    /// about it.
    public var description: String {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return isSOCKS ? "socks://\(authority)" : authority
    }

    public var debugDescription: String { description }
}

// MARK: - Policy

/// Proxy selection and `no_proxy` matching, as pure functions.
///
/// No IO, no networking, no dependency on the HTTP client: this target is the
/// one every other module can see, and the matching rules have to be the same
/// answer everywhere or a request will be checked by one rule and sent by
/// another.
public enum ProxyPolicy {

    // MARK: Proxy URLs

    /// Parses `scheme://[user:pass@]host[:port]` into an endpoint, or nil for
    /// anything that could not be used as a proxy.
    ///
    /// Nil rather than a thrown error, and nil for every malformed spelling: the
    /// caller's only sane response to an unusable proxy setting is to warn and
    /// go direct, and a typo in an environment variable must not be able to end
    /// a session.
    ///
    /// A bare `host:port` with no scheme is accepted because that is how these
    /// variables are frequently set, and it is read as `http` — the scheme the
    /// overwhelming majority of proxy deployments speak, and the one whose
    /// default port (80) is least likely to be silently wrong. A bare host with
    /// no port at all therefore also lands on port 80.
    ///
    /// Hand-rolled rather than handed to `URL`: `URL(string: "host:8080")`
    /// parses as scheme `host` with path `8080`, which is a wrong answer rather
    /// than a rejection, and a wrong answer here means connecting somewhere the
    /// user did not name.
    public static func endpoint(from raw: String) -> ProxyEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var rest = Substring(trimmed)
        var scheme = "http"
        if let separator = rest.range(of: "://") {
            scheme = String(rest[rest.startIndex..<separator.lowerBound]).lowercased()
            rest = rest[separator.upperBound...]
        }
        guard let defaultPort = defaultProxyPort(forScheme: scheme) else { return nil }

        // A proxy is an authority, never a path. Everything from the first
        // separator on is discarded rather than rejected, so a trailing slash —
        // which every browser-facing proxy document writes — still parses.
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<cut]
        }
        guard !rest.isEmpty else { return nil }

        var username: String?
        var password: String?
        if let at = rest.lastIndex(of: "@") {
            // The LAST `@`: a password is required to be percent-encoded, but
            // one that is not would otherwise truncate the host to whatever
            // followed the first `@` and send the request somewhere else.
            let credentials = splitCredentials(rest[..<at])
            username = credentials.username
            password = credentials.password
            rest = rest[rest.index(after: at)...]
        }

        guard let authority = splitHostPort(rest, defaultPort: defaultPort) else { return nil }
        return ProxyEndpoint(
            host: authority.host,
            port: authority.port,
            username: username,
            password: password,
            isSOCKS: scheme.hasPrefix("socks")
        )
    }

    /// The endpoint a request to `url` must go through, or nil to go direct.
    ///
    /// The scheme chooses the variable and there is deliberately no fallback
    /// from one to the other: in the `no_proxy` convention an unset
    /// `https_proxy` means https traffic is not proxied, and quietly borrowing
    /// `http_proxy` for it would route TLS through a server the user never
    /// nominated for it. The catch-all belongs to `all_proxy`, which
    /// ``fromEnvironment(_:)`` folds into *both* fields at resolution time.
    public static func endpoint(for url: URL, settings: ProxySettings) -> ProxyEndpoint? {
        guard settings.enabled else { return nil }
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return nil
        }

        let raw: String?
        let defaultPort: Int
        switch scheme {
        case "https":
            raw = settings.httpsProxy
            defaultPort = 443
        case "http":
            raw = settings.httpProxy
            defaultPort = 80
        default:
            // Anything else is not something this policy knows how to proxy, and
            // guessing would be worse than leaving it alone.
            return nil
        }

        guard !bypasses(host: host, port: url.port ?? defaultPort, noProxy: settings.noProxy) else {
            return nil
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return endpoint(from: raw)
    }

    // MARK: no_proxy

    /// Whether a request to `host:port` must be made directly.
    ///
    /// The `no_proxy` convention as `curl` and the wider ecosystem implement it:
    /// entries separated by commas and/or whitespace, matched case-insensitively;
    /// `*` meaning everything; a name matching itself and any subdomain of it on
    /// a label boundary, with or without a leading dot; an optional `:port`
    /// restricting the entry to that port; IP literals matching exactly and CIDR
    /// blocks matching their range.
    ///
    /// **Loopback always bypasses, whatever `no_proxy` says.** This is not a
    /// convenience. The default mode of this application is a terminal client
    /// talking to a server this same process spawned on the loopback interface;
    /// handing that connection to a proxy breaks the entire program, and no
    /// proxy on any network could route to it in the first place — the address
    /// is only meaningful inside this machine. Someone whose environment sets a
    /// proxy without a `no_proxy` entry for loopback, which is the common case,
    /// would otherwise find the tool unable to talk to itself. So the loopback
    /// test runs before `no_proxy` is even read, and there is deliberately no
    /// setting that turns it off.
    /// Whether `host` is a literal address on a private or otherwise non-routable
    /// network — loopback, the RFC 1918 IPv4 ranges, link-local, and the RFC 4193
    /// IPv6 unique-local range.
    ///
    /// Exposed because a second copy of this test had grown elsewhere in the
    /// package and the two disagreed. A hand-rolled version guarding remote
    /// access recognised `::1` and `fe80:` but not `fc00::/7` — the range a
    /// private IPv6 network actually uses — and not `::ffff:10.0.0.1`, the
    /// IPv4-mapped form a dual-stack resolver hands back. An allow-list that can
    /// be stepped around by spelling the same address differently is not an
    /// allow-list, so both callers now share this one, which parses the address
    /// properly rather than matching on prefixes of the text.
    ///
    /// A NAME is never private here, whatever it resolves to: this answers a
    /// question about a literal, and resolving to decide would mean a DNS lookup
    /// inside a pure function and a different answer each time the record moves.
    /// A caller that needs resolution has to do it and ask again.
    public static func isPrivateAddress(_ host: String) -> Bool {
        let target = normalizedHost(host)
        guard !target.isEmpty else { return false }
        if isLoopback(target) { return true }

        // Every reading the resolver might take, not just the canonical one:
        // `127.1` and `0x7f000001` are 127.0.0.1 to `getaddrinfo`, and treating
        // them as names is what let them past this gate.
        let readings = lenientIPv4Addresses(target)
        if !readings.isEmpty { return readings.contains(where: isPrivateIPv4) }
        guard let address = ipv6Address(target) else { return false }

        // Unspecified (`::`), unique-local (`fc00::/7`), and link-local
        // (`fe80::/10`).
        if address.allSatisfy({ $0 == 0 }) { return true }
        if address[0] & 0xFE == 0xFC { return true }
        if address[0] == 0xFE, address[1] & 0xC0 == 0x80 { return true }

        // The IPv4-mapped form is the same host reached by another spelling, so
        // it has to get the same answer.
        let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        guard Array(address.prefix(12)) == mappedPrefix else { return false }
        let mapped = (UInt32(address[12]) << 24) | (UInt32(address[13]) << 16)
            | (UInt32(address[14]) << 8) | UInt32(address[15])
        return isPrivateIPv4(mapped)
    }

    /// The RFC 1918 ranges plus loopback, link-local, and the unspecified address.
    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xFF
        if address == 0 { return true }
        if first == 10 || first == 127 { return true }
        if first == 169, second == 254 { return true }
        if first == 192, second == 168 { return true }
        return first == 172 && (16...31).contains(second)
    }

    public static func bypasses(host: String, port: Int, noProxy: String?) -> Bool {
        let target = normalizedHost(host)
        // A host that cannot be read is not a host a proxy decision can be made
        // about; direct is the behaviour that was in place before any of this
        // existed, so it is the safe answer.
        guard !target.isEmpty else { return true }

        if isLoopback(target) { return true }

        guard let noProxy, !noProxy.isEmpty else { return false }

        // Parsed once rather than per entry: a list of a hundred intranet ranges
        // is an ordinary thing to find in this variable.
        let targetIPv4 = ipv4Address(target)
        let targetIPv6 = ipv6Address(target)

        for entry in noProxy.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let entry = entry.lowercased()
            if entry == "*" { return true }
            guard let parsed = parseNoProxyEntry(entry) else { continue }
            if let entryPort = parsed.port, entryPort != port { continue }
            if matches(pattern: parsed.host, host: target, ipv4: targetIPv4, ipv6: targetIPv6) {
                return true
            }
        }
        return false
    }

    // MARK: Environment

    /// Resolves settings from an environment dictionary.
    ///
    /// Reads `https_proxy`, `http_proxy`, `all_proxy` and `no_proxy` in both
    /// spellings, with lowercase winning over uppercase — the established
    /// convention, and the one a user will have relied on when they set exactly
    /// one of the two. `all_proxy` is folded into both scheme-specific fields so
    /// that the selection in ``endpoint(for:settings:)`` needs no fallback of
    /// its own.
    ///
    /// An empty value reads as "not set" rather than "an empty proxy": exporting
    /// an empty variable is the documented way to switch a proxy off for one
    /// command, and treating it as configuration would turn that into an
    /// unparseable proxy URL and a warning the user did not earn.
    ///
    /// The environment is an argument rather than something read from
    /// `ProcessInfo` so that this stays a pure function — the caller composing
    /// it with higher-precedence settings needs to be able to say exactly what
    /// each layer contributed.
    public static func fromEnvironment(_ environment: [String: String]) -> ProxySettings {
        func value(_ name: String) -> String? {
            for key in [name, name.uppercased()] {
                guard let raw = environment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }

        let all = value("all_proxy")
        return ProxySettings(
            enabled: true,
            httpProxy: value("http_proxy") ?? all,
            httpsProxy: value("https_proxy") ?? all,
            noProxy: value("no_proxy")
        )
    }

    // MARK: - Parsing helpers

    /// The port a proxy scheme implies when the URL does not say. Nil for a
    /// scheme this policy will not proxy through at all.
    private static func defaultProxyPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        case "socks", "socks4", "socks4a", "socks5", "socks5h": return 1080
        default: return nil
        }
    }

    /// Splits `user:pass`, percent-decoding both halves.
    ///
    /// Percent-decoding matters because `:`, `@` and `/` are exactly the
    /// characters a generated proxy password is likely to contain and exactly
    /// the ones that must be encoded to survive the URL form.
    private static func splitCredentials(
        _ text: Substring
    ) -> (username: String?, password: String?) {
        func decoded(_ part: Substring) -> String? {
            guard !part.isEmpty else { return nil }
            return String(part).removingPercentEncoding ?? String(part)
        }
        guard let colon = text.firstIndex(of: ":") else {
            return (decoded(text), nil)
        }
        return (decoded(text[..<colon]), decoded(text[text.index(after: colon)...]))
    }

    /// Splits a proxy authority into host and port, rejecting anything that is
    /// not usable as one.
    private static func splitHostPort(
        _ text: Substring,
        defaultPort: Int
    ) -> (host: String, port: Int)? {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            guard ipv6Address(host) != nil else { return nil }
            let remainder = text[text.index(after: close)...]
            if remainder.isEmpty { return (host.lowercased(), defaultPort) }
            guard remainder.hasPrefix(":"), let port = parsePort(remainder.dropFirst()) else {
                return nil
            }
            return (host.lowercased(), port)
        }

        let colons = text.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colons == 0 {
            guard isPlausibleHostname(text) else { return nil }
            return (text.lowercased(), defaultPort)
        }
        if colons == 1, let colon = text.firstIndex(of: ":") {
            let host = text[..<colon]
            guard isPlausibleHostname(host), let port = parsePort(text[text.index(after: colon)...])
            else { return nil }
            return (host.lowercased(), port)
        }
        // More than one colon and no brackets: the only reading that is not a
        // typo is a bare IPv6 literal, which people do write in these variables.
        guard ipv6Address(String(text)) != nil else { return nil }
        return (text.lowercased(), defaultPort)
    }

    /// A decimal port in the usable range. Zero is rejected along with the
    /// unparseable: a proxy on port 0 is a connection that cannot be made, and
    /// silently accepting it would replace a warning with a hang.
    private static func parsePort(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ ("0"..."9").contains($0) }),
            let port = Int(text), port > 0, port <= 65_535
        else { return nil }
        return port
    }

    /// Whether `text` could be a host name — non-empty and free of the
    /// characters that would mean it was actually something else that failed to
    /// parse.
    private static func isPlausibleHostname(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        return text.allSatisfy { character in
            guard let ascii = character.asciiValue, ascii > 0x20, ascii < 0x7F else { return false }
            return !"/@:[]?#\\".contains(character)
        }
    }

    // MARK: - no_proxy matching

    /// Lowercases, and strips the two decorations that would otherwise defeat a
    /// literal comparison: the brackets around an IPv6 literal and the trailing
    /// dot of a fully-qualified name.
    private static func normalizedHost(_ host: String) -> String {
        var text = Substring(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if text.hasPrefix("["), text.hasSuffix("]"), text.count > 2 {
            text = text.dropFirst().dropLast()
        }
        if text.count > 1, text.hasSuffix(".") { text = text.dropLast() }
        return String(text)
    }

    /// Splits one `no_proxy` entry into its host pattern and optional port.
    private static func parseNoProxyEntry(_ entry: String) -> (host: String, port: Int?)? {
        let text = Substring(entry)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let remainder = text[text.index(after: close)...]
            if remainder.isEmpty { return (host, nil) }
            // `[fd00::]/8` — the prefix length belongs to the address, not to
            // the authority, so it is handed back as part of the pattern.
            if remainder.hasPrefix("/") { return (host + remainder, nil) }
            guard remainder.hasPrefix(":"), let port = parsePort(remainder.dropFirst()) else {
                return nil
            }
            return (host, port)
        }

        let colons = text.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colons == 1, let colon = text.firstIndex(of: ":") {
            let host = String(text[..<colon])
            guard !host.isEmpty, let port = parsePort(text[text.index(after: colon)...]) else {
                return nil
            }
            return (host, port)
        }
        // Zero colons is a name or an IPv4 form; more than one is a bare IPv6
        // literal, which cannot also carry a port without brackets.
        guard !entry.isEmpty else { return nil }
        return (entry, nil)
    }

    /// Whether one `no_proxy` host pattern covers the request's host.
    private static func matches(
        pattern: String,
        host: String,
        ipv4: UInt32?,
        ipv6: [UInt8]?
    ) -> Bool {
        if pattern.contains("/") {
            return cidrMatches(pattern: pattern, ipv4: ipv4, ipv6: ipv6)
        }
        if let network = ipv4Address(pattern) { return ipv4 == network }
        if let network = ipv6Address(pattern) { return ipv6 == network }

        // An address is never matched by a name pattern. Without this, an entry
        // of `0.1` would match the host `10.0.0.1` by suffix, which is a range
        // nobody wrote down.
        guard ipv4 == nil, ipv6 == nil else { return false }

        var trimmed = Substring(pattern)
        if trimmed.hasPrefix("*.") { trimmed = trimmed.dropFirst(2) }
        if trimmed.hasPrefix(".") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        let base = String(trimmed)
        guard !base.isEmpty else { return false }
        // The suffix must begin at a label boundary. Comparing raw suffixes is
        // the classic bug here: `notexample.com` ends with `example.com` and is
        // a different domain under different control, so an entry for one must
        // never send traffic for the other direct.
        return host == base || host.hasSuffix("." + base)
    }

    /// Whether a `network/prefix` pattern contains the request's address.
    ///
    /// Anything malformed — a prefix that is not a number, one too long for the
    /// family, an address that does not parse — is "no match" rather than a
    /// trap or a wildcard. A typo in one entry of a long list must cost that
    /// entry and nothing else.
    private static func cidrMatches(pattern: String, ipv4: UInt32?, ipv6: [UInt8]?) -> Bool {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let prefixText = parts[1]
        guard !prefixText.isEmpty, prefixText.count <= 3,
            prefixText.allSatisfy({ ("0"..."9").contains($0) }), let prefix = Int(prefixText)
        else { return false }
        let network = String(parts[0])

        if let networkIPv4 = ipv4Address(network) {
            guard prefix <= 32, let address = ipv4 else { return false }
            // `UInt32.max << 32` is zero under Swift's non-masking shift, which
            // is exactly the mask a /0 wants, so the degenerate prefix needs no
            // special case.
            let mask = UInt32.max << (32 - prefix)
            return (address & mask) == (networkIPv4 & mask)
        }
        guard let networkIPv6 = ipv6Address(network) else { return false }
        guard prefix <= 128, let address = ipv6 else { return false }
        let wholeBytes = prefix / 8
        for index in 0..<wholeBytes where address[index] != networkIPv6[index] { return false }
        let remainingBits = prefix % 8
        if remainingBits > 0 {
            let mask = UInt8(0xFF) << (8 - remainingBits)
            if (address[wholeBytes] ^ networkIPv6[wholeBytes]) & mask != 0 { return false }
        }
        return true
    }

    /// Whether this host is the machine itself. See the note on
    /// ``bypasses(host:port:noProxy:)`` for why this outranks every setting.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // Same leniency as the privacy test, and for the same reason: these two
        // disagreeing about what an address IS is the class of bug that put a
        // loopback endpoint on the far side of a gate that was supposed to
        // refuse it.
        let readings = lenientIPv4Addresses(host)
        if !readings.isEmpty { return readings.contains { $0 >> 24 == 127 } }
        guard let address = ipv6Address(host) else { return false }
        if address == Self.ipv6Loopback { return true }
        // `::ffff:127.0.0.1` is the same interface reached through the
        // IPv4-mapped form, which is what a dual-stack resolver hands back.
        let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        return Array(address.prefix(12)) == mappedPrefix && address[12] == 127
    }

    private static let ipv6Loopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

    // MARK: - Address parsing

    /// A dotted-quad IPv4 literal as a single unsigned word, or nil.
    ///
    /// Strict about the form: exactly four parts, one to three decimal digits
    /// each, none above 255. The lenient readings `inet_aton` allows — octal
    /// from a leading zero, a 32-bit integer with no dots at all — are the
    /// reason address matching is a classic source of bypasses, and none of them
    /// is a thing a user writes in this variable on purpose.
    /// Every IPv4 address the platform resolver would reach for `text`, when it
    /// would treat it as a numeric literal at all.
    ///
    /// The strict reader below is right for a `no_proxy` ENTRY, which a user
    /// types deliberately. It is wrong for the host of a URL, which is the
    /// untrusted side, and the difference was a way straight past the
    /// private-network gate: `getaddrinfo` accepts `127.1`, `2130706433`,
    /// `0x7f000001` and `0127.0.0.1` and returns 127.0.0.1 for all of them, while
    /// a dotted-quad-only reader calls each one a name and therefore public. The
    /// endpoint the gate refuses when spelled `127.0.0.1` was reachable by typing
    /// the same address a different way — verified end to end against a real
    /// listening socket.
    ///
    /// So this follows `inet_aton`: one to four parts, the last absorbing the
    /// remaining bytes, each part decimal, hex (`0x…`) or octal (leading zero).
    ///
    /// It returns a SET because the platforms disagree and the gate must be right
    /// on both: glibc reads a leading zero as octal (`012.0.0.1` → 10.0.0.1)
    /// while Darwin reads it as decimal (→ 12.0.0.1). A caller treats the host as
    /// private if ANY reading is private, which fails closed on the ambiguity
    /// rather than picking a platform and being wrong on the other.
    static func lenientIPv4Addresses(_ text: String) -> [UInt32] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return [] }

        // Each part can read more than one way; the candidate addresses are the
        // combinations. Bounded by 2^4 readings, so the product cannot blow up.
        var readings: [[UInt64]] = []
        for part in parts {
            let values = numericReadings(part)
            guard !values.isEmpty else { return [] }
            readings.append(values)
        }

        var addresses: Set<UInt32> = []
        func combine(_ index: Int, _ chosen: [UInt64]) {
            guard index < readings.count else {
                if let address = inetAtonAddress(chosen) { addresses.insert(address) }
                return
            }
            for value in readings[index] { combine(index + 1, chosen + [value]) }
        }
        combine(0, [])
        return Array(addresses)
    }

    /// The values one dotted part can denote, per `inet_aton`'s grammar.
    private static func numericReadings(_ part: Substring) -> [UInt64] {
        // 20 rather than a tight per-radix bound: the value is what actually
        // constrains this (a UInt64 parse rejects overflow and `inetAtonAddress`
        // caps the result at 32 bits), and a tight digit cap silently rejected
        // `017700000001` — twelve characters of octal that is exactly 127.0.0.1.
        guard !part.isEmpty, part.count <= 20 else { return [] }
        let lower = part.lowercased()
        if lower.hasPrefix("0x") {
            let digits = lower.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }),
                let value = UInt64(digits, radix: 16)
            else { return [] }
            return [value]
        }
        guard part.allSatisfy({ ("0"..."9").contains($0) }) else { return [] }
        guard let decimal = UInt64(part) else { return [] }
        // A leading zero is octal on glibc and decimal on Darwin, so both count.
        if part.count > 1, part.first == "0", let octal = UInt64(part.dropFirst(), radix: 8) {
            return [decimal, octal]
        }
        return [decimal]
    }

    /// `inet_aton`'s assembly rule: the final part absorbs whatever bytes the
    /// leading parts did not name.
    private static func inetAtonAddress(_ parts: [UInt64]) -> UInt32? {
        guard let last = parts.last else { return nil }
        let leading = parts.dropLast()
        guard leading.allSatisfy({ $0 <= 255 }) else { return nil }
        let remainingBytes = 4 - leading.count
        let ceiling: UInt64 = remainingBytes >= 4 ? 0xFFFF_FFFF : (UInt64(1) << (8 * remainingBytes)) - 1
        guard last <= ceiling else { return nil }
        var address: UInt64 = 0
        for value in leading { address = (address << 8) | value }
        address = (address << (8 * remainingBytes)) | last
        guard address <= 0xFFFF_FFFF else { return nil }
        return UInt32(address)
    }

    private static func ipv4Address(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ ("0"..."9").contains($0) }),
                let octet = UInt32(part), octet <= 255
            else { return nil }
            result = (result << 8) | octet
        }
        return result
    }

    /// An IPv6 literal as sixteen bytes, or nil.
    ///
    /// Written out with integer arithmetic rather than handed to `inet_pton`
    /// because this target is compiled with strict memory safety and has no
    /// business reaching for a pointer to satisfy a C signature. Handles `::`
    /// compression and the IPv4-tail form, which is the spelling a dual-stack
    /// address arrives in.
    private static func ipv6Address(_ text: String) -> [UInt8]? {
        var body = Substring(text)
        // A zone index (`fe80::1%en0`) identifies an interface, not a different
        // address; dropping it lets the address itself still match.
        if let percent = body.firstIndex(of: "%") { body = body[..<percent] }
        guard !body.isEmpty, body.count <= 45 else { return nil }
        guard
            body.allSatisfy({ character in
                (character.isHexDigit && character.isASCII) || character == ":" || character == "."
            })
        else { return nil }

        var headGroups: [UInt16] = []
        var tailGroups: [UInt16] = []
        var compressed = false

        if let marker = body.range(of: "::") {
            let head = body[..<marker.lowerBound]
            let tail = body[marker.upperBound...]
            // A second `::` makes the number of elided groups ambiguous, which
            // is why the form forbids it.
            guard tail.range(of: "::") == nil else { return nil }
            compressed = true
            guard let parsedHead = ipv6Groups(head, allowIPv4Tail: false) else { return nil }
            guard let parsedTail = ipv6Groups(tail, allowIPv4Tail: true) else { return nil }
            headGroups = parsedHead
            tailGroups = parsedTail
        } else {
            guard let parsed = ipv6Groups(body, allowIPv4Tail: true) else { return nil }
            headGroups = parsed
        }

        var groups: [UInt16] = []
        if compressed {
            let written = headGroups.count + tailGroups.count
            // `::` stands for at least one elided group; eight written groups
            // leave it standing for none.
            guard written < 8 else { return nil }
            groups = headGroups + Array(repeating: 0, count: 8 - written) + tailGroups
        } else {
            guard headGroups.count == 8 else { return nil }
            groups = headGroups
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for group in groups {
            bytes.append(UInt8(truncatingIfNeeded: group >> 8))
            bytes.append(UInt8(truncatingIfNeeded: group))
        }
        return bytes
    }

    /// The colon-separated groups of one half of an IPv6 literal.
    ///
    /// An empty half — the text on either side of a leading or trailing `::` —
    /// is no groups rather than one empty group.
    private static func ipv6Groups(_ text: Substring, allowIPv4Tail: Bool) -> [UInt16]? {
        guard !text.isEmpty else { return [] }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var groups: [UInt16] = []
        for (index, part) in parts.enumerated() {
            if part.contains(".") {
                guard allowIPv4Tail, index == parts.count - 1, let address = ipv4Address(String(part))
                else { return nil }
                groups.append(UInt16(truncatingIfNeeded: address >> 16))
                groups.append(UInt16(truncatingIfNeeded: address))
                continue
            }
            guard !part.isEmpty, part.count <= 4, let group = UInt16(part, radix: 16) else {
                return nil
            }
            groups.append(group)
        }
        guard groups.count <= 8 else { return nil }
        return groups
    }
}
