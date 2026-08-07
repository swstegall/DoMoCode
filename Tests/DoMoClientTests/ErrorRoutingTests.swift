// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Where a failure GOES, which is the half of "errors show no context" that the
// existing coverage does not ask about.
//
// The reported complaint is about placement: "errors for the domocode tui should
// throw in a dialog with enter to close, not break the tui at the prompt area".
// Before this file, a failure had exactly one destination — a transcript row —
// so a user reading the top of a long transcript, or looking at another window,
// was told nothing at all. Reproduced against the real binary under a PTY: a
// client pointed at a runtime that is not there paints
// `✗ Could not reach the runtime` into the transcript and nothing else; there is
// no modal, and nothing to press Enter on.
//
// The rule these tests pin is that BOTH now happen, and in that order: the row
// is the durable record a user scrolls back to, the dialog is what makes them
// notice there is something to scroll back to. And the one thing the dialog must
// never do is answer a question that was asked of the user — an approval prompt
// or a structured question owns the keyboard until it is answered.

import DoMoCore
import DoMoLLM
import DoMoServer
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

// MARK: - The store's two live doors

@MainActor
@Suite("Where a failure is routed")
struct ErrorRoutingTests {

    private func errorRows(_ store: EventStore) -> [String] {
        store.transcript.compactMap {
            if case .error(let headline, _, _) = $0 { headline } else { nil }
        }
    }

    @Test("A live error notice is announced once AND keeps its transcript row")
    func liveErrorNoticeIsAnnouncedAndKeepsItsRow() {
        let store = EventStore()
        store.select("s1")
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }

        store.apply(.notice(ServerNotice(
            level: .error,
            code: "provider_error",
            text: "The provider refused the request",
            detail: "HTTP 500: upstream is unavailable",
            kind: "provider"
        )))

        // The row is the durable half. A dialog that REPLACED it would leave a
        // user who pressed Enter with no way to read the failure again.
        #expect(errorRows(store).count == 1)
        #expect(announced.count == 1)
        #expect(announced.first?.message.contains("HTTP 500: upstream is unavailable") == true)
    }

    @Test("A warning notice is not announced — it is still a status-line glance")
    func warningsAreNotAnnounced() {
        let store = EventStore()
        store.select("s1")
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }

        store.apply(.notice(ServerNotice(level: .warning, code: "retry", text: "Retrying in 8s")))

        // Announcing a retry would put a modal in front of the user on every
        // backoff of a run that is recovering by itself.
        #expect(announced.isEmpty)
        #expect(errorRows(store).isEmpty)
        #expect(store.lastNotice?.code == "retry")
    }

    @Test("A client-side failure carries its headline, body and hint to the surface")
    func postedFailureCarriesAllThreeParts() {
        let store = EventStore()
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }

        store.postError(
            headline: "Could not send the message",
            message: "HTTP 502 from /session/abc/prompt: bad gateway",
            hint: "Your text was put back in the prompt."
        )

        #expect(announced.count == 1)
        let report = announced.first
        #expect(report?.headline == "Could not send the message")
        #expect(report?.message == "HTTP 502 from /session/abc/prompt: bad gateway")
        // The hint is where the "where do I see more" line rides, so a dialog that
        // dropped it would be strictly less useful than the row beside it.
        #expect(report?.hint == "Your text was put back in the prompt.")
        #expect(errorRows(store) == ["Could not send the message"])
    }

    @Test("A re-seed announces nothing — the reconnect must not re-open old failures")
    func reSeededHistoryIsNotAnnounced() {
        let store = EventStore()
        store.select("s1")
        let failed = Message.assistant(AssistantMessage(
            content: [],
            model: "m",
            stopReason: .error,
            errorMessage: "the provider hung up"
        ))

        // Live first, so the store has a reason to believe it knows this failure:
        // it learned the kind for these exact words. The re-seed below rebuilds
        // the same row from history.
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }
        store.apply(.notice(ServerNotice(
            level: .error, code: "provider_error", text: "the provider hung up", kind: "provider"
        )))
        #expect(announced.count == 1)

        store.seed([failed])
        store.seed([failed])

        // The stream re-seeds on EVERY reconnect, so announcing from `seed` would
        // put a modal in front of the user once per outage for a failure they read
        // and dismissed an hour ago — while the row it is about was already there.
        #expect(errorRows(store).count == 1, "the re-seeded row itself must survive")
        #expect(announced.count == 1, "a re-seed announced a failure it did not just receive")
    }

    @Test("What is announced is sanitized, exactly like the row")
    func announcedTextIsSanitized() {
        let store = EventStore()
        store.select("s1")
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }

        store.apply(.notice(ServerNotice(
            level: .error,
            code: "provider_error",
            text: "boom \u{1b}[2J\u{1b}[31mred",
            kind: "provider"
        )))

        // Provider prose reaches the frame through this value now, not only
        // through the transcript renderer, so the escape has to be gone here.
        let message = announced.first?.message ?? ""
        #expect(!message.contains("\u{1b}"))
        #expect(message.contains("boom"))
    }
}

