// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The read side of the client's CQRS split. The server's SSE stream is
// delta-only (see ServerEvent's doc), so the client reconstructs the transcript
// itself: `seed(_:)` lays down the REST history for the selected session, then
// `apply(_:)` folds each live `ServerEvent` on top. The two-pane UI renders
// straight off this — it never touches the wire.
//
// `MainActor`: the UI reads it on the render actor, and the SSE consumer hops
// here to mutate it, so a frame never observes a half-applied event.

import DoMoCore
import DoMoLLM
import Foundation
import DoMoPermissions
import DoMoServer
import DoMoTermGraphics
import DoMoTUI

// MARK: - Event store

/// The normalized, renderable state of the client: the session list (sidebar),
/// which session is selected, that session's transcript (main pane), and whether
/// a turn is running.
@MainActor
public final class EventStore {
    /// Whether a turn is currently streaming for the selected session.
    public enum RunState: Sendable, Hashable {
        case idle
        case running
    }

    /// The session list backing the sidebar. Populated by `GET /sessions`; there
    /// is no cross-session push, so it is refreshed explicitly.
    public private(set) var sessions: [SessionSummary] = []
    /// The session whose transcript is shown, if any.
    public private(set) var selectedSessionID: String?
    /// The selected session's transcript, oldest first.
    public private(set) var transcript: [TranscriptItem] = []
    /// Whether the selected session has a turn in flight.
    public private(set) var runState: RunState = .idle
    /// The last `agent_end` reason (e.g. `completed`, `aborted`, `errored`), for a
    /// status line. Cleared when a new turn starts.
    public private(set) var lastStopReason: String?
    /// A pending permission prompt for the selected session (Phase 8b): the server
    /// asked over SSE and the run is parked until a client answers. `nil` when nothing
    /// is awaiting approval. Per-session, so it is cleared on a session switch.
    public private(set) var pendingPermission: PermissionRequest?
    /// Ids of prompts already resolved (or whose run ended) THIS session, so the
    /// `GET /permissions` reconcile can't resurrect a dead one that a `permission_resolved`
    /// raced ahead of. Cleared on a session switch (ids reset per session).
    private var resolvedRequestIDs: Set<String> = []

    /// The file backing the selected session, when the server told us.
    ///
    /// There is no log file in this program — the `Logger` bootstrap writes to
    /// stderr, and stderr under an active alternate screen is invisible — so the
    /// session JSONL is the only durable record of a run there is. Keeping the
    /// path here is what lets a failure row end with "Full transcript: <path>"
    /// instead of leaving "where do I see more" unanswered.
    ///
    /// Session-scoped, not transcript-scoped: ``seed(_:)`` replaces the
    /// transcript several times for the SAME session (the initial history, then
    /// every re-seed after a stream outage), and clearing the path on each of
    /// those would delete a fact that never stopped being true.
    public private(set) var sessionPath: String?

    /// The most recent non-error notice.
    ///
    /// Transient by contract: a `warning` or `info` notice is something the user
    /// may glance at and forget — a retry in progress, a refresh that did not
    /// land — and it is deliberately NOT put in `transcript`, which is the place
    /// reserved for things that must survive being scrolled past. Errors take
    /// the other door; see ``postError(headline:message:hint:)``.
    public private(set) var lastNotice: ServerNotice?

    /// When the last event of ANY kind arrived on the stream.
    ///
    /// The one fact that separates "the model is slow" from "nothing is
    /// connected", and the only reason a heartbeat is not a wasted frame. The
    /// server sends one every 15 s whether or not a turn is running, so a stream
    /// that has said nothing for appreciably longer than that is dead — whatever
    /// the socket believes. This store used to DISCARD heartbeats before recording
    /// anything about them, so a half-open connection (which throws nothing and
    /// delivers nothing) was completely invisible.
    ///
    /// Advanced only by ``apply(_:)`` — deliberately NOT by ``adopt(_:)``. A
    /// successful `/status` poll proves the SERVER is reachable, which is a
    /// different fact from the stream being alive, and folding the two together
    /// would hide exactly the failure the timestamp exists to expose.
    public private(set) var lastEventAt: Date = Date()

