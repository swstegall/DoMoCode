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

import DoMoLLM
import DoMoPermissions
import DoMoServer
import DoMoTermGraphics

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

    /// Fired after any mutation, so the UI can request a render. Set by the app.
    public var onChange: (() -> Void)?

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
                if !user.text.isEmpty { transcript.append(.user(user.text)) }
                appendImages(user.content.compactMap(\.imageBlock))
            case .assistant(let assistant):
                if !assistant.text.isEmpty {
                    transcript.append(.assistant(assistant.text))
                }
            case .tool(let result):
                transcript.append(.tool(
                    name: result.toolName,
                    output: result.output,
                    isError: result.isError,
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
        switch event {
        case .connected, .heartbeat, .turnStart, .turnEnd:
            return   // no transcript effect (connection/version handled by the caller)

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

        case .permissionResolved(let id):
            resolvedRequestIDs.insert(id)
            if pendingPermission?.id == id { pendingPermission = nil }

        case .messageStart(let message):
            switch message {
            case .user(let user):
                if !user.text.isEmpty { transcript.append(.user(user.text)) }
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
            if let text, !text.isEmpty { appendAssistantDelta(text) }
            if let reasoning, !reasoning.isEmpty { appendReasoningDelta(reasoning) }

        case .messageEnd(let message):
            switch message {
            case .assistant(let assistant) where !assistant.text.isEmpty:
                // Replace the streamed buffer with the authoritative final text when
                // a row was streamed, else append. A tool-call-only turn (empty text)
                // leaves nothing.
                if let index = streamingAssistantIndex, transcript.indices.contains(index) {
                    transcript[index] = .assistant(assistant.text)
                } else {
                    transcript.append(.assistant(assistant.text))
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

        case .toolStart(let id, let name, _):
            transcript.append(.tool(name: name, output: "", isError: false, imageCount: 0))
            toolIndexByID[id] = transcript.count - 1

        case .toolEnd(let id, let name, let output, let isError, let imageCount):
            let item = TranscriptItem.tool(name: name, output: output, isError: isError, imageCount: imageCount)
            if let index = toolIndexByID[id], transcript.indices.contains(index) {
                transcript[index] = item
                toolIndexByID[id] = nil
            } else {
                transcript.append(item)
            }
        }
        onChange?()
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

    /// Clear the pending prompt after the client answers it (optimistic — the
    /// server's `permission_resolved` echo also clears it, idempotently), so the
    /// overlay-reconcile does not re-present the request it just answered.
    public func clearPendingPermission() {
        pendingPermission = nil
        onChange?()
    }

    private func endStreaming() {
        streamingAssistantIndex = nil
        streamingReasoningIndex = nil
    }

    private func clearTranscript() {
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