// MARK: - The screen

/// The same claims against the REAL client: a stub runtime that fails, and the
/// bytes the client actually wrote replayed into a VT100 emulator.
///
/// A store-level test proves the routing decision; only this proves the
/// placement, and placement is what was reported.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ErrorPlacementOnScreenTests {
    static let token = "error-routing-token"

    private static let sessionRef = #"{"id":"abc123","path":"/tmp/abc123.jsonl"}"#
    private static let sessionList =
        #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/work","timestamp":"2026-01-01"}]"#

    private static func sse(_ events: [ServerEvent]) -> String {
        let encoder = JSONEncoder()
        return events.map { event in
            let json = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "data: \(json)\n\n"
        }.joined()
    }

    @Test("A failure is put in a dialog, and closing it leaves the transcript row behind")
    func failureIsPresentedInADialog() async throws {
        // The reproduction, made fast: a runtime that answers the session listing
        // with a 500 is the same experience as one that is not there, without the
        // ten-second connect timeout that makes the real case slow.
        let stub = try ExplainingServer(
            routes: [
                StubRoute("GET", "/sessions", 500, "Internal Server Error", "the session directory is gone"),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = try await WedgeClient.make(baseURL: stub.baseURL, token: Self.token)
        #expect(
            await client.wait(for: "Could not reach the runtime"),
            "the failure never reached the screen at all:\n\(client.joined())"
        )
        // The claim of this whole change. Before it, this failure had exactly one
        // destination — a row in a transcript the user may have scrolled away
        // from — and there was nothing to press Enter on.
        #expect(
            await client.wait(for: "Enter to close"),
            "the failure never became a dialog:\n\(client.joined())"
        )
        // The provider's own words, in the modal that has room for them.
        #expect(
            await client.wait(for: "the session directory is gone"),
            "the detail never reached the screen:\n\(client.joined())"
        )

        client.press()   // Enter closes it
        #expect(
            await client.waitUntilGone("Enter to close"),
            "Enter did not close the dialog:\n\(client.joined())"
        )
        // And the durable half is still there. Asserted AFTER the dialog is gone,
        // so it cannot be satisfied by the dialog's own copy of the words.
        #expect(
            client.showing("Could not reach the runtime"),
            "closing the dialog took the transcript row with it:\n\(client.joined())"
        )
        await client.quit()
    }

    @Test("A failure that arrives under an approval prompt waits for it to be answered")
    func failureQueuesBehindAnApprovalPrompt() async throws {
        // Both frames on one stream, in this order: the ask parks a tool call, and
        // the failure lands while the user is being asked to approve something.
        // Presenting over the prompt would collect the Enter that was meant for
        // it — i.e. answer a permission question on the user's behalf.
        let events = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: true),
            .permissionRequest(
                id: "req-1",
                sessionID: "abc123",
                permission: "edit",
                patterns: ["*"],
                always: [],
                metadata: ["filepath": .string("/work/notes.txt")],
                disableAlways: true
            ),
            .notice(ServerNotice(
                level: .error,
                code: "provider_error",
                text: "The provider dropped the turn",
                detail: "HTTP 503: upstream unavailable",
                kind: "provider"
            )),
        ])
        let stub = try ExplainingServer(
            routes: [
                // Above `POST /session`, which matches every POST this client makes.
                StubRoute("POST", "/permission", 200, "OK", ""),
                StubRoute("GET", "/sessions", 200, "OK", Self.sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                // ONCE, and then an outage. The stub closes the body after writing
                // it, so the client reconnects — and a SUCCESSFUL reconnect
                // re-seeds the transcript, which drops the pending prompt and
                // would take the modal down a few hundred milliseconds after it
                // appeared. A stream that stays down leaves the prompt exactly
                // where the user is looking at it, which is the state this test is
                // about. The outage earns a failure row of its own after eight
                // seconds; that is the same queueing rule, asserted twice.
                StubRoute("GET", "/events", 200, "OK", events, times: 1),
                StubRoute("GET", "/events", 503, "Service Unavailable", "the runtime is restarting"),
                StubRoute("POST", "/session", 201, "Created", Self.sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
        stub.start()
        defer { stub.stop() }

        let client = try await WedgeClient.make(baseURL: stub.baseURL, token: Self.token)
        #expect(
            await client.wait(for: "Permission required"),
            "the approval prompt never appeared:\n\(client.joined())"
        )
        // The failure is on the transcript immediately — only the MODAL waits.
        #expect(
            await client.wait(for: "The provider dropped the turn"),
            "the failure never reached the transcript:\n\(client.joined())"
        )
        #expect(
            !client.showing("Enter to close"),
            "an error dialog took the keyboard from an approval prompt:\n\(client.joined())"
        )

        client.press()   // Enter answers the prompt with the selected "Allow once"
        // And now it gets its turn: queued, not dropped.
        #expect(
            await client.wait(for: "Enter to close"),
            "the queued failure never appeared after the prompt cleared:\n\(client.joined())"
        )
        await client.quit()
    }
}