    /// Fired after any mutation, so the UI can request a render. Set by the app.
    public var onChange: (() -> Void)?

    /// Fired once per non-error notice, so a surface with a timed message area
    /// can start its own dwell clock.
    ///
    /// A callback rather than a poll of ``lastNotice``, because ``onChange``
    /// fires on every mutation: a status line that re-posted whatever
    /// `lastNotice` currently held would restart the four-second timer on every
    /// keystroke and the message would never go away.
    public var onNotice: ((ServerNotice) -> Void)?

    // Streaming bookkeeping — indices into `transcript` of the in-progress items.
    private var streamingAssistantIndex: Int?
    private var streamingReasoningIndex: Int?
    private var toolIndexByID: [String: Int] = [:]

    public init() {}

    // MARK: Sidebar

    /// Replace the session list.
    public func setSessions(_ sessions: [SessionSummary]) {
        self.sessions = sessions
        onChange?()
    }

    /// Select a session (or none). Clears the transcript; the caller then
    /// ``seed(_:)``s its history and attaches its event stream.
    public func select(_ sessionID: String?) {
        selectedSessionID = sessionID
        clearTranscript()
        // Cleared HERE and not in `clearTranscript`, which `seed(_:)` also calls:
        // the path belongs to the session, and a re-seed of the same session must
        // not forget where that session lives. Selecting a different one must.
        sessionPath = nil
        lastNotice = nil
        onChange?()
    }

    /// Record where the selected session is persisted, for a failure row's
    /// "where do I see more". `nil` when the server did not say.
    public func setSessionPath(_ path: String?) {
        guard sessionPath != path else { return }
        sessionPath = path
        onChange?()
    }

    // MARK: Transcript

