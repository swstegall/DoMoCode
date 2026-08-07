// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The private-address predicate the remote-access gate is built on.
//
// It exists as one shared function because it used to exist as two that
// disagreed: the gate guarding outbound access matched on prefixes of the host
// TEXT, so the same machine was "private" written one way and public written
// another. Every case below that is marked as a former bypass reached the
// network without the opt-in the gate is there to require.

import Testing

import DoMoCore

@Suite("Private address detection")
struct PrivateAddressTests {

    // MARK: The spellings that used to get through

    /// `fc00::/7` is what a private IPv6 network is numbered from — the direct
    /// equivalent of 10/8 — and the previous matcher recognised only the
    /// link-local `fe80:` prefix, so an ordinary intranet address was read as
    /// public.
    @Test("A unique-local IPv6 address is private", arguments: [
        "fc00::1",
        "fd00::1",
        "fd12:3456:789a:1::1",
        "FD00::1",
    ])
    func uniqueLocalIsPrivate(_ host: String) {
        #expect(ProxyPolicy.isPrivateAddress(host))
    }

    /// The form a dual-stack resolver hands back for an IPv4 host. Matching on
    /// text could not see the IPv4 address inside it.
    @Test("An IPv4-mapped IPv6 address is judged by the address it maps to", arguments: [
        "::ffff:10.0.0.1",
        "::ffff:192.168.1.5",
        "::ffff:127.0.0.1",
    ])
    func mappedIPv4IsPrivate(_ host: String) {
        #expect(ProxyPolicy.isPrivateAddress(host))
    }

    @Test("A mapped PUBLIC address is still public")
    func mappedPublicIsPublic() {
        #expect(!ProxyPolicy.isPrivateAddress("::ffff:93.184.216.34"))
    }

    // MARK: What was already right, and must stay right

    @Test("The RFC 1918 ranges, loopback and link-local are private", arguments: [
        "10.0.0.1", "10.255.255.255",
        "172.16.0.1", "172.31.255.254",
        "192.168.1.5",
        "127.0.0.1", "127.1.2.3",
        "169.254.1.1",
        "::1", "fe80::1",
        "localhost",
        "0.0.0.0", "::",
    ])
    func knownPrivate(_ host: String) {
        #expect(ProxyPolicy.isPrivateAddress(host))
    }

    /// The neighbours of each range, which a sloppy comparison catches by
    /// mistake. `172.15` and `172.32` sit either side of the RFC 1918 block.
    @Test("Addresses just outside the private ranges are public", arguments: [
        "11.0.0.1",
        "172.15.255.255", "172.32.0.1",
        "192.169.1.1", "191.168.1.1",
        "126.0.0.1", "128.0.0.1",
        "169.253.1.1",
        "8.8.8.8",
        "2001:4860:4860::8888",
    ])
    func knownPublic(_ host: String) {
        #expect(!ProxyPolicy.isPrivateAddress(host))
    }

    // MARK: Names

    /// A name answers "no" whatever it resolves to — this is a question about a
    /// literal, and resolving inside it would mean a DNS lookup in a pure
    /// function whose answer changes when the record moves. A deployment that
    /// needs name-based control uses the allowed-hosts list, which is exact.
    @Test("A hostname is not an address", arguments: [
        "intranet.example.com",
        "10-0-0-1.example.com",
        "not-localhost",
    ])
    func namesAreNotAddresses(_ host: String) {
        #expect(!ProxyPolicy.isPrivateAddress(host))
    }

    /// `.localhost` is reserved for the loopback interface, so a name under it
    /// is the one name that does answer yes.
    @Test("A name under the reserved localhost domain is loopback")
    func localhostDomainIsPrivate() {
        #expect(ProxyPolicy.isPrivateAddress("service.localhost"))
    }

    // MARK: Robustness

    @Test("Malformed input answers no rather than trapping", arguments: [
        "", "   ", ":::", "10.0.0", "10.0.0.1.2", "10.0.0.256", "999.999.999.999",
        "[", "]", "%",
    ])
    func malformedIsNotPrivate(_ host: String) {
        #expect(!ProxyPolicy.isPrivateAddress(host))
    }

    /// A bracketed literal is what a URL carries, and a zone index identifies an
    /// interface rather than a different host, so neither may change the answer.
    @Test("Brackets and zone indices do not change the answer")
    func bracketsAndZones() {
        #expect(ProxyPolicy.isPrivateAddress("[::1]"))
        #expect(ProxyPolicy.isPrivateAddress("[fd00::1]"))
        #expect(ProxyPolicy.isPrivateAddress("fe80::1%en0"))
        // An EMPTY zone index is still just a zone index. What remains is a
        // well-formed link-local address, and reading it as private is both
        // right and the safe direction — the gate denies without an opt-in, so
        // a wrong answer here would open access rather than block it.
        #expect(ProxyPolicy.isPrivateAddress("fe80::1%"))
    }
}