// MARK: - Recording does not depend on anyone listening

@MainActor
@Suite("Error recording is independent of the announcement")
struct ErrorRecordingIndependenceTests {

    /// The routing hook was first written as `onError?(appendError(…))`, which
    /// reads naturally and is wrong: Swift does not evaluate the argument of an
    /// optional call when the optional is nil, so the transcript row — the
    /// durable half — was produced only when something happened to be listening.
    /// Production set the hook, so the bug was invisible there; a consumer
    /// without one lost every error silently.
    @Test("A store with no error hook still records the row")
    func rowSurvivesWithNoHook() {
        let store = EventStore()
        store.select("s1")
        #expect(store.onError == nil, "this test is about the no-listener case")

        store.apply(.notice(ServerNotice(
            level: .error,
            code: "provider_error",
            text: "HTTP 401: Invalid API key",
            kind: "authentication"
        )))

        let rows = store.transcript.filter {
            if case .error = $0 { return true } else { return false }
        }
        #expect(rows.count == 1, "the row must not depend on an observer existing")
    }

    @Test("postError records without a hook too")
    func postErrorSurvivesWithNoHook() {
        let store = EventStore()
        store.select("s1")

        store.postError(headline: "Could not reach the runtime", message: "connect timeout", hint: nil)

        let rows = store.transcript.filter {
            if case .error = $0 { return true } else { return false }
        }
        #expect(rows.count == 1)
    }

    @Test("With a hook, the row and the announcement carry the same words")
    func rowAndAnnouncementAgree() {
        let store = EventStore()
        store.select("s1")
        var announced: [EventStore.ErrorReport] = []
        store.onError = { announced.append($0) }

        store.postError(headline: "Headline", message: "Detail", hint: "Hint")

        #expect(announced.count == 1)
        let row = store.transcript.compactMap { item -> String? in
            if case .error(let headline, _, _) = item { return headline } else { return nil }
        }
        #expect(row == [announced.first?.headline].compactMap { $0 })
    }
}
