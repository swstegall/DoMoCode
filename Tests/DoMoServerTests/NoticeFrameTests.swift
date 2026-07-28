// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The `notice` frame is the one additive wire case this release ships, and its
// `Kind`/`CodingKeys`/`encode`/`decode` arms are hand-written in four separate
// places. A frame that encodes but does not decode (or vice versa) would fail
// silently — `ServerClient.parseFrame` swallows a decode failure by design — so
// the codec is pinned here rather than discovered later.
//
// A separate file from `ServerEventTests.swift` so the areas landing behaviour on
// top of this seam are appending, never editing someone else's cases.

import DoMoAgent
import DoMoCore
import DoMoServer
import Foundation
import Testing

@Suite("The notice frame")
struct NoticeFrameTests {

    @Test("A notice round-trips through JSON with every field populated")
    func fullRoundTrip() throws {
        let event = ServerEvent.notice(ServerNotice(
            level: .error,
            code: "provider_error",
            text: "the gateway said no",
            detail: "upstream: 502 bad gateway",
            kind: DoMoError.Kind.authentication.label,
            ttlMilliseconds: 8_000
        ))
        let decoded = try JSONDecoder().decode(
            ServerEvent.self, from: try JSONEncoder().encode(event)
        )
        #expect(decoded == event)
    }

    @Test("The optional fields are genuinely optional in both directions")
    func minimalRoundTrip() throws {
        let event = ServerEvent.notice(ServerNotice(level: .info, code: "retry", text: "retrying"))
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(ServerEvent.self, from: data) == event)

        let json = try JSONValue(parsing: data)
        #expect(json["type"]?.stringValue == "notice")
        #expect(json["notice"]?["level"]?.stringValue == "info")
        #expect(json["notice"]?["code"]?.stringValue == "retry")
        #expect(json["notice"]?["text"]?.stringValue == "retrying")
        #expect(json["notice"]?["detail"] == nil)
        #expect(json["notice"]?["kind"] == nil)
        #expect(json["notice"]?["ttlMilliseconds"] == nil)
    }

    @Test("A runtime notice projects onto the wire, Duration becoming milliseconds")
    func projection() {
        let notice = AgentNotice(
            level: .warning,
            code: "retry",
            text: "Retrying in 8s (attempt 4/10) — provider busy",
            detail: "503 service unavailable",
            kind: DoMoError.Kind.provider(status: 503, isRetryable: true).label,
            ttl: .milliseconds(10_500)
        )
        #expect(
            ServerEvent.project(.notice(notice))
                == .notice(ServerNotice(
                    level: .warning,
                    code: "retry",
                    text: "Retrying in 8s (attempt 4/10) — provider busy",
                    detail: "503 service unavailable",
                    kind: "provider",
                    ttlMilliseconds: 10_500
                ))
        )
    }

    @Test("A sub-millisecond TTL rounds DOWN rather than to a surprising zero-or-one")
    func ttlRoundsDown() {
        func millis(_ ttl: Duration) -> Int? {
            guard case .notice(let n)? = ServerEvent.project(
                .notice(AgentNotice(level: .info, code: "c", text: "t", ttl: ttl))
            ) else { return nil }
            return n.ttlMilliseconds
        }
        #expect(millis(.zero) == 0)
        #expect(millis(.microseconds(999)) == 0)
        #expect(millis(.milliseconds(1)) == 1)
        #expect(millis(.seconds(3) + .milliseconds(499)) == 3_499)
    }

    @Test("A TTL too large for milliseconds saturates instead of trapping")
    func ttlSaturates() {
        // `Retry-After` is text from the far side of a wire and clamps to a
        // `Duration` near `Int64.max` seconds — which overflows `× 1000`.
        guard case .notice(let n)? = ServerEvent.project(.notice(
            AgentNotice(level: .info, code: "c", text: "t", ttl: .seconds(Int64.max / 2))
        )) else { return #expect(Bool(false), "projection dropped a notice") }
        #expect(n.ttlMilliseconds == Int.max)
    }

    @Test("No TTL stays no TTL — the consumer's default, not a zero dwell")
    func absentTTL() {
        guard case .notice(let n)? = ServerEvent.project(.notice(
            AgentNotice(level: .info, code: "c", text: "t")
        )) else { return #expect(Bool(false), "projection dropped a notice") }
        #expect(n.ttlMilliseconds == nil)
    }

    @Test("Every level crosses the wire under its own name")
    func levels() throws {
        for (agent, server) in [
            (AgentNotice.Level.info, ServerNotice.Level.info),
            (.warning, .warning),
            (.error, .error),
        ] {
            let projected = ServerEvent.project(
                .notice(AgentNotice(level: agent, code: "c", text: "t"))
            )
            #expect(projected == .notice(ServerNotice(level: server, code: "c", text: "t")))
            let json = try JSONValue(parsing: try JSONEncoder().encode(projected))
            #expect(json["notice"]?["level"]?.stringValue == agent.rawValue)
        }
    }

    @Test("A notice's kind is a DoMoError label, so a reader can classify it back")
    func kindIsAWireLabel() {
        let notice = ServerNotice(
            level: .error, code: "provider_error", text: "401",
            kind: DoMoError.Kind.authentication.label
        )
        #expect(DoMoError.Kind.labeled(notice.kind ?? "") == .authentication)
        #expect(
            ErrorPresentation.rows(label: notice.kind, message: notice.text).headline
                == "The gateway rejected the credential"
        )
    }

    @Test("The new stop reason has a stable snake_case spelling")
    func noProgressOnTheWire() {
        #expect(
            ServerEvent.project(.agentEnd(messages: [], reason: .noProgress))
                == .agentEnd(reason: "no_progress")
        )
    }

    @Test("An older client drops an unknown frame instead of tearing the stream down")
    func unknownFrameIsDropped() throws {
        // This is why `serverProtocolVersion` need not move for an additive
        // frame. `ServerClient.parseFrame` is internal to DoMoClient, but the
        // property it relies on is this one: an unrecognized `type` fails to
        // decode, and a `try?` there turns that into a skipped frame.
        let unknown = Data(#"{"type":"telepathy","payload":1}"#.utf8)
        #expect((try? JSONDecoder().decode(ServerEvent.self, from: unknown)) == nil)
        // ...while a KNOWN frame in the same stream still decodes, so dropping
        // one costs exactly one frame.
        let known = Data(#"{"type":"heartbeat"}"#.utf8)
        #expect(try JSONDecoder().decode(ServerEvent.self, from: known) == .heartbeat)
    }
}
