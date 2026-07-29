// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The client half of "errors that show no context": where a failure enters the
// read model, how it survives the rest of the turn, and what `^O` does to the
// rows that were capped.
//
// Every test here answers a symptom that was reported rather than a line that
// was written: an errored session that re-opens as an empty pane, a status line
// that says only `idle (errored)`, a failed tool whose reason is eight rows and
// a dead end, and a toggle key that could have been wired into a memo cache and
// silently done nothing.

import DoMoCore
import DoMoLLM
import DoMoServer
import DoMoTermGraphics
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

@MainActor
private func errorRows(_ store: EventStore) -> [(headline: String, message: String, hint: String?)] {
    store.transcript.compactMap {
        if case .error(let headline, let message, let hint) = $0 {
            (headline: headline, message: message, hint: hint)
        } else {
            nil
        }
    }
}

private func assistant(
    _ text: String,
    stopReason: StopReason,
    errorMessage: String? = nil
) -> Message {
    .assistant(AssistantMessage(
        content: text.isEmpty ? [] : [.text(text)],
        model: "m",
        stopReason: stopReason,
        errorMessage: errorMessage
    ))
}

@MainActor
@Suite("The client's error surface")
struct ErrorSurfaceTests {

    // MARK: The notice frame

    @Test("An error notice becomes a persistent row with a headline, the text, and a remedy")
    func errorNoticeBecomesARow() {
        let store = EventStore()
        store.select("s1")
        store.apply(.notice(ServerNotice(
            level: .error,
            code: "provider_error",
            text: "stream chat completions: HTTP 401: Invalid API key",
            kind: "authentication"
        )))

        let rows = errorRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.headline == "The gateway rejected the credential")
        #expect(rows.first?.message.contains("Invalid API key") == true)
        // The remedy is the answer to "is my key wrong": it exists precisely so
        // the user does not have to know the taxonomy to act on it.
        #expect(rows.first?.hint?.contains("credential") == true)
    }

    @Test("Each classified kind reaches its own headline, and an unknown one is not guessed at")
    func kindsReachTheirHeadlines() {
        func headline(_ kind: String?) -> String? {
            let store = EventStore()
            store.select("s1")
            store.apply(.notice(ServerNotice(level: .error, code: "provider_error", text: "x", kind: kind)))
            return errorRows(store).first?.headline
        }
        #expect(headline("authentication") == "The gateway rejected the credential")
        #expect(headline("context_overflow") == "The conversation no longer fits the context window")
        #expect(headline("transport") == "Cannot reach the gateway")
        #expect(headline("provider") == "The gateway returned an error")
        // A label a newer server invented must read as unclassified, never as a
        // wrong kind that sends the reader after the wrong remedy.
        #expect(headline("wormhole_collapse") == "Something went wrong")
        #expect(headline(nil) == "Something went wrong")
    }

    @Test("A notice's second line is kept, so the gateway's own words survive")
    func noticeDetailIsKept() {
        let store = EventStore()
        store.select("s1")
        store.apply(.notice(ServerNotice(
            level: .error, code: "provider_error",
            text: "The gateway returned an error",
            detail: "upstream connect error or disconnect/reset before headers",
            kind: "provider"
        )))
        #expect(errorRows(store).first?.message.contains("upstream connect error") == true)
    }

    @Test("A gateway cannot smuggle an escape sequence into the store through a notice")
    func noticeTextIsSanitised() {
        let store = EventStore()
        store.select("s1")
        store.apply(.notice(ServerNotice(
            level: .error, code: "provider_error",
            text: "before\u{1b}[2Jafter", detail: "d\u{1b}[5Ae", kind: "provider"
        )))
        let row = errorRows(store).first
        #expect(row?.message.contains("\u{1b}") == false)
        #expect(row?.message.contains("before") == true)
    }

    @Test("A warning or info notice stays transient — it never enters the transcript")
    func nonErrorNoticesAreTransient() {
        let store = EventStore()
        store.select("s1")
        var seen: [ServerNotice] = []
        store.onNotice = { seen.append($0) }
        store.apply(.notice(ServerNotice(level: .warning, code: "retry", text: "Retrying in 8s")))
        store.apply(.notice(ServerNotice(level: .info, code: "x", text: "fyi")))

        #expect(errorRows(store).isEmpty)
        #expect(store.transcript.isEmpty)
        #expect(store.lastNotice?.text == "fyi")
        #expect(seen.map(\.text) == ["Retrying in 8s", "fyi"])
    }

    @Test("An error row outlives the turn it belongs to")
    func errorRowsArePersistent() {
        // The whole reason this is a transcript row and not a status message: an
        // error the user must act on cannot evaporate four seconds later, and the
        // next turn must not wipe it either.
        let store = EventStore()
        store.select("s1")
        store.postError(headline: "Could not send the message", message: "HTTP 502")
        store.apply(.agentEnd(reason: "completed"))
        store.apply(.agentStart)
        store.apply(.messageDelta(text: "a new answer", reasoning: nil))
        #expect(errorRows(store).count == 1)
    }

    // MARK: Seeding a session that failed

    @Test("Re-opening a session whose turn errored renders the reason, not an empty pane")
    func seededFailedTurnRenders() {
        // The reported bug, exactly. The turn IS persisted and its reason IS on
        // it; `seed` dropped the whole message because it gated on `text` alone,
        // and a failed turn has no text.
        let store = EventStore()
        store.select("s1")
        store.seed([
            .user(UserMessage(content: [.text("hello")])),
            assistant("", stopReason: .error, errorMessage: "HTTP 401: Invalid API key"),
        ])
        let rows = errorRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.message.contains("Invalid API key") == true)
    }

    @Test("An aborted turn is not painted red")
    func seededAbortIsNotAnError() {
        // `AssistantMessage.failure` answers a non-nil `.cancelled` error for an
        // abort, so `failure != nil` alone would turn every Esc into a scary red
        // block — the failure mode `DoMoError.isCancellation` exists to prevent.
        let store = EventStore()
        store.select("s1")
        store.seed([assistant("", stopReason: .aborted, errorMessage: "Request was aborted")])
        #expect(errorRows(store).isEmpty)
    }

    @Test("A truncated turn is a short answer, not a failure")
    func seededLengthStopIsNotAnError() {
        let store = EventStore()
        store.select("s1")
        store.seed([assistant("as far as I got", stopReason: .length)])
        #expect(errorRows(store).isEmpty)
        #expect(store.transcript.count == 1)
    }

    @Test("A failed turn that DID say something keeps both the words and the reason")
    func seededFailureKeepsPartialText() {
        let store = EventStore()
        store.select("s1")
        store.seed([assistant("here is half an ans", stopReason: .error, errorMessage: "connection reset")])
        #expect(store.transcript.count == 2)
        if case .assistant(let text) = store.transcript.first { #expect(text.contains("half an ans")) }
        #expect(errorRows(store).first?.message.contains("connection reset") == true)
    }

    @Test("A re-seed replaces the rows rather than doubling them")
    func reSeedDoesNotDouble() {
        // Live errors come from the notice frame, history errors from `seed`, and
        // `seed` clears first — so a reconnect that re-fetches history cannot
        // stack a second copy of the same failure.
        let store = EventStore()
        store.select("s1")
        let history: [Message] = [assistant("", stopReason: .error, errorMessage: "boom")]
        store.seed(history)
        store.seed(history)
        #expect(errorRows(store).count == 1)
    }

    // MARK: Where to look

    @Test("The session file is remembered across a re-seed and forgotten on a switch")
    func sessionPathLifetime() {
        let store = EventStore()
        store.select("s1")
        store.setSessionPath("/sessions/s1.jsonl")
        // A re-seed of the SAME session must not forget where that session lives:
        // `open` learns the path before it fetches history, and the row's "where
        // do I see more" would otherwise be blank exactly when it matters.
        store.seed([])
        #expect(store.sessionPath == "/sessions/s1.jsonl")
        store.select("s2")
        #expect(store.sessionPath == nil)
    }

    // MARK: What ^O is offered for

    @Test("The expand hint is offered only where there is detail to expand")
    func expandableDetail() {
        let store = EventStore()
        store.select("s1")
        #expect(!store.hasExpandableDetail)

        store.apply(.agentStart)
        store.apply(.toolStart(id: "t", name: "bash", arguments: .object([:])))
        store.apply(.toolEnd(id: "t", name: "bash", output: "ok", isError: false, imageCount: 0))
        #expect(!store.hasExpandableDetail, "a SUCCEEDED tool is not expandable detail")

        store.apply(.toolStart(id: "u", name: "bash", arguments: .object([:])))
        store.apply(.toolEnd(id: "u", name: "bash", output: "boom", isError: true, imageCount: 0))
        #expect(store.hasExpandableDetail)

        let other = EventStore()
        other.select("s2")
        other.postError(headline: "h", message: "m")
        #expect(other.hasExpandableDetail)
    }

    // MARK: Rendering

    @Test("Expanding shows the whole body AND busts the render memo")
    func expandBustsTheCache() {
        // The regression this pins is a specific, silent one: `expandErrors` added
        // to the memo tuple but not to its comparison (or the reverse) leaves the
        // cache matching, so the key is pressed, the flag flips, and the screen
        // does not change.
        let view = TranscriptView()
        view.items = [.error(
            headline: "The gateway returned an error",
            message: (1...80).map { "line \($0)" }.joined(separator: "\n"),
            hint: nil
        )]
        let collapsed = view.render(width: 40)
        view.expandErrors = true
        let expanded = view.render(width: 40)
        #expect(expanded.count > collapsed.count, "the toggle did nothing — check the memo key")
        #expect(expanded.joined().contains("line 80"))
        #expect(!collapsed.joined().contains("line 80"))
    }

    @Test("A capped body names the key that uncaps it and counts what is behind it")
    func cappedBodyNamesTheKey() {
        let view = TranscriptView()
        view.items = [.error(headline: "h", message: (1...200).map { "line \($0)" }.joined(separator: "\n"), hint: nil)]
        let rows = view.render(width: 40).dropLast()
        #expect(rows.count <= 14, "a 200-line body must not push the conversation off the screen")
        #expect(rows.joined().contains("^O"))
        #expect(rows.joined().contains("188 more lines"))
    }

    @Test("A failed tool gets the headroom its output is for; a successful one does not")
    func failedToolGetsMoreRows() {
        // The text was always on the wire. What was missing was room to read it
        // and a door to open when eight rows were not enough.
        let output = (1...30).map { "diagnostic \($0)" }.joined(separator: "\n")
        func rows(_ state: ToolCallState, expanded: Bool = false) -> [String] {
            let view = TranscriptView()
            view.expandErrors = expanded
            view.items = [.tool(name: "bash", detail: "", output: output, state: state, imageCount: 0)]
            return view.render(width: 40)
        }
        #expect(rows(.failed).count > rows(.succeeded).count)
        #expect(rows(.succeeded).joined().contains("^O"))
        #expect(rows(.failed, expanded: true).joined().contains("diagnostic 30"))
        #expect(!rows(.failed).joined().contains("diagnostic 30"))
    }

    @Test("Tool output never overflows a pane too narrow to hold its indent")
    func toolBodyFitsANarrowPane() {
        // `max(1, width - 2)` bottoms out at one column, and prefixing that with a
        // two-space indent emits a THREE-column row into a two-column pane — which
        // does not wrap, it overwrites whatever is drawn beside it.
        for width in [1, 2, 3, 4, 8, 40] {
            let view = TranscriptView()
            view.items = [.tool(
                name: "bash", detail: "",
                output: String(repeating: "x", count: 200),
                state: .failed, imageCount: 0
            )]
            for row in view.render(width: width) {
                #expect(visibleWidth(row) <= width, "width \(width): row was \(visibleWidth(row)) columns")
            }
        }
    }

    @Test("Every error row fits its pane at every width, expanded or not")
    func errorRowsFitEveryWidth() {
        for expanded in [false, true] {
            for width in [1, 2, 3, 5, 17, 40, 120] {
                let view = TranscriptView()
                view.expandErrors = expanded
                view.items = [.error(
                    headline: "The conversation no longer fits the context window",
                    message: (1...40).map { "cause \($0) in the chain" }.joined(separator: ": "),
                    hint: "Compact it and retry."
                )]
                for row in view.render(width: width) {
                    #expect(visibleWidth(row) <= width, "width \(width) expanded=\(expanded): \(visibleWidth(row))")
                }
            }
        }
    }

    // MARK: The transport's own words

    @Test("An HTTP error carries the body, so a 500 stops looking like a 502")
    func errorBodyIsCarried() {
        #expect(ServerClient.errorBody(Data("upstream connect error".utf8)) == "upstream connect error")
        #expect(ServerClient.errorBody(Data()) == nil)
        #expect(ServerClient.errorBody(nil) == nil)
        // Whitespace-only is nothing to show, not an empty ": " on the end of a
        // sentence.
        #expect(ServerClient.errorBody(Data("  \n ".utf8)) == nil)
        // A gateway can answer with an entire HTML page; this row ends up in a
        // transcript.
        let huge = ServerClient.errorBody(Data(String(repeating: "z", count: 10_000).utf8))
        #expect((huge?.count ?? 0) <= ServerClient.errorBodyCharacterCap + 1)
    }
}
