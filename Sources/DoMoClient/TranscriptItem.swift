// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The client's read model. The server streams a projection of the runtime's
// events (deltas, not snapshots); the client folds that stream — plus the REST
// history it seeds from — into this flat, renderable transcript. One item per
// visible block, in arrival order, is all the two-pane main view needs.

import DoMoLLM

// MARK: - Tool call state

/// Where a tool call has got to.
///
/// The wire carries `tool_start` and `tool_end` but nothing in between, and the
/// gap between them is exactly where a run parks waiting for the user to approve
/// the call. Modelling the middle explicitly is what lets the transcript say
/// "running" and "waiting for you" rather than showing a finished-looking row with
/// an empty result — the state a user reads as "it froze".
public enum ToolCallState: Sendable, Hashable {
    /// Started, still executing.
    case running
    /// Started, and parked on a permission prompt nobody has answered yet.
    case awaitingApproval
    /// Finished successfully.
    case succeeded
    /// Finished with an error (including a rejected permission).
    case failed

    /// Whether the call is still in flight — the two states that animate.
    public var isActive: Bool {
        self == .running || self == .awaitingApproval
    }
}

// MARK: - Transcript item

/// One rendered block in a session transcript.
///
/// Deliberately smaller than ``DoMoLLM/Message``: the UI shows who spoke and what
/// they said, plus a compact line per tool call. Reasoning is kept separate so it
/// can be dimmed or hidden. Streaming grows the string in place — an ``assistant``
/// or ``reasoning`` item's text accumulates as `message_delta` frames arrive, then
/// is replaced with the authoritative text on `message_end`.
public enum TranscriptItem: Sendable, Hashable {
    /// A user prompt.
    case user(String)
    /// Assistant output. Grows during streaming, finalized on `message_end`.
    case assistant(String)
    /// Assistant reasoning, when the gateway forwarded it.
    case reasoning(String)
    /// A tool invocation and its result.
    ///
    /// `detail` is the one-line argument summary (the file path, the shell command,
    /// the search pattern) taken from the `tool_start` arguments, so the row says
    /// *what* the tool is doing and not merely that it is doing something. `output`
    /// is empty until `tool_end`; `state` says whether that emptiness means
    /// "running", "waiting for you", or "finished with nothing to say".
    case tool(name: String, detail: String, output: String, state: ToolCallState, imageCount: Int)
    /// An image to display inline — a user attachment or a tool-produced image.
    /// The `imageId` is a stable Kitty id, allocated once when the item is created,
    /// so the differential renderer can track and delete the image across frames.
    case image(ImageBlock, imageId: UInt32)
    /// A failure with no message of its own.
    ///
    /// A transcript row rather than a status-line notice, because an error the
    /// user has to act on must not evaporate after four seconds — it has to
    /// survive scrollback, and be copyable. The three parts are the ones
    /// ``DoMoCore/ErrorPresentation/rows(label:message:)`` produces: `headline`
    /// names the class of failure, `message` is what actually happened, `hint`
    /// is what to do about it (nil where there is nothing honest to say).
    ///
    /// `message` is model- or gateway-controlled and is sanitized on the way in,
    /// exactly like assistant text and tool output.
    case error(headline: String, message: String, hint: String?)
}