    /// Lay down a session's REST history as the transcript base, replacing any
    /// current content. System messages are dropped; a tool result becomes one
    /// compact ``TranscriptItem/tool(name:output:isError:imageCount:)`` line (the
    /// assistant's tool *call* is represented by that result, not repeated).
    public func seed(_ messages: [Message]) {
        clearTranscript()
        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let user):
                if !user.text.isEmpty { transcript.append(.user(sanitizeUntrustedText(user.text))) }
                appendImages(user.content.compactMap(\.imageBlock))
            case .assistant(let assistant):
                if !assistant.text.isEmpty {
                    transcript.append(.assistant(sanitizeUntrustedText(assistant.text)))
                }
                // A failed turn carries its detail in `errorMessage`, never in
                // `text`. Gating on text alone is exactly why re-opening a session
                // that errored rendered as an EMPTY pane: the turn is persisted, the
                // reason is right there on it, and the renderer dropped the whole
                // message because it had no words in it.
                //
                // An abort is not a failure — `AssistantMessage.failure` answers a
                // `.cancelled` error for `stopReason == .aborted`, so `failure !=
                // nil` alone would paint every Esc red. `.length` answers nil: a
                // truncated turn is a short answer, not an error.
                //
                // No label: a persisted message carries prose, not a taxonomy (the
                // kind was never part of the JSONL shape), so a seeded row honestly
                // says "Something went wrong" rather than inventing a classification
                // it cannot know. A LIVE failure keeps its kind — it comes through
                // the notice frame, not through here.
                if let failure = assistant.failure, !failure.isCancellation {
                    appendError(ErrorPresentation.rows(label: nil, message: failure.message))
                }
            case .tool(let result):
                // History carries no arguments (the tool-result message has only the
                // name and the output), so `detail` is empty for seeded rows — live
                // rows fill it from `tool_start`.
                transcript.append(.tool(
                    name: sanitizeUntrustedText(result.toolName),
                    detail: "",
                    output: sanitizeUntrustedText(result.output),
                    state: result.isError ? .failed : .succeeded,
                    imageCount: result.images.count
                ))
                appendImages(result.images)
            }
        }
        onChange?()
    }

    /// Fold one live event onto the transcript.
    ///
    /// Tool activity is taken from `tool_start`/`tool_end` only; the tool-result
    /// *message* frames (`message_start`/`message_end` for the `tool` role) and
    /// system messages are ignored, so a tool call is never double-counted.
    public func apply(_ event: ServerEvent) {
        // ABOVE the switch, so the `.heartbeat` arm's early `return` — the frame
        // whose ONLY purpose is to prove the stream is alive — still advances it.
        lastEventAt = Date()
        switch event {
        case .connected(_, _, let running):
            // Adopt the server's run state, in BOTH directions.
            //
            // Without adopting it at all, the client's flag is write-once per attach —
            // it only ever learns "running" from an `agent_start` it witnessed — so
            // attaching mid-turn left it stuck on "idle" for the rest of the turn.
            // Adopting only the `true` direction is just as bad the other way: a
            // reconnect that missed the turn's `agent_end` pins the client on
            // "running" FOREVER, and the synchronous submit guard then refuses every
            // prompt for the life of the session. The server owns this flag; the frame
            // is authoritative at the instant it is sent.
            //
            // `nil` means the server predates the field and said nothing, which is not
            // the same as saying "idle" — leave the old behaviour alone.
            guard let running else { break }
            if running {
                runState = .running
                lastStopReason = nil
            } else {
                runState = .idle
                // A turn that is over cannot still have a tool call in flight; without
                // this the row (and its spinner) animates forever.
                settleActiveToolCalls()
                if let id = pendingPermission?.id { resolvedRequestIDs.insert(id) }
                pendingPermission = nil
            }

        case .heartbeat, .turnStart, .turnEnd:
            return   // no transcript effect (version handled by the caller)

        case .notice(let notice):
            // The two doors, and the rule that picks between them: an error the
            // user has to ACT on becomes a persistent transcript row, because a
            // message that evaporates after four seconds is a message that was
            // never delivered. Everything else is a glance — a retry in flight, a
            // refresh that did not land — and belongs on the status line, where it
            // does not push the conversation up the screen.
            switch notice.level {
            case .error:
                appendError(ErrorPresentation.rows(
                    label: notice.kind,
                    message: Self.noticeBody(notice)
                ))
            case .warning, .info:
                lastNotice = notice
                onNotice?(notice)
            }

        case .agentStart:
            runState = .running
            lastStopReason = nil

        case .agentEnd(let reason):
            runState = .idle
            lastStopReason = reason
            endStreaming()
            // A turn that ended cannot still be waiting on approval.
            if let id = pendingPermission?.id { resolvedRequestIDs.insert(id) }
            pendingPermission = nil
            // The loop emits a `tool_end` for every call it started, including
            // aborted ones — but a run that died before the loop settled (the
            // server's `errored` close) can leave a row in flight. Settle it, so a
            // spinner cannot outlive the turn that owns it.
            settleActiveToolCalls()

        case .permissionRequest(let id, let sessionID, let permission, let patterns, let always, let metadata, let disableAlways):
            // Drop a prompt that is NOT for the selected session (a late frame from a
            // session being switched away from would otherwise pop a modal here and
            // silently decide the WRONG session's tool call), and one whose id was
            // already resolved this session (a resolve that raced the GET reconcile).
            guard sessionID == selectedSessionID, !resolvedRequestIDs.contains(id) else { return }
            pendingPermission = PermissionRequest(
                id: id, sessionID: sessionID, permission: permission,
                patterns: patterns, always: always, metadata: metadata, disableAlways: disableAlways
            )
            markPendingToolAwaitingApproval()

        case .permissionResolved(let id):
            resolvedRequestIDs.insert(id)
            if pendingPermission?.id == id {
                pendingPermission = nil
                markPendingToolAwaitingApproval()
            }

        case .messageStart(let message):
            switch message {
            case .user(let user):
                if !user.text.isEmpty { transcript.append(.user(sanitizeUntrustedText(user.text))) }
                appendImages(user.content.compactMap(\.imageBlock))
            case .assistant:
                // Don't reserve a row yet: the first non-empty delta (or a
                // non-empty message_end) creates it. A tool-call-only or aborted
                // turn then leaves no blank row, matching seed(); and reasoning that
                // streams before the answer renders above it in natural order.
                streamingAssistantIndex = nil
                streamingReasoningIndex = nil
            case .system, .tool:
                break
            }

        case .messageDelta(let text, let reasoning):
            if let text, !text.isEmpty { appendAssistantDelta(sanitizeUntrustedText(text)) }
            if let reasoning, !reasoning.isEmpty { appendReasoningDelta(sanitizeUntrustedText(reasoning)) }

        case .messageEnd(let message):
            switch message {
            case .assistant(let assistant) where !assistant.text.isEmpty:
                // Replace the streamed buffer with the authoritative final text when
                // a row was streamed, else append. A tool-call-only turn (empty text)
                // leaves nothing.
                if let index = streamingAssistantIndex, transcript.indices.contains(index) {
                    transcript[index] = .assistant(sanitizeUntrustedText(assistant.text))
                } else {
                    transcript.append(.assistant(sanitizeUntrustedText(assistant.text)))
                }
            case .tool(let result):
                // The tool row itself came from tool_start/tool_end (which carry only
                // a count); the actual image bytes ride the tool-role message frame,
                // so display them here, after the tool row.
                appendImages(result.images)
            default:
                break
            }
            streamingAssistantIndex = nil
            streamingReasoningIndex = nil

        case .toolStart(let id, let name, let arguments):
            // The arguments ride the wire and used to be dropped on the floor; they
            // are what turns an anonymous `edit` row into `edit  src/Foo.swift`.
            transcript.append(.tool(
                name: sanitizeUntrustedText(name),
                detail: toolCallDetail(name: name, arguments: arguments),
                output: "",
                state: .running,
                imageCount: 0
            ))
            toolIndexByID[id] = transcript.count - 1
            // A prompt can be asked before this row exists (the ask and the start are
            // separate frames, and the drop-oldest stream can reorder nothing but can
            // deliver the ask first on a reconcile); re-apply the marking so the new
            // row picks it up.
            markPendingToolAwaitingApproval()

        case .toolEnd(let id, let name, let output, let isError, let imageCount):
            // Keep the detail from `tool_start` — `tool_end` does not repeat it.
            var detail = ""
            if let index = toolIndexByID[id], transcript.indices.contains(index),
               case .tool(_, let existing, _, _, _) = transcript[index] {
                detail = existing
            }
            let item = TranscriptItem.tool(
                name: sanitizeUntrustedText(name),
                detail: detail,
                output: sanitizeUntrustedText(output),
                state: isError ? .failed : .succeeded,
                imageCount: imageCount
            )
            if let index = toolIndexByID[id], transcript.indices.contains(index) {
                transcript[index] = item
                toolIndexByID[id] = nil
            } else {
                transcript.append(item)
            }
        }
        onChange?()
    }

    // MARK: The server's authoritative view

    /// Fold a server-authoritative status snapshot.
    ///
    /// The server owns run state and the pending-prompt set; the client's copy is
    /// only ever a fold of edge-triggered frames, and every one of those edges can
    /// be missed. Once an edge is missed, nothing in the edge-triggered world can
    /// undo it: a client that never saw `agent_end` believes a turn is in flight
    /// forever, and the synchronous submit guard then refuses every prompt for the
    /// life of the session. This is how it gets back in sync without needing a
    /// reconnect it has no reason to make.
    ///
    /// Ignores a snapshot for a session that is no longer selected — a poll in
    /// flight across a session switch must not decide the new session's state.
    public func adopt(_ status: SessionStatus) {
        guard status.sessionID == selectedSessionID else { return }
        if status.running {
            if runState != .running {
                runState = .running
                lastStopReason = nil
            }
        } else if runState != .idle {
            runState = .idle
            // A turn that is over cannot still have a tool call in flight, and
            // cannot still be waiting on approval.
            settleActiveToolCalls()
            if let id = pendingPermission?.id { resolvedRequestIDs.insert(id) }
            pendingPermission = nil
        }
        // Drop a modal the server no longer has parked. This is the case where the
        // `permission_resolved` echo was the frame that got lost: the run moved on,
        // and the client is holding a question nobody is waiting for an answer to.
        if let pending = pendingPermission, !status.pendingPermissionIDs.contains(pending.id) {
            resolvedRequestIDs.insert(pending.id)
            pendingPermission = nil
            markPendingToolAwaitingApproval()
        }
        onChange?()
    }

    /// Whether any of `ids` names a prompt this store has neither parked nor
    /// already answered — i.e. an ask that was lost in transit.
    ///
    /// The bounded broadcast buffers drop the OLDEST frame, and a `permission_request`
    /// is followed by the deltas of whatever else the run is doing, so the ask is
    /// exactly the frame most likely to be evicted. Recovering it used to require a
    /// reconnect, because the `connected` reconcile was the only caller of
    /// `GET /permissions`; a stream that never drops does not reconnect, so a
    /// prompt lost this way was lost for good.
    public func hasUnseenPermission(in ids: [String]) -> Bool {
        guard pendingPermission == nil else { return false }
        return ids.contains { !resolvedRequestIDs.contains($0) }
    }

    // MARK: Failures

    /// Append a failure row.
    ///
    /// **The single entry point for client-side failures too.** A `try?` that
    /// swallowed a transport error had nowhere to say so, which is why eleven of
    /// them accumulated; now there is one obvious place, and a bootstrap that
    /// could not list sessions renders in exactly the same shape as a gateway
    /// that rejected the credential. Persistent by design — a transient notice
    /// is the wrong surface for anything the user has to act on.
    public func postError(headline: String, message: String, hint: String? = nil) {
        appendError((headline: headline, message: message, hint: hint))
        onChange?()
    }

    /// Whether the transcript holds anything `^O` acts on: a failure row with a
    /// body, or a failed tool call with output.
    ///
    /// Deliberately width-independent, so it can be read in the same frame that
    /// builds the status line. That makes it very slightly generous — a body
    /// short enough to fit uncapped still counts — which is the safe direction:
    /// it can advertise a key that turns out to have nothing more to show, never
    /// hide one that does.
    public var hasExpandableDetail: Bool {
        transcript.contains { item in
            switch item {
            case .error(_, let message, _):
                return !message.isEmpty
            case .tool(_, _, let output, let state, _):
                return state == .failed && !output.isEmpty
            case .user, .assistant, .reasoning, .image:
                return false
            }
        }
    }

    /// The message a notice contributes to its row: the headline line, plus the
    /// provider's own words underneath when the notice carried a second line.
    ///
    /// Re-capped after joining rather than trusting the producer's per-field cap,
    /// because two fields each within budget are not one field within budget.
    private static func noticeBody(_ notice: ServerNotice) -> String {
        guard let detail = notice.detail, !detail.isEmpty else { return notice.text }
        return DoMoError.truncating(notice.text + "\n" + detail)
    }

    /// Put a failure row on the transcript, sanitizing all three parts.
    ///
    /// Sanitized HERE as well as at the render boundary, and deliberately so.
    /// `ErrorPresentation.rows` cannot sanitize — `DoMoCore` has no access to
    /// `DoMoTUI`'s `sanitizeUntrustedText` — and this is the ingress every other
    /// untrusted string in this file already passes through, so the invariant
    /// "nothing in `transcript` carries an ESC introducer" holds for the whole
    /// type rather than for all-but-one of its cases. The renderer sanitizes too
    /// because it also draws rows that did not come from here.
    private func appendError(_ parts: (headline: String, message: String, hint: String?)) {
        transcript.append(.error(
            headline: sanitizeUntrustedText(parts.headline),
            message: sanitizeUntrustedText(parts.message),
            hint: parts.hint.map(sanitizeUntrustedText)
        ))
    }

    // MARK: Tool call state

    /// The tool call currently in flight, if any — what the status line reports so
    /// "busy" can name the thing it is busy with.
    public var activeToolCall: (name: String, detail: String, state: ToolCallState)? {
        for item in transcript.reversed() {
            guard case .tool(let name, let detail, _, let state, _) = item else { continue }
            if state.isActive { return (name, detail, state) }
        }
        return nil
    }

    /// Mark the newest in-flight tool row as parked on approval, or put it back to
    /// running when nothing is pending.
    ///
    /// Permission asks are strictly sequential (the agent loop prepares tool calls
    /// one at a time, and the ask happens inside that preparation), so "the newest
    /// active tool call" is unambiguously the one being asked about. Deriving it
    /// this way means no new field has to be threaded onto the wire to correlate a
    /// request id with a tool call id.
    private func markPendingToolAwaitingApproval() {
        let wanted: ToolCallState = pendingPermission == nil ? .running : .awaitingApproval
        for index in transcript.indices.reversed() {
            guard case .tool(let name, let detail, let output, let state, let imageCount) = transcript[index] else { continue }
            guard state.isActive else { continue }
            if state != wanted {
                transcript[index] = .tool(name: name, detail: detail, output: output, state: wanted, imageCount: imageCount)
            }
            return
        }
    }

    // MARK: Streaming helpers

    /// Append one image item per block, each with a freshly-allocated stable Kitty
    /// id so the differential renderer can track and delete it across frames.
    private func appendImages(_ images: [ImageBlock]) {
        for image in images {
            transcript.append(.image(image, imageId: allocateImageId()))
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if let index = streamingAssistantIndex,
           transcript.indices.contains(index),
           case .assistant(let current) = transcript[index] {
            transcript[index] = .assistant(current + delta)
        } else {
            transcript.append(.assistant(delta))
            streamingAssistantIndex = transcript.count - 1
        }
    }

    private func appendReasoningDelta(_ delta: String) {
        if let index = streamingReasoningIndex,
           transcript.indices.contains(index),
           case .reasoning(let current) = transcript[index] {
            transcript[index] = .reasoning(current + delta)
        } else {
            transcript.append(.reasoning(delta))
            streamingReasoningIndex = transcript.count - 1
        }
    }

    /// Force the run state to idle, for a caller that learned authoritatively that
    /// nothing is running (an abort the server reports as a no-op). Settles any tool
    /// row still in flight, so a spinner cannot outlive the turn it belongs to.
    public func markIdle() {
        guard runState != .idle else { return }
        runState = .idle
        settleActiveToolCalls()
        onChange?()
    }

    /// Clear the pending prompt after the client answers it (optimistic — the
    /// server's `permission_resolved` echo also clears it, idempotently), so the
    /// overlay-reconcile does not re-present the request it just answered.
    public func clearPendingPermission() {
        pendingPermission = nil
        markPendingToolAwaitingApproval()
        onChange?()
    }

    /// Turn any still-in-flight tool row into a terminal state. A call that never
    /// reported an end did not succeed, so it settles as failed rather than being
    /// left to look either finished or forever busy.
    private func settleActiveToolCalls() {
        for index in transcript.indices {
            guard case .tool(let name, let detail, let output, let state, let imageCount) = transcript[index],
                  state.isActive
            else { continue }
            transcript[index] = .tool(name: name, detail: detail, output: output, state: .failed, imageCount: imageCount)
        }
        toolIndexByID = [:]
    }

    private func endStreaming() {
        streamingAssistantIndex = nil
        streamingReasoningIndex = nil
    }

    private func clearTranscript() {
        // Fresh data is a sign of life: a re-seed that did NOT reset this would
        // leave a newly-opened session reporting the previous one's silence.
        lastEventAt = Date()
        transcript = []
        streamingAssistantIndex = nil
        streamingReasoningIndex = nil
        toolIndexByID = [:]
        runState = .idle
        lastStopReason = nil
        // A pending prompt belongs to the session being left; a switch back re-fetches
        // it (GET /permissions), so it must not linger and show against the wrong one.
        pendingPermission = nil
        resolvedRequestIDs = []
    }
}
